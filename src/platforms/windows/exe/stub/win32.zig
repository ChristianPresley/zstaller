// Copyright 2026 The zstaller Authors
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//
// SPDX-License-Identifier: Apache-2.0

//! The few Win32 functions the installer stub needs, declared directly so
//! the stub does not depend on the shape of `std.os.windows`.

const std = @import("std");

pub const WCHAR = u16;
pub const DWORD = u32;
pub const LSTATUS = i32;
pub const HKEY = *opaque {};
pub const HWND = *opaque {};
pub const HANDLE = *anyopaque;

pub const HKEY_LOCAL_MACHINE: HKEY = @ptrFromInt(0x80000002);
pub const HWND_BROADCAST: HWND = @ptrFromInt(0xffff);

pub const ERROR_SUCCESS: LSTATUS = 0;
pub const ERROR_FILE_NOT_FOUND: LSTATUS = 2;
pub const ERROR_MORE_DATA: LSTATUS = 234;

pub const KEY_QUERY_VALUE: DWORD = 0x0001;
pub const KEY_SET_VALUE: DWORD = 0x0002;
pub const KEY_ALL_ACCESS: DWORD = 0xF003F;
pub const KEY_WOW64_64KEY: DWORD = 0x0100;
pub const REG_OPTION_NON_VOLATILE: DWORD = 0;

pub const REG_SZ: DWORD = 1;
pub const REG_EXPAND_SZ: DWORD = 2;
pub const REG_DWORD: DWORD = 4;

pub const MB_OK: u32 = 0x0;
pub const MB_YESNO: u32 = 0x4;
pub const MB_ICONERROR: u32 = 0x10;
pub const MB_ICONQUESTION: u32 = 0x20;
pub const MB_ICONINFORMATION: u32 = 0x40;
pub const IDYES: c_int = 6;

pub const WM_SETTINGCHANGE: u32 = 0x001A;
pub const SMTO_ABORTIFHUNG: u32 = 0x0002;

pub const CREATE_NO_WINDOW: DWORD = 0x08000000;
pub const DETACHED_PROCESS: DWORD = 0x00000008;

pub const STARTUPINFOW = extern struct {
    cb: DWORD,
    lpReserved: ?[*:0]u16 = null,
    lpDesktop: ?[*:0]u16 = null,
    lpTitle: ?[*:0]u16 = null,
    dwX: DWORD = 0,
    dwY: DWORD = 0,
    dwXSize: DWORD = 0,
    dwYSize: DWORD = 0,
    dwXCountChars: DWORD = 0,
    dwYCountChars: DWORD = 0,
    dwFillAttribute: DWORD = 0,
    dwFlags: DWORD = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?HANDLE = null,
    hStdOutput: ?HANDLE = null,
    hStdError: ?HANDLE = null,
};

pub const PROCESS_INFORMATION = extern struct {
    hProcess: ?HANDLE,
    hThread: ?HANDLE,
    dwProcessId: DWORD,
    dwThreadId: DWORD,
};

pub extern "advapi32" fn RegCreateKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const WCHAR,
    Reserved: DWORD,
    lpClass: ?[*:0]const WCHAR,
    dwOptions: DWORD,
    samDesired: DWORD,
    lpSecurityAttributes: ?*anyopaque,
    phkResult: *HKEY,
    lpdwDisposition: ?*DWORD,
) callconv(.winapi) LSTATUS;

pub extern "advapi32" fn RegOpenKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const WCHAR,
    ulOptions: DWORD,
    samDesired: DWORD,
    phkResult: *HKEY,
) callconv(.winapi) LSTATUS;

pub extern "advapi32" fn RegSetValueExW(
    hKey: HKEY,
    lpValueName: ?[*:0]const WCHAR,
    Reserved: DWORD,
    dwType: DWORD,
    lpData: [*]const u8,
    cbData: DWORD,
) callconv(.winapi) LSTATUS;

pub extern "advapi32" fn RegQueryValueExW(
    hKey: HKEY,
    lpValueName: ?[*:0]const WCHAR,
    lpReserved: ?*DWORD,
    lpType: ?*DWORD,
    lpData: ?[*]u8,
    lpcbData: ?*DWORD,
) callconv(.winapi) LSTATUS;

pub extern "advapi32" fn RegDeleteKeyExW(
    hKey: HKEY,
    lpSubKey: [*:0]const WCHAR,
    samDesired: DWORD,
    Reserved: DWORD,
) callconv(.winapi) LSTATUS;

pub extern "advapi32" fn RegCloseKey(hKey: HKEY) callconv(.winapi) LSTATUS;

pub extern "user32" fn MessageBoxW(
    hWnd: ?HWND,
    lpText: [*:0]const WCHAR,
    lpCaption: [*:0]const WCHAR,
    uType: u32,
) callconv(.winapi) c_int;

pub extern "user32" fn SendMessageTimeoutW(
    hWnd: HWND,
    Msg: u32,
    wParam: usize,
    lParam: isize,
    fuFlags: u32,
    uTimeout: u32,
    lpdwResult: ?*usize,
) callconv(.winapi) isize;

pub extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const WCHAR,
    lpCommandLine: ?[*:0]WCHAR,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: c_int,
    dwCreationFlags: DWORD,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const WCHAR,
    lpStartupInfo: *STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) c_int;

pub extern "kernel32" fn CloseHandle(hObject: HANDLE) callconv(.winapi) c_int;

pub const SYNCHRONIZE: DWORD = 0x00100000;
pub const INFINITE: DWORD = 0xFFFFFFFF;
pub const MOVEFILE_DELAY_UNTIL_REBOOT: DWORD = 0x4;

pub extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) DWORD;
pub extern "kernel32" fn OpenProcess(dwDesiredAccess: DWORD, bInheritHandle: c_int, dwProcessId: DWORD) callconv(.winapi) ?HANDLE;
pub extern "kernel32" fn WaitForSingleObject(hHandle: HANDLE, dwMilliseconds: DWORD) callconv(.winapi) DWORD;
pub extern "kernel32" fn Sleep(dwMilliseconds: DWORD) callconv(.winapi) void;
pub extern "kernel32" fn MoveFileExW(
    lpExistingFileName: [*:0]const WCHAR,
    lpNewFileName: ?[*:0]const WCHAR,
    dwFlags: DWORD,
) callconv(.winapi) c_int;

// ---- Finding and ending programs that run from the install directory.

pub const TH32CS_SNAPPROCESS: DWORD = 0x2;
pub const INVALID_HANDLE_VALUE: HANDLE = @ptrFromInt(std.math.maxInt(usize));
pub const PROCESS_TERMINATE: DWORD = 0x0001;
pub const PROCESS_QUERY_LIMITED_INFORMATION: DWORD = 0x1000;
pub const WAIT_OBJECT_0: DWORD = 0;
pub const MAX_PATH = 260;

pub const PROCESSENTRY32W = extern struct {
    dwSize: DWORD,
    cntUsage: DWORD = 0,
    th32ProcessID: DWORD = 0,
    th32DefaultHeapID: usize = 0,
    th32ModuleID: DWORD = 0,
    cntThreads: DWORD = 0,
    th32ParentProcessID: DWORD = 0,
    pcPriClassBase: i32 = 0,
    dwFlags: DWORD = 0,
    szExeFile: [MAX_PATH]WCHAR = @splat(0),
};

pub extern "kernel32" fn CreateToolhelp32Snapshot(dwFlags: DWORD, th32ProcessID: DWORD) callconv(.winapi) HANDLE;
pub extern "kernel32" fn Process32FirstW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;
pub extern "kernel32" fn Process32NextW(hSnapshot: HANDLE, lppe: *PROCESSENTRY32W) callconv(.winapi) c_int;
pub extern "kernel32" fn QueryFullProcessImageNameW(
    hProcess: HANDLE,
    dwFlags: DWORD,
    lpExeName: [*]WCHAR,
    lpdwSize: *DWORD,
) callconv(.winapi) c_int;
pub extern "kernel32" fn TerminateProcess(hProcess: HANDLE, uExitCode: u32) callconv(.winapi) c_int;

pub extern "shell32" fn ShellExecuteW(
    hwnd: ?HWND,
    lpOperation: ?[*:0]const WCHAR,
    lpFile: [*:0]const WCHAR,
    lpParameters: ?[*:0]const WCHAR,
    lpDirectory: ?[*:0]const WCHAR,
    nShowCmd: c_int,
) callconv(.winapi) isize;

pub const SW_SHOWNORMAL: c_int = 1;

// ---- COM, for writing Start Menu shortcuts with IShellLinkW.

pub const HRESULT = i32;
pub const GUID = extern struct { data1: u32, data2: u16, data3: u16, data4: [8]u8 };

pub const COINIT_APARTMENTTHREADED: DWORD = 0x2;
pub const CLSCTX_INPROC_SERVER: DWORD = 0x1;

pub const CLSID_ShellLink: GUID = .{ .data1 = 0x00021401, .data2 = 0, .data3 = 0, .data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
pub const IID_IShellLinkW: GUID = .{ .data1 = 0x000214F9, .data2 = 0, .data3 = 0, .data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };
pub const IID_IPersistFile: GUID = .{ .data1 = 0x0000010B, .data2 = 0, .data3 = 0, .data4 = .{ 0xC0, 0, 0, 0, 0, 0, 0, 0x46 } };

pub extern "ole32" fn CoInitializeEx(pvReserved: ?*anyopaque, dwCoInit: DWORD) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoUninitialize() callconv(.winapi) void;
pub extern "ole32" fn CoCreateInstance(
    rclsid: *const GUID,
    pUnkOuter: ?*anyopaque,
    dwClsContext: DWORD,
    riid: *const GUID,
    ppv: *?*anyopaque,
) callconv(.winapi) HRESULT;

const Unused = *const fn () callconv(.winapi) void;

/// IShellLinkW vtable, in declaration order (shobjidl_core.h).
pub const IShellLinkW = extern struct {
    vtable: *const extern struct {
        QueryInterface: *const fn (*IShellLinkW, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: Unused,
        Release: *const fn (*IShellLinkW) callconv(.winapi) u32,
        GetPath: Unused,
        GetIDList: Unused,
        SetIDList: Unused,
        GetDescription: Unused,
        SetDescription: *const fn (*IShellLinkW, [*:0]const WCHAR) callconv(.winapi) HRESULT,
        GetWorkingDirectory: Unused,
        SetWorkingDirectory: *const fn (*IShellLinkW, [*:0]const WCHAR) callconv(.winapi) HRESULT,
        GetArguments: Unused,
        SetArguments: Unused,
        GetHotkey: Unused,
        SetHotkey: Unused,
        GetShowCmd: Unused,
        SetShowCmd: Unused,
        GetIconLocation: Unused,
        SetIconLocation: *const fn (*IShellLinkW, [*:0]const WCHAR, c_int) callconv(.winapi) HRESULT,
        SetRelativePath: Unused,
        Resolve: Unused,
        SetPath: *const fn (*IShellLinkW, [*:0]const WCHAR) callconv(.winapi) HRESULT,
    },
};

/// IPersistFile vtable, in declaration order (objidl.h).
pub const IPersistFile = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IPersistFile) callconv(.winapi) u32,
        GetClassID: Unused,
        IsDirty: Unused,
        Load: Unused,
        Save: *const fn (*IPersistFile, [*:0]const WCHAR, c_int) callconv(.winapi) HRESULT,
        SaveCompleted: Unused,
        GetCurFile: Unused,
    },
};

// ---- Windows, messages and painting, for the installer wizard.

pub const HINSTANCE = *opaque {};
pub const HICON = *opaque {};
pub const HCURSOR = *opaque {};
pub const HDC = *opaque {};
pub const HMONITOR = *opaque {};
/// Fonts, brushes and bitmaps.
pub const HGDIOBJ = *anyopaque;
pub const WPARAM = usize;
pub const LPARAM = isize;
pub const LRESULT = isize;
pub const WNDPROC = *const fn (HWND, u32, WPARAM, LPARAM) callconv(.winapi) LRESULT;

pub const POINT = extern struct { x: i32 = 0, y: i32 = 0 };
pub const RECT = extern struct { left: i32 = 0, top: i32 = 0, right: i32 = 0, bottom: i32 = 0 };

pub const MSG = extern struct {
    hwnd: ?HWND = null,
    message: u32 = 0,
    wParam: WPARAM = 0,
    lParam: LPARAM = 0,
    time: DWORD = 0,
    pt: POINT = .{},
    lPrivate: DWORD = 0,
};

pub const WNDCLASSEXW = extern struct {
    cbSize: u32 = @sizeOf(WNDCLASSEXW),
    style: u32 = 0,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32 = 0,
    cbWndExtra: i32 = 0,
    hInstance: ?HINSTANCE,
    hIcon: ?HICON = null,
    hCursor: ?HCURSOR = null,
    hbrBackground: ?HGDIOBJ = null,
    lpszMenuName: ?[*:0]const WCHAR = null,
    lpszClassName: [*:0]const WCHAR,
    hIconSm: ?HICON = null,
};

pub const PAINTSTRUCT = extern struct {
    hdc: ?HDC = null,
    fErase: c_int = 0,
    rcPaint: RECT = .{},
    fRestore: c_int = 0,
    fIncUpdate: c_int = 0,
    rgbReserved: [32]u8 = @splat(0),
};

pub const MONITORINFO = extern struct {
    cbSize: DWORD = @sizeOf(MONITORINFO),
    rcMonitor: RECT = .{},
    rcWork: RECT = .{},
    dwFlags: DWORD = 0,
};

pub const BITMAPINFOHEADER = extern struct {
    biSize: u32 = @sizeOf(BITMAPINFOHEADER),
    biWidth: i32,
    biHeight: i32,
    biPlanes: u16 = 1,
    biBitCount: u16 = 32,
    biCompression: u32 = 0,
    biSizeImage: u32 = 0,
    biXPelsPerMeter: i32 = 0,
    biYPelsPerMeter: i32 = 0,
    biClrUsed: u32 = 0,
    biClrImportant: u32 = 0,
};

pub const BITMAPINFO = extern struct {
    bmiHeader: BITMAPINFOHEADER,
    bmiColors: [1]u32 = .{0},
};

pub const INITCOMMONCONTROLSEX = extern struct {
    dwSize: DWORD = @sizeOf(INITCOMMONCONTROLSEX),
    dwICC: DWORD,
};

pub const ICC_STANDARD_CLASSES: DWORD = 0x4000;
pub const ICC_PROGRESS_CLASS: DWORD = 0x20;

pub const WS_OVERLAPPED: DWORD = 0x00000000;
pub const WS_CAPTION: DWORD = 0x00C00000;
pub const WS_SYSMENU: DWORD = 0x00080000;
pub const WS_MINIMIZEBOX: DWORD = 0x00020000;
pub const WS_CLIPCHILDREN: DWORD = 0x02000000;
pub const WS_CHILD: DWORD = 0x40000000;
pub const WS_VISIBLE: DWORD = 0x10000000;
pub const WS_TABSTOP: DWORD = 0x00010000;
pub const WS_GROUP: DWORD = 0x00020000;
pub const WS_VSCROLL: DWORD = 0x00200000;
pub const WS_BORDER: DWORD = 0x00800000;
pub const WS_EX_CONTROLPARENT: DWORD = 0x00010000;
pub const WS_EX_CLIENTEDGE: DWORD = 0x00000200;
pub const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));

pub const BS_PUSHBUTTON: DWORD = 0x0;
pub const BS_DEFPUSHBUTTON: DWORD = 0x1;
pub const BS_AUTOCHECKBOX: DWORD = 0x3;
pub const ES_MULTILINE: DWORD = 0x4;
pub const ES_AUTOVSCROLL: DWORD = 0x40;
pub const ES_AUTOHSCROLL: DWORD = 0x80;
pub const ES_READONLY: DWORD = 0x800;
pub const PBS_SMOOTH: DWORD = 0x1;

pub const SW_HIDE: c_int = 0;
pub const SW_SHOW: c_int = 5;

pub const SWP_NOSIZE: u32 = 0x1;
pub const SWP_NOMOVE: u32 = 0x2;
pub const SWP_NOZORDER: u32 = 0x4;
pub const SWP_NOACTIVATE: u32 = 0x10;

pub const WM_DESTROY: u32 = 0x0002;
pub const WM_SIZE: u32 = 0x0005;
pub const WM_SETFOCUS: u32 = 0x0007;
pub const WM_PAINT: u32 = 0x000F;
pub const WM_CLOSE: u32 = 0x0010;
pub const WM_ERASEBKGND: u32 = 0x0014;
pub const WM_SETFONT: u32 = 0x0030;
pub const WM_SETICON: u32 = 0x0080;
pub const WM_COMMAND: u32 = 0x0111;
pub const WM_CTLCOLOREDIT: u32 = 0x0133;
pub const WM_CTLCOLORBTN: u32 = 0x0135;
pub const WM_CTLCOLORSTATIC: u32 = 0x0138;
pub const WM_DPICHANGED: u32 = 0x02E0;
pub const WM_PRINTCLIENT: u32 = 0x0318;
pub const WM_QUIT: u32 = 0x0012;
pub const BM_GETCHECK: u32 = 0x00F0;
pub const BM_SETCHECK: u32 = 0x00F1;
pub const BM_SETSTYLE: u32 = 0x00F4;
pub const BST_CHECKED: usize = 1;
pub const BN_CLICKED: u16 = 0;
pub const EN_CHANGE: u16 = 0x0300;
pub const EM_SETSEL: u32 = 0x00B1;
pub const EM_SETLIMITTEXT: u32 = 0x00C5;
pub const EM_SETMARGINS: u32 = 0x00D3;
pub const EC_LEFTMARGIN: usize = 0x1;
pub const EC_RIGHTMARGIN: usize = 0x2;
pub const PBM_SETPOS: u32 = 0x0402;
pub const PBM_SETRANGE32: u32 = 0x0406;
pub const PBM_SETMARQUEE: u32 = 0x040A;
pub const PM_REMOVE: u32 = 0x1;
pub const ICON_SMALL: usize = 0;
pub const ICON_BIG: usize = 1;

pub const IDOK: c_int = 1;
pub const IDCANCEL: c_int = 2;
pub const MB_OKCANCEL: u32 = 0x1;
pub const MB_ICONWARNING: u32 = 0x30;
pub const MB_DEFBUTTON2: u32 = 0x100;

pub const IMAGE_ICON: u32 = 1;
pub const LR_DEFAULTCOLOR: u32 = 0;
pub const LR_SHARED: u32 = 0x8000;
pub const DI_NORMAL: u32 = 0x3;
/// `MAKEINTRESOURCE(32512)`: the standard arrow cursor and application
/// icon.
pub const IDC_ARROW: usize = 32512;
pub const IDI_APPLICATION: usize = 32512;

pub const MONITOR_DEFAULTTONEAREST: DWORD = 0x2;

pub const DT_LEFT: u32 = 0x0;
pub const DT_CENTER: u32 = 0x1;
pub const DT_VCENTER: u32 = 0x4;
pub const DT_WORDBREAK: u32 = 0x10;
pub const DT_SINGLELINE: u32 = 0x20;
pub const DT_NOPREFIX: u32 = 0x800;
pub const DT_CALCRECT: u32 = 0x400;
pub const DT_END_ELLIPSIS: u32 = 0x8000;
pub const DT_PATH_ELLIPSIS: u32 = 0x4000;

pub const TRANSPARENT: c_int = 1;
pub const HALFTONE: c_int = 4;
pub const DIB_RGB_COLORS: u32 = 0;
pub const SRCCOPY: u32 = 0x00CC0020;
pub const FW_NORMAL: c_int = 400;
pub const FW_SEMIBOLD: c_int = 600;
pub const DEFAULT_CHARSET: u32 = 1;
pub const CLEARTYPE_QUALITY: u32 = 5;

pub extern "user32" fn RegisterClassExW(lpwcx: *const WNDCLASSEXW) callconv(.winapi) u16;
pub extern "user32" fn CreateWindowExW(
    dwExStyle: DWORD,
    lpClassName: [*:0]const WCHAR,
    lpWindowName: ?[*:0]const WCHAR,
    dwStyle: DWORD,
    X: i32,
    Y: i32,
    nWidth: i32,
    nHeight: i32,
    hWndParent: ?HWND,
    hMenu: ?*anyopaque,
    hInstance: ?HINSTANCE,
    lpParam: ?*anyopaque,
) callconv(.winapi) ?HWND;
pub extern "user32" fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn GetMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32) callconv(.winapi) c_int;
pub extern "user32" fn PeekMessageW(lpMsg: *MSG, hWnd: ?HWND, wMsgFilterMin: u32, wMsgFilterMax: u32, wRemoveMsg: u32) callconv(.winapi) c_int;
pub extern "user32" fn TranslateMessage(lpMsg: *const MSG) callconv(.winapi) c_int;
pub extern "user32" fn DispatchMessageW(lpMsg: *const MSG) callconv(.winapi) LRESULT;
pub extern "user32" fn IsDialogMessageW(hDlg: HWND, lpMsg: *MSG) callconv(.winapi) c_int;
pub extern "user32" fn PostQuitMessage(nExitCode: c_int) callconv(.winapi) void;
pub extern "user32" fn PostMessageW(hWnd: ?HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) c_int;
pub extern "user32" fn DestroyWindow(hWnd: HWND) callconv(.winapi) c_int;
pub extern "user32" fn ShowWindow(hWnd: HWND, nCmdShow: c_int) callconv(.winapi) c_int;
pub extern "user32" fn SetWindowPos(hWnd: HWND, hWndInsertAfter: ?HWND, X: i32, Y: i32, cx: i32, cy: i32, uFlags: u32) callconv(.winapi) c_int;
pub extern "user32" fn SetWindowTextW(hWnd: HWND, lpString: [*:0]const WCHAR) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextW(hWnd: HWND, lpString: [*]WCHAR, nMaxCount: c_int) callconv(.winapi) c_int;
pub extern "user32" fn GetWindowTextLengthW(hWnd: HWND) callconv(.winapi) c_int;
pub extern "user32" fn EnableWindow(hWnd: HWND, bEnable: c_int) callconv(.winapi) c_int;
pub extern "user32" fn IsWindowEnabled(hWnd: HWND) callconv(.winapi) c_int;
pub extern "user32" fn SendMessageW(hWnd: HWND, Msg: u32, wParam: WPARAM, lParam: LPARAM) callconv(.winapi) LRESULT;
pub extern "user32" fn InvalidateRect(hWnd: HWND, lpRect: ?*const RECT, bErase: c_int) callconv(.winapi) c_int;
pub extern "user32" fn UpdateWindow(hWnd: HWND) callconv(.winapi) c_int;
pub extern "user32" fn BeginPaint(hWnd: HWND, lpPaint: *PAINTSTRUCT) callconv(.winapi) ?HDC;
pub extern "user32" fn EndPaint(hWnd: HWND, lpPaint: *const PAINTSTRUCT) callconv(.winapi) c_int;
pub extern "user32" fn GetClientRect(hWnd: HWND, lpRect: *RECT) callconv(.winapi) c_int;
pub extern "user32" fn LoadCursorW(hInstance: ?HINSTANCE, lpCursorName: usize) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn LoadImageW(hInst: ?HINSTANCE, name: usize, type: u32, cx: c_int, cy: c_int, fuLoad: u32) callconv(.winapi) ?HANDLE;
pub extern "user32" fn DestroyIcon(hIcon: HICON) callconv(.winapi) c_int;
pub extern "user32" fn GetDpiForWindow(hwnd: HWND) callconv(.winapi) u32;
pub extern "user32" fn AdjustWindowRectExForDpi(lpRect: *RECT, dwStyle: DWORD, bMenu: c_int, dwExStyle: DWORD, dpi: u32) callconv(.winapi) c_int;
pub extern "user32" fn MonitorFromWindow(hwnd: HWND, dwFlags: DWORD) callconv(.winapi) ?HMONITOR;
pub extern "user32" fn GetMonitorInfoW(hMonitor: HMONITOR, lpmi: *MONITORINFO) callconv(.winapi) c_int;
pub extern "user32" fn SetFocus(hWnd: ?HWND) callconv(.winapi) ?HWND;
pub extern "user32" fn GetFocus() callconv(.winapi) ?HWND;
pub extern "user32" fn SetForegroundWindow(hWnd: HWND) callconv(.winapi) c_int;
pub extern "user32" fn FillRect(hDC: HDC, lprc: *const RECT, hbr: HGDIOBJ) callconv(.winapi) c_int;
pub extern "user32" fn DrawTextW(hdc: HDC, lpchText: [*]const WCHAR, cchText: c_int, lprc: *RECT, format: u32) callconv(.winapi) c_int;
pub extern "user32" fn DrawIconEx(hdc: HDC, xLeft: c_int, yTop: c_int, hIcon: HICON, cxWidth: c_int, cyWidth: c_int, istepIfAniCur: u32, hbrFlickerFreeDraw: ?HGDIOBJ, diFlags: u32) callconv(.winapi) c_int;

pub extern "gdi32" fn CreateFontW(
    cHeight: c_int,
    cWidth: c_int,
    cEscapement: c_int,
    cOrientation: c_int,
    cWeight: c_int,
    bItalic: u32,
    bUnderline: u32,
    bStrikeOut: u32,
    iCharSet: u32,
    iOutPrecision: u32,
    iClipPrecision: u32,
    iQuality: u32,
    iPitchAndFamily: u32,
    pszFaceName: [*:0]const WCHAR,
) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteObject(ho: HGDIOBJ) callconv(.winapi) c_int;
pub extern "gdi32" fn SelectObject(hdc: HDC, h: HGDIOBJ) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn CreateSolidBrush(color: u32) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn SetBkMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SetBkColor(hdc: HDC, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn SetTextColor(hdc: HDC, color: u32) callconv(.winapi) u32;
pub extern "gdi32" fn CreateCompatibleDC(hdc: ?HDC) callconv(.winapi) ?HDC;
pub extern "gdi32" fn CreateCompatibleBitmap(hdc: HDC, cx: c_int, cy: c_int) callconv(.winapi) ?HGDIOBJ;
pub extern "gdi32" fn DeleteDC(hdc: HDC) callconv(.winapi) c_int;
pub extern "gdi32" fn BitBlt(hdc: HDC, x: c_int, y: c_int, cx: c_int, cy: c_int, hdcSrc: ?HDC, x1: c_int, y1: c_int, rop: u32) callconv(.winapi) c_int;
pub extern "gdi32" fn StretchDIBits(
    hdc: HDC,
    xDest: c_int,
    yDest: c_int,
    DestWidth: c_int,
    DestHeight: c_int,
    xSrc: c_int,
    ySrc: c_int,
    SrcWidth: c_int,
    SrcHeight: c_int,
    lpBits: ?*const anyopaque,
    lpbmi: *const BITMAPINFO,
    iUsage: u32,
    rop: u32,
) callconv(.winapi) c_int;
pub extern "gdi32" fn SetStretchBltMode(hdc: HDC, mode: c_int) callconv(.winapi) c_int;
pub extern "gdi32" fn SetBrushOrgEx(hdc: HDC, x: c_int, y: c_int, lppt: ?*POINT) callconv(.winapi) c_int;

pub extern "comctl32" fn InitCommonControlsEx(picce: *const INITCOMMONCONTROLSEX) callconv(.winapi) c_int;

pub extern "kernel32" fn GetModuleHandleW(lpModuleName: ?[*:0]const WCHAR) callconv(.winapi) ?HINSTANCE;
pub extern "kernel32" fn GetDiskFreeSpaceExW(
    lpDirectoryName: [*:0]const WCHAR,
    lpFreeBytesAvailableToCaller: ?*u64,
    lpTotalNumberOfBytes: ?*u64,
    lpTotalNumberOfFreeBytes: ?*u64,
) callconv(.winapi) c_int;

// ---- The folder picker (IFileOpenDialog with FOS_PICKFOLDERS).

pub const CLSID_FileOpenDialog: GUID = .{ .data1 = 0xDC1C5A9C, .data2 = 0xE88A, .data3 = 0x4DDE, .data4 = .{ 0xA5, 0xA1, 0x60, 0xF8, 0x2A, 0x20, 0xAE, 0xF7 } };
pub const IID_IFileOpenDialog: GUID = .{ .data1 = 0xD57C7288, .data2 = 0xD4AD, .data3 = 0x4768, .data4 = .{ 0xBE, 0x02, 0x9D, 0x96, 0x95, 0x32, 0xD9, 0x60 } };
pub const IID_IShellItem: GUID = .{ .data1 = 0x43826D1E, .data2 = 0xE718, .data3 = 0x42EE, .data4 = .{ 0xBC, 0x55, 0xA1, 0xE2, 0x61, 0xC3, 0x7B, 0xFE } };
pub const FOS_PICKFOLDERS: DWORD = 0x20;
pub const FOS_FORCEFILESYSTEM: DWORD = 0x40;
pub const FOS_PATHMUSTEXIST: DWORD = 0x800;
pub const SIGDN_FILESYSPATH: u32 = 0x80058000;

/// IFileOpenDialog vtable up to `GetResult`, in declaration order
/// (shobjidl_core.h: IUnknown, IModalWindow, IFileDialog).
pub const IFileOpenDialog = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IFileOpenDialog) callconv(.winapi) u32,
        Show: *const fn (*IFileOpenDialog, ?HWND) callconv(.winapi) HRESULT,
        SetFileTypes: Unused,
        SetFileTypeIndex: Unused,
        GetFileTypeIndex: Unused,
        Advise: Unused,
        Unadvise: Unused,
        SetOptions: *const fn (*IFileOpenDialog, DWORD) callconv(.winapi) HRESULT,
        GetOptions: *const fn (*IFileOpenDialog, *DWORD) callconv(.winapi) HRESULT,
        SetDefaultFolder: Unused,
        SetFolder: *const fn (*IFileOpenDialog, *IShellItem) callconv(.winapi) HRESULT,
        GetFolder: Unused,
        GetCurrentSelection: Unused,
        SetFileName: Unused,
        GetFileName: Unused,
        SetTitle: *const fn (*IFileOpenDialog, [*:0]const WCHAR) callconv(.winapi) HRESULT,
        SetOkButtonLabel: Unused,
        SetFileNameLabel: Unused,
        GetResult: *const fn (*IFileOpenDialog, *?*IShellItem) callconv(.winapi) HRESULT,
    },
};

/// IShellItem vtable up to `GetDisplayName` (shobjidl_core.h).
pub const IShellItem = extern struct {
    vtable: *const extern struct {
        QueryInterface: Unused,
        AddRef: Unused,
        Release: *const fn (*IShellItem) callconv(.winapi) u32,
        BindToHandler: Unused,
        GetParent: Unused,
        GetDisplayName: *const fn (*IShellItem, u32, *?[*:0]WCHAR) callconv(.winapi) HRESULT,
    },
};

pub extern "shell32" fn SHCreateItemFromParsingName(pszPath: [*:0]const WCHAR, pbc: ?*anyopaque, riid: *const GUID, ppv: *?*anyopaque) callconv(.winapi) HRESULT;
pub extern "ole32" fn CoTaskMemFree(pv: ?*anyopaque) callconv(.winapi) void;

// ---- List view (commctrl.h)

pub const ICC_LISTVIEW_CLASSES: DWORD = 0x1;
pub const LVS_REPORT: DWORD = 0x1;
pub const LVS_SINGLESEL: DWORD = 0x4;
pub const LVS_SHOWSELALWAYS: DWORD = 0x8;
pub const LVS_NOSORTHEADER: DWORD = 0x8000;
pub const LVS_EX_FULLROWSELECT: usize = 0x20;
pub const LVS_EX_LABELTIP: usize = 0x4000;
pub const LVS_EX_DOUBLEBUFFER: usize = 0x10000;
pub const LVM_DELETEALLITEMS: u32 = 0x1000 + 9;
pub const LVM_SETCOLUMNWIDTH: u32 = 0x1000 + 30;
pub const LVM_SETEXTENDEDLISTVIEWSTYLE: u32 = 0x1000 + 54;
pub const LVM_INSERTITEMW: u32 = 0x1000 + 77;
pub const LVM_INSERTCOLUMNW: u32 = 0x1000 + 97;
pub const LVM_SETITEMTEXTW: u32 = 0x1000 + 116;
pub const LVCF_FMT: u32 = 0x1;
pub const LVCF_WIDTH: u32 = 0x2;
pub const LVCF_TEXT: u32 = 0x4;
pub const LVCF_SUBITEM: u32 = 0x8;
pub const LVCFMT_LEFT: c_int = 0;
pub const LVCFMT_RIGHT: c_int = 1;
pub const LVIF_TEXT: u32 = 0x1;

pub const LVCOLUMNW = extern struct {
    mask: u32 = 0,
    fmt: c_int = 0,
    cx: c_int = 0,
    pszText: ?[*:0]const WCHAR = null,
    cchTextMax: c_int = 0,
    iSubItem: c_int = 0,
    iImage: c_int = 0,
    iOrder: c_int = 0,
    cxMin: c_int = 0,
    cxDefault: c_int = 0,
    cxIdeal: c_int = 0,
};

pub const LVITEMW = extern struct {
    mask: u32 = 0,
    iItem: c_int = 0,
    iSubItem: c_int = 0,
    state: u32 = 0,
    stateMask: u32 = 0,
    pszText: ?[*:0]const WCHAR = null,
    cchTextMax: c_int = 0,
    iImage: c_int = 0,
    lParam: LPARAM = 0,
    iIndent: c_int = 0,
    iGroupId: c_int = 0,
    cColumns: u32 = 0,
    puColumns: ?*u32 = null,
    piColFmt: ?*c_int = null,
    iGroup: c_int = 0,
};

// ---- Restart Manager (restartmanager.h): which processes and services
// have files open.

pub const CCH_RM_SESSION_KEY = 32;

pub const RM_UNIQUE_PROCESS = extern struct {
    dwProcessId: DWORD,
    ProcessStartTime: [2]DWORD,
};

pub const RM_APP_TYPE = enum(c_int) {
    unknown = 0,
    main_window = 1,
    other_window = 2,
    service = 3,
    explorer = 4,
    console = 5,
    critical = 1000,
    _,
};

pub const RM_PROCESS_INFO = extern struct {
    Process: RM_UNIQUE_PROCESS,
    strAppName: [256]WCHAR,
    strServiceShortName: [64]WCHAR,
    ApplicationType: RM_APP_TYPE,
    AppStatus: u32,
    TSSessionId: DWORD,
    bRestartable: c_int,
};

pub extern "rstrtmgr" fn RmStartSession(pSessionHandle: *DWORD, dwSessionFlags: DWORD, strSessionKey: [*]WCHAR) callconv(.winapi) DWORD;
pub extern "rstrtmgr" fn RmEndSession(dwSessionHandle: DWORD) callconv(.winapi) DWORD;
pub extern "rstrtmgr" fn RmRegisterResources(
    dwSessionHandle: DWORD,
    nFiles: u32,
    rgsFileNames: ?[*]const [*:0]const WCHAR,
    nApplications: u32,
    rgApplications: ?[*]const RM_UNIQUE_PROCESS,
    nServices: u32,
    rgsServiceNames: ?[*]const [*:0]const WCHAR,
) callconv(.winapi) DWORD;
pub extern "rstrtmgr" fn RmGetList(
    dwSessionHandle: DWORD,
    pnProcInfoNeeded: *u32,
    pnProcInfo: *u32,
    rgAffectedApps: ?[*]RM_PROCESS_INFO,
    lpdwRebootReasons: *DWORD,
) callconv(.winapi) DWORD;

// ---- Process owners and services

pub const TOKEN_QUERY: DWORD = 0x8;
pub const TokenUser: c_int = 1;
pub const SID_AND_ATTRIBUTES = extern struct { Sid: ?*anyopaque, Attributes: DWORD };

pub extern "advapi32" fn OpenProcessToken(ProcessHandle: HANDLE, DesiredAccess: DWORD, TokenHandle: *?HANDLE) callconv(.winapi) c_int;
pub extern "advapi32" fn GetTokenInformation(TokenHandle: HANDLE, TokenInformationClass: c_int, TokenInformation: ?*anyopaque, TokenInformationLength: DWORD, ReturnLength: *DWORD) callconv(.winapi) c_int;
pub extern "advapi32" fn LookupAccountSidW(
    lpSystemName: ?[*:0]const WCHAR,
    Sid: *anyopaque,
    Name: [*]WCHAR,
    cchName: *DWORD,
    ReferencedDomainName: [*]WCHAR,
    cchReferencedDomainName: *DWORD,
    peUse: *c_int,
) callconv(.winapi) c_int;

pub const SC_HANDLE = *opaque {};
pub const SC_MANAGER_CONNECT: DWORD = 0x1;
pub const SERVICE_QUERY_CONFIG: DWORD = 0x1;
pub const SERVICE_QUERY_STATUS: DWORD = 0x4;
pub const SERVICE_STOP: DWORD = 0x20;
pub const SERVICE_CONTROL_STOP: DWORD = 0x1;
pub const SERVICE_STOPPED: DWORD = 0x1;
pub const ERROR_SERVICE_NOT_ACTIVE: DWORD = 1062;

pub const SERVICE_STATUS = extern struct {
    dwServiceType: DWORD = 0,
    dwCurrentState: DWORD = 0,
    dwControlsAccepted: DWORD = 0,
    dwWin32ExitCode: DWORD = 0,
    dwServiceSpecificExitCode: DWORD = 0,
    dwCheckPoint: DWORD = 0,
    dwWaitHint: DWORD = 0,
};

pub const QUERY_SERVICE_CONFIGW = extern struct {
    dwServiceType: DWORD,
    dwStartType: DWORD,
    dwErrorControl: DWORD,
    lpBinaryPathName: ?[*:0]WCHAR,
    lpLoadOrderGroup: ?[*:0]WCHAR,
    dwTagId: DWORD,
    lpDependencies: ?[*:0]WCHAR,
    lpServiceStartName: ?[*:0]WCHAR,
    lpDisplayName: ?[*:0]WCHAR,
};

pub extern "advapi32" fn OpenSCManagerW(lpMachineName: ?[*:0]const WCHAR, lpDatabaseName: ?[*:0]const WCHAR, dwDesiredAccess: DWORD) callconv(.winapi) ?SC_HANDLE;
pub extern "advapi32" fn OpenServiceW(hSCManager: SC_HANDLE, lpServiceName: [*:0]const WCHAR, dwDesiredAccess: DWORD) callconv(.winapi) ?SC_HANDLE;
pub extern "advapi32" fn CloseServiceHandle(hSCObject: SC_HANDLE) callconv(.winapi) c_int;
pub extern "advapi32" fn QueryServiceConfigW(hService: SC_HANDLE, lpServiceConfig: ?*anyopaque, cbBufSize: DWORD, pcbBytesNeeded: *DWORD) callconv(.winapi) c_int;
pub extern "advapi32" fn ControlService(hService: SC_HANDLE, dwControl: DWORD, lpServiceStatus: *SERVICE_STATUS) callconv(.winapi) c_int;
pub extern "advapi32" fn QueryServiceStatus(hService: SC_HANDLE, lpServiceStatus: *SERVICE_STATUS) callconv(.winapi) c_int;
pub extern "kernel32" fn GetLastError() callconv(.winapi) DWORD;

pub const IDC_WAIT: usize = 32514;
pub extern "user32" fn SetCursor(hCursor: ?HCURSOR) callconv(.winapi) ?HCURSOR;
pub extern "user32" fn MessageBeep(uType: u32) callconv(.winapi) c_int;
