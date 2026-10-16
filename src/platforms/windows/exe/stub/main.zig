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
//! Run normally it shows a wizard (`wizard.zig`); with `/S` it works
//! silently and reports through its exit code and standard error.
//!
//! The installer installs per machine, so its manifest requests
//! administrator rights and Windows shows a UAC prompt when it starts.

const std = @import("std");
const builtin = @import("builtin");
const zstaller = @import("zstaller");
const config = @import("config");
const payload_bytes = @import("payload").bytes;
const w32 = @import("win32.zig");
const wizard = @import("wizard.zig");

const cli = zstaller.exe_cli;
const payload = zstaller.exe_payload;
const Allocator = std.mem.Allocator;
const Io = std.Io;

const manifest_name = ".zstaller-files";
const uninstaller_name = cli.uninstaller_name;
const uninstall_key_prefix = "Software\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\";
pub const uninstall_key = uninstall_key_prefix ++ config.registry_key;
const environment_key = "SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment";

pub const ExitCode = enum(u8) { success = 0, failure = 1, cancelled = 2, usage = 3 };

pub const State = struct {
    gpa: Allocator,
    io: Io,
    env: *std.process.Environ.Map,
    silent: bool,
    /// The wizard window, which owns any message box.
    owner: ?w32.HWND = null,
    /// What went wrong, set by `report` for the caller to show.
    failure: ?[]const u8 = null,

    pub fn message(s: *const State, text: []const u8, icon: u32) void {
        if (s.silent) {
            std.debug.print("{s}\n", .{text});
            return;
        }
        _ = messageBox(s.gpa, s.owner, text, w32.MB_OK | icon);
    }

    pub fn confirm(s: *const State, text: []const u8) bool {
        if (s.silent) return true;
        return messageBox(s.gpa, s.owner, text, w32.MB_YESNO | w32.MB_ICONQUESTION) == w32.IDYES;
    }

    pub fn fail(s: *const State, comptime fmt: []const u8, args: anytype) ExitCode {
        const text = std.fmt.allocPrint(s.gpa, fmt, args) catch "Installation failed.";
        s.message(text, w32.MB_ICONERROR);
        return .failure;
    }

    /// Records why an install or uninstall step failed and returns
    /// `error.Reported`; the caller shows `failure`.
    pub fn report(s: *State, comptime fmt: []const u8, args: anytype) error{ Reported, OutOfMemory } {
        s.failure = try std.fmt.allocPrint(s.gpa, fmt, args);
        return error.Reported;
    }

    /// The text to show for an error from `applyInstall` or
    /// `applyUninstall`.
    pub fn failureText(s: *const State, err: anyerror, comptime what: []const u8) []const u8 {
        if (err == error.Reported) if (s.failure) |f| return f;
        return std.fmt.allocPrint(s.gpa, what ++ " failed: {t}", .{err}) catch what ++ " failed.";
    }
};

/// Reports progress of `applyInstall` and `applyUninstall`.
pub const Progress = struct {
    ctx: *anyopaque,
    func: *const fn (ctx: *anyopaque, done: u64, total: u64, item: []const u8) void,

    fn step(p: ?Progress, done: u64, total: u64, item: []const u8) void {
        if (p) |x| x.func(x.ctx, done, total, item);
    }
};

/// What to install, and where.
pub const Plan = struct {
    dir: []const u8,
    add_to_path: bool,
    desktop_shortcut: bool,
};

pub fn main(init: std.process.Init) u8 {
    // setup.exe usually runs elevated from the Downloads folder. Keep any
    // DLL Windows loads on our behalf from now on out of that folder, so a
    // file planted next to the installer cannot run as administrator.
    _ = w32.SetDefaultDllDirectories(w32.LOAD_LIBRARY_SEARCH_SYSTEM32);
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
        .install => if (state.silent)
            installSilent(&state, cmd, self_path) catch |err| state.fail("Installation failed: {t}", .{err})
        else
            wizard.runInstall(&state, cmd, self_path),
        .uninstall => blk: {
            const dir = uninstallDir(&state, self_path) orelse
                break :blk state.fail(config.display_name ++ " is not installed.", .{});
            break :blk if (state.silent)
                uninstallSilent(&state, dir, self_path)
            else
                wizard.runUninstall(&state, dir, self_path);
        },
        .cleanup => cleanup(&state, cmd.cleanup_dir.?, cmd.wait_handle, self_path),
    };
    return @intFromEnum(code);
}

/// The install directory a new installation goes to: the one an earlier
/// version was installed in, else the configured default.
pub fn defaultInstallDir(s: *const State) ![]const u8 {
    if (readString(s.gpa, uninstall_key, "InstallLocation")) |previous| {
        if (cli.isValidInstallDir(previous)) return previous;
    }
    return cli.defaultInstallDir(s.gpa, @field(cli.InstallRoot, @tagName(config.install_root)), s.env, config.install_dir_name);
}

/// The version already installed, if any.
pub fn installedVersion(s: *const State) ?[]const u8 {
    if (readString(s.gpa, uninstall_key, "InstallLocation") == null) return null;
    return readString(s.gpa, uninstall_key, "DisplayVersion");
}

/// Size of the installed files, from the payload header.
pub fn payloadSize() u64 {
    if (payload_bytes.len < 16) return 0;
    return std.mem.readInt(u64, payload_bytes[8..16], .little);
}

fn installSilent(s: *State, cmd: cli.Command, self_path: []const u8) !ExitCode {
    const dir = cmd.install_dir orelse try defaultInstallDir(s);
    if (!cli.isValidInstallDir(dir)) return s.fail("The install directory must be a full path, such as C:\\Apps\\Example: {s}", .{dir});
    const plan: Plan = .{
        .dir = dir,
        .add_to_path = switch (config.add_to_path) {
            .never => false,
            .always => true,
            .optional => cmd.add_to_path orelse false,
        },
        .desktop_shortcut = switch (config.desktop_shortcut) {
            .never => false,
            .always => true,
            .optional => cmd.desktop_shortcut orelse false,
        },
    };
    if (try ensureNotRunning(s, dir, .install)) |code| return code;
    applyInstall(s, plan, self_path, null) catch |err| {
        s.message(s.failureText(err, "Installation"), w32.MB_ICONERROR);
        return .failure;
    };
    s.message(config.display_name ++ " " ++ config.version ++ " was installed successfully.", w32.MB_ICONINFORMATION);
    return .success;
}

fn uninstallSilent(s: *State, dir: []const u8, self_path: []const u8) ExitCode {
    if (ensureNotRunning(s, dir, .uninstall) catch |err| return s.fail("Uninstall failed: {t}", .{err})) |code| return code;
    applyUninstall(s, dir, self_path, null) catch |err| {
        s.message(s.failureText(err, "Uninstall"), w32.MB_ICONERROR);
        return .failure;
    };
    s.message(config.display_name ++ " was removed.", w32.MB_ICONINFORMATION);
    return .success;
}

/// The directory to uninstall from. The installed uninstaller removes the
/// directory it is in; the setup program run with /uninstall finds the
/// installation in the registry.
fn uninstallDir(s: *const State, self_path: []const u8) ?[]const u8 {
    if (cli.defaultAction(self_path) == .uninstall) return std.fs.path.dirname(self_path);
    return readString(s.gpa, uninstall_key, "InstallLocation");
}

/// Installs the payload as `plan` says. Errors that need explaining are
/// recorded with `State.report`.
pub fn applyInstall(s: *State, plan: Plan, self_path: []const u8, progress: ?Progress) !void {
    const dir = plan.dir;
    const total = payloadSize();
    Progress.step(progress, 0, total, "Preparing files...");
    var decoded = try payload.decode(s.gpa, payload_bytes);
    defer decoded.deinit(s.gpa);

    Io.Dir.cwd().createDirPath(s.io, dir) catch |err|
        return s.report("Could not create the folder {s}: {t}", .{ dir, err });
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
        Progress.step(progress, total_bytes, total, e.path);
        if (std.fs.path.dirnamePosix(e.path)) |parent| try install_dir.createDirPath(s.io, parent);
        install_dir.writeFile(s.io, .{ .sub_path = e.path, .data = e.data }) catch |err| switch (err) {
            error.AccessDenied, error.FileBusy => return s.report(
                "{s}\\{s} is in use by another program, so it cannot be replaced.\n\n" ++
                    "Close the program that is using it, then run Setup again.",
                .{ dir, e.path },
            ),
            else => return err,
        };
        total_bytes += e.data.len;
        try manifest.appendSlice(s.gpa, e.path);
        try manifest.append(s.gpa, '\n');
    }
    try install_dir.writeFile(s.io, .{ .sub_path = manifest_name, .data = manifest.items });

    Progress.step(progress, total_bytes, total, "Creating shortcuts...");
    const uninstaller_path = try std.fs.path.join(s.gpa, &.{ dir, uninstaller_name });
    if (!std.ascii.eqlIgnoreCase(self_path, uninstaller_path)) {
        try Io.Dir.copyFileAbsolute(self_path, uninstaller_path, s.io, .{});
    }

    const app_path = try std.fs.path.join(s.gpa, &.{ dir, config.exe_name });
    const icon = if (config.has_icon) uninstaller_path else app_path;
    var shortcuts: Shortcuts = .{};
    if (config.start_menu_shortcut) {
        shortcuts.start_menu = createShortcut(s, try startMenuDir(s), app_path, dir, icon) catch |err| sc: {
            // The application still works without its shortcut.
            std.debug.print("could not create the Start Menu shortcut: {t}\n", .{err});
            break :sc null;
        };
    }
    if (plan.desktop_shortcut) {
        shortcuts.desktop = createShortcut(s, try desktopDir(s), app_path, dir, icon) catch |err| sc: {
            std.debug.print("could not create the desktop shortcut: {t}\n", .{err});
            break :sc null;
        };
    }

    Progress.step(progress, total_bytes, total, "Registering " ++ config.display_name ++ "...");
    try registerUninstall(s, dir, uninstaller_path, total_bytes, plan.add_to_path, shortcuts);
    if (plan.add_to_path) try editSystemPath(s, dir, .add);
    Progress.step(progress, total, total, "");
}

/// Removes the installation in `dir`. Errors that need explaining are
/// recorded with `State.report`.
pub fn applyUninstall(s: *State, dir: []const u8, self_path: []const u8, progress: ?Progress) !void {
    var install_dir = Io.Dir.openDirAbsolute(s.io, dir, .{}) catch |err|
        return s.report("Could not open {s}: {t}", .{ dir, err });
    defer install_dir.close(s.io);

    // Prefer the manifest the installer wrote; fall back to this
    // uninstaller's own payload if it is missing.
    const paths: []const []const u8 = readManifest(s, install_dir) orelse blk: {
        const decoded = try payload.decode(s.gpa, payload_bytes);
        const list = try s.gpa.alloc([]const u8, decoded.entries.len);
        for (decoded.entries, list) |e, *p| p.* = e.path;
        break :blk list;
    };

    if (readDword(uninstall_key, "ZstallerAddedToPath", s.gpa) == 1) {
        editSystemPath(s, dir, .remove) catch {};
    }

    for (paths, 0..) |p, i| {
        Progress.step(progress, i, paths.len, p);
        install_dir.deleteFile(s.io, p) catch |err| switch (err) {
            error.FileNotFound => {},
            // A program that `findInUse` cannot see has the file open.
            error.AccessDenied, error.FileBusy => return s.report(
                "{s}\\{s} is in use by another program, so it cannot be removed.\n\n" ++
                    "Close the program that is using it, then run the uninstaller again.",
                .{ dir, p },
            ),
            else => return err,
        };
    }
    Progress.step(progress, paths.len, paths.len, "Removing shortcuts...");
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

    for ([_][]const u8{ "ZstallerShortcut", "ZstallerDesktopShortcut" }) |value| {
        if (readString(s.gpa, uninstall_key, value)) |shortcut| {
            Io.Dir.deleteFileAbsolute(s.io, shortcut) catch {};
        }
    }
    deleteKey(s.gpa, uninstall_key);

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
    Progress.step(progress, paths.len, paths.len, "");
}

pub const Operation = enum { install, uninstall };

/// Windows cannot replace or delete files that are in use, so install and
/// uninstall check first, before they change anything, for programs
/// using the installation in `dir`. Returns null when none are left,
/// else the exit code to stop with. With `config.close_running_apps`
/// they are closed (silent runs do so without asking); without it, the
/// user is told to close them. The wizard shows its own page instead.
pub fn ensureNotRunning(s: *const State, dir: []const u8, op: Operation) !?ExitCode {
    const running = try findInUse(s, dir);
    if (running.len == 0) return null;
    const list = try cli.processList(s.gpa, running);
    const action, const tool = switch (op) {
        .install => .{ "updated", "installer" },
        .uninstall => .{ "uninstalled", "uninstaller" },
    };

    if (!config.close_running_apps) {
        return s.fail(
            config.display_name ++ " cannot be {s} while its files are in use.\n\n" ++
                "In use by:\n{s}\n\nClose {s}, then run the {s} again.",
            .{ action, list, if (running.len == 1) "it" else "them", tool },
        );
    }
    const question = try std.fmt.allocPrint(
        s.gpa,
        "These programs are using " ++ config.display_name ++ "'s files and must be closed before it can be {s}:\n\n{s}\n\n" ++
            "Close {s} now? Unsaved work in {s} will be lost.",
        .{ action, list, if (running.len == 1) "it" else "them", if (running.len == 1) "it" else "them" },
    );
    if (!s.confirm(question)) return .cancelled;

    if (closePrograms(running)) |p| {
        var buf: [256]u8 = undefined;
        return s.fail("Could not close {s} (process ID {d}).\n\nClose it, then run the {s} again.", .{ p.label(&buf), p.pid, tool });
    }
    if (s.silent) for (running) |p| {
        var buf: [256]u8 = undefined;
        std.debug.print("closed {s} (process ID {d})\n", .{ p.label(&buf), p.pid });
    };
    return null;
}

/// The programs keeping the installation in `dir` in use: every other
/// process whose executable is inside `dir`, and every process or service
/// Windows (the Restart Manager) reports as having one of its installed
/// files open. Processes this process cannot query (protected system
/// processes) are skipped; none of them run from an install directory.
pub fn findInUse(s: *const State, dir: []const u8) ![]const cli.RunningProcess {
    const self_pid = w32.GetCurrentProcessId();
    var found: std.ArrayList(cli.RunningProcess) = .empty;

    const snapshot = w32.CreateToolhelp32Snapshot(w32.TH32CS_SNAPPROCESS, 0);
    if (snapshot != w32.INVALID_HANDLE_VALUE) {
        defer _ = w32.CloseHandle(snapshot);
        var entry: w32.PROCESSENTRY32W = .{ .dwSize = @sizeOf(w32.PROCESSENTRY32W) };
        var more = w32.Process32FirstW(snapshot, &entry) != 0;
        while (more) : (more = w32.Process32NextW(snapshot, &entry) != 0) {
            const pid = entry.th32ProcessID;
            if (pid == 0 or pid == self_pid) continue;
            const image = imagePath(s.gpa, pid) orelse continue;
            if (!cli.isInsideDir(image, dir)) continue;
            try cli.addProcess(s.gpa, &found, .{
                .pid = pid,
                .name = cli.processName(image),
                .path = image,
                .user = processUser(s.gpa, pid) orelse "",
            });
        }
    }

    for (try lockingProcesses(s, dir)) |info| {
        const pid = info.Process.dwProcessId;
        if (pid == 0 or pid == self_pid) continue;
        const service: ?[]const u8 = if (info.ApplicationType == .service)
            wideField(s.gpa, &info.strServiceShortName)
        else
            null;
        const image = imagePath(s.gpa, pid);
        const name = if (image) |i| cli.processName(i) else wideField(s.gpa, &info.strAppName) orelse continue;
        const user = processUser(s.gpa, pid) orelse
            (if (service) |svc| serviceAccount(s.gpa, svc) else null) orelse "";
        try cli.addProcess(s.gpa, &found, .{
            .pid = pid,
            .name = name,
            .path = image orelse "",
            .user = user,
            .service = service,
        });
    }
    return found.items;
}

/// What the Restart Manager reports as using the files installed in
/// `dir`. Empty when nothing is installed there or the check fails.
fn lockingProcesses(s: *const State, dir: []const u8) ![]const w32.RM_PROCESS_INFO {
    var install_dir = Io.Dir.openDirAbsolute(s.io, dir, .{}) catch return &.{};
    defer install_dir.close(s.io);
    const paths = readManifest(s, install_dir) orelse return &.{};

    var files: std.ArrayList([*:0]const u16) = .empty;
    for (paths) |p| {
        const full = try std.fs.path.join(s.gpa, &.{ dir, p });
        std.mem.replaceScalar(u8, full, '/', '\\');
        try files.append(s.gpa, std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, full) catch continue);
    }
    if (files.items.len == 0) return &.{};

    const rm = w32.RestartManager.load() orelse return &.{};
    var session: w32.DWORD = 0;
    var key: [w32.CCH_RM_SESSION_KEY + 1]u16 = @splat(0);
    if (rm.RmStartSession(&session, 0, &key) != 0) return &.{};
    defer _ = rm.RmEndSession(session);
    if (rm.RmRegisterResources(session, @intCast(files.items.len), files.items.ptr, 0, null, 0, null) != 0) return &.{};

    var infos: []w32.RM_PROCESS_INFO = &.{};
    // The list can grow between the size query and the read; retry a few
    // times.
    for (0..4) |_| {
        var needed: u32 = 0;
        var count: u32 = @intCast(infos.len);
        var reasons: w32.DWORD = 0;
        switch (rm.RmGetList(session, &needed, &count, if (infos.len > 0) infos.ptr else null, &reasons)) {
            0 => return infos[0..@min(count, infos.len)],
            @as(w32.DWORD, @intCast(w32.ERROR_MORE_DATA)) => infos = try s.gpa.alloc(w32.RM_PROCESS_INFO, needed + 4),
            else => return &.{},
        }
    }
    return &.{};
}

/// Closes each of `procs`: services are stopped through the service
/// manager, other programs are ended. Returns the first one that is
/// still running, or null when all are closed.
pub fn closePrograms(procs: []const cli.RunningProcess) ?cli.RunningProcess {
    for (procs) |p| {
        const closed = if (p.service) |svc| stopService(svc) and waitForExit(p.pid) else forceQuit(p.pid);
        if (!closed) return p;
    }
    return null;
}

fn imagePath(gpa: Allocator, pid: w32.DWORD) ?[]const u8 {
    const process = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w32.CloseHandle(process);
    var buf: [1024]u16 = undefined;
    var len: w32.DWORD = buf.len;
    if (w32.QueryFullProcessImageNameW(process, 0, &buf, &len) == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, buf[0..len]) catch null;
}

/// The account process `pid` runs as, as `DOMAIN\name`.
fn processUser(gpa: Allocator, pid: w32.DWORD) ?[]const u8 {
    const process = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return null;
    defer _ = w32.CloseHandle(process);
    var token: ?w32.HANDLE = null;
    if (w32.OpenProcessToken(process, w32.TOKEN_QUERY, &token) == 0) return null;
    defer _ = w32.CloseHandle(token.?);
    var buf: [256]u8 align(@alignOf(w32.SID_AND_ATTRIBUTES)) = undefined;
    var len: w32.DWORD = 0;
    if (w32.GetTokenInformation(token.?, w32.TokenUser, &buf, buf.len, &len) == 0) return null;
    const user: *const w32.SID_AND_ATTRIBUTES = @ptrCast(&buf);
    var name: [256]u16 = undefined;
    var name_len: w32.DWORD = name.len;
    var domain: [256]u16 = undefined;
    var domain_len: w32.DWORD = domain.len;
    var use: c_int = 0;
    if (w32.LookupAccountSidW(null, user.Sid orelse return null, &name, &name_len, &domain, &domain_len, &use) == 0) return null;
    const n = std.unicode.wtf16LeToWtf8Alloc(gpa, name[0..name_len]) catch return null;
    if (domain_len == 0) return n;
    const d = std.unicode.wtf16LeToWtf8Alloc(gpa, domain[0..domain_len]) catch return null;
    return std.fmt.allocPrint(gpa, "{s}\\{s}", .{ d, n }) catch null;
}

/// The account service `name` is configured to run as, such as
/// `LocalSystem` or `NT AUTHORITY\LocalService`.
fn serviceAccount(gpa: Allocator, name: []const u8) ?[]const u8 {
    const manager = w32.OpenSCManagerW(null, null, w32.SC_MANAGER_CONNECT) orelse return null;
    defer _ = w32.CloseServiceHandle(manager);
    const name_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, name) catch return null;
    const service = w32.OpenServiceW(manager, name_w.ptr, w32.SERVICE_QUERY_CONFIG) orelse return null;
    defer _ = w32.CloseServiceHandle(service);
    var buf: [8192]u8 align(@alignOf(w32.QUERY_SERVICE_CONFIGW)) = undefined;
    var needed: w32.DWORD = 0;
    if (w32.QueryServiceConfigW(service, &buf, buf.len, &needed) == 0) return null;
    const cfg: *const w32.QUERY_SERVICE_CONFIGW = @ptrCast(&buf);
    const account = cfg.lpServiceStartName orelse return null;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, std.mem.span(account)) catch null;
}

/// A NUL-terminated string field of a Win32 struct.
fn wideField(gpa: Allocator, field: []const u16) ?[]const u8 {
    const len = std.mem.indexOfScalar(u16, field, 0) orelse field.len;
    if (len == 0) return null;
    return std.unicode.wtf16LeToWtf8Alloc(gpa, field[0..len]) catch null;
}

/// Asks the service manager to stop service `name` and waits up to 30
/// seconds for it to stop. Returns true if it is stopped.
fn stopService(name: []const u8) bool {
    var name_buf: [256]u16 = undefined;
    const n = std.unicode.wtf8ToWtf16Le(name_buf[0 .. name_buf.len - 1], name) catch return false;
    name_buf[n] = 0;
    const manager = w32.OpenSCManagerW(null, null, w32.SC_MANAGER_CONNECT) orelse return false;
    defer _ = w32.CloseServiceHandle(manager);
    const service = w32.OpenServiceW(manager, name_buf[0..n :0], w32.SERVICE_STOP | w32.SERVICE_QUERY_STATUS) orelse return false;
    defer _ = w32.CloseServiceHandle(service);
    var status: w32.SERVICE_STATUS = .{};
    if (w32.ControlService(service, w32.SERVICE_CONTROL_STOP, &status) == 0 and
        w32.GetLastError() != w32.ERROR_SERVICE_NOT_ACTIVE) return false;
    for (0..300) |_| {
        if (w32.QueryServiceStatus(service, &status) == 0) return false;
        if (status.dwCurrentState == w32.SERVICE_STOPPED) return true;
        w32.Sleep(100);
    }
    return false;
}

/// Gives the process of a stopped service up to 3 seconds to exit. A
/// process that hosts other services keeps running; the stopped service
/// has released its files, so that counts as closed too.
fn waitForExit(pid: w32.DWORD) bool {
    const process = w32.OpenProcess(w32.SYNCHRONIZE, 0, pid) orelse return true;
    defer _ = w32.CloseHandle(process);
    _ = w32.WaitForSingleObject(process, 3_000);
    return true;
}

/// Ends process `pid` and waits up to 10 seconds for it to exit, so its
/// files can be removed. Returns true if it is gone.
fn forceQuit(pid: w32.DWORD) bool {
    const process = w32.OpenProcess(w32.PROCESS_TERMINATE | w32.SYNCHRONIZE, 0, pid) orelse {
        // Either it has exited since it was found, or this process may
        // not end it. `findInUse` could query it, so if that still works
        // it is running.
        const still = w32.OpenProcess(w32.PROCESS_QUERY_LIMITED_INFORMATION, 0, pid) orelse return true;
        _ = w32.CloseHandle(still);
        return false;
    };
    defer _ = w32.CloseHandle(process);
    _ = w32.TerminateProcess(process, 1);
    return w32.WaitForSingleObject(process, 10_000) == w32.WAIT_OBJECT_0;
}

fn readManifest(s: *const State, dir: Io.Dir) ?[]const []const u8 {
    const text = dir.readFileAlloc(s.io, manifest_name, s.gpa, .limited(16 << 20)) catch return null;
    return cli.manifestPaths(s.gpa, text) catch null;
}

const Shortcuts = struct {
    start_menu: ?[]const u8 = null,
    desktop: ?[]const u8 = null,
};

fn registerUninstall(s: *const State, dir: []const u8, uninstaller: []const u8, total_bytes: u64, added_to_path: bool, shortcuts: Shortcuts) !void {
    const key = try createKey(s.gpa, uninstall_key);
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
    if (shortcuts.start_menu) |path| try setString(s.gpa, key, "ZstallerShortcut", path, w32.REG_SZ);
    if (shortcuts.desktop) |path| try setString(s.gpa, key, "ZstallerDesktopShortcut", path, w32.REG_SZ);
}

/// The Start Menu programs folder for all users.
fn startMenuDir(s: *const State) ![]const u8 {
    const program_data = s.env.get("ProgramData") orelse s.env.get("ALLUSERSPROFILE") orelse "C:\\ProgramData";
    return std.fs.path.join(s.gpa, &.{ program_data, "Microsoft", "Windows", "Start Menu", "Programs" });
}

/// The desktop folder for all users.
fn desktopDir(s: *const State) ![]const u8 {
    const public = s.env.get("PUBLIC") orelse "C:\\Users\\Public";
    return std.fs.path.join(s.gpa, &.{ public, "Desktop" });
}

/// Writes `<folder>\<name>.lnk` and returns its path.
fn createShortcut(s: *const State, folder: []const u8, target: []const u8, work_dir: []const u8, icon: []const u8) ![]const u8 {
    try Io.Dir.cwd().createDirPath(s.io, folder);
    const link_path = try std.fs.path.join(s.gpa, &.{ folder, config.display_name ++ ".lnk" });

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
pub fn launch(s: *const State, app_path: []const u8, dir: []const u8) void {
    const file_w = wide(s.gpa, app_path) catch return;
    const dir_w = wide(s.gpa, dir) catch return;
    const verb_w = wide(s.gpa, "open") catch return;
    _ = w32.ShellExecuteW(null, verb_w, file_w, null, dir_w, w32.SW_SHOWNORMAL);
}

fn wide(gpa: Allocator, text: []const u8) ![:0]const u16 {
    return std.unicode.wtf8ToWtf16LeAllocZ(gpa, text);
}

const PathEdit = enum { add, remove };

fn editSystemPath(s: *const State, dir: []const u8, edit: PathEdit) !void {
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
/// process has exited. A copy of this program is started as a hidden
/// helper (`/_cleanup`) with an inherited handle to this process; it waits
/// on that handle, so it works however long this process stays open (for
/// example while the final message box is shown).
///
/// The copy goes in a new folder under %TEMP% that only administrators and
/// SYSTEM can write to. For an uninstall run as SYSTEM (Intune, SCCM),
/// %TEMP% is C:\Windows\Temp, where every user can create files: a
/// predictable file name there could be replaced before it is started, and
/// a DLL planted beside it would be loaded as SYSTEM.
fn removeAfterExit(s: *const State, self_path: []const u8, dir: []const u8) !void {
    const temp = s.env.get("TEMP") orelse s.env.get("TMP") orelse return error.NoTempDir;
    const pid = w32.GetCurrentProcessId();
    const helper_dir = try createPrivateDir(s, temp, pid);
    const helper_path = try std.fs.path.join(s.gpa, &.{ helper_dir, "zstaller-uninstall.exe" });
    try Io.Dir.copyFileAbsolute(self_path, helper_path, s.io, .{});
    errdefer {
        Io.Dir.deleteFileAbsolute(s.io, helper_path) catch {};
        Io.Dir.deleteDirAbsolute(s.io, helper_dir) catch {};
    }

    const self_handle = w32.OpenProcess(w32.SYNCHRONIZE, 1, pid) orelse return error.OpenProcessFailed;
    defer _ = w32.CloseHandle(self_handle);

    const line = try std.fmt.allocPrint(s.gpa, "\"{s}\" \"/_cleanup={s}\" /_wait={d}", .{
        helper_path, dir, @intFromPtr(self_handle),
    });
    const line_w = try std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, line);
    const helper_w = try std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, helper_path);
    // Start the helper in %TEMP%. It would otherwise inherit this
    // process's working directory, which is the install directory when the
    // uninstaller is opened from Explorer, and Windows cannot delete a
    // directory that a process has as its working directory.
    const temp_w = try std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, temp);
    var si: w32.STARTUPINFOW = .{ .cb = @sizeOf(w32.STARTUPINFOW) };
    var pi: w32.PROCESS_INFORMATION = undefined;
    if (w32.CreateProcessW(helper_w.ptr, line_w.ptr, null, null, 1, w32.CREATE_NO_WINDOW, null, temp_w.ptr, &si, &pi) == 0) {
        return error.CreateProcessFailed;
    }
    if (pi.hThread) |h| _ = w32.CloseHandle(h);
    if (pi.hProcess) |h| _ = w32.CloseHandle(h);
}

/// Creates a new folder in `parent` that only SYSTEM and administrators
/// can open, with inheritance from `parent` turned off. A folder that
/// already exists is never reused, as someone else may have made it.
fn createPrivateDir(s: *const State, parent: []const u8, pid: w32.DWORD) ![]const u8 {
    const sddl = std.unicode.utf8ToUtf16LeStringLiteral("D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)");
    var sd: ?*anyopaque = null;
    if (w32.ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, w32.SDDL_REVISION_1, &sd, null) == 0) {
        return error.SecurityDescriptorFailed;
    }
    defer _ = w32.LocalFree(sd);
    const sa: w32.SECURITY_ATTRIBUTES = .{ .lpSecurityDescriptor = sd };

    var attempt: u32 = 0;
    while (attempt < 16) : (attempt += 1) {
        const name = try std.fmt.allocPrint(s.gpa, "zstaller-{d}-{x}-{d}", .{ pid, w32.GetTickCount64(), attempt });
        const path = try std.fs.path.join(s.gpa, &.{ parent, name });
        const path_w = try std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, path);
        if (w32.CreateDirectoryW(path_w.ptr, &sa) != 0) return path;
        if (w32.GetLastError() != w32.ERROR_ALREADY_EXISTS) return error.CreateDirectoryFailed;
    }
    return error.CreateDirectoryFailed;
}

/// The `/_cleanup` helper started by `removeAfterExit`: waits for the
/// uninstaller to exit, deletes it and the install directory (if nothing
/// else is left in it), then has Windows delete this temporary copy at the
/// next restart, as a running program cannot delete itself.
fn cleanup(s: *const State, dir: []const u8, wait_handle: ?usize, self_path: []const u8) ExitCode {
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
    // The same goes for the directory, which Explorer or a scanner may
    // still have open. Files the user added keep it, as they should.
    attempt = 0;
    while (attempt < 50) : (attempt += 1) {
        Io.Dir.deleteDirAbsolute(s.io, dir) catch |err| switch (err) {
            error.FileNotFound, error.DirNotEmpty => break,
            else => {
                w32.Sleep(100);
                continue;
            },
        };
        break;
    }

    // Windows removes this copy, then its private folder, at the next
    // restart, in the order they are queued.
    if (std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, self_path)) |self_w| {
        _ = w32.MoveFileExW(self_w.ptr, null, w32.MOVEFILE_DELAY_UNTIL_REBOOT);
    } else |_| {}
    if (std.fs.path.dirname(self_path)) |helper_dir| {
        if (std.mem.startsWith(u8, std.fs.path.basename(helper_dir), "zstaller-")) {
            if (std.unicode.wtf8ToWtf16LeAllocZ(s.gpa, helper_dir)) |dir_w| {
                _ = w32.MoveFileExW(dir_w.ptr, null, w32.MOVEFILE_DELAY_UNTIL_REBOOT);
            } else |_| {}
        }
    }
    return .success;
}

pub fn messageBox(gpa: Allocator, owner: ?w32.HWND, text: []const u8, flags: u32) c_int {
    const text_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, text) catch return 0;
    const title_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, config.display_name ++ " Setup") catch return 0;
    return w32.MessageBoxW(owner, text_w.ptr, title_w.ptr, flags);
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

pub fn readString(gpa: Allocator, sub_key: []const u8, name: []const u8) ?[]const u8 {
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
