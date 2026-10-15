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
    section: []const u8 = "utils",
    priority: []const u8 = "optional",
    homepage: ?[]const u8 = null,
    depends: ?[]const u8 = null,
    files: []const File,
    /// Modification time for every archive entry (seconds since epoch).
    mtime: u64 = 0,
};

pub const Error = Allocator.Error || Writer.Error || error{ NameTooLong, ValueTooLarge, InvalidPath, InvalidField };

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

fn validate(pkg: Package) error{ InvalidPath, InvalidField }!void {
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
    try t.finish();
    return out.toOwnedSlice();
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
    bad = sample;
    bad.description = "two\nlines";
    try testing.expectError(error.InvalidField, write(testing.allocator, &out.writer, bad));
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
