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
