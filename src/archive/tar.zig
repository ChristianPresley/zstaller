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

//! Minimal, deterministic ustar archive writer.
//!
//! Every entry is owned by root:root (uid/gid 0) and carries a caller-chosen
//! mtime, so the same inputs always produce byte-identical archives. Paths
//! longer than the ustar name field are split across the prefix field; paths
//! that cannot be split are rejected rather than written with vendor
//! extensions, which keeps the output readable by every tar implementation
//! (including dpkg's).

const std = @import("std");
const Writer = std.Io.Writer;

pub const block_size = 512;

pub const Error = Writer.Error || error{ NameTooLong, ValueTooLarge };

pub const EntryOptions = struct {
    mode: u32 = 0o644,
    mtime: u64 = 0,
};

pub const TarWriter = struct {
    out: *Writer,

    pub fn init(out: *Writer) TarWriter {
        return .{ .out = out };
    }

    /// Writes a directory entry with mode 0755. `path` should end in '/';
    /// one is appended if missing.
    pub fn writeDir(t: TarWriter, path: []const u8, mtime: u64) Error!void {
        var buf: [256]u8 = undefined;
        const p = if (std.mem.endsWith(u8, path, "/")) path else blk: {
            if (path.len + 1 > buf.len) return error.NameTooLong;
            @memcpy(buf[0..path.len], path);
            buf[path.len] = '/';
            break :blk buf[0 .. path.len + 1];
        };
        try t.writeHeader(p, '5', 0, 0o755, mtime);
    }

    /// Writes a regular file whose contents are `data`.
    pub fn writeFileBytes(t: TarWriter, path: []const u8, data: []const u8, opts: EntryOptions) Error!void {
        try t.writeHeader(path, '0', data.len, opts.mode, opts.mtime);
        try t.out.writeAll(data);
        try t.pad(data.len);
    }

    /// Writes the header of a regular file of `size` bytes. The caller must
    /// then write exactly `size` bytes to `out` and call `pad(size)`.
    pub fn beginFile(t: TarWriter, path: []const u8, size: u64, opts: EntryOptions) Error!void {
        try t.writeHeader(path, '0', size, opts.mode, opts.mtime);
    }

    pub fn pad(t: TarWriter, size: u64) Writer.Error!void {
        const rem: usize = @intCast(size % block_size);
        if (rem != 0) try t.out.splatByteAll(0, block_size - rem);
    }

    /// Writes the two zero blocks that terminate the archive.
    pub fn finish(t: TarWriter) Writer.Error!void {
        try t.out.splatByteAll(0, block_size * 2);
    }

    fn writeHeader(t: TarWriter, path: []const u8, typeflag: u8, size: u64, mode: u32, mtime: u64) Error!void {
        var h: [block_size]u8 = @splat(0);
        const name, const prefix = try splitPath(path);
        @memcpy(h[0..name.len], name);
        @memcpy(h[345..][0..prefix.len], prefix);
        try octal(h[100..108], mode);
        try octal(h[108..116], 0);
        try octal(h[116..124], 0);
        try octal(h[124..136], size);
        try octal(h[136..148], mtime);
        h[156] = typeflag;
        @memcpy(h[257..263], "ustar\x00");
        @memcpy(h[263..265], "00");
        @memcpy(h[265..][0..4], "root");
        @memcpy(h[297..][0..4], "root");
        @memset(h[148..156], ' ');
        var sum: u32 = 0;
        for (h) |b| sum += b;
        try octal(h[148..155], sum);
        h[155] = ' ';
        try t.out.writeAll(&h);
    }
};

/// Splits `path` into ustar (name, prefix). The name holds at most 100
/// bytes and the prefix at most 155, split at a '/'.
fn splitPath(path: []const u8) error{NameTooLong}!struct { []const u8, []const u8 } {
    if (path.len == 0) return error.NameTooLong;
    if (path.len <= 100) return .{ path, "" };
    // Find the earliest '/' such that the remainder fits in 100 bytes and
    // the prefix fits in 155. A trailing '/' (directories) stays in name.
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] != '/') continue;
        const prefix = path[0..i];
        const name = path[i + 1 ..];
        if (prefix.len <= 155 and name.len <= 100 and name.len > 0) return .{ name, prefix };
        if (prefix.len > 155) break;
    }
    return error.NameTooLong;
}

/// Writes `value` as zero-padded octal followed by a NUL, filling `field`.
fn octal(field: []u8, value: u64) error{ValueTooLarge}!void {
    const digits = field.len - 1;
    var v = value;
    var i = digits;
    while (i > 0) {
        i -= 1;
        field[i] = '0' + @as(u8, @intCast(v & 7));
        v >>= 3;
    }
    if (v != 0) return error.ValueTooLarge;
    field[digits] = 0;
}

const testing = std.testing;

test "file entry header layout and checksum" {
    var buf: [4 * block_size]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const t: TarWriter = .init(&w);
    try t.writeFileBytes("./usr/bin/app", "hello", .{ .mode = 0o755, .mtime = 1700000000 });
    const out = w.buffered();
    try testing.expectEqual(@as(usize, 2 * block_size), out.len);
    const h = out[0..block_size];
    try testing.expectEqualStrings("./usr/bin/app", std.mem.sliceTo(h[0..100], 0));
    try testing.expectEqualStrings("0000755", h[100..107]);
    try testing.expectEqualStrings("00000000005", h[124..135]);
    try testing.expectEqualStrings("14524770400", h[136..147]);
    try testing.expectEqual(@as(u8, '0'), h[156]);
    try testing.expectEqualStrings("root", std.mem.sliceTo(h[265..297], 0));

    // Recompute checksum the way readers do.
    var copy = h.*;
    @memset(copy[148..156], ' ');
    var sum: u32 = 0;
    for (copy) |b| sum += b;
    const stored = try std.fmt.parseInt(u32, h[148..154], 8);
    try testing.expectEqual(sum, stored);
    try testing.expectEqualStrings("hello", out[block_size..][0..5]);
}

test "directory gets trailing slash and 0755" {
    var buf: [block_size]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try TarWriter.init(&w).writeDir("./usr", 0);
    try testing.expectEqualStrings("./usr/", std.mem.sliceTo(buf[0..100], 0));
    try testing.expectEqualStrings("0000755", buf[100..107]);
    try testing.expectEqual(@as(u8, '5'), buf[156]);
}

test "long paths split into prefix" {
    const long = "./usr/share/" ++ "a" ** 60 ++ "/" ++ "b" ** 60;
    const name, const prefix = try splitPath(long);
    try testing.expectEqualStrings("b" ** 60, name);
    try testing.expectEqualStrings("./usr/share/" ++ "a" ** 60, prefix);
    try testing.expectError(error.NameTooLong, splitPath("x" ** 101));
}

test "archive is readable by std.tar" {
    var buf: [8 * block_size]u8 = undefined;
    var w: Writer = .fixed(&buf);
    const t: TarWriter = .init(&w);
    try t.writeDir("./opt", 0);
    try t.writeFileBytes("./opt/a.txt", "abc", .{});
    try t.finish();

    var reader: std.Io.Reader = .fixed(w.buffered());
    var name_buf: [std.fs.max_path_bytes]u8 = undefined;
    var link_buf: [std.fs.max_path_bytes]u8 = undefined;
    var it: std.tar.Iterator = .init(&reader, .{ .file_name_buffer = &name_buf, .link_name_buffer = &link_buf });
    const d = (try it.next()).?;
    try testing.expectEqualStrings("./opt/", d.name);
    const f = (try it.next()).?;
    try testing.expectEqualStrings("./opt/a.txt", f.name);
    try testing.expectEqual(@as(u64, 3), f.size);
    try testing.expect((try it.next()) == null);
}
