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

//! In-memory DEFLATE helpers on top of `std.compress.flate`.

const std = @import("std");
const flate = std.compress.flate;
const Allocator = std.mem.Allocator;

pub const Container = flate.Container;

/// Compresses `data` into a newly allocated buffer using `container`
/// framing (`.raw`, `.gzip` or `.zlib`).
pub fn compress(gpa: Allocator, data: []const u8, container: Container) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
    errdefer out.deinit();
    try compressTo(gpa, &out.writer, data, container);
    return out.toOwnedSlice();
}

/// gzip at the highest compression level, with the header saying so (as
/// Debian expects of manual pages and changelogs).
pub fn gzipBest(gpa: Allocator, data: []const u8) Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, data.len / 2 + 64);
    errdefer out.deinit();
    try compressLevel(gpa, &out.writer, data, .gzip, .best);
    const bytes = try out.toOwnedSlice();
    // XFL: 2 = maximum compression (RFC 1952, section 2.3.1).
    bytes[8] = 2;
    return bytes;
}

/// Compresses `data` into `w`. `w` must be an allocating or otherwise
/// unbounded writer; write failures are reported as OutOfMemory.
pub fn compressTo(gpa: Allocator, w: *std.Io.Writer, data: []const u8, container: Container) Allocator.Error!void {
    return compressLevel(gpa, w, data, container, .default);
}

fn compressLevel(gpa: Allocator, w: *std.Io.Writer, data: []const u8, container: Container, options: flate.Compress.Options) Allocator.Error!void {
    const window = try gpa.alloc(u8, flate.max_window_len);
    defer gpa.free(window);
    const c = try gpa.create(flate.Compress);
    defer gpa.destroy(c);
    c.* = flate.Compress.init(w, window, container, options) catch return error.OutOfMemory;
    c.writer.writeAll(data) catch return error.OutOfMemory;
    c.finish() catch return error.OutOfMemory;
}

/// Decompresses `data` (for tests and payload extraction).
pub fn decompress(gpa: Allocator, data: []const u8, container: Container) ![]u8 {
    var in: std.Io.Reader = .fixed(data);
    var window: [flate.max_window_len]u8 = undefined;
    var d: flate.Decompress = .init(&in, container, &window);
    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    _ = try d.reader.streamRemaining(&out.writer);
    return out.toOwnedSlice();
}

test "round trip all containers" {
    const gpa = std.testing.allocator;
    const input = "zstaller " ** 1000 ++ "tail";
    inline for (.{ Container.raw, Container.gzip, Container.zlib }) |container| {
        const packed_bytes = try compress(gpa, input, container);
        defer gpa.free(packed_bytes);
        try std.testing.expect(packed_bytes.len < input.len / 4);
        const unpacked = try decompress(gpa, packed_bytes, container);
        defer gpa.free(unpacked);
        try std.testing.expectEqualStrings(input, unpacked);
    }
}

test "gzipBest round trips and marks maximum compression" {
    const gpa = std.testing.allocator;
    const input = "man page text " ** 200;
    const gz = try gzipBest(gpa, input);
    defer gpa.free(gz);
    try std.testing.expectEqual(@as(u8, 2), gz[8]);
    const back = try decompress(gpa, gz, .gzip);
    defer gpa.free(back);
    try std.testing.expectEqualStrings(input, back);
}

test "gzip header magic" {
    const gpa = std.testing.allocator;
    const gz = try compress(gpa, "", .gzip);
    defer gpa.free(gz);
    try std.testing.expectEqual(@as(u8, 0x1f), gz[0]);
    try std.testing.expectEqual(@as(u8, 0x8b), gz[1]);
}
