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

//! Reading Windows access control lists: whether anyone other than
//! SYSTEM and administrators can change a folder. Kept free of Win32 calls
//! so it is unit tested on every host; `folder.zig` gets the bytes from
//! Windows.

const std = @import("std");

pub const DELETE: u32 = 0x0001_0000;
pub const WRITE_DAC: u32 = 0x0004_0000;
pub const WRITE_OWNER: u32 = 0x0008_0000;
pub const GENERIC_ALL: u32 = 0x1000_0000;
pub const GENERIC_WRITE: u32 = 0x4000_0000;
pub const FILE_ADD_FILE: u32 = 0x0002;
pub const FILE_ADD_SUBDIRECTORY: u32 = 0x0004;
pub const FILE_DELETE_CHILD: u32 = 0x0040;

/// Rights on a folder that let someone replace it or an entry in it:
/// rename or delete it, delete what is in it, or change its permissions
/// or owner. A folder above the install folder must not grant these.
pub const replace_rights = DELETE | WRITE_DAC | WRITE_OWNER | GENERIC_ALL | FILE_DELETE_CHILD;

/// `replace_rights` plus adding files and folders, which would let
/// someone put a DLL next to the application. The install folder must not
/// grant these.
pub const write_rights = replace_rights | GENERIC_WRITE | FILE_ADD_FILE | FILE_ADD_SUBDIRECTORY;

const ACCESS_ALLOWED_ACE_TYPE = 0;
const ACCESS_ALLOWED_CALLBACK_ACE_TYPE = 9;
const INHERIT_ONLY_ACE = 0x08;

/// SIDs that may change installed programs: SYSTEM, Administrators,
/// TrustedInstaller, and the two placeholders that stand for the owner
/// (callers check the owner separately).
const trusted = [_][]const u8{
    &sid(5, &.{18}), // SYSTEM
    &sid(5, &.{ 32, 544 }), // BUILTIN\Administrators
    &sid(5, &.{ 80, 956008885, 3418522649, 1831038044, 1853292631, 2271478464 }), // TrustedInstaller
    &sid(3, &.{0}), // CREATOR OWNER
    &sid(3, &.{4}), // OWNER RIGHTS
};

/// The binary form of the SID S-1-`authority`-`subs`...
fn sid(comptime authority: u8, comptime subs: []const u32) [8 + 4 * subs.len]u8 {
    var out: [8 + 4 * subs.len]u8 = undefined;
    out[0] = 1;
    out[1] = subs.len;
    @memset(out[2..7], 0);
    out[7] = authority;
    for (subs, 0..) |s, i| std.mem.writeInt(u32, out[8 + 4 * i ..][0..4], s, .little);
    return out;
}

/// The length of the SID at the start of `bytes`, or null if it is not one.
pub fn sidLen(bytes: []const u8) ?usize {
    if (bytes.len < 8 or bytes[0] != 1) return null;
    const len = 8 + 4 * @as(usize, bytes[1]);
    return if (len <= bytes.len) len else null;
}

/// Whether `owner` (a binary SID) is one that may change installed
/// programs.
pub fn isTrusted(owner: []const u8) bool {
    const len = sidLen(owner) orelse return false;
    for (trusted) |t| {
        if (std.mem.eql(u8, owner[0..len], t)) return true;
    }
    return false;
}

/// Whether the access control list `dacl` (its binary form, starting with
/// the ACL header) allows anyone not in `trusted` any of `rights` on the
/// object itself. A missing list allows everyone everything, and a list
/// that cannot be read counts as allowing it too. Deny entries are
/// ignored, which can only make the answer stricter.
pub fn othersHave(dacl: ?[]const u8, rights: u32) bool {
    const list = dacl orelse return true;
    if (list.len < 8) return true;
    const size = std.mem.readInt(u16, list[2..4], .little);
    const count = std.mem.readInt(u16, list[4..6], .little);
    if (size < 8 or size > list.len) return true;
    var pos: usize = 8;
    for (0..count) |_| {
        if (pos + 4 > size) return true;
        const ace_type = list[pos];
        const flags = list[pos + 1];
        const ace_size = std.mem.readInt(u16, list[pos + 2 ..][0..2], .little);
        if (ace_size < 4 or pos + ace_size > size) return true;
        const ace = list[pos .. pos + ace_size];
        pos += ace_size;
        if (ace_type != ACCESS_ALLOWED_ACE_TYPE and ace_type != ACCESS_ALLOWED_CALLBACK_ACE_TYPE) continue;
        // Entries only passed on to new files and folders.
        if (flags & INHERIT_ONLY_ACE != 0) continue;
        if (ace.len < 8) return true;
        const mask = std.mem.readInt(u32, ace[4..8], .little);
        if (mask & rights == 0) continue;
        if (!isTrusted(ace[8..])) return true;
    }
    return false;
}

const testing = std.testing;

/// Builds an ACL from (type, flags, mask, sid) entries, as Windows stores it.
fn testAcl(buf: []u8, entries: []const struct { u8, u8, u32, []const u8 }) []const u8 {
    var pos: usize = 8;
    for (entries) |e| {
        const ace_size: u16 = @intCast(8 + e[3].len);
        buf[pos] = e[0];
        buf[pos + 1] = e[1];
        std.mem.writeInt(u16, buf[pos + 2 ..][0..2], ace_size, .little);
        std.mem.writeInt(u32, buf[pos + 4 ..][0..4], e[2], .little);
        @memcpy(buf[pos + 8 ..][0..e[3].len], e[3]);
        pos += ace_size;
    }
    buf[0] = 2;
    buf[1] = 0;
    std.mem.writeInt(u16, buf[2..4], @intCast(pos), .little);
    std.mem.writeInt(u16, buf[4..6], @intCast(entries.len), .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    return buf[0..pos];
}

const system = sid(5, &.{18});
const admins = sid(5, &.{ 32, 544 });
const users = sid(5, &.{ 32, 545 });
const authenticated_users = sid(5, &.{11});
const a_user = sid(5, &.{ 21, 1, 2, 3, 1001 });
const full: u32 = 0x1F01FF;
const read_execute: u32 = 0x1200A9;
const modify: u32 = 0x1301BF;

test "isTrusted" {
    try testing.expect(isTrusted(&system));
    try testing.expect(isTrusted(&admins));
    try testing.expect(!isTrusted(&users));
    try testing.expect(!isTrusted(&a_user));
    try testing.expect(!isTrusted(admins[0..7]));
}

test "othersHave: a Program Files style folder" {
    var buf: [256]u8 = undefined;
    const acl = testAcl(&buf, &.{
        .{ 0, 0, full, &system },
        .{ 0, 0x03, full, &admins },
        .{ 0, 0x03, read_execute, &users },
        .{ 0, 0x0B, GENERIC_ALL, &sid(3, &.{0}) },
    });
    try testing.expect(!othersHave(acl, write_rights));
}

test "othersHave: a folder in C:\\ inherits Modify for Authenticated Users" {
    var buf: [256]u8 = undefined;
    const acl = testAcl(&buf, &.{
        .{ 0, 0x10, full, &admins },
        .{ 0, 0x10, modify, &authenticated_users },
    });
    try testing.expect(othersHave(acl, replace_rights));
    try testing.expect(othersHave(acl, write_rights));
}

test "othersHave: C:\\ itself lets users create folders but not replace them" {
    var buf: [256]u8 = undefined;
    const acl = testAcl(&buf, &.{
        .{ 0, 0, full, &admins },
        .{ 0, 0, FILE_ADD_SUBDIRECTORY, &authenticated_users },
        // Inherit-only: applies to what is created inside, not C:\.
        .{ 0, 0x0B, modify, &authenticated_users },
        .{ 0, 0x03, read_execute, &users },
    });
    try testing.expect(!othersHave(acl, replace_rights));
    try testing.expect(othersHave(acl, write_rights));
}

test "othersHave: deny entries, missing and broken lists" {
    var buf: [256]u8 = undefined;
    const acl = testAcl(&buf, &.{
        .{ 1, 0, full, &a_user },
        .{ 0, 0, full, &system },
    });
    try testing.expect(!othersHave(acl, write_rights));
    try testing.expect(othersHave(null, write_rights));
    try testing.expect(othersHave(acl[0 .. acl.len - 3], write_rights));
    var bad = buf;
    std.mem.writeInt(u16, bad[2..4], 300, .little);
    try testing.expect(othersHave(bad[0..acl.len], write_rights));
}
