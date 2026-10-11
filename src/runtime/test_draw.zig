//! C comparison tests for DrawManager and AudioManager matching tests/test_draw.c.
//! Validates transforms, sprites, text, shapes, surfaces, layers, window metrics,
//! and audio playback against a recording mock platform.

const std = @import("std");
const platform_mod = @import("platform.zig");
const PlatformInterface = platform_mod.PlatformInterface;
const AudioInterface = platform_mod.AudioInterface;

const sprite_mod = @import("sprite.zig");
const SpriteDef = sprite_mod.SpriteDef;
const SpriteRegistry = sprite_mod.SpriteRegistry;
const MAX_SPRITES = sprite_mod.MAX_SPRITES;

const object_mod = @import("object.zig");
const ObjectDef = object_mod.ObjectDef;
const ObjectRegistry = object_mod.ObjectRegistry;
const OBJECT_NONE = object_mod.OBJECT_NONE;

const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;

const layer_mod = @import("layer.zig");
const LayerManager = layer_mod.LayerManager;
const LAYER_ASSETS = layer_mod.LAYER_ASSETS;
const LAYER_BACKGROUND = layer_mod.LAYER_BACKGROUND;

const view_mod = @import("view.zig");
const ViewManager = view_mod.ViewManager;

const room_mod = @import("room.zig");
const RoomDef = room_mod.RoomDef;
const RoomViewDef = room_mod.RoomViewDef;
const RoomLayerDef = room_mod.RoomLayerDef;
const RoomTileDef = room_mod.RoomTileDef;
const RoomManager = room_mod.RoomManager;

const draw_mod = @import("draw.zig");
const DrawManager = draw_mod.DrawManager;
const APP_SURFACE = draw_mod.APP_SURFACE;

const audio_mod = @import("audio.zig");
const AudioManager = audio_mod.AudioManager;
const AUDIO_HANDLE_BASE = audio_mod.AUDIO_HANDLE_BASE;

// ---- Recording Mock Platform ----

const Call = struct {
    kind: u8 = 0, // 'I' image, 'R' rect, 'C' circle, 'T' text, 'S' surface draw, 'K' clear, 'G' target, 'F' free
    a: i32 = 0,
    b: i32 = 0,
    sx: i32 = 0,
    sy: i32 = 0,
    sw: i32 = 0,
    sh: i32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    xo: f32 = 0.0,
    yo: f32 = 0.0,
    xs: f32 = 0.0,
    ys: f32 = 0.0,
    angle: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    alpha: f32 = 0.0,
    colour: u32 = 0,
    outline: bool = false,
    text: [32]u8 = [_]u8{0} ** 32,
};

const CALLS_MAX: usize = 512;

const MockPlatformState = struct {
    calls: [CALLS_MAX]Call = [_]Call{.{}} ** CALLS_MAX,
    ncalls: usize = 0,
    app_w: i32 = 0,
    app_h: i32 = 0,
    presents: usize = 0,
    next_surface: i32 = 0,
    win_w: i32 = 800,
    win_h: i32 = 450,
    fullscreen: bool = false,

    fn reset(self: *MockPlatformState) void {
        self.ncalls = 0;
        self.app_w = 0;
        self.app_h = 0;
        self.presents = 0;
        self.next_surface = 0;
        self.win_w = 800;
        self.win_h = 450;
        self.fullscreen = false;
        @memset(&self.calls, Call{});
    }

    fn rec(self: *MockPlatformState, kind: u8) *Call {
        const idx = if (self.ncalls < CALLS_MAX) self.ncalls else CALLS_MAX - 1;
        self.ncalls += 1;
        self.calls[idx] = .{ .kind = kind };
        return &self.calls[idx];
    }

    fn countKind(self: *const MockPlatformState, kind: u8) usize {
        var n: usize = 0;
        const total = @min(self.ncalls, CALLS_MAX);
        for (0..total) |i| {
            if (self.calls[i].kind == kind) n += 1;
        }
        return n;
    }
};

var mock_state: MockPlatformState = .{};

fn m_begin(ud: ?*anyopaque, w: i32, h: i32) void {
    _ = ud;
    mock_state.app_w = w;
    mock_state.app_h = h;
}

fn m_present(ud: ?*anyopaque) void {
    _ = ud;
    mock_state.presents += 1;
}

fn m_clear(ud: ?*anyopaque, c: u32, a: f32) void {
    _ = ud;
    const k = mock_state.rec('K');
    k.colour = c;
    k.alpha = a;
}

fn m_sprite_load(ud: ?*anyopaque, sprite: i32, path: [*:0]const u8, frames: i32, w: *i32, h: *i32) bool {
    _ = ud;
    _ = sprite;
    _ = frames;
    const path_slice = std.mem.span(path);
    if (std.mem.indexOf(u8, path_slice, "missing") != null) {
        return false;
    }
    w.* = 40;
    h.* = 20;
    return true;
}

fn m_image(
    ud: ?*anyopaque,
    sprite: i32,
    frame: i32,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
    x: f32,
    y: f32,
    xo: f32,
    yo: f32,
    xs: f32,
    ys: f32,
    angle: f32,
    c: u32,
    a: f32,
) void {
    _ = ud;
    const k = mock_state.rec('I');
    k.a = sprite;
    k.b = frame;
    k.sx = sx;
    k.sy = sy;
    k.sw = sw;
    k.sh = sh;
    k.x = x;
    k.y = y;
    k.xo = xo;
    k.yo = yo;
    k.xs = xs;
    k.ys = ys;
    k.angle = angle;
    k.colour = c;
    k.alpha = a;
}

fn m_rect(ud: ?*anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, c: u32, a: f32, o: bool) void {
    _ = ud;
    const k = mock_state.rec('R');
    k.x = x1;
    k.y = y1;
    k.w = x2;
    k.h = y2;
    k.colour = c;
    k.alpha = a;
    k.outline = o;
}

fn m_circle(ud: ?*anyopaque, x: f32, y: f32, r: f32, c: u32, a: f32, o: bool) void {
    _ = ud;
    const k = mock_state.rec('C');
    k.x = x;
    k.y = y;
    k.w = r;
    k.colour = c;
    k.alpha = a;
    k.outline = o;
}

fn m_font_load(ud: ?*anyopaque, path: [*:0]const u8, size: i32) i32 {
    _ = ud;
    _ = size;
    const path_slice = std.mem.span(path);
    return if (std.mem.indexOf(u8, path_slice, "missing") != null) 0 else 7;
}

fn m_text(ud: ?*anyopaque, font: i32, t: [*:0]const u8, x: f32, y: f32, scale: f32, c: u32, a: f32) void {
    _ = ud;
    const k = mock_state.rec('T');
    k.a = font;
    k.x = x;
    k.y = y;
    k.xs = scale;
    k.colour = c;
    k.alpha = a;
    const s = std.mem.span(t);
    const copy_len = @min(s.len, k.text.len - 1);
    @memcpy(k.text[0..copy_len], s[0..copy_len]);
    k.text[copy_len] = 0;
}

fn m_surface_create(ud: ?*anyopaque, w: i32, h: i32) i32 {
    _ = ud;
    _ = w;
    _ = h;
    mock_state.next_surface += 1;
    return mock_state.next_surface + 100;
}

fn m_surface_free(ud: ?*anyopaque, s: i32) void {
    _ = ud;
    const k = mock_state.rec('F');
    k.a = s;
}

fn m_surface_target(ud: ?*anyopaque, s: i32) void {
    _ = ud;
    const k = mock_state.rec('G');
    k.a = s;
}

fn m_draw_surface(ud: ?*anyopaque, s: i32, x: f32, y: f32, w: f32, h: f32, a: f32) void {
    _ = ud;
    const k = mock_state.rec('S');
    k.a = s;
    k.x = x;
    k.y = y;
    k.w = w;
    k.h = h;
    k.alpha = a;
}

fn m_window(ud: ?*anyopaque, w: *i32, h: *i32) void {
    _ = ud;
    w.* = mock_state.win_w;
    h.* = mock_state.win_h;
}

fn m_display(ud: ?*anyopaque, w: *i32, h: *i32) void {
    _ = ud;
    w.* = 1920;
    h.* = 1080;
}

fn m_set_window(ud: ?*anyopaque, w: i32, h: i32) void {
    _ = ud;
    mock_state.win_w = w;
    mock_state.win_h = h;
}

fn m_fullscreen(ud: ?*anyopaque, f: bool) void {
    _ = ud;
    mock_state.fullscreen = f;
}

// ---- Setup helper ----

var s_sprites: [2]SpriteDef = undefined;
var s_objs: [1]ObjectDef = undefined;

fn setup() void {
    mock_state.reset();

    const mock_platform = PlatformInterface{
        .user_data = null,
        .begin_frame_fn = m_begin,
        .present_fn = m_present,
        .clear_fn = m_clear,
        .sprite_load_fn = m_sprite_load,
        .draw_image_fn = m_image,
        .draw_rect_fn = m_rect,
        .draw_circle_fn = m_circle,
        .font_load_fn = m_font_load,
        .draw_text_fn = m_text,
        .surface_create_fn = m_surface_create,
        .surface_free_fn = m_surface_free,
        .surface_target_fn = m_surface_target,
        .draw_surface_fn = m_draw_surface,
        .window_size_fn = m_window,
        .display_size_fn = m_display,
        .set_window_size_fn = m_set_window,
        .set_fullscreen_fn = m_fullscreen,
    };
    DrawManager.get().setBackend(mock_platform);

    s_sprites[0] = .{
        .name = "sBox",
        .width = 16,
        .height = 16,
        .xorigin = 8,
        .yorigin = 8,
        .bbox_left = 0,
        .bbox_top = 0,
        .bbox_right = 15,
        .bbox_bottom = 15,
        .frame_count = 4,
    };
    s_sprites[1] = .{
        .name = "bTile",
        .width = 32,
        .height = 32,
        .xorigin = 0,
        .yorigin = 0,
        .bbox_left = 0,
        .bbox_top = 0,
        .bbox_right = 31,
        .bbox_bottom = 31,
        .frame_count = 1,
    };
    _ = SpriteRegistry.get().initRegistry(&s_sprites);

    s_objs[0] = .{
        .name = "o",
        .parent_index = OBJECT_NONE,
        .default_sprite = 0,
        .default_mask = -1,
        .default_visible = true,
    };
    _ = ObjectRegistry.get().initRegistry(&s_objs);

    InstanceManager.get().reset();
    _ = RoomManager.get().registryInit(null, null);
    ViewManager.get().reset();
    LayerManager.get().reset();
    DrawManager.get().reset();
}

fn teardown() void {
    DrawManager.get().setBackend(.{});
}

// ---- Unit Tests ----

test "C Parity: test_frame_and_app_surface" {
    setup();
    defer teardown();

    const dm = DrawManager.get();
    dm.beginFrame(); // no room, no views: 640 x 480 default room size
    try std.testing.expectEqual(@as(i32, 640), mock_state.app_w);
    try std.testing.expectEqual(@as(i32, 480), mock_state.app_h);
    try std.testing.expectEqual(@as(usize, 1), mock_state.countKind('K'));
    try std.testing.expectEqual(@as(u32, 0), mock_state.calls[0].colour);
    try std.testing.expectEqual(@as(f32, 1.0), mock_state.calls[0].alpha);

    dm.surfaceResize(APP_SURFACE, 427, 240); // oScreen
    dm.endFrame();
    dm.beginFrame();
    try std.testing.expectEqual(@as(i32, 427), mock_state.app_w);
    try std.testing.expectEqual(@as(i32, 240), mock_state.app_h);
    try std.testing.expectEqual(@as(usize, 1), mock_state.presents);
    try std.testing.expectEqual(@as(i32, 427), dm.appWidth());
    try std.testing.expect(dm.surfaceExists(APP_SURFACE));
}

test "C Parity: test_sprites_and_alpha" {
    setup();
    defer teardown();

    const dm = DrawManager.get();
    dm.beginFrame();
    dm.passRoom();
    mock_state.ncalls = 0;
    dm.setAlpha(0.5);
    dm.drawSprite(0, 5.7, 100, 50); // frame floor(5.7) mod 4 = 1, draw alpha
    try std.testing.expectEqual(@as(u8, 'I'), mock_state.calls[0].kind);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[0].a);
    try std.testing.expectEqual(@as(i32, 1), mock_state.calls[0].b);
    try std.testing.expectEqual(@as(f32, 100), mock_state.calls[0].x);
    try std.testing.expectEqual(@as(f32, 50), mock_state.calls[0].y);
    try std.testing.expectEqual(@as(f32, 8), mock_state.calls[0].xo);
    try std.testing.expectEqual(@as(i32, 16), mock_state.calls[0].sw);
    try std.testing.expectEqual(@as(f32, 0.5), mock_state.calls[0].alpha);
    try std.testing.expectEqual(@as(u32, 0x00FFFFFF), mock_state.calls[0].colour);

    dm.drawSprite(0, -1.0, 0, 0); // negative wraps: 3
    try std.testing.expectEqual(@as(i32, 3), mock_state.calls[1].b);

    dm.drawSpriteExt(0, 0, 10, 20, -2, 1, 90, 255.0, 3.0); // alpha capped at 1
    try std.testing.expectEqual(@as(f32, -2), mock_state.calls[2].xs);
    try std.testing.expectEqual(@as(f32, 90), mock_state.calls[2].angle);
    try std.testing.expectEqual(@as(u32, 0xFF), mock_state.calls[2].colour);
    try std.testing.expectEqual(@as(f32, 1.0), mock_state.calls[2].alpha);

    dm.drawSpriteStretched(0, 0, 0, 0, 64, 32); // origin ignored
    try std.testing.expectEqual(@as(f32, 4), mock_state.calls[3].xs);
    try std.testing.expectEqual(@as(f32, 2), mock_state.calls[3].ys);
    try std.testing.expectEqual(@as(f32, 0), mock_state.calls[3].xo);
    try std.testing.expectEqual(@as(f32, 0.5), mock_state.calls[3].alpha);

    dm.drawSprite(9, 0, 0, 0); // no such sprite: nothing
    try std.testing.expectEqual(@as(usize, 4), mock_state.ncalls);

    const inst = InstanceManager.get().create(0, 30.0, 40.0);
    try std.testing.expect(inst != null);
    inst.?.image_index = 2;
    inst.?.image_alpha = 0.25;
    inst.?.image_xscale = -1;
    dm.drawSelf(inst);
    try std.testing.expectEqual(@as(i32, 2), mock_state.calls[4].b);
    try std.testing.expectEqual(@as(f32, 30), mock_state.calls[4].x);
    try std.testing.expectEqual(@as(f32, 0.25), mock_state.calls[4].alpha);
    try std.testing.expectEqual(@as(f32, -1), mock_state.calls[4].xs);

    dm.setAlpha(7);
    try std.testing.expectEqual(@as(f32, 1.0), dm.getAlpha());
}

test "C Parity: test_view_and_gui_transforms" {
    setup();
    defer teardown();

    const view0 = RoomViewDef{
        .visible = true,
        .xview = 100,
        .yview = 50,
        .wview = 160,
        .hview = 120,
        .xport = 0,
        .yport = 0,
        .wport = 320,
        .hport = 240,
        .hborder = 32,
        .vborder = 32,
        .hspeed = -1,
        .vspeed = -1,
        .object = -1,
    };
    var views = [_]RoomViewDef{RoomViewDef{}} ** 8;
    views[0] = view0;

    const test_room = [_]RoomDef{
        .{
            .name = "r",
            .width = 1000,
            .height = 500,
            .speed = 30,
            .persistent = false,
            .enable_views = true,
            .views = views,
        },
    };
    const order = [_]i32{0};

    try std.testing.expect(RoomManager.get().registryInit(&test_room, &order));
    try std.testing.expect(RoomManager.get().start(0, true));

    const dm = DrawManager.get();
    dm.beginFrame();
    try std.testing.expectEqual(@as(i32, 320), mock_state.app_w); // view 0's port
    try std.testing.expectEqual(@as(i32, 240), mock_state.app_h);

    dm.passView(0);
    mock_state.ncalls = 0;
    dm.drawSprite(0, 0, 110, 60);
    try std.testing.expectEqual(@as(f32, 20), mock_state.calls[0].x);
    try std.testing.expectEqual(@as(f32, 20), mock_state.calls[0].y);
    try std.testing.expectEqual(@as(f32, 2), mock_state.calls[0].xs);
    try std.testing.expectEqual(@as(f32, 2), mock_state.calls[0].ys);

    dm.setColour(0x00FF00);
    dm.drawText(100, 50, "HI");
    try std.testing.expectEqual(@as(u8, 'T'), mock_state.calls[1].kind);
    try std.testing.expectEqual(@as(f32, 0), mock_state.calls[1].x);
    try std.testing.expectEqual(@as(f32, 2), mock_state.calls[1].xs);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[1].a);
    try std.testing.expectEqual(@as(u32, 0x00FF00), mock_state.calls[1].colour);

    dm.drawCircle(110, 60, 4, true);
    try std.testing.expectEqual(@as(u8, 'C'), mock_state.calls[2].kind);
    try std.testing.expectEqual(@as(f32, 8), mock_state.calls[2].w);
    try std.testing.expect(mock_state.calls[2].outline);

    dm.drawRectangle(100, 50, 110, 60, false);
    try std.testing.expectEqual(@as(u8, 'R'), mock_state.calls[3].kind);
    try std.testing.expectEqual(@as(f32, 0), mock_state.calls[3].x);
    try std.testing.expectEqual(@as(f32, 20), mock_state.calls[3].w);
    try std.testing.expect(!mock_state.calls[3].outline);

    // GUI: gui size 160 x 120 onto the 320 x 240 application surface.
    dm.displaySetGuiSize(160, 120);
    dm.passGui();
    dm.drawSprite(0, 0, 10, 10);
    try std.testing.expectEqual(@as(f32, 20), mock_state.calls[4].x);
    try std.testing.expectEqual(@as(f32, 2), mock_state.calls[4].xs);
}

test "C Parity: test_surfaces" {
    setup();
    defer teardown();

    const dm = DrawManager.get();
    dm.beginFrame();
    dm.passRoom();
    try std.testing.expect(!dm.surfaceExists(-1) and !dm.surfaceExists(5));

    const s = dm.surfaceCreate(64, 32);
    const t = dm.surfaceCreate(8, 8);
    try std.testing.expect(s >= 1 and t >= 1 and s != t and dm.surfaceExists(s));
    try std.testing.expectEqual(@as(i32, -1), dm.surfaceCreate(0, 5));

    mock_state.ncalls = 0;
    try std.testing.expect(dm.surfaceSetTarget(s));
    try std.testing.expectEqual(@as(u8, 'G'), mock_state.calls[0].kind);
    try std.testing.expectEqual(@as(i32, 101), mock_state.calls[0].a);

    dm.drawSurface(s, 0, 0); // never into itself
    dm.drawSurface(t, 3, 4);
    try std.testing.expectEqual(@as(u8, 'S'), mock_state.calls[1].kind);
    try std.testing.expectEqual(@as(i32, 102), mock_state.calls[1].a);
    try std.testing.expectEqual(@as(f32, 3), mock_state.calls[1].x);
    try std.testing.expectEqual(@as(f32, 8), mock_state.calls[1].w);

    try std.testing.expect(dm.surfaceResetTarget());
    try std.testing.expectEqual(@as(u8, 'G'), mock_state.calls[2].kind);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[2].a);
    try std.testing.expect(!dm.surfaceResetTarget());

    dm.drawSurfaceStretched(s, 0, 0, 128, 64);
    try std.testing.expectEqual(@as(f32, 128), mock_state.calls[3].w);
    try std.testing.expectEqual(@as(f32, 1.0), mock_state.calls[3].alpha);

    dm.surfaceResize(s, 16, 16); // recreated
    try std.testing.expectEqual(@as(u8, 'F'), mock_state.calls[4].kind);
    try std.testing.expectEqual(@as(i32, 101), mock_state.calls[4].a);

    dm.surfaceFree(s);
    try std.testing.expect(!dm.surfaceExists(s));

    dm.setAlpha(0.5);
    dm.drawClear(0x123456);
    try std.testing.expectEqual(@as(u8, 'K'), mock_state.calls[mock_state.ncalls - 1].kind);
    try std.testing.expectEqual(@as(f32, 1.0), mock_state.calls[mock_state.ncalls - 1].alpha);

    try std.testing.expect(dm.surfaceSetTarget(t));
    dm.endFrame(); // unbalanced targets are reset
    try std.testing.expectEqual(@as(u8, 'G'), mock_state.calls[mock_state.ncalls - 1].kind);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[mock_state.ncalls - 1].a);
}

test "C Parity: test_added_sprites_fonts_window" {
    setup();
    defer teardown();

    const dm = DrawManager.get();
    const spr = dm.spriteAdd("locale/en/images/start_sign.png", 2, 4, 6);
    try std.testing.expect(spr == @as(i32, @intCast(MAX_SPRITES)) and dm.spriteExists(spr));
    try std.testing.expectEqual(@as(i32, 40), dm.spriteWidth(spr));
    try std.testing.expectEqual(@as(i32, 20), dm.spriteHeight(spr));
    try std.testing.expectEqual(@as(i32, -1), dm.spriteAdd("missing.png", 1, 0, 0));
    try std.testing.expectEqual(@as(i32, 16), dm.spriteWidth(0));
    try std.testing.expectEqual(@as(i32, 0), dm.spriteWidth(-1));

    dm.beginFrame();
    dm.passRoom();
    mock_state.ncalls = 0;
    dm.drawSprite(spr, 3, 1, 2);
    try std.testing.expectEqual(@as(i32, spr), mock_state.calls[0].a);
    try std.testing.expectEqual(@as(i32, 1), mock_state.calls[0].b);
    try std.testing.expectEqual(@as(f32, 4), mock_state.calls[0].xo);
    try std.testing.expectEqual(@as(i32, 40), mock_state.calls[0].sw);

    const font = dm.fontAdd("fonts/a.ttf", 12);
    try std.testing.expect(font == 0 and dm.fontAdd("missing.ttf", 12) == -1);

    dm.setFont(font);
    dm.drawText(0, 0, "A\nB");
    try std.testing.expectEqual(@as(u8, 'T'), mock_state.calls[1].kind);
    try std.testing.expectEqual(@as(i32, 7), mock_state.calls[1].a);
    try std.testing.expect(std.mem.startsWith(u8, &mock_state.calls[1].text, "A\nB"));

    dm.setFont(-1);
    dm.drawText(0, 0, "C");
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[2].a); // default font

    dm.drawText(0, 0, "");
    try std.testing.expectEqual(@as(usize, 3), mock_state.ncalls);

    try std.testing.expectEqual(@as(i32, 800), dm.windowWidth());
    try std.testing.expectEqual(@as(i32, 1080), dm.displayHeight());

    dm.windowSetSize(640, 360);
    dm.windowSetSize(0, 5);
    try std.testing.expectEqual(@as(i32, 640), dm.windowWidth());
    try std.testing.expectEqual(@as(i32, 360), dm.windowHeight());

    dm.windowSetFullscreen(true);
    try std.testing.expect(mock_state.fullscreen);
}

test "C Parity: test_layers" {
    setup();
    defer teardown();

    const layers = [_]RoomLayerDef{
        .{ .name = "Tiles", .id = 1, .kind = LAYER_ASSETS, .depth = 100, .visible = true, .first_tile = 0, .tile_count = 2 },
        .{ .name = "Back", .id = 2, .kind = LAYER_BACKGROUND, .depth = 1000, .visible = true, .bg_sprite = 1, .bg_htiled = true, .bg_colour = 0xFF0000FF },
        .{ .name = "Colour", .id = 3, .kind = LAYER_BACKGROUND, .depth = 2000, .visible = true, .bg_sprite = -1, .bg_colour = 0x80102030 },
    };
    const tiles = [_]RoomTileDef{
        .{ .sprite = 1, .u = 16, .v = 0, .w = 16, .h = 16, .x = 32.0, .y = 48.0, .xscale = 1.0, .yscale = 1.0, .colour = 0xFFFFFFFF },
        .{ .sprite = 1, .u = 0, .v = 16, .w = 16, .h = 16, .x = 900.0, .y = 48.0, .xscale = 1.0, .yscale = 1.0, .colour = 0xFFFFFFFF }, // outside
    };
    const test_room = [_]RoomDef{
        .{
            .name = "r",
            .width = 100,
            .height = 80,
            .speed = 30,
            .persistent = false,
            .enable_views = false,
            .layer_count = 3,
            .layers = &layers,
            .tile_count = 2,
            .tiles = &tiles,
        },
    };
    const order = [_]i32{0};

    try std.testing.expect(RoomManager.get().registryInit(&test_room, &order));
    try std.testing.expect(RoomManager.get().start(0, true));

    const dm = DrawManager.get();
    dm.beginFrame();
    dm.passRoom();
    mock_state.ncalls = 0;

    const lm = LayerManager.get();
    var i: isize = @as(isize, @intCast(lm.count())) - 1;
    while (i >= 0) : (i -= 1) { // back to front
        dm.drawLayer(lm.at(@intCast(i)).?);
    }

    // Colour layer: one view-sized rect with the layer colour and alpha.
    try std.testing.expectEqual(@as(u8, 'R'), mock_state.calls[0].kind);
    try std.testing.expectEqual(@as(f32, 0), mock_state.calls[0].x);
    try std.testing.expectEqual(@as(f32, 100), mock_state.calls[0].w);
    try std.testing.expectEqual(@as(f32, 80), mock_state.calls[0].h);
    try std.testing.expectEqual(@as(u32, 0x102030), mock_state.calls[0].colour);
    try std.testing.expect(mock_state.calls[0].alpha > 0.50 and mock_state.calls[0].alpha < 0.51);

    // Back: 32 px wide, htiled across 100 px -> 4 copies on one row.
    try std.testing.expectEqual(@as(u8, 'I'), mock_state.calls[1].kind);
    try std.testing.expectEqual(@as(u8, 'I'), mock_state.calls[4].kind);
    try std.testing.expectEqual(@as(u8, 'I'), mock_state.calls[5].kind);
    try std.testing.expectEqual(@as(f32, 0), mock_state.calls[1].x);
    try std.testing.expectEqual(@as(f32, 96), mock_state.calls[4].x);
    try std.testing.expectEqual(@as(u32, 0xFF), mock_state.calls[1].colour);

    // Tiles: the visible one only, region (16, 0, 16, 16).
    try std.testing.expectEqual(@as(i32, 16), mock_state.calls[5].sx);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[5].sy);
    try std.testing.expectEqual(@as(f32, 32), mock_state.calls[5].x);
    try std.testing.expectEqual(@as(f32, 48), mock_state.calls[5].y);
    try std.testing.expectEqual(@as(usize, 6), mock_state.ncalls);
}

// ---- Audio Test ----

var s_last_sound: i32 = 0;
var s_stopped: i32 = 0;
var s_paused: i32 = 0;
var s_last_loop: bool = false;
var s_gain: f32 = 0.0;
var s_master: f32 = 0.0;

fn ma_play(ud: ?*anyopaque, s: i32, v: f32, p: f32, loop: bool) i32 {
    _ = ud;
    _ = v;
    _ = p;
    s_last_sound = s;
    s_last_loop = loop;
    return AUDIO_HANDLE_BASE + 1;
}

fn ma_stop(ud: ?*anyopaque, id: i32) void {
    _ = ud;
    s_stopped = id;
}

fn ma_gain(ud: ?*anyopaque, id: i32, v: f32) void {
    _ = ud;
    _ = id;
    s_gain = v;
}

fn ma_master(ud: ?*anyopaque, v: f32) void {
    _ = ud;
    s_master = v;
}

fn ma_pause(ud: ?*anyopaque) void {
    _ = ud;
    s_paused = 1;
}

fn ma_playing(ud: ?*anyopaque, id: i32) bool {
    _ = ud;
    return id == AUDIO_HANDLE_BASE + 1;
}

test "C Parity: test_audio" {
    var am = AudioManager.get();
    am.reset();

    const mock_audio = AudioInterface{
        .user_data = null,
        .play_sound_fn = ma_play,
        .stop_sound_fn = ma_stop,
        .set_sound_volume_fn = ma_gain,
        .set_master_volume_fn = ma_master,
        .pause_all_fn = ma_pause,
        .is_playing_fn = ma_playing,
    };
    am.setBackend(mock_audio);
    defer am.setBackend(.{});

    const h = am.playSound(5, 10, 1);
    try std.testing.expectEqual(@as(f32, @floatFromInt(AUDIO_HANDLE_BASE + 1)), h);
    try std.testing.expectEqual(@as(i32, 5), s_last_sound);
    try std.testing.expect(s_last_loop);

    try std.testing.expectEqual(@as(f32, -1.0), am.playSound(-1, 0, 0));
    try std.testing.expect(am.isPlaying(h) and !am.isPlaying(5));

    am.stopSound(h);
    try std.testing.expectEqual(AUDIO_HANDLE_BASE + 1, s_stopped);

    am.soundGain(5, -2, 0);
    try std.testing.expectEqual(@as(f32, 0.0), s_gain);

    am.masterGain(0.5);
    am.pauseAll();
    try std.testing.expectEqual(@as(f32, 0.5), s_master);
    try std.testing.expectEqual(@as(i32, 1), s_paused);

    am.resumeAll();
    am.stopAll();
}

var s_font_sprites: [2]SpriteDef = undefined;

test "sprite fonts: runtime text layout, size fallback, default font" {
    setup();
    defer teardown();

    // ' '..'Z' glyph strips, as sFont / sFontSmall.
    s_font_sprites[0] = .{ .name = "sBig", .width = 16, .height = 16, .bbox_right = 15, .bbox_bottom = 15, .frame_count = 59 };
    s_font_sprites[1] = .{ .name = "sSmall", .width = 8, .height = 8, .bbox_right = 7, .bbox_bottom = 7, .frame_count = 59 };
    _ = SpriteRegistry.get().initRegistry(&s_font_sprites);

    const dm = DrawManager.get();
    try std.testing.expectEqual(@as(i32, 0), dm.fontAddSprite(.{ .sprite = 0 }));
    try std.testing.expectEqual(@as(i32, 1), dm.fontAddSprite(.{ .sprite = 1 }));
    try std.testing.expectEqual(@as(i32, -1), dm.fontAddSprite(.{ .sprite = 7 }));

    // No host face: the sprite font that best fits the size.
    try std.testing.expectEqual(@as(i32, 2), dm.fontAdd("missing.ttf", 24));
    try std.testing.expectEqual(@as(i32, 0), dm.getFont(2).?.sprite.sprite);
    try std.testing.expectEqual(@as(i32, 1), dm.getFont(dm.fontAdd("missing.ttf", 12)).?.sprite.sprite);
    try std.testing.expectEqual(@as(i32, 1), dm.getFont(dm.fontAdd("missing.ttf", 4)).?.sprite.sprite);
    try std.testing.expectEqual(@as(i32, 7), dm.getFont(dm.fontAdd("fonts/a.ttf", 12)).?.host);

    dm.setColour(0x0000FF);
    dm.setAlpha(0.5);
    dm.setFont(1);
    mock_state.ncalls = 0;
    dm.drawText(10, 20, "Hi a\r\nZ~");
    // H, I (folded), A (folded), Z; blanks and '~' only advance.
    try std.testing.expectEqual(@as(usize, 4), mock_state.ncalls);
    const want = [_]struct { f: i32, x: f32, y: f32 }{
        .{ .f = 'H' - ' ', .x = 10, .y = 20 },
        .{ .f = 'I' - ' ', .x = 18, .y = 20 },
        .{ .f = 'A' - ' ', .x = 34, .y = 20 },
        .{ .f = 'Z' - ' ', .x = 10, .y = 28 },
    };
    for (want, mock_state.calls[0..4]) |w, c| {
        try std.testing.expectEqual(@as(u8, 'I'), c.kind);
        try std.testing.expectEqual(@as(i32, 1), c.a);
        try std.testing.expectEqual(w.f, c.b);
        try std.testing.expectEqual(w.x, c.x);
        try std.testing.expectEqual(w.y, c.y);
        try std.testing.expectEqual(@as(i32, 8), c.sw);
        try std.testing.expectEqual(@as(i32, 8), c.sh);
        try std.testing.expectEqual(@as(f32, 0), c.xo);
        try std.testing.expectEqual(@as(u32, 0x0000FF), c.colour);
        try std.testing.expectEqual(@as(f32, 0.5), c.alpha);
    }

    // The view transform scales positions, cells and advance.
    dm.xf = .{ .sx = 2, .sy = 3, .tx = 5, .ty = 1 };
    mock_state.ncalls = 0;
    dm.drawText(0, 0, "AB\nC");
    try std.testing.expectEqual(@as(f32, 21), mock_state.calls[1].x);
    try std.testing.expectEqual(@as(f32, 25), mock_state.calls[2].y);
    try std.testing.expectEqual(@as(f32, 2), mock_state.calls[1].xs);
    try std.testing.expectEqual(@as(f32, 3), mock_state.calls[1].ys);

    // No font set: the default font, else the host's face 0.
    dm.xf = .{};
    dm.setFont(-1);
    dm.setDefaultFont(0);
    mock_state.ncalls = 0;
    dm.drawText(0, 0, "A");
    try std.testing.expectEqual(@as(u8, 'I'), mock_state.calls[0].kind);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[0].a);
    dm.setDefaultFont(null);
    dm.drawText(0, 0, "A");
    try std.testing.expectEqual(@as(u8, 'T'), mock_state.calls[1].kind);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[1].a);

    // A host with no text support at all still draws sprite fonts.
    var bare = dm.backend;
    bare.font_load_fn = null;
    bare.draw_text_fn = null;
    dm.setBackend(bare);
    dm.setFont(2);
    mock_state.ncalls = 0;
    dm.drawText(0, 0, "A");
    try std.testing.expectEqual(@as(usize, 1), mock_state.ncalls);
    try std.testing.expectEqual(@as(i32, 0), mock_state.calls[0].a);
}
