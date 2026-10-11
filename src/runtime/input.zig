//! Keyboard state and mapping as GameMaker-HTML5 runner keeps it.
//! Follows yyIOManager.js and packaged_src/src/runtime/gm_input.c.

const std = @import("std");

pub const MAX_KEYS: usize = 256;
pub const VK_NOKEY: i32 = 0;
pub const VK_ANYKEY: i32 = 1;

pub const InputManager = struct {
    raw_down: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS,
    raw_pressed: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS,
    raw_up: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS,
    raw_last: i32 = 0,

    down: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS,
    pressed: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS,
    released: [MAX_KEYS]bool = [_]bool{false} ** MAX_KEYS,
    map: [MAX_KEYS]i32 = [_]i32{0} ** MAX_KEYS, // mapped key + 1; 0 = identity

    keyboard_key: i32 = 0,
    keyboard_lastkey: i32 = 0,

    var instance: InputManager = .{};

    pub fn get() *InputManager {
        return &instance;
    }

    fn valid(key: i32) bool {
        return key >= 0 and key < @as(i32, @intCast(MAX_KEYS));
    }

    pub fn reset(self: *InputManager) void {
        @memset(&self.raw_down, false);
        @memset(&self.raw_pressed, false);
        @memset(&self.raw_up, false);
        @memset(&self.down, false);
        @memset(&self.pressed, false);
        @memset(&self.released, false);
        @memset(&self.map, 0);
        self.raw_last = 0;
        self.keyboard_key = 0;
        self.keyboard_lastkey = 0;
    }

    pub fn keyDown(self: *InputManager, key: i32) void {
        if (!valid(key)) return;
        const ukey: usize = @intCast(key);
        if (!self.raw_down[ukey]) {
            self.raw_pressed[ukey] = true;
        }
        self.raw_down[ukey] = true;
        self.raw_last = key;
    }

    pub fn keyUp(self: *InputManager, key: i32) void {
        if (!valid(key)) return;
        const ukey: usize = @intCast(key);
        self.raw_up[ukey] = true;
        self.raw_down[ukey] = false;
    }

    pub fn startStep(self: *InputManager) void {
        var any_pressed = false;
        var any_down = false;
        var any_released = false;

        @memset(&self.down, false);
        @memset(&self.pressed, false);
        @memset(&self.released, false);

        for (0..MAX_KEYS) |i| {
            const mapped_key = if (self.map[i] != 0) self.map[i] - 1 else @as(i32, @intCast(i));
            if (valid(mapped_key)) {
                const ukey: usize = @intCast(mapped_key);
                self.pressed[ukey] = self.pressed[ukey] or self.raw_pressed[i];
                self.released[ukey] = self.released[ukey] or self.raw_up[i];
                self.down[ukey] = self.down[ukey] or self.raw_down[i];
            }
            any_pressed = any_pressed or self.raw_pressed[i];
            any_down = any_down or self.raw_down[i];
            any_released = any_released or self.raw_up[i];
            self.raw_pressed[i] = false;
            self.raw_up[i] = false;
        }

        self.pressed[VK_ANYKEY] = any_pressed;
        self.down[VK_ANYKEY] = any_down;
        self.released[VK_ANYKEY] = any_released;

        self.pressed[VK_NOKEY] = !any_pressed;
        self.down[VK_NOKEY] = !any_down;
        self.released[VK_NOKEY] = !any_released;

        if (self.raw_last != 0) {
            if (self.keyboard_key != 0) {
                self.keyboard_lastkey = self.keyboard_key;
            }
            self.keyboard_key = self.raw_last;
            self.raw_last = 0;
        } else if (!valid(self.keyboard_key) or !self.down[@intCast(self.keyboard_key)]) {
            self.keyboard_lastkey = self.keyboard_key;
            self.keyboard_key = 0;
        }
    }

    pub fn check(self: *const InputManager, key: i32) bool {
        return if (valid(key)) self.down[@intCast(key)] else false;
    }

    pub fn checkPressed(self: *const InputManager, key: i32) bool {
        return if (valid(key)) self.pressed[@intCast(key)] else false;
    }

    pub fn checkReleased(self: *const InputManager, key: i32) bool {
        return if (valid(key)) self.released[@intCast(key)] else false;
    }

    pub fn clear(self: *InputManager, key: i32) void {
        if (!valid(key)) return;
        const ukey: usize = @intCast(key);
        self.down[ukey] = false;
        self.pressed[ukey] = false;
        self.released[ukey] = false;
    }

    pub fn setMap(self: *InputManager, from: i32, to: i32) void {
        if (!valid(from) or !valid(to)) return;
        self.map[@intCast(from)] = to + 1;
    }

    pub fn getKeyboardKey(self: *const InputManager) i32 {
        return self.keyboard_key;
    }

    pub fn getKeyboardLastkey(self: *const InputManager) i32 {
        return self.keyboard_lastkey;
    }

    pub fn setKeyboardKey(self: *InputManager, key: i32) void {
        self.keyboard_key = key;
    }

    pub fn setKeyboardLastkey(self: *InputManager, key: i32) void {
        self.keyboard_lastkey = key;
    }
};

test "InputManager key events, step transitions, anykey, and remapping" {
    var im = InputManager.get();
    im.reset();

    const KEY_A = 65;
    const KEY_B = 66;

    im.keyDown(KEY_A);
    im.startStep();

    try std.testing.expect(im.check(KEY_A));
    try std.testing.expect(im.checkPressed(KEY_A));
    try std.testing.expect(!im.checkReleased(KEY_A));
    try std.testing.expect(im.check(VK_ANYKEY));
    try std.testing.expect(!im.check(VK_NOKEY));

    // Next step without key release: down remains true, pressed becomes false
    im.startStep();
    try std.testing.expect(im.check(KEY_A));
    try std.testing.expect(!im.checkPressed(KEY_A));

    // Key up
    im.keyUp(KEY_A);
    im.startStep();
    try std.testing.expect(!im.check(KEY_A));
    try std.testing.expect(im.checkReleased(KEY_A));

    // Key remapping
    im.setMap(KEY_A, KEY_B);
    im.keyDown(KEY_A);
    im.startStep();
    try std.testing.expect(im.check(KEY_B));
}
