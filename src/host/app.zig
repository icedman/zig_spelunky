//! Platform-neutral game driver shared by every host (SDL2 desktop, web,
//! Playdate).
//!
//! The host owns the device and the loop. It
//!   1. implements `runtime.PlatformInterface` (video) and
//!      `runtime.AudioInterface` (sound); every entry is optional and a null
//!      entry is the headless behaviour. Text needs no host support: the
//!      game's sprite fonts are drawn by the runtime through `draw_image_fn`;
//!   2. calls `App.boot` once, then `App.frame` once per display frame from
//!      whatever drives it (a blocking loop, `emscripten_set_main_loop`, the
//!      Playdate update callback), pacing frames at `App.frameSeconds`;
//!   3. forwards input as GameMaker virtual keys (`keys.zig`) via `App.key`.
//!
//! Mirrors install_game / the main loop of packaged_src/src/host/main_sdl2.c.
//! The game state lives in the runtime's static pools; `App` holds no heap
//! memory, so hosts without an allocator (Playdate) can embed it as is.

const std = @import("std");
const runtime = @import("runtime");
const gml = @import("gml");
const game = @import("game");
const assets = @import("assets");

pub const keys = @import("keys.zig");

const k = game.constants;
const rt = gml.rt;
const log = std.log.scoped(.host);

/// Font ids the game expects (setLocale): 0 = sFont (16 px), 1 = sFontSmall.
pub const font_large: i32 = 0;
pub const font_small: i32 = 1;

pub const Backends = struct {
    video: runtime.PlatformInterface = .{},
    audio: runtime.AudioInterface = .{},
};

/// Holds `key` from host frame `frame` (1-based) for `hold` frames.
pub const Press = struct {
    frame: u64,
    key: i32,
    hold: u64 = 3,

    /// "FRAME:VK[:HOLD]" (the hosts' --press argument).
    pub fn parse(text: []const u8) error{InvalidPress}!Press {
        var it = std.mem.splitScalar(u8, text, ':');
        const frame = it.next() orelse return error.InvalidPress;
        const vk = it.next() orelse return error.InvalidPress;
        var p: Press = .{
            .frame = std.fmt.parseInt(u64, frame, 10) catch return error.InvalidPress,
            .key = std.fmt.parseInt(i32, vk, 10) catch return error.InvalidPress,
        };
        if (it.next()) |hold| p.hold = std.fmt.parseInt(u64, hold, 10) catch return error.InvalidPress;
        if (it.next() != null or p.hold == 0) return error.InvalidPress;
        return p;
    }
};

pub const Options = struct {
    /// The game's datafiles directory (working_directory).
    data_dir: []const u8 = "build/data",
    /// Scripted input (tests, headless runs).
    presses: []const Press = &.{},
    /// Debug: object spawned next to the player when 'O' is pressed.
    item_object: ?i32 = null,
};

pub const KeyEvent = enum { press, repeat, release };

pub const BootError = error{
    AssetsInstall,
    RoomRegistry,
    LoopInit,
    WorkingDirectory,
    StartGame,
};

pub const App = struct {
    options: Options,
    frames: u64 = 0,
    spawn_item: bool = false,
    ended: bool = false,

    /// install_game: installs the backends, a fresh runtime with the game's
    /// tables, the sprite fonts, and starts the first room.
    pub fn boot(backends: Backends, options: Options) BootError!App {
        runtime.DrawManager.get().setBackend(backends.video);
        runtime.AudioManager.get().setBackend(backends.audio);

        runtime.InstanceManager.get().reset();
        runtime.StringManager.get().reset();
        runtime.DsManager.get().reset();
        runtime.InputManager.get().reset();
        runtime.DrawManager.get().reset();
        rt.reset();
        rt.install(&game.game);
        if (!assets.install()) return error.AssetsInstall;
        runtime.collision.init();
        runtime.collision.indexDefaultRoots();
        runtime.RoomManager.get().setHooks(rt.roomHooks());
        if (!assets.installRooms()) return error.RoomRegistry;
        if (!runtime.LoopManager.get().init(rt.loopHooks())) return error.LoopInit;
        if (!runtime.FileManager.get().setWorkingDirectory(options.data_dir)) return error.WorkingDirectory;
        installFonts();
        rt.globalInit();
        if (!runtime.RoomManager.get().startGame()) return error.StartGame;
        return .{ .options = options };
    }

    /// Stops the sound and detaches the backends (the host frees its
    /// resources afterwards).
    pub fn shutdown(self: *App) void {
        _ = self;
        runtime.AudioManager.get().stopAll();
        runtime.DrawManager.get().setBackend(.{});
        runtime.AudioManager.get().setBackend(.{});
    }

    /// One display frame: scripted input, debug spawn, one game tick (which
    /// draws through the video backend and presents). Call after delivering
    /// the frame's input with `key`.
    pub fn frame(self: *App) runtime.LoopStatus {
        if (self.ended) return .ended;
        self.frames += 1;
        for (self.options.presses) |p| {
            if (p.frame == self.frames) {
                self.key(p.key, .press);
            } else if (p.frame + p.hold == self.frames) {
                self.key(p.key, .release);
            }
        }
        if (self.spawn_item) self.spawnItem();
        if (runtime.LoopManager.get().tick() == .ended) {
            log.info("game_end in room {s}", .{self.roomName()});
            self.ended = true;
            runtime.AudioManager.get().stopAll();
        }
        return if (self.ended) .ended else .running;
    }

    /// A key event in GameMaker virtual key codes (`keys.zig`).
    pub fn key(self: *App, vk: i32, event: KeyEvent) void {
        const input = runtime.InputManager.get();
        switch (event) {
            .press, .repeat => input.keyDown(vk),
            .release => input.keyUp(vk),
        }
        if (event == .press and vk == keys.vk_debug_item and self.options.item_object != null) {
            self.spawn_item = true;
        }
    }

    /// Target frame duration: 1 / room_speed (30 fps when unset).
    pub fn frameSeconds(self: *const App) f32 {
        _ = self;
        const speed = runtime.RoomManager.get().getSpeed();
        return 1.0 / (if (speed > 0.0) speed else 30.0);
    }

    pub fn roomName(self: *const App) []const u8 {
        _ = self;
        const rm = runtime.RoomManager.get();
        return rm.getName(rm.current());
    }

    pub fn instanceCount(self: *const App) usize {
        _ = self;
        return runtime.InstanceManager.get().totalCount();
    }

    /// Spawns the --item object 40 px right of the first player instance.
    fn spawnItem(self: *App) void {
        self.spawn_item = false;
        const obj = self.options.item_object orelse return;
        const instances = runtime.InstanceManager.get();
        const player = instances.find(k.OBJ_oPlayer1, 0, null, null) orelse {
            log.warn("--item: no player in this room", .{});
            return;
        };
        _ = instances.createDepth(player.x + 40, player.y, runtime.ObjectRegistry.get().getDepth(obj), obj);
    }
};

/// Sprite fonts in the order the game expects (font_large, font_small);
/// draw_text without a font uses the small one, as the C hosts did.
fn installFonts() void {
    const dm = runtime.DrawManager.get();
    if (dm.fontAddSprite(.{ .sprite = k.SPR_sFont }) != font_large or
        dm.fontAddSprite(.{ .sprite = k.SPR_sFontSmall }) != font_small)
    {
        log.err("sprite fonts did not get ids 0 and 1", .{});
    }
    dm.setDefaultFont(font_small);
}

/// Object index by name (host debug options), null if unknown.
pub fn objectByName(name: []const u8) ?i32 {
    const reg = runtime.ObjectRegistry.get();
    for (0..reg.countObjects()) |i| {
        const def = reg.getDef(@intCast(i)) orelse continue;
        if (std.mem.eql(u8, def.name, name)) return @intCast(i);
    }
    return null;
}

pub const Rect = struct { x: f32, y: f32, w: f32, h: f32 };

/// The application surface scaled to fit `dst` and centred (letterboxed).
pub fn letterbox(src_w: i32, src_h: i32, dst_w: i32, dst_h: i32) Rect {
    const sw: f32 = @floatFromInt(@max(src_w, 1));
    const sh: f32 = @floatFromInt(@max(src_h, 1));
    const dw: f32 = @floatFromInt(dst_w);
    const dh: f32 = @floatFromInt(dst_h);
    const scale = @min(dw / sw, dh / sh);
    return .{ .x = (dw - sw * scale) / 2.0, .y = (dh - sh * scale) / 2.0, .w = sw * scale, .h = sh * scale };
}

// ---- tests --------------------------------------------------------------------

test "Press.parse" {
    try std.testing.expectEqual(Press{ .frame = 10, .key = 90, .hold = 3 }, try Press.parse("10:90"));
    try std.testing.expectEqual(Press{ .frame = 1, .key = 13, .hold = 40 }, try Press.parse("1:13:40"));
    for ([_][]const u8{ "", "5", "a:1", "1:2:0", "1:2:3:4", "1:" }) |bad| {
        try std.testing.expectError(error.InvalidPress, Press.parse(bad));
    }
}

test "letterbox" {
    try std.testing.expectEqual(Rect{ .x = 0, .y = 0, .w = 960, .h = 540 }, letterbox(320, 180, 960, 540));
    // 320 x 240 on the Playdate's 400 x 240: pillarboxed.
    try std.testing.expectEqual(Rect{ .x = 40, .y = 0, .w = 320, .h = 240 }, letterbox(320, 240, 400, 240));
}

const Recorder = struct {
    var images: usize = 0;
    var presents: usize = 0;
    var app_w: i32 = 0;

    fn begin(_: ?*anyopaque, w: i32, _: i32) void {
        app_w = w;
    }
    fn present(_: ?*anyopaque) void {
        presents += 1;
    }
    fn image(_: ?*anyopaque, _: i32, _: i32, _: i32, _: i32, _: i32, _: i32, _: f32, _: f32, _: f32, _: f32, _: f32, _: f32, _: f32, _: u32, _: f32) void {
        images += 1;
    }
};

test "boot the real game headlessly and run its intro on a recording backend" {
    var app = try App.boot(.{ .video = .{
        .begin_frame_fn = Recorder.begin,
        .present_fn = Recorder.present,
        .draw_image_fn = Recorder.image,
    } }, .{ .presses = &.{.{ .frame = 2, .key = 'K' }} });
    defer app.shutdown();

    // Sprite fonts registered, text drawn by the runtime.
    const dm = runtime.DrawManager.get();
    try std.testing.expectEqual(@as(i32, k.SPR_sFont), dm.getFont(font_large).?.sprite.sprite);
    try std.testing.expectEqual(@as(i32, k.SPR_sFontSmall), dm.getFont(font_small).?.sprite.sprite);
    // A TTF font_add (non-English locales) falls back to the sprite fonts by size.
    try std.testing.expectEqual(@as(i32, k.SPR_sFont), dm.getFont(dm.fontAdd("locale/x.ttf", 24)).?.sprite.sprite);
    try std.testing.expectEqual(@as(i32, k.SPR_sFontSmall), dm.getFont(dm.fontAdd("locale/x.ttf", 12)).?.sprite.sprite);

    // Tick 1 runs rGameMakerIntro_room and rScreenInit; the intro follows.
    try std.testing.expectEqual(runtime.LoopStatus.running, app.frame());
    try std.testing.expectEqualStrings("rIntro", app.roomName());
    try std.testing.expect(!runtime.InputManager.get().check('K'));
    _ = app.frame();
    try std.testing.expect(runtime.InputManager.get().check('K'));
    for (0..60) |_| try std.testing.expectEqual(runtime.LoopStatus.running, app.frame());
    try std.testing.expect(!runtime.InputManager.get().check('K'));

    try std.testing.expectEqual(@as(u64, 62), app.frames);
    try std.testing.expect(Recorder.presents >= 62 and Recorder.app_w > 0);
    // oIntro draws its story text in the sprite font.
    try std.testing.expect(Recorder.images > 0);
    try std.testing.expect(app.frameSeconds() > 0.0);
    try std.testing.expect(objectByName("oPlayer1").? == k.OBJ_oPlayer1);
    try std.testing.expect(objectByName("oNope") == null);
}
