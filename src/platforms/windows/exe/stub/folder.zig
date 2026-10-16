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

//! Securing the install folder.
//!
//! The installer runs as administrator, puts an uninstaller that later
//! runs as administrator in the install folder, and may add the folder to
//! the system PATH. Program Files is safe for that: only administrators
//! can change it. Other places are not. A folder in `C:\` inherits
//! "Modify" for every signed-in user, `C:\ProgramData` lets users add
//! files, and a user can create a folder (or a junction pointing
//! elsewhere) where the installer is about to install.
//!
//! So before installing, `prepare` walks the path to the install folder:
//!
//! - Folders that do not exist yet are created owned by Administrators,
//!   with only SYSTEM and administrators allowed to change them.
//! - A link (junction or symbolic link) anywhere on the path stops the
//!   installation.
//! - An existing folder above the install folder that other users can
//!   rename or replace stops it, unless it is part of the application's
//!   own default path (`Acme` in `C:\Acme\Widget`); those are locked down
//!   like a new folder.
//! - An existing install folder that other users can change is locked
//!   down, with everything in it, when it is empty or holds an earlier
//!   installation of this application. Otherwise the installation stops.
//!
//! Locking works top down on handles opened without following links, so
//! once a folder is locked nobody else can swap what is inside it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const w32 = @import("win32.zig");
const acl = @import("zstaller").exe_acl;

/// Why `prepare` refused, and the folder it is about.
pub const Failure = struct {
    kind: Kind = .none,
    path: []const u8 = "",

    pub const Kind = enum {
        none,
        /// A junction, symbolic link or hard link.
        link,
        /// A folder above the install folder that other users can change.
        others_can_change,
        /// An install folder other users can change that holds files
        /// that are not an earlier installation of this application.
        not_empty,
    };
};

/// SYSTEM and Administrators: full control; Users and app packages: read
/// and run. The same as Program Files, without TrustedInstaller.
const locked_sddl = "O:BAD:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;0x1200a9;;;BU)(A;OICI;0x1200a9;;;AC)";
/// What a folder inside a locked folder inherits.
const inner_dir_sddl = "O:BAD:AI(A;OICIID;FA;;;SY)(A;OICIID;FA;;;BA)(A;OICIID;0x1200a9;;;BU)(A;OICIID;0x1200a9;;;AC)";
/// What a file inside a locked folder inherits.
const inner_file_sddl = "O:BAD:AI(A;ID;FA;;;SY)(A;ID;FA;;;BA)(A;ID;0x1200a9;;;BU)(A;ID;0x1200a9;;;AC)";

/// Makes `dir` safe to install into, creating it if needed (see the file
/// comment). `owned` is how many trailing components of `dir` belong to
/// this application: 1 for the install folder alone, more when `dir` is
/// the default nested location such as `C:\Acme\Widget`. `has_install`
/// says `dir` holds an earlier installation of this application.
/// Returns `error.Refused` with `failure` set when it will not install
/// there.
pub fn prepare(gpa: Allocator, dir: []const u8, owned: usize, has_install: bool, failure: *Failure) !void {
    const root_len = rootLen(dir);
    var segments: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeAny(u8, dir[root_len..], "\\/");
    while (it.next()) |seg| try segments.append(gpa, seg);
    const n = segments.items.len;
    if (n == 0) return;
    // Wine stores no folder permissions and reports every folder as the
    // user's own; and as every program in it runs as that Unix user, there
    // is nobody else to keep out.
    const ntdll: w32.HMODULE = @ptrCast(w32.GetModuleHandleW(std.unicode.utf8ToUtf16LeStringLiteral("ntdll.dll")) orelse return error.Unexpected);
    const under_wine = w32.GetProcAddress(ntdll, "wine_get_version") != null;

    var path: std.ArrayList(u8) = .empty;
    try path.appendSlice(gpa, dir[0..root_len]);
    for (segments.items, 0..) |seg, i| {
        if (path.items.len > 0 and path.items[path.items.len - 1] != '\\') try path.append(gpa, '\\');
        try path.appendSlice(gpa, seg);
        const p = try gpa.dupe(u8, path.items);
        const is_leaf = i + 1 == n;
        const ours = i + owned >= n;
        const rights = if (is_leaf) acl.write_rights else acl.replace_rights;

        var state = try inspect(gpa, p, rights);
        if (state == .unsafe and under_wine) state = .safe;
        if (state == .missing) {
            if (try createLocked(gpa, p)) continue;
            // Someone else created it in the meantime; judge what is there.
            state = try inspect(gpa, p, rights);
        }
        switch (state) {
            .missing => return error.FileNotFound,
            .link => return refuse(failure, .link, p),
            .safe => {},
            .unsafe => if (!ours) {
                return refuse(failure, .others_can_change, p);
            } else if (!is_leaf) {
                // Only the folder itself: what else is in it belongs to
                // other applications.
                try withPrivileges(gpa, p, false, failure);
            } else {
                if (!has_install and !try isEmpty(gpa, p)) return refuse(failure, .not_empty, p);
                try withPrivileges(gpa, p, true, failure);
            },
        }
    }
}

/// Whether `rel` (a path inside the folder `dir`, with `/`) passes
/// through a junction or symbolic link inside `dir`. Deleting such a file
/// would delete a file somewhere else.
pub fn crossesLink(gpa: Allocator, dir: []const u8, rel: []const u8) bool {
    var parent = std.fs.path.dirnamePosix(rel);
    while (parent) |p| : (parent = std.fs.path.dirnamePosix(p)) {
        const full = std.fs.path.join(gpa, &.{ dir, p }) catch return true;
        const attrs = attributes(gpa, full) orelse continue;
        if (attrs & w32.FILE_ATTRIBUTE_REPARSE_POINT != 0) return true;
    }
    return false;
}

fn refuse(failure: *Failure, kind: Failure.Kind, path: []const u8) error{Refused} {
    failure.* = .{ .kind = kind, .path = path };
    return error.Refused;
}

/// The length of the drive or share part of `dir`: `C:\` or
/// `\\server\share\`.
fn rootLen(dir: []const u8) usize {
    if (dir.len >= 3 and dir[1] == ':') return 3;
    if (std.mem.startsWith(u8, dir, "\\\\")) {
        var seps: usize = 0;
        for (dir[2..], 2..) |c, i| {
            if (c == '\\' or c == '/') {
                seps += 1;
                if (seps == 2) return i + 1;
            }
        }
        return dir.len;
    }
    return 0;
}

const State = enum { missing, link, safe, unsafe };

/// Whether `path` exists, is a link, and whether anyone besides SYSTEM and
/// administrators owns it or has any of `rights` on it.
fn inspect(gpa: Allocator, path: []const u8, rights: u32) !State {
    const h = open(gpa, path, w32.READ_CONTROL | w32.FILE_READ_ATTRIBUTES) catch |err| switch (err) {
        error.FileNotFound => return .missing,
        else => return err,
    };
    defer _ = w32.CloseHandle(h);
    var info: w32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (w32.GetFileInformationByHandle(h, &info) == 0) return error.Unexpected;
    if (info.dwFileAttributes & w32.FILE_ATTRIBUTE_REPARSE_POINT != 0) return .link;
    if (info.dwFileAttributes & w32.FILE_ATTRIBUTE_DIRECTORY == 0) return error.NotDir;

    var owner: ?[*]const u8 = null;
    var dacl: ?[*]const u8 = null;
    var sd: ?*anyopaque = null;
    const rc = w32.GetSecurityInfo(h, w32.SE_FILE_OBJECT, w32.OWNER_SECURITY_INFORMATION | w32.DACL_SECURITY_INFORMATION, &owner, null, &dacl, null, &sd);
    if (rc != 0) return error.AccessDenied;
    defer _ = w32.LocalFree(sd);

    const owner_sid: []const u8 = if (owner) |o| o[0 .. 8 + 4 * @as(usize, o[1])] else &.{};
    if (!acl.isTrusted(owner_sid)) return .unsafe;
    const dacl_bytes: ?[]const u8 = if (dacl) |d| d[0..std.mem.readInt(u16, d[2..4], .little)] else null;
    return if (acl.othersHave(dacl_bytes, rights)) .unsafe else .safe;
}

/// Creates the folder `path` locked down. False if it already exists.
fn createLocked(gpa: Allocator, path: []const u8) !bool {
    const sd = try descriptor(locked_sddl);
    defer _ = w32.LocalFree(sd);
    const sa: w32.SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = sd };
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, path);
    if (w32.CreateDirectoryW(path_w.ptr, &sa) != 0) return true;
    return switch (w32.GetLastError()) {
        w32.ERROR_ALREADY_EXISTS => false,
        w32.ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.CreateDirectoryFailed,
    };
}

fn isEmpty(gpa: Allocator, path: []const u8) !bool {
    const pattern = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, try std.fs.path.join(gpa, &.{ path, "*" }));
    var data: w32.WIN32_FIND_DATAW = undefined;
    const find = w32.FindFirstFileW(pattern.ptr, &data);
    if (find == w32.INVALID_HANDLE_VALUE) return true;
    defer _ = w32.FindClose(find);
    while (true) {
        if (!isDotEntry(&data)) return false;
        if (w32.FindNextFileW(find, &data) == 0) return true;
    }
}

const Place = enum { top, inner_dir, inner_file };

/// Locks the folder `path`, and with `recurse` everything in it, with the
/// privileges that let administrators take over files other users own.
fn withPrivileges(gpa: Allocator, path: []const u8, recurse: bool, failure: *Failure) !void {
    var token: ?w32.HANDLE = null;
    if (w32.OpenProcessToken(w32.GetCurrentProcess(), w32.TOKEN_ADJUST_PRIVILEGES | w32.TOKEN_QUERY, &token) == 0) {
        return lock(gpa, path, .top, recurse, failure);
    }
    defer _ = w32.CloseHandle(token.?);
    const names = [_][:0]const u16{
        std.unicode.utf8ToUtf16LeStringLiteral("SeRestorePrivilege"),
        std.unicode.utf8ToUtf16LeStringLiteral("SeTakeOwnershipPrivilege"),
        std.unicode.utf8ToUtf16LeStringLiteral("SeBackupPrivilege"),
    };
    for (names) |name| setPrivilege(token.?, name, true);
    defer for (names) |name| setPrivilege(token.?, name, false);
    return lock(gpa, path, .top, recurse, failure);
}

fn setPrivilege(token: w32.HANDLE, name: [:0]const u16, on: bool) void {
    var tp: w32.TOKEN_PRIVILEGES_1 = .{ .Luid = undefined, .Attributes = if (on) w32.SE_PRIVILEGE_ENABLED else 0 };
    if (w32.LookupPrivilegeValueW(null, name.ptr, &tp.Luid) == 0) return;
    _ = w32.AdjustTokenPrivileges(token, 0, &tp, 0, null, null);
}

/// Gives `path` the Administrators owner and the locked-down permissions
/// (`.top`) or the ones inherited from a locked folder, then, with
/// `recurse`, does the same for what is inside it. Each entry is opened without following links
/// and checked before it is changed; a link stops the walk.
fn lock(gpa: Allocator, path: []const u8, place: Place, recurse: bool, failure: *Failure) !void {
    const h = try open(gpa, path, w32.READ_CONTROL | w32.WRITE_DAC | w32.WRITE_OWNER | w32.FILE_READ_ATTRIBUTES);
    var info: w32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (w32.GetFileInformationByHandle(h, &info) == 0) {
        _ = w32.CloseHandle(h);
        return error.Unexpected;
    }
    const is_dir = info.dwFileAttributes & w32.FILE_ATTRIBUTE_DIRECTORY != 0;
    if (info.dwFileAttributes & w32.FILE_ATTRIBUTE_REPARSE_POINT != 0 or (!is_dir and info.nNumberOfLinks > 1)) {
        _ = w32.CloseHandle(h);
        return refuse(failure, .link, path);
    }
    const sd = try switch (place) {
        .top => descriptor(locked_sddl),
        .inner_dir => descriptor(inner_dir_sddl),
        .inner_file => descriptor(inner_file_sddl),
    };
    defer _ = w32.LocalFree(sd);
    // Unlike SetSecurityInfo, this changes only this entry and does not
    // walk into folders, which would follow links.
    const ok = w32.SetKernelObjectSecurity(h, w32.OWNER_SECURITY_INFORMATION | w32.DACL_SECURITY_INFORMATION, sd.?);
    _ = w32.CloseHandle(h);
    if (ok == 0) return error.AccessDenied;
    if (!is_dir or !recurse) return;

    const pattern = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, try std.fs.path.join(gpa, &.{ path, "*" }));
    var data: w32.WIN32_FIND_DATAW = undefined;
    const find = w32.FindFirstFileW(pattern.ptr, &data);
    if (find == w32.INVALID_HANDLE_VALUE) return;
    defer _ = w32.FindClose(find);
    while (true) {
        if (!isDotEntry(&data)) {
            const name = std.mem.sliceTo(&data.cFileName, 0);
            const child = try std.fs.path.join(gpa, &.{ path, try std.unicode.wtf16LeToWtf8Alloc(gpa, name) });
            const child_place: Place = if (data.dwFileAttributes & w32.FILE_ATTRIBUTE_DIRECTORY != 0) .inner_dir else .inner_file;
            try lock(gpa, child, child_place, true, failure);
        }
        if (w32.FindNextFileW(find, &data) == 0) break;
    }
}

fn isDotEntry(data: *const w32.WIN32_FIND_DATAW) bool {
    const name = std.mem.sliceTo(&data.cFileName, 0);
    return (name.len == 1 and name[0] == '.') or (name.len == 2 and name[0] == '.' and name[1] == '.');
}

fn descriptor(comptime sddl: []const u8) !?*anyopaque {
    var sd: ?*anyopaque = null;
    if (w32.ConvertStringSecurityDescriptorToSecurityDescriptorW(std.unicode.utf8ToUtf16LeStringLiteral(sddl), w32.SDDL_REVISION_1, &sd, null) == 0) {
        return error.SecurityDescriptorFailed;
    }
    return sd;
}

/// Opens `path` (a file or folder) without following a link at its end.
fn open(gpa: Allocator, path: []const u8, access: w32.DWORD) !w32.HANDLE {
    const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, path);
    const h = w32.CreateFileW(path_w.ptr, access, w32.FILE_SHARE_ALL, null, w32.OPEN_EXISTING, w32.FILE_FLAG_BACKUP_SEMANTICS | w32.FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (h == w32.INVALID_HANDLE_VALUE) return switch (w32.GetLastError()) {
        2, w32.ERROR_PATH_NOT_FOUND => error.FileNotFound,
        w32.ERROR_ACCESS_DENIED => error.AccessDenied,
        else => error.Unexpected,
    };
    return h;
}

fn attributes(gpa: Allocator, path: []const u8) ?w32.DWORD {
    const h = open(gpa, path, w32.FILE_READ_ATTRIBUTES) catch return null;
    defer _ = w32.CloseHandle(h);
    var info: w32.BY_HANDLE_FILE_INFORMATION = undefined;
    if (w32.GetFileInformationByHandle(h, &info) == 0) return null;
    return info.dwFileAttributes;
}
