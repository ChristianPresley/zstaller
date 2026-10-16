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

//! The payload embedded in Windows EXE installers.
//!
//! Layout (all integers little-endian):
//!
//!     magic        "ZSTLPAY2"
//!     raw_len      u64   length of the decompressed body
//!     digest       [32]u8 SHA-256 of the compressed body
//!     body         raw DEFLATE stream of:
//!         count    u32
//!         count x  { path_len u16, path [path_len]u8, size u64, data [size]u8 }
//!
//! Paths are relative, use '/' as separator and are validated on both
//! ends, so a crafted payload cannot write outside the install directory.
//! The digest is checked before anything is decompressed, so a corrupted
//! or truncated download is reported as such instead of reaching the
//! decompressor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const deflate = @import("../../../archive/deflate.zig");

pub const magic = "ZSTLPAY2";
const Sha256 = std.crypto.hash.sha2.Sha256;
const header_len = magic.len + 8 + Sha256.digest_length;

pub const Entry = struct {
    path: []const u8,
    data: []const u8,
};

pub const Error = error{ InvalidPayload, InvalidPath };

/// Encodes `entries` into a payload.
pub fn encode(gpa: Allocator, entries: []const Entry) (Allocator.Error || Error)![]u8 {
    var body: std.Io.Writer.Allocating = .init(gpa);
    defer body.deinit();
    const w = &body.writer;
    w.writeInt(u32, @intCast(entries.len), .little) catch return error.OutOfMemory;
    for (entries) |e| {
        if (!isSafePath(e.path)) return error.InvalidPath;
        w.writeInt(u16, @intCast(e.path.len), .little) catch return error.OutOfMemory;
        w.writeAll(e.path) catch return error.OutOfMemory;
        w.writeInt(u64, e.data.len, .little) catch return error.OutOfMemory;
        w.writeAll(e.data) catch return error.OutOfMemory;
    }
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    out.writer.writeAll(magic) catch return error.OutOfMemory;
    out.writer.writeInt(u64, body.written().len, .little) catch return error.OutOfMemory;
    out.writer.writeAll(&@as([Sha256.digest_length]u8, @splat(0))) catch return error.OutOfMemory;
    try deflate.compressTo(gpa, &out.writer, body.written(), .raw);
    const bytes = try out.toOwnedSlice();
    Sha256.hash(bytes[header_len..], bytes[16..header_len], .{});
    return bytes;
}

/// A decoded payload. Entry slices point into `body`.
pub const Decoded = struct {
    body: []u8,
    entries: []Entry,

    pub fn deinit(d: *Decoded, gpa: Allocator) void {
        gpa.free(d.entries);
        gpa.free(d.body);
        d.* = undefined;
    }
};

/// Decodes and validates a payload produced by `encode`.
pub fn decode(gpa: Allocator, bytes: []const u8) (Allocator.Error || Error)!Decoded {
    if (bytes.len < header_len or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidPayload;
    const raw_len = std.mem.readInt(u64, bytes[8..16], .little);
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(bytes[header_len..], &digest, .{});
    if (!std.mem.eql(u8, &digest, bytes[16..header_len])) return error.InvalidPayload;
    const body = deflate.decompress(gpa, bytes[header_len..], .raw) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidPayload,
    };
    errdefer gpa.free(body);
    if (body.len != raw_len or body.len < 4) return error.InvalidPayload;

    var pos: usize = 0;
    const count = std.mem.readInt(u32, body[0..4], .little);
    pos = 4;
    if (count > body.len) return error.InvalidPayload;
    const entries = try gpa.alloc(Entry, count);
    errdefer gpa.free(entries);
    for (entries) |*e| {
        if (body.len - pos < 2) return error.InvalidPayload;
        const plen = std.mem.readInt(u16, body[pos..][0..2], .little);
        pos += 2;
        if (body.len - pos < @as(usize, plen) + 8) return error.InvalidPayload;
        const path = body[pos..][0..plen];
        pos += plen;
        if (!isSafePath(path)) return error.InvalidPath;
        const size = std.mem.readInt(u64, body[pos..][0..8], .little);
        pos += 8;
        if (body.len - pos < size) return error.InvalidPayload;
        e.* = .{ .path = path, .data = body[pos..][0..@intCast(size)] };
        pos += @intCast(size);
    }
    if (pos != body.len) return error.InvalidPayload;
    return .{ .body = body, .entries = entries };
}

/// A path is safe when it is relative, uses '/' separators, has no empty,
/// '.' or '..' segments, and contains no characters Windows forbids in
/// file names.
pub fn isSafePath(path: []const u8) bool {
    if (path.len == 0 or path.len > 260) return false;
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".") or std.mem.eql(u8, seg, "..")) return false;
        if (seg[seg.len - 1] == '.' or seg[seg.len - 1] == ' ') return false;
        for (seg) |c| switch (c) {
            0...31, '<', '>', ':', '"', '\\', '|', '?', '*' => return false,
            else => {},
        };
    }
    return true;
}

const testing = std.testing;

test "round trip" {
    const entries = [_]Entry{
        .{ .path = "app.exe", .data = "MZ" ++ "\x00" ** 100 },
        .{ .path = "docs/README.md", .data = "# hi\n" },
        .{ .path = "empty.txt", .data = "" },
    };
    const bytes = try encode(testing.allocator, &entries);
    defer testing.allocator.free(bytes);
    var d = try decode(testing.allocator, bytes);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(entries.len, d.entries.len);
    for (entries, d.entries) |a, b| {
        try testing.expectEqualStrings(a.path, b.path);
        try testing.expectEqualSlices(u8, a.data, b.data);
    }
}

test "rejects unsafe paths" {
    for ([_][]const u8{ "", "../x", "a/../b", "/abs", "C:/x", "a\\b", "a//b", "trailing.", "a/./b", "nul\x00" }) |p| {
        try testing.expect(!isSafePath(p));
    }
    try testing.expect(isSafePath("bin/tool.exe"));
    try testing.expectError(error.InvalidPath, encode(testing.allocator, &.{.{ .path = "../evil", .data = "" }}));
}

test "rejects corrupt payloads" {
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, "nope"));
    const bytes = try encode(testing.allocator, &.{.{ .path = "a", .data = "abc" }});
    defer testing.allocator.free(bytes);
    const truncated = bytes[0 .. bytes.len - 2];
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, truncated));
    var wrong_len = try testing.allocator.dupe(u8, bytes);
    defer testing.allocator.free(wrong_len);
    wrong_len[8] +%= 1;
    try testing.expectError(error.InvalidPayload, decode(testing.allocator, wrong_len));
}

test "rejects a payload whose compressed body was changed" {
    const bytes = try encode(testing.allocator, &.{.{ .path = "a", .data = "abc" ** 50 }});
    defer testing.allocator.free(bytes);
    // Every single-byte change after the header, including ones that would
    // still decompress, is caught by the digest.
    for (header_len..bytes.len) |i| {
        const copy = try testing.allocator.dupe(u8, bytes);
        defer testing.allocator.free(copy);
        copy[i] ^= 0x5a;
        try testing.expectError(error.InvalidPayload, decode(testing.allocator, copy));
    }
}
