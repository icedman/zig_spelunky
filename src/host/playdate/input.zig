//! Playdate buttons, crank and system menu -> GameMaker virtual keys.
//! Port of pump_input in src/host/playdate/main_playdate.c.
//!
//!   d-pad = arrows, A = jump (Z) + Enter, B = whip / action (X),
//!   crank undocked = run (Shift); cranking forward / back by `crank_step`
//!   degrees taps bomb (A) / rope (S),
//!   system menu: "pause" (Escape), "item" (C), "pay" (P).
//!
//! Taps (crank, menu) are pressed for exactly one game step: released on the
//! next pump.

const app_mod = @import("app");
const keys = app_mod.keys;
const pd_mod = @import("pd.zig");
const api = pd_mod.api;

pub const crank_step: f32 = 60.0;
const tap_max = 16;

const KeyMap = struct { button: api.PDButtons, vk: i32 };

const key_map = [_]KeyMap{
    .{ .button = api.BUTTON_LEFT, .vk = keys.vk_left },
    .{ .button = api.BUTTON_RIGHT, .vk = keys.vk_right },
    .{ .button = api.BUTTON_UP, .vk = keys.vk_up },
    .{ .button = api.BUTTON_DOWN, .vk = keys.vk_down },
    .{ .button = api.BUTTON_A, .vk = 'Z' }, // jump
    .{ .button = api.BUTTON_A, .vk = keys.vk_enter }, // menus
    .{ .button = api.BUTTON_B, .vk = 'X' }, // whip / action
};

pub const MenuItem = struct { title: [:0]const u8, vk: i32 };

pub const menu_items = [_]MenuItem{
    .{ .title = "pause", .vk = keys.vk_escape },
    .{ .title = "item", .vk = 'C' },
};

/// Bounded list of keys.
const Keys = struct {
    items: [tap_max]i32 = undefined,
    len: usize = 0,

    fn add(self: *Keys, vk: i32) void {
        if (self.len == tap_max) return;
        self.items[self.len] = vk;
        self.len += 1;
    }

    fn slice(self: *const Keys) []const i32 {
        return self.items[0..self.len];
    }
};

pub const Input = struct {
    crank: f32 = 0.0,
    run_held: bool = false,
    /// Pressed on the next pump (crank, menu callbacks).
    taps: Keys = .{},
    /// Pressed on the last pump, released on the next.
    releases: Keys = .{},

    /// Adds the system menu items; their callbacks tap through `self`.
    pub fn addMenuItems(self: *Input) void {
        for (&menu_items) |*item| {
            _ = pd_mod.pd.system.addMenuItem(item.title, menuTap, @constCast(item));
        }
        menu_input = self;
    }

    pub fn tap(self: *Input, vk: i32) void {
        self.taps.add(vk);
    }

    /// Delivers this frame's input to the app.
    pub fn pump(self: *Input, app: *app_mod.App) void {
        for (self.releases.slice()) |vk| app.key(vk, .release);
        self.releases.len = 0;

        const sys = pd_mod.pd.system;
        // Short C enums on the device: only the low byte may be written.
        var cur: api.PDButtons = 0;
        var pushed: api.PDButtons = 0;
        var released: api.PDButtons = 0;
        sys.getButtonState(&cur, &pushed, &released);
        for (key_map) |m| {
            if (pushed & m.button != 0) app.key(m.vk, .press);
            if (released & m.button != 0 and cur & m.button == 0) app.key(m.vk, .release);
        }

        const run = sys.isCrankDocked() == 0;
        if (run != self.run_held) {
            app.key(keys.vk_shift, if (run) .press else .release);
            self.run_held = run;
        }
        if (run) {
            if (crankTap(&self.crank, sys.getCrankChange())) |vk| self.tap(vk);
        } else {
            self.crank = 0.0;
        }

        for (self.taps.slice()) |vk| {
            app.key(vk, .press);
            self.releases.add(vk);
        }
        self.taps.len = 0;
    }
};

/// Accumulates crank motion (reset on a direction change); a full step
/// forward taps bomb, backward rope.
fn crankTap(acc: *f32, change: f32) ?i32 {
    if ((change > 0.0 and acc.* < 0.0) or (change < 0.0 and acc.* > 0.0)) acc.* = 0.0;
    acc.* += change;
    if (acc.* >= crank_step) {
        acc.* = 0.0;
        return 'A';
    }
    if (acc.* <= -crank_step) {
        acc.* = 0.0;
        return 'S';
    }
    return null;
}

var menu_input: ?*Input = null;

fn menuTap(userdata: ?*anyopaque) callconv(.c) void {
    const item: *const MenuItem = @ptrCast(@alignCast(userdata.?));
    if (menu_input) |in| in.tap(item.vk);
}

test crankTap {
    const std = @import("std");
    var acc: f32 = 0.0;
    try std.testing.expectEqual(@as(?i32, null), crankTap(&acc, 30.0));
    try std.testing.expectEqual(@as(?i32, 'A'), crankTap(&acc, 30.0));
    try std.testing.expectEqual(@as(f32, 0.0), acc);
    try std.testing.expectEqual(@as(?i32, null), crankTap(&acc, 50.0));
    // Reversing drops the forward progress.
    try std.testing.expectEqual(@as(?i32, null), crankTap(&acc, -50.0));
    try std.testing.expectEqual(@as(?i32, 'S'), crankTap(&acc, -10.0));
}
