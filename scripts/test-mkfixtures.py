#!/usr/bin/env python3
"""Drives the installed Firefox over Marionette to write fixture profiles.

The installed Firefox writes every fixture, so the bytes come from NSS. A
generator built on this project's own reading of key4.db and logins.json
would show that the reader agrees with itself. See
core/testdata/README.md for what each fixture covers.

Usage:
    scripts/test-mkfixtures.py fresh       --profile core/testdata/fresh/profile
    scripts/test-mkfixtures.py primary     --profile core/testdata/primary/profile
    scripts/test-mkfixtures.py sync-shaped --profile core/testdata/sync-shaped/profile
    scripts/test-mkfixtures.py migrate     --profile core/testdata/migrated/profile
    scripts/test-mkfixtures.py overflow
    scripts/test-mkfixtures.py fanout
    scripts/test-mkfixtures.py page64k
    scripts/test-mkfixtures.py reserved
    scripts/test-mkfixtures.py random

The first four subcommands launch Firefox, drive it, and quit it. Firefox
must be fully closed before the caller reads key4.db or logins.json, so this
script always waits for the child process to exit.

The `overflow`, `page64k` and `random` subcommands run no Firefox. Each writes
one database through Python's own sqlite3. The `fanout` and `reserved` subcommands
run neither, and assemble their pages byte by byte. See
core/testdata/README.md.
"""

import argparse
import json
import os
import random
import socket
import sqlite3
import struct
import subprocess
import sys
import time

MARIONETTE_PORT = 2828
DEFAULT_FIREFOX = "/Applications/Firefox.app/Contents/MacOS/firefox"


class MarionetteError(RuntimeError):
    pass


class Marionette:
    """A minimal client for the Marionette wire protocol (v3).

    Every message, in both directions, is framed as ``<byte length>:<json>``.
    A command is the array ``[0, message_id, name, params]``. A response is
    ``[1, message_id, error_or_null, result]``.
    """

    def __init__(self, host="127.0.0.1", port=MARIONETTE_PORT, timeout=30):
        self._sock = socket.create_connection((host, port), timeout=timeout)
        self._buf = b""
        self._next_id = 1
        self._read_handshake()

    def _read_exact(self, n):
        while len(self._buf) < n:
            chunk = self._sock.recv(65536)
            if not chunk:
                raise MarionetteError("connection closed while reading")
            self._buf += chunk
        out, self._buf = self._buf[:n], self._buf[n:]
        return out

    def _read_message(self):
        length = b""
        while True:
            if b":" in self._buf:
                idx = self._buf.index(b":")
                length, self._buf = self._buf[:idx], self._buf[idx + 1 :]
                break
            chunk = self._sock.recv(65536)
            if not chunk:
                raise MarionetteError("connection closed while reading a length prefix")
            self._buf += chunk
        payload = self._read_exact(int(length))
        return json.loads(payload.decode("utf-8"))

    def _read_handshake(self):
        self.handshake = self._read_message()

    def _send(self, name, params):
        msg_id = self._next_id
        self._next_id += 1
        packet = json.dumps([0, msg_id, name, params]).encode("utf-8")
        self._sock.sendall(str(len(packet)).encode("ascii") + b":" + packet)
        return msg_id

    def command(self, name, params=None):
        msg_id = self._send(name, params or {})
        while True:
            reply = self._read_message()
            if reply[0] != 1:
                continue
            _, reply_id, error, result = reply
            if reply_id != msg_id:
                continue
            if error is not None:
                raise MarionetteError(f"{name}: {error}")
            return result

    def new_session(self):
        return self.command("WebDriver:NewSession", {"capabilities": {}})

    def set_context(self, value):
        return self.command("Marionette:SetContext", {"value": value})

    def execute_script(self, script, args=None):
        return self.command(
            "WebDriver:ExecuteScript",
            {
                "script": script,
                "args": args or [],
                "sandbox": None,
                "newSandbox": False,
                "filename": "mkfixtures.py",
                "line": 1,
            },
        )

    def execute_async_script(self, script, args=None):
        return self.command(
            "WebDriver:ExecuteAsyncScript",
            {
                "script": script,
                "args": args or [],
                "sandbox": None,
                "newSandbox": False,
                "filename": "mkfixtures.py",
                "line": 1,
            },
        )

    def quit(self):
        self._sock.close()


def wait_for_marionette(port, deadline):
    while time.time() < deadline:
        try:
            return Marionette(port=port)
        except (ConnectionRefusedError, OSError):
            time.sleep(0.2)
    raise MarionetteError(f"Marionette never answered on port {port}")


class FirefoxDriver:
    """Launches one headless Firefox against one profile and drives it."""

    def __init__(self, firefox, profile_dir, port=MARIONETTE_PORT):
        self.firefox = firefox
        self.profile_dir = profile_dir
        self.port = port
        self.proc = None
        self.client = None

    def __enter__(self):
        os.makedirs(self.profile_dir, exist_ok=True)
        prefs_path = os.path.join(self.profile_dir, "user.js")
        with open(prefs_path, "a", encoding="utf-8") as f:
            f.write('user_pref("app.update.auto", false);\n')
            f.write(f'user_pref("marionette.port", {self.port});\n')

        self.proc = subprocess.Popen(
            [
                self.firefox,
                "--headless",
                "--marionette",
                "--remote-allow-system-access",
                "--profile",
                self.profile_dir,
                "--no-remote",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        self.client = wait_for_marionette(self.port, time.time() + 30)
        self.client.new_session()
        self.client.set_context("chrome")
        return self

    def __exit__(self, exc_type, exc, tb):
        if self.client is not None:
            try:
                self.client.execute_script("Services.startup.quit(Ci.nsIAppStartup.eForceQuit);")
            except (MarionetteError, OSError, BrokenPipeError):
                pass
            self.client.quit()
        if self.proc is not None:
            try:
                self.proc.wait(timeout=20)
            except subprocess.TimeoutExpired:
                self.proc.kill()
                self.proc.wait(timeout=10)
        for name in ("key4.db-wal", "key4.db-shm", "logins.json.bak"):
            p = os.path.join(self.profile_dir, name)
            if os.path.exists(p):
                os.remove(p)


ADD_LOGIN_SCRIPT = """
const [hostname, formActionOrigin, httpRealm, username, password,
       usernameField, passwordField, resolve] = arguments;
(async () => {
  const login = Cc["@mozilla.org/login-manager/loginInfo;1"]
    .createInstance(Ci.nsILoginInfo);
  login.init(
    hostname,
    formActionOrigin === "" ? null : formActionOrigin,
    httpRealm === "" ? null : httpRealm,
    username, password, usernameField, passwordField);
  await Services.logins.addLoginAsync(login);
  resolve("ok");
})().catch(e => resolve("error: " + e));
"""


def add_login(fx, hostname, username, password, form_action_origin="", http_realm="",
              username_field="", password_field=""):
    result = fx.client.execute_async_script(
        ADD_LOGIN_SCRIPT,
        [hostname, form_action_origin, http_realm, username, password,
         username_field, password_field],
    )
    result = result.get("value", result) if isinstance(result, dict) else result
    if result != "ok":
        raise MarionetteError(f"addLoginAsync failed: {result}")


SET_PRIMARY_PASSWORD_SCRIPT = """
const [password, resolve] = arguments;
(async () => {
  const token = Cc["@mozilla.org/security/internalkeytoken;1"]
    .createInstance(Ci.nsIPKCS11Token);
  // A never-initialized token takes its first password through
  // changePassword("", new). Firefox's own changemp.js does the same:
  // the uninitialized case sets oldpw = "" and calls changePassword.
  // initPassword does not set it.
  token.changePassword("", password);
  resolve("ok " + token.needsLogin() + " " + token.checkPassword(password));
})().catch(e => resolve("error: " + e));
"""


def set_primary_password(fx, password):
    result = fx.client.execute_async_script(SET_PRIMARY_PASSWORD_SCRIPT, [password])
    result = result.get("value", result) if isinstance(result, dict) else result
    if not result.startswith("ok "):
        raise MarionetteError(f"changePassword failed: {result}")


# Synthetic credentials only. See core/testdata/README.md.
STANDARD_LOGINS = [
    dict(hostname="https://example.com", username="fixture-user-1",
         password="fixture-pass-1", form_action_origin="https://example.com",
         username_field="user", password_field="pass"),
    dict(hostname="https://sub.example.org", username="fixture-user-2",
         password="fixture-pass-2", form_action_origin="https://sub.example.org",
         username_field="user", password_field="pass"),
    dict(hostname="http://plain.example.net", username="fixture-user-3",
         password="fixture-pass-3", http_realm="Restricted Area"),
]

PRIMARY_PASSWORD_FIXTURE = "fixture-primary-password-1"


def cmd_fresh(args):
    with FirefoxDriver(args.firefox, args.profile, args.port) as fx:
        for login in STANDARD_LOGINS:
            add_login(fx, **login)


def cmd_primary(args):
    with FirefoxDriver(args.firefox, args.profile, args.port) as fx:
        for login in STANDARD_LOGINS:
            add_login(fx, **login)
        set_primary_password(fx, PRIMARY_PASSWORD_FIXTURE)


def cmd_sync_shaped(args):
    with FirefoxDriver(args.firefox, args.profile, args.port) as fx:
        for login in STANDARD_LOGINS:
            add_login(fx, **login)
        add_login(
            fx,
            hostname="chrome://FirefoxAccounts",
            username="fixture@example.com",
            password=json.dumps({"kSync": "fixture-sync-key", "kXCS": "fixture-kxcs"}),
            http_realm="Firefox Accounts credentials",
        )
        add_login(
            fx,
            hostname="moz-extension://fixture-extension-id",
            username="fixture-ext-user",
            password="fixture-ext-pass",
            http_realm="fixture-extension-realm",
        )

    logins_path = os.path.join(args.profile, "logins.json")
    with open(logins_path, encoding="utf-8") as f:
        data = json.load(f)
    now = int(time.time() * 1000)
    data["logins"].append({
        "id": 9001,
        "guid": "{fixture-tombstone-0000-000000000001}",
        "deleted": True,
        "everSynced": True,
        "syncCounter": 1,
        "timePasswordChanged": now,
    })
    data["logins"].append({
        "id": 9002,
        "guid": "{fixture-tombstone-0000-000000000002}",
        "deleted": True,
        "everSynced": True,
        "syncCounter": 1,
        "timePasswordChanged": now,
    })
    with open(logins_path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)


def cmd_migrate(args):
    """Reopens an existing (unmigrated) profile once with this Firefox."""
    with FirefoxDriver(args.firefox, args.profile, args.port):
        pass


# A 512-byte page puts the payload threshold at 477 bytes, so every `wide`
# row below spills onto an overflow page. 400 of them give the table 6
# interior pages. A key4.db has 32768-byte pages and rows of about 400 bytes,
# and each of its tables fits on one leaf page.
OVERFLOW_ROWS = 400


def cmd_overflow(args):
    """Writes one database whose rows spill onto overflow pages.

    Python's sqlite3 writes the file, so the bytes still come from SQLite.
    Each row's content derives from its row number. Two runs write the same
    bytes.
    """
    if os.path.exists(args.out):
        os.remove(args.out)

    con = sqlite3.connect(args.out)
    con.execute("PRAGMA page_size = 512")
    con.execute("PRAGMA journal_mode = delete")
    con.execute(
        "CREATE TABLE wide (id INTEGER PRIMARY KEY, label TEXT, body BLOB, n INT, f REAL, spare)"
    )
    # metaData and nssPrivate declare their primary key with no type, so the
    # column stores a value of its own. `wide.id` above declares INTEGER, so
    # it aliases the rowid and the record stores a NULL.
    con.execute("CREATE TABLE narrow (id PRIMARY KEY UNIQUE ON CONFLICT REPLACE, item1, item2)")

    for i in range(OVERFLOW_ROWS):
        # Three rows carry a body long enough to need a chain of overflow
        # pages. The rest need one page each. The width cycles so that both
        # branches of the local-size formula are reached.
        size = 20000 if i % 137 == 0 else 500 + (i * 29) % 400
        body = bytes((i + j) % 256 for j in range(size))
        con.execute(
            "INSERT INTO wide (id, label, body, n, f, spare) VALUES (?, ?, ?, ?, ?, ?)",
            (i + 1, f"row-{i}", body, i * -7919, i / 8.0, None),
        )

    for i in range(3):
        con.execute(
            "INSERT INTO narrow VALUES (?, ?, ?)",
            (f"key-{i}", bytes([i]) * (i * 400), None),
        )

    con.commit()
    con.close()


# The 64 KB page fixture. Header offset 16 is two bytes wide, so SQLite stores
# a 65536-byte page as 1 and sqlitedb.Db.open maps that value back. Every
# key4.db uses 32768 bytes and never reaches the mapping.
PAGE64K_SIZE = 65536
# usable is 65536, so max_local is 65501 and min_local is 8199. A 70000-byte
# blob gives a 70005-byte record: k is 70005, past max_local, so local falls
# back to min_local. A 75000-byte blob gives 75005, k is 9473, and local takes
# k. Each row spills onto one overflow page.
PAGE64K_BLOBS = (70000, 75000)


def cmd_page64k(args):
    """Writes one database with a 65536-byte page.

    Python's sqlite3 writes the file, so the bytes come from SQLite. Each
    blob's content derives from its byte position, so two runs write the same
    bytes.
    """
    if os.path.exists(args.page64k_out):
        os.remove(args.page64k_out)

    con = sqlite3.connect(args.page64k_out)
    con.execute(f"PRAGMA page_size = {PAGE64K_SIZE}")
    con.execute("PRAGMA journal_mode = delete")
    con.execute("CREATE TABLE wide (id INTEGER PRIMARY KEY, body BLOB)")
    for size in PAGE64K_BLOBS:
        con.execute("INSERT INTO wide (body) VALUES (?)", (payload_bytes(size),))
    con.commit()
    con.close()


def payload_bytes(size):
    """Content that names its own byte position.

    A reader that takes the wrong number of local bytes returns a shifted copy
    of this, and a byte-for-byte comparison reports it.
    """
    return bytes((i * 7) % 251 for i in range(size))


# The reserved-bytes fixture. Header offset 20 reserves a tail on every page
# for an extension such as SEE, and sqlitedb's payload arithmetic counts
# page_size minus that tail. Firefox loads no extension, so every key4.db
# stores 0 there and no fixture sqlite3 writes can separate the two fields.
# cmd_reserved below assembles the file byte by byte.
RESERVED_PAGE_SIZE = 512
RESERVED_TAIL = 16
# usable is 496, so max_local is 461 and min_local is 37. A 600-byte record
# gives k = 108, so 108 bytes sit in the cell and 492 on one overflow page.
# Reading the same file with page_size in place of usable takes 92 local bytes.
RESERVED_RECORD = 600
RESERVED_SQL = b"CREATE TABLE wide(id INTEGER PRIMARY KEY, body BLOB)"


def reserved_file_header(page_count):
    """The 100-byte header at offset 0, with a non-zero reserved field."""
    h = bytearray(100)
    h[0:16] = b"SQLite format 3\x00"
    h[16:18] = struct.pack(">H", RESERVED_PAGE_SIZE)
    h[18] = 1  # write version 1, so the reader does not report WalJournal
    h[19] = 1
    h[20] = RESERVED_TAIL
    h[21] = 64
    h[22] = 32
    h[23] = 32
    h[24:28] = struct.pack(">I", 1)
    h[28:32] = struct.pack(">I", page_count)
    h[44:48] = struct.pack(">I", 4)
    h[56:60] = struct.pack(">I", 1)  # text encoding UTF-8
    h[92:96] = struct.pack(">I", 1)
    h[96:100] = struct.pack(">I", 3045000)
    return bytes(h)


def reserved_leaf_page(cell, header=None):
    """One table leaf page holding `cell`, written into a full page.

    `header` is the 100-byte file header for page 1, and None for every other
    page. Page 1 puts its b-tree header after that header. The cell ends where
    the reserved tail starts, so no byte of the payload lands in the tail.
    """
    p = bytearray(RESERVED_PAGE_SIZE)
    base = 0
    if header is not None:
        p[0:100] = header
        base = 100
    start = RESERVED_PAGE_SIZE - RESERVED_TAIL - len(cell)
    p[start:start + len(cell)] = cell
    p[base] = 0x0D  # table leaf
    p[base + 3:base + 5] = struct.pack(">H", 1)
    p[base + 5:base + 7] = struct.pack(">H", start)
    # The cell pointer array of a leaf starts 8 bytes into the b-tree header. A
    # zero here sends the reader to a cell at offset 0.
    p[base + 8:base + 10] = struct.pack(">H", start)
    return bytes(p)


def cmd_reserved(args):
    """Writes one database whose pages reserve a 16-byte tail.

    The record spans the cell's own page and one overflow page. Its content
    derives from its byte position, so a reader that counts page_size where it
    should count usable bytes returns different bytes.
    """
    usable = RESERVED_PAGE_SIZE - RESERVED_TAIL
    max_local = usable - 35
    min_local = ((usable - 12) * 32 // 255) - 23
    k = min_local + (RESERVED_RECORD - min_local) % (usable - 4)
    local = k if k <= max_local else min_local

    # Serial type 0 for the rowid alias, 12 + 2n for a blob of n bytes. The
    # blob fills what the record has left after its own header.
    blob = RESERVED_RECORD - 4
    record = bytes([4, 0]) + sqlite_varint(12 + 2 * blob) + payload_bytes(blob)
    assert len(record) == RESERVED_RECORD, len(record)

    # A table leaf cell: the payload size, the rowid, the local bytes, then the
    # first overflow page number.
    cell = (sqlite_varint(RESERVED_RECORD) + sqlite_varint(1) +
            record[:local] + struct.pack(">I", 3))

    master_payload = (
        bytes([6, 13 + 2 * 5, 13 + 2 * 4, 13 + 2 * 4, 1, 13 + 2 * len(RESERVED_SQL)]) +
        b"table" + b"wide" + b"wide" + bytes([2]) + RESERVED_SQL
    )
    master_cell = sqlite_varint(len(master_payload)) + sqlite_varint(1) + master_payload

    # The overflow page: the next page number, then the rest of the record.
    overflow = bytearray(RESERVED_PAGE_SIZE)
    rest = record[local:]
    assert len(rest) <= usable - 4, len(rest)
    overflow[4:4 + len(rest)] = rest

    pages = [
        reserved_leaf_page(master_cell, reserved_file_header(3)),
        reserved_leaf_page(cell),
        bytes(overflow),
    ]
    with open(args.reserved_out, "wb") as f:
        f.write(b"".join(pages))


# The fan-out fixture. sqlite3 refuses to write a b-tree that reaches one page
# twice, so cmd_fanout below assembles every page byte by byte.
FANOUT_PAGE_SIZE = 512
# A 512-byte interior page carries a 12-byte header and 5-byte cells. 71 cells
# take 355 content bytes and 142 pointer bytes, and 12 + 355 + 142 is 509. A
# 72nd cell overlaps the pointer array with the content area. The reader
# returns Corrupt for that overlap, and this fixture tests the page budget.
FANOUT_CELLS = 71
# Each level multiplies the child count by 72. At 21 levels the walk reaches
# 72**21 leaves through a 23-page file.
FANOUT_LEVELS = 21


def sqlite_varint(n):
    """SQLite's own varint: big-endian, 7 bits per byte. This is not LEB128."""
    if n < 0x80:
        return bytes([n])
    out = []
    while n:
        out.append(n & 0x7F)
        n >>= 7
    out.reverse()
    return bytes([b | 0x80 for b in out[:-1]]) + bytes([out[-1]])


def fanout_file_header(page_count):
    """The 100-byte header at offset 0. sqlitedb.Db.open reads six fields."""
    h = bytearray(100)
    h[0:16] = b"SQLite format 3\x00"
    h[16:18] = struct.pack(">H", FANOUT_PAGE_SIZE)
    h[18] = 1  # write version 1, so the reader does not report WalJournal
    h[19] = 1
    h[20] = 0  # no reserved tail, so usable equals the page size
    h[21] = 64
    h[22] = 32
    h[23] = 32
    h[24:28] = struct.pack(">I", 1)
    h[28:32] = struct.pack(">I", page_count)
    h[44:48] = struct.pack(">I", 4)
    h[56:60] = struct.pack(">I", 1)  # text encoding UTF-8
    h[92:96] = struct.pack(">I", 1)
    h[96:100] = struct.pack(">I", 3045000)
    return bytes(h)


def fanout_page1(page_count, root):
    """Page 1: the file header, then a sqlite_master leaf naming metaData.

    keydb.load looks up `metaData`, so this fixture reaches the walk through
    the same call path a key4.db reaches it through. A hand-built RowIterator
    would skip Db.table.
    """
    sql = b"CREATE TABLE metaData(id,item1,item2)"
    # Serial types for the five sqlite_master columns: text 5, text 8, text 8,
    # 1-byte integer, text len(sql). An odd type from 13 is text of
    # (type - 13) / 2 bytes.
    header = bytes([6, 13 + 2 * 5, 13 + 2 * 8, 13 + 2 * 8, 1, 13 + 2 * len(sql)])
    payload = header + b"table" + b"metaData" + b"metaData" + bytes([root]) + sql
    cell = sqlite_varint(len(payload)) + sqlite_varint(1) + payload

    body = bytearray(FANOUT_PAGE_SIZE - 100)
    start = len(body) - len(cell)
    body[start:] = cell
    body[0] = 0x0D  # table leaf
    body[3:5] = struct.pack(">H", 1)
    body[5:7] = struct.pack(">H", 100 + start)
    # The cell pointer array of a leaf starts at page offset 8. A zero here
    # sends the reader to a cell at offset 0, and it returns Corrupt for that
    # cell. This fixture tests the page budget.
    body[8:10] = struct.pack(">H", 100 + start)
    return fanout_file_header(page_count) + bytes(body)


def fanout_interior(child):
    """An interior table page whose every child pointer names `child`."""
    p = bytearray(FANOUT_PAGE_SIZE)
    p[0] = 0x05  # table interior
    p[8:12] = struct.pack(">I", child)  # the rightmost child
    cell = struct.pack(">I", child) + sqlite_varint(1)

    content = FANOUT_PAGE_SIZE
    offsets = []
    for _ in range(FANOUT_CELLS):
        content -= len(cell)
        p[content:content + len(cell)] = cell
        offsets.append(content)

    p[3:5] = struct.pack(">H", FANOUT_CELLS)
    p[5:7] = struct.pack(">H", content)
    for i, offset in enumerate(offsets):
        p[12 + 2 * i:14 + 2 * i] = struct.pack(">H", offset)
    return bytes(p)


def fanout_leaf():
    """One leaf holding one row, so a walk that reaches it returns a row."""
    p = bytearray(FANOUT_PAGE_SIZE)
    payload = bytes([2, 9])  # header length 2, serial 9, the constant 1
    cell = sqlite_varint(len(payload)) + sqlite_varint(1) + payload
    start = FANOUT_PAGE_SIZE - len(cell)
    p[start:] = cell
    p[0] = 0x0D
    p[3:5] = struct.pack(">H", 1)
    p[5:7] = struct.pack(">H", start)
    p[8:10] = struct.pack(">H", start)
    return bytes(p)


def cmd_fanout(args):
    """Writes one database whose b-tree reaches the same pages many times.

    Every interior page names the next page 72 times, once per cell and once
    as the rightmost child. The walk reaches 22 stack frames against
    RowIterator's limit of 24, so the depth check lets it run. The page budget
    in RowIterator.push stops it.

    This function writes the bytes. sqlite3 rejects the result, so
    core/test/oracle.zig leaves it out of its fixture list.
    """
    page_count = 2 + FANOUT_LEVELS
    pages = [fanout_page1(page_count, 2)]
    for i in range(FANOUT_LEVELS):
        pages.append(fanout_interior(3 + i))
    pages.append(fanout_leaf())

    with open(args.fanout_out, "wb") as f:
        f.write(b"".join(pages))


# Each value sits at the boundary where SQLite's record serial type changes.
RANDOM_BOUNDARY_INTS = [
    0, 1, -1,
    -128, 127, -129, 128,
    -32768, 32767, -32769, 32768,
    -8388608, 8388607, -8388609, 8388608,
    -2147483648, 2147483647, -2147483649, 2147483648,
    -140737488355328, 140737488355327,
    -140737488355329, 140737488355328,
    -9223372036854775808, 9223372036854775807,
]

RANDOM_SEED = 0xc3c3_3c3c_c3c3_3c3c


def random_value(rng):
    """One column value chosen at random from the types SQLite stores."""
    kind = rng.choice(["null", "int", "boundary", "float", "text", "blob", "empty_blob"])
    if kind == "null":
        return None
    if kind == "int":
        return rng.randint(-(2**62), 2**62)
    if kind == "boundary":
        return rng.choice(RANDOM_BOUNDARY_INTS)
    if kind == "float":
        return rng.uniform(-1e10, 1e10)
    if kind == "text":
        n = rng.randint(0, 200)
        return "".join(rng.choice("abcdefghijklmnopqrstuvwxyz0123456789") for _ in range(n))
    if kind == "blob":
        n = rng.randint(1, 200)
        return bytes(rng.randint(0, 255) for _ in range(n))
    return b""


def cmd_random(args):
    """Writes one database with random schemas and values.

    Python's sqlite3 writes the file, so the bytes come from SQLite.
    RANDOM_SEED controls every choice, so two runs write the same bytes.
    ALTER TABLE ADD COLUMN after the first batch of inserts leaves rows
    whose records stop before the last declared column.
    """
    if os.path.exists(args.random_out):
        os.remove(args.random_out)

    rng = random.Random(RANDOM_SEED)

    con = sqlite3.connect(args.random_out)
    con.execute("PRAGMA page_size = 4096")
    con.execute("PRAGMA journal_mode = delete")

    affinities = ["TEXT", "NUMERIC", "INTEGER", "REAL", "BLOB", ""]

    tables = []
    for t in range(5):
        ncols = rng.randint(2, 8)
        cols = []
        for c in range(ncols):
            aff = rng.choice(affinities)
            cols.append(f"c{c} {aff}" if aff else f"c{c}")
        name = f"t{t}"
        con.execute(f"CREATE TABLE {name} ({', '.join(cols)})")
        tables.append((name, ncols))

        for _ in range(30):
            values = [random_value(rng) for _ in range(ncols)]
            placeholders = ", ".join("?" for _ in values)
            con.execute(f"INSERT INTO {name} VALUES ({placeholders})", values)

    for name, ncols in tables:
        aff = rng.choice(affinities)
        decl = f"late {aff}" if aff else "late"
        con.execute(f"ALTER TABLE {name} ADD COLUMN {decl}")

        for _ in range(10):
            values = [random_value(rng) for _ in range(ncols + 1)]
            placeholders = ", ".join("?" for _ in values)
            con.execute(f"INSERT INTO {name} VALUES ({placeholders})", values)

    con.commit()
    con.close()


def cmd_synthetic(args):
    """Writes two synthetic key4.db fixtures through Python's sqlite3.

    Each carries the metaData and nssPrivate tables from Firefox's schema.
    The password-check row is copied verbatim from core/testdata/fresh/key4.db,
    so the empty password decrypts it.

    no-password-row/key4.db: metaData exists but holds no row with
    id = 'password'. keydb.load returns MissingPasswordRow.

    no-key-row/key4.db: metaData holds the password-check row. nssPrivate
    is empty. keydb.load returns NoSdrKey.
    """
    src = sqlite3.connect(os.path.join("core", "testdata", "fresh", "key4.db"))
    meta_sql = src.execute(
        "SELECT sql FROM sqlite_master WHERE name = 'metaData'"
    ).fetchone()[0]
    nss_sql = src.execute(
        "SELECT sql FROM sqlite_master WHERE name = 'nssPrivate'"
    ).fetchone()[0]
    pw_row = src.execute(
        "SELECT item1, item2 FROM metaData WHERE id = 'password'"
    ).fetchone()
    src.close()
    global_salt, check_blob = pw_row

    for name, include_pw, include_version in [
        ("no-password-row", False, True),
        ("no-key-row", True, False),
    ]:
        out_dir = os.path.join("core", "testdata", name)
        os.makedirs(out_dir, exist_ok=True)
        out_path = os.path.join(out_dir, "key4.db")
        if os.path.exists(out_path):
            os.remove(out_path)
        con = sqlite3.connect(out_path)
        con.execute("PRAGMA page_size = 32768")
        con.execute("PRAGMA journal_mode = delete")
        con.execute(meta_sql)
        con.execute(nss_sql)
        if include_pw:
            con.execute(
                "INSERT INTO metaData VALUES ('password', ?, ?)",
                (global_salt, check_blob),
            )
        if include_version:
            con.execute("INSERT INTO metaData VALUES ('version', X'01', NULL)")
        con.commit()
        con.close()
        print(f"wrote {out_path}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--firefox", default=DEFAULT_FIREFOX, help="path to the firefox binary")
    parser.add_argument("--profile", help="profile directory to create or reopen")
    parser.add_argument("--out", default="core/testdata/overflow.db",
                        help="output path for the overflow fixture")
    parser.add_argument("--fanout-out", default="core/testdata/fanout.db",
                        help="output path for the fan-out fixture")
    parser.add_argument("--page64k-out", default="core/testdata/page64k.db",
                        help="output path for the 64 KB page fixture")
    parser.add_argument("--reserved-out", default="core/testdata/reserved.db",
                        help="output path for the reserved-bytes fixture")
    parser.add_argument("--random-out", default="core/testdata/random.db",
                        help="output path for the random-schema fixture")
    parser.add_argument("--port", type=int, default=MARIONETTE_PORT)
    sub = parser.add_subparsers(dest="fixture", required=True)
    sub.add_parser("fresh")
    sub.add_parser("primary")
    sub.add_parser("sync-shaped")
    sub.add_parser("migrate")
    sub.add_parser("overflow")
    sub.add_parser("fanout")
    sub.add_parser("page64k")
    sub.add_parser("reserved")
    sub.add_parser("random")
    sub.add_parser("synthetic")

    args = parser.parse_args()

    if args.fixture == "overflow":
        cmd_overflow(args)
        print(f"wrote {args.out}")
        return

    if args.fixture == "fanout":
        cmd_fanout(args)
        print(f"wrote {args.fanout_out}")
        return

    if args.fixture == "page64k":
        cmd_page64k(args)
        print(f"wrote {args.page64k_out}")
        return

    if args.fixture == "reserved":
        cmd_reserved(args)
        print(f"wrote {args.reserved_out}")
        return

    if args.fixture == "random":
        cmd_random(args)
        print(f"wrote {args.random_out}")
        return

    if args.fixture == "synthetic":
        cmd_synthetic(args)
        return

    if args.profile is None:
        parser.error("--profile is required for a Firefox-driven fixture")
    if os.path.exists(os.path.join(args.profile, "key4.db")) and args.fixture != "migrate":
        sys.exit(f"refusing to overwrite an existing profile at {args.profile}")

    {
        "fresh": cmd_fresh,
        "primary": cmd_primary,
        "sync-shaped": cmd_sync_shaped,
        "migrate": cmd_migrate,
    }[args.fixture](args)
    print(f"wrote {args.profile}")


if __name__ == "__main__":
    main()
