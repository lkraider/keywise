//! One-screen TUI. It searches the profile's logins, reveals one password at
//! a time, copies the row under the cursor, and wipes on quit.

const std = @import("std");
const builtin = @import("builtin");
const vaxis = @import("vaxis");
const vxfw = vaxis.vxfw;

fn panicHandler(message: []const u8, return_address: ?usize) noreturn {
    vaxis.recover();
    std.debug.defaultPanic(message, return_address);
}

pub const panic = std.debug.FullPanic(panicHandler);
// vaxis capability messages are diagnostic noise between alternate-screen
// entry and the first frame, where they appear as a startup flash.
pub const std_options: std.Options = .{ .log_level = .warn };

var termination_signal: std.c.sig_atomic_t = 0;
const termination_poll_ms = 50;

fn setTerminationSignal(signal: std.posix.SIG) void {
    const incoming: std.c.sig_atomic_t = @intCast(@intFromEnum(signal));
    const suspended: std.c.sig_atomic_t = @intCast(@intFromEnum(std.posix.SIG.TSTP));
    // A termination request replaces a pending suspend; otherwise the first signal wins.
    var current = @atomicLoad(std.c.sig_atomic_t, &termination_signal, .monotonic);
    while (current == 0 or (current == suspended and incoming != suspended)) {
        current = @cmpxchgWeak(std.c.sig_atomic_t, &termination_signal, current, incoming, .monotonic, .monotonic) orelse return;
    }
}

fn requestTermination(signal: std.posix.SIG) callconv(.c) void {
    setTerminationSignal(signal);
}

fn clearTerminationSignal() void {
    @atomicStore(std.c.sig_atomic_t, &termination_signal, 0, .monotonic);
}

fn clearSuspensionSignal() void {
    const suspended: std.c.sig_atomic_t = @intCast(@intFromEnum(std.posix.SIG.TSTP));
    _ = @cmpxchgStrong(std.c.sig_atomic_t, &termination_signal, suspended, 0, .monotonic, .monotonic);
}

fn terminationSignal() u8 {
    return @intCast(@atomicLoad(std.c.sig_atomic_t, &termination_signal, .monotonic));
}

fn terminationAction() std.posix.Sigaction {
    return .{
        .handler = .{ .handler = requestTermination },
        .mask = if (builtin.os.tag == .macos) 0 else std.posix.sigemptyset(),
        .flags = std.posix.SA.RESTART,
    };
}

const TerminationHandlers = struct {
    hup: std.posix.Sigaction,
    int: std.posix.Sigaction,
    quit: std.posix.Sigaction,
    term: std.posix.Sigaction,
    tstp: std.posix.Sigaction,

    fn install() TerminationHandlers {
        const action = terminationAction();
        var previous: TerminationHandlers = undefined;
        std.posix.sigaction(.HUP, &action, &previous.hup);
        std.posix.sigaction(.INT, &action, &previous.int);
        std.posix.sigaction(.QUIT, &action, &previous.quit);
        std.posix.sigaction(.TERM, &action, &previous.term);
        std.posix.sigaction(.TSTP, &action, &previous.tstp);
        return previous;
    }

    fn suspendProcess(self: TerminationHandlers) !void {
        std.posix.sigaction(.TSTP, &self.tstp, null);
        try std.posix.raise(.TSTP);
        const action = terminationAction();
        std.posix.sigaction(.TSTP, &action, null);
    }

    fn deinit(self: TerminationHandlers) void {
        std.posix.sigaction(.HUP, &self.hup, null);
        std.posix.sigaction(.INT, &self.int, null);
        std.posix.sigaction(.QUIT, &self.quit, null);
        std.posix.sigaction(.TERM, &self.term, null);
        std.posix.sigaction(.TSTP, &self.tstp, null);
    }
};

const core = @import("core");
const profiles = core.profiles;
const store_mod = core.store;
const friendlyMessage = core.messages.friendly;

const cli = @import("args.zig");
const build_options = @import("build_options");

const masked_password = "\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}\u{2022}";
const secret_buffer_len = 8192;
const AccountAction = enum { reveal, copy };
const PendingAccountAction = struct { index: usize, action: AccountAction };

/// A password prompt with its own tiny buffer. Its application-owned copy of
/// the Primary Password is wiped explicitly instead of being left to a generic
/// text field allocator.
const SecretField = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    userdata: ?*anyopaque = null,
    onSubmit: ?*const fn (?*anyopaque, *vxfw.EventContext, []const u8) anyerror!void = null,

    fn init(gpa: std.mem.Allocator) SecretField {
        return .{ .gpa = gpa };
    }

    fn deinit(self: *SecretField) void {
        if (self.buf.capacity > 0) std.crypto.secureZero(u8, self.buf.allocatedSlice());
        self.buf.deinit(self.gpa);
    }

    fn clear(self: *SecretField) void {
        if (self.buf.capacity > 0) std.crypto.secureZero(u8, self.buf.allocatedSlice());
        self.buf.clearRetainingCapacity();
    }

    /// ArrayList may move an allocation while growing it, which would release
    /// the old password bytes without wiping them. Grow explicitly so every
    /// allocation this field relinquishes is scrubbed first.
    fn appendSlice(self: *SecretField, text: []const u8) std.mem.Allocator.Error!void {
        const needed = std.math.add(usize, self.buf.items.len, text.len) catch return error.OutOfMemory;
        if (needed > self.buf.capacity) {
            const grown = self.buf.capacity +| self.buf.capacity / 2 +| 8;
            const new_memory = try self.gpa.alloc(u8, @max(needed, grown));
            const old_len = self.buf.items.len;
            @memcpy(new_memory[0..old_len], self.buf.items);
            if (self.buf.capacity > 0) {
                const old_memory = self.buf.allocatedSlice();
                std.crypto.secureZero(u8, old_memory);
                self.gpa.free(old_memory);
            }
            self.buf.items = new_memory[0..old_len];
            self.buf.capacity = new_memory.len;
        }
        self.buf.appendSliceAssumeCapacity(text);
    }

    fn widget(self: *SecretField) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = typeErasedEventHandler,
            .drawFn = typeErasedDrawFn,
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *SecretField = @ptrCast(@alignCast(ptr));
        return self.handleEvent(ctx, event);
    }

    fn handleEvent(self: *SecretField, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        switch (event) {
            .key_press => |key| {
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.onSubmit) |cb| try cb(self.userdata, ctx, self.buf.items);
                    return ctx.consumeAndRedraw();
                } else if (key.matches(vaxis.Key.backspace, .{})) {
                    if (self.buf.items.len == 0) return ctx.consumeAndRedraw();
                    var iter = vaxis.unicode.graphemeIterator(self.buf.items);
                    var last_start: usize = 0;
                    while (iter.next()) |g| last_start = g.start;
                    std.crypto.secureZero(u8, self.buf.items[last_start..]);
                    self.buf.items.len = last_start;
                    return ctx.consumeAndRedraw();
                } else if (key.text) |text| {
                    try self.appendSlice(text);
                    return ctx.consumeAndRedraw();
                }
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *SecretField = @ptrCast(@alignCast(ptr));
        var n: usize = 0;
        var iter = vaxis.unicode.graphemeIterator(self.buf.items);
        while (iter.next()) |_| n += 1;

        const dots = try ctx.arena.alloc(u8, n * 3);
        var i: usize = 0;
        while (i < n) : (i += 1) @memcpy(dots[i * 3 ..][0..3], "\u{2022}");

        const text: vxfw.Text = .{ .text = dots, .softwrap = false };
        // Text.draw() stamps its own (local, about-to-be-dangling) widget
        // identity onto the surface. Restamp it as this SecretField's, or
        // focus tracking can never find this field in the surface tree.
        var surface = try text.draw(ctx);
        surface.widget = self.widget();
        return surface;
    }
};

/// One line in the list: "kind marker  hostname  username  password". Text
/// lives here so ListView's builder can hand out a stable pointer without an
/// arena of its own. Only `.text` is replaced, in place, when reveal state
/// changes.
const Row = struct {
    text: vxfw.Text = .{ .text = "", .softwrap = false },

    fn widget(self: *Row) vxfw.Widget {
        return self.text.widget();
    }
};

const Model = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    profile_path: []const u8,
    /// `main` reads WAYLAND_DISPLAY and DISPLAY and picks the local helper
    /// chain before constructing the model.
    helpers: []const []const []const u8,

    password_field: SecretField,
    password_error: bool = false,
    /// Set when the profile failed to open with a message the user cannot
    /// act on. The screen then shows that message and accepts `q`. A wrong
    /// Primary Password sets `password_error` and keeps the prompt.
    open_error: bool = false,
    initial_open_pending: bool = true,

    store: ?store_mod.Store = null,
    rows: []Row = &.{},
    row_lines: [][]u8 = &.{}, // owned per-row formatted line, freed on rebuild
    match_indices: std.ArrayList(usize) = .empty,

    search_field: vxfw.TextField,
    list_view: vxfw.ListView = .{ .children = .{ .slice = &.{} } },

    /// Plain letters must stay typeable in the search field, so `y`/`q` and
    /// the other single-key shortcuts only fire in `.normal` mode, when the
    /// list holds focus and the search field does not. `/` enters `.search`.
    /// `enter` or `escape` in the search field returns to `.normal`.
    mode: enum { normal, search } = .normal,

    revealed_index: ?usize = null,
    /// Account credentials require the same action on the same row twice, so
    /// moving between account rows cannot reuse a confirmation.
    pending_account_action: ?PendingAccountAction = null,
    reveal_scratch: [secret_buffer_len]u8 = undefined,
    reveal_out: [secret_buffer_len]u8 = undefined,

    /// Filled by `y` when stdout is a pipe or a file. `main` writes it once,
    /// after app.run returns. Bytes already in the pipe cannot be retracted.
    /// A write per press would send every password of the run, with nothing
    /// between them.
    stdout_out: [secret_buffer_len]u8 = undefined,
    stdout_len: usize = 0,

    status: [160]u8 = undefined,
    status_len: usize = 0,
    status_line: vxfw.Text = .{ .text = "", .softwrap = false },

    fn init(
        gpa: std.mem.Allocator,
        io: std.Io,
        profile_path: []const u8,
        helpers: []const []const []const u8,
    ) !*Model {
        const model = try gpa.create(Model);
        errdefer gpa.destroy(model);
        model.* = .{
            .gpa = gpa,
            .io = io,
            .profile_path = profile_path,
            .helpers = helpers,
            .password_field = SecretField.init(gpa),
            .search_field = .init(gpa),
        };
        model.password_field.userdata = model;
        model.password_field.onSubmit = Model.onPasswordSubmit;
        model.search_field.userdata = model;
        model.search_field.onChange = Model.onSearchChange;
        return model;
    }

    fn deinit(self: *Model) void {
        std.crypto.secureZero(u8, &self.reveal_scratch);
        std.crypto.secureZero(u8, &self.reveal_out);
        std.crypto.secureZero(u8, &self.stdout_out);
        self.password_field.deinit();
        self.search_field.deinit();
        self.match_indices.deinit(self.gpa);
        for (self.row_lines) |line| {
            std.crypto.secureZero(u8, line);
            self.gpa.free(line);
        }
        self.gpa.free(self.row_lines);
        self.gpa.free(self.rows);
        if (self.store) |*s| s.deinit();
        self.gpa.destroy(self);
    }

    fn widget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedEventHandler,
            .drawFn = Model.typeErasedDrawFn,
        };
    }

    fn setStatus(self: *Model, comptime fmt: []const u8, args: anytype) void {
        self.status_len = if (std.fmt.bufPrint(&self.status, fmt, args)) |s| s.len else |_| 0;
        self.status_line.text = self.status[0..self.status_len];
    }

    /// Returns no error. A wrong Primary Password sets `password_error`,
    /// and the prompt asks again. Every other failure sets `open_error` and
    /// a message through `setStatus`.
    fn tryOpen(self: *Model, password: []const u8) void {
        self.store = store_mod.Store.open(self.gpa, self.io, self.profile_path, password) catch |err| {
            switch (err) {
                error.WrongPassword => {
                    if (password.len > 0) self.password_error = true;
                },
                else => {
                    self.open_error = true;
                    self.setStatus("{s}", .{friendlyMessage(err)});
                },
            }
            return;
        };
        self.buildRows() catch |err| {
            self.open_error = true;
            self.setStatus("{s}", .{friendlyMessage(err)});
            return;
        };
        self.setStatus(
            "{d} logins ({d} tombstones skipped) -- / search, enter reveal, y copy, q quit",
            .{ self.store.?.entries.len, self.store.?.tombstones_skipped },
        );
    }

    fn buildRows(self: *Model) !void {
        const s = &self.store.?;
        self.rows = try self.gpa.alloc(Row, s.entries.len);
        for (self.rows) |*r| r.* = .{};
        self.row_lines = try self.gpa.alloc([]u8, s.entries.len);
        for (self.row_lines) |*l| l.* = &.{};
        for (s.entries, 0..) |_, i| try self.refreshRow(i);

        self.list_view = .{
            .children = .{ .builder = .{ .userdata = self, .buildFn = Model.buildListItem } },
            .item_count = @intCast(s.entries.len),
        };
        try self.rebuildMatches("");
    }

    fn refreshRow(self: *Model, index: usize) !void {
        const s = &self.store.?;
        const e = s.entries[index];
        const marker: []const u8 = switch (e.kind) {
            .account_credential => "[account] ",
            .extension => "[extension] ",
            .normal => "",
        };
        const user_display = if (e.legacy_3des) "<3DES, unsupported>" else e.username;
        const password_display: []const u8 = if (self.revealed_index == index)
            try s.reveal(index, &self.reveal_scratch, &self.reveal_out)
        else
            masked_password;

        const new_line = try std.fmt.allocPrint(
            self.gpa,
            "{s}{s}  {s}  {s}",
            .{ marker, e.hostname, user_display, password_display },
        );
        std.crypto.secureZero(u8, self.row_lines[index]);
        self.gpa.free(self.row_lines[index]);
        self.row_lines[index] = new_line;
        self.rows[index].text.text = self.row_lines[index];
    }

    fn wipeRevealBuffers(self: *Model) void {
        std.crypto.secureZero(u8, &self.reveal_scratch);
        std.crypto.secureZero(u8, &self.reveal_out);
    }

    fn hideRevealed(self: *Model) void {
        const idx = self.revealed_index orelse return;
        self.revealed_index = null;
        self.pending_account_action = null;
        self.wipeRevealBuffers();
        self.refreshRow(idx) catch {
            std.crypto.secureZero(u8, self.row_lines[idx]);
            self.rows[idx].text.text = "";
        };
    }

    fn revealAt(self: *Model, index: usize) void {
        defer self.wipeRevealBuffers();
        if (self.revealed_index) |prev| {
            if (prev != index) self.hideRevealed();
        }
        self.revealed_index = index;
        self.refreshRow(index) catch |err| {
            self.revealed_index = null;
            self.pending_account_action = null;
            self.setStatus("reveal failed: {s}", .{friendlyMessage(err)});
        };
    }

    fn scrubForSuspend(self: *Model) void {
        self.hideRevealed();
        self.password_field.clear();
        self.wipeRevealBuffers();
        std.crypto.secureZero(u8, &self.stdout_out);
        self.stdout_len = 0;
        self.pending_account_action = null;
    }

    fn confirmAccountAction(self: *Model, index: usize, action: AccountAction) bool {
        if (self.pending_account_action) |pending| {
            if (pending.index == index and pending.action == action) {
                self.pending_account_action = null;
                return true;
            }
        }
        self.pending_account_action = .{ .index = index, .action = action };
        return false;
    }

    fn selectedEntryIndex(self: *Model) ?usize {
        if (self.match_indices.items.len == 0) return null;
        const cursor = @min(self.list_view.cursor, self.match_indices.items.len - 1);
        return self.match_indices.items[cursor];
    }

    fn rebuildMatches(self: *Model, query: []const u8) !void {
        const s = &self.store.?;
        try self.match_indices.resize(self.gpa, s.entries.len);
        const count = s.search(query, self.match_indices.items);
        self.match_indices.items.len = @min(count, s.entries.len);

        self.list_view.item_count = @intCast(self.match_indices.items.len);
        self.list_view.cursor = 0;
        self.list_view.scroll = .{};
    }

    /// Wraps ListView so unrelated input can cancel a pending account action
    /// before ListView consumes it.
    fn listWidget(self: *Model) vxfw.Widget {
        return .{
            .userdata = self,
            .eventHandler = Model.typeErasedListEventHandler,
            .drawFn = Model.typeErasedListDrawFn,
        };
    }

    fn typeErasedListEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .key_press => |key| {
                if (!key.matches(vaxis.Key.enter, .{}) and !key.matches('y', .{})) {
                    self.pending_account_action = null;
                }
            },
            .mouse, .focus_out => self.pending_account_action = null,
            else => {},
        }
        return self.list_view.handleEvent(ctx, event);
    }

    fn typeErasedListDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        var surface = try self.list_view.draw(ctx);
        surface.widget = self.listWidget();
        return surface;
    }

    fn buildListItem(ptr: *const anyopaque, idx: usize, _: usize) ?vxfw.Widget {
        const self: *const Model = @ptrCast(@alignCast(ptr));
        if (idx >= self.match_indices.items.len) return null;
        const entry_index = self.match_indices.items[idx];
        return @constCast(&self.rows[entry_index]).widget();
    }

    fn onSearchChange(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        self.pending_account_action = null;
        if (self.revealed_index != null) self.hideRevealed();
        try self.rebuildMatches(str);
        ctx.consumeAndRedraw();
    }

    fn onPasswordSubmit(maybe_ptr: ?*anyopaque, ctx: *vxfw.EventContext, str: []const u8) anyerror!void {
        const ptr = maybe_ptr orelse return;
        const self: *Model = @ptrCast(@alignCast(ptr));
        self.password_error = false;
        self.tryOpen(str);
        self.password_field.clear();
        try ctx.requestFocus(self.focusForMode());
        ctx.consumeAndRedraw();
    }

    /// Copies the row under the cursor. The row stays masked. The plaintext
    /// buffers are wiped on every return after the account confirmation.
    fn copySelected(self: *Model) void {
        const idx = self.selectedEntryIndex() orelse {
            self.pending_account_action = null;
            return;
        };
        const s = &self.store.?;
        if (s.entries[idx].kind == .account_credential and !self.confirmAccountAction(idx, .copy)) {
            self.setStatus("this copies Firefox Sync account credentials to the clipboard -- press y again to confirm", .{});
            return;
        }
        self.pending_account_action = null;
        defer self.wipeRevealBuffers();
        const plain = s.reveal(idx, &self.reveal_scratch, &self.reveal_out) catch |err| {
            self.setStatus("copy failed: {s}", .{friendlyMessage(err)});
            return;
        };
        // OSC 52 is always attempted before the local helper. A terminal can
        // reject or ignore it without acknowledging the clipboard write.
        copyOsc52(self.io, plain) catch {};
        copyViaHelper(self.io, self.helpers, plain);

        // A terminal on stdout puts the password into scrollback, into a tmux
        // buffer and into `script` output.
        if (!(std.Io.File.stdout().isTty(self.io) catch true)) {
            std.debug.assert(plain.len <= self.stdout_out.len);
            std.crypto.secureZero(u8, &self.stdout_out);
            @memcpy(self.stdout_out[0..plain.len], plain);
            self.stdout_len = plain.len;
        }

        self.setStatus("copied", .{});
    }

    fn focusForMode(self: *Model) vxfw.Widget {
        // In the open_error screen nothing but Model itself is drawn.
        // Requesting focus on password_field there would ask the focus
        // handler to find a widget that is not in the surface tree at all.
        if (self.open_error) return self.widget();
        if (self.store == null) return self.password_field.widget();
        return switch (self.mode) {
            .normal => self.listWidget(),
            .search => self.search_field.widget(),
        };
    }

    fn typeErasedEventHandler(ptr: *anyopaque, ctx: *vxfw.EventContext, event: vxfw.Event) anyerror!void {
        const self: *Model = @ptrCast(@alignCast(ptr));
        switch (event) {
            .init => {
                // Draw a complete loading frame before opening SQLite and
                // deriving keys, which can take long enough to expose the old
                // shell or an empty alternate screen as a visible flash.
                ctx.redraw = true;
                return ctx.tick(0, self.widget());
            },
            .focus_in => {
                ctx.redraw = true;
                if (!self.initial_open_pending) return ctx.requestFocus(self.focusForMode());
            },
            .tick => {
                const signal = terminationSignal();
                if (signal != 0) {
                    if (signal == @intFromEnum(std.posix.SIG.TSTP)) self.scrubForSuspend();
                    ctx.quit = true;
                    return;
                }
                if (self.initial_open_pending) {
                    self.initial_open_pending = false;
                    self.tryOpen("");
                    try ctx.requestFocus(self.focusForMode());
                    ctx.redraw = true;
                }
                return ctx.tick(termination_poll_ms, self.widget());
            },
            .key_press => |key| {
                if (key.matches('c', .{ .ctrl = true })) {
                    self.pending_account_action = null;
                    ctx.quit = true;
                    return;
                }
                if (key.matches('z', .{ .ctrl = true })) {
                    setTerminationSignal(.TSTP);
                    self.scrubForSuspend();
                    ctx.quit = true;
                    return;
                }
                if (self.store == null) {
                    if (self.open_error and key.matches('q', .{})) ctx.quit = true;
                    return; // otherwise routed to password_field by focus
                }

                if (self.mode == .search) {
                    if (key.matches(vaxis.Key.enter, .{}) or key.matches(vaxis.Key.escape, .{})) {
                        self.mode = .normal;
                        try ctx.requestFocus(self.listWidget());
                        return ctx.consumeAndRedraw();
                    }
                    return; // let the search field handle everything else
                }

                // .normal mode: the list wrapper holds focus, so plain letters
                // are free to use as shortcuts.
                if (key.matches('/', .{})) {
                    self.pending_account_action = null;
                    self.mode = .search;
                    try ctx.requestFocus(self.search_field.widget());
                    return ctx.consumeAndRedraw();
                }
                if (key.matches('q', .{})) {
                    self.pending_account_action = null;
                    ctx.quit = true;
                    return;
                }
                if (key.matches(vaxis.Key.enter, .{})) {
                    if (self.selectedEntryIndex()) |idx| {
                        const kind = self.store.?.entries[idx].kind;
                        if (kind == .account_credential and
                            self.revealed_index != idx and
                            !self.confirmAccountAction(idx, .reveal))
                        {
                            self.setStatus("this reveals Firefox Sync account credentials -- press enter again to confirm", .{});
                            return ctx.consumeAndRedraw();
                        }
                        self.pending_account_action = null;
                        if (self.revealed_index == idx) {
                            self.hideRevealed();
                        } else {
                            self.revealAt(idx);
                        }
                        return ctx.consumeAndRedraw();
                    }
                    self.pending_account_action = null;
                    return;
                }
                if (key.matches('y', .{})) {
                    self.copySelected();
                    return ctx.consumeAndRedraw();
                }
                // A confirmation applies only to an immediately repeated
                // action. Navigation or any unrelated key cancels it.
                self.pending_account_action = null;
            },
            else => {},
        }
    }

    fn typeErasedDrawFn(ptr: *anyopaque, ctx: vxfw.DrawContext) std.mem.Allocator.Error!vxfw.Surface {
        const self: *Model = @ptrCast(@alignCast(ptr));
        const max = ctx.max.size();

        if (self.initial_open_pending) {
            const loading: vxfw.Text = .{ .text = "Opening Firefox profile…", .softwrap = false };
            return self.composite(ctx, max, &.{.{
                .origin = .{ .row = 0, .col = 0 },
                .surface = try loading.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
            }});
        }
        if (self.open_error) {
            return self.drawOpenError(ctx, max);
        }
        if (self.store == null) {
            return self.drawPasswordPrompt(ctx, max);
        }

        const list_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.listWidget().draw(ctx.withConstraints(
                ctx.min,
                .{ .width = max.width, .height = max.height -| 3 },
            )),
        };
        const search_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 2 },
            .surface = try self.search_field.draw(ctx.withConstraints(ctx.min, .{ .width = max.width -| 2, .height = 1 })),
        };
        const empty: vxfw.Text = .{
            .text = if (self.store.?.entries.len == 0)
                "No saved logins in this Firefox profile."
            else if (self.match_indices.items.len == 0)
                "No logins match this search."
            else
                "",
            .softwrap = false,
        };
        const empty_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try empty.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };
        const prompt: vxfw.Text = .{ .text = "/", .softwrap = false };
        const prompt_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try prompt.draw(ctx.withConstraints(ctx.min, .{ .width = 2, .height = 1 })),
        };
        const status_surface: vxfw.SubSurface = .{
            .origin = .{ .row = max.height -| 1, .col = 0 },
            .surface = try self.status_line.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };

        return self.composite(ctx, max, &.{ list_surface, empty_surface, search_surface, prompt_surface, status_surface });
    }

    fn drawOpenError(self: *Model, ctx: vxfw.DrawContext, max: vxfw.Size) !vxfw.Surface {
        const label: vxfw.Text = .{ .text = self.status_line.text, .softwrap = true };
        const label_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try label.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 3 })),
        };
        const hint: vxfw.Text = .{ .text = "press q to quit", .softwrap = false };
        const hint_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 4, .col = 0 },
            .surface = try hint.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };
        return self.composite(ctx, max, &.{ label_surface, hint_surface });
    }

    fn drawPasswordPrompt(self: *Model, ctx: vxfw.DrawContext, max: vxfw.Size) !vxfw.Surface {
        const label: vxfw.Text = .{
            .text = if (self.password_error)
                "Wrong Primary Password. Try again:"
            else
                "This profile needs its Primary Password:",
            .softwrap = false,
        };
        const label_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 0, .col = 0 },
            .surface = try label.draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };
        const field_surface: vxfw.SubSurface = .{
            .origin = .{ .row = 2, .col = 0 },
            .surface = try self.password_field.widget().draw(ctx.withConstraints(ctx.min, .{ .width = max.width, .height = 1 })),
        };
        return self.composite(ctx, max, &.{ label_surface, field_surface });
    }

    /// Every screen is one Surface over already-drawn children. The draw
    /// paths differ only in the children they pass here.
    fn composite(self: *Model, ctx: vxfw.DrawContext, size: vxfw.Size, children: []const vxfw.SubSurface) !vxfw.Surface {
        return .{
            .size = size,
            .widget = self.widget(),
            .buffer = &.{},
            .children = try ctx.arena.dupe(vxfw.SubSurface, children),
        };
    }
};

/// wl-copy connects to a Wayland compositor. xclip and xsel need $DISPLAY.
/// Both reach a Wayland clipboard through XWayland.
const wayland_helpers: []const []const []const u8 = &.{
    &.{"wl-copy"},
    &.{ "xclip", "-selection", "clipboard" },
    &.{ "xsel", "--clipboard", "--input" },
};
const x11_helpers: []const []const []const u8 = wayland_helpers[1..];
const macos_helpers: []const []const []const u8 = &.{&.{"pbcopy"}};

/// Writes OSC 52 directly so plaintext and base64 copies stay in fixed buffers
/// that can be wiped, rather than in the framework command allocator.
fn copyOsc52(io: std.Io, text: []const u8) !void {
    const encoder = std.base64.standard.Encoder;
    var encoded: [encoder.calcSize(secret_buffer_len)]u8 = undefined;
    defer std.crypto.secureZero(u8, &encoded);
    if (text.len > secret_buffer_len) return error.SecretTooLarge;
    const b64 = encoder.encode(encoded[0..encoder.calcSize(text.len)], text);

    const tty = try std.Io.Dir.cwd().openFile(io, "/dev/tty", .{
        .mode = .write_only,
        .allow_directory = false,
    });
    defer tty.close(io);

    var buffer: [4096]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    var writer = tty.writer(io, &buffer);
    try writer.interface.print("\x1b]52;c;{s}\x1b\\", .{b64});
    try writer.interface.flush();
}

/// Best-effort local clipboard write after the unconditional OSC 52 copy.
fn copyViaHelper(io: std.Io, helpers: []const []const []const u8, text: []const u8) void {
    for (helpers) |argv| {
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch continue;
        var wrote = false;
        if (child.stdin) |stdin| {
            var buf: [4096]u8 = undefined;
            defer std.crypto.secureZero(u8, &buf);
            var writer = stdin.writer(io, &buf);
            wrote = write: {
                writer.interface.writeAll(text) catch break :write false;
                writer.interface.flush() catch break :write false;
                break :write true;
            };
            stdin.close(io);
            // wait()'s cleanup closes child.stdin itself if non-null. Closing
            // it above and leaving this set would double-close the fd.
            child.stdin = null;
        }
        const term = child.wait(io) catch continue;
        if (wrote and term == .exited and term.exited == 0) return;
    }
}

fn readProfilesIni(io: std.Io, gpa: std.mem.Allocator, firefox_dir: []const u8) ![]u8 {
    const ini_path = try std.fs.path.join(gpa, &.{ firefox_dir, "profiles.ini" });
    defer gpa.free(ini_path);
    return std.Io.Dir.cwd().readFileAlloc(io, ini_path, gpa, .unlimited);
}

fn resolveDefaultProfile(io: std.Io, gpa: std.mem.Allocator, firefox_dir: []const u8) ![]u8 {
    const ini = try readProfilesIni(io, gpa, firefox_dir);
    defer gpa.free(ini);
    return profiles.resolveDefault(gpa, firefox_dir, ini);
}

/// One profile per line, name then path, so a shell can cut either field.
/// The root goes to stderr. `cut -f1` over stdout keeps working.
fn listProfiles(io: std.Io, gpa: std.mem.Allocator, firefox_dir: []const u8) !void {
    var root_buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&root_buf, "{s}\n", .{firefox_dir})) |line| {
        write(io, .stderr(), line) catch {};
    } else |_| {}

    const ini = try readProfilesIni(io, gpa, firefox_dir);
    defer gpa.free(ini);
    const list = try profiles.enumerate(gpa, firefox_dir, ini);
    defer {
        for (list) |p| {
            gpa.free(p.name);
            gpa.free(p.path);
        }
        gpa.free(list);
    }

    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &buf);
    for (list) |p| try writer.interface.print("{s}\t{s}\n", .{ p.name, p.path });
    try writer.interface.flush();
}

/// The first root under $HOME holding a profiles.ini. Null means this
/// function already wrote the reason to stderr. `main` then returns 1.
///
/// Call this only where a profiles.ini has to be read. Calling it before
/// `--profile` is read makes a populated root a precondition for every run.
fn resolveFirefoxDir(io: std.Io, gpa: std.mem.Allocator, home: ?[]const u8) !?[]u8 {
    const dir = home orelse {
        try write(io, .stderr(), "HOME is not set\n");
        return null;
    };
    return profiles.resolveDir(io, gpa, dir) catch |err| switch (err) {
        error.OutOfMemory => return err,
        error.NoFirefoxDir => {
            try reportNoFirefoxDir(io, gpa, dir);
            return null;
        },
    };
}

fn reportNoFirefoxDir(io: std.Io, gpa: std.mem.Allocator, home: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var writer = std.Io.File.stderr().writer(io, &buf);
    try writer.interface.writeAll("keywise: found no profiles.ini under\n");
    for (profiles.home_relative_dirs) |rel| {
        const dir = try std.fs.path.join(gpa, &.{ home, rel });
        defer gpa.free(dir);
        try writer.interface.print("  {s}\n", .{dir});
    }
    try writer.interface.flush();
}

fn write(io: std.Io, file: std.Io.File, text: []const u8) !void {
    var buf: [512]u8 = undefined;
    defer std.crypto.secureZero(u8, &buf);
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(text);
    try writer.interface.flush();
}

/// Collects the arguments after the program name. Each slice points into
/// the iterator's own storage. That storage lives as long as the process.
fn collectArgs(gpa: std.mem.Allocator, argv: std.process.Args) ![]const []const u8 {
    var it: std.process.Args.Iterator = .init(argv);
    _ = it.skip();
    var list: std.ArrayList([]const u8) = .empty;
    errdefer list.deinit(gpa);
    while (it.next()) |arg| try list.append(gpa, arg);
    return list.toOwnedSlice(gpa);
}

fn runTerminalApp(
    io: std.Io,
    gpa: std.mem.Allocator,
    env_map: *std.process.Environ.Map,
    model: *Model,
) !void {
    var buffer: [1024]u8 = undefined;
    var app: vxfw.App = try .init(io, gpa, env_map, &buffer);
    defer app.deinit();
    // Exiting on a key press can leave its separately reported release event
    // queued for the restored shell, where the CSI-u bytes appear as garbage.
    app.vx.opts.kitty_keyboard_flags.report_events = false;

    const reported_size = app.tty.getWinsize() catch return error.UnusableTerminalSize;
    const cols: u16 = if (reported_size.cols == 0) 80 else reported_size.cols;
    const rows: u16 = if (reported_size.rows == 0) 24 else reported_size.rows;
    if (reported_size.cols == 0 or reported_size.rows == 0) {
        var terminal_size: std.posix.winsize = .{
            .row = rows,
            .col = cols,
            .xpixel = reported_size.x_pixel,
            .ypixel = reported_size.y_pixel,
        };
        // libc's ioctl request is signed on Darwin and the BSDs; Linux's is u32.
        // Zig 0.16 also omits Darwin's _IOW('t', 103, winsize) constant.
        const set_winsize = if (builtin.os.tag == .linux)
            std.posix.T.IOCSWINSZ
        else if (builtin.os.tag == .macos)
            @as(c_int, @bitCast(@as(u32, 0x80087467)))
        else
            @as(c_int, @bitCast(@as(u32, @intCast(std.posix.T.IOCSWINSZ))));
        const ioctl_result = std.posix.system.ioctl(
            app.tty.fd.handle,
            set_winsize,
            @intFromPtr(&terminal_size),
        );
        if (std.posix.errno(ioctl_result) != .SUCCESS) return error.UnusableTerminalSize;
    }
    try app.vx.resize(gpa, app.tty.writer(), .{
        .cols = cols,
        .rows = rows,
        .x_pixel = reported_size.x_pixel,
        .y_pixel = reported_size.y_pixel,
    });

    try app.run(model.widget(), .{});
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;

    const argv = try collectArgs(gpa, init.minimal.args);
    defer gpa.free(argv);
    const options = cli.parse(argv) catch |err| {
        const message = switch (err) {
            error.MissingValue => "keywise: --profile needs a path\n",
            error.UnknownFlag => "keywise: unrecognized argument, see keywise --help\n",
        };
        try write(io, .stderr(), message);
        return 2;
    };
    if (options.help) {
        try write(io, .stdout(), cli.usage);
        return 0;
    }
    if (options.version) {
        try write(io, .stdout(), "keywise " ++ build_options.version ++ "\n");
        return 0;
    }

    const home = init.environ_map.get("HOME");

    if (options.list_profiles) {
        const firefox_dir = try resolveFirefoxDir(io, gpa, home) orelse return 1;
        defer gpa.free(firefox_dir);
        try listProfiles(io, gpa, firefox_dir);
        return 0;
    }

    // Duped so one `free` covers both this and resolveDefault's allocation.
    const profile = if (options.profile_path) |path|
        try gpa.dupe(u8, path)
    else default: {
        const firefox_dir = try resolveFirefoxDir(io, gpa, home) orelse return 1;
        defer gpa.free(firefox_dir);
        break :default try resolveDefaultProfile(io, gpa, firefox_dir);
    };
    defer gpa.free(profile);

    const helpers: []const []const []const u8 = if (builtin.os.tag == .macos)
        macos_helpers
    else if (init.environ_map.get("WAYLAND_DISPLAY") != null)
        wayland_helpers
    else if (init.environ_map.get("DISPLAY") != null)
        x11_helpers
    else
        &.{};

    clearTerminationSignal();
    const handlers = TerminationHandlers.install();
    defer handlers.deinit();

    const model = try Model.init(gpa, io, profile, helpers);
    defer model.deinit();

    var signal: u8 = 0;
    while (true) {
        runTerminalApp(io, gpa, init.environ_map, model) catch |err| switch (err) {
            error.UnusableTerminalSize => {
                try write(io, .stderr(), "keywise: terminal reported an unusable size\n");
                return 1;
            },
            else => return err,
        };
        signal = terminationSignal();
        if (signal != @intFromEnum(std.posix.SIG.TSTP)) break;

        // App.deinit has restored termios and the primary screen. Clear only
        // the handled SIGTSTP; compare-exchange preserves a termination request
        // that races with this transition.
        clearSuspensionSignal();
        signal = terminationSignal();
        if (signal != 0) break;
        try handlers.suspendProcess();
        signal = terminationSignal();
        if (signal != 0) break;
    }

    if (signal != 0) return 128 +| signal;

    // std.Io.Threaded installs a SIGPIPE handler (Threaded.zig:1661), so a
    // reader that exited first gives error.BrokenPipe here. A `try`
    // would make `keywise | head -c 5` exit non-zero with a trace.
    if (model.stdout_len > 0) {
        write(io, .stdout(), model.stdout_out[0..model.stdout_len]) catch {};
    }
    return 0;
}
