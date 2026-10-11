//! SDL2_mixer audio backend: `runtime.AudioInterface`. Port of the sp_audio
//! half of packaged_src/src/host/main_sdl2.c.
//!
//! Sounds load on first play from ASSETS/sounds/<name>. A channel's volume is
//! master gain x play gain x the sound's gain (audio_sound_gain on the sound
//! id) x the sound's default .yy volume. Ids >= AUDIO_HANDLE_BASE are
//! playing-instance handles, smaller ids are sound indices.

const std = @import("std");
const runtime = @import("runtime");
const assets = @import("assets");
const c = @import("sdl");

const log = std.log.scoped(.host);

const channels = 32;
const sound_count = assets.sounds.len;
const handle_base = runtime.AUDIO_HANDLE_BASE;

pub const Audio = struct {
    /// False: no device (muted or none could be opened); every call is a no-op.
    open: bool = false,
    assets_dir: []const u8 = "build/assets",
    chunks: [sound_count]?*c.Mix_Chunk = [_]?*c.Mix_Chunk{null} ** sound_count,
    chunk_tried: [sound_count]bool = [_]bool{false} ** sound_count,
    sound_gain: [sound_count]f32 = [_]f32{1.0} ** sound_count,
    ch_sound: [channels]i32 = [_]i32{-1} ** channels,
    ch_handle: [channels]i32 = [_]i32{0} ** channels,
    ch_gain: [channels]f32 = [_]f32{1.0} ** channels,
    master: f32 = 1.0,
    next_handle: i32 = 0,

    /// Opens the device unless `mute`; failing to open one is not an error.
    pub fn start(self: *Audio, mute: bool) void {
        if (mute) return;
        if (c.Mix_OpenAudio(44100, c.sp_audio_s16sys, 2, 1024) != 0) {
            log.warn("no audio ({s})", .{c.SDL_GetError()});
            return;
        }
        _ = c.Mix_AllocateChannels(channels);
        self.open = true;
    }

    pub fn stop(self: *Audio) void {
        if (!self.open) return;
        _ = c.Mix_HaltChannel(-1);
        for (&self.chunks) |*ch| {
            if (ch.*) |loaded| c.Mix_FreeChunk(loaded);
            ch.* = null;
        }
        c.Mix_CloseAudio();
        self.open = false;
    }

    pub fn interface(self: *Audio) runtime.AudioInterface {
        return .{
            .user_data = self,
            .play_sound_fn = play,
            .stop_sound_fn = stopSound,
            .stop_all_sounds_fn = stopAll,
            .set_sound_volume_fn = setVolume,
            .is_playing_fn = isPlaying,
            .pause_all_fn = pauseAll,
            .resume_all_fn = resumeAll,
            .set_master_volume_fn = setMaster,
        };
    }

    fn chunk(self: *Audio, sound: i32) ?*c.Mix_Chunk {
        if (!self.open or sound < 0 or sound >= sound_count) return null;
        const i: usize = @intCast(sound);
        if (!self.chunk_tried[i]) {
            self.chunk_tried[i] = true;
            var buf: [1024]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/sounds/{s}", .{ self.assets_dir, assets.sounds[i].name }) catch return null;
            self.chunks[i] = c.Mix_LoadWAV_RW(c.SDL_RWFromFile(path.ptr, "rb"), 1);
            if (self.chunks[i] == null) log.warn("sound {s}: {s}", .{ assets.sounds[i].name, c.SDL_GetError() });
        }
        return self.chunks[i];
    }

    fn applyVolume(self: *Audio, ch: usize) void {
        const s = self.ch_sound[ch];
        const sound: f32 = if (s >= 0) self.sound_gain[@intCast(s)] * assets.sounds[@intCast(s)].volume else 1.0;
        const v = std.math.clamp(self.master * self.ch_gain[ch] * sound, 0.0, 1.0);
        _ = c.Mix_Volume(@intCast(ch), @intFromFloat(@round(v * @as(f32, @floatFromInt(c.sp_mix_max_volume)))));
    }

    /// Channel `ch` plays sound / handle `id`.
    fn matches(self: *const Audio, ch: usize, id: i32) bool {
        return c.Mix_Playing(@intCast(ch)) != 0 and
            (if (id >= handle_base) self.ch_handle[ch] == id else self.ch_sound[ch] == id);
    }
};

fn self_(ud: ?*anyopaque) *Audio {
    return @ptrCast(@alignCast(ud.?));
}

fn play(ud: ?*anyopaque, sound: i32, volume: f32, pan: f32, loop: bool) i32 {
    _ = pan;
    const a = self_(ud);
    const ch_chunk = a.chunk(sound) orelse return -1;
    const ch = c.Mix_PlayChannelTimed(-1, ch_chunk, if (loop) -1 else 0, -1);
    if (ch < 0 or ch >= channels) return -1;
    const i: usize = @intCast(ch);
    a.ch_sound[i] = sound;
    a.ch_gain[i] = volume;
    a.ch_handle[i] = handle_base + a.next_handle;
    a.next_handle += 1;
    a.applyVolume(i);
    return a.ch_handle[i];
}

fn stopSound(ud: ?*anyopaque, id: i32) void {
    const a = self_(ud);
    if (!a.open) return;
    for (0..channels) |ch| {
        if (a.matches(ch, id)) _ = c.Mix_HaltChannel(@intCast(ch));
    }
}

fn stopAll(ud: ?*anyopaque) void {
    if (self_(ud).open) _ = c.Mix_HaltChannel(-1);
}

fn setVolume(ud: ?*anyopaque, id: i32, v: f32) void {
    const a = self_(ud);
    if (id >= 0 and id < sound_count) a.sound_gain[@intCast(id)] = v;
    if (!a.open) return;
    for (0..channels) |ch| {
        if (!a.matches(ch, id)) continue;
        if (id >= handle_base) a.ch_gain[ch] = v;
        a.applyVolume(ch);
    }
}

fn isPlaying(ud: ?*anyopaque, id: i32) bool {
    const a = self_(ud);
    if (!a.open) return false;
    for (0..channels) |ch| {
        if (a.matches(ch, id)) return true;
    }
    return false;
}

fn pauseAll(ud: ?*anyopaque) void {
    if (self_(ud).open) c.Mix_Pause(-1);
}

fn resumeAll(ud: ?*anyopaque) void {
    if (self_(ud).open) c.Mix_Resume(-1);
}

fn setMaster(ud: ?*anyopaque, v: f32) void {
    const a = self_(ud);
    a.master = v;
    if (!a.open) return;
    for (0..channels) |ch| a.applyVolume(ch);
}
