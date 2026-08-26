#!/usr/bin/env python3
"""Drive the shipped Linux TUI through a real controlling PTY."""

from __future__ import annotations

import errno
import fcntl
import os
import pathlib
import pty
import select
import signal
import struct
import sys
import tempfile
import termios
import time

TIMEOUT = 12.0
DEFAULT_SIZE = (24, 100)


class Tui:
    def __init__(
        self,
        binary: pathlib.Path,
        profile: pathlib.Path,
        env: dict[str, str],
        size: tuple[int, int],
    ):
        master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", size[0], size[1], 0, 0))
        self.initial_termios = termios.tcgetattr(slave)
        self.requested_size = size
        pid = os.fork()
        if pid == 0:
            try:
                os.close(master)
                os.setsid()
                fcntl.ioctl(slave, termios.TIOCSCTTY, 0)
                for fd in (0, 1, 2):
                    os.dup2(slave, fd)
                if slave > 2:
                    os.close(slave)
                os.execve(binary, [str(binary), "--profile", str(profile)], env)
            except BaseException:
                os._exit(127)

        os.close(slave)
        self.master = master
        self.pid = pid
        self.output = bytearray()
        self.status: int | None = None
        self.kitty_queries_seen = 0
        self.status_queries_seen = 0

    def send(self, data: bytes) -> None:
        os.write(self.master, data)

    def wait_for(self, text: str) -> None:
        needle = text.encode()
        deadline = time.monotonic() + TIMEOUT
        while needle not in self.output:
            self._read_once(deadline)
            if self.status is not None and needle not in self.output:
                raise RuntimeError(f"TUI exited before rendering {text!r}; wait status {self.status}")

    def suspend_and_resume(self, marker: str) -> None:
        needle = marker.encode()
        count_before = self.output.count(needle)
        cleanup_start = len(self.output)
        os.kill(self.pid, signal.SIGTSTP)
        deadline = time.monotonic() + TIMEOUT
        while self.output.count(needle) <= count_before:
            self._read_once(deadline)
        cleanup = self.output[cleanup_start:]
        for sequence in (b"\x1b[?25h", b"\x1b[?1049l", b"\x1b[<u"):
            if sequence not in cleanup:
                raise AssertionError(f"suspend cleanup omitted {sequence!r}")

    def finish(self, expected_exit: int) -> bytes:
        deadline = time.monotonic() + TIMEOUT
        while self.status is None:
            self._read_once(deadline)
        exit_code = os.WEXITSTATUS(self.status) if os.WIFEXITED(self.status) else None
        if exit_code != expected_exit:
            raise RuntimeError(f"TUI exited with wait status {self.status}")
        final_termios = termios.tcgetattr(self.master)
        packed_size = fcntl.ioctl(self.master, termios.TIOCGWINSZ, b"\0" * 8)
        final_size = struct.unpack("HHHH", packed_size)[:2]
        expected_size = (self.requested_size[0] or 24, self.requested_size[1] or 80)
        if final_termios != self.initial_termios:
            raise AssertionError("TUI did not restore the original termios state")
        if final_size != expected_size:
            raise AssertionError(f"TUI changed the PTY size: {final_size}, expected {expected_size}")
        for sequence in (b"\x1b[?25h", b"\x1b[?1049l", b"\x1b[<u"):
            if sequence not in self.output:
                raise AssertionError(f"TUI cleanup omitted {sequence!r}")
        os.close(self.master)
        return bytes(self.output)

    def abort(self) -> None:
        if self.status is None:
            try:
                os.kill(self.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(self.pid, 0)
        os.close(self.master)

    def _read_once(self, deadline: float) -> None:
        pid, status = os.waitpid(self.pid, os.WNOHANG)
        if pid:
            self.status = status
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            rendered = bytes(self.output[-4000:]).decode(errors="replace")
            raise TimeoutError(f"TUI timed out; final output:\n{rendered}")
        readable, _, _ = select.select([self.master], [], [], min(0.1, remaining))
        if readable:
            try:
                chunk = os.read(self.master, 65536)
                self.output.extend(chunk)
                kitty_queries = self.output.count(b"\x1b[?u")
                while self.kitty_queries_seen < kitty_queries:
                    os.write(self.master, b"\x1b[?0u")
                    self.kitty_queries_seen += 1
                # libvaxis wakes its reader thread during shutdown with a
                # device-status query. A terminal answers it; this PTY driver
                # must do the same or App.run cannot finish joining the reader.
                status_queries = self.output.count(b"\x1b[5n")
                while self.status_queries_seen < status_queries:
                    os.write(self.master, b"\x1b[0n")
                    self.status_queries_seen += 1
            except OSError as exc:
                if exc.errno != errno.EIO:
                    raise


def run_case(
    name: str,
    binary: pathlib.Path,
    profile: pathlib.Path,
    actions: list[tuple[str, str | bytes | int]],
    env: dict[str, str],
    size: tuple[int, int] = DEFAULT_SIZE,
    expected_exit: int = 0,
) -> bytes:
    tui = Tui(binary, profile, env, size)
    try:
        for operation, value in actions:
            if operation == "wait":
                tui.wait_for(str(value))
            elif operation == "signal":
                os.kill(tui.pid, int(value))
            elif operation == "suspend":
                tui.suspend_and_resume(str(value))
            else:
                tui.send(bytes(value))
        output = tui.finish(expected_exit)
    except BaseException:
        tui.abort()
        raise
    print(f"PASS  {name}")
    return output


def main() -> int:
    repo = pathlib.Path(__file__).resolve().parent.parent
    binary = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else "zig-out/bin/keywise").resolve()
    if not os.access(binary, os.X_OK):
        raise SystemExit(f"no executable at {binary}")

    env = os.environ.copy()
    env["TERM"] = "xterm-256color"

    terminal_output = run_case(
        "an unsized PTY opens a Firefox 154 profile with no logins",
        binary,
        repo / "core/testdata/no-logins",
        [("wait", "Opening"), ("wait", "Firefox"), ("send", b"q")],
        env,
        size=(0, 0),
    )
    if b"\x1b[>29u" not in terminal_output or b"\x1b[>31u" in terminal_output:
        raise AssertionError("TUI requested Kitty key-release events")
    if b"(vaxis)" in terminal_output:
        raise AssertionError("vaxis diagnostics flashed before the first frame")
    run_case(
        "SIGTERM restores terminal modes before exiting with shell status 143",
        binary,
        repo / "core/testdata/fresh",
        [("wait", "tombstones"), ("signal", signal.SIGTERM)],
        env,
        expected_exit=143,
    )
    run_case(
        "SIGTSTP cleans the terminal before rebuilding it after resume",
        binary,
        repo / "core/testdata/fresh",
        [("wait", "tombstones"), ("suspend", "tombstones"), ("send", b"q")],
        env,
    )
    run_case(
        "a Primary Password rejects a wrong value and accepts the right one",
        binary,
        repo / "core/testdata/primary",
        [
            ("wait", "Primary"),
            ("send", b"wrong\r"),
            ("wait", "Wrong"),
            ("send", b"fixture-primary-password-1\r"),
            ("wait", "tombstones"),
            ("send", b"q"),
        ],
        env,
    )

    with tempfile.TemporaryDirectory() as tmp_string:
        tmp = pathlib.Path(tmp_string)
        clipboard = tmp / "clipboard"
        helper = tmp / "xclip"
        helper.write_text("#!/bin/sh\ncat > \"$KEYWISE_CLIPBOARD_FILE\"\n")
        helper.chmod(0o755)
        copy_env = env | {
            "DISPLAY": ":99",
            "KEYWISE_CLIPBOARD_FILE": str(clipboard),
            "PATH": f"{tmp}:{env.get('PATH', '')}",
        }
        run_case(
            "reveal and the Linux clipboard-helper path copy the selected password",
            binary,
            repo / "core/testdata/fresh",
            [
                ("wait", "tombstones"),
                ("send", b"\r"),
                ("wait", "fixture-pass-1"),
                ("send", b"y"),
                ("wait", "copied"),
                ("send", b"q"),
            ],
            copy_env,
        )
        if clipboard.read_bytes() != b"fixture-pass-1":
            raise AssertionError("clipboard helper did not receive the selected password")

    print("PASS  every interactive Linux TUI case")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
