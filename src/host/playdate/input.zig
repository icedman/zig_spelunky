//! Playdate buttons, crank and system menu -> GameMaker virtual keys.
//! Port of pump_input in src/host/playdate/main_playdate.c.
//!
//!   d-pad = arrows, A = jump (Z) + Enter, B = whip / action (X),
//!   double-tap left / right or crank undocked = run (Shift),
//!   cranking forward / back by `crank_step` degrees taps bomb (A) / rope (S),
//!   system menu: "pause" (Escape), "item" (C), "pay" (P).
//!
//! Taps (crank, menu) are pressed for exactly one game step: released on the
//! next pump.

const app_mod = @import("app");
const keys = app_mod.keys;
const pd_mod = @import("pd.zig");
const api = pd_mod.api;

pub const crank_step: f32 = 180.0;
pub const double_tap_timeout_ms: u32 = 300;
pub const tap_max_duration_ms: u32 = 300;
pub const run_retain_ms: u32 = 500;
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
    .{ .title = "pay", .vk = 'P' },
    .{ .title = "bomb", .vk = 'A' },
    .{ .title = "rope", .vk = 'S' },
    // .{ .title = "item", .vk = 'C' },
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
    shift_held: bool = false,
    left_press_time: ?u32 = null,
    left_tap_time: ?u32 = null,
    right_press_time: ?u32 = null,
    right_tap_time: ?u32 = null,
    run_release_time: ?u32 = null,
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

    /// Updates double-tap run and release retention state.
    pub fn updateRun(self: *Input, now: u32, cur: api.PDButtons, pushed: api.PDButtons, released: api.PDButtons) void {
        // Double tap detection on LEFT
        if (pushed & api.BUTTON_LEFT != 0) {
            if (self.left_tap_time) |tap_time| {
                if (now -% tap_time <= double_tap_timeout_ms) {
                    self.run_held = true;
                    self.run_release_time = null;
                }
            }
            self.left_tap_time = null;
            self.left_press_time = now;
            self.right_tap_time = null;
        }
        if (released & api.BUTTON_LEFT != 0 and cur & api.BUTTON_LEFT == 0) {
            if (self.left_press_time) |press_time| {
                if (now -% press_time <= tap_max_duration_ms) {
                    self.left_tap_time = now;
                } else {
                    self.left_tap_time = null;
                }
                self.left_press_time = null;
            }
        }

        // Double tap detection on RIGHT
        if (pushed & api.BUTTON_RIGHT != 0) {
            if (self.right_tap_time) |tap_time| {
                if (now -% tap_time <= double_tap_timeout_ms) {
                    self.run_held = true;
                    self.run_release_time = null;
                }
            }
            self.right_tap_time = null;
            self.right_press_time = now;
            self.left_tap_time = null;
        }
        if (released & api.BUTTON_RIGHT != 0 and cur & api.BUTTON_RIGHT == 0) {
            if (self.right_press_time) |press_time| {
                if (now -% press_time <= tap_max_duration_ms) {
                    self.right_tap_time = now;
                } else {
                    self.right_tap_time = null;
                }
                self.right_press_time = null;
            }
        }

        // If run_held is active, keep it while left/right is held;
        // when left/right was released, retain for half a second before releasing.
        if (self.run_held) {
            const dir_held = (cur & (api.BUTTON_LEFT | api.BUTTON_RIGHT)) != 0;
            if (dir_held) {
                self.run_release_time = null;
            } else {
                if (self.run_release_time) |rel_time| {
                    if (now -% rel_time >= run_retain_ms) {
                        self.run_held = false;
                        self.run_release_time = null;
                    }
                } else {
                    self.run_release_time = now;
                }
            }
        }
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

        const now: u32 = sys.getCurrentTimeMilliseconds();
        self.updateRun(now, cur, pushed, released);

        const crank_open = sys.isCrankDocked() == 0;
        // const run = crank_open or self.run_held;
        // if (run != self.shift_held) {
        //     app.key(keys.vk_shift, if (run) .press else .release);
        //     self.shift_held = run;
        // }

        if (crank_open) {
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
        return 'C';
    }
    if (acc.* <= -crank_step) {
        acc.* = 0.0;
        return 'C';
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

test "double tap left activates run_held and release retains for half second" {
    const std = @import("std");
    var in: Input = .{};

    // First tap left: press at 100, release at 150
    in.updateRun(100, api.BUTTON_LEFT, api.BUTTON_LEFT, 0);
    try std.testing.expect(!in.run_held);
    in.updateRun(150, 0, 0, api.BUTTON_LEFT);
    try std.testing.expect(!in.run_held);

    // Second tap left: press at 250 (gap 100ms <= 300ms)
    in.updateRun(250, api.BUTTON_LEFT, api.BUTTON_LEFT, 0);
    try std.testing.expect(in.run_held);

    // Continue holding left at 300
    in.updateRun(300, api.BUTTON_LEFT, 0, 0);
    try std.testing.expect(in.run_held);

    // Release left at 400
    in.updateRun(400, 0, 0, api.BUTTON_LEFT);
    try std.testing.expect(in.run_held); // Retained!

    // Still within half a second: 400 + 490 = 890
    in.updateRun(890, 0, 0, 0);
    try std.testing.expect(in.run_held); // Still retained!

    // Half a second expires: 400 + 500 = 900
    in.updateRun(900, 0, 0, 0);
    try std.testing.expect(!in.run_held); // Released!
}

test "double tap right and pressing direction during retain continues run" {
    const std = @import("std");
    var in: Input = .{};

    // Double tap right: press at 50, release at 100, press at 200
    in.updateRun(50, api.BUTTON_RIGHT, api.BUTTON_RIGHT, 0);
    in.updateRun(100, 0, 0, api.BUTTON_RIGHT);
    in.updateRun(200, api.BUTTON_RIGHT, api.BUTTON_RIGHT, 0);
    try std.testing.expect(in.run_held);

    // Release right at 300 -> starts 500ms retain
    in.updateRun(300, 0, 0, api.BUTTON_RIGHT);
    try std.testing.expect(in.run_held);

    // 300ms later (at 600), press LEFT to run in opposite direction
    in.updateRun(600, api.BUTTON_LEFT, api.BUTTON_LEFT, 0);
    try std.testing.expect(in.run_held);

    // Release left at 800 -> new 500ms retain window
    in.updateRun(800, 0, 0, api.BUTTON_LEFT);
    try std.testing.expect(in.run_held);

    // Check at 1290 (490ms after release): still retained
    in.updateRun(1290, 0, 0, 0);
    try std.testing.expect(in.run_held);

    // Check at 1300 (500ms after release): released
    in.updateRun(1300, 0, 0, 0);
    try std.testing.expect(!in.run_held);
}

test "alternating left then right does not trigger double tap" {
    const std = @import("std");
    var in: Input = .{};

    // Tap left at 100, release at 150
    in.updateRun(100, api.BUTTON_LEFT, api.BUTTON_LEFT, 0);
    in.updateRun(150, 0, 0, api.BUTTON_LEFT);
    try std.testing.expect(!in.run_held);

    // Tap right at 200
    in.updateRun(200, api.BUTTON_RIGHT, api.BUTTON_RIGHT, 0);
    try std.testing.expect(!in.run_held);
}

test "slow double tap (>300ms gap) does not trigger double tap" {
    const std = @import("std");
    var in: Input = .{};

    // Tap left at 100, release at 150
    in.updateRun(100, api.BUTTON_LEFT, api.BUTTON_LEFT, 0);
    in.updateRun(150, 0, 0, api.BUTTON_LEFT);
    try std.testing.expect(!in.run_held);

    // Second press at 500 (gap 350ms > 300ms)
    in.updateRun(500, api.BUTTON_LEFT, api.BUTTON_LEFT, 0);
    try std.testing.expect(!in.run_held);
}
