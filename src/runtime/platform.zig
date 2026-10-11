//! Platform & Audio Hardware Abstraction Interfaces.
//! Decouples video, windowing, keyboard/gamepad input, and sound playback.

const std = @import("std");

pub const InputButton = enum(u32) {
    left = 1 << 0,
    right = 1 << 1,
    up = 1 << 2,
    down = 1 << 3,
    jump = 1 << 4, // 'Z' / Button A
    action = 1 << 5, // 'X' / Button B (Whip / Throw)
    bomb = 1 << 6, // 'C'
    rope = 1 << 7, // 'V'
    pay = 1 << 8, // 'P'
    start = 1 << 9, // Escape / Start
};

pub const InputState = struct {
    buttons_held: u32 = 0,
    buttons_pressed: u32 = 0,
    buttons_released: u32 = 0,

    pub inline fn isDown(self: InputState, btn: InputButton) bool {
        return (self.buttons_held & @intFromEnum(btn)) != 0;
    }

    pub inline fn isPressed(self: InputState, btn: InputButton) bool {
        return (self.buttons_pressed & @intFromEnum(btn)) != 0;
    }

    pub inline fn isReleased(self: InputState, btn: InputButton) bool {
        return (self.buttons_released & @intFromEnum(btn)) != 0;
    }
};

pub const PlatformInterface = struct {
    user_data: ?*anyopaque = null,

    init_fn: ?*const fn (ctx: ?*anyopaque, width: i32, height: i32, scale: i32) bool = null,
    shutdown_fn: ?*const fn (ctx: ?*anyopaque) void = null,
    poll_events_fn: ?*const fn (ctx: ?*anyopaque, out_input: *InputState) bool = null,

    begin_frame_fn: ?*const fn (ctx: ?*anyopaque, app_w: i32, app_h: i32) void = null,
    present_fn: ?*const fn (ctx: ?*anyopaque) void = null,
    clear_fn: ?*const fn (ctx: ?*anyopaque, colour: u32, alpha: f32) void = null,

    sprite_load_fn: ?*const fn (ctx: ?*anyopaque, sprite: i32, path: [*:0]const u8, frames: i32, out_w: *i32, out_h: *i32) bool = null,
    draw_image_fn: ?*const fn (
        ctx: ?*anyopaque,
        sprite: i32,
        frame: i32,
        sx: i32,
        sy: i32,
        sw: i32,
        sh: i32,
        x: f32,
        y: f32,
        xorig: f32,
        yorig: f32,
        xscale: f32,
        yscale: f32,
        angle: f32,
        colour: u32,
        alpha: f32,
    ) void = null,
    draw_rect_fn: ?*const fn (ctx: ?*anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, colour: u32, alpha: f32, outline: bool) void = null,
    draw_circle_fn: ?*const fn (ctx: ?*anyopaque, x: f32, y: f32, r: f32, colour: u32, alpha: f32, outline: bool) void = null,

    font_load_fn: ?*const fn (ctx: ?*anyopaque, path: [*:0]const u8, size: i32) i32 = null,
    draw_text_fn: ?*const fn (ctx: ?*anyopaque, font: i32, text: [*:0]const u8, x: f32, y: f32, scale: f32, colour: u32, alpha: f32) void = null,

    surface_create_fn: ?*const fn (ctx: ?*anyopaque, w: i32, h: i32) i32 = null,
    surface_free_fn: ?*const fn (ctx: ?*anyopaque, surface: i32) void = null,
    surface_target_fn: ?*const fn (ctx: ?*anyopaque, surface: i32) void = null,
    draw_surface_fn: ?*const fn (ctx: ?*anyopaque, surface: i32, x: f32, y: f32, w: f32, h: f32, alpha: f32) void = null,

    window_size_fn: ?*const fn (ctx: ?*anyopaque, out_w: *i32, out_h: *i32) void = null,
    display_size_fn: ?*const fn (ctx: ?*anyopaque, out_w: *i32, out_h: *i32) void = null,
    set_window_size_fn: ?*const fn (ctx: ?*anyopaque, w: i32, h: i32) void = null,
    set_fullscreen_fn: ?*const fn (ctx: ?*anyopaque, fullscreen: bool) void = null,

    get_ticks_ms_fn: ?*const fn (ctx: ?*anyopaque) u32 = null,
    delay_ms_fn: ?*const fn (ctx: ?*anyopaque, ms: u32) void = null,
    directory_exists_fn: ?*const fn (ctx: ?*anyopaque, path: [*:0]const u8) bool = null,
};

pub const AudioInterface = struct {
    user_data: ?*anyopaque = null,

    init_fn: ?*const fn (ctx: ?*anyopaque) bool = null,
    shutdown_fn: ?*const fn (ctx: ?*anyopaque) void = null,

    play_sound_fn: ?*const fn (ctx: ?*anyopaque, sound_id: i32, volume: f32, pan: f32, loop: bool) i32 = null,
    stop_sound_fn: ?*const fn (ctx: ?*anyopaque, handle: i32) void = null,
    stop_all_sounds_fn: ?*const fn (ctx: ?*anyopaque) void = null,
    set_sound_volume_fn: ?*const fn (ctx: ?*anyopaque, handle: i32, volume: f32) void = null,
    is_playing_fn: ?*const fn (ctx: ?*anyopaque, handle: i32) bool = null,
    pause_all_fn: ?*const fn (ctx: ?*anyopaque) void = null,
    resume_all_fn: ?*const fn (ctx: ?*anyopaque) void = null,
    set_master_volume_fn: ?*const fn (ctx: ?*anyopaque, volume: f32) void = null,

    play_music_fn: ?*const fn (ctx: ?*anyopaque, music_id: i32, loop: bool) void = null,
    stop_music_fn: ?*const fn (ctx: ?*anyopaque) void = null,
};

test "InputState bitwise queries" {
    var state = InputState{};
    state.buttons_held |= @intFromEnum(InputButton.jump);
    state.buttons_pressed |= @intFromEnum(InputButton.jump);

    try std.testing.expect(state.isDown(.jump));
    try std.testing.expect(state.isPressed(.jump));
    try std.testing.expect(!state.isDown(.action));
}
