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

//! The installer and uninstaller wizard: one native window whose pages
//! are drawn with GDI over themed Win32 controls.
//!
//! Install: Welcome, License (when the project supplies one), Install
//! location, Options (when there is a choice to make), Installing,
//! Finished. Uninstall: Confirm, Removing, Finished. Before installing or
//! removing files, a "Programs in use" page lists any programs that keep
//! them in use, until they are closed.
//!
//! Layout is in pixels at 100% scaling, the size of the Windows Installer
//! dialogs (493x360, with 493x312 artwork above a 48-pixel button bar),
//! and scaled to each monitor's DPI. Install and uninstall run on the
//! window's thread; the progress callback keeps the window responsive
//! between files.

const std = @import("std");
const zstaller = @import("zstaller");
const config = @import("config");
const wizard_bytes = @import("payload").wizard;
const w32 = @import("win32.zig");
const main = @import("main.zig");
const art = zstaller.wizard_art;

const cli = zstaller.exe_cli;
const assets_mod = zstaller.wizard_assets;
const Allocator = std.mem.Allocator;
const ExitCode = main.ExitCode;

// ---- Layout, in pixels at 100% scaling.

const width = 493;
const height = 360;
const art_height = 312;
const banner_height = 58;
const margin = 24;
/// Left edge of the text on the Welcome and Finish pages.
const welcome_text_x = art.panel_width + 22;
const button_width = 80;
const button_height = 26;
const button_y = art_height + (height - art_height - button_height) / 2;

// ---- Colors, 0xRRGGBB.

const color_text = 0x1B1B1B;
const color_body = 0x3B3B3B;
const color_muted = 0x6B6B6B;
const color_bar = 0xF3F3F3;
const color_line = 0xE1E1E1;
const color_white = 0xFFFFFF;

const Page = enum {
    welcome,
    license,
    location,
    options,
    installing,
    finish,
    uninstall_confirm,
    uninstalling,
    uninstall_finish,
    /// Programs keep the installation in use; shown before Installing or
    /// Uninstalling until they are closed.
    in_use,

    fn usesWelcomeArt(p: Page) bool {
        return p == .welcome or p == .finish or p == .uninstall_finish;
    }

    fn busy(p: Page) bool {
        return p == .installing or p == .uninstalling;
    }
};

const Id = struct {
    const next: u16 = 1; // IDOK: Enter
    const cancel: u16 = 2; // IDCANCEL: Esc
    const back: u16 = 3;
    const browse: u16 = 10;
    const dir: u16 = 11;
    const accept: u16 = 12;
    const path: u16 = 13;
    const desktop: u16 = 14;
    const launch: u16 = 15;
    const mcp: u16 = 19;
    const license: u16 = 16;
    const progress: u16 = 17;
    const in_use: u16 = 18;
};

/// Columns of the "Programs in use" list: title, width at 100% scaling,
/// and alignment.
const in_use_columns = [_]struct { []const u8, i32, c_int }{
    .{ "Full path", 152, w32.LVCFMT_LEFT },
    .{ "Process name", 92, w32.LVCFMT_LEFT },
    .{ "PID", 42, w32.LVCFMT_RIGHT },
    .{ "User or service account", 140, w32.LVCFMT_LEFT },
};

var current: ?*Wizard = null;

pub fn runInstall(s: *main.State, cmd: cli.Command, self_path: []const u8) ExitCode {
    var wz: Wizard = .{ .s = s, .self_path = self_path, .page = .welcome };
    wz.installed_version = main.installedVersion(s);
    const dir = cmd.install_dir orelse main.defaultInstallDir(s) catch "";
    const add_to_path = switch (config.add_to_path) {
        .never => false,
        .always => true,
        .optional => cmd.add_to_path orelse true,
    };
    const desktop = switch (config.desktop_shortcut) {
        .never => false,
        .always => true,
        .optional => cmd.desktop_shortcut orelse false,
    };
    if (!wz.create()) return s.fail("Setup could not open its window.", .{});
    wz.setText(wz.dir_edit, dir);
    Wizard.check(wz.path, add_to_path);
    Wizard.check(wz.desktop, desktop);
    Wizard.check(wz.mcp, cmd.register_mcp orelse true);
    Wizard.check(wz.launch, config.launch_on_finish);
    return wz.run();
}

pub fn runUninstall(s: *main.State, dir: []const u8, self_path: []const u8) ExitCode {
    var wz: Wizard = .{ .s = s, .self_path = self_path, .page = .uninstall_confirm, .uninstall_dir = dir };
    if (!wz.create()) return s.fail("The uninstaller could not open its window.", .{});
    return wz.run();
}

const Wizard = struct {
    s: *main.State,
    self_path: []const u8,
    page: Page,
    ready: bool = false,
    outcome: ExitCode = .cancelled,
    /// Why install or uninstall failed, shown on the Finish page.
    failure: ?[]const u8 = null,
    /// The installation being removed (uninstall only).
    uninstall_dir: []const u8 = "",
    installed_version: ?[]const u8 = null,
    /// The programs listed on the "Programs in use" page, and what the
    /// wizard was about to do when it found them.
    in_use: []const cli.RunningProcess = &.{},
    in_use_op: main.Operation = .install,

    hinst: ?w32.HINSTANCE = null,
    hwnd: w32.HWND = undefined,
    dpi: u32 = 96,

    font_body: ?w32.HGDIOBJ = null,
    font_title: ?w32.HGDIOBJ = null,
    font_heading: ?w32.HGDIOBJ = null,
    font_small: ?w32.HGDIOBJ = null,
    brush_white: w32.HGDIOBJ = undefined,
    brush_bar: w32.HGDIOBJ = undefined,
    brush_line: w32.HGDIOBJ = undefined,
    /// The application icon for the Welcome panel and the banner.
    icon_large: ?w32.HICON = null,
    icon_banner: ?w32.HICON = null,
    icon_window: ?w32.HICON = null,
    icon_window_small: ?w32.HICON = null,

    assets: assets_mod.Assets = .{},
    /// Built-in artwork at the current DPI, when no images are supplied.
    welcome_art: ?[]u8 = null,
    banner_art: ?[]u8 = null,
    art_dpi: u32 = 0,

    back: w32.HWND = undefined,
    next: w32.HWND = undefined,
    cancel: w32.HWND = undefined,
    browse: w32.HWND = undefined,
    dir_edit: w32.HWND = undefined,
    accept: w32.HWND = undefined,
    path: w32.HWND = undefined,
    desktop: w32.HWND = undefined,
    mcp: w32.HWND = undefined,
    launch: w32.HWND = undefined,
    license: w32.HWND = undefined,
    progress: w32.HWND = undefined,
    in_use_list: w32.HWND = undefined,

    status: [512]u8 = undefined,
    status_len: usize = 0,

    // ---- Window lifetime

    fn create(wz: *Wizard) bool {
        const icc: w32.INITCOMMONCONTROLSEX = .{ .dwICC = w32.ICC_STANDARD_CLASSES | w32.ICC_PROGRESS_CLASS | w32.ICC_LISTVIEW_CLASSES };
        _ = w32.InitCommonControlsEx(&icc);
        _ = w32.CoInitializeEx(null, w32.COINIT_APARTMENTTHREADED);

        if (zstaller.exe_payload.decode(wz.s.gpa, wizard_bytes)) |decoded| {
            wz.assets = assets_mod.find(decoded.entries);
        } else |_| {}

        wz.hinst = w32.GetModuleHandleW(null);
        wz.brush_white = w32.CreateSolidBrush(colorref(color_white)) orelse return false;
        wz.brush_bar = w32.CreateSolidBrush(colorref(color_bar)) orelse return false;
        wz.brush_line = w32.CreateSolidBrush(colorref(color_line)) orelse return false;

        const class_name = std.unicode.utf8ToUtf16LeStringLiteral("ZstallerWizard");
        const class: w32.WNDCLASSEXW = .{
            .lpfnWndProc = wndProc,
            .hInstance = wz.hinst,
            .hCursor = w32.LoadCursorW(null, w32.IDC_ARROW),
            .lpszClassName = class_name,
        };
        _ = w32.RegisterClassExW(&class);

        current = wz;
        const title = wide(wz.s.gpa, config.display_name ++ " Setup");
        wz.hwnd = w32.CreateWindowExW(
            w32.WS_EX_CONTROLPARENT,
            class_name,
            title.ptr,
            window_style,
            w32.CW_USEDEFAULT,
            w32.CW_USEDEFAULT,
            width,
            height,
            null,
            null,
            wz.hinst,
            null,
        ) orelse return false;
        wz.s.owner = wz.hwnd;
        wz.dpi = w32.GetDpiForWindow(wz.hwnd);
        if (wz.dpi == 0) wz.dpi = 96;

        wz.createControls();
        wz.applyDpi();
        wz.center();
        wz.ready = true;
        return true;
    }

    const window_style = w32.WS_OVERLAPPED | w32.WS_CAPTION | w32.WS_SYSMENU | w32.WS_MINIMIZEBOX | w32.WS_CLIPCHILDREN;

    fn run(wz: *Wizard) ExitCode {
        wz.showPage(wz.page);
        _ = w32.ShowWindow(wz.hwnd, w32.SW_SHOW);
        _ = w32.SetForegroundWindow(wz.hwnd);
        var msg: w32.MSG = .{};
        while (w32.GetMessageW(&msg, null, 0, 0) > 0) {
            if (w32.IsDialogMessageW(wz.hwnd, &msg) == 0) {
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageW(&msg);
            }
        }
        current = null;
        return wz.outcome;
    }

    /// Handles pending window messages while installing, so the window
    /// repaints and stays responsive.
    fn pump(wz: *Wizard) void {
        var msg: w32.MSG = .{};
        while (w32.PeekMessageW(&msg, null, 0, 0, w32.PM_REMOVE) != 0) {
            if (msg.message == w32.WM_QUIT) {
                w32.PostQuitMessage(@intCast(msg.wParam));
                return;
            }
            if (w32.IsDialogMessageW(wz.hwnd, &msg) == 0) {
                _ = w32.TranslateMessage(&msg);
                _ = w32.DispatchMessageW(&msg);
            }
        }
    }

    fn close(wz: *Wizard, outcome: ExitCode) void {
        wz.outcome = outcome;
        _ = w32.DestroyWindow(wz.hwnd);
    }

    // ---- Controls and DPI

    fn createControls(wz: *Wizard) void {
        const button = std.unicode.utf8ToUtf16LeStringLiteral("BUTTON");
        const edit = std.unicode.utf8ToUtf16LeStringLiteral("EDIT");
        const progress = std.unicode.utf8ToUtf16LeStringLiteral("msctls_progress32");
        const list_view = std.unicode.utf8ToUtf16LeStringLiteral("SysListView32");
        const tab = w32.WS_CHILD | w32.WS_TABSTOP;

        // Creation order is the Tab order.
        wz.license = wz.child(edit, "", tab | w32.WS_VSCROLL | w32.ES_MULTILINE | w32.ES_READONLY | w32.ES_AUTOVSCROLL, w32.WS_EX_CLIENTEDGE, Id.license);
        wz.accept = wz.child(button, "I &accept the terms of the license agreement", tab | w32.BS_AUTOCHECKBOX, 0, Id.accept);
        wz.dir_edit = wz.child(edit, "", tab | w32.ES_AUTOHSCROLL | (if (config.allow_install_dir_change) 0 else w32.ES_READONLY), w32.WS_EX_CLIENTEDGE, Id.dir);
        wz.browse = wz.child(button, "B&rowse...", tab, 0, Id.browse);
        wz.path = wz.child(button, "Add " ++ config.display_name ++ " to the &PATH environment variable", tab | w32.BS_AUTOCHECKBOX, 0, Id.path);
        wz.desktop = wz.child(button, "Create a &desktop shortcut", tab | w32.BS_AUTOCHECKBOX, 0, Id.desktop);
        wz.mcp = wz.child(button, "Add " ++ config.display_name ++ " to my &AI tools (" ++ config.mcp_clients ++ ")", tab | w32.BS_AUTOCHECKBOX, 0, Id.mcp);
        wz.launch = wz.child(button, "&Launch " ++ config.display_name, tab | w32.BS_AUTOCHECKBOX, 0, Id.launch);
        wz.progress = wz.child(progress, "", w32.WS_CHILD | w32.PBS_SMOOTH, 0, Id.progress);
        wz.in_use_list = wz.child(list_view, "", tab | w32.LVS_REPORT | w32.LVS_SINGLESEL | w32.LVS_SHOWSELALWAYS | w32.LVS_NOSORTHEADER, w32.WS_EX_CLIENTEDGE, Id.in_use);
        wz.back = wz.child(button, "< &Back", tab, 0, Id.back);
        wz.next = wz.child(button, "&Next >", tab | w32.BS_DEFPUSHBUTTON, 0, Id.next);
        wz.cancel = wz.child(button, "Cancel", tab, 0, Id.cancel);

        _ = w32.SendMessageW(wz.progress, w32.PBM_SETRANGE32, 0, 1000);
        const list_style = w32.LVS_EX_FULLROWSELECT | w32.LVS_EX_LABELTIP | w32.LVS_EX_DOUBLEBUFFER;
        _ = w32.SendMessageW(wz.in_use_list, w32.LVM_SETEXTENDEDLISTVIEWSTYLE, list_style, @bitCast(list_style));
        for (in_use_columns, 0..) |col, i| {
            const title, _, const fmt = col;
            const column: w32.LVCOLUMNW = .{
                .mask = w32.LVCF_FMT | w32.LVCF_WIDTH | w32.LVCF_TEXT | w32.LVCF_SUBITEM,
                .fmt = fmt,
                .pszText = wide(wz.s.gpa, title).ptr,
                .iSubItem = @intCast(i),
            };
            _ = w32.SendMessageW(wz.in_use_list, w32.LVM_INSERTCOLUMNW, i, @bitCast(@intFromPtr(&column)));
        }
        if (wz.assets.license) |license_text| {
            _ = w32.SendMessageW(wz.license, w32.EM_SETLIMITTEXT, 0, 0);
            const crlf = cli.crlf(wz.s.gpa, license_text) catch license_text;
            wz.setText(wz.license, crlf);
        }
    }

    fn child(wz: *Wizard, class: [*:0]const u16, label: []const u8, style: w32.DWORD, ex_style: w32.DWORD, id: u16) w32.HWND {
        const label_w = wide(wz.s.gpa, label);
        return w32.CreateWindowExW(ex_style, class, label_w.ptr, style, 0, 0, 0, 0, wz.hwnd, @ptrFromInt(id), wz.hinst, null) orelse
            @panic("could not create a wizard control");
    }

    /// Scales `v` pixels at 100% to the current DPI.
    fn px(wz: *const Wizard, v: i32) i32 {
        return @intCast(@divFloor(@as(i64, v) * wz.dpi + 48, 96));
    }

    fn scale(wz: *const Wizard) f32 {
        return @as(f32, @floatFromInt(wz.dpi)) / 96.0;
    }

    fn rect(wz: *const Wizard, x: i32, y: i32, w: i32, h: i32) w32.RECT {
        return .{ .left = wz.px(x), .top = wz.px(y), .right = wz.px(x + w), .bottom = wz.px(y + h) };
    }

    /// (Re)creates the fonts and icons for the current DPI.
    fn applyDpi(wz: *Wizard) void {
        for ([_]?w32.HGDIOBJ{ wz.font_body, wz.font_title, wz.font_heading, wz.font_small }) |f| {
            if (f) |obj| _ = w32.DeleteObject(obj);
        }
        wz.font_body = wz.font(12, w32.FW_NORMAL);
        wz.font_small = wz.font(11, w32.FW_NORMAL);
        wz.font_title = wz.font(15, w32.FW_SEMIBOLD);
        wz.font_heading = wz.font(22, w32.FW_SEMIBOLD);

        for ([_]?w32.HICON{ wz.icon_large, wz.icon_banner, wz.icon_window, wz.icon_window_small }) |icon| {
            if (icon) |i| if (config.has_icon) {
                _ = w32.DestroyIcon(i);
            };
        }
        wz.icon_large = wz.loadIcon(art.icon_size);
        wz.icon_banner = wz.loadIcon(32);
        wz.icon_window = wz.loadIcon(32);
        wz.icon_window_small = wz.loadIcon(16);
        if (wz.icon_window) |i| _ = w32.SendMessageW(wz.hwnd, w32.WM_SETICON, w32.ICON_BIG, @bitCast(@intFromPtr(i)));
        if (wz.icon_window_small) |i| _ = w32.SendMessageW(wz.hwnd, w32.WM_SETICON, w32.ICON_SMALL, @bitCast(@intFromPtr(i)));

        for ([_]w32.HWND{ wz.license, wz.accept, wz.dir_edit, wz.browse, wz.path, wz.desktop, wz.mcp, wz.launch, wz.in_use_list, wz.back, wz.next, wz.cancel }) |h| {
            if (wz.font_body) |f| _ = w32.SendMessageW(h, w32.WM_SETFONT, @intFromPtr(f), 1);
        }
        for (in_use_columns, 0..) |col, i| {
            _, const col_width, _ = col;
            _ = w32.SendMessageW(wz.in_use_list, w32.LVM_SETCOLUMNWIDTH, i, wz.px(col_width));
        }
        // Room between the edit box's border and its text.
        const edit_margin: usize = @intCast(wz.px(4));
        _ = w32.SendMessageW(wz.dir_edit, w32.EM_SETMARGINS, w32.EC_LEFTMARGIN | w32.EC_RIGHTMARGIN, @intCast(edit_margin | edit_margin << 16));
    }

    fn font(wz: *const Wizard, size: i32, weight: c_int) ?w32.HGDIOBJ {
        const face = std.unicode.utf8ToUtf16LeStringLiteral("Segoe UI");
        return w32.CreateFontW(-wz.px(size), 0, 0, 0, weight, 0, 0, 0, w32.DEFAULT_CHARSET, 0, 0, w32.CLEARTYPE_QUALITY, 0, face);
    }

    fn loadIcon(wz: *const Wizard, size: i32) ?w32.HICON {
        const s = wz.px(size);
        const handle = if (config.has_icon)
            w32.LoadImageW(wz.hinst, 1, w32.IMAGE_ICON, s, s, w32.LR_DEFAULTCOLOR)
        else
            w32.LoadImageW(null, w32.IDI_APPLICATION, w32.IMAGE_ICON, s, s, w32.LR_SHARED);
        return @ptrCast(handle);
    }

    /// Sizes the window for the current DPI and centers it on its monitor.
    fn center(wz: *Wizard) void {
        var r: w32.RECT = .{ .right = wz.px(width), .bottom = wz.px(height) };
        _ = w32.AdjustWindowRectExForDpi(&r, window_style, 0, w32.WS_EX_CONTROLPARENT, wz.dpi);
        const w = r.right - r.left;
        const h = r.bottom - r.top;
        var x: i32 = 0;
        var y: i32 = 0;
        if (w32.MonitorFromWindow(wz.hwnd, w32.MONITOR_DEFAULTTONEAREST)) |mon| {
            var info: w32.MONITORINFO = .{};
            if (w32.GetMonitorInfoW(mon, &info) != 0) {
                x = info.rcWork.left + @divTrunc(info.rcWork.right - info.rcWork.left - w, 2);
                y = info.rcWork.top + @divTrunc(info.rcWork.bottom - info.rcWork.top - h, 2);
            }
        }
        _ = w32.SetWindowPos(wz.hwnd, null, x, y, w, h, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
    }

    fn onDpiChanged(wz: *Wizard, dpi: u32, suggested: *const w32.RECT) void {
        wz.dpi = dpi;
        wz.applyDpi();
        _ = w32.SetWindowPos(wz.hwnd, null, suggested.left, suggested.top, suggested.right - suggested.left, suggested.bottom - suggested.top, w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        wz.showPage(wz.page);
    }

    // ---- Pages

    fn hasOptionsPage() bool {
        return config.add_to_path == .optional or config.desktop_shortcut == .optional or config.mcp_register == .optional;
    }

    /// The page after `p` in the install flow.
    fn following(wz: *const Wizard, p: Page) Page {
        return switch (p) {
            .welcome => if (wz.assets.license != null) .license else .location,
            .license => .location,
            .location => if (hasOptionsPage()) .options else .installing,
            .options => .installing,
            else => p,
        };
    }

    fn preceding(wz: *const Wizard, p: Page) ?Page {
        return switch (p) {
            .license => .welcome,
            .location => if (wz.assets.license != null) .license else .welcome,
            .options => .location,
            else => null,
        };
    }

    fn showPage(wz: *Wizard, page: Page) void {
        wz.page = page;

        // Every control is hidden unless the page places it.
        for ([_]w32.HWND{ wz.license, wz.accept, wz.dir_edit, wz.browse, wz.path, wz.desktop, wz.mcp, wz.launch, wz.progress, wz.in_use_list }) |h| {
            _ = w32.ShowWindow(h, w32.SW_HIDE);
        }
        switch (page) {
            .license => {
                wz.place(wz.license, margin, banner_height + 16, width - 2 * margin, 186);
                wz.place(wz.accept, margin, banner_height + 214, width - 2 * margin, 22);
            },
            .location => {
                const edit_w: i32 = if (config.allow_install_dir_change) width - 2 * margin - button_width - 10 else width - 2 * margin;
                wz.place(wz.dir_edit, margin, location_edit_y, edit_w, 26);
                if (config.allow_install_dir_change) wz.place(wz.browse, width - margin - button_width, location_edit_y, button_width, 26);
            },
            .options => {
                var y: i32 = banner_height + 56;
                if (config.add_to_path == .optional) {
                    wz.place(wz.path, margin, y, width - 2 * margin, 22);
                    y += 28;
                }
                if (config.desktop_shortcut == .optional) {
                    wz.place(wz.desktop, margin, y, width - 2 * margin, 22);
                    y += 28;
                }
                if (config.mcp_register == .optional) {
                    wz.place(wz.mcp, margin, y, width - 2 * margin, 22);
                }
            },
            .installing, .uninstalling => {
                _ = w32.SendMessageW(wz.progress, w32.PBM_SETPOS, 0, 0);
                wz.place(wz.progress, margin, banner_height + 74, width - 2 * margin, 16);
                wz.status_len = 0;
            },
            .finish => if (wz.outcome == .success and config.launch_on_finish) {
                wz.place(wz.launch, welcome_text_x, art_height - 44, width - welcome_text_x - 20, 22);
            },
            .in_use => wz.place(wz.in_use_list, margin, in_use_list_y, width - 2 * margin, art_height - in_use_list_y - 14),
            else => {},
        }

        // Buttons, right-aligned in the bar: Back, Next, gap, Cancel.
        const cancel_x = width - 12 - button_width;
        const next_x = cancel_x - 10 - button_width;
        const back_x = next_x - button_width;
        wz.place(wz.back, back_x, button_y, button_width, button_height);
        wz.place(wz.next, next_x, button_y, button_width, button_height);
        wz.place(wz.cancel, cancel_x, button_y, button_width, button_height);

        const busy = page.busy();
        const final = page == .finish or page == .uninstall_finish;
        show(wz.back, !final and page != .uninstall_confirm and !busy);
        show(wz.cancel, !final);
        _ = w32.EnableWindow(wz.back, @intFromBool(wz.preceding(page) != null));
        wz.setText(wz.back, "< &Back");
        if (page == .in_use) {
            // Back becomes "Close programs", when the project allows it.
            const close_width = 110;
            wz.place(wz.back, next_x - 10 - close_width, button_y, close_width, button_height);
            wz.setText(wz.back, "&Close programs");
            show(wz.back, config.close_running_apps);
            _ = w32.EnableWindow(wz.back, 1);
        }
        _ = w32.EnableWindow(wz.cancel, @intFromBool(!busy));
        _ = w32.EnableWindow(wz.next, @intFromBool(!busy and (page != .license or checked(wz.accept))));
        wz.setText(wz.next, switch (page) {
            .welcome, .license, .location, .options => if (wz.following(page) == .installing) "&Install" else "&Next >",
            .installing, .uninstalling => "&Next >",
            .finish => if (wz.outcome == .success) "&Finish" else "&Close",
            .uninstall_confirm => "&Uninstall",
            .uninstall_finish => "&Close",
            .in_use => "&Retry",
        });
        if (final) {
            // The only button left moves to the far right.
            wz.place(wz.next, cancel_x, button_y, button_width, button_height);
        }

        _ = w32.InvalidateRect(wz.hwnd, null, 0);
        if (!busy) _ = w32.SetFocus(if (page == .license and !checked(wz.accept)) wz.accept else wz.next);
    }

    const location_edit_y = banner_height + 64;
    const in_use_list_y = banner_height + 60;

    fn place(wz: *const Wizard, h: w32.HWND, x: i32, y: i32, w: i32, hgt: i32) void {
        _ = w32.SetWindowPos(h, null, wz.px(x), wz.px(y), wz.px(x + w) - wz.px(x), wz.px(y + hgt) - wz.px(y), w32.SWP_NOZORDER | w32.SWP_NOACTIVATE);
        _ = w32.ShowWindow(h, w32.SW_SHOW);
    }

    fn show(h: w32.HWND, visible: bool) void {
        _ = w32.ShowWindow(h, if (visible) w32.SW_SHOW else w32.SW_HIDE);
    }

    // ---- Commands

    fn command(wz: *Wizard, id: u16, code: u16) void {
        switch (id) {
            Id.next => if (w32.IsWindowEnabled(wz.next) != 0 and code == w32.BN_CLICKED) wz.onNext(),
            Id.back => if (w32.IsWindowEnabled(wz.back) != 0) {
                if (wz.page == .in_use) {
                    wz.onClosePrograms();
                } else if (wz.preceding(wz.page)) |p| wz.showPage(p);
            },
            Id.cancel => wz.onCancel(),
            Id.browse => wz.onBrowse(),
            Id.accept => _ = w32.EnableWindow(wz.next, @intFromBool(checked(wz.accept))),
            Id.dir => if (code == w32.EN_CHANGE and wz.page == .location) {
                var r = wz.rect(0, location_edit_y + 30, width, 60);
                _ = w32.InvalidateRect(wz.hwnd, &r, 0);
            },
            else => {},
        }
    }

    fn onNext(wz: *Wizard) void {
        switch (wz.page) {
            .welcome, .license, .options => wz.advance(),
            .location => {
                const dir = wz.getText(wz.dir_edit);
                if (!cli.isValidInstallDir(dir)) {
                    _ = main.messageBox(wz.s.gpa, wz.hwnd, "Enter the full path of a folder, such as C:\\Program Files\\" ++ config.install_dir_name ++ ".", w32.MB_OK | w32.MB_ICONWARNING);
                    _ = w32.SetFocus(wz.dir_edit);
                    return;
                }
                if (freeSpace(wz.s.gpa, dir) == null) {
                    const msg = std.fmt.allocPrint(wz.s.gpa, "The drive for {s} is not available.\n\nChoose a folder on another drive.", .{dir}) catch "The drive is not available.";
                    _ = main.messageBox(wz.s.gpa, wz.hwnd, msg, w32.MB_OK | w32.MB_ICONWARNING);
                    _ = w32.SetFocus(wz.dir_edit);
                    return;
                }
                wz.advance();
            },
            .finish => {
                if (wz.outcome == .success and config.launch_on_finish and checked(wz.launch)) {
                    main.launch(wz.s, std.fs.path.join(wz.s.gpa, &.{ wz.getText(wz.dir_edit), config.exe_name }) catch return, wz.getText(wz.dir_edit));
                }
                wz.close(wz.outcome);
            },
            .uninstall_confirm => wz.uninstall(),
            .uninstall_finish => wz.close(wz.outcome),
            .in_use => wz.retry(),
            .installing, .uninstalling => {},
        }
    }

    fn advance(wz: *Wizard) void {
        const next = wz.following(wz.page);
        if (next == .installing) wz.install() else wz.showPage(next);
    }

    fn onCancel(wz: *Wizard) void {
        switch (wz.page) {
            .installing, .uninstalling => {},
            .finish, .uninstall_finish => wz.close(wz.outcome),
            else => {
                const removing = wz.page == .uninstall_confirm or (wz.page == .in_use and wz.in_use_op == .uninstall);
                const question = if (removing)
                    "Cancel the removal of " ++ config.display_name ++ "?"
                else
                    "Setup is not complete. If you exit now, " ++ config.display_name ++ " will not be installed.\n\nExit Setup?";
                if (main.messageBox(wz.s.gpa, wz.hwnd, question, w32.MB_YESNO | w32.MB_ICONQUESTION | w32.MB_DEFBUTTON2) == w32.IDYES) {
                    wz.close(.cancelled);
                }
            },
        }
    }

    fn onBrowse(wz: *Wizard) void {
        var obj: ?*anyopaque = null;
        if (w32.CoCreateInstance(&w32.CLSID_FileOpenDialog, null, w32.CLSCTX_INPROC_SERVER, &w32.IID_IFileOpenDialog, &obj) < 0) return;
        const dialog: *w32.IFileOpenDialog = @ptrCast(@alignCast(obj.?));
        defer _ = dialog.vtable.Release(dialog);
        var options: w32.DWORD = 0;
        _ = dialog.vtable.GetOptions(dialog, &options);
        _ = dialog.vtable.SetOptions(dialog, options | w32.FOS_PICKFOLDERS | w32.FOS_FORCEFILESYSTEM | w32.FOS_PATHMUSTEXIST);
        _ = dialog.vtable.SetTitle(dialog, std.unicode.utf8ToUtf16LeStringLiteral("Choose where to install " ++ config.display_name));

        // Start in the nearest existing folder of the current choice.
        var start: ?[]const u8 = wz.getText(wz.dir_edit);
        while (start) |dir| : (start = std.fs.path.dirnameWindows(dir)) {
            const dir_w = std.unicode.wtf8ToWtf16LeAllocZ(wz.s.gpa, dir) catch break;
            var item_obj: ?*anyopaque = null;
            if (w32.SHCreateItemFromParsingName(dir_w.ptr, null, &w32.IID_IShellItem, &item_obj) >= 0) {
                const item: *w32.IShellItem = @ptrCast(@alignCast(item_obj.?));
                _ = dialog.vtable.SetFolder(dialog, item);
                _ = item.vtable.Release(item);
                break;
            }
        }

        if (dialog.vtable.Show(dialog, wz.hwnd) < 0) return; // cancelled
        var result: ?*w32.IShellItem = null;
        if (dialog.vtable.GetResult(dialog, &result) < 0) return;
        const item = result orelse return;
        defer _ = item.vtable.Release(item);
        var name: ?[*:0]u16 = null;
        if (item.vtable.GetDisplayName(item, w32.SIGDN_FILESYSPATH, &name) < 0) return;
        defer w32.CoTaskMemFree(name);
        const picked = std.unicode.wtf16LeToWtf8Alloc(wz.s.gpa, std.mem.span(name.?)) catch return;
        const dir = cli.browsedInstallDir(wz.s.gpa, picked, cli.installDirLeaf(config.install_dir_name)) catch return;
        wz.setText(wz.dir_edit, dir);
    }

    fn install(wz: *Wizard) void {
        const dir = wz.getText(wz.dir_edit);
        const plan: main.Plan = .{
            .dir = dir,
            .add_to_path = switch (config.add_to_path) {
                .never => false,
                .always => true,
                .optional => checked(wz.path),
            },
            .desktop_shortcut = switch (config.desktop_shortcut) {
                .never => false,
                .always => true,
                .optional => checked(wz.desktop),
            },
            .register_mcp = switch (config.mcp_register) {
                .never => false,
                .always => true,
                .optional => checked(wz.mcp),
            },
        };
        // Programs still running from an earlier install keep its files
        // locked; the user is asked to close them first.
        if (!wz.clearOfPrograms(dir, .install)) return;

        wz.showPage(.installing);
        main.applyInstall(wz.s, plan, wz.self_path, wz.progressCallback()) catch |err| {
            wz.failure = wz.s.failureText(err, "Installation");
        };
        wz.outcome = if (wz.failure == null) .success else .failure;
        wz.showPage(.finish);
    }

    fn uninstall(wz: *Wizard) void {
        if (!wz.clearOfPrograms(wz.uninstall_dir, .uninstall)) return;

        wz.showPage(.uninstalling);
        main.applyUninstall(wz.s, wz.uninstall_dir, wz.self_path, wz.progressCallback()) catch |err| {
            wz.failure = wz.s.failureText(err, "Uninstall");
        };
        wz.outcome = if (wz.failure == null) .success else .failure;
        wz.showPage(.uninstall_finish);
    }

    /// Whether no program keeps the installation in `dir` in use. If
    /// some do, they are listed on the "Programs in use" page and `op`
    /// waits until they are closed.
    fn clearOfPrograms(wz: *Wizard, dir: []const u8, op: main.Operation) bool {
        const found = main.findInUse(wz.s, dir) catch &.{};
        if (found.len == 0) return true;
        wz.in_use = found;
        wz.in_use_op = op;
        wz.fillInUseList();
        if (wz.page == .in_use) {
            _ = w32.MessageBeep(w32.MB_ICONWARNING);
            _ = w32.InvalidateRect(wz.hwnd, null, 0);
        } else {
            wz.showPage(.in_use);
        }
        return false;
    }

    fn fillInUseList(wz: *Wizard) void {
        const list = wz.in_use_list;
        _ = w32.SendMessageW(list, w32.LVM_DELETEALLITEMS, 0, 0);
        for (wz.in_use, 0..) |p, i| {
            var label_buf: [256]u8 = undefined;
            var pid_buf: [16]u8 = undefined;
            const cells = [_][]const u8{
                if (p.path.len > 0) p.path else "Not available",
                p.label(&label_buf),
                std.fmt.bufPrint(&pid_buf, "{d}", .{p.pid}) catch "",
                if (p.user.len > 0) p.user else "Not available",
            };
            for (cells, 0..) |cell, col| {
                const item: w32.LVITEMW = .{
                    .mask = w32.LVIF_TEXT,
                    .iItem = @intCast(i),
                    .iSubItem = @intCast(col),
                    .pszText = wide(wz.s.gpa, cell).ptr,
                };
                const msg = if (col == 0) w32.LVM_INSERTITEMW else w32.LVM_SETITEMTEXTW;
                _ = w32.SendMessageW(list, msg, i, @bitCast(@intFromPtr(&item)));
            }
        }
    }

    /// Retry on the "Programs in use" page: carries on if they are
    /// closed, else refreshes the list.
    fn retry(wz: *Wizard) void {
        switch (wz.in_use_op) {
            .install => wz.install(),
            .uninstall => wz.uninstall(),
        }
    }

    fn onClosePrograms(wz: *Wizard) void {
        const question = if (wz.in_use.len == 1)
            "Close the program listed? Unsaved work in it will be lost."
        else
            std.fmt.allocPrint(wz.s.gpa, "Close the {d} programs listed? Unsaved work in them will be lost.", .{wz.in_use.len}) catch return;
        if (main.messageBox(wz.s.gpa, wz.hwnd, question, w32.MB_YESNO | w32.MB_ICONWARNING | w32.MB_DEFBUTTON2) != w32.IDYES) return;
        const cursor = w32.SetCursor(w32.LoadCursorW(null, w32.IDC_WAIT));
        const stuck = main.closePrograms(wz.in_use);
        _ = w32.SetCursor(cursor);
        if (stuck) |p| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.allocPrint(
                wz.s.gpa,
                "{s} (process ID {d}) could not be closed.\n\nClose it yourself, then click Retry.",
                .{ p.label(&buf), p.pid },
            ) catch "A program could not be closed.";
            _ = main.messageBox(wz.s.gpa, wz.hwnd, msg, w32.MB_OK | w32.MB_ICONWARNING);
        }
        wz.retry();
    }

    fn progressCallback(wz: *Wizard) main.Progress {
        return .{ .ctx = wz, .func = onProgress };
    }

    fn onProgress(ctx: *anyopaque, done: u64, total: u64, item: []const u8) void {
        const wz: *Wizard = @ptrCast(@alignCast(ctx));
        const pos: u64 = if (total == 0) 0 else @min(1000, done * 1000 / total);
        _ = w32.SendMessageW(wz.progress, w32.PBM_SETPOS, @intCast(pos), 0);
        const verb = if (wz.page == .uninstalling) "Removing " else "Copying ";
        // Steps such as "Creating shortcuts..." are shown as they are; file
        // paths get a verb.
        const line = if (item.len == 0 or std.mem.endsWith(u8, item, "..."))
            std.fmt.bufPrint(&wz.status, "{s}", .{item})
        else
            std.fmt.bufPrint(&wz.status, "{s}{s}", .{ verb, item });
        wz.status_len = if (line) |t| t.len else |_| 0;
        var r = wz.rect(0, banner_height + 40, width, 30);
        _ = w32.InvalidateRect(wz.hwnd, &r, 0);
        wz.pump();
    }

    // ---- Painting

    fn paintBuffered(wz: *Wizard, hdc: w32.HDC) void {
        var client: w32.RECT = .{};
        _ = w32.GetClientRect(wz.hwnd, &client);
        const mem = w32.CreateCompatibleDC(hdc) orelse return wz.paint(hdc);
        defer _ = w32.DeleteDC(mem);
        const bmp = w32.CreateCompatibleBitmap(hdc, client.right, client.bottom) orelse return wz.paint(hdc);
        defer _ = w32.DeleteObject(bmp);
        const old = w32.SelectObject(mem, bmp);
        wz.paint(mem);
        _ = w32.BitBlt(hdc, 0, 0, client.right, client.bottom, mem, 0, 0, w32.SRCCOPY);
        if (old) |o| _ = w32.SelectObject(mem, o);
    }

    fn paint(wz: *Wizard, hdc: w32.HDC) void {
        _ = w32.SetBkMode(hdc, w32.TRANSPARENT);
        wz.ensureArt();
        const page = wz.page;

        if (page.usesWelcomeArt()) {
            wz.drawWelcomeArt(hdc);
        } else {
            var content = wz.rect(0, banner_height, width, art_height - banner_height);
            _ = w32.FillRect(hdc, &content, wz.brush_white);
            wz.drawBanner(hdc);
        }

        // Button bar with a hairline above it, and the product on its left.
        var bar = wz.rect(0, art_height, width, height - art_height);
        _ = w32.FillRect(hdc, &bar, wz.brush_bar);
        var line: w32.RECT = .{ .left = 0, .top = wz.px(art_height), .right = wz.px(width), .bottom = wz.px(art_height) + @max(1, @divFloor(wz.px(1), 1)) };
        _ = w32.FillRect(hdc, &line, wz.brush_line);
        wz.drawText(hdc, wz.font_small, color_muted, wz.rect(14, art_height, 200, height - art_height), config.display_name ++ " " ++ config.version, w32.DT_SINGLELINE | w32.DT_VCENTER | w32.DT_END_ELLIPSIS);

        switch (page) {
            .welcome => wz.welcomeText(hdc, "Welcome to " ++ config.display_name ++ " Setup", wz.welcomeBody()),
            .finish => if (wz.outcome == .success)
                wz.welcomeText(hdc, config.display_name ++ " is installed", config.finish_text orelse
                    "Setup has installed " ++ config.display_name ++ " " ++ config.version ++ " on your computer.\n\nClick Finish to close Setup.")
            else
                wz.welcomeText(hdc, "Setup could not finish", wz.failureBody("Setup")),
            .uninstall_finish => if (wz.outcome == .success)
                wz.welcomeText(hdc, config.display_name ++ " was removed", config.display_name ++ " has been removed from your computer.\n\nClick Close to exit.")
            else
                wz.welcomeText(hdc, "Uninstall could not finish", wz.failureBody("the uninstaller")),
            .license => {},
            .location => {
                const intro = if (config.allow_install_dir_change)
                    "Setup will install " ++ config.display_name ++ " in the folder below. To use a different folder, click Browse or type its path."
                else
                    "Setup will install " ++ config.display_name ++ " in the folder below.";
                wz.drawText(hdc, wz.font_body, color_body, wz.rect(margin, banner_height + 18, width - 2 * margin, 40), intro, w32.DT_WORDBREAK);
                wz.spaceText(hdc);
            },
            .options => {
                wz.drawText(hdc, wz.font_body, color_body, wz.rect(margin, banner_height + 18, width - 2 * margin, 36), "Choose the additional tasks for Setup to perform, then click Install.", w32.DT_WORDBREAK);
                const dir = wz.getText(wz.dir_edit);
                const where = std.fmt.allocPrint(wz.s.gpa, "Install location:\n{s}", .{dir}) catch "";
                wz.drawText(hdc, wz.font_body, color_muted, wz.rect(margin, art_height - 58, width - 2 * margin, 44), where, w32.DT_WORDBREAK | w32.DT_PATH_ELLIPSIS);
            },
            .in_use => {
                const what = if (wz.in_use_op == .install) "Setup needs to replace" else "the uninstaller needs to remove";
                const how = if (config.close_running_apps)
                    "Close them and click Retry, or click Close programs to close them now."
                else
                    "Close them, then click Retry.";
                const body = std.fmt.allocPrint(wz.s.gpa, "These programs are using files that {s}. {s}", .{ what, how }) catch "";
                wz.drawText(hdc, wz.font_body, color_body, wz.rect(margin, banner_height + 16, width - 2 * margin, in_use_list_y - banner_height - 20), body, w32.DT_WORDBREAK);
            },
            .installing, .uninstalling => {
                wz.drawText(hdc, wz.font_body, color_body, wz.rect(margin, banner_height + 44, width - 2 * margin, 22), wz.status[0..wz.status_len], w32.DT_SINGLELINE | w32.DT_PATH_ELLIPSIS);
            },
            .uninstall_confirm => {
                const body = std.fmt.allocPrint(
                    wz.s.gpa,
                    config.display_name ++ " " ++ config.version ++ " will be removed from your computer, with its shortcuts and the files Setup installed in:\n\n{s}\n\nClick Uninstall to continue.",
                    .{wz.uninstall_dir},
                ) catch "";
                wz.drawText(hdc, wz.font_body, color_body, wz.rect(margin, banner_height + 18, width - 2 * margin, art_height - banner_height - 30), body, w32.DT_WORDBREAK);
            },
        }
    }

    fn welcomeBody(wz: *Wizard) []const u8 {
        if (config.welcome_text) |t| return t;
        const intro = "Setup will install " ++ config.display_name ++ " " ++ config.version ++ " on your computer.";
        const outro = "\n\nClose other programs before you continue.\n\nClick Next to continue, or Cancel to exit Setup.";
        if (wz.installed_version) |v| {
            const note = if (std.mem.eql(u8, v, config.version))
                "\n\nThis version is already installed; Setup will repair it."
            else
                std.fmt.allocPrint(wz.s.gpa, "\n\nVersion {s} is installed and will be upgraded.", .{v}) catch "";
            return std.mem.concat(wz.s.gpa, u8, &.{ intro, note, outro }) catch intro;
        }
        return intro ++ outro;
    }

    fn failureBody(wz: *Wizard, comptime who: []const u8) []const u8 {
        const reason = wz.failure orelse "An unknown error occurred.";
        return std.fmt.allocPrint(wz.s.gpa, "{s}\n\nClick Close to exit " ++ who ++ ".", .{reason}) catch reason;
    }

    /// "Space required" and "Space available" on the location page.
    fn spaceText(wz: *Wizard, hdc: w32.HDC) void {
        var need_buf: [32]u8 = undefined;
        const need = cli.formatSize(&need_buf, main.payloadSize());
        var free_buf: [32]u8 = undefined;
        const free: []const u8 = if (freeSpace(wz.s.gpa, wz.getText(wz.dir_edit))) |bytes|
            cli.formatSize(&free_buf, bytes)
        else
            "drive not available";
        var buf: [128]u8 = undefined;
        const t = std.fmt.bufPrint(&buf, "Space required:  {s}\nSpace available:  {s}", .{ need, free }) catch return;
        wz.drawText(hdc, wz.font_body, color_muted, wz.rect(margin, location_edit_y + 40, width - 2 * margin, 44), t, w32.DT_WORDBREAK);
    }

    fn welcomeText(wz: *Wizard, hdc: w32.HDC, title: []const u8, body: []const u8) void {
        const x = welcome_text_x;
        const w = width - x - 22;
        var title_rect = wz.rect(x, 26, w, 120);
        const title_h = wz.measure(hdc, wz.font_heading, title_rect, title);
        title_rect.bottom = title_rect.top + title_h;
        wz.drawText(hdc, wz.font_heading, color_text, title_rect, title, w32.DT_WORDBREAK);
        var body_rect = wz.rect(x, 0, w, 0);
        body_rect.top = title_rect.bottom + wz.px(14);
        body_rect.bottom = wz.px(art_height - 50);
        wz.drawText(hdc, wz.font_body, color_body, body_rect, body, w32.DT_WORDBREAK);
    }

    fn drawWelcomeArt(wz: *Wizard, hdc: w32.HDC) void {
        const dest = wz.rect(0, 0, width, art_height);
        if (wz.assets.welcome) |img| {
            drawBits(hdc, dest, img.bgrx, img.width, img.height);
            return;
        }
        if (wz.welcome_art) |bits| {
            drawBits(hdc, dest, bits, @intCast(dest.right), @intCast(dest.bottom));
        } else {
            _ = w32.FillRect(hdc, &dest, wz.brush_white);
        }
        if (wz.icon_large) |icon| {
            const size = wz.px(art.icon_size);
            const cx: i32 = @intFromFloat(@round(art.icon_center[0] * wz.scale()));
            const cy: i32 = @intFromFloat(@round(art.icon_center[1] * wz.scale()));
            _ = w32.DrawIconEx(hdc, cx - @divTrunc(size, 2), cy - @divTrunc(size, 2), icon, size, size, 0, null, w32.DI_NORMAL);
        }
    }

    fn drawBanner(wz: *Wizard, hdc: w32.HDC) void {
        const dest = wz.rect(0, 0, width, banner_height);
        if (wz.assets.banner) |img| {
            drawBits(hdc, dest, img.bgrx, img.width, img.height);
        } else {
            if (wz.banner_art) |bits| {
                drawBits(hdc, dest, bits, @intCast(dest.right), @intCast(dest.bottom));
            } else {
                _ = w32.FillRect(hdc, &dest, wz.brush_white);
            }
            if (wz.icon_banner) |icon| {
                const size = wz.px(32);
                _ = w32.DrawIconEx(hdc, wz.px(width - 20 - 32), wz.px(@divTrunc(banner_height - 32, 2)), icon, size, size, 0, null, w32.DI_NORMAL);
            }
        }
        var line: w32.RECT = .{ .left = 0, .top = wz.px(banner_height) - 1, .right = wz.px(width), .bottom = wz.px(banner_height) };
        _ = w32.FillRect(hdc, &line, wz.brush_line);

        const title, const subtitle = switch (wz.page) {
            .license => .{ "License Agreement", "Please review the license terms before installing " ++ config.display_name ++ "." },
            .location => .{ "Choose Install Location", "Choose the folder in which to install " ++ config.display_name ++ "." },
            .options => .{ "Additional Tasks", "Choose how " ++ config.display_name ++ " is set up." },
            .installing => .{ "Installing", "Please wait while Setup installs " ++ config.display_name ++ "." },
            .uninstall_confirm => .{ "Uninstall " ++ config.display_name, "Remove " ++ config.display_name ++ " from your computer." },
            .uninstalling => .{ "Uninstalling", "Please wait while " ++ config.display_name ++ " is removed." },
            .in_use => .{ "Programs in Use", "Some programs are using " ++ config.display_name ++ "'s files." },
            else => .{ "", "" },
        };
        wz.drawText(hdc, wz.font_title, color_text, wz.rect(20, 10, 340, 22), title, w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS);
        wz.drawText(hdc, wz.font_body, color_muted, wz.rect(20, 32, 360, 20), subtitle, w32.DT_SINGLELINE | w32.DT_END_ELLIPSIS);
    }

    /// Draws `bits` (BGRX rows, top down) into `dest`, scaled smoothly.
    fn drawBits(hdc: w32.HDC, dest: w32.RECT, bits: []const u8, w: u32, h: u32) void {
        const bmi: w32.BITMAPINFO = .{ .bmiHeader = .{ .biWidth = @intCast(w), .biHeight = -@as(i32, @intCast(h)) } };
        _ = w32.SetStretchBltMode(hdc, w32.HALFTONE);
        _ = w32.SetBrushOrgEx(hdc, 0, 0, null);
        _ = w32.StretchDIBits(hdc, dest.left, dest.top, dest.right - dest.left, dest.bottom - dest.top, 0, 0, @intCast(w), @intCast(h), bits.ptr, &bmi, w32.DIB_RGB_COLORS, w32.SRCCOPY);
    }

    /// Draws the built-in artwork at the current DPI, unless images were
    /// supplied.
    fn ensureArt(wz: *Wizard) void {
        if (wz.art_dpi == wz.dpi) return;
        const pa = std.heap.page_allocator;
        if (wz.welcome_art) |a| pa.free(a);
        if (wz.banner_art) |a| pa.free(a);
        wz.welcome_art = null;
        wz.banner_art = null;
        if (wz.assets.welcome == null) {
            wz.welcome_art = art.welcome(pa, @intCast(wz.px(width)), @intCast(wz.px(art_height)), wz.scale(), config.accent_color) catch null;
        }
        if (wz.assets.banner == null) {
            wz.banner_art = art.banner(pa, @intCast(wz.px(width)), @intCast(wz.px(banner_height)), wz.scale(), config.accent_color) catch null;
        }
        wz.art_dpi = wz.dpi;
    }

    fn drawText(wz: *const Wizard, hdc: w32.HDC, f: ?w32.HGDIOBJ, color: u32, r: w32.RECT, t: []const u8, flags: u32) void {
        _ = wz;
        var buf: [4096]u16 = undefined;
        const t_w = toWide(&buf, t);
        const old = if (f) |obj| w32.SelectObject(hdc, obj) else null;
        defer if (old) |o| {
            _ = w32.SelectObject(hdc, o);
        };
        _ = w32.SetTextColor(hdc, colorref(color));
        var rr = r;
        _ = w32.DrawTextW(hdc, t_w.ptr, @intCast(t_w.len), &rr, flags | w32.DT_NOPREFIX);
    }

    /// Height of `t` word-wrapped in `r`'s width.
    fn measure(wz: *const Wizard, hdc: w32.HDC, f: ?w32.HGDIOBJ, r: w32.RECT, t: []const u8) i32 {
        _ = wz;
        var buf: [4096]u16 = undefined;
        const t_w = toWide(&buf, t);
        const old = if (f) |obj| w32.SelectObject(hdc, obj) else null;
        defer if (old) |o| {
            _ = w32.SelectObject(hdc, o);
        };
        var rr = r;
        _ = w32.DrawTextW(hdc, t_w.ptr, @intCast(t_w.len), &rr, w32.DT_WORDBREAK | w32.DT_CALCRECT | w32.DT_NOPREFIX);
        return rr.bottom - rr.top;
    }

    // ---- Helpers

    fn colorref(rgb: u32) u32 {
        return ((rgb & 0xff) << 16) | (rgb & 0xff00) | ((rgb >> 16) & 0xff);
    }

    /// Converts as much of `t` as fits into `buf`.
    fn toWide(buf: []u16, t: []const u8) []u16 {
        var end = @min(t.len, buf.len);
        while (end > 0 and !std.unicode.utf8ValidateSlice(t[0..end])) end -= 1;
        const n = std.unicode.wtf8ToWtf16Le(buf, t[0..end]) catch 0;
        return buf[0..n];
    }

    fn wide(gpa: Allocator, t: []const u8) [:0]const u16 {
        return std.unicode.wtf8ToWtf16LeAllocZ(gpa, t) catch std.unicode.utf8ToUtf16LeStringLiteral("");
    }

    fn setText(wz: *const Wizard, h: w32.HWND, t: []const u8) void {
        _ = w32.SetWindowTextW(h, wide(wz.s.gpa, t).ptr);
    }

    fn getText(wz: *const Wizard, h: w32.HWND) []const u8 {
        const len = w32.GetWindowTextLengthW(h);
        if (len <= 0) return "";
        const buf = wz.s.gpa.alloc(u16, @intCast(len + 1)) catch return "";
        const n = w32.GetWindowTextW(h, buf.ptr, len + 1);
        const t = std.unicode.wtf16LeToWtf8Alloc(wz.s.gpa, buf[0..@intCast(@max(n, 0))]) catch return "";
        return std.mem.trim(u8, t, " \t\"");
    }

    /// Free bytes on the volume `dir` is on, or null if it is not
    /// available.
    fn freeSpace(gpa: Allocator, dir: []const u8) ?u64 {
        const root = cli.volumeRoot(dir) orelse return null;
        const root_w = std.unicode.wtf8ToWtf16LeAllocZ(gpa, root) catch return null;
        var bytes: u64 = 0;
        if (w32.GetDiskFreeSpaceExW(root_w.ptr, &bytes, null, null) == 0) return null;
        return bytes;
    }

    fn checked(h: w32.HWND) bool {
        return w32.SendMessageW(h, w32.BM_GETCHECK, 0, 0) == w32.BST_CHECKED;
    }

    fn check(h: w32.HWND, on: bool) void {
        _ = w32.SendMessageW(h, w32.BM_SETCHECK, @intFromBool(on), 0);
    }

    // ---- Window procedure

    fn wndProc(hwnd: w32.HWND, msg: u32, wp: w32.WPARAM, lp: w32.LPARAM) callconv(.winapi) w32.LRESULT {
        const wz = current orelse return w32.DefWindowProcW(hwnd, msg, wp, lp);
        if (!wz.ready) return w32.DefWindowProcW(hwnd, msg, wp, lp);
        switch (msg) {
            w32.WM_PAINT => {
                var ps: w32.PAINTSTRUCT = .{};
                const hdc = w32.BeginPaint(hwnd, &ps) orelse return 0;
                wz.paintBuffered(hdc);
                _ = w32.EndPaint(hwnd, &ps);
                return 0;
            },
            w32.WM_PRINTCLIENT => {
                const hdc: w32.HDC = @ptrFromInt(wp);
                wz.paint(hdc);
                return 0;
            },
            w32.WM_ERASEBKGND => return 1,
            w32.WM_COMMAND => {
                wz.command(@truncate(wp), @truncate(wp >> 16));
                return 0;
            },
            w32.WM_CTLCOLORSTATIC, w32.WM_CTLCOLOREDIT => {
                const hdc: w32.HDC = @ptrFromInt(wp);
                _ = w32.SetBkColor(hdc, colorref(color_white));
                _ = w32.SetTextColor(hdc, colorref(color_text));
                return @bitCast(@intFromPtr(wz.brush_white));
            },
            w32.WM_CTLCOLORBTN => {
                const control: ?w32.HWND = @ptrFromInt(@as(usize, @bitCast(lp)));
                const on_white = control == wz.browse;
                return @bitCast(@intFromPtr(if (on_white) wz.brush_white else wz.brush_bar));
            },
            w32.WM_DPICHANGED => {
                const r: *const w32.RECT = @ptrFromInt(@as(usize, @bitCast(lp)));
                wz.onDpiChanged(@truncate(wp), r);
                return 0;
            },
            w32.WM_CLOSE => {
                wz.onCancel();
                return 0;
            },
            w32.WM_DESTROY => {
                w32.PostQuitMessage(@intFromEnum(wz.outcome));
                return 0;
            },
            else => return w32.DefWindowProcW(hwnd, msg, wp, lp),
        }
    }
};
