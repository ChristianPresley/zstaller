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

//! Writes reproducible zip archives (APPNOTE 6.3): entries in the order
//! given, one fixed timestamp, Unix permissions, deflate when it helps.
//! No zip64, so the archive and every entry stay under 4 GiB.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const deflate = @import("deflate.zig");
const DosTime = @import("../platforms/windows/msi/cab.zig").DosTime;

pub const Entry = struct {
    /// Path inside the archive with '/' separators.
    path: []const u8,
    data: []const u8,
    /// Unix permission bits.
    mode: u32 = 0o644,
};

pub const Error = Allocator.Error || Writer.Error || error{ TooLarge, InvalidPath };

const method_store = 0;
const method_deflate = 8;
const flag_utf8 = 0x0800;
const version_needed = 20;
const made_by_unix = 3 << 8 | 20;

pub fn write(gpa: Allocator, out: *Writer, entries: []const Entry, mtime: u64) Error!void {
    if (entries.len > 0xFFFF) return error.TooLarge;
    const stamp: DosTime = .fromUnix(mtime);

    const Placed = struct { offset: u32, crc: u32, method: u16, size: u32 };
    const placed = try gpa.alloc(Placed, entries.len);
    defer gpa.free(placed);

    var offset: u64 = 0;
    for (entries, placed) |e, *p| {
        if (e.path.len == 0 or e.path.len > 0xFFFF or e.path[0] == '/' or
            std.mem.indexOfScalar(u8, e.path, '\\') != null) return error.InvalidPath;
        if (e.data.len > std.math.maxInt(u32)) return error.TooLarge;
        const compressed = try deflate.compress(gpa, e.data, .raw);
        defer gpa.free(compressed);
        const use_deflate = compressed.len < e.data.len;
        const body = if (use_deflate) compressed else e.data;
        if (offset > std.math.maxInt(u32)) return error.TooLarge;
        p.* = .{
            .offset = @intCast(offset),
            .crc = std.hash.Crc32.hash(e.data),
            .method = if (use_deflate) method_deflate else method_store,
            .size = @intCast(body.len),
        };
        try out.writeInt(u32, 0x04034b50, .little);
        try out.writeInt(u16, version_needed, .little);
        try out.writeInt(u16, flag_utf8, .little);
        try out.writeInt(u16, p.method, .little);
        try out.writeInt(u16, stamp.time, .little);
        try out.writeInt(u16, stamp.date, .little);
        try out.writeInt(u32, p.crc, .little);
        try out.writeInt(u32, p.size, .little);
        try out.writeInt(u32, @intCast(e.data.len), .little);
        try out.writeInt(u16, @intCast(e.path.len), .little);
        try out.writeInt(u16, 0, .little);
        try out.writeAll(e.path);
        try out.writeAll(body);
        offset += 30 + e.path.len + body.len;
    }

    const central_start = offset;
    for (entries, placed) |e, p| {
        try out.writeInt(u32, 0x02014b50, .little);
        try out.writeInt(u16, made_by_unix, .little);
        try out.writeInt(u16, version_needed, .little);
        try out.writeInt(u16, flag_utf8, .little);
        try out.writeInt(u16, p.method, .little);
        try out.writeInt(u16, stamp.time, .little);
        try out.writeInt(u16, stamp.date, .little);
        try out.writeInt(u32, p.crc, .little);
        try out.writeInt(u32, p.size, .little);
        try out.writeInt(u32, @intCast(e.data.len), .little);
        try out.writeInt(u16, @intCast(e.path.len), .little);
        try out.writeInt(u16, 0, .little); // extra
        try out.writeInt(u16, 0, .little); // comment
        try out.writeInt(u16, 0, .little); // disk
        try out.writeInt(u16, 0, .little); // internal attributes
        try out.writeInt(u32, (0o100000 | (e.mode & 0o7777)) << 16, .little); // regular file
        try out.writeInt(u32, p.offset, .little);
        try out.writeAll(e.path);
        offset += 46 + e.path.len;
    }
    const central_size = offset - central_start;
    if (offset > std.math.maxInt(u32)) return error.TooLarge;

    try out.writeInt(u32, 0x06054b50, .little);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, 0, .little);
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u16, @intCast(entries.len), .little);
    try out.writeInt(u32, @intCast(central_size), .little);
    try out.writeInt(u32, @intCast(central_start), .little);
    try out.writeInt(u16, 0, .little);
}

test "unzip reads what write wrote" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var out: Writer.Allocating = .init(gpa);
    defer out.deinit();
    const text = "hello zip " ** 200;
    try write(gpa, &out.writer, &.{
        .{ .path = "manifest.json", .data = text },
        .{ .path = "server/app", .data = "\x00\x01\x02", .mode = 0o755 },
    }, 1700000000);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "a.zip", .data = out.written() });
    const path = try std.fmt.allocPrint(gpa, ".zig-cache/tmp/{s}/a.zip", .{tmp.sub_path});
    defer gpa.free(path);
    const r = std.process.run(gpa, io, .{ .argv = &.{ "unzip", "-p", path, "manifest.json" } }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => |e| return e,
    };
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    try std.testing.expectEqualStrings(text, r.stdout);
    const t = try std.process.run(gpa, io, .{ .argv = &.{ "unzip", "-Z", "-l", path } });
    defer gpa.free(t.stdout);
    defer gpa.free(t.stderr);
    try std.testing.expect(std.mem.indexOf(u8, t.stdout, "-rwxr-xr-x") != null);
    try std.testing.expect(std.mem.indexOf(u8, t.stdout, "defN") != null);
}

test "rejects unsafe paths" {
    var out: Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try std.testing.expectError(error.InvalidPath, write(std.testing.allocator, &out.writer, &.{.{ .path = "/abs", .data = "" }}, 0));
    try std.testing.expectError(error.InvalidPath, write(std.testing.allocator, &out.writer, &.{.{ .path = "a\\b", .data = "" }}, 0));
}
