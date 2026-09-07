//! The Win32 declarations this app calls, written by hand.
//!
//! Zig bundles a `.def` file for every DLL used here under
//! `lib/libc/mingw/lib-common/`, and it generates the import library from
//! that file. `linkSystemLibrary("user32")` therefore cross-compiles from a
//! Mac with no Windows SDK installed.
//!
//! The rejected alternative is the `zigwin32` dependency, a generated source
//! tree of about 300 MB.

const std = @import("std");

pub const BOOL = c_int;
pub const BYTE = u8;
pub const WORD = u16;
pub const DWORD = u32;
pub const LONG = i32;
pub const UINT = c_uint;
pub const WCHAR = u16;
// align(1) because intResource below builds one of these out of a small
// integer. A u16 pointer wants a 2-byte alignment, and @ptrFromInt panics on
// an odd resource id such as IDI_APP = 1.
pub const LPCWSTR = [*:0]align(1) const WCHAR;
pub const LPWSTR = [*:0]WCHAR;

pub const UINT_PTR = usize;
pub const ULONG_PTR = usize;
pub const LONG_PTR = isize;
pub const WPARAM = UINT_PTR;
pub const LPARAM = LONG_PTR;
pub const LRESULT = LONG_PTR;
pub const HRESULT = i32;

pub const HANDLE = *anyopaque;
pub const HWND = *opaque {};
pub const HINSTANCE = *opaque {};
pub const HMENU = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HBRUSH = *opaque {};
pub const HFONT = *opaque {};
pub const HGDIOBJ = *opaque {};
pub const HGLOBAL = *opaque {};
pub const HKEY = *opaque {};
pub const HACCEL = *opaque {};

/// A resource id passed where the API takes a string. Windows reads a
/// pointer whose high word is zero as an id in the low word.
pub fn intResource(id: u16) LPCWSTR {
    return @ptrFromInt(id);
}

pub const POINT = extern struct { x: LONG, y: LONG };
pub const RECT = extern struct { left: LONG, top: LONG, right: LONG, bottom: LONG };

pub const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};

pub const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub const DLGPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) INT_PTR;
pub const INT_PTR = isize;

pub const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: c_int = 0,
    cbWndExtra: c_int = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HBRUSH = null,
    lpszMenuName: ?LPCWSTR = null,
    lpszClassName: LPCWSTR,
    hIconSm: ?HICON = null,
};

pub const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: ?HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: c_int,
    cx: c_int,
    y: c_int,
    x: c_int,
    style: LONG,
    lpszName: ?LPCWSTR,
    lpszClass: ?LPCWSTR,
    dwExStyle: DWORD,
};

pub const LF_FACESIZE = 32;

pub const LOGFONTW = extern struct {
    lfHeight: LONG,
    lfWidth: LONG,
    lfEscapement: LONG,
    lfOrientation: LONG,
    lfWeight: LONG,
    lfItalic: BYTE,
    lfUnderline: BYTE,
    lfStrikeOut: BYTE,
    lfCharSet: BYTE,
    lfOutPrecision: BYTE,
    lfClipPrecision: BYTE,
    lfQuality: BYTE,
    lfPitchAndFamily: BYTE,
    lfFaceName: [LF_FACESIZE]WCHAR,
};

pub const NONCLIENTMETRICSW = extern struct {
    cbSize: UINT,
    iBorderWidth: c_int,
    iScrollWidth: c_int,
    iScrollHeight: c_int,
    iCaptionWidth: c_int,
    iCaptionHeight: c_int,
    lfCaptionFont: LOGFONTW,
    iSmCaptionWidth: c_int,
    iSmCaptionHeight: c_int,
    lfSmCaptionFont: LOGFONTW,
    iMenuWidth: c_int,
    iMenuHeight: c_int,
    lfMenuFont: LOGFONTW,
    lfStatusFont: LOGFONTW,
    lfMessageFont: LOGFONTW,
    iPaddedBorderWidth: c_int,
};

pub const NMHDR = extern struct {
    hwndFrom: ?HWND,
    idFrom: UINT_PTR,
    code: UINT,
};

pub const LVITEMW = extern struct {
    mask: UINT = 0,
    iItem: c_int = 0,
    iSubItem: c_int = 0,
    state: UINT = 0,
    stateMask: UINT = 0,
    pszText: ?LPWSTR = null,
    cchTextMax: c_int = 0,
    iImage: c_int = 0,
    lParam: LPARAM = 0,
    iIndent: c_int = 0,
    iGroupId: c_int = 0,
    cColumns: UINT = 0,
    puColumns: ?*UINT = null,
    piColFmt: ?*c_int = null,
    iGroup: c_int = 0,
};

pub const NMLVDISPINFOW = extern struct {
    hdr: NMHDR,
    item: LVITEMW,
};

pub const LVCOLUMNW = extern struct {
    mask: UINT = 0,
    fmt: c_int = 0,
    cx: c_int = 0,
    pszText: ?LPWSTR = null,
    cchTextMax: c_int = 0,
    iSubItem: c_int = 0,
    iImage: c_int = 0,
    iOrder: c_int = 0,
    cxMin: c_int = 0,
    cxDefault: c_int = 0,
    cxIdeal: c_int = 0,
};

pub const MENUITEMINFOW = extern struct {
    cbSize: UINT,
    fMask: UINT = 0,
    fType: UINT = 0,
    fState: UINT = 0,
    wID: UINT = 0,
    hSubMenu: ?HMENU = null,
    hbmpChecked: ?HANDLE = null,
    hbmpUnchecked: ?HANDLE = null,
    dwItemData: ULONG_PTR = 0,
    dwTypeData: ?LPWSTR = null,
    cch: UINT = 0,
    hbmpItem: ?HANDLE = null,
};

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD,
    dwICC: DWORD,
};

// Window class and creation.
pub const CS_VREDRAW: UINT = 0x0001;
pub const CS_HREDRAW: UINT = 0x0002;
pub const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_TABSTOP: DWORD = 0x00010000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_EX_CLIENTEDGE: DWORD = 0x00000200;
pub const CW_USEDEFAULT: c_int = @bitCast(@as(u32, 0x80000000));
pub const SW_SHOWNORMAL: c_int = 1;
pub const COLOR_BTNFACE: c_int = 15;
pub const GWLP_USERDATA: c_int = -21;
pub const IDC_ARROW: u16 = 32512;

// Messages.
pub const WM_CREATE: UINT = 0x0001;
pub const WM_DESTROY: UINT = 0x0002;
pub const WM_SIZE: UINT = 0x0005;
pub const WM_SETFOCUS: UINT = 0x0007;
pub const WM_SETFONT: UINT = 0x0030;
pub const WM_SYSKEYDOWN: UINT = 0x0104;
pub const WM_SYSKEYUP: UINT = 0x0105;
pub const WM_SYSCHAR: UINT = 0x0106;
pub const WM_INITDIALOG: UINT = 0x0110;
pub const WM_COMMAND: UINT = 0x0111;
pub const WM_TIMER: UINT = 0x0113;
pub const WM_NOTIFY: UINT = 0x004E;
pub const WM_DPICHANGED: UINT = 0x02E0;
/// The EDIT control copies its own selection to the clipboard for this.
pub const WM_COPY: UINT = 0x0301;
pub const WM_USER: UINT = 0x0400;

pub const EN_CHANGE: WORD = 0x0300;

// Edit control.
pub const ES_AUTOHSCROLL: DWORD = 0x0080;
pub const ECM_FIRST: UINT = 0x1500;
pub const EM_SETCUEBANNER: UINT = ECM_FIRST + 1;
pub const EM_SETSEL: UINT = 0x00B1;

// List view.
pub const WC_LISTVIEWW: LPCWSTR = std.unicode.utf8ToUtf16LeStringLiteral("SysListView32");
pub const LVS_REPORT: DWORD = 0x0001;
pub const LVS_SINGLESEL: DWORD = 0x0004;
pub const LVS_SHOWSELALWAYS: DWORD = 0x0008;
pub const LVS_OWNERDATA: DWORD = 0x1000;
pub const LVS_EX_FULLROWSELECT: DWORD = 0x00000020;
pub const LVS_EX_DOUBLEBUFFER: DWORD = 0x00010000;

pub const LVM_FIRST: UINT = 0x1000;
pub const LVM_GETNEXTITEM: UINT = LVM_FIRST + 12;
pub const LVM_REDRAWITEMS: UINT = LVM_FIRST + 21;
pub const LVM_SETITEMCOUNT: UINT = LVM_FIRST + 47;
pub const LVM_SETEXTENDEDLISTVIEWSTYLE: UINT = LVM_FIRST + 54;
pub const LVM_INSERTCOLUMNW: UINT = LVM_FIRST + 97;

pub const LVIF_TEXT: UINT = 0x0001;
pub const LVCF_WIDTH: UINT = 0x0002;
pub const LVCF_TEXT: UINT = 0x0004;
pub const LVCF_SUBITEM: UINT = 0x0008;
pub const LVNI_SELECTED: UINT = 0x0002;
pub const LVSICF_NOSCROLL: UINT = 0x0002;

/// Notification codes arrive as a UINT holding a negative number.
pub const LVN_GETDISPINFOW: UINT = @bitCast(@as(i32, -177));
pub const NM_DBLCLK: UINT = @bitCast(@as(i32, -3));
pub const NM_RCLICK: UINT = @bitCast(@as(i32, -5));

// Status bar.
pub const STATUSCLASSNAMEW: LPCWSTR = std.unicode.utf8ToUtf16LeStringLiteral("msctls_statusbar32");
pub const SBARS_SIZEGRIP: DWORD = 0x0100;
pub const SB_SETPARTS: UINT = WM_USER + 4;
pub const SB_SETTEXTW: UINT = WM_USER + 11;

// Common controls.
pub const ICC_LISTVIEW_CLASSES: DWORD = 0x00000001;
pub const ICC_BAR_CLASSES: DWORD = 0x00000004;

// Menus.
pub const MIIM_ID: UINT = 0x00000002;
pub const MIIM_STRING: UINT = 0x00000040;
pub const MIIM_FTYPE: UINT = 0x00000100;
pub const MFT_STRING: UINT = 0x00000000;
pub const MFT_RADIOCHECK: UINT = 0x00000200;
pub const MF_BYCOMMAND: UINT = 0x00000000;
pub const MF_BYPOSITION: UINT = 0x00000400;
pub const TPM_LEFTALIGN: UINT = 0x0000;
pub const TPM_RIGHTBUTTON: UINT = 0x0002;

// Message box.
pub const MB_OK: UINT = 0x00000000;
pub const MB_YESNO: UINT = 0x00000004;
pub const MB_ICONERROR: UINT = 0x00000010;
pub const MB_ICONWARNING: UINT = 0x00000030;
pub const IDOK: c_int = 1;
pub const IDCANCEL: c_int = 2;
pub const IDYES: c_int = 6;

// Clipboard.
pub const CF_UNICODETEXT: UINT = 13;
pub const GMEM_MOVEABLE: UINT = 0x0002;

// Fonts and DPI.
pub const SPI_GETNONCLIENTMETRICS: UINT = 0x0029;
pub const SWP_NOZORDER: UINT = 0x0004;
pub const SWP_NOACTIVATE: UINT = 0x0010;

// Dark mode.
pub const DWMWA_USE_IMMERSIVE_DARK_MODE: DWORD = 20;
pub const HKEY_CURRENT_USER: HKEY = @ptrFromInt(0x80000001);
pub const RRF_RT_REG_DWORD: DWORD = 0x00000010;
pub const ERROR_SUCCESS: LONG = 0;

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?LPCWSTR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GlobalAlloc(uFlags: UINT, dwBytes: usize) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalFree(hMem: HGLOBAL) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalLock(hMem: HGLOBAL) callconv(.winapi) ?*anyopaque;
pub extern "kernel32" fn GlobalUnlock(hMem: HGLOBAL) callconv(.winapi) BOOL;

pub extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: ?LPCWSTR,
    lpWindowName: ?LPCWSTR,
    dwStyle: DWORD,
    X: c_int,
    Y: c_int,
    nWidth: c_int,
    nHeight: c_int,
    hWndParent: ?HWND,
    hMenu: ?HMENU,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn DestroyWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn ShowWindow(HWND, c_int) callconv(.winapi) BOOL;
pub extern "user32" fn UpdateWindow(HWND) callconv(.winapi) BOOL;
pub extern "user32" fn GetMessageW(*MSG, ?HWND, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) BOOL;
pub extern "user32" fn IsDialogMessageW(HWND, *MSG) callconv(.winapi) BOOL;
pub extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn PostQuitMessage(c_int) callconv(.winapi) void;
pub extern "user32" fn LoadCursorW(?HINSTANCE, LPCWSTR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadIconW(?HINSTANCE, LPCWSTR) callconv(.winapi) ?HICON;
pub extern "user32" fn SendMessageW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) BOOL;
pub extern "user32" fn MoveWindow(HWND, c_int, c_int, c_int, c_int, BOOL) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowPos(HWND, ?HWND, c_int, c_int, c_int, c_int, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn SetFocus(?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn GetWindowTextW(HWND, [*]WCHAR, c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextLengthW(HWND) callconv(.winapi) c_int;
pub extern "user32" fn SetWindowTextW(HWND, LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn SetWindowLongPtrW(HWND, c_int, LONG_PTR) callconv(.winapi) LONG_PTR;
pub extern "user32" fn GetWindowLongPtrW(HWND, c_int) callconv(.winapi) LONG_PTR;
pub extern "user32" fn SetTimer(?HWND, UINT_PTR, UINT, ?*anyopaque) callconv(.winapi) UINT_PTR;
pub extern "user32" fn KillTimer(?HWND, UINT_PTR) callconv(.winapi) BOOL;
pub extern "user32" fn MessageBoxW(?HWND, ?LPCWSTR, ?LPCWSTR, UINT) callconv(.winapi) c_int;
pub extern "user32" fn DialogBoxParamW(?HINSTANCE, LPCWSTR, ?HWND, ?DLGPROC, LPARAM) callconv(.winapi) INT_PTR;
pub extern "user32" fn EndDialog(HWND, INT_PTR) callconv(.winapi) BOOL;
pub extern "user32" fn GetDlgItem(?HWND, c_int) callconv(.winapi) ?HWND;
pub extern "user32" fn SetDlgItemTextW(HWND, c_int, LPCWSTR) callconv(.winapi) BOOL;
pub extern "user32" fn LoadAcceleratorsW(?HINSTANCE, LPCWSTR) callconv(.winapi) ?HACCEL;
pub extern "user32" fn TranslateAcceleratorW(HWND, HACCEL, *MSG) callconv(.winapi) c_int;
pub extern "user32" fn LoadMenuW(?HINSTANCE, LPCWSTR) callconv(.winapi) ?HMENU;
pub extern "user32" fn SetMenu(HWND, ?HMENU) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenu(HWND) callconv(.winapi) ?HMENU;
pub extern "user32" fn GetSubMenu(HMENU, c_int) callconv(.winapi) ?HMENU;
pub extern "user32" fn InsertMenuItemW(HMENU, UINT, BOOL, *const MENUITEMINFOW) callconv(.winapi) BOOL;
pub extern "user32" fn CheckMenuRadioItem(HMENU, UINT, UINT, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn DeleteMenu(HMENU, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetMenuItemCount(?HMENU) callconv(.winapi) c_int;
pub extern "user32" fn TrackPopupMenu(HMENU, UINT, c_int, c_int, c_int, HWND, ?*const RECT) callconv(.winapi) BOOL;
pub extern "user32" fn GetCursorPos(*POINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetSysColorBrush(c_int) callconv(.winapi) ?HBRUSH;
pub extern "user32" fn SystemParametersInfoForDpi(UINT, UINT, ?*anyopaque, UINT, UINT) callconv(.winapi) BOOL;
pub extern "user32" fn GetDpiForWindow(HWND) callconv(.winapi) UINT;
pub extern "user32" fn OpenClipboard(?HWND) callconv(.winapi) BOOL;
pub extern "user32" fn CloseClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn EmptyClipboard() callconv(.winapi) BOOL;
pub extern "user32" fn SetClipboardData(UINT, ?HANDLE) callconv(.winapi) ?HANDLE;
pub extern "user32" fn RegisterClipboardFormatW(LPCWSTR) callconv(.winapi) UINT;
pub extern "user32" fn GetClipboardSequenceNumber() callconv(.winapi) DWORD;
pub extern "user32" fn GetClipboardData(uFormat: UINT) callconv(.winapi) ?HGLOBAL;
pub extern "kernel32" fn GlobalSize(hMem: HGLOBAL) callconv(.winapi) usize;

pub extern "gdi32" fn CreateFontIndirectW(*const LOGFONTW) callconv(.winapi) ?HFONT;
pub extern "gdi32" fn DeleteObject(HGDIOBJ) callconv(.winapi) BOOL;

pub extern "comctl32" fn InitCommonControlsEx(*const INITCOMMONCONTROLSEX) callconv(.winapi) BOOL;

pub extern "dwmapi" fn DwmSetWindowAttribute(HWND, DWORD, *const anyopaque, DWORD) callconv(.winapi) HRESULT;

pub extern "uxtheme" fn SetWindowTheme(HWND, ?LPCWSTR, ?LPCWSTR) callconv(.winapi) HRESULT;

pub extern "advapi32" fn RegGetValueW(
    hkey: HKEY,
    lpSubKey: ?LPCWSTR,
    lpValue: ?LPCWSTR,
    dwFlags: DWORD,
    pdwType: ?*DWORD,
    pvData: ?*anyopaque,
    pcbData: ?*DWORD,
) callconv(.winapi) LONG;

/// The low word of a WM_COMMAND wParam. It holds the menu id, the
/// accelerator id or the control id.
pub fn commandId(wParam: WPARAM) u16 {
    return @truncate(wParam);
}

/// The high word of a WM_COMMAND wParam. It holds the control's notification
/// code.
pub fn commandCode(wParam: WPARAM) u16 {
    return @truncate(wParam >> 16);
}
