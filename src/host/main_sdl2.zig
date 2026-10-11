//! SDL2 host for the Spelunky Classic HD Zig port (desktop). Port of
//! packaged_src/src/host/main_sdl2.c on top of the platform-neutral `App`
//! (zig/host/app.zig); the SDL backends are in zig/host/sdl2/.
//!
//!   spelunky_sdl2 [--assets DIR] [--data DIR] [--frames N] [--screenshot FILE.bmp]
//!                 [--press FRAME:VK[:N]]... [--mute] [--item OBJECT]
//!
//!   --assets      build/assets (sprites/<name>/<i>.png, sounds/<name>)
//!   --data        the game's datafiles directory, used as working_directory
//!                 (both defaults come from build.zig's `sdl2_options`)
//!   --frames N    run N frames and quit (with --screenshot: save the last frame)
//!   --press F:VK[:N]  hold GameMaker key VK from frame F for N frames (default 3)
//!   --mute        no audio device (also used when none can be opened)
//!   --item OBJ    debug: pressing O (or --press F:79) spawns an instance of
//!                 object OBJ (e.g. oJar) next to the player
//!
//! Headless runs: SDL_VIDEODRIVER=offscreen (or dummy) with --frames.

const std = @import("std");
const runtime = @import("runtime");
const app_mod = @import("app");
const c = @import("sdl");
const sdl2_options = @import("sdl2_options");

const Video = @import("sdl2/video.zig").Video;
const Audio = @import("sdl2/audio.zig").Audio;
const input = @import("sdl2/input.zig");

const log = std.log.scoped(.host);

const usage = "usage: spelunky_sdl2 [--assets DIR] [--data DIR] [--frames N] [--screenshot FILE.bmp] " ++
    "[--press FRAME:VK[:N]]... [--mute] [--item OBJECT]\n";
const press_max = 64;

const Args = struct {
    assets: []const u8 = sdl2_options.assets_dir,
    data: []const u8 = sdl2_options.data_dir,
    frames: ?u64 = null,
    screenshot: ?[:0]const u8 = null,
    presses: [press_max]app_mod.Press = undefined,
    press_count: usize = 0,
    mute: bool = false,
    item: ?[]const u8 = null,

    fn parse(it: *std.process.Args.Iterator) error{Usage}!Args {
        var a: Args = .{};
        _ = it.next();
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "--mute")) {
                a.mute = true;
                continue;
            }
            const val = it.next() orelse return error.Usage;
            if (std.mem.eql(u8, arg, "--assets")) {
                a.assets = val;
            } else if (std.mem.eql(u8, arg, "--data")) {
                a.data = val;
            } else if (std.mem.eql(u8, arg, "--frames")) {
                a.frames = std.fmt.parseInt(u64, val, 10) catch return error.Usage;
            } else if (std.mem.eql(u8, arg, "--screenshot")) {
                a.screenshot = val;
            } else if (std.mem.eql(u8, arg, "--press")) {
                if (a.press_count == press_max) return error.Usage;
                a.presses[a.press_count] = app_mod.Press.parse(val) catch return error.Usage;
                a.press_count += 1;
            } else if (std.mem.eql(u8, arg, "--item")) {
                a.item = val;
            } else return error.Usage;
        }
        return a;
    }
};

// Large (sprite texture table); static like the runtime's pools.
var video: Video = .{};
var audio: Audio = .{};

pub fn main(init: std.process.Init) !u8 {
    var out_buf: [512]u8 = undefined;
    var out: std.Io.File.Writer = .init(.stdout(), init.io, &out_buf);
    const stdout = &out.interface;

    var it = init.minimal.args.iterate();
    const args = Args.parse(&it) catch {
        std.debug.print(usage, .{});
        return 2;
    };

    if (c.SDL_Init(c.SDL_INIT_VIDEO | c.SDL_INIT_AUDIO | c.SDL_INIT_EVENTS) != 0) {
        log.err("SDL_Init: {s}", .{c.SDL_GetError()});
        return 1;
    }
    defer c.SDL_Quit();
    _ = c.IMG_Init(c.IMG_INIT_PNG);
    defer c.IMG_Quit();

    video.assets_dir = args.assets;
    video.arena = init.arena.allocator();
    video.screenshot = args.screenshot;
    video.open("Spelunky", 960, 540) catch {
        log.err("no renderer: {s}", .{c.SDL_GetError()});
        video.close();
        return 1;
    };
    defer video.close();
    audio.assets_dir = args.assets;
    audio.start(args.mute);
    defer audio.stop();

    var app = app_mod.App.boot(
        .{ .video = video.interface(), .audio = audio.interface() },
        .{ .data_dir = args.data, .presses = args.presses[0..args.press_count] },
    ) catch |err| {
        log.err("the game tables did not install: {t}", .{err});
        return 1;
    };
    defer app.shutdown();
    if (args.item) |name| {
        app.options.item_object = app_mod.objectByName(name) orelse {
            log.err("--item: unknown object '{s}'", .{name});
            return 2;
        };
        try stdout.print("host: press O to spawn {s}\n", .{name});
        try stdout.flush();
    }

    var frame: u64 = 1;
    while (args.frames == null or frame <= args.frames.?) : (frame += 1) {
        const start = c.SDL_GetPerformanceCounter();
        if (!input.pump(&app)) break;
        video.want_shot = args.screenshot != null and frame == args.frames;
        if (app.frame() == .ended) break;
        if (args.frames == null) {
            const used = @as(f32, @floatFromInt(c.SDL_GetPerformanceCounter() - start)) /
                @as(f32, @floatFromInt(c.SDL_GetPerformanceFrequency()));
            const budget = app.frameSeconds();
            if (used < budget) c.SDL_Delay(@intFromFloat((budget - used) * 1000.0));
        }
    }
    if (args.frames != null) {
        // gm_loop_frame_count: game steps (the first tick runs several).
        try stdout.print("host: {d} frames, room {s}, {d} instances\n", .{
            runtime.LoopManager.get().frameCount(), app.roomName(), app.instanceCount(),
        });
        try stdout.flush();
    }
    return 0;
}

test {
    _ = input;
}
