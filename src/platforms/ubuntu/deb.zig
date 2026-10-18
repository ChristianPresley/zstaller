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

//! Debian binary package (.deb) writer.
//!
//! A .deb is an `ar` archive with three members, in this order:
//!   1. `debian-binary`: the format version, "2.0\n".
//!   2. `control.tar.gz`: package metadata (`control`, `md5sums`).
//!   3. `data.tar.gz`: the files to install, rooted at `./`.
//!
//! All archive metadata is fixed (root ownership, caller-chosen mtime) so the
//! same inputs always produce the same bytes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const ArWriter = @import("../../archive/ar.zig").ArWriter;
const TarWriter = @import("../../archive/tar.zig").TarWriter;
const deflate = @import("../../archive/deflate.zig");

pub const File = struct {
    /// Absolute install path, e.g. `/usr/bin/myapp`.
    path: []const u8,
    data: []const u8,
    mode: u32 = 0o644,
};

/// Maintainer scripts (see deb-postinst(5) and friends).
pub const Scripts = struct {
    preinst: ?[]const u8 = null,
    postinst: ?[]const u8 = null,
    prerm: ?[]const u8 = null,
    postrm: ?[]const u8 = null,
};

/// Whether dpkg should treat the file at `path` as a configuration file:
/// keep the administrator's changes on upgrade and ask before replacing
/// them. Debian policy makes every file in /etc one.
pub fn isConffile(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/etc/");
}

pub const Package = struct {
    /// Debian package name (see `naming.debPackageName`).
    name: []const u8,
    /// Debian version (see `naming.debVersion`).
    version: []const u8,
    /// Debian architecture, e.g. `amd64`.
    architecture: []const u8,
    maintainer: []const u8,
    /// One-line synopsis.
    description: []const u8,
    /// Paragraphs that follow the synopsis in `dpkg -s` and `apt show`.
    /// Lines are wrapped by the reader; blank lines separate paragraphs.
    long_description: ?[]const u8 = null,
    section: []const u8 = "utils",
    priority: []const u8 = "optional",
    homepage: ?[]const u8 = null,
    depends: ?[]const u8 = null,
    files: []const File,
    /// Maintainer scripts dpkg runs around installing and removing the
    /// package. Each must start with `#!`.
    scripts: Scripts = .{},
    /// Modification time for every archive entry (seconds since epoch).
    mtime: u64 = 0,
};

pub const Error = Allocator.Error || Writer.Error || error{ NameTooLong, ValueTooLarge, InvalidPath, InvalidField, InvalidScript };

/// Writes the complete .deb for `pkg` to `out`.
pub fn write(gpa: Allocator, out: *Writer, pkg: Package) Error!void {
    try validate(pkg);

    const data_tar = try buildDataTar(gpa, pkg);
    defer gpa.free(data_tar);
    const data_gz = try deflate.compress(gpa, data_tar, .gzip);
    defer gpa.free(data_gz);

    const control_tar = try buildControlTar(gpa, pkg);
    defer gpa.free(control_tar);
    const control_gz = try deflate.compress(gpa, control_tar, .gzip);
    defer gpa.free(control_gz);

    const ar = try ArWriter.init(out);
    try ar.writeMember("debian-binary", "2.0\n", pkg.mtime);
    try ar.writeMember("control.tar.gz", control_gz, pkg.mtime);
    try ar.writeMember("data.tar.gz", data_gz, pkg.mtime);
}

fn validate(pkg: Package) error{ InvalidPath, InvalidField, InvalidScript }!void {
    inline for (@typeInfo(Scripts).@"struct".fields) |field| {
        if (@field(pkg.scripts, field.name)) |script| {
            if (!std.mem.startsWith(u8, script, "#!")) return error.InvalidScript;
        }
    }
    for ([_][]const u8{ pkg.name, pkg.version, pkg.architecture, pkg.maintainer, pkg.description, pkg.section, pkg.priority }) |field| {
        if (field.len == 0 or std.mem.indexOfAny(u8, field, "\r\n") != null) return error.InvalidField;
    }
    for ([_]?[]const u8{ pkg.homepage, pkg.depends }) |opt| {
        if (opt) |field| if (std.mem.indexOfAny(u8, field, "\r\n") != null) return error.InvalidField;
    }
    for (pkg.files) |f| {
        if (f.path.len < 2 or f.path[0] != '/' or f.path[f.path.len - 1] == '/') return error.InvalidPath;
        var it = std.mem.splitScalar(u8, f.path[1..], '/');
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return error.InvalidPath;
        }
    }
}

fn buildDataTar(gpa: Allocator, pkg: Package) Error![]u8 {
    // Every parent directory needs its own entry, emitted once and before
    // its children. Sorting all paths gives both properties.
    var dirs: std.StringArrayHashMapUnmanaged(void) = .empty;
    defer dirs.deinit(gpa);
    for (pkg.files) |f| {
        var i: usize = 1;
        while (std.mem.indexOfScalarPos(u8, f.path, i, '/')) |slash| : (i = slash + 1) {
            try dirs.put(gpa, f.path[0..slash], {});
        }
    }
    // A path cannot be both a file and the folder of another file.
    for (pkg.files) |f| if (dirs.contains(f.path)) return error.InvalidPath;
    const dir_list = try gpa.dupe([]const u8, dirs.keys());
    defer gpa.free(dir_list);
    std.mem.sort([]const u8, dir_list, {}, lessThanStr);

    const files = try gpa.dupe(File, pkg.files);
    defer gpa.free(files);
    std.mem.sort(File, files, {}, lessThanFile);
    for (files[1..], 0..) |f, i| {
        if (std.mem.eql(u8, f.path, files[i].path)) return error.InvalidPath;
    }

    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const t = TarWriter.init(&out.writer);
    try t.writeDir("./", pkg.mtime);
    var path_buf: [512]u8 = undefined;
    for (dir_list) |d| {
        try t.writeDir(try dotPath(&path_buf, d), pkg.mtime);
    }
    for (files) |f| {
        try t.writeFileBytes(try dotPath(&path_buf, f.path), f.data, .{ .mode = f.mode, .mtime = pkg.mtime });
    }
    try t.finish();
    return out.toOwnedSlice();
}

fn buildControlTar(gpa: Allocator, pkg: Package) Error![]u8 {
    var control: Writer.Allocating = .init(gpa);
    defer control.deinit();
    const w = &control.writer;
    var installed_bytes: u64 = 0;
    for (pkg.files) |f| installed_bytes += f.data.len;
    try w.print("Package: {s}\n", .{pkg.name});
    try w.print("Version: {s}\n", .{pkg.version});
    try w.print("Architecture: {s}\n", .{pkg.architecture});
    try w.print("Maintainer: {s}\n", .{pkg.maintainer});
    try w.print("Installed-Size: {d}\n", .{(installed_bytes + 1023) / 1024});
    if (pkg.depends) |d| try w.print("Depends: {s}\n", .{d});
    try w.print("Section: {s}\n", .{pkg.section});
    try w.print("Priority: {s}\n", .{pkg.priority});
    if (pkg.homepage) |h| try w.print("Homepage: {s}\n", .{h});
    try w.print("Description: {s}\n", .{pkg.description});
    if (pkg.long_description) |long| try writeLongDescription(w, long);

    var md5sums: Writer.Allocating = .init(gpa);
    defer md5sums.deinit();
    const files = try gpa.dupe(File, pkg.files);
    defer gpa.free(files);
    std.mem.sort(File, files, {}, lessThanFile);
    for (files) |f| {
        var d: [16]u8 = undefined;
        std.crypto.hash.Md5.hash(f.data, &d, .{});
        try md5sums.writer.print("{x}  {s}\n", .{ &d, f.path[1..] });
    }

    var out: Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const t = TarWriter.init(&out.writer);
    try t.writeDir("./", pkg.mtime);
    try t.writeFileBytes("./control", control.written(), .{ .mtime = pkg.mtime });
    try t.writeFileBytes("./md5sums", md5sums.written(), .{ .mtime = pkg.mtime });

    var conffiles: Writer.Allocating = .init(gpa);
    defer conffiles.deinit();
    for (files) |f| {
        if (isConffile(f.path)) try conffiles.writer.print("{s}\n", .{f.path});
    }
    if (conffiles.written().len > 0) {
        try t.writeFileBytes("./conffiles", conffiles.written(), .{ .mtime = pkg.mtime });
    }
    inline for (@typeInfo(Scripts).@"struct".fields) |field| {
        if (@field(pkg.scripts, field.name)) |script| {
            try t.writeFileBytes("./" ++ field.name, script, .{ .mode = 0o755, .mtime = pkg.mtime });
        }
    }
    try t.finish();
    return out.toOwnedSlice();
}

/// The extended description: each line indented by one space, and blank
/// lines as ` .`, as deb-control(5) requires.
fn writeLongDescription(w: *Writer, text: []const u8) Writer.Error!void {
    var it = std.mem.splitScalar(u8, std.mem.trim(u8, text, "\n"), '\n');
    while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t\r");
        if (line.len == 0) {
            try w.writeAll(" .\n");
        } else {
            try w.print(" {s}\n", .{line});
        }
    }
}

/// A Debian changelog (deb-changelog(5)) with one entry for `version`,
/// dated `mtime`. Lintian expects one in every package.
pub fn changelogFile(gpa: Allocator, name: []const u8, version: []const u8, maintainer: []const u8, mtime: u64) Allocator.Error![]u8 {
    const es: std.time.epoch.EpochSeconds = .{ .secs = mtime };
    const day = es.getEpochDay();
    const yd = day.calculateYearDay();
    const md = yd.calculateMonthDay();
    const ds = es.getDaySeconds();
    const weekdays = [_][]const u8{ "Thu", "Fri", "Sat", "Sun", "Mon", "Tue", "Wed" };
    const months = [_][]const u8{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };
    return std.fmt.allocPrint(gpa,
        \\{s} ({s}) unstable; urgency=medium
        \\
        \\  * Release {s}.
        \\
        \\ -- {s}  {s}, {d:0>2} {s} {d} {d:0>2}:{d:0>2}:{d:0>2} +0000
        \\
    , .{
        name,                               version,
        version,                            maintainer,
        weekdays[day.day % 7],              md.day_index + 1,
        months[@intFromEnum(md.month) - 1], yd.year,
        ds.getHoursIntoDay(),               ds.getMinutesIntoHour(),
        ds.getSecondsIntoMinute(),
    });
}

/// The prerm script with lines that remove the package's MCP server
/// registrations (`helper unregister --all-users`, see src/mcp/helper.zig)
/// when the package is removed. They go right after the `#!` line of the
/// author's own `prerm`, or make up the whole script when there is none.
pub fn withPrermSnippet(gpa: Allocator, prerm: ?[]const u8, helper: []const u8) Allocator.Error![]u8 {
    const snippet = try std.fmt.allocPrint(gpa,
        \\# Added by zstaller: remove this package's MCP server from the
        \\# users' AI tools (only entries that run this package's program).
        \\if [ "$1" = remove ] && [ -x {s} ]; then
        \\    {s} unregister --all-users >/dev/null 2>&1 || true
        \\fi
        \\
    , .{ helper, helper });
    defer gpa.free(snippet);
    const script = prerm orelse return std.mem.concat(gpa, u8, &.{ "#!/bin/sh\nset -e\n", snippet });
    const nl = (std.mem.indexOfScalar(u8, script, '\n') orelse return std.mem.concat(gpa, u8, &.{ script, "\n", snippet })) + 1;
    return std.mem.concat(gpa, u8, &.{ script[0..nl], snippet, script[nl..] });
}

/// Whether `script` runs with a POSIX shell, so that shell lines can be
/// added to it.
pub fn isShellScript(script: []const u8) bool {
    const line = script[0 .. std.mem.indexOfScalar(u8, script, '\n') orelse script.len];
    if (!std.mem.startsWith(u8, line, "#!")) return false;
    var words = std.mem.tokenizeAny(u8, line[2..], " \t\r");
    var interpreter = words.next() orelse return false;
    // `#!/usr/bin/env sh`
    if (std.mem.eql(u8, std.fs.path.basename(interpreter), "env")) interpreter = words.next() orelse return false;
    const name = std.fs.path.basename(interpreter);
    for ([_][]const u8{ "sh", "bash", "dash" }) |shell| if (std.mem.eql(u8, name, shell)) return true;
    return false;
}

test isShellScript {
    try std.testing.expect(isShellScript("#!/bin/sh\nset -e\n"));
    try std.testing.expect(isShellScript("#! /bin/bash -e\n"));
    try std.testing.expect(isShellScript("#!/usr/bin/env dash"));
    try std.testing.expect(!isShellScript("#!/usr/bin/python3\nprint(1)\n"));
    try std.testing.expect(!isShellScript("#!/usr/bin/env perl\n"));
    try std.testing.expect(!isShellScript("echo hi\n"));
}

test withPrermSnippet {
    const gpa = std.testing.allocator;
    const alone = try withPrermSnippet(gpa, null, "/usr/lib/app/zstaller-mcp");
    defer gpa.free(alone);
    try std.testing.expect(std.mem.startsWith(u8, alone, "#!/bin/sh\nset -e\n# Added by zstaller"));
    try std.testing.expect(std.mem.indexOf(u8, alone, "    /usr/lib/app/zstaller-mcp unregister --all-users") != null);
    const theirs = try withPrermSnippet(gpa, "#!/bin/bash\necho bye\n", "/x");
    defer gpa.free(theirs);
    try std.testing.expect(std.mem.startsWith(u8, theirs, "#!/bin/bash\n# Added by zstaller"));
    try std.testing.expect(std.mem.endsWith(u8, theirs, "fi\necho bye\n"));
}

/// Whether `path` is a manual page, which Debian policy wants compressed
/// with gzip.
pub fn isUncompressedManPage(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/usr/share/man/") and !std.mem.endsWith(u8, path, ".gz");
}

fn dotPath(buf: []u8, abs: []const u8) error{NameTooLong}![]const u8 {
    if (abs.len + 1 > buf.len) return error.NameTooLong;
    buf[0] = '.';
    @memcpy(buf[1..][0..abs.len], abs);
    return buf[0 .. abs.len + 1];
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn lessThanFile(_: void, a: File, b: File) bool {
    return std.mem.lessThan(u8, a.path, b.path);
}

/// Writes a machine-readable debian/copyright file declaring `license` for
/// all files.
pub fn copyrightFile(gpa: Allocator, name: []const u8, license: []const u8, holder: ?[]const u8) Allocator.Error![]u8 {
    return std.fmt.allocPrint(gpa,
        \\Format: https://www.debian.org/doc/packaging-manuals/copyright-format/1.0/
        \\Upstream-Name: {s}
        \\
        \\Files: *
        \\Copyright: {s}
        \\License: {s}
        \\
    , .{ name, holder orelse name, license });
}

const testing = std.testing;

const sample: Package = .{
    .name = "hello",
    .version = "1.0.0",
    .architecture = "amd64",
    .maintainer = "Jane Doe <jane@example.com>",
    .description = "Says hello",
    .files = &.{
        .{ .path = "/usr/bin/hello", .data = "\x7fELF...", .mode = 0o755 },
        .{ .path = "/usr/share/doc/hello/copyright", .data = "License: MIT\n" },
    },
};

test "deb has the three members in order" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    try write(testing.allocator, &out.writer, sample);
    const bytes = out.written();
    try testing.expect(std.mem.startsWith(u8, bytes, "!<arch>\ndebian-binary   "));
    const control_at = std.mem.indexOf(u8, bytes, "control.tar.gz").?;
    const data_at = std.mem.indexOf(u8, bytes, "data.tar.gz").?;
    try testing.expect(control_at < data_at);
}

test "deb output is deterministic" {
    var a: Writer.Allocating = .init(testing.allocator);
    defer a.deinit();
    var b: Writer.Allocating = .init(testing.allocator);
    defer b.deinit();
    try write(testing.allocator, &a.writer, sample);
    try write(testing.allocator, &b.writer, sample);
    try testing.expectEqualSlices(u8, a.written(), b.written());
}

test "control file contents" {
    const tar_bytes = try buildControlTar(testing.allocator, sample);
    defer testing.allocator.free(tar_bytes);
    try testing.expect(std.mem.indexOf(u8, tar_bytes, "Package: hello\nVersion: 1.0.0\nArchitecture: amd64\n") != null);
    try testing.expect(std.mem.indexOf(u8, tar_bytes, "Installed-Size: 1\n") != null);
    try testing.expect(std.mem.indexOf(u8, tar_bytes, "  usr/bin/hello\n") != null);
}

test "data tar lists parent directories first" {
    const tar_bytes = try buildDataTar(testing.allocator, sample);
    defer testing.allocator.free(tar_bytes);
    var reader: std.Io.Reader = .fixed(tar_bytes);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    const expected = [_][]const u8{ "./", "./usr/", "./usr/bin/", "./usr/share/", "./usr/share/doc/", "./usr/share/doc/hello/", "./usr/bin/hello", "./usr/share/doc/hello/copyright" };
    for (expected) |e| {
        const entry = (try it.next()).?;
        try testing.expectEqualStrings(e, entry.name);
    }
    try testing.expect((try it.next()) == null);
}

test "rejects bad paths and fields" {
    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    var bad = sample;
    bad.files = &.{.{ .path = "relative/path", .data = "" }};
    try testing.expectError(error.InvalidPath, write(testing.allocator, &out.writer, bad));
    bad.files = &.{.{ .path = "/usr/../etc/passwd", .data = "" }};
    try testing.expectError(error.InvalidPath, write(testing.allocator, &out.writer, bad));
    bad.files = &.{ .{ .path = "/a/b", .data = "" }, .{ .path = "/a/b", .data = "" } };
    try testing.expectError(error.InvalidPath, write(testing.allocator, &out.writer, bad));
    bad.files = &.{ .{ .path = "/a/b", .data = "" }, .{ .path = "/a/b/c", .data = "" } };
    try testing.expectError(error.InvalidPath, write(testing.allocator, &out.writer, bad));
    bad = sample;
    bad.description = "two\nlines";
    try testing.expectError(error.InvalidField, write(testing.allocator, &out.writer, bad));
}

test "files in /etc are conffiles; scripts are executable" {
    var pkg = sample;
    pkg.files = &.{
        .{ .path = "/usr/bin/hello", .data = "\x7fELF", .mode = 0o755 },
        .{ .path = "/etc/hello/hello.conf", .data = "greeting = hi\n" },
        .{ .path = "/etc/default/hello", .data = "ARGS=\n" },
    };
    pkg.scripts = .{ .postinst = "#!/bin/sh\nset -e\n" };
    const tar_bytes = try buildControlTar(testing.allocator, pkg);
    defer testing.allocator.free(tar_bytes);
    var reader: std.Io.Reader = .fixed(tar_bytes);
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    var saw_conffiles = false;
    var saw_postinst = false;
    while (try it.next()) |entry| {
        if (std.mem.eql(u8, entry.name, "./conffiles")) {
            var buf: [128]u8 = undefined;
            var w: Writer = .fixed(&buf);
            try it.streamRemaining(entry, &w);
            try testing.expectEqualStrings("/etc/default/hello\n/etc/hello/hello.conf\n", w.buffered());
            saw_conffiles = true;
        } else if (std.mem.eql(u8, entry.name, "./postinst")) {
            try testing.expectEqual(@as(u32, 0o755), entry.mode);
            saw_postinst = true;
        }
    }
    try testing.expect(saw_conffiles and saw_postinst);

    var out: Writer.Allocating = .init(testing.allocator);
    defer out.deinit();
    pkg.scripts = .{ .prerm = "echo no shebang\n" };
    try testing.expectError(error.InvalidScript, write(testing.allocator, &out.writer, pkg));
}

test "long description" {
    var pkg = sample;
    pkg.long_description = "First paragraph,\nsecond line.\n\nSecond paragraph.\n";
    const tar_bytes = try buildControlTar(testing.allocator, pkg);
    defer testing.allocator.free(tar_bytes);
    try testing.expect(std.mem.indexOf(u8, tar_bytes, "Description: Says hello\n First paragraph,\n second line.\n .\n Second paragraph.\n") != null);
}

test "changelogFile" {
    const text = try changelogFile(testing.allocator, "hello", "1.2.0", "Jane Doe <jane@example.com>", 1760572800);
    defer testing.allocator.free(text);
    try testing.expectEqualStrings(
        \\hello (1.2.0) unstable; urgency=medium
        \\
        \\  * Release 1.2.0.
        \\
        \\ -- Jane Doe <jane@example.com>  Thu, 16 Oct 2025 00:00:00 +0000
        \\
    , text);
    const epoch0 = try changelogFile(testing.allocator, "a", "1", "M <m@x>", 315532800);
    defer testing.allocator.free(epoch0);
    try testing.expect(std.mem.indexOf(u8, epoch0, "Tue, 01 Jan 1980 00:00:00 +0000") != null);
}

test "dpkg-deb accepts the package (skipped when dpkg-deb is missing)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    try write(gpa, &out.writer, sample);
    try tmp.dir.writeFile(io, .{ .sub_path = "hello.deb", .data = out.written() });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/hello.deb", .{tmp.sub_path});
    defer gpa.free(path);

    for ([_][]const u8{ "--info", "--contents" }) |flag| {
        const result = std.process.run(gpa, io, .{ .argv = &.{ "dpkg-deb", flag, path } }) catch |err| switch (err) {
            error.FileNotFound => return error.SkipZigTest,
            else => |e| return e,
        };
        defer gpa.free(result.stdout);
        defer gpa.free(result.stderr);
        if (result.term != .exited or result.term.exited != 0) {
            std.debug.print("dpkg-deb {s} failed:\n{s}\n", .{ flag, result.stderr });
            return error.DpkgDebRejected;
        }
        if (std.mem.eql(u8, flag, "--info")) {
            try testing.expect(std.mem.indexOf(u8, result.stdout, "Package: hello") != null);
        } else {
            try testing.expect(std.mem.indexOf(u8, result.stdout, "./usr/bin/hello") != null);
        }
    }
}
