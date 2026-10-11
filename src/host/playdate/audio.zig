//! Playdate audio backend: `runtime.AudioInterface`. Port of the sp_audio
//! half of src/host/playdate/main_playdate.c.
//!
//! Effects are AudioSamples (assets/sounds/<name>.pda, loaded whole on first
//! play) on a fixed set of SamplePlayer voices; when all are busy the oldest
//! is stolen. Sounds without a sample are music, streamed one at a time from
//! assets/music/<name> by a FilePlayer. A voice's volume is master gain x
//! play gain x the sound's gain (audio_sound_gain) x its default volume.
//! Ids >= AUDIO_HANDLE_BASE are playing-instance handles, smaller ids are
//! sound indices.

const std = @import("std");
const runtime = @import("runtime");
const assets = @import("assets");
const pd_mod = @import("pd.zig");
const api = pd_mod.api;

const voice_count = 16;
const sound_count = assets.sounds.len;
const handle_base = runtime.AUDIO_HANDLE_BASE;

const Voice = struct {
    player: ?*api.SamplePlayer = null,
    sound: i32 = -1,
    handle: i32 = 0,
    gain: f32 = 1.0,
    paused: bool = false,
};

pub const Audio = struct {
    /// False: every call is a no-op (-Dplaydate-audio=false, or before start).
    enabled: bool = false,
    samples: [sound_count]?*api.AudioSample = @splat(null),
    sample_tried: [sound_count]bool = @splat(false),
    sound_gain: [sound_count]f32 = @splat(1.0),
    voices: [voice_count]Voice = @splat(.{}),
    next_voice: usize = 0,
    music: ?*api.FilePlayer = null,
    music_sound: i32 = -1,
    music_handle: i32 = 0,
    music_gain: f32 = 1.0,
    music_loop: bool = false,
    music_paused: bool = false,
    master: f32 = 1.0,
    next_handle: i32 = 0,

    pub fn start(self: *Audio) void {
        const sp = pd_mod.pd.sound.sampleplayer;
        for (&self.voices) |*v| v.* = .{ .player = sp.newPlayer() };
        self.enabled = true;
    }

    pub fn stop(self: *Audio) void {
        if (!self.enabled) return;
        stopAll(self);
        const snd = pd_mod.pd.sound;
        for (&self.samples) |*s| {
            if (s.*) |smp| snd.sample.freeSample(smp);
            s.* = null;
        }
        for (&self.voices) |*v| {
            if (v.player) |p| snd.sampleplayer.freePlayer(p);
            v.* = .{};
        }
        if (self.music) |m| snd.fileplayer.freePlayer(m);
        self.music = null;
        self.enabled = false;
    }

    pub fn interface(self: *Audio) runtime.AudioInterface {
        return .{
            .user_data = self,
            .play_sound_fn = play,
            .stop_sound_fn = stopSound,
            .stop_all_sounds_fn = stopAllFn,
            .set_sound_volume_fn = setVolume,
            .is_playing_fn = isPlaying,
            .pause_all_fn = pauseAllFn,
            .resume_all_fn = resumeAllFn,
            .set_master_volume_fn = setMaster,
        };
    }

    /// pdc compiles x.wav into x.pda; music has no sample (see playMusic).
    fn sample(self: *Audio, sound: usize) ?*api.AudioSample {
        if (!self.sample_tried[sound]) {
            self.sample_tried[sound] = true;
            const path = pd_mod.path("assets/sounds/{s}.pda", .{assets.sounds[sound].name}) orelse return null;
            var st: api.FileStat = undefined;
            if (pd_mod.pd.file.stat(path, &st) == 0) self.samples[sound] = pd_mod.pd.sound.sample.load(path);
        }
        return self.samples[sound];
    }

    fn volume(self: *const Audio, sound: i32, gain: f32) f32 {
        const s: f32 = if (sound >= 0) self.sound_gain[@intCast(sound)] * assets.sounds[@intCast(sound)].volume else 1.0;
        return std.math.clamp(self.master * gain * s, 0.0, 1.0);
    }

    fn applyVoice(self: *const Audio, v: *const Voice) void {
        const vol = self.volume(v.sound, v.gain);
        pd_mod.pd.sound.sampleplayer.setVolume(v.player, vol, vol);
    }

    fn applyMusic(self: *const Audio) void {
        const m = self.music orelse return;
        if (self.music_sound < 0) return;
        const vol = self.volume(self.music_sound, self.music_gain);
        pd_mod.pd.sound.fileplayer.setVolume(m, vol, vol);
    }

    fn musicPlaying(self: *const Audio) bool {
        const m = self.music orelse return false;
        return self.music_sound >= 0 and (self.music_paused or pd_mod.pd.sound.fileplayer.isPlaying(m) != 0);
    }

    /// Sounds without an effect sample stream from assets/music.
    fn playMusic(self: *Audio, sound: usize, gain: f32, loop: bool) i32 {
        const fp = pd_mod.pd.sound.fileplayer;
        const m = self.music orelse (fp.newPlayer() orelse return -1);
        self.music = m;
        fp.stop(m);
        const path = pd_mod.path("assets/music/{s}", .{assets.sounds[sound].name}) orelse return -1;
        if (fp.loadIntoPlayer(m, path) == 0) {
            pd_mod.log("host: sound {s}: not found", .{assets.sounds[sound].name});
            self.music_sound = -1;
            return -1;
        }
        self.music_sound = @intCast(sound);
        self.music_gain = gain;
        self.music_loop = loop;
        self.music_paused = false;
        self.music_handle = handle_base + self.next_handle;
        self.next_handle += 1;
        self.applyMusic();
        _ = fp.play(m, if (loop) 0 else 1);
        return self.music_handle;
    }

    /// The voice plays sound / handle `id` (or is paused on it).
    fn voiceMatches(v: *const Voice, id: i32) bool {
        const p = v.player orelse return false;
        return v.sound >= 0 and (v.paused or pd_mod.pd.sound.sampleplayer.isPlaying(p) != 0) and
            (if (id >= handle_base) v.handle == id else v.sound == id);
    }

    fn musicMatches(self: *const Audio, id: i32) bool {
        return self.musicPlaying() and (if (id >= handle_base) self.music_handle == id else self.music_sound == id);
    }

    fn stopAll(self: *Audio) void {
        const snd = pd_mod.pd.sound;
        for (&self.voices) |*v| {
            const p = v.player orelse continue;
            snd.sampleplayer.stop(p);
            v.paused = false;
            v.sound = -1;
        }
        if (self.music) |m| {
            snd.fileplayer.stop(m);
            self.music_paused = false;
            self.music_sound = -1;
        }
    }

    pub fn pauseAll(self: *Audio) void {
        if (!self.enabled) return;
        const snd = pd_mod.pd.sound;
        for (&self.voices) |*v| {
            const p = v.player orelse continue;
            if (!v.paused and snd.sampleplayer.isPlaying(p) != 0) {
                snd.sampleplayer.setPaused(p, 1);
                v.paused = true;
            }
        }
        if (self.music) |m| {
            if (!self.music_paused and self.music_sound >= 0 and snd.fileplayer.isPlaying(m) != 0) {
                snd.fileplayer.pause(m);
                self.music_paused = true;
            }
        }
    }

    pub fn resumeAll(self: *Audio) void {
        if (!self.enabled) return;
        const snd = pd_mod.pd.sound;
        for (&self.voices) |*v| {
            const p = v.player orelse continue;
            if (v.paused) {
                snd.sampleplayer.setPaused(p, 0);
                v.paused = false;
            }
        }
        if (self.music) |m| {
            if (self.music_paused) {
                _ = snd.fileplayer.play(m, if (self.music_loop) 0 else 1);
                self.music_paused = false;
            }
        }
    }
};

fn self_(ud: ?*anyopaque) *Audio {
    return @ptrCast(@alignCast(ud.?));
}

fn play(ud: ?*anyopaque, sound: i32, gain: f32, pan: f32, loop: bool) i32 {
    _ = pan;
    const a = self_(ud);
    if (!a.enabled or sound < 0 or sound >= sound_count) return -1;
    const smp = a.sample(@intCast(sound)) orelse return a.playMusic(@intCast(sound), gain, loop);
    const sp = pd_mod.pd.sound.sampleplayer;
    const free_voice = for (0..voice_count) |i| {
        const v = &a.voices[(a.next_voice + i) % voice_count];
        const p = v.player orelse continue;
        if (!v.paused and sp.isPlaying(p) == 0) break v;
    } else null;
    const v = free_voice orelse steal: {
        // All busy: steal the oldest.
        const v = &a.voices[a.next_voice];
        sp.stop(v.player orelse return -1);
        break :steal v;
    };
    const index = (@intFromPtr(v) - @intFromPtr(&a.voices[0])) / @sizeOf(Voice);
    a.next_voice = (index + 1) % voice_count;
    v.sound = sound;
    v.gain = gain;
    v.paused = false;
    v.handle = handle_base + a.next_handle;
    a.next_handle += 1;
    sp.setSample(v.player, smp);
    a.applyVoice(v);
    _ = sp.play(v.player, if (loop) 0 else 1, 1.0);
    return v.handle;
}

fn stopSound(ud: ?*anyopaque, id: i32) void {
    const a = self_(ud);
    if (!a.enabled) return;
    for (&a.voices) |*v| {
        if (!Audio.voiceMatches(v, id)) continue;
        pd_mod.pd.sound.sampleplayer.stop(v.player);
        v.paused = false;
        v.sound = -1;
    }
    if (a.musicMatches(id)) {
        pd_mod.pd.sound.fileplayer.stop(a.music);
        a.music_paused = false;
        a.music_sound = -1;
    }
}

fn stopAllFn(ud: ?*anyopaque) void {
    const a = self_(ud);
    if (a.enabled) a.stopAll();
}

fn setVolume(ud: ?*anyopaque, id: i32, gain: f32) void {
    const a = self_(ud);
    if (id >= 0 and id < sound_count) a.sound_gain[@intCast(id)] = gain;
    if (!a.enabled) return;
    for (&a.voices) |*v| {
        if (!Audio.voiceMatches(v, id)) continue;
        if (id >= handle_base) v.gain = gain;
        a.applyVoice(v);
    }
    if (a.musicMatches(id)) {
        if (id >= handle_base) a.music_gain = gain;
        a.applyMusic();
    }
}

fn isPlaying(ud: ?*anyopaque, id: i32) bool {
    const a = self_(ud);
    if (!a.enabled) return false;
    for (&a.voices) |*v| {
        if (Audio.voiceMatches(v, id)) return true;
    }
    return a.musicMatches(id);
}

fn pauseAllFn(ud: ?*anyopaque) void {
    self_(ud).pauseAll();
}

fn resumeAllFn(ud: ?*anyopaque) void {
    self_(ud).resumeAll();
}

fn setMaster(ud: ?*anyopaque, gain: f32) void {
    const a = self_(ud);
    a.master = gain;
    if (!a.enabled) return;
    for (&a.voices) |*v| {
        if (v.player != null and v.sound >= 0) a.applyVoice(v);
    }
    a.applyMusic();
}
