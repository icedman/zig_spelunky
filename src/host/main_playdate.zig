//! Playdate host for the Spelunky Classic HD Zig port: the root of pdex.so
//! (Simulator) and pdex.elf (device). Port of
//! src/host/playdate/main_playdate.c on top of the platform-neutral `App`
//! (zig/host/app.zig); the backends are in zig/host/playdate/.
//!
//! No libc: the runtime's file I/O goes to pd->file (playdate/stdio.zig) and
//! `randomize` seeds from the system clock. The update callback runs one
//! game tick per display frame at the room speed (setRefreshRate).
//!
//! The .pdx (`zig build playdate`) holds, besides pdex.*:
//!   assets/sprites/<name>/<i>   1-bit frame bitmaps (tools/playdate_assets.py)
//!   assets/sounds/<name>        sound effects, assets/music/<name> music
//!   data/                       the game's datafiles = working_directory

const std = @import("std");
const builtin = @import("builtin");
const runtime = @import("runtime");
const app_mod = @import("app");
const options = @import("playdate_options");

const pd_mod = @import("playdate/pd.zig");
const api = pd_mod.api;
const Video = @import("playdate/video.zig").Video;
const Audio = @import("playdate/audio.zig").Audio;
const Input = @import("playdate/input.zig").Input;
const stdio = @import("playdate/stdio.zig");

pub const panic = std.debug.FullPanic(panicHandler);

pub const std_options: std.Options = .{
    .logFn = logToConsole,
    // ReleaseSmall logs errors only; the profiler reports at info.
    .log_scope_levels = &.{.{ .scope = .profile, .level = .info }},
    .allow_stack_tracing = false,
    .enable_segfault_handler = false,
};

// Large (sprite and sound tables); static like the runtime's pools.
var video: Video = .{};
var audio: Audio = .{};
var input: Input = .{};
var app: app_mod.App = undefined;
var ready = false;
var refresh: f32 = 0.0;

/// Reads find data/ in the save folder first, then in the .pdx; writes go
/// to the save folder.
const data_dir = "data";

pub export fn eventHandler(playdate: *api.PlaydateAPI, event: api.PDSystemEvent, arg: u32) callconv(.c) c_int {
    _ = arg;
    switch (event) {
        .EventInit => init(playdate),
        .EventPause, .EventLock => if (ready) audio.pauseAll(),
        .EventResume, .EventUnlock => if (ready) audio.resumeAll(),
        .EventTerminate => if (ready) {
            app.shutdown();
            audio.stop();
            video.deinit();
            ready = false;
        },
        else => {},
    }
    return 0;
}

fn init(playdate: *api.PlaydateAPI) void {
    pd_mod.pd = playdate;
    runtime.file.stdio = stdio.stdio;
    runtime.math.clock_seed_source = clockSeed;

    video.display_scale = options.display_scale;
    video.show_fps = options.show_fps;
    if (options.profile_frames > 0) {
        runtime.profile.clock = pickProfileClock();
    }
    video.init();
    if (options.audio) audio.start();

    _ = playdate.file.mkdir(data_dir);
    app = app_mod.App.boot(
        .{ .video = video.interface(), .audio = audio.interface() },
        .{ .data_dir = data_dir },
    ) catch |err| {
        playdate.system.@"error"("host: the game tables did not install: %s", @errorName(err).ptr);
        return;
    };
    input.addMenuItems();
    // The screen is the frame buffer and each frame starts with a clear, so
    // screen draws from step events (oScreen's full-screen blit) never show.
    runtime.DrawManager.get().skip_unseen = true;
    pd_mod.log("host: booted ({d} instances max), room {s}", .{ runtime.instance.MAX_INSTANCES, app.roomName() });
    ready = true;

    playdate.display.setRefreshRate(60.0);
    playdate.system.setUpdateCallback(update, null);
}

fn update(_: ?*anyopaque) callconv(.c) c_int {
    if (!ready or app.ended) return 0;
    // const speed = 1.0 / app.frameSeconds();
    // if (speed != refresh) {
    //     pd_mod.pd.display.setRefreshRate(speed);
    //     refresh = speed;
    // }
    const t = runtime.profile.start();
    input.pump(&app);
    if (app.frame() == .ended) pd_mod.log("host: game_end, room {s}", .{app.roomName()});
    runtime.profile.stop(.host_frame, t);
    if (options.profile_frames > 0) {
        runtime.profile.frameDone(runtime.InstanceManager.get().activeCount(), options.profile_frames);
    }
    return 1;
}

/// Clock for runtime.profile: getElapsedTime (microseconds) if it advances
/// while code runs, else the millisecond clock (phase times then average
/// out over the report window rather than being exact per frame).
fn pickProfileClock() *const fn () u32 {
    const sys = pd_mod.pd.system;
    sys.resetElapsedTime();
    const e0 = sys.getElapsedTime();
    const m0 = sys.getCurrentTimeMilliseconds();
    // Busy-wait ~3 ms of wall time (bounded, should the ms clock stall too).
    var spins: u32 = 0;
    while (sys.getCurrentTimeMilliseconds() -% m0 < 3 and spins < 1_000_000) : (spins += 1) {
        std.mem.doNotOptimizeAway(spins);
    }
    const e1 = sys.getElapsedTime();
    const ms = sys.getCurrentTimeMilliseconds() -% m0;
    const live = e1 > e0;
    // Integers only: float formatting needs more stack than the game task has.
    pd_mod.log("profile: getElapsedTime {d} -> {d} us over {d} ms ({d} spins): using {s}", .{
        usFromSecs(e0), usFromSecs(e1), ms, spins, if (live) "getElapsedTime (us)" else "getCurrentTimeMilliseconds (ms)",
    });
    if (live) {
        sys.resetElapsedTime();
        return profileClockElapsed;
    }
    return profileClockMs;
}

/// Seconds -> microseconds, saturating (NaN and negatives give 0).
fn usFromSecs(secs: f32) u32 {
    if (!(secs > 0.0)) return 0;
    if (secs >= 4294.0) return std.math.maxInt(u32);
    return @intFromFloat(secs * 1_000_000.0);
}

fn profileClockMs() u32 {
    return pd_mod.pd.system.getCurrentTimeMilliseconds() *% 1000;
}

/// getElapsedTime is a float: rebase it every 60 s so it keeps microsecond
/// precision.
fn profileClockElapsed() u32 {
    const S = struct {
        var base: u32 = 0;
    };
    const sys = pd_mod.pd.system;
    var secs = sys.getElapsedTime();
    if (secs >= 60.0) {
        S.base +%= usFromSecs(secs);
        sys.resetElapsedTime();
        secs = 0.0;
    }
    return S.base +% usFromSecs(secs);
}

/// time(NULL) ^ clock() of the C port: seconds since the epoch and the
/// milliseconds the game has been running.
fn clockSeed() u32 {
    const sys = pd_mod.pd.system;
    return sys.getSecondsSinceEpoch(null) ^ sys.getCurrentTimeMilliseconds();
}

fn logToConsole(
    comptime level: std.log.Level,
    comptime scope: @EnumLiteral(),
    comptime format: []const u8,
    args: anytype,
) void {
    const prefix = if (scope == .default) "" else @tagName(scope) ++ ": ";
    pd_mod.log(level.asText() ++ ": " ++ prefix ++ format, args);
}

/// Shown by the Simulator / device as a crash with the message.
fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    _ = first_trace_addr;
    var buf: [256]u8 = undefined;
    const n = @min(msg.len, buf.len - 1);
    @memcpy(buf[0..n], msg[0..n]);
    buf[n] = 0;
    pd_mod.pd.system.@"error"("PANIC: %s", @as([*:0]const u8, @ptrCast(&buf)));
    while (true) {}
}

test {
    _ = @import("playdate/video.zig");
    _ = @import("playdate/input.zig");
}
