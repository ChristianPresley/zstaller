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

//! PNG and BMP decoding for installer artwork.
//!
//! zstaller decodes the images a project supplies for the installer
//! wizard at build time, so a wrong file or size fails the build with a
//! clear message instead of showing a broken installer, and the installer
//! itself needs no image decoder. The result is embedded as raw pixels.
//!
//! Supported: PNG (every color type and bit depth, not interlaced) and
//! uncompressed BMP (8-bit paletted, 24-bit and 32-bit).

const std = @import("std");
const Allocator = std.mem.Allocator;
const deflate = @import("archive/deflate.zig");

/// An image as 8-bit RGBA pixels, rows top to bottom.
pub const Image = struct {
    width: u32,
    height: u32,
    /// `width * height * 4` bytes: R, G, B, A.
    rgba: []u8,

    pub fn deinit(img: *Image, gpa: Allocator) void {
        gpa.free(img.rgba);
        img.* = undefined;
    }
};

pub const Error = error{
    UnknownFormat,
    InvalidImage,
    UnsupportedImage,
    InterlacedPng,
    TooLarge,
} || Allocator.Error;

/// Largest width or height accepted; installer artwork is far smaller.
const max_dimension = 8192;

/// Decodes a PNG or BMP file, recognized by its signature.
pub fn decode(gpa: Allocator, bytes: []const u8) Error!Image {
    if (std.mem.startsWith(u8, bytes, &png_signature)) return decodePng(gpa, bytes);
    if (std.mem.startsWith(u8, bytes, "BM")) return decodeBmp(gpa, bytes);
    return error.UnknownFormat;
}

// ---- PNG

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

pub fn decodePng(gpa: Allocator, bytes: []const u8) Error!Image {
    if (!std.mem.startsWith(u8, bytes, &png_signature)) return error.InvalidImage;
    var pos: usize = png_signature.len;

    var width: u32 = 0;
    var height: u32 = 0;
    var depth: u8 = 0;
    var color: u8 = 0;
    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    var palette_len: usize = 0;
    var trns_gray: ?u16 = null;
    var trns_rgb: ?[3]u16 = null;
    var idat: std.ArrayList(u8) = .empty;
    defer idat.deinit(gpa);
    var seen_header = false;

    while (true) {
        if (bytes.len - pos < 12) return error.InvalidImage;
        const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
        const kind = bytes[pos + 4 ..][0..4];
        if (bytes.len - pos - 12 < len) return error.InvalidImage;
        const data = bytes[pos + 8 ..][0..len];
        const crc = std.mem.readInt(u32, bytes[pos + 8 + len ..][0..4], .big);
        if (std.hash.Crc32.hash(bytes[pos + 4 .. pos + 8 + len]) != crc) return error.InvalidImage;
        pos += 12 + len;

        if (std.mem.eql(u8, kind, "IHDR")) {
            if (len != 13) return error.InvalidImage;
            width = std.mem.readInt(u32, data[0..4], .big);
            height = std.mem.readInt(u32, data[4..8], .big);
            depth = data[8];
            color = data[9];
            if (data[10] != 0 or data[11] != 0) return error.InvalidImage;
            if (data[12] != 0) return error.InterlacedPng;
            if (width == 0 or height == 0) return error.InvalidImage;
            if (width > max_dimension or height > max_dimension) return error.TooLarge;
            const ok = switch (color) {
                0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
                3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
                2, 4, 6 => depth == 8 or depth == 16,
                else => false,
            };
            if (!ok) return error.InvalidImage;
            seen_header = true;
        } else if (!seen_header) {
            return error.InvalidImage;
        } else if (std.mem.eql(u8, kind, "PLTE")) {
            if (len % 3 != 0 or len / 3 > 256) return error.InvalidImage;
            palette_len = len / 3;
            for (0..palette_len) |i| palette[i] = .{ data[i * 3], data[i * 3 + 1], data[i * 3 + 2], 255 };
        } else if (std.mem.eql(u8, kind, "tRNS")) {
            switch (color) {
                0 => if (len >= 2) {
                    trns_gray = std.mem.readInt(u16, data[0..2], .big);
                },
                2 => if (len >= 6) {
                    trns_rgb = .{
                        std.mem.readInt(u16, data[0..2], .big),
                        std.mem.readInt(u16, data[2..4], .big),
                        std.mem.readInt(u16, data[4..6], .big),
                    };
                },
                3 => for (data[0..@min(len, 256)], 0..) |a, i| {
                    palette[i][3] = a;
                },
                else => {},
            }
        } else if (std.mem.eql(u8, kind, "IDAT")) {
            try idat.appendSlice(gpa, data);
        } else if (std.mem.eql(u8, kind, "IEND")) {
            break;
        } else if (kind[0] & 0x20 == 0) {
            // An unknown critical chunk: the image cannot be decoded
            // correctly without it.
            return error.UnsupportedImage;
        }
    }
    if (!seen_header or idat.items.len == 0) return error.InvalidImage;
    if (color == 3 and palette_len == 0) return error.InvalidImage;

    const channels: u32 = switch (color) {
        0, 3 => 1,
        2 => 3,
        4 => 2,
        6 => 4,
        else => unreachable,
    };
    const bits_pp = channels * depth;
    const stride: usize = (@as(usize, width) * bits_pp + 7) / 8;
    const bpp: usize = @max(1, bits_pp / 8);

    const raw = deflate.decompress(gpa, idat.items, .zlib) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidImage,
    };
    defer gpa.free(raw);
    if (raw.len < (stride + 1) * height) return error.InvalidImage;

    // Undo the per-row filters in place, keeping each row's filter byte.
    var prev: ?[]const u8 = null;
    for (0..height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        try unfilter(raw[y * (stride + 1)], row, prev, bpp);
        prev = row;
    }

    const out = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(out);
    for (0..height) |y| {
        const row = raw[y * (stride + 1) + 1 ..][0..stride];
        for (0..width) |x| {
            const px = out[(y * width + x) * 4 ..][0..4];
            switch (color) {
                0 => {
                    const v = sample(row, x, depth);
                    const g = scaleTo8(v, depth);
                    const a: u8 = if (trns_gray) |t| (if (t == v) 0 else 255) else 255;
                    px.* = .{ g, g, g, a };
                },
                3 => {
                    const i = sample(row, x, depth);
                    if (i >= palette_len) return error.InvalidImage;
                    px.* = palette[i];
                },
                2 => {
                    const r = sample(row, x * 3, depth);
                    const g = sample(row, x * 3 + 1, depth);
                    const b = sample(row, x * 3 + 2, depth);
                    const a: u8 = if (trns_rgb) |t| (if (t[0] == r and t[1] == g and t[2] == b) 0 else 255) else 255;
                    px.* = .{ scaleTo8(r, depth), scaleTo8(g, depth), scaleTo8(b, depth), a };
                },
                4 => {
                    const g = scaleTo8(sample(row, x * 2, depth), depth);
                    px.* = .{ g, g, g, scaleTo8(sample(row, x * 2 + 1, depth), depth) };
                },
                6 => for (px, 0..) |*c, i| {
                    c.* = scaleTo8(sample(row, x * 4 + i, depth), depth);
                },
                else => unreachable,
            }
        }
    }
    return .{ .width = width, .height = height, .rgba = out };
}

fn unfilter(filter: u8, row: []u8, prev: ?[]const u8, bpp: usize) Error!void {
    switch (filter) {
        0 => {},
        1 => for (bpp..row.len) |i| {
            row[i] +%= row[i - bpp];
        },
        2 => if (prev) |p| for (row, p) |*c, b| {
            c.* +%= b;
        },
        3 => for (row, 0..) |*c, i| {
            const a: u16 = if (i >= bpp) row[i - bpp] else 0;
            const b: u16 = if (prev) |p| p[i] else 0;
            c.* +%= @intCast((a + b) / 2);
        },
        4 => for (row, 0..) |*c, i| {
            const a: u8 = if (i >= bpp) row[i - bpp] else 0;
            const b: u8 = if (prev) |p| p[i] else 0;
            const cc: u8 = if (i >= bpp) (if (prev) |p| p[i - bpp] else 0) else 0;
            c.* +%= paeth(a, b, cc);
        },
        else => return error.InvalidImage,
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const p: i16 = @as(i16, a) + b - c;
    const pa = @abs(p - a);
    const pb = @abs(p - b);
    const pc = @abs(p - c);
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

/// The `index`th sample of `row` at `depth` bits per sample.
fn sample(row: []const u8, index: usize, depth: u8) u16 {
    return switch (depth) {
        16 => std.mem.readInt(u16, row[index * 2 ..][0..2], .big),
        8 => row[index],
        else => blk: {
            const bit = index * depth;
            const shift: u3 = @intCast(8 - depth - (bit % 8));
            const mask: u8 = @intCast((@as(u16, 1) << @intCast(depth)) - 1);
            break :blk (row[bit / 8] >> shift) & mask;
        },
    };
}

fn scaleTo8(v: u16, depth: u8) u8 {
    return switch (depth) {
        16 => @intCast(v >> 8),
        8 => @intCast(v),
        else => @intCast(v * 255 / ((@as(u16, 1) << @intCast(depth)) - 1)),
    };
}

// ---- BMP

pub fn decodeBmp(gpa: Allocator, bytes: []const u8) Error!Image {
    if (bytes.len < 54 or !std.mem.startsWith(u8, bytes, "BM")) return error.InvalidImage;
    const data_offset = std.mem.readInt(u32, bytes[10..14], .little);
    const header_size = std.mem.readInt(u32, bytes[14..18], .little);
    if (header_size < 40 or 14 + header_size > bytes.len) return error.InvalidImage;
    const width_raw = std.mem.readInt(i32, bytes[18..22], .little);
    const height_raw = std.mem.readInt(i32, bytes[22..26], .little);
    const planes = std.mem.readInt(u16, bytes[26..28], .little);
    const bit_count = std.mem.readInt(u16, bytes[28..30], .little);
    const compression = std.mem.readInt(u32, bytes[30..34], .little);
    const colors_used = std.mem.readInt(u32, bytes[46..50], .little);
    if (planes != 1 or width_raw <= 0 or height_raw == 0) return error.InvalidImage;
    const width: u32 = @intCast(width_raw);
    const height: u32 = @abs(height_raw);
    if (width > max_dimension or height > max_dimension) return error.TooLarge;
    const top_down = height_raw < 0;

    const bi_rgb = 0;
    const bi_bitfields = 3;
    var masks: [4]u32 = .{ 0x00ff0000, 0x0000ff00, 0x000000ff, 0 };
    switch (bit_count) {
        8 => if (compression != bi_rgb) return error.UnsupportedImage,
        24 => if (compression != bi_rgb) return error.UnsupportedImage,
        32 => if (compression == bi_bitfields) {
            // The masks follow a 40-byte header, or are part of a V4/V5 one.
            if (14 + 40 + 12 > bytes.len) return error.InvalidImage;
            for (0..3) |i| masks[i] = std.mem.readInt(u32, bytes[54 + i * 4 ..][0..4], .little);
            if (header_size >= 56 and 14 + 56 <= bytes.len) masks[3] = std.mem.readInt(u32, bytes[66..70], .little);
            for (masks[0..3]) |m| if (m == 0 or @popCount(m) != 8 or @ctz(m) % 8 != 0) return error.UnsupportedImage;
        } else if (compression != bi_rgb) return error.UnsupportedImage,
        else => return error.UnsupportedImage,
    }

    var palette: [256][4]u8 = @splat(.{ 0, 0, 0, 255 });
    if (bit_count == 8) {
        const count: usize = if (colors_used == 0) 256 else @min(colors_used, 256);
        const start = 14 + header_size;
        if (start + count * 4 > bytes.len) return error.InvalidImage;
        for (0..count) |i| {
            const e = bytes[start + i * 4 ..][0..4];
            palette[i] = .{ e[2], e[1], e[0], 255 };
        }
    }

    const stride: usize = ((@as(usize, width) * bit_count + 31) / 32) * 4;
    if (data_offset > bytes.len or bytes.len - data_offset < stride * height) return error.InvalidImage;

    // A 32-bit image whose alpha is zero everywhere was saved without
    // alpha (common for BI_RGB); treat it as opaque.
    var use_alpha = false;
    if (bit_count == 32) {
        const has_mask = compression != bi_bitfields or masks[3] != 0;
        if (has_mask) {
            for (0..height) |y| {
                const row = bytes[data_offset + y * stride ..][0..stride];
                for (0..width) |x| {
                    const v = std.mem.readInt(u32, row[x * 4 ..][0..4], .little);
                    const a = if (compression == bi_bitfields) channel(v, masks[3]) else @as(u8, @intCast(v >> 24));
                    if (a != 0) use_alpha = true;
                }
            }
        }
    }

    const out = try gpa.alloc(u8, @as(usize, width) * height * 4);
    errdefer gpa.free(out);
    for (0..height) |y| {
        const src_y = if (top_down) y else height - 1 - y;
        const row = bytes[data_offset + src_y * stride ..][0..stride];
        for (0..width) |x| {
            const px = out[(y * width + x) * 4 ..][0..4];
            switch (bit_count) {
                8 => px.* = palette[row[x]],
                24 => px.* = .{ row[x * 3 + 2], row[x * 3 + 1], row[x * 3], 255 },
                32 => {
                    const v = std.mem.readInt(u32, row[x * 4 ..][0..4], .little);
                    const a: u8 = if (!use_alpha) 255 else if (compression == bi_bitfields) channel(v, masks[3]) else @intCast(v >> 24);
                    px.* = .{ channel(v, masks[0]), channel(v, masks[1]), channel(v, masks[2]), a };
                },
                else => unreachable,
            }
        }
    }
    return .{ .width = width, .height = height, .rgba = out };
}

fn channel(v: u32, mask: u32) u8 {
    if (mask == 0) return 255;
    return @truncate((v & mask) >> @intCast(@ctz(mask)));
}

// ---- Output

/// Returns the image as 32-bit top-down BGRX rows (the layout of a Windows
/// DIB section), with transparent pixels blended onto `background`
/// (0xRRGGBB).
pub fn toBgrx(gpa: Allocator, img: Image, background: u24) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, img.rgba.len);
    const bg = [3]u16{ @as(u8, @truncate(background >> 16)), @as(u8, @truncate(background >> 8)), @as(u8, @truncate(background)) };
    var i: usize = 0;
    while (i < img.rgba.len) : (i += 4) {
        const a: u16 = img.rgba[i + 3];
        var rgb: [3]u8 = undefined;
        for (&rgb, 0..) |*c, k| {
            c.* = @intCast((@as(u16, img.rgba[i + k]) * a + bg[k] * (255 - a) + 127) / 255);
        }
        out[i..][0..4].* = .{ rgb[2], rgb[1], rgb[0], 0 };
    }
    return out;
}

/// Writes `img` as a PNG (RGBA, 8-bit). Used by tests and to generate
/// sample artwork.
pub fn encodePng(gpa: Allocator, img: Image) Allocator.Error![]u8 {
    const stride = @as(usize, img.width) * 4;
    const raw = try gpa.alloc(u8, (stride + 1) * img.height);
    defer gpa.free(raw);
    for (0..img.height) |y| {
        raw[y * (stride + 1)] = 0;
        @memcpy(raw[y * (stride + 1) + 1 ..][0..stride], img.rgba[y * stride ..][0..stride]);
    }
    const z = try deflate.compress(gpa, raw, .zlib);
    defer gpa.free(z);

    var out: std.Io.Writer.Allocating = .init(gpa);
    errdefer out.deinit();
    const w = &out.writer;
    w.writeAll(&png_signature) catch return error.OutOfMemory;
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], img.width, .big);
    std.mem.writeInt(u32, ihdr[4..8], img.height, .big);
    ihdr[8..13].* = .{ 8, 6, 0, 0, 0 };
    writeChunk(w, "IHDR", &ihdr) catch return error.OutOfMemory;
    writeChunk(w, "IDAT", z) catch return error.OutOfMemory;
    writeChunk(w, "IEND", "") catch return error.OutOfMemory;
    return out.toOwnedSlice();
}

fn writeChunk(w: *std.Io.Writer, kind: *const [4]u8, data: []const u8) !void {
    try w.writeInt(u32, @intCast(data.len), .big);
    try w.writeAll(kind);
    try w.writeAll(data);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(data);
    try w.writeInt(u32, crc.final(), .big);
}

const testing = std.testing;

fn testImage(gpa: Allocator, w: u32, h: u32) !Image {
    const px = try gpa.alloc(u8, w * h * 4);
    for (0..h) |y| for (0..w) |x| {
        px[(y * w + x) * 4 ..][0..4].* = .{ @intCast(x * 40), @intCast(y * 60), @intCast((x + y) * 10), @intCast(255 - x * 20) };
    };
    return .{ .width = w, .height = h, .rgba = px };
}

test "png round trip" {
    const gpa = testing.allocator;
    var img = try testImage(gpa, 5, 3);
    defer img.deinit(gpa);
    const png = try encodePng(gpa, img);
    defer gpa.free(png);
    var back = try decode(gpa, png);
    defer back.deinit(gpa);
    try testing.expectEqual(img.width, back.width);
    try testing.expectEqual(img.height, back.height);
    try testing.expectEqualSlices(u8, img.rgba, back.rgba);
}

test "png filters, palettes and low bit depths" {
    const gpa = testing.allocator;
    // 4x2, color type 3 (palette), 2 bits per pixel, filter types Sub and
    // Paeth; built by hand.
    const rows = [_]u8{
        1, 0b00_01_10_11, // Sub: deltas over packed bytes
        4, 0b00_00_00_00, // Paeth: same as the row above
    };
    // Sub on a 1-byte-per-pixel row with a single byte is a no-op.
    const z = try deflate.compress(gpa, &rows, .zlib);
    defer gpa.free(z);
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    const w = &out.writer;
    try w.writeAll(&png_signature);
    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], 4, .big);
    std.mem.writeInt(u32, ihdr[4..8], 2, .big);
    ihdr[8..13].* = .{ 2, 3, 0, 0, 0 };
    try writeChunk(w, "IHDR", &ihdr);
    try writeChunk(w, "PLTE", &.{ 255, 0, 0, 0, 255, 0, 0, 0, 255, 9, 9, 9 });
    try writeChunk(w, "tRNS", &.{ 255, 128 });
    try writeChunk(w, "IDAT", z);
    try writeChunk(w, "IEND", "");

    var img = try decode(gpa, out.written());
    defer img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 255, 9, 9, 9, 255 }, img.rgba[0..16]);
    try testing.expectEqualSlices(u8, img.rgba[0..16], img.rgba[16..32]);
}

test "png rejects corrupt and interlaced files" {
    const gpa = testing.allocator;
    var img = try testImage(gpa, 2, 2);
    defer img.deinit(gpa);
    const png = try encodePng(gpa, img);
    defer gpa.free(png);
    const bad = try gpa.dupe(u8, png);
    defer gpa.free(bad);
    bad[20] ^= 1; // inside IHDR: the CRC no longer matches
    try testing.expectError(error.InvalidImage, decode(gpa, bad));
    @memcpy(bad, png);
    bad[8 + 8 + 12] = 1; // interlace method
    // Fix the CRC so the interlace check is what fails.
    std.mem.writeInt(u32, bad[29..33], std.hash.Crc32.hash(bad[12..29]), .big);
    try testing.expectError(error.InterlacedPng, decode(gpa, bad));
    try testing.expectError(error.UnknownFormat, decode(gpa, "GIF89a"));
}

fn bmpHeader(buf: []u8, w: i32, h: i32, bits: u16, data_offset: u32, header_size: u32, compression: u32) void {
    @memset(buf, 0);
    buf[0..2].* = "BM".*;
    std.mem.writeInt(u32, buf[2..6], @intCast(buf.len), .little);
    std.mem.writeInt(u32, buf[10..14], data_offset, .little);
    std.mem.writeInt(u32, buf[14..18], header_size, .little);
    std.mem.writeInt(i32, buf[18..22], w, .little);
    std.mem.writeInt(i32, buf[22..26], h, .little);
    std.mem.writeInt(u16, buf[26..28], 1, .little);
    std.mem.writeInt(u16, buf[28..30], bits, .little);
    std.mem.writeInt(u32, buf[30..34], compression, .little);
}

test "bmp 24-bit bottom-up" {
    const gpa = testing.allocator;
    // 2x2: stride 8 (6 bytes padded to 8).
    var buf: [54 + 16]u8 = undefined;
    bmpHeader(&buf, 2, 2, 24, 54, 40, 0);
    // Bottom row first: blue, green; then top row: red, white.
    buf[54..70].* = .{ 255, 0, 0, 0, 255, 0, 0, 0, 0, 0, 255, 255, 255, 255, 0, 0 };
    var img = try decode(gpa, &buf);
    defer img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{
        255, 0, 0,   255, 255, 255, 255, 255,
        0,   0, 255, 255, 0,   255, 0,   255,
    }, img.rgba);
}

test "bmp 32-bit with and without alpha, and 8-bit palette" {
    const gpa = testing.allocator;
    var buf: [54 + 8]u8 = undefined;
    bmpHeader(&buf, 2, -1, 32, 54, 40, 0);
    buf[54..62].* = .{ 1, 2, 3, 0, 4, 5, 6, 0 };
    var opaque_img = try decode(gpa, &buf);
    defer opaque_img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 255, 6, 5, 4, 255 }, opaque_img.rgba);
    buf[57] = 128;
    var alpha_img = try decode(gpa, &buf);
    defer alpha_img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 128, 6, 5, 4, 0 }, alpha_img.rgba);

    var pal: [54 + 8 + 4]u8 = undefined;
    bmpHeader(&pal, 3, 1, 8, 62, 40, 0);
    std.mem.writeInt(u32, pal[46..50], 2, .little);
    pal[54..62].* = .{ 10, 20, 30, 0, 40, 50, 60, 0 };
    pal[62..66].* = .{ 1, 0, 1, 0 };
    var pal_img = try decode(gpa, &pal);
    defer pal_img.deinit(gpa);
    try testing.expectEqualSlices(u8, &.{ 60, 50, 40, 255, 30, 20, 10, 255, 60, 50, 40, 255 }, pal_img.rgba);
}

test "toBgrx blends onto the background" {
    const gpa = testing.allocator;
    var px = [_]u8{ 255, 0, 0, 255, 0, 0, 255, 0 };
    const out = try toBgrx(gpa, .{ .width = 2, .height = 1, .rgba = &px }, 0xffffff);
    defer gpa.free(out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 255, 0, 255, 255, 255, 0 }, out);
}
