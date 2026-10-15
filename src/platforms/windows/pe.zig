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

//! Makes linked PE images independent of where they were built.
//!
//! The linker derives a PE image's CodeView GUID (the "RSDS" record that
//! ties the image to its .pdb) from the contents of the .pdb, and with
//! reproducible linking the COFF and debug-directory timestamps are taken
//! from the same hash. A .pdb records the absolute paths of the object
//! files and of the build cache, so two builds of the same source in
//! different directories produce images that differ in those fields alone.
//!
//! `normalize` replaces every such field with a value derived from the rest
//! of the image: it zeroes the fields, hashes the image with SHA-256, and
//! writes the hash back as the CodeView GUID, the timestamps and the
//! contents of any repro debug entry, the same scheme the linker's own
//! reproducible mode uses, minus the .pdb. The resulting image depends only
//! on its code and data. Images without debug info are handled the same
//! way, so every Windows binary zstaller packages goes through one path.
//!
//! The image no longer matches the .pdb left in the build cache, which
//! zstaller never packages.

const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Error = error{InvalidPe};

const image_debug_type_codeview = 2;
const image_debug_type_repro = 16;
const debug_directory_index = 6;
const debug_entry_size = 28;
const section_header_size = 40;

/// A byte range rewritten by `normalize`.
const Field = struct { offset: usize, len: usize };

const Layout = struct {
    /// COFF header TimeDateStamp, the debug entries' TimeDateStamps and
    /// repro data, and the CodeView GUIDs.
    buf: [64]Field = undefined,
    len: usize = 0,
    /// Offset of the optional header's CheckSum.
    checksum_offset: usize = 0,

    fn fields(l: *const Layout) []const Field {
        return l.buf[0..l.len];
    }
};

/// Rewrites `image` in place so that it no longer depends on the build
/// paths recorded in its .pdb.
pub fn normalize(image: []u8) Error!void {
    const layout = try parse(image);
    for (layout.fields()) |f| @memset(image[f.offset..][0..f.len], 0);
    const old_checksum = std.mem.readInt(u32, image[layout.checksum_offset..][0..4], .little);
    std.mem.writeInt(u32, image[layout.checksum_offset..][0..4], 0, .little);

    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(image, &digest, .{});
    for (layout.fields()) |f| {
        var i: usize = 0;
        while (i < f.len) : (i += digest.len) {
            const n = @min(digest.len, f.len - i);
            @memcpy(image[f.offset + i ..][0..n], digest[0..n]);
        }
    }
    // The linker only sets the checksum when asked to; keep it that way.
    if (old_checksum != 0) {
        std.mem.writeInt(u32, image[layout.checksum_offset..][0..4], peChecksum(image, layout.checksum_offset), .little);
    }
}

fn parse(image: []const u8) Error!Layout {
    var layout: Layout = .{};
    if (image.len < 0x40 or !std.mem.eql(u8, image[0..2], "MZ")) return error.InvalidPe;
    const pe = std.mem.readInt(u32, image[0x3c..][0..4], .little);
    const coff = try range(image, pe, 24);
    if (!std.mem.eql(u8, image[pe..][0..4], "PE\x00\x00")) return error.InvalidPe;
    const num_sections = read(u16, image, coff + 6);
    const opt_size = read(u16, image, coff + 20);
    try add(&layout, image, coff + 8, 4);

    const opt = coff + 24;
    _ = try range(image, opt, opt_size);
    const dirs: usize, const num_dirs_offset: usize = switch (read(u16, image, opt)) {
        0x10b => .{ opt + 96, opt + 92 },
        0x20b => .{ opt + 112, opt + 108 },
        else => return error.InvalidPe,
    };
    if (opt_size < 68 or num_dirs_offset + 4 > opt + opt_size) return error.InvalidPe;
    layout.checksum_offset = opt + 64;
    const num_dirs = read(u32, image, num_dirs_offset);
    const sections = opt + opt_size;
    _ = try range(image, sections, @as(usize, num_sections) * section_header_size);

    if (num_dirs <= debug_directory_index) return layout;
    const dir = dirs + debug_directory_index * 8;
    if (dir + 8 > opt + opt_size) return error.InvalidPe;
    const debug_rva = read(u32, image, dir);
    const debug_size = read(u32, image, dir + 4);
    if (debug_rva == 0 or debug_size == 0) return layout;
    const debug = try rvaToOffset(image, sections, num_sections, debug_rva, debug_size);

    var entry = debug;
    while (entry + debug_entry_size <= debug + debug_size) : (entry += debug_entry_size) {
        try add(&layout, image, entry + 4, 4);
        const kind = read(u32, image, entry + 12);
        const size = read(u32, image, entry + 16);
        const data = read(u32, image, entry + 24);
        switch (kind) {
            image_debug_type_codeview => {
                const rec = try range(image, data, size);
                if (size >= 24 and std.mem.eql(u8, image[rec..][0..4], "RSDS")) try add(&layout, image, rec + 4, 16);
            },
            image_debug_type_repro => if (size > 0) try add(&layout, image, try range(image, data, size), size),
            else => {},
        }
    }
    return layout;
}

fn add(layout: *Layout, image: []const u8, offset: usize, len: usize) Error!void {
    _ = try range(image, offset, len);
    if (layout.len == layout.buf.len) return error.InvalidPe;
    layout.buf[layout.len] = .{ .offset = offset, .len = len };
    layout.len += 1;
}

fn range(image: []const u8, offset: usize, len: usize) Error!usize {
    if (offset > image.len or len > image.len - offset) return error.InvalidPe;
    return offset;
}

fn read(comptime T: type, image: []const u8, offset: usize) T {
    return std.mem.readInt(T, image[offset..][0..@sizeOf(T)], .little);
}

fn rvaToOffset(image: []const u8, sections: usize, count: u16, rva: u32, len: u32) Error!usize {
    for (0..count) |i| {
        const s = sections + i * section_header_size;
        const va = read(u32, image, s + 12);
        const raw_size = read(u32, image, s + 16);
        const raw = read(u32, image, s + 20);
        if (rva >= va and @as(u64, rva) + len <= @as(u64, va) + raw_size) {
            return range(image, raw + (rva - va), len);
        }
    }
    return error.InvalidPe;
}

/// The PE image checksum (as computed by `CheckSumMappedFile`): a 16-bit
/// one's-complement style sum of the image as little-endian words, with
/// the CheckSum field itself treated as zero, plus the image length.
fn peChecksum(image: []const u8, checksum_offset: usize) u32 {
    var sum: u64 = 0;
    var i: usize = 0;
    while (i < image.len) : (i += 2) {
        if (i == checksum_offset or i == checksum_offset + 2) continue;
        const lo: u64 = image[i];
        const hi: u64 = if (i + 1 < image.len) image[i + 1] else 0;
        sum += lo | hi << 8;
        sum = (sum & 0xffff) + (sum >> 16);
    }
    sum = (sum & 0xffff) + (sum >> 16);
    sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(sum + image.len);
}

/// A minimal PE32+ image with one section holding a debug directory (a
/// CodeView entry and a repro entry) followed by `code`.
fn testImage(code: []const u8, timestamp: u32, guid: [16]u8, checksum: u32) [0x400]u8 {
    var img = [_]u8{0} ** 0x400;
    const w = struct {
        fn int(buf: []u8, comptime T: type, off: usize, v: T) void {
            std.mem.writeInt(T, buf[off..][0..@sizeOf(T)], v, .little);
        }
    }.int;
    @memcpy(img[0..2], "MZ");
    w(&img, u32, 0x3c, 0x40);
    @memcpy(img[0x40..0x44], "PE\x00\x00");
    const coff = 0x44;
    w(&img, u16, coff, 0xaa64);
    w(&img, u16, coff + 2, 1);
    w(&img, u32, coff + 4, timestamp);
    w(&img, u16, coff + 16, 240);
    const opt = coff + 20;
    w(&img, u16, opt, 0x20b);
    w(&img, u32, opt + 64, checksum);
    w(&img, u32, opt + 108, 16);
    w(&img, u32, opt + 112 + 6 * 8, 0x1000);
    w(&img, u32, opt + 112 + 6 * 8 + 4, 2 * 28);
    const sec = opt + 240;
    w(&img, u32, sec + 8, 0x200);
    w(&img, u32, sec + 12, 0x1000);
    w(&img, u32, sec + 16, 0x200);
    w(&img, u32, sec + 20, 0x200);
    // Debug directory at file offset 0x200.
    w(&img, u32, 0x200 + 4, timestamp);
    w(&img, u32, 0x200 + 12, image_debug_type_codeview);
    w(&img, u32, 0x200 + 16, 24 + 11);
    w(&img, u32, 0x200 + 24, 0x240);
    w(&img, u32, 0x200 + 28 + 4, timestamp);
    w(&img, u32, 0x200 + 28 + 12, image_debug_type_repro);
    @memcpy(img[0x240..0x244], "RSDS");
    @memcpy(img[0x244..0x254], &guid);
    w(&img, u32, 0x254, 1);
    @memcpy(img[0x258..0x263], "sample.pdb\x00");
    @memcpy(img[0x300..][0..code.len], code);
    return img;
}

test "normalize makes images that differ only in build-path-derived fields identical" {
    var a = testImage("code", 0x11111111, @splat(0xaa), 0);
    var b = testImage("code", 0x22222222, @splat(0xbb), 0);
    try normalize(&a);
    try normalize(&b);
    try std.testing.expectEqualSlices(u8, &a, &b);
    // The fields now hold the hash, not zeroes.
    try std.testing.expect(!std.mem.allEqual(u8, a[0x244..0x254], 0));
    try std.testing.expectEqualSlices(u8, a[0x244..0x248], a[0x48..0x4c]);
    try std.testing.expectEqualSlices(u8, a[0x48..0x4c], a[0x204..0x208]);
    // Everything else is untouched.
    try std.testing.expectEqualStrings("sample.pdb", a[0x258..0x262]);
    try std.testing.expectEqual(1, std.mem.readInt(u32, a[0x254..0x258], .little));
}

test "normalize is idempotent and depends on the code" {
    var a = testImage("code", 1, @splat(1), 0);
    try normalize(&a);
    const once = a;
    try normalize(&a);
    try std.testing.expectEqualSlices(u8, &once, &a);

    var c = testImage("CODE", 1, @splat(1), 0);
    try normalize(&c);
    try std.testing.expect(!std.mem.eql(u8, a[0x244..0x254], c[0x244..0x254]));
}

test "normalize recomputes a checksum the linker set" {
    var a = testImage("code", 7, @splat(7), 0x1234);
    try normalize(&a);
    const sum = std.mem.readInt(u32, a[0x44 + 20 + 64 ..][0..4], .little);
    try std.testing.expectEqual(peChecksum(&a, 0x44 + 20 + 64), sum);
    try std.testing.expect(sum != 0x1234);

    var b = testImage("code", 7, @splat(7), 0);
    try normalize(&b);
    try std.testing.expectEqual(0, std.mem.readInt(u32, b[0x44 + 20 + 64 ..][0..4], .little));
}

test "normalize rejects non-PE input" {
    var junk = [_]u8{0} ** 128;
    try std.testing.expectError(error.InvalidPe, normalize(&junk));
    var img = testImage("code", 1, @splat(1), 0);
    std.mem.writeInt(u32, img[0x3c..][0..4], 0x3fe, .little);
    try std.testing.expectError(error.InvalidPe, normalize(&img));
}
