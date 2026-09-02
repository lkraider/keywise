//! The Win32 front end. It owns the window, the controls, the timers and the
//! dialogs. model.zig holds every rule about what a row shows and what an
//! activation means.
//!
//! The macOS app defines the feature set. Windows mechanisms deliver it. The
//! `Profile` menu carries profile switching, a context menu carries the row
//! actions, and a modal `MessageBoxW` carries the account-row confirmation.

const std = @import("std");
const core = @import("core");
const cli = @import("args");

const w = @import("win32.zig");
const ids = @import("ids.zig");
const clipboard = @import("clipboard.zig");
const crash = @import("crash.zig");
const model_mod = @import("model.zig");
const text_mod = @import("text.zig");

/// `win_exe.subsystem = .Windows` in build.zig sends Zig's default panic text
/// to a stderr with no console. crash.zig shows it in a `MessageBoxW` instead.
/// The compiler reads this declaration from the root source file alone, and
/// build.zig roots model.zig, ids.zig and text.zig as their own test binaries,
/// so it reaches the Windows exe and nothing else.
pub const panic = std.debug.FullPanic(crash.report);

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("KeywiseWindow");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("Keywise");
const search_cue = std.unicode.utf8ToUtf16LeStringLiteral("Search logins");
const masked = std.unicode.utf8ToUtf16LeStringLiteral(model_mod.masked_password);

const edit_class = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
const dark_list_theme = std.unicode.utf8ToUtf16LeStringLiteral("DarkMode_Explorer");

/// A revealed password masks itself after this long, and a copied one leaves
/// the clipboard after the same wait. macOS uses 30 seconds too.
const secret_timeout_ms: w.UINT = 30_000;

const search_max = 256;
/// logins.json holds the password as an SDR blob, and store.reveal decrypts
/// into a buffer this size in every front end.
const secret_max = 8192;

const App = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    instance: w.HINSTANCE,
    model: model_mod.Model,
    clip: clipboard.Writer = .{},

    hwnd: ?w.HWND = null,
    search: ?w.HWND = null,
    list: ?w.HWND = null,
    status: ?w.HWND = null,
    font: ?w.HFONT = null,

    profiles: []core.profiles.Profile = &.{},
    selected: usize = 0,

    /// UTF-16 copies of every hostname and username, made once per profile
    /// open. LVN_GETDISPINFOW hands the list a pointer, so these outlive the
    /// callback.
    text: std.heap.ArenaAllocator,
    hostnames: [][:0]u16 = &.{},
    usernames: [][:0]u16 = &.{},
    /// The password column's text for the row the list is asking about.
    row_buf: [secret_max]u16 = undefined,
};

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.gpa;
    const io = init.io;

    const argv = try collectArgs(gpa, init.minimal.args);
    defer freeArgs(gpa, argv);
    const options = cli.parse(argv) catch {
        reportFatal("Usage: Keywise.exe [--profile <path>]");
        return 2;
    };

    const instance = w.GetModuleHandleW(null) orelse return 1;

    var app: App = .{
        .gpa = gpa,
        .io = io,
        .instance = instance,
        .model = .init(gpa, io),
        .text = .init(gpa),
    };
    defer app.model.deinit();
    defer app.text.deinit();

    if (options.profile_path) |path| {
        app.profiles = try gpa.dupe(core.profiles.Profile, &.{.{
            .name = try gpa.dupe(u8, path),
            .path = try gpa.dupe(u8, path),
        }});
    } else if (init.environ_map.get("APPDATA")) |appdata| {
        app.profiles = readProfiles(gpa, io, appdata) catch &.{};
    }
    defer freeProfiles(gpa, app.profiles);

    const picked = app.model.openFirst(app.profiles) orelse {
        reportFatal(app.model.status());
        return 1;
    };
    app.selected = picked;

    const icc: w.INITCOMMONCONTROLSEX = .{
        .dwSize = @sizeOf(w.INITCOMMONCONTROLSEX),
        .dwICC = w.ICC_LISTVIEW_CLASSES | w.ICC_BAR_CLASSES,
    };
    _ = w.InitCommonControlsEx(&icc);

    const class: w.WNDCLASSEXW = .{
        .cbSize = @sizeOf(w.WNDCLASSEXW),
        .style = w.CS_HREDRAW | w.CS_VREDRAW,
        .lpfnWndProc = windowProc,
        .hInstance = instance,
        .hIcon = w.LoadIconW(instance, w.intResource(ids.IDI_APP)),
        .hIconSm = w.LoadIconW(instance, w.intResource(ids.IDI_APP)),
        .hCursor = w.LoadCursorW(null, w.intResource(w.IDC_ARROW)),
        .hbrBackground = w.GetSysColorBrush(w.COLOR_BTNFACE),
        .lpszClassName = class_name,
    };
    if (w.RegisterClassExW(&class) == 0) return 1;

    const hwnd = w.CreateWindowExW(
        0,
        class_name,
        window_title,
        w.WS_OVERLAPPEDWINDOW | w.WS_CLIPCHILDREN,
        w.CW_USEDEFAULT,
        w.CW_USEDEFAULT,
        900,
        600,
        null,
        null,
        instance,
        &app,
    ) orelse return 1;

    if (app.model.needs_password) promptPassword(&app, hwnd);

    _ = w.ShowWindow(hwnd, w.SW_SHOWNORMAL);
    _ = w.UpdateWindow(hwnd);

    const accel = w.LoadAcceleratorsW(instance, w.intResource(ids.IDR_MAINACCEL));

    var msg: w.MSG = undefined;
    while (w.GetMessageW(&msg, null, 0, 0) > 0) {
        if (accel) |table| {
            if (w.TranslateAcceleratorW(hwnd, table, &msg) != 0) continue;
        }
        // Tab moves the focus between the search box and the list. Both
        // children carry WS_TABSTOP, and IsDialogMessageW reads that bit.
        // The accelerator table above claims Enter and Escape first.
        //
        // IsDialogMessageW consumes WM_SYSKEYDOWN, WM_SYSKEYUP and WM_SYSCHAR
        // while a modeless dialog is active, and the frame's menu mnemonics
        // then stop working. Microsoft's reference names TAB, the arrow keys,
        // WM_GETDLGCODE, DM_GETDEFID and DM_SETDEFID, and no Alt handling.
        // This app passes the frame window itself, and win/app.rc puts `&`
        // only in menu items, so the three lines below change nothing today.
        const alt = msg.message == w.WM_SYSKEYDOWN or msg.message == w.WM_SYSKEYUP or
            msg.message == w.WM_SYSCHAR;
        if (!alt and w.IsDialogMessageW(hwnd, &msg) != 0) continue;
        _ = w.TranslateMessage(&msg);
        _ = w.DispatchMessageW(&msg);
    }
    return 0;
}

/// Each slice is duped, because the Windows iterator frees its own storage in
/// `deinit`.
fn collectArgs(gpa: std.mem.Allocator, argv: std.process.Args) ![]const []const u8 {
    var it: std.process.Args.Iterator = try .initAllocator(argv, gpa);
    defer it.deinit();
    _ = it.skip();

    var list: std.ArrayList([]const u8) = .empty;
    errdefer {
        for (list.items) |a| gpa.free(a);
        list.deinit(gpa);
    }
    while (it.next()) |arg| try list.append(gpa, try gpa.dupe(u8, arg));
    return list.toOwnedSlice(gpa);
}

fn freeArgs(gpa: std.mem.Allocator, argv: []const []const u8) void {
    for (argv) |a| gpa.free(a);
    gpa.free(argv);
}

/// Firefox keeps profiles.ini under %APPDATA%\Mozilla\Firefox on Windows.
fn readProfiles(gpa: std.mem.Allocator, io: std.Io, appdata: []const u8) ![]core.profiles.Profile {
    const firefox_dir = try std.fs.path.join(gpa, &.{ appdata, "Mozilla", "Firefox" });
    defer gpa.free(firefox_dir);

    const ini_path = try std.fs.path.join(gpa, &.{ firefox_dir, "profiles.ini" });
    defer gpa.free(ini_path);

    const ini = try std.Io.Dir.cwd().readFileAlloc(io, ini_path, gpa, .unlimited);
    defer gpa.free(ini);

    return core.profiles.enumerate(gpa, firefox_dir, ini);
}

fn freeProfiles(gpa: std.mem.Allocator, list: []core.profiles.Profile) void {
    for (list) |p| {
        gpa.free(p.name);
        gpa.free(p.path);
    }
    gpa.free(list);
}

fn appOf(hwnd: w.HWND) ?*App {
    const raw = w.GetWindowLongPtrW(hwnd, w.GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn windowProc(hwnd: w.HWND, message: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.LRESULT {
    switch (message) {
        w.WM_CREATE => {
            const create: *const w.CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            const app: *App = @ptrCast(@alignCast(create.lpCreateParams.?));
            app.hwnd = hwnd;
            crash.model = &app.model;
            _ = w.SetWindowLongPtrW(hwnd, w.GWLP_USERDATA, @bitCast(@intFromPtr(app)));
            createChildren(app, hwnd) catch return -1;
            return 0;
        },
        w.WM_SIZE => {
            if (appOf(hwnd)) |app| layout(app, hwnd);
            return 0;
        },
        // The frame holds the focus at startup, and a click on the frame
        // returns it here. Typing belongs in the search box.
        w.WM_SETFOCUS => {
            if (appOf(hwnd)) |app| {
                if (app.search) |search| _ = w.SetFocus(search);
            }
            return 0;
        },
        w.WM_COMMAND => {
            if (appOf(hwnd)) |app| return onCommand(app, hwnd, wparam);
            return 0;
        },
        w.WM_NOTIFY => {
            if (appOf(hwnd)) |app| return onNotify(app, lparam);
            return 0;
        },
        w.WM_TIMER => {
            if (appOf(hwnd)) |app| onTimer(app, hwnd, wparam);
            return 0;
        },
        w.WM_DPICHANGED => {
            if (appOf(hwnd)) |app| {
                const suggested: *const w.RECT = @ptrFromInt(@as(usize, @bitCast(lparam)));
                _ = w.SetWindowPos(
                    hwnd,
                    null,
                    suggested.left,
                    suggested.top,
                    suggested.right - suggested.left,
                    suggested.bottom - suggested.top,
                    w.SWP_NOZORDER | w.SWP_NOACTIVATE,
                );
                applyFont(app, hwnd);
            }
            return 0;
        },
        w.WM_DESTROY => {
            if (appOf(hwnd)) |app| {
                app.model.hideRevealed();
                app.clip.clearIfUnchanged(hwnd);
                if (app.font) |f| _ = w.DeleteObject(@ptrCast(f));
            }
            w.PostQuitMessage(0);
            return 0;
        },
        else => {},
    }
    return w.DefWindowProcW(hwnd, message, wparam, lparam);
}

fn createChildren(app: *App, hwnd: w.HWND) !void {
    app.search = w.CreateWindowExW(
        w.WS_EX_CLIENTEDGE,
        edit_class,
        null,
        w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.ES_AUTOHSCROLL,
        0,
        0,
        0,
        0,
        hwnd,
        @ptrFromInt(ids.IDC_SEARCH),
        app.instance,
        null,
    ) orelse return error.CreateFailed;
    _ = w.SendMessageW(app.search.?, w.EM_SETCUEBANNER, 1, @bitCast(@intFromPtr(search_cue)));

    // LVS_OWNERDATA asks for a row's text through LVN_GETDISPINFOW, so 1701
    // entries cost no per-row insert.
    app.list = w.CreateWindowExW(
        0,
        w.WC_LISTVIEWW,
        null,
        w.WS_CHILD | w.WS_VISIBLE | w.WS_TABSTOP | w.WS_BORDER |
            w.LVS_REPORT | w.LVS_OWNERDATA | w.LVS_SINGLESEL | w.LVS_SHOWSELALWAYS,
        0,
        0,
        0,
        0,
        hwnd,
        @ptrFromInt(ids.IDC_LIST),
        app.instance,
        null,
    ) orelse return error.CreateFailed;
    _ = w.SendMessageW(
        app.list.?,
        w.LVM_SETEXTENDEDLISTVIEWSTYLE,
        0,
        w.LVS_EX_FULLROWSELECT | w.LVS_EX_DOUBLEBUFFER,
    );
    try addColumns(app.list.?);

    app.status = w.CreateWindowExW(
        0,
        w.STATUSCLASSNAMEW,
        null,
        w.WS_CHILD | w.WS_VISIBLE | w.SBARS_SIZEGRIP,
        0,
        0,
        0,
        0,
        hwnd,
        @ptrFromInt(ids.IDC_STATUS),
        app.instance,
        null,
    ) orelse return error.CreateFailed;

    if (w.LoadMenuW(app.instance, w.intResource(ids.IDR_MAINMENU))) |menu| {
        _ = w.SetMenu(hwnd, menu);
        buildProfileMenu(app, menu);
    }

    applyFont(app, hwnd);
    applyDarkMode(app, hwnd);
    refreshRows(app);
}

fn addColumns(list: w.HWND) !void {
    const titles = [_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("Site"),
        std.unicode.utf8ToUtf16LeStringLiteral("Username"),
        std.unicode.utf8ToUtf16LeStringLiteral("Password"),
    };
    const widths = [_]c_int{ 380, 250, 200 };

    for (titles, widths, 0..) |title, width, i| {
        var column: w.LVCOLUMNW = .{
            .mask = w.LVCF_TEXT | w.LVCF_WIDTH | w.LVCF_SUBITEM,
            .cx = width,
            .pszText = @constCast(title.ptr),
            .iSubItem = @intCast(i),
        };
        if (w.SendMessageW(list, w.LVM_INSERTCOLUMNW, i, @bitCast(@intFromPtr(&column))) < 0) {
            return error.ColumnFailed;
        }
    }
}

/// One radio item per profile, inserted into the `Profile` menu at load. This
/// carries the feature ProfilePicker gives the macOS app.
fn buildProfileMenu(app: *App, menu: w.HMENU) void {
    const profile_menu = w.GetSubMenu(menu, 1) orelse return;
    // app.rc gives the popup one separator. Measured: an empty block fails
    // to compile with "empty menu of type 'POPUP' not allowed". Every
    // profile goes in ahead of that separator, and this drops it.
    defer {
        const count = w.GetMenuItemCount(profile_menu);
        if (count > 0) _ = w.DeleteMenu(profile_menu, @intCast(count - 1), w.MF_BYPOSITION);
    }

    for (app.profiles, 0..) |p, i| {
        if (i > ids.IDM_PROFILE_LAST - ids.IDM_PROFILE_FIRST) break;
        // core/src/profiles.zig caps neither the Name= value nor the resolved
        // path, so this label is the one conversion in the file that a
        // profiles.ini can overrun.
        var label: [512]u16 = undefined;
        _ = text_mod.wideZ(&label, menuLabel(p));

        var item: w.MENUITEMINFOW = .{
            .cbSize = @sizeOf(w.MENUITEMINFOW),
            .fMask = w.MIIM_STRING | w.MIIM_ID | w.MIIM_FTYPE,
            .fType = w.MFT_STRING | w.MFT_RADIOCHECK,
            .wID = ids.IDM_PROFILE_FIRST + @as(w.UINT, @intCast(i)),
            .dwTypeData = @ptrCast(&label),
        };
        _ = w.InsertMenuItemW(profile_menu, @intCast(i), 1, &item);
    }
    checkProfileMenu(app);
}

fn menuLabel(p: core.profiles.Profile) []const u8 {
    return if (p.name.len > 0) p.name else p.path;
}

fn checkProfileMenu(app: *App) void {
    const hwnd = app.hwnd orelse return;
    const menu = w.GetMenu(hwnd) orelse return;
    const profile_menu = w.GetSubMenu(menu, 1) orelse return;
    if (app.profiles.len == 0) return;
    const last: w.UINT = ids.IDM_PROFILE_FIRST + @as(w.UINT, @intCast(app.profiles.len - 1));
    _ = w.CheckMenuRadioItem(
        profile_menu,
        ids.IDM_PROFILE_FIRST,
        last,
        ids.IDM_PROFILE_FIRST + @as(w.UINT, @intCast(app.selected)),
        w.MF_BYCOMMAND,
    );
}

const margin: c_int = 8;
const search_height: c_int = 24;

fn layout(app: *App, hwnd: w.HWND) void {
    const status = app.status orelse return;
    _ = w.SendMessageW(status, w.WM_SIZE, 0, 0);

    var client: w.RECT = undefined;
    _ = w.GetClientRect(hwnd, &client);

    var status_rect: w.RECT = undefined;
    _ = w.GetClientRect(status, &status_rect);
    const status_height = status_rect.bottom - status_rect.top;

    // The count part takes a fixed slice of the right edge. -1 means the
    // first part runs to the start of the second.
    const parts = [_]c_int{ client.right - 140, -1 };
    _ = w.SendMessageW(status, w.SB_SETPARTS, parts.len, @bitCast(@intFromPtr(&parts)));

    if (app.search) |search| {
        _ = w.MoveWindow(search, margin, margin, client.right - 2 * margin, search_height, 1);
    }
    if (app.list) |list| {
        const top = margin + search_height + margin;
        const height = client.bottom - status_height - top - margin;
        _ = w.MoveWindow(list, margin, top, client.right - 2 * margin, @max(height, 0), 1);
    }
}

/// Every control draws in the default bitmap font until it is given one. The
/// message font follows the system setting and the window's current DPI.
fn applyFont(app: *App, hwnd: w.HWND) void {
    var metrics: w.NONCLIENTMETRICSW = undefined;
    metrics.cbSize = @sizeOf(w.NONCLIENTMETRICSW);
    const dpi = w.GetDpiForWindow(hwnd);
    if (w.SystemParametersInfoForDpi(
        w.SPI_GETNONCLIENTMETRICS,
        @sizeOf(w.NONCLIENTMETRICSW),
        &metrics,
        0,
        dpi,
    ) == 0) return;

    const font = w.CreateFontIndirectW(&metrics.lfMessageFont) orelse return;
    if (app.font) |old| _ = w.DeleteObject(@ptrCast(old));
    app.font = font;

    for ([_]?w.HWND{ app.search, app.list, app.status }) |maybe| {
        if (maybe) |control| _ = w.SendMessageW(control, w.WM_SETFONT, @intFromPtr(font), 1);
    }
}

/// Common controls draw light whatever the system setting says. These two
/// calls cover the title bar and the list.
fn applyDarkMode(app: *App, hwnd: w.HWND) void {
    if (appsUseLightTheme()) return;
    const on: w.BOOL = 1;
    _ = w.DwmSetWindowAttribute(hwnd, w.DWMWA_USE_IMMERSIVE_DARK_MODE, &on, @sizeOf(w.BOOL));
    if (app.list) |list| _ = w.SetWindowTheme(list, dark_list_theme, null);
}

fn appsUseLightTheme() bool {
    const key = std.unicode.utf8ToUtf16LeStringLiteral(
        "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
    );
    const name = std.unicode.utf8ToUtf16LeStringLiteral("AppsUseLightTheme");
    var value: w.DWORD = 1;
    var size: w.DWORD = @sizeOf(w.DWORD);
    const status = w.RegGetValueW(
        w.HKEY_CURRENT_USER,
        key,
        name,
        w.RRF_RT_REG_DWORD,
        null,
        &value,
        &size,
    );
    if (status != w.ERROR_SUCCESS) return true;
    return value != 0;
}

fn onCommand(app: *App, hwnd: w.HWND, wparam: w.WPARAM) w.LRESULT {
    const id = w.commandId(wparam);
    if (id >= ids.IDM_PROFILE_FIRST and id <= ids.IDM_PROFILE_LAST) {
        switchProfile(app, hwnd, id - ids.IDM_PROFILE_FIRST);
        return 0;
    }
    switch (id) {
        ids.IDC_SEARCH => {
            if (w.commandCode(wparam) == w.EN_CHANGE) runSearch(app);
        },
        ids.IDM_EDIT_FIND => {
            if (app.search) |search| {
                _ = w.SetFocus(search);
                _ = w.SendMessageW(search, w.EM_SETSEL, 0, -1);
            }
        },
        ids.IDM_EDIT_HIDE => {
            app.model.hideRevealed();
            _ = w.KillTimer(hwnd, ids.timer_hide_reveal);
            redrawRows(app);
            showStatus(app);
        },
        ids.IDM_ROW_REVEAL => toggleSelected(app, hwnd),
        // app.rc binds Ctrl+C to IDM_ROW_COPY, and TranslateAcceleratorW
        // matches whatever control holds the focus. WM_SETFOCUS puts the
        // caret in the search box at startup, so Ctrl+C over a selected
        // search term used to put the row's password on the clipboard.
        // commandCode reads the HIWORD of wParam: 1 for an accelerator and 0
        // for a menu item. The row context menu therefore still copies while
        // the search box holds the focus.
        ids.IDM_ROW_COPY => {
            if (w.commandCode(wparam) == 1 and app.search != null and
                w.GetFocus() == app.search)
            {
                _ = w.SendMessageW(app.search.?, w.WM_COPY, 0, 0);
            } else copySelected(app, hwnd);
        },
        ids.IDM_FILE_EXIT => _ = w.DestroyWindow(hwnd),
        ids.IDM_HELP_ABOUT => showAbout(hwnd),
        else => {},
    }
    return 0;
}

fn onNotify(app: *App, lparam: w.LPARAM) w.LRESULT {
    // align(1) because commctrl.h declares NMLVKEYDOWN inside pshpack1.h. An
    // arrow key in the list sends LVN_KEYDOWN with lparam 2 bytes off an
    // 8-byte boundary. NMHDR's own fields sit at the same offsets either way.
    const header: *align(1) const w.NMHDR = @ptrFromInt(@as(usize, @bitCast(lparam)));
    if (header.idFrom != ids.IDC_LIST) return 0;

    switch (header.code) {
        w.LVN_GETDISPINFOW => {
            const info: *w.NMLVDISPINFOW = @ptrFromInt(@as(usize, @bitCast(lparam)));
            fillRow(app, info);
        },
        w.NM_DBLCLK => toggleSelected(app, app.hwnd.?),
        w.NM_RCLICK => showRowMenu(app),
        else => {},
    }
    return 0;
}

fn fillRow(app: *App, info: *w.NMLVDISPINFOW) void {
    if (info.item.mask & w.LVIF_TEXT == 0) return;
    const row: usize = @intCast(@max(info.item.iItem, 0));

    switch (info.item.iSubItem) {
        0 => info.item.pszText = pointerInto(app.hostnames, row),
        1 => info.item.pszText = pointerInto(app.usernames, row),
        2 => {
            if (!app.model.isRevealed(row)) {
                info.item.pszText = @constCast(masked.ptr);
                return;
            }
            _ = text_mod.wideZ(&app.row_buf, app.model.passwordText(row));
            info.item.pszText = @ptrCast(&app.row_buf);
        },
        else => {},
    }
}

/// The list draws whatever `pszText` names. A null there for an LVIF_TEXT
/// request sends comctl32 to address 0, so a row past the slice gets the
/// empty string.
fn pointerInto(list: [][:0]u16, row: usize) w.LPWSTR {
    if (row >= list.len) return @ptrCast(&empty_wide);
    return @ptrCast(list[row].ptr);
}

/// Converts every hostname and username to UTF-16 once, then tells the list
/// how many rows it has.
fn refreshRows(app: *App) void {
    _ = app.text.reset(.retain_capacity);
    const arena = app.text.allocator();
    const count = app.model.rowCount();

    app.hostnames = arena.alloc([:0]u16, count) catch &.{};
    app.usernames = arena.alloc([:0]u16, count) catch &.{};
    // The arena can satisfy the first alloc and fail the second, so the loop
    // takes the shorter of the two.
    for (0..@min(app.hostnames.len, app.usernames.len)) |row| {
        const entry = app.model.entryAt(row) orelse continue;
        app.hostnames[row] = std.unicode.utf8ToUtf16LeAllocZ(arena, entry.hostname) catch &empty_wide;
        app.usernames[row] = std.unicode.utf8ToUtf16LeAllocZ(arena, entry.username) catch &empty_wide;
    }

    if (app.list) |list| {
        _ = w.SendMessageW(list, w.LVM_SETITEMCOUNT, count, w.LVSICF_NOSCROLL);
    }
    showStatus(app);
}

var empty_wide = [_:0]u16{};

fn redrawRows(app: *App) void {
    const list = app.list orelse return;
    const count = app.model.rowCount();
    if (count == 0) return;
    _ = w.SendMessageW(list, w.LVM_REDRAWITEMS, 0, @intCast(count - 1));
}

fn runSearch(app: *App) void {
    const search = app.search orelse return;
    var wide_buf: [search_max]u16 = undefined;
    const n: usize = @intCast(@max(w.GetWindowTextW(search, &wide_buf, search_max), 0));

    var query: [search_max * 3]u8 = undefined;
    const len = std.unicode.utf16LeToUtf8(&query, wide_buf[0..n]) catch 0;

    app.model.hideRevealed();
    app.model.search(query[0..len]) catch {
        app.model.setStatus("search failed (out of memory)", .{});
    };
    refreshRows(app);
    showStatus(app);
}

fn selectedRow(app: *App) ?usize {
    const list = app.list orelse return null;
    const found = w.SendMessageW(list, w.LVM_GETNEXTITEM, @bitCast(@as(isize, -1)), w.LVNI_SELECTED);
    if (found < 0) return null;
    return @intCast(found);
}

fn toggleSelected(app: *App, hwnd: w.HWND) void {
    const row = selectedRow(app) orelse return;
    var result = app.model.toggleReveal(row, false);
    if (result == .needs_confirmation) {
        if (!confirm(hwnd, model_mod.account_reveal_prompt)) return;
        result = app.model.toggleReveal(row, true);
    }

    _ = w.KillTimer(hwnd, ids.timer_hide_reveal);
    if (result == .revealed) {
        _ = w.SetTimer(hwnd, ids.timer_hide_reveal, secret_timeout_ms, null);
    }
    redrawRows(app);
    showStatus(app);
}

fn copySelected(app: *App, hwnd: w.HWND) void {
    const row = selectedRow(app) orelse return;
    var result = app.model.requestCopy(row, false);
    if (result == .needs_confirmation) {
        if (!confirm(hwnd, model_mod.account_copy_prompt)) return;
        result = app.model.requestCopy(row, true);
    }

    switch (result) {
        .copied => |text| {
            var scratch: [secret_max]u16 = undefined;
            app.clip.write(hwnd, text, &scratch) catch |err| {
                app.model.clearCopy();
                app.model.reportCopyFailed(copyFailure(err));
                showStatus(app);
                return;
            };
            app.model.clearCopy();
            app.model.reportCopied();
            _ = w.KillTimer(hwnd, ids.timer_clear_clipboard);
            _ = w.SetTimer(hwnd, ids.timer_clear_clipboard, secret_timeout_ms, null);
        },
        else => {},
    }
    showStatus(app);
}

/// The one place clipboard.zig's error set meets model.zig's enum. model.zig
/// cannot import clipboard.zig, because build.zig runs its tests on the build
/// host with no user32 to link.
fn copyFailure(err: clipboard.Error) model_mod.CopyFailure {
    return switch (err) {
        error.ClipboardBusy => .clipboard_busy,
        error.TooLong => .too_long,
        error.InvalidUtf8 => .invalid_text,
        error.OutOfMemory => .out_of_memory,
    };
}

fn onTimer(app: *App, hwnd: w.HWND, id: w.WPARAM) void {
    switch (id) {
        ids.timer_hide_reveal => {
            _ = w.KillTimer(hwnd, ids.timer_hide_reveal);
            app.model.hideRevealed();
            redrawRows(app);
            showStatus(app);
        },
        ids.timer_clear_clipboard => {
            _ = w.KillTimer(hwnd, ids.timer_clear_clipboard);
            app.clip.clearIfUnchanged(hwnd);
        },
        else => {},
    }
}

fn showRowMenu(app: *App) void {
    const hwnd = app.hwnd orelse return;
    const menu = w.LoadMenuW(app.instance, w.intResource(ids.IDR_ROWMENU)) orelse return;
    const popup = w.GetSubMenu(menu, 0) orelse return;

    var at: w.POINT = undefined;
    _ = w.GetCursorPos(&at);
    _ = w.TrackPopupMenu(popup, w.TPM_LEFTALIGN | w.TPM_RIGHTBUTTON, at.x, at.y, 0, hwnd, null);
}

fn switchProfile(app: *App, hwnd: w.HWND, index: usize) void {
    if (index >= app.profiles.len) return;
    app.selected = index;
    checkProfileMenu(app);

    _ = w.KillTimer(hwnd, ids.timer_hide_reveal);
    if (app.search) |search| _ = w.SetWindowTextW(search, std.unicode.utf8ToUtf16LeStringLiteral(""));

    _ = app.model.open(app.profiles[index].path);
    if (app.model.needs_password) promptPassword(app, hwnd);
    refreshRows(app);
}

fn showStatus(app: *App) void {
    const status = app.status orelse return;

    var message: [512]u16 = undefined;
    _ = text_mod.wideZ(&message, app.model.status());
    _ = w.SendMessageW(status, w.SB_SETTEXTW, 0, @bitCast(@intFromPtr(&message)));

    var count_utf8: [64]u8 = undefined;
    const text = std.fmt.bufPrint(&count_utf8, "{d} shown", .{app.model.rowCount()}) catch "";
    var count: [64]u16 = undefined;
    _ = text_mod.wideZ(&count, text);
    _ = w.SendMessageW(status, w.SB_SETTEXTW, 1, @bitCast(@intFromPtr(&count)));
}

fn confirm(hwnd: w.HWND, prompt: []const u8) bool {
    var text: [512]u16 = undefined;
    _ = text_mod.wideZ(&text, prompt);
    const answer = w.MessageBoxW(
        hwnd,
        @ptrCast(&text),
        window_title,
        w.MB_YESNO | w.MB_ICONWARNING,
    );
    return answer == w.IDYES;
}

fn showAbout(hwnd: w.HWND) void {
    _ = w.MessageBoxW(
        hwnd,
        std.unicode.utf8ToUtf16LeStringLiteral(
            "Keywise\n\nShows the saved logins in a local Firefox profile.\n" ++
                "https://github.com/lkraider/keywise",
        ),
        window_title,
        w.MB_OK,
    );
}

fn reportFatal(message: []const u8) void {
    var text: [512]u16 = undefined;
    _ = text_mod.wideZ(&text, message);
    _ = w.MessageBoxW(null, @ptrCast(&text), window_title, w.MB_OK | w.MB_ICONERROR);
}

/// The Primary Password prompt. The dialog template carries the tab order,
/// the default button, Esc to cancel and Segoe UI 9pt, so no font code runs
/// here. A wrong password keeps the dialog open with IDC_PW_ERROR set.
fn promptPassword(app: *App, hwnd: w.HWND) void {
    _ = w.DialogBoxParamW(
        app.instance,
        w.intResource(ids.IDD_PASSWORD),
        hwnd,
        passwordProc,
        @bitCast(@intFromPtr(app)),
    );
}

fn passwordProc(hdlg: w.HWND, message: w.UINT, wparam: w.WPARAM, lparam: w.LPARAM) callconv(.winapi) w.INT_PTR {
    switch (message) {
        w.WM_INITDIALOG => {
            _ = w.SetWindowLongPtrW(hdlg, w.GWLP_USERDATA, lparam);
            return 1;
        },
        w.WM_COMMAND => {
            const app = appOf(hdlg) orelse return 0;
            switch (w.commandId(wparam)) {
                ids.IDC_PW_EDIT => return 0,
                @as(u16, @intCast(w.IDOK)) => {
                    submitPassword(app, hdlg);
                    return 1;
                },
                @as(u16, @intCast(w.IDCANCEL)) => {
                    _ = w.EndDialog(hdlg, w.IDCANCEL);
                    return 1;
                },
                else => return 0,
            }
        },
        else => return 0,
    }
}

/// Both the UTF-16 buffer the edit control fills and its UTF-8 copy are wiped
/// after every attempt.
fn submitPassword(app: *App, hdlg: w.HWND) void {
    var wide_buf: [512]u16 = undefined;
    defer std.crypto.secureZero(u16, &wide_buf);
    var utf8: [512 * 3]u8 = undefined;
    defer std.crypto.secureZero(u8, &utf8);

    const edit = w.GetDlgItem(hdlg, ids.IDC_PW_EDIT) orelse return;
    const n: usize = @intCast(@max(w.GetWindowTextW(edit, &wide_buf, wide_buf.len), 0));
    const len = std.unicode.utf16LeToUtf8(&utf8, wide_buf[0..n]) catch 0;

    const path = app.profiles[app.selected].path;
    if (app.model.unlock(path, utf8[0..len]) == .opened) {
        refreshRows(app);
        _ = w.EndDialog(hdlg, w.IDOK);
        return;
    }

    var error_text: [256]u16 = undefined;
    _ = text_mod.wideZ(&error_text, app.model.status());
    _ = w.SetDlgItemTextW(hdlg, ids.IDC_PW_ERROR, @ptrCast(&error_text));
    _ = w.SetWindowTextW(edit, std.unicode.utf8ToUtf16LeStringLiteral(""));
    _ = w.SetFocus(edit);
}
