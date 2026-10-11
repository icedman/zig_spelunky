//! GameMaker audio built-ins over sp_audio (Function_Audio.js subset).
//! Follows packaged_src/src/runtime/gm_audio.c and allows headless execution by default.

const std = @import("std");
const platform_mod = @import("platform.zig");
const AudioInterface = platform_mod.AudioInterface;

pub const AUDIO_HANDLE_BASE: i32 = 100000;

pub const AudioManager = struct {
    backend: AudioInterface = .{},
    headless_handle_counter: i32 = AUDIO_HANDLE_BASE,

    var instance: AudioManager = .{};

    pub fn get() *AudioManager {
        return &instance;
    }

    pub fn setBackend(self: *AudioManager, backend: AudioInterface) void {
        self.backend = backend;
    }

    pub fn reset(self: *AudioManager) void {
        self.headless_handle_counter = AUDIO_HANDLE_BASE;
        self.stopAll();
    }

    pub fn playSound(self: *AudioManager, sound: f32, priority: f32, loop: f32) f32 {
        _ = priority;
        const s: i32 = @intFromFloat(sound);
        if (s < 0) return -1.0;

        const is_loop = loop >= 0.5;
        if (self.backend.play_sound_fn) |play_fn| {
            const h = play_fn(self.backend.user_data, s, 1.0, 0.0, is_loop);
            return @floatFromInt(h);
        }

        // Headless default fallback
        const h = self.headless_handle_counter;
        self.headless_handle_counter +%= 1;
        if (self.headless_handle_counter < AUDIO_HANDLE_BASE) {
            self.headless_handle_counter = AUDIO_HANDLE_BASE;
        }
        return @floatFromInt(h);
    }

    pub fn stopSound(self: *AudioManager, id: f32) void {
        const h: i32 = @intFromFloat(id);
        if (self.backend.stop_sound_fn) |stop_fn| {
            stop_fn(self.backend.user_data, h);
        }
    }

    pub fn stopAll(self: *AudioManager) void {
        if (self.backend.stop_all_sounds_fn) |stop_all_fn| {
            stop_all_fn(self.backend.user_data);
        }
    }

    pub fn isPlaying(self: *AudioManager, id: f32) bool {
        const h: i32 = @intFromFloat(id);
        if (self.backend.is_playing_fn) |is_playing_fn| {
            return is_playing_fn(self.backend.user_data, h);
        }
        return false;
    }

    pub fn soundGain(self: *AudioManager, id: f32, volume: f32, ms: f32) void {
        _ = ms;
        const h: i32 = @intFromFloat(id);
        const vol = @max(0.0, volume);
        if (self.backend.set_sound_volume_fn) |set_vol_fn| {
            set_vol_fn(self.backend.user_data, h, vol);
        }
    }

    pub fn masterGain(self: *AudioManager, volume: f32) void {
        const vol = @max(0.0, volume);
        if (self.backend.set_master_volume_fn) |set_master_fn| {
            set_master_fn(self.backend.user_data, vol);
        }
    }

    pub fn pauseAll(self: *AudioManager) void {
        if (self.backend.pause_all_fn) |pause_fn| {
            pause_fn(self.backend.user_data);
        }
    }

    pub fn resumeAll(self: *AudioManager) void {
        if (self.backend.resume_all_fn) |resume_fn| {
            resume_fn(self.backend.user_data);
        }
    }
};

test "Headless Audio playback, handle generation, and gain" {
    var am = AudioManager.get();
    am.reset();

    const h1 = am.playSound(1.0, 1.0, 0.0);
    const h2 = am.playSound(2.0, 1.0, 1.0);
    try std.testing.expect(h1 >= @as(f32, @floatFromInt(AUDIO_HANDLE_BASE)));
    try std.testing.expect(h2 > h1);

    try std.testing.expect(!am.isPlaying(h1));
    am.soundGain(h1, 0.5, 0.0);
    am.masterGain(0.8);
    am.pauseAll();
    am.resumeAll();
    am.stopSound(h1);
    am.stopAll();
}
