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

//! Name-based (version 5, SHA-1) UUIDs, used for deterministic Windows
//! Installer GUIDs (ProductCode, component IDs, package codes).

const std = @import("std");
const Sha1 = std.crypto.hash.Sha1;

pub const Uuid = [16]u8;

/// Namespace for all zstaller-generated GUIDs (a fixed random UUID).
pub const zstaller_namespace: Uuid = parse("{6F0C7A52-3B1E-4C5D-9A8E-2D4F1B7C9E03}") catch unreachable;

/// Returns the version 5 UUID of `name` within `namespace`.
pub fn v5(namespace: Uuid, name: []const u8) Uuid {
    var h = Sha1.init(.{});
    h.update(&namespace);
    h.update(name);
    var d: [Sha1.digest_length]u8 = undefined;
    h.final(&d);
    var u: Uuid = d[0..16].*;
    u[6] = (u[6] & 0x0f) | 0x50;
    u[8] = (u[8] & 0x3f) | 0x80;
    return u;
}

/// v5 of the concatenation of `parts` separated by NUL bytes.
pub fn v5Parts(namespace: Uuid, parts: []const []const u8) Uuid {
    var h = Sha1.init(.{});
    h.update(&namespace);
    for (parts, 0..) |p, i| {
        if (i != 0) h.update(&.{0});
        h.update(p);
    }
    var d: [Sha1.digest_length]u8 = undefined;
    h.final(&d);
    var u: Uuid = d[0..16].*;
    u[6] = (u[6] & 0x0f) | 0x50;
    u[8] = (u[8] & 0x3f) | 0x80;
    return u;
}

/// Formats as a registry-style GUID: `{XXXXXXXX-XXXX-XXXX-XXXX-XXXXXXXXXXXX}`
/// with uppercase hex, as Windows Installer requires.
pub fn format(u: Uuid) [38]u8 {
    var out: [38]u8 = undefined;
    const hex = "0123456789ABCDEF";
    out[0] = '{';
    var o: usize = 1;
    for (u, 0..) |b, i| {
        if (i == 4 or i == 6 or i == 8 or i == 10) {
            out[o] = '-';
            o += 1;
        }
        out[o] = hex[b >> 4];
        out[o + 1] = hex[b & 15];
        o += 2;
    }
    out[37] = '}';
    return out;
}

/// Parses a GUID with or without braces, case-insensitive.
pub fn parse(s: []const u8) error{InvalidUuid}!Uuid {
    var str = s;
    if (str.len == 38 and str[0] == '{' and str[37] == '}') str = str[1..37];
    if (str.len != 36) return error.InvalidUuid;
    var u: Uuid = undefined;
    var o: usize = 0;
    var i: usize = 0;
    while (i < 36) {
        if (i == 8 or i == 13 or i == 18 or i == 23) {
            if (str[i] != '-') return error.InvalidUuid;
            i += 1;
            continue;
        }
        const hi = std.fmt.charToDigit(str[i], 16) catch return error.InvalidUuid;
        const lo = std.fmt.charToDigit(str[i + 1], 16) catch return error.InvalidUuid;
        u[o] = (hi << 4) | lo;
        o += 1;
        i += 2;
    }
    return u;
}

/// Little-endian "mixed" byte layout used inside binary Windows structures
/// (CLSIDs in compound files): the first three groups are byte-swapped.
pub fn toWindowsBytes(u: Uuid) [16]u8 {
    var out = u;
    std.mem.reverse(u8, out[0..4]);
    std.mem.reverse(u8, out[4..6]);
    std.mem.reverse(u8, out[6..8]);
    return out;
}

const testing = std.testing;

test "v5 matches RFC 4122 example" {
    // uuid.uuid5(uuid.NAMESPACE_DNS, "python.org") == 886313e1-3b8a-5372-9b90-0c9aee199e5d
    const dns = try parse("6ba7b810-9dad-11d1-80b4-00c04fd430c8");
    const u = v5(dns, "python.org");
    try testing.expectEqualStrings("{886313E1-3B8A-5372-9B90-0C9AEE199E5D}", &format(u));
}

test "parse and format round trip" {
    const s = "{6F0C7A52-3B1E-4C5D-9A8E-2D4F1B7C9E03}";
    try testing.expectEqualStrings(s, &format(try parse(s)));
    try testing.expectEqualStrings(s, &format(try parse("6f0c7a52-3b1e-4c5d-9a8e-2d4f1b7c9e03")));
    try testing.expectError(error.InvalidUuid, parse("not-a-guid"));
}

test "windows byte order" {
    const u = try parse("{000C1084-0000-0000-C000-000000000046}");
    const b = toWindowsBytes(u);
    try testing.expectEqualSlices(u8, &.{ 0x84, 0x10, 0x0C, 0x00, 0, 0, 0, 0, 0xC0, 0, 0, 0, 0, 0, 0, 0x46 }, &b);
}
