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

//! The payload of an EXE installer, appended to the linked setup program
//! as a PE overlay (data after the last section, which Windows does not
//! load). Keeping it out of the program's sections means the setup
//! program is compiled once per target and configuration, not again for
//! every change to the application.
//!
//! Layout at the end of the file, before any Authenticode signature:
//!
//!     image        the setup program, as linked
//!     padding      zeros up to a multiple of 8
//!     payload      `payload.zig` bytes
//!     padding      zeros, so the trailer ends on a multiple of 8
//!     trailer      magic "ZSTLOVL1", offset u64, length u64 (little-endian)
//!
//! A signing tool appends its certificate table after the trailer and
//! records where it starts in the PE security directory; `extract` looks
//! for the trailer just before that. Ending on a multiple of 8 means the
//! tool has no padding to add in between.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const magic = "ZSTLOVL1";
const trailer_len = magic.len + 16;

/// Returns `image` with `payload` appended as an overlay.
pub fn append(gpa: Allocator, image: []const u8, payload: []const u8) Allocator.Error![]u8 {
    const start = std.mem.alignForward(usize, image.len, 8);
    const end = std.mem.alignForward(usize, start + payload.len + trailer_len, 8);
    const out = try gpa.alloc(u8, end);
    @memset(out, 0);
    @memcpy(out[0..image.len], image);
    @memcpy(out[start..][0..payload.len], payload);
    const trailer = out[end - trailer_len ..];
    @memcpy(trailer[0..magic.len], magic);
    std.mem.writeInt(u64, trailer[8..16], start, .little);
    std.mem.writeInt(u64, trailer[16..24], payload.len, .little);
    return out;
}

/// Finds the payload in the bytes of a setup program, signed or not.
/// Null when there is none or the file is damaged.
pub fn extract(file: []const u8) ?[]const u8 {
    const end = signatureStart(file) orelse file.len;
    if (end < trailer_len or end > file.len) return null;
    const trailer = file[end - trailer_len .. end];
    if (!std.mem.eql(u8, trailer[0..magic.len], magic)) return null;
    const offset = std.mem.readInt(u64, trailer[8..16], .little);
    const len = std.mem.readInt(u64, trailer[16..24], .little);
    if (offset > end - trailer_len or len > end - trailer_len - offset) return null;
    return file[@intCast(offset)..][0..@intCast(len)];
}

/// Where the Authenticode certificate table starts, from the PE security
/// directory, or null when the file is not signed.
fn signatureStart(file: []const u8) ?usize {
    if (file.len < 0x40 or !std.mem.eql(u8, file[0..2], "MZ")) return null;
    const pe = std.mem.readInt(u32, file[0x3C..0x40], .little);
    const opt = @as(usize, pe) + 4 + 20;
    if (opt + 2 > file.len or !std.mem.eql(u8, file[pe..][0..4], "PE\x00\x00")) return null;
    const dirs: usize = switch (std.mem.readInt(u16, file[opt..][0..2], .little)) {
        0x10b => opt + 96,
        0x20b => opt + 112,
        else => return null,
    };
    const security = dirs + 4 * 8;
    if (security + 8 > file.len) return null;
    const offset = std.mem.readInt(u32, file[security..][0..4], .little);
    const size = std.mem.readInt(u32, file[security + 4 ..][0..4], .little);
    if (offset == 0 or size == 0) return null;
    return offset;
}

const testing = std.testing;

/// A minimal PE32+ header with room for the data directories.
fn fakeImage(buf: []u8) []u8 {
    @memset(buf, 0);
    @memcpy(buf[0..2], "MZ");
    std.mem.writeInt(u32, buf[0x3C..0x40], 0x40, .little);
    @memcpy(buf[0x40..0x44], "PE\x00\x00");
    std.mem.writeInt(u16, buf[0x58..0x5A], 0x20b, .little);
    return buf;
}

test "round trip, unsigned" {
    var buf: [0x200 + 3]u8 = undefined;
    const image = fakeImage(&buf);
    const out = try append(testing.allocator, image, "payload bytes");
    defer testing.allocator.free(out);
    try testing.expectEqual(0, out.len % 8);
    try testing.expectEqualStrings("payload bytes", extract(out).?);
    try testing.expectEqualSlices(u8, image, out[0..image.len]);
}

test "round trip, signed" {
    var buf: [0x200]u8 = undefined;
    const image = fakeImage(&buf);
    const unsigned = try append(testing.allocator, image, "abc");
    defer testing.allocator.free(unsigned);
    // What a signing tool does: append a certificate table and point the
    // security directory (data directory 4) at it.
    const signed = try std.mem.concat(testing.allocator, u8, &.{ unsigned, "CERTIFICATE TABLE" });
    defer testing.allocator.free(signed);
    const security = 0x58 + 112 + 4 * 8;
    std.mem.writeInt(u32, signed[security..][0..4], @intCast(unsigned.len), .little);
    std.mem.writeInt(u32, signed[security + 4 ..][0..4], 17, .little);
    try testing.expectEqualStrings("abc", extract(signed).?);
}

test "rejects files without a payload" {
    var buf: [0x200]u8 = undefined;
    try testing.expectEqual(null, extract(fakeImage(&buf)));
    try testing.expectEqual(null, extract("short"));
    const out = try append(testing.allocator, fakeImage(&buf), "abc");
    defer testing.allocator.free(out);
    // A length that runs past the trailer.
    std.mem.writeInt(u64, out[out.len - 8 ..][0..8], 1 << 40, .little);
    try testing.expectEqual(null, extract(out));
}
