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

//! The artwork and license text shown by the EXE installer's wizard.
//!
//! zstaller-pack decodes the project's images at build time and stores
//! them, with the license text, in a payload (see `payload.zig`) that the
//! installer embeds. Each image entry is
//!
//!     width   u32 little-endian
//!     height  u32 little-endian
//!     pixels  width * height * 4 bytes, BGRX rows top to bottom
//!
//! which the installer hands straight to a Windows DIB section.
//!
//! The image sizes follow the Windows Installer (WiX) banner and dialog
//! bitmaps, so one set of artwork can serve both installers.

const std = @import("std");
const Allocator = std.mem.Allocator;
const image = @import("../../../image.zig");
const payload = @import("payload.zig");

pub const Kind = enum {
    /// Header of the inner wizard pages. The page title is drawn over its
    /// left part.
    banner,
    /// Background of the Welcome and Finish pages. Text is drawn over
    /// everything right of the left 164 pixels.
    welcome,

    /// Size in pixels at 100% display scaling (96 DPI).
    pub fn size(kind: Kind) [2]u32 {
        return switch (kind) {
            .banner => .{ 493, 58 },
            .welcome => .{ 493, 312 },
        };
    }

    pub fn entryName(kind: Kind) []const u8 {
        return @tagName(kind);
    }
};

pub const license_entry = "license";

/// Width of the artwork strip on the left of the Welcome and Finish
/// pages, in pixels at 100% scaling. The text starts right of it.
pub const welcome_art_width = 164;

/// Whether `width` x `height` is an accepted size for `kind`: the size at
/// 100% scaling or exactly twice it (for sharp high-DPI displays).
pub fn sizeAccepted(kind: Kind, width: u32, height: u32) bool {
    const s = kind.size();
    return (width == s[0] and height == s[1]) or (width == s[0] * 2 and height == s[1] * 2);
}

pub const EncodeError = image.Error || error{WrongSize};

/// Decodes a PNG or BMP file and returns the payload entry data for it.
/// Transparent areas are blended onto white, the wizard's background.
pub fn encodeImage(gpa: Allocator, kind: Kind, file: []const u8) EncodeError![]u8 {
    var img = try image.decode(gpa, file);
    defer img.deinit(gpa);
    if (!sizeAccepted(kind, img.width, img.height)) return error.WrongSize;
    const bgrx = try image.toBgrx(gpa, img, 0xffffff);
    defer gpa.free(bgrx);
    const out = try gpa.alloc(u8, 8 + bgrx.len);
    std.mem.writeInt(u32, out[0..4], img.width, .little);
    std.mem.writeInt(u32, out[4..8], img.height, .little);
    @memcpy(out[8..], bgrx);
    return out;
}

/// The pixels of an image entry.
pub const Bitmap = struct {
    width: u32,
    height: u32,
    bgrx: []const u8,
};

/// Reads an image entry written by `encodeImage`.
pub fn decodeImage(data: []const u8) ?Bitmap {
    if (data.len < 8) return null;
    const w = std.mem.readInt(u32, data[0..4], .little);
    const h = std.mem.readInt(u32, data[4..8], .little);
    if (w == 0 or h == 0 or (data.len - 8) / 4 / w < h or data.len - 8 != @as(u64, w) * h * 4) return null;
    return .{ .width = w, .height = h, .bgrx = data[8..] };
}

/// Wizard content found in an assets payload.
pub const Assets = struct {
    banner: ?Bitmap = null,
    welcome: ?Bitmap = null,
    license: ?[]const u8 = null,
};

/// Finds the wizard content in decoded payload entries.
pub fn find(entries: []const payload.Entry) Assets {
    var a: Assets = .{};
    for (entries) |e| {
        if (std.mem.eql(u8, e.path, Kind.banner.entryName())) a.banner = decodeImage(e.data);
        if (std.mem.eql(u8, e.path, Kind.welcome.entryName())) a.welcome = decodeImage(e.data);
        if (std.mem.eql(u8, e.path, license_entry)) a.license = e.data;
    }
    return a;
}

const testing = std.testing;

test "image entries round trip and sizes are checked" {
    const gpa = testing.allocator;
    const px = try gpa.alloc(u8, 986 * 116 * 4);
    defer gpa.free(px);
    @memset(px, 0xff);
    const png = try image.encodePng(gpa, .{ .width = 986, .height = 116, .rgba = px });
    defer gpa.free(png);

    const entry = try encodeImage(gpa, .banner, png);
    defer gpa.free(entry);
    const bmp = decodeImage(entry).?;
    try testing.expectEqual(@as(u32, 986), bmp.width);
    try testing.expectEqual(@as(u32, 116), bmp.height);
    try testing.expectError(error.WrongSize, encodeImage(gpa, .welcome, png));

    try testing.expect(sizeAccepted(.welcome, 493, 312));
    try testing.expect(sizeAccepted(.welcome, 986, 624));
    try testing.expect(!sizeAccepted(.welcome, 494, 312));
    try testing.expect(decodeImage(entry[0 .. entry.len - 1]) == null);

    const bytes = try payload.encode(gpa, &.{
        .{ .path = "banner", .data = entry },
        .{ .path = "license", .data = "MIT" },
    });
    defer gpa.free(bytes);
    var decoded = try payload.decode(gpa, bytes);
    defer decoded.deinit(gpa);
    const assets = find(decoded.entries);
    try testing.expect(assets.banner != null);
    try testing.expect(assets.welcome == null);
    try testing.expectEqualStrings("MIT", assets.license.?);
}
