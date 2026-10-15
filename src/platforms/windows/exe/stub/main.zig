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

//! Windows EXE installer stub.
//!
//! zstaller compiles this program once per Windows target with the
//! application's files embedded (`@import("payload")`) and its settings
//! baked in (`@import("config")`). The same binary is copied into the
//! install directory as `uninstall.exe`; run with `/uninstall` it removes
//! the application again.
//!
//! The installer installs per machine, so its manifest requests
//! administrator rights and Windows shows a UAC prompt when it starts.

const std = @import("std");
const builtin = @import("builtin");
const zstaller = @import("zstaller");
const config = @import("config");
const payload_bytes = @import("payload").bytes;
const w32 = @import("win32.zig");

const cli = zstaller.exe_cli;
const payload = zstaller.exe_payload;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const manifest_name = ".zstaller-files";
const uninstaller_name = "uninstall.exe";
const uninstall_key_prefix = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\";
const environment_key = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment";

const ExitCode = enum(u8) { success = 0, failure = 1, cancelled = 2, usage = 3 };

const State = struct {
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    silent: bool,

    fn message(s: State, text: []const u8, icon: u32) void {
        if (s.silent) {
            std.debug.print("{s}\n", .{text});
            return;
        }
        _ = messageBox(s.gpa, text, w32.MB_OK | icon);
    }

    fn confirm(s: State, text: []const u8) bool {
        if (s.silent) return true;
        return messageBox(s.gpa, text, w32.MB_YESNO | w32.MB_ICONQUESTION) == w32.IDYES;
    }

    fn fail(s: State, comptime fmt: []const u8, args: anytype) ExitCode {
        const text = std.fmt.allocPrint(s.gpa, fmt, args) catch "Installation failed.";
        s.message(text, w32.MB_ICONERROR);
        return .failure;
    }
};

pub fn main(init: std.process.Init) u8 {
    const gpa = init.arena.allocator();
    const args = init.minimal.args.toSlice(gpa) catch return @intFromEnum(ExitCode.failure);
    var state: State = .{ .gpa = gpa, .io = init.io, .env = init.environ_map, .silent = false };

    const cmd = cli.parse(if (args.len > 0) args[1..] else args) catch {
        state.message("Unrecognized option.\n\n" ++ cli.help_text, w32.MB_ICONERROR);
        return @intFromEnum(ExitCode.usage);
    };
    state.silent = cmd.silent;
    const code: ExitCode = switch (cmd.action) {
        .help => blk: {
            state.message(config.display_name ++ " " ++ config.version ++ " installer\n\n" ++ cli.help_text, w32.MB_ICONINFORMATION);
            break :blk .success;
        },
        .install => install(state, cmd) catch |err| state.fail("Installation failed: {t}", .{err}),
        .uninstall => uninstall(state) catch |err| state.fail("Uninstall failed: {t}", .{err}),
    };
    return @intFromEnum(code);
}

fn install(s: State, cmd: cli.Command) !ExitCode {
    const default_dir = try defaultInstallDir(s);
    const dir = cmd.install_dir orelse default_dir;
    if (!std.fs.path.isAbsolute(dir)) return s.fail("The install directory must be an absolute path: {s}", .{dir});

    const add_to_path = switch (config.add_to_path) {
        .never => false,
        .always => true,
        .optional => cmd.add_to_path orelse if (s.silent) false else s.confirm(
            try std.fmt.allocPrint(s.gpa, "Add {s} to the system PATH so " ++ config.exe_name ++ " can be run from any terminal?", .{dir}),
        ),
    };
    if (!s.confirm(try std.fmt.allocPrint(s.gpa, "Install " ++ config.display_name ++ " " ++ config.version ++ " to {s}?", .{dir}))) {
        return .cancelled;
    }

    var decoded = try payload.decode(s.gpa, payload_bytes);
    defer decoded.deinit(s.gpa);

    try Io.Dir.cwd().createDirPath(s.io, dir);
    var install_dir = try Io.Dir.openDirAbsolute(s.io, dir, .{});
    defer install_dir.close(s.io);

    // Remove files from a previous version that this version no longer
    // ships, so upgrades do not leave stale files behind.
    if (readManifest(s, install_dir)) |old_paths| {
        for (old_paths) |old| {
            const still_shipped = for (decoded.entries) |e| {
                if (std.mem.eql(u8, e.path, old)) break true;
            } else false;
            if (!still_shipped) install_dir.deleteFile(s.io, old) catch {};
        }
    }

    var total_bytes: u64 = 0;
    var manifest: std.ArrayList(u8) = .empty;
    for (decoded.entries) |e| {
        if (std.fs.path.dirnamePosix(e.path)) |parent| try install_dir.createDirPath(s.io, parent);
        try install_dir.writeFile(s.io, .{ .sub_path = e.path, .data = e.data });
        total_bytes += e.data.len;
        try manifest.appendSlice(s.gpa, e.path);
        try manifest.append(s.gpa, '\n');
    }
    try install_dir.writeFile(s.io, .{ .sub_path = manifest_name, .data = manifest.items });

    const self_path = try std.process.executablePathAlloc(s.io, s.gpa);
    const uninstaller_path = try std.fs.path.join(s.gpa, &.{ dir, uninstaller_name });
    if (!std.ascii.eqlIgnoreCase(self_path, uninstaller_path)) {
        try Io.Dir.copyFileAbsolute(self_path, uninstaller_path, s.io, .{});
    }

    const app_path = try std.fs.path.join(s.gpa, &.{ dir, config.exe_name });
    const shortcut_path: ?[]const u8 = if (config.start_menu_shortcut) blk: {
        const icon = if (config.has_icon) uninstaller_path else app_path;
        break :blk createShortcut(s, app_path, dir, icon) catch |err| sc: {
            // The application still works without its shortcut.
            std.debug.print("could not create the Start Menu shortcut: {t}\n", .{err});
            break :sc null;
        };
    } else null;

    try registerUninstall(s, dir, uninstaller_path, total_bytes, add_to_path, shortcut_path);
    if (add_to_path) try editSystemPath(s, dir, .add);

    const done = config.display_name ++ " " ++ config.version ++ " was installed successfully.";
    if (s.silent) {
        s.message(done, w32.MB_ICONINFORMATION);
    } else if (s.confirm(done ++ "\n\nLaunch " ++ config.display_name ++ " now?")) {
        launch(s, app_path, dir);
    }
    return .success;
}

fn uninstall(s: State) !ExitCode {
    const self_path = try std.process.executablePathAlloc(s.io, s.gpa);
    const dir = std.fs.path.dirname(self_path) orelse return error.NoInstallDir;
    if (!s.confirm("Remove " ++ config.display_name ++ " and all of its files?")) return .cancelled;

    var install_dir = try Io.Dir.openDirAbsolute(s.io, dir, .{});
    defer install_dir.close(s.io);

    // Prefer the manifest the installer wrote; fall back to this
    // uninstaller's own payload if it is missing.
    const paths: []const []const u8 = readManifest(s, install_dir) orelse blk: {
        const decoded = try payload.decode(s.gpa, payload_bytes);
        const list = try s.gpa.alloc([]const u8, decoded.entries.len);
        for (decoded.entries, list) |e, *p| p.* = e.path;
        break :blk list;
    };

    if (readDword(uninstall_key_prefix ++ config.registry_key, "ZstallerAddedToPath", s.gpa) == 1) {
        editSystemPath(s, dir, .remove) catch {};
    }

    for (paths) |p| install_dir.deleteFile(s.io, p) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    install_dir.deleteFile(s.io, manifest_name) catch {};
    // Remove now-empty parent directories, deepest first.
    var i = paths.len;
    while (i > 0) {
        i -= 1;
        var parent = std.fs.path.dirnamePosix(paths[i]);
        while (parent) |p| : (parent = std.fs.path.dirnamePosix(p)) {
            install_dir.deleteDir(s.io, p) catch break;
        }
    }

    if (readString(s.gpa, uninstall_key_prefix ++ config.registry_key, "ZstallerShortcut")) |shortcut| {
        Io.Dir.deleteFileAbsolute(s.io, shortcut) catch {};
    }
    deleteKey(s.gpa, uninstall_key_prefix ++ config.registry_key);
    scheduleSelfDelete(s, self_path, dir);

    s.message(config.display_name ++ " was removed.", w32.MB_ICONINFORMATION);
    return .success;
}

fn defaultInstallDir(s: State) ![]const u8 {
    // ProgramW6432 is the native Program Files even from an emulated
    // process; ProgramFiles is the fallback.
    const base = s.env.get("ProgramW6432") orelse s.env.get("ProgramFiles") orelse "C:\\Program Files";
    return std.fs.path.join(s.gpa, &.{ base, config.install_dir_name });
}

fn readManifest(s: State, dir: Io.Dir) ?[]const []const u8 {
    const text = dir.readFileAlloc(s.io, manifest_name, s.gpa, .limited(16 << 20)) catch return null;
    return cli.manifestPaths(s.gpa, text) catch null;
}

fn registerUninstall(s: State, dir: []const u8, uninstaller: []const u8, total_bytes: u64, added_to_path: bool, shortcut: ?[]const u8) !void {
    const key = try createKey(s.gpa, uninstall_key_prefix ++ config.registry_key);
    defer _ = w32.RegCloseKey(key);
    const quoted = try std.fmt.allocPrint(s.gpa, "\"{s}\" /uninstall", .{uninstaller});
    try setString(s.gpa, key, "DisplayName", config.display_name, w32.REG_SZ);
    try setString(s.gpa, key, "DisplayVersion", config.version, w32.REG_SZ);
    if (config.publisher.len > 0) try setString(s.gpa, key, "Publisher", config.publisher, w32.REG_SZ);
    try setString(s.gpa, key, "InstallLocation", dir, w32.REG_SZ);
    try setString(s.gpa, key, "UninstallString", quoted, w32.REG_SZ);
    try setString(s.gpa, key, "QuietUninstallString", try std.fmt.allocPrint(s.gpa, "{s} /S", .{quoted}), w32.REG_SZ);
    try setString(s.gpa, key, "DisplayIcon", try std.fs.path.join(s.gpa, &.{ dir, config.exe_name }), w32.REG_SZ);
    try setDword(s.gpa, key, "NoModify", 1);
    try setDword(s.gpa, key, "NoRepair", 1);
    try setDword(s.gpa, key, "EstimatedSize", @intCast(@min(total_bytes / 1024, std.math.maxInt(u32))));
    try setDword(s.gpa, key, "ZstallerAddedToPath", @intFromBool(added_to_path));
    if (shortcut) |path| try setString(s.gpa, key, "ZstallerShortcut", path, w32.REG_SZ);
}

/// Writes `<ProgramData>\Microsoft\Windows\Start Menu\Programs\<name>.lnk`
/// for all users and returns its path.
fn createShortcut(s: State, target: []const u8, work_dir: []const u8, icon: []const u8) ![]const u8 {
    const program_data = s.env.get("ProgramData") orelse s.env.get("ALLUSERSPROFILE") orelse "C:\\ProgramData";
    const programs = try std.fs.path.join(s.gpa, &.{ program_data, "Microsoft", "Windows", "Start Menu", "Programs" });
    try Io.Dir.cwd().createDirPath(s.io, programs);
    const link_path = try std.fs.path.join(s.gpa, &.{ programs, config.display_name ++ ".lnk" });

    const hr_init = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);
    if (hr_init < 0) return error.ComInitFailed;
    defer w32.CoUninitialize();

    var obj: ?*anyopaque = null;
    if (w32.CoCreateInstance(&w32.CLSID_ShellLink, null, w32.CLSCTX_INPROC_SERVER, &w32.IID_IShellLinkW, &obj) < 0) return error.ShellLinkUnavailable;
    const link: *w32.IShellLinkW = @ptrCast(@alignCast(obj.?));
    defer _ = link.vtable.Release(link);

    if (link.vtable.SetPath(link, try wide(s.gpa, target)) < 0) return error.ShortcutFailed;
    if (link.vtable.SetWorkingDirectory(link, try wide(s.gpa, work_dir)) < 0) return error.ShortcutFailed;
    if (link.vtable.SetIconLocation(link, try wide(s.gpa, icon), 0) < 0) return error.ShortcutFailed;
    if (config.description.len > 0) _ = link.vtable.SetDescription(link, try wide(s.gpa, config.description));

    var pf_obj: ?*anyopaque = null;
    if (link.vtable.QueryInterface(link, &w32.IID_IPersistFile, &pf_obj) < 0) return error.ShortcutFailed;
    const pf: *w32.IPersistFile = @ptrCast(@alignCast(pf_obj.?));
    defer _ = pf.vtable.Release(pf);
    if (pf.vtable.Save(pf, try wide(s.gpa, link_path), 1) < 0) return error.ShortcutFailed;
    return link_path;
}

/// Starts the installed application in its own window.
fn launch(s: State, app_path: []const u8, dir: []const u8) void {
    const file_w = wide(s.gpa, app_path) catch return;
    const dir_w = wide(s.gpa, dir) catch return;
    const verb_w = wide(s.gpa, "open") catch return;
    _ = w32.ShellExecuteW(null, verb_w, file_w, null, dir_w, w32.SW_SHOWNORMAL);
}

fn wide(gpa: Allocator, text: []const u8) ![:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, text);
}

const PathEdit = enum { add, remove };

fn editSystemPath(s: State, dir: []const u8, edit: PathEdit) !void {
    const key = try createKey(s.gpa, environment_key);
    defer _ = w32.RegCloseKey(key);
    const current = try queryString(s.gpa, key, "Path");
    const updated = switch (edit) {
        .add => try cli.pathAppend(s.gpa, current, dir),
        .remove => try cli.pathRemove(s.gpa, current, dir),
    } orelse return;
    try setString(s.gpa, key, "Path", updated, w32.REG_EXPAND_SZ);
    const env_w = std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, "Environment") catch return;
    _ = w32.SendMessageTimeoutW(w32.HWND_BROADCAST, w32.WM_SETTINGCHANGE, 0, @bitCast(@intFromPtr(env_w.ptr)), w32.SMTO_ABORTIFHUNG, 5000, null);
}

/// The running uninstaller cannot delete its own file, so it starts a
/// hidden cmd.exe that waits briefly, then deletes the file and the (now
/// empty) install directory.
fn scheduleSelfDelete(s: State, self_path: []const u8, dir: []const u8) void {
    var sys_buf: [260]u16 = undefined;
    const n = w32.GetSystemDirectoryW(&sys_buf, sys_buf.len);
    if (n == 0 or n >= sys_buf.len) return;
    const sys_dir = std.unicode.wtf16LeToWtf8Alloc(s.gpa, sys_buf[0..n]) catch return;
    const cmd_exe = std.fs.path.join(s.gpa, &.{ sys_dir, "cmd.exe" }) catch return;
    const line = std.fmt.allocPrint(
        s.gpa,
        "\"{s}\" /d /s /c \"ping -n 3 127.0.0.1 >nul & del /f /q \"{s}\" & rmdir \"{s}\"\"",
        .{ cmd_exe, self_path, dir },
    ) catch return;
    const line_w = std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, line) catch return;
    var si: w32.STARTUPINFOW = .{ .cb = @sizeOf(w32.STARTUPINFOW) };
    var pi: w32.PROCESS_INFORMATION = undefined;
    if (w32.CreateProcessW(null, line_w.ptr, null, null, 0, w32.CREATE_NO_WINDOW, null, null, &si, &pi) != 0) {
        if (pi.hThread) |h| _ = w32.CloseHandle(h);
        if (pi.hProcess) |h| _ = w32.CloseHandle(h);
    }
}

fn messageBox(gpa: Allocator, text: []const u8, flags: u32) c_int {
    const text_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, text) catch return 0;
    const title_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, config.display_name ++ " Setup") catch return 0;
    return w32.MessageBoxW(null, text_w.ptr, title_w.ptr, flags);
}

fn createKey(gpa: Allocator, sub_key: []const u8) !w32.HKEY {
    const sub_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, sub_key);
    var key: w32.HKEY = undefined;
    const rc = w32.RegCreateKeyExW(w32.HKEY_LOCAL_MACHINE, sub_w.ptr, 0, null, w32.REG_OPTION_NON_VOLATILE, w32.KEY_ALL_ACCESS | w32.KEY_WOW64_64KEY, null, &key, null);
    if (rc != w32.ERROR_SUCCESS) return error.RegistryAccessDenied;
    return key;
}

fn deleteKey(gpa: Allocator, sub_key: []const u8) void {
    const sub_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, sub_key) catch return;
    _ = w32.RegDeleteKeyExW(w32.HKEY_LOCAL_MACHINE, sub_w.ptr, w32.KEY_WOW64_64KEY, 0);
}

fn setString(gpa: Allocator, key: w32.HKEY, name: []const u8, value: []const u8, kind: w32.DWORD) !void {
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, name);
    const value_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, value);
    const bytes = std.mem.sliceAsBytes(value_w[0 .. value_w.len + 1]);
    if (w32.RegSetValueExW(key, name_w.ptr, 0, kind, bytes.ptr, @intCast(bytes.len)) != w32.ERROR_SUCCESS)
        return error.RegistryWriteFailed;
}

fn setDword(gpa: Allocator, key: w32.HKEY, name: []const u8, value: u32) !void {
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, name);
    const bytes = std.mem.asBytes(&value);
    if (w32.RegSetValueExW(key, name_w.ptr, 0, w32.REG_DWORD, bytes.ptr, bytes.len) != w32.ERROR_SUCCESS)
        return error.RegistryWriteFailed;
}

fn queryString(gpa: Allocator, key: w32.HKEY, name: []const u8) ![]const u8 {
    const name_w = try std.unicode.wtf8ToWtf16LeAllocZ(gpa, name);
    var size: w32.DWORD = 0;
    var kind: w32.DWORD = 0;
    var rc = w32.RegQueryValueExW(key, name_w.ptr, null, &kind, null, &size);
    if (rc == w32.ERROR_FILE_NOT_FOUND) return "";
    if (rc != w32.ERROR_SUCCESS) return error.RegistryReadFailed;
    const buf = try gpa.alloc(u16, size / 2 + 1);
    var cb: w32.DWORD = @intCast(buf.len * 2);
    rc = w32.RegQueryValueExW(key, name_w.ptr, null, &kind, @ptrCast(buf.ptr), &cb);
    if (rc != w32.ERROR_SUCCESS) return error.RegistryReadFailed;
    var len = cb / 2;
    while (len > 0 and buf[len - 1] == 0) len -= 1;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..len]);
}

fn readString(gpa: Allocator, sub_key: []const u8, name: []const u8) ?[]const u8 {
    const sub_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, sub_key) catch return null;
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_LOCAL_MACHINE, sub_w.ptr, 0, w32.KEY_QUERY_VALUE | w32.KEY_WOW64_64KEY, &key) != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(key);
    const value = queryString(gpa, key, name) catch return null;
    return if (value.len == 0) null else value;
}

fn readDword(sub_key: []const u8, name: []const u8, gpa: Allocator) ?u32 {
    const sub_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, sub_key) catch return null;
    const name_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, name) catch return null;
    var key: w32.HKEY = undefined;
    if (w32.RegOpenKeyExW(w32.HKEY_LOCAL_MACHINE, sub_w.ptr, 0, w32.KEY_QUERY_VALUE | w32.KEY_WOW64_64KEY, &key) != w32.ERROR_SUCCESS) return null;
    defer _ = w32.RegCloseKey(key);
    var value: u32 = 0;
    var cb: w32.DWORD = @sizeOf(u32);
    if (w32.RegQueryValueExW(key, name_w.ptr, null, null, @ptrCast(&value), &cb) != w32.ERROR_SUCCESS) return null;
    return value;
}

comptime {
    if (builtin.os.tag != .windows) @compileError("the installer stub only targets Windows");
}
