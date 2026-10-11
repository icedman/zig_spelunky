//! SDL2 keyboard -> GameMaker virtual keys, and the event pump.

const app_mod = @import("app");
const keys = app_mod.keys;
const c = @import("sdl");

/// SDL keycode -> GameMaker virtual key, null if unmapped.
pub fn vkOf(k: c.SDL_Keycode) ?i32 {
    if (k >= c.SDLK_a and k <= c.SDLK_z) return 'A' + (k - c.SDLK_a);
    if (k >= c.SDLK_0 and k <= c.SDLK_9) return '0' + (k - c.SDLK_0);
    if (k >= c.SDLK_F1 and k <= c.SDLK_F12) return keys.vk_f1 + (k - c.SDLK_F1);
    if (k >= c.SDLK_KP_1 and k <= c.SDLK_KP_9) return keys.vk_numpad0 + 1 + (k - c.SDLK_KP_1);
    return switch (k) {
        c.SDLK_KP_0 => keys.vk_numpad0,
        c.SDLK_LEFT => keys.vk_left,
        c.SDLK_UP => keys.vk_up,
        c.SDLK_RIGHT => keys.vk_right,
        c.SDLK_DOWN => keys.vk_down,
        c.SDLK_RETURN, c.SDLK_KP_ENTER => keys.vk_enter,
        c.SDLK_ESCAPE => keys.vk_escape,
        c.SDLK_SPACE => keys.vk_space,
        c.SDLK_BACKSPACE => keys.vk_backspace,
        c.SDLK_TAB => keys.vk_tab,
        c.SDLK_LSHIFT, c.SDLK_RSHIFT => keys.vk_shift,
        c.SDLK_LCTRL, c.SDLK_RCTRL => keys.vk_control,
        c.SDLK_LALT, c.SDLK_RALT => keys.vk_alt,
        c.SDLK_PAUSE => keys.vk_pause,
        c.SDLK_PAGEUP => keys.vk_pageup,
        c.SDLK_PAGEDOWN => keys.vk_pagedown,
        c.SDLK_END => keys.vk_end,
        c.SDLK_HOME => keys.vk_home,
        c.SDLK_INSERT => keys.vk_insert,
        c.SDLK_DELETE => keys.vk_delete,
        else => null,
    };
}

/// Delivers pending events to the app; false when the window was closed.
pub fn pump(app: *app_mod.App) bool {
    var ev: c.SDL_Event = undefined;
    while (c.SDL_PollEvent(&ev) != 0) {
        switch (ev.type) {
            c.SDL_QUIT => return false,
            c.SDL_KEYDOWN, c.SDL_KEYUP => {
                const vk = vkOf(ev.key.keysym.sym) orelse continue;
                app.key(vk, if (ev.type == c.SDL_KEYUP) .release else if (ev.key.repeat != 0) .repeat else .press);
            },
            else => {},
        }
    }
    return true;
}

test vkOf {
    const std = @import("std");
    try std.testing.expectEqual(@as(?i32, 'A'), vkOf(c.SDLK_a));
    try std.testing.expectEqual(@as(?i32, 'Z'), vkOf(c.SDLK_z));
    try std.testing.expectEqual(@as(?i32, '7'), vkOf(c.SDLK_7));
    try std.testing.expectEqual(@as(?i32, 123), vkOf(c.SDLK_F12));
    try std.testing.expectEqual(@as(?i32, 96), vkOf(c.SDLK_KP_0));
    try std.testing.expectEqual(@as(?i32, 105), vkOf(c.SDLK_KP_9));
    try std.testing.expectEqual(@as(?i32, 13), vkOf(c.SDLK_KP_ENTER));
    try std.testing.expectEqual(@as(?i32, 16), vkOf(c.SDLK_RSHIFT));
    try std.testing.expectEqual(@as(?i32, 40), vkOf(c.SDLK_DOWN));
    try std.testing.expectEqual(@as(?i32, null), vkOf(c.SDLK_F13));
}
