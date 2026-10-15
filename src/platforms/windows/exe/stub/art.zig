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

//! The installer wizard's built-in artwork, drawn when a project supplies
//! no images: a gradient side panel for the Welcome and Finish pages and
//! a tinted header for the other pages, both in the accent color.
//!
//! Drawn in pixels at the display's scale, so it is sharp at any DPI.
//! Output is 32-bit BGRX rows, top to bottom, ready for a DIB. Pure Zig,
//! so it is unit tested on every host.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// A color as 0xRRGGBB.
pub const Rgb = u32;

/// Width of the Welcome page's side panel at 100% scaling.
pub const panel_width = 164;

/// Where the Welcome page's built-in artwork places the application icon,
/// in pixels at 100% scaling: the center of the panel's highlight circle.
pub const icon_center = [2]f32{ 82, 112 };
/// Size of that icon at 100% scaling.
pub const icon_size = 64;

const Circle = struct { x: f32, y: f32, r: f32, color: Rgb, alpha: f32 };

const Canvas = struct {
    px: []u8,
    w: u32,
    h: u32,

    fn set(c: Canvas, x: u32, y: u32, rgb: Rgb) void {
        c.px[(y * c.w + x) * 4 ..][0..4].* = .{ @truncate(rgb), @truncate(rgb >> 8), @truncate(rgb >> 16), 0 };
    }

    fn get(c: Canvas, x: u32, y: u32) Rgb {
        const p = c.px[(y * c.w + x) * 4 ..][0..3];
        return @as(Rgb, p[2]) << 16 | @as(Rgb, p[1]) << 8 | p[0];
    }

    /// Blends an anti-aliased circle (coordinates in pixels) into the
    /// region left of `clip_right`.
    fn circle(c: Canvas, k: Circle, clip_right: u32) void {
        const x0: u32 = @intFromFloat(@max(0, @floor(k.x - k.r - 1)));
        const y0: u32 = @intFromFloat(@max(0, @floor(k.y - k.r - 1)));
        const x1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(clip_right)), @max(0, @ceil(k.x + k.r + 1))));
        const y1: u32 = @intFromFloat(@min(@as(f32, @floatFromInt(c.h)), @max(0, @ceil(k.y + k.r + 1))));
        var y = y0;
        while (y < y1) : (y += 1) {
            var x = x0;
            while (x < x1) : (x += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - k.x;
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - k.y;
                const coverage = std.math.clamp(k.r - @sqrt(dx * dx + dy * dy) + 0.5, 0, 1);
                if (coverage > 0) c.set(x, y, mix(c.get(x, y), k.color, coverage * k.alpha));
            }
        }
    }
};

/// `a` moved towards `b` by `t` (0..1).
pub fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    var out: Rgb = 0;
    inline for (.{ 16, 8, 0 }) |shift| {
        const ca: f32 = @floatFromInt((a >> shift) & 0xff);
        const cb: f32 = @floatFromInt((b >> shift) & 0xff);
        const v: Rgb = @intFromFloat(@round(ca + (cb - ca) * std.math.clamp(t, 0, 1)));
        out |= v << shift;
    }
    return out;
}

const white: Rgb = 0xffffff;
const black: Rgb = 0x000000;

/// The Welcome and Finish page background: a diagonal accent gradient in
/// the left panel, decorated with soft circles, and white elsewhere.
/// `w` x `h` is the size in pixels; `scale` is the display scale (1.0 at
/// 96 DPI).
pub fn welcome(gpa: Allocator, w: u32, h: u32, scale: f32, accent: Rgb) Allocator.Error![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    const c: Canvas = .{ .px = px, .w = w, .h = h };
    const panel: u32 = @min(w, @as(u32, @intFromFloat(@round(panel_width * scale))));
    const top = mix(accent, white, 0.18);
    const bottom = mix(accent, black, 0.38);
    const fw: f32 = @floatFromInt(@max(panel, 1));
    const fh: f32 = @floatFromInt(h);
    for (0..h) |y| for (0..w) |x| {
        if (x < panel) {
            const t = (@as(f32, @floatFromInt(x)) / fw) * 0.3 + (@as(f32, @floatFromInt(y)) / fh) * 0.7;
            c.set(@intCast(x), @intCast(y), mix(top, bottom, t));
        } else {
            c.set(@intCast(x), @intCast(y), white);
        }
    };
    const circles = [_]Circle{
        .{ .x = 150, .y = 30, .r = 96, .color = white, .alpha = 0.10 },
        .{ .x = 10, .y = 290, .r = 120, .color = white, .alpha = 0.07 },
        .{ .x = 130, .y = 250, .r = 40, .color = white, .alpha = 0.06 },
        .{ .x = icon_center[0], .y = icon_center[1], .r = 54, .color = white, .alpha = 0.18 },
    };
    for (circles) |k| c.circle(.{ .x = k.x * scale, .y = k.y * scale, .r = k.r * scale, .color = k.color, .alpha = k.alpha }, panel);
    return px;
}

/// The header of the inner pages: white on the left, where the title
/// goes, fading to a light accent tint with soft circles on the right.
pub fn banner(gpa: Allocator, w: u32, h: u32, scale: f32, accent: Rgb) Allocator.Error![]u8 {
    const px = try gpa.alloc(u8, @as(usize, w) * h * 4);
    const c: Canvas = .{ .px = px, .w = w, .h = h };
    const tint = mix(accent, white, 0.86);
    const fw: f32 = @floatFromInt(w);
    for (0..h) |y| for (0..w) |x| {
        const u = (@as(f32, @floatFromInt(x)) / fw - 0.5) / 0.5;
        const t = if (u <= 0) 0 else std.math.pow(f32, u, 1.6);
        c.set(@intCast(x), @intCast(y), mix(white, tint, t));
    };
    const right = 493.0;
    const circles = [_]Circle{
        .{ .x = right - 30, .y = -4, .r = 46, .color = accent, .alpha = 0.10 },
        .{ .x = right + 4, .y = 52, .r = 34, .color = accent, .alpha = 0.08 },
    };
    for (circles) |k| c.circle(.{ .x = k.x * scale, .y = k.y * scale, .r = k.r * scale, .color = k.color, .alpha = k.alpha }, w);
    return px;
}

const testing = std.testing;

fn pixel(px: []const u8, w: u32, x: u32, y: u32) Rgb {
    const p = px[(y * w + x) * 4 ..][0..3];
    return @as(Rgb, p[2]) << 16 | @as(Rgb, p[1]) << 8 | p[0];
}

test "mix" {
    try testing.expectEqual(@as(Rgb, 0x808080), mix(0x000000, 0xffffff, 0.502));
    try testing.expectEqual(@as(Rgb, 0x0067c0), mix(0x0067c0, 0xffffff, 0));
    try testing.expectEqual(@as(Rgb, 0xffffff), mix(0x0067c0, 0xffffff, 2));
}

test "welcome art: accent panel on the left, white text area" {
    const gpa = testing.allocator;
    inline for (.{ 1.0, 1.5 }) |scale| {
        const w: u32 = @intFromFloat(493 * scale);
        const h: u32 = @intFromFloat(312 * scale);
        const px = try welcome(gpa, w, h, scale, 0x0067c0);
        defer gpa.free(px);
        try testing.expectEqual(@as(usize, w * h * 4), px.len);
        try testing.expectEqual(white, pixel(px, w, w - 1, h - 1));
        try testing.expectEqual(white, pixel(px, w, @intFromFloat(170 * scale), 10));
        // The panel is darker at the bottom than at the top.
        const top = pixel(px, w, 2, 2);
        const bottom = pixel(px, w, 2, h - 2);
        try testing.expect(top & 0xff > bottom & 0xff);
    }
}

test "banner art: white where the title goes" {
    const gpa = testing.allocator;
    const px = try banner(gpa, 493, 58, 1.0, 0x0067c0);
    defer gpa.free(px);
    try testing.expectEqual(white, pixel(px, 493, 10, 30));
    try testing.expect(pixel(px, 493, 492, 30) != white);
}
