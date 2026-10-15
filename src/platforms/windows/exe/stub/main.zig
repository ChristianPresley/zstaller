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
//! install directory as `uninstall.exe`; run under that name, or with
//! `/uninstall`, it removes the application again.
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
const uninstaller_name = cli.uninstaller_name;
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
    const self_path = std.process.executablePathAlloc(init.io, gpa) catch return @intFromEnum(ExitCode.failure);
    const action = cmd.action orelse cli.defaultAction(self_path);
    const code: ExitCode = switch (action) {
        .help => blk: {
            state.message(config.display_name ++ " " ++ config.version ++ " installer\n\n" ++ cli.help_text, w32.MB_ICONINFORMATION);
            break :blk .success;
        },
        .install => install(state, cmd, self_path) catch |err| state.fail("Installation failed: {t}", .{err}),
        .uninstall => uninstall(state, self_path) catch |err| state.fail("Uninstall failed: {t}", .{err}),
        .cleanup => cleanup(state, cmd.cleanup_dir.?, cmd.wait_handle, self_path),
    };
    return @intFromEnum(code);
}

fn install(s: State, cmd: cli.Command, self_path: []const u8) !ExitCode {
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

    if (try ensureNotRunning(s, dir, .install)) |code| return code;

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

fn uninstall(s: State, self_path: []const u8) !ExitCode {
    // The installed uninstaller removes the directory it is in. The setup
    // program run with /uninstall finds the installation in the registry.
    const dir = if (cli.defaultAction(self_path) == .uninstall)
        std.fs.path.dirname(self_path) orelse return error.NoInstallDir
    else
        readString(s.gpa, uninstall_key_prefix ++ config.registry_key, "InstallLocation") orelse
            return s.fail(config.display_name ++ " is not installed.", .{});
    if (!s.confirm("Remove " ++ config.display_name ++ " and all of its files?")) return .cancelled;
    if (try ensureNotRunning(s, dir, .uninstall)) |code| return code;

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
        // A program that `ensureNotRunning` cannot see, such as an editor,
        // has the file open.
        error.AccessDenied, error.FileBusy => return s.fail(
            "Uninstall failed: {s}\\{s} is in use by another program, so it cannot be removed.\n\n" ++
                "Close the program that is using it, then run the uninstaller again.",
            .{ dir, p },
        ),
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

    // Last, the uninstaller itself and the install directory. Windows
    // cannot delete a running executable, so when that is this process a
    // helper deletes it after this process exits.
    const uninstaller_path = try std.fs.path.join(s.gpa, &.{ dir, uninstaller_name });
    if (std.ascii.eqlIgnoreCase(self_path, uninstaller_path)) {
        removeAfterExit(s, self_path, dir) catch |err| {
            std.debug.print("could not schedule removal of {s}: {t}\n", .{ uninstaller_path, err });
        };
    } else {
        Io.Dir.deleteFileAbsolute(s.io, uninstaller_path) catch {};
        Io.Dir.deleteDirAbsolute(s.io, dir) catch {};
    }

    s.message(config.display_name ++ " was removed.", w32.MB_ICONINFORMATION);
    return .success;
}

fn defaultInstallDir(s: State) ![]const u8 {
    // ProgramW6432 is the native Program Files even from an emulated
    // process; ProgramFiles is the fallback.
    const base = s.env.get("ProgramW6432") orelse s.env.get("ProgramFiles") orelse "C:\\Program Files";
    return std.fs.path.join(s.gpa, &.{ base, config.install_dir_name });
}

const Operation = enum { install, uninstall };

/// Windows cannot replace or delete the files of a running program, so
/// install and uninstall check first, before they change anything, for
/// programs running from `dir`. Returns null when none are left running,
/// else the exit code to stop with. With `config.close_running_apps` the
/// user is asked to force-quit them (silent runs do so without asking);
/// without it, the user is told to close them.
fn ensureNotRunning(s: State, dir: []const u8, op: Operation) !?ExitCode {
    const running = try findRunning(s, dir);
    if (running.len == 0) return null;
    const list = try cli.processList(s.gpa, running);
    const action, const tool = switch (op) {
        .install => .{ "updated", "installer" },
        .uninstall => .{ "uninstalled", "uninstaller" },
    };

    if (!config.close_running_apps) {
        return s.fail(
            config.display_name ++ " cannot be {s} while it is running, because Windows cannot remove files that are in use.\n\n" ++
                "Still running:\n{s}\n\nClose {s}, then run the {s} again.",
            .{ action, list, if (running.len == 1) "it" else "them", tool },
        );
    }
    const question = try std.fmt.allocPrint(
        s.gpa,
        config.display_name ++ " is still running. It must be closed before it can be {s}:\n\n{s}\n\n" ++
            "Force-quit {s} now? Unsaved work in {s} will be lost.",
        .{ action, list, if (running.len == 1) "it" else "them", if (running.len == 1) "it" else "them" },
    );
    if (!s.confirm(question)) return .cancelled;

    for (running) |p| {
        if (!forceQuit(p.pid)) {
            return s.fail("Could not close {s} (process ID {d}).\n\nClose it, then run the {s} again.", .{ p.name, p.pid, tool });
        }
        if (s.silent) std.debug.print("closed {s} (process ID {d})\n", .{ p.name, p.pid });
    }
    return null;
}

/// Other processes whose executable is inside `dir`. Processes this
/// process cannot query (protected system processes) are skipped; none of
/// them run from an application's install directory.
fn findRunning(s: State, dir: []const u8) ![]const cli.RunningProcess {
    const snapshot = w32.CreateToolhelp32Snapshot(w32.TH32CS_SNAPPROCESS, 0);
    if (snapshot == w32.INVALID_HANDLE_VALUE) return &.{};
    defer _ = w32.CloseHandle(snapshot);

    const self_pid = w32.GetCurrentProcessId();
    var found: std.ArrayList(cli.RunningProcess) = .empty;
    var entry: w32.PROCESSENTRY32W = .{ .dwSize = @sizeOf(w32.PROCESSENTRY32W) };
    var more = w32.Process32FirstW(snapshot, &entry) != 0;
    while (more) : (more = w32.Process32NextW(snapshot, &entry) != 0) {
        const pid = entry.th32ProcessID;
        if (pid == 0 or pid == self_pid) continue;
        const image = imagePath(s.gpa, pid) orelse continue;
        if (!cli.isInsideDir(image, dir)) continue;
        try found.append(s.gpa, .{ .pid = pid, .name = cli.processName(image) });
    }
    return found.items;
}

fn imagePath(gpa: Allocator, pid: w32.DWORD) ?[]const u8 {
    const process = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w32.CloseHandle(process);
    var buf: [1024]u16 = undefined;
    var len: w32.DWORD = buf.len;
    if (w32.QueryFullProcessImageNameW(process, 0, &buf, &len) == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..len]) catch null;
}

/// Ends process `pid` and waits up to 10 seconds for it to exit, so its
/// files can be removed. Returns true if it is gone.
fn forceQuit(pid: w32.DWORD) bool {
    const process = w32.OpenProcess(w32.PROCESS_TERMINATE | w32.SYNCHRONIZE, 0, pid) orelse {
        // Either it has exited since it was found, or this process may
        // not end it. `findRunning` could query it, so if that still works
        // it is running.
        const still = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return true;
        _ = w32.CloseHandle(still);
        return false;
    };
    defer _ = w32.CloseHandle(process);
    _ = w32.TerminateProcess(process, 1);
    return w32.WaitForSingleObject(process, 10_000) == w32.WAIT_OBJECT_0;
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

/// Removes the running uninstaller and the install directory once this
/// process has exited. A copy of this program in %TEMP% is started as a
/// hidden helper (`/_cleanup`) with an inherited handle to this process;
/// it waits on that handle, so it works however long this process stays
/// open (for example while the final message box is shown).
fn removeAfterExit(s: State, self_path: []const u8, dir: []const u8) !void {
    const temp = s.env.get("TEMP") orelse s.env.get("TMP") orelse return error.NoTempDir;
    const pid = w32.GetCurrentProcessId();
    const helper_name = try std.fmt.allocPrint(s.gpa, "zstaller-uninstall-{d}.exe", .{pid});
    const helper_path = try std.fs.path.join(s.gpa, &.{ temp, helper_name });
    try Io.Dir.copyFileAbsolute(self_path, helper_path, s.io, .{});
    errdefer Io.Dir.deleteFileAbsolute(s.io, helper_path) catch {};

    const self_handle = w32.OpenProcess(w32.SYNCHRONIZE, 1, pid) orelse return error.OpenProcessFailed;
    defer _ = w32.CloseHandle(self_handle);

    const line = try std.fmt.allocPrint(s.gpa, "\"{s}\" \"/_cleanup={s}\" /_wait={d}", .{
        helper_path, dir, @intFromPtr(self_handle),
    });
    const line_w = try std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, line);
    var si: w32.STARTUPINFOW = .{ .cb = @sizeOf(w32.STARTUPINFOW) };
    var pi: w32.PROCESS_INFORMATION = undefined;
    if (w32.CreateProcessW(null, line_w.ptr, null, null, 1, w32.CREATE_NO_WINDOW, null, null, &si, &pi) == 0) {
        return error.CreateProcessFailed;
    }
    if (pi.hThread) |h| _ = w32.CloseHandle(h);
    if (pi.hProcess) |h| _ = w32.CloseHandle(h);
}

/// The `/_cleanup` helper started by `removeAfterExit`: waits for the
/// uninstaller to exit, deletes it and the install directory (if nothing
/// else is left in it), then has Windows delete this temporary copy at the
/// next restart, as a running program cannot delete itself.
fn cleanup(s: State, dir: []const u8, wait_handle: ?usize, self_path: []const u8) ExitCode {
    if (wait_handle) |h| {
        if (h != 0) {
            const handle: w32.HANDLE = @ptrFromInt(h);
            _ = w32.WaitForSingleObject(handle, w32.INFINITE);
            _ = w32.CloseHandle(handle);
        }
    }
    const uninstaller_path = std.fs.path.join(s.gpa, &.{ dir, uninstaller_name }) catch return .failure;
    // Antivirus scanners may still hold the file briefly after the
    // process has exited.
    var attempt: u32 = 0;
    while (attempt < 50) : (attempt += 1) {
        Io.Dir.deleteFileAbsolute(s.io, uninstaller_path) catch |err| switch (err) {
            error.FileNotFound => break,
            else => {
                w32.Sleep(100);
                continue;
            },
        };
        break;
    }
    Io.Dir.deleteDirAbsolute(s.io, dir) catch {};

    if (std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, self_path)) |self_w| {
        _ = w32.MoveFileExW(self_w.ptr, null, w32.MOVEFILE_DELAY_UNTIL_REBOOT);
    } else |_| {}
    return .success;
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
