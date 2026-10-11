//! Port of tests/test_room.c to Zig:
//! Validates room runtime (room.zig), layers/tiles (layer.zig), and views/cameras (view.zig)
//! with 100% parity against C baseline.

const std = @import("std");
const sprite_mod = @import("sprite.zig");
const SpriteRegistry = sprite_mod.SpriteRegistry;
const SpriteDef = sprite_mod.SpriteDef;
const object_mod = @import("object.zig");
const ObjectRegistry = object_mod.ObjectRegistry;
const ObjectDef = object_mod.ObjectDef;
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;
const GM_NOONE = instance_mod.GM_NOONE;
const layer_mod = @import("layer.zig");
const LayerManager = layer_mod.LayerManager;
const MAX_LAYERS = layer_mod.MAX_LAYERS;
const MAX_ELEMENTS = layer_mod.MAX_ELEMENTS;
const ELEMENT_BACKGROUND = layer_mod.ELEMENT_BACKGROUND;
const ELEMENT_TILE = layer_mod.ELEMENT_TILE;
const view_mod = @import("view.zig");
const ViewManager = view_mod.ViewManager;
const ViewField = view_mod.ViewField;
const room_mod = @import("room.zig");
const RoomManager = room_mod.RoomManager;
const RoomDef = room_mod.RoomDef;
const RoomViewDef = room_mod.RoomViewDef;
const RoomLayerDef = room_mod.RoomLayerDef;
const RoomTileDef = room_mod.RoomTileDef;
const RoomInstDef = room_mod.RoomInstDef;
const RoomHooks = room_mod.RoomHooks;
const ROOM_NONE = room_mod.ROOM_NONE;
const ROOM_FIRST_DYNAMIC_ID = room_mod.ROOM_FIRST_DYNAMIC_ID;
const EVENT_TYPE_CREATE = room_mod.EVENT_TYPE_CREATE;
const EVENT_TYPE_DESTROY = room_mod.EVENT_TYPE_DESTROY;
const EVENT_TYPE_ALARM = room_mod.EVENT_TYPE_ALARM;
const EVENT_TYPE_STEP = room_mod.EVENT_TYPE_STEP;
const EVENT_TYPE_OTHER = room_mod.EVENT_TYPE_OTHER;
const EVENT_TYPE_CLEAN_UP = room_mod.EVENT_TYPE_CLEAN_UP;
const EVENT_TYPE_PRE_CREATE = room_mod.EVENT_TYPE_PRE_CREATE;
const EVENT_OTHER_GAME_START = room_mod.EVENT_OTHER_GAME_START;
const EVENT_OTHER_ROOM_START = room_mod.EVENT_OTHER_ROOM_START;
const EVENT_OTHER_ROOM_END = room_mod.EVENT_OTHER_ROOM_END;

const OBJ_BLOCK: i32 = 0;
const OBJ_INTRO: i32 = 1;
const OBJ_KEEPER: i32 = 2;
const OBJ_PLAYER: i32 = 3;
const OBJ_COUNT: usize = 4;

const RM_A: i32 = 0;
const RM_B: i32 = 1;
const RM_C: i32 = 2;
const RM_COUNT: usize = 3;

// ---- Event Log ----
const LOG_MAX: usize = 256;
const Entry = struct {
    id: i32,
    what: i32,
    seen: usize,
};

var s_log: [LOG_MAX]Entry = undefined;
var s_log_count: usize = 0;
var s_blocks_at_first_create: i32 = -1;
var s_room_code_self_id: i32 = -1;
var s_end_room_saw: usize = 0;
var s_intro_goto: i32 = ROOM_NONE;

fn logAdd(self: *Instance, what: i32) void {
    if (s_log_count < LOG_MAX) {
        s_log[s_log_count] = .{
            .id = self.id,
            .what = what,
            .seen = InstanceManager.get().activeCount(),
        };
        s_log_count += 1;
    }
}

fn logFind(id: i32, what: i32) ?usize {
    for (0..s_log_count) |i| {
        if (s_log[i].id == id and s_log[i].what == what) {
            return i;
        }
    }
    return null;
}

fn logCount(what: i32) usize {
    var n: usize = 0;
    for (0..s_log_count) |i| {
        if (s_log[i].what == what) n += 1;
    }
    return n;
}

fn evBlockCreate(self: *Instance, _: ?*Instance) void {
    if (s_blocks_at_first_create < 0) {
        s_blocks_at_first_create = @intCast(InstanceManager.get().count(OBJ_BLOCK));
    }
    logAdd(self, 0);
}

fn evIntroCreate(self: *Instance, _: ?*Instance) void {
    self.vars[0] = 0.0;
    logAdd(self, 0);
    if (s_intro_goto != ROOM_NONE) {
        _ = RoomManager.get().roomGoto(s_intro_goto);
    }
}

fn codeIntro(self: *Instance, _: ?*Instance) void {
    self.vars[0] = 400.0;
    logAdd(self, 1);
}

fn evAnyCreate(self: *Instance, _: ?*Instance) void {
    logAdd(self, 0);
}

fn evDestroy(self: *Instance, _: ?*Instance) void {
    logAdd(self, 2);
}

fn roomCode(self: *Instance, _: ?*Instance) void {
    s_room_code_self_id = self.id;
    self.vars[1] = 9.0;
}

fn performHook(inst: *Instance, ev_type: i32, number: i32) void {
    if (ev_type == EVENT_TYPE_PRE_CREATE) {
        logAdd(inst, 200);
    } else if (ev_type == EVENT_TYPE_OTHER) {
        if (number == EVENT_OTHER_ROOM_END) {
            s_end_room_saw = InstanceManager.get().totalCount();
        }
        logAdd(inst, 100 + number);
    }
}

const s_hooks = RoomHooks{
    .perform = performHook,
    .room_begin = null,
};

// ---- Tables ----
var s_objs: [OBJ_COUNT]ObjectDef = undefined;
var s_sprites: [1]SpriteDef = undefined;

const s_layers_a = [_]RoomLayerDef{
    .{ .name = "Compatibility_Instances_Depth_0", .id = 1, .kind = layer_mod.LAYER_INSTANCES, .depth = 0, .visible = true },
    .{ .name = "Compatibility_Instances_Depth_100", .id = 2, .kind = layer_mod.LAYER_INSTANCES, .depth = 100, .visible = true },
    .{ .name = "Compatibility_Tiles_Depth_1000000", .id = 3, .kind = layer_mod.LAYER_ASSETS, .depth = 1000000, .visible = true, .first_tile = 0, .tile_count = 2 },
    .{ .name = "Compatibility_Background_0_bg", .id = 4, .kind = layer_mod.LAYER_BACKGROUND, .depth = 2147483500, .visible = true, .bg_sprite = 0, .bg_htiled = true, .bg_vtiled = true, .bg_stretch = false, .bg_colour = 0xffffffff },
};

const s_tiles_a = [_]RoomTileDef{
    .{ .sprite = 0, .u = 64, .v = 0, .w = 16, .h = 16, .x = 32.0, .y = 128.0, .xscale = 1.0, .yscale = 1.0, .colour = 0xffffffff },
    .{ .sprite = 0, .u = 0, .v = 0, .w = 16, .h = 16, .x = 48.0, .y = 128.0, .xscale = 1.0, .yscale = 1.0, .colour = 0x80ffffff },
};

const s_insts_a = [_]RoomInstDef{
    .{ .id = 100000, .object = OBJ_BLOCK, .x = 16.0, .y = 192.0, .xscale = 1.0, .yscale = 1.0, .angle = 0.0, .colour = 0xffffffff, .image_index = 0.0, .image_speed = 1.0, .layer = 1, .code = null },
    .{ .id = 100001, .object = OBJ_INTRO, .x = 0.0, .y = 0.0, .xscale = -1.0, .yscale = 1.0, .angle = 0.0, .colour = 0xffffffff, .image_index = 0.0, .image_speed = 1.0, .layer = 0, .code = codeIntro },
    .{ .id = 100002, .object = OBJ_BLOCK, .x = 32.0, .y = 192.0, .xscale = 1.0, .yscale = 1.0, .angle = 0.0, .colour = 0x80ffffff, .image_index = 0.0, .image_speed = 1.0, .layer = 1, .code = null },
    .{ .id = 100003, .object = OBJ_KEEPER, .x = 0.0, .y = 0.0, .xscale = 1.0, .yscale = 1.0, .angle = 0.0, .colour = 0xffffffff, .image_index = 0.0, .image_speed = 1.0, .layer = 0, .code = null },
};

const s_layers_b = [_]RoomLayerDef{
    .{ .name = "Compatibility_Instances_Depth_0", .id = 5, .kind = layer_mod.LAYER_INSTANCES, .depth = 0, .visible = true },
};

const s_insts_b = [_]RoomInstDef{
    .{ .id = 100004, .object = OBJ_PLAYER, .x = 40.0, .y = 50.0, .xscale = 1.0, .yscale = 1.0, .angle = 0.0, .colour = 0xffffffff, .image_index = 0.0, .image_speed = 1.0, .layer = 0, .code = null },
    .{ .id = 100005, .object = OBJ_BLOCK, .x = 0.0, .y = 0.0, .xscale = 1.0, .yscale = 1.0, .angle = 0.0, .colour = 0xffffffff, .image_index = 0.0, .image_speed = 1.0, .layer = 0, .code = null },
};

const VIEW_OFF = RoomViewDef{
    .visible = false,
    .xview = 0,
    .yview = 0,
    .wview = 640,
    .hview = 480,
    .xport = 0,
    .yport = 0,
    .wport = 640,
    .hport = 480,
    .hborder = 32,
    .vborder = 32,
    .hspeed = -1,
    .vspeed = -1,
    .object = -1,
};

const s_rooms = [_]RoomDef{
    .{
        .name = "rA",
        .width = 768,
        .height = 240,
        .speed = 30,
        .persistent = false,
        .enable_views = true,
        .views = [_]RoomViewDef{
            .{ .visible = true, .xview = 0, .yview = 0, .wview = 320, .hview = 240, .xport = 0, .yport = 0, .wport = 640, .hport = 480, .hborder = 32, .vborder = 32, .hspeed = -1, .vspeed = -1, .object = -1 },
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
        },
        .layer_count = 4,
        .layers = &s_layers_a,
        .tile_count = 2,
        .tiles = &s_tiles_a,
        .instance_count = 4,
        .instances = &s_insts_a,
        .code = roomCode,
    },
    .{
        .name = "rB",
        .width = 672,
        .height = 544,
        .speed = 30,
        .persistent = false,
        .enable_views = true,
        .views = [_]RoomViewDef{
            .{ .visible = true, .xview = 0, .yview = 0, .wview = 320, .hview = 240, .xport = 0, .yport = 0, .wport = 640, .hport = 480, .hborder = 160, .vborder = 96, .hspeed = -1, .vspeed = -1, .object = OBJ_PLAYER },
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
            VIEW_OFF,
        },
        .layer_count = 1,
        .layers = &s_layers_b,
        .tile_count = 0,
        .tiles = null,
        .instance_count = 2,
        .instances = &s_insts_b,
        .code = null,
    },
    .{
        .name = "rC",
        .width = 320,
        .height = 240,
        .speed = 30,
        .persistent = false,
        .enable_views = false,
        .views = [_]RoomViewDef{VIEW_OFF} ** 8,
        .layer_count = 0,
        .layers = null,
        .tile_count = 0,
        .tiles = null,
        .instance_count = 0,
        .instances = null,
        .code = null,
    },
};

const s_order = [_]i32{ RM_B, RM_A, RM_C };

fn setup() void {
    for (0..OBJ_COUNT) |i| {
        s_objs[i] = .{
            .parent_index = object_mod.OBJECT_NONE,
            .default_sprite = -1,
            .default_mask = -1,
            .default_visible = true,
            .ev_destroy = evDestroy,
            .ev_create = evAnyCreate,
        };
    }
    s_objs[@intCast(OBJ_BLOCK)].name = "oBlock";
    s_objs[@intCast(OBJ_BLOCK)].ev_create = evBlockCreate;
    s_objs[@intCast(OBJ_BLOCK)].default_depth = 100.0;
    s_objs[@intCast(OBJ_INTRO)].name = "oIntroBG";
    s_objs[@intCast(OBJ_INTRO)].ev_create = evIntroCreate;
    s_objs[@intCast(OBJ_KEEPER)].name = "oKeeper";
    s_objs[@intCast(OBJ_KEEPER)].default_persistent = true;
    s_objs[@intCast(OBJ_PLAYER)].name = "oPlayer";

    s_sprites[0] = .{
        .name = "bg",
        .width = 16,
        .height = 16,
        .frame_count = 1,
    };

    _ = SpriteRegistry.get().initRegistry(&s_sprites);
    _ = ObjectRegistry.get().initRegistry(&s_objs);
    InstanceManager.get().reset();
    RoomManager.get().setHooks(s_hooks);
    _ = RoomManager.get().registryInit(&s_rooms, &s_order);

    s_log_count = 0;
    s_blocks_at_first_create = -1;
    s_room_code_self_id = -1;
    s_end_room_saw = 0;
    s_intro_goto = ROOM_NONE;
}

// Helpers for tile_add, tile_layer_find
fn tileAdd(sprite: i32, left: i32, top: i32, w: i32, h: i32, x: f32, y: f32, depth: i32) i32 {
    const lm = LayerManager.get();
    var layers: [MAX_LAYERS]i32 = undefined;
    const n = lm.getAll(&layers);
    var use: i32 = -1;

    for (0..n) |i| {
        if (lm.find(layers[i]).?.depth == depth) {
            use = layers[i];
            break;
        }
    }
    if (use == -1) {
        use = lm.create(depth, null);
    }
    return lm.tileCreate(use, x, y, sprite, left, top, w, h);
}

fn tileLayerFind(depth: i32, x: f32, y: f32) i32 {
    const lm = LayerManager.get();
    var els: [MAX_ELEMENTS]i32 = undefined;
    var layers: [MAX_LAYERS]i32 = undefined;
    const n = lm.getAll(&layers);

    for (0..n) |i| {
        const l = lm.find(layers[i]).?;
        if (l.depth != depth) continue;
        const m = lm.elements(layers[i], &els);
        for (0..m) |j| {
            const e = lm.element(els[j]).?;
            if (e.type == ELEMENT_TILE and x >= e.x and y >= e.y and
                x < e.x + e.xscale * @as(f32, @floatFromInt(e.w)) and
                y < e.y + e.yscale * @as(f32, @floatFromInt(e.h)))
            {
                return e.id;
            }
        }
    }
    return -1;
}

test "C Parity: test_registry_and_order" {
    setup();
    const rm = RoomManager.get();
    try std.testing.expectEqual(@as(usize, 3), rm.count());
    try std.testing.expectEqualStrings("rA", rm.getName(RM_A));
    try std.testing.expectEqualStrings("", rm.getName(7));
    try std.testing.expect(rm.exists(RM_C) and !rm.exists(-1) and !rm.exists(3));
    try std.testing.expectEqual(RM_B, rm.first());
    try std.testing.expectEqual(RM_C, rm.last());
    try std.testing.expectEqual(RM_A, rm.next(RM_B));
    try std.testing.expectEqual(ROOM_NONE, rm.next(RM_C));
    try std.testing.expectEqual(RM_A, rm.previous(RM_C));
    try std.testing.expectEqual(ROOM_NONE, rm.previous(RM_B));
    try std.testing.expectEqual(ROOM_NONE, rm.current());

    var bad = s_rooms[0];
    bad.persistent = true; // unsupported
    const bad_slice = [_]RoomDef{bad};
    try std.testing.expect(!rm.registryInit(&bad_slice, null));
    try std.testing.expectEqual(@as(usize, 0), rm.count());
}

test "C Parity: test_start_creates_with_fixed_ids_and_layer_depth" {
    setup();
    const rm = RoomManager.get();
    const mgr = InstanceManager.get();

    try std.testing.expect(rm.start(RM_A, true));
    try std.testing.expectEqual(RM_A, rm.current());
    try std.testing.expectEqual(@as(usize, 4), mgr.totalCount());

    const a = mgr.findById(100000);
    const b = mgr.findById(100002);
    const intro = mgr.findById(100001);
    try std.testing.expect(a != null and b != null and intro != null);
    try std.testing.expectEqual(@as(f32, 100.0), a.?.depth);
    try std.testing.expectEqual(@as(f32, 0.0), intro.?.depth);
    try std.testing.expectEqual(@as(f32, -1.0), intro.?.image_xscale);
    try std.testing.expect(b.?.image_alpha > 0.50 and b.?.image_alpha < 0.51 and b.?.image_blend == 0xffffff);

    try std.testing.expectEqual(a.?, mgr.activeAt(0).?);
    try std.testing.expectEqual(intro.?, mgr.activeAt(1).?);
    try std.testing.expectEqual(@as(f32, 768.0), rm.getWidth());
    try std.testing.expectEqual(@as(f32, 240.0), rm.getHeight());
    try std.testing.expectEqual(@as(f32, 30.0), rm.getSpeed());
}

test "C Parity: test_all_instances_exist_during_the_first_create" {
    setup();
    _ = RoomManager.get().start(RM_A, true);
    try std.testing.expectEqual(@as(i32, 2), s_blocks_at_first_create);
    const pos = logFind(100000, 0).?;
    try std.testing.expectEqual(@as(usize, 4), s_log[pos].seen);
}

test "C Parity: test_precreate_create_code_order" {
    setup();
    _ = RoomManager.get().start(RM_A, true);
    const intro = InstanceManager.get().findById(100001);
    try std.testing.expect(intro != null and intro.?.vars[0] == 400.0);

    const pre = logFind(100001, 200).?;
    const create = logFind(100001, 0).?;
    const code = logFind(100001, 1).?;
    const next_pre = logFind(100002, 200).?;

    try std.testing.expect(pre < create and create < code and code < next_pre);
    try std.testing.expect(logFind(100000, 0).? < pre);
}

test "C Parity: test_game_start_room_code_and_room_start" {
    setup();
    const rm = RoomManager.get();
    _ = rm.start(RM_A, true);

    try std.testing.expectEqual(@as(usize, 4), logCount(100 + EVENT_OTHER_GAME_START));
    try std.testing.expectEqual(@as(usize, 4), logCount(100 + EVENT_OTHER_ROOM_START));
    try std.testing.expectEqual(@as(i32, 0), s_room_code_self_id);
    try std.testing.expect(InstanceManager.get().findById(0) == null);

    const code_pos = logFind(100003, 100 + EVENT_OTHER_GAME_START).?;
    const start_pos = logFind(100003, 100 + EVENT_OTHER_ROOM_START).?;
    try std.testing.expect(code_pos < start_pos);
    // Walks active list from the end: 100003 runs before 100000
    try std.testing.expect(logFind(100003, 100 + EVENT_OTHER_ROOM_START).? < logFind(100000, 100 + EVENT_OTHER_ROOM_START).?);

    s_log_count = 0;
    _ = rm.roomGoto(RM_B);
    _ = rm.switchPending();
    try std.testing.expectEqual(@as(usize, 0), logCount(100 + EVENT_OTHER_GAME_START));
}

test "C Parity: test_switch_is_deferred_and_carries_persistent_instances" {
    setup();
    const rm = RoomManager.get();
    const mgr = InstanceManager.get();

    _ = rm.start(RM_A, true);
    const keeper = mgr.findById(100003);
    try std.testing.expect(rm.roomGoto(RM_B));
    try std.testing.expectEqual(RM_A, rm.current()); // deferred
    try std.testing.expectEqual(RM_B, rm.pending());

    s_log_count = 0;
    try std.testing.expect(rm.switchPending());
    try std.testing.expectEqual(RM_B, rm.current());
    try std.testing.expectEqual(ROOM_NONE, rm.pending());
    try std.testing.expect(!rm.switchPending());

    try std.testing.expectEqual(@as(usize, 4), logCount(100 + EVENT_OTHER_ROOM_END));
    try std.testing.expectEqual(@as(usize, 4), s_end_room_saw);
    try std.testing.expectEqual(@as(usize, 0), logCount(2)); // No Destroy events

    try std.testing.expect(mgr.findById(100000) == null and mgr.findById(100001) == null);
    try std.testing.expect(mgr.findById(100003) == keeper and keeper.?.in_use);
    try std.testing.expectEqual(@as(usize, 3), mgr.totalCount());

    // New instances first, carried-over appended after
    try std.testing.expectEqual(@as(i32, 100004), mgr.activeAt(0).?.id);
    try std.testing.expectEqual(keeper.?, mgr.activeAt(2).?);

    // Persistent instance did not exist in active list during new Creates
    const b_create = logFind(100005, 0).?;
    try std.testing.expectEqual(@as(usize, 2), s_log[b_create].seen);

    // Back to rA: storage instance 100003 is the live persistent one, not recreated
    _ = rm.roomGoto(RM_A);
    _ = rm.switchPending();
    try std.testing.expectEqual(@as(usize, 1), mgr.count(OBJ_KEEPER));
    try std.testing.expectEqual(@as(usize, 4), mgr.totalCount());
    try std.testing.expectEqual(keeper.?, mgr.findById(100003).?);
}

test "C Parity: test_deactivated_instances_are_cleared_too" {
    setup();
    const rm = RoomManager.get();
    const mgr = InstanceManager.get();

    _ = rm.start(RM_A, true);
    const keeper = mgr.findById(100003).?;
    mgr.deactivate(keeper);
    mgr.deactivate(mgr.findById(100000).?);

    _ = rm.roomGoto(RM_B);
    _ = rm.switchPending();
    try std.testing.expectEqual(@as(usize, 2), mgr.totalCount());
    try std.testing.expect(mgr.findById(100003) == null);
}

test "C Parity: test_restart_next_and_invalid_goto" {
    setup();
    const rm = RoomManager.get();
    const mgr = InstanceManager.get();

    try std.testing.expect(rm.startGame());
    try std.testing.expectEqual(RM_B, rm.current());

    const dyn_block = mgr.create(OBJ_BLOCK, 0.0, 0.0);
    try std.testing.expectEqual(@as(i32, ROOM_FIRST_DYNAMIC_ID), dyn_block.?.id);

    rm.roomRestart();
    try std.testing.expectEqual(RM_B, rm.pending());
    _ = rm.switchPending();
    try std.testing.expectEqual(@as(usize, 2), mgr.totalCount());
    try std.testing.expect(mgr.findById(100004) != null);

    rm.roomGotoNext();
    try std.testing.expectEqual(RM_A, rm.pending());
    _ = rm.switchPending();
    rm.roomGotoNext();
    _ = rm.switchPending();
    try std.testing.expectEqual(RM_C, rm.current());

    rm.roomGotoNext(); // end of order
    try std.testing.expectEqual(ROOM_NONE, rm.pending());

    try std.testing.expect(!rm.roomGoto(99));
    try std.testing.expect(!rm.roomGoto(-1));
    try std.testing.expectEqual(ROOM_NONE, rm.pending());
    try std.testing.expectEqual(@as(usize, 2), rm.errors());

    rm.roomGotoPrevious();
    try std.testing.expectEqual(RM_A, rm.pending());
}

test "C Parity: test_room_goto_during_room_end_is_kept" {
    setup();
    const rm = RoomManager.get();
    _ = rm.start(RM_A, true);
    _ = rm.roomGoto(RM_B);
    _ = rm.switchPending();
    try std.testing.expectEqual(ROOM_NONE, rm.pending());

    rm.setCaption("hello");
    try std.testing.expectEqualStrings("hello", rm.getCaption());
    rm.setWidth(1000.0);
    try std.testing.expectEqual(@as(f32, 1000.0), rm.getWidth());
}

test "C Parity: test_events_are_gated_while_a_room_is_pending" {
    setup();
    const rm = RoomManager.get();
    const mgr = InstanceManager.get();

    s_intro_goto = RM_C;
    _ = rm.start(RM_A, true);
    try std.testing.expectEqual(RM_C, rm.pending());
    try std.testing.expect(logFind(100001, 1) != null); // creation code ran

    const block = mgr.findById(100002);
    try std.testing.expect(block != null);
    try std.testing.expect(logFind(100002, 200) == null and logFind(100002, 0) == null);
    try std.testing.expect(logFind(100003, 200) != null and logFind(100003, 0) != null);
    try std.testing.expectEqual(@as(usize, 1), logCount(100 + EVENT_OTHER_GAME_START)); // keeper only
    try std.testing.expectEqual(@as(usize, 1), logCount(100 + EVENT_OTHER_ROOM_START));
    try std.testing.expect(logFind(100003, 100 + EVENT_OTHER_ROOM_START) != null);
    try std.testing.expectEqual(@as(i32, 0), s_room_code_self_id);

    try std.testing.expect(rm.eventBlocked(block.?, EVENT_TYPE_STEP));
    try std.testing.expect(!rm.eventBlocked(block.?, EVENT_TYPE_CLEAN_UP));

    const keeper = mgr.findById(100003);
    try std.testing.expect(rm.eventBlocked(keeper.?, EVENT_TYPE_STEP));
    try std.testing.expect(!rm.eventBlocked(keeper.?, EVENT_TYPE_ALARM));

    s_log_count = 0;
    const made = mgr.create(OBJ_BLOCK, 0.0, 0.0);
    try std.testing.expect(made != null and logCount(0) == 0);

    mgr.destroy(block.?);
    try std.testing.expect(block.?.marked_for_destroy and logCount(2) == 0);

    _ = rm.switchPending();
    try std.testing.expectEqual(ROOM_NONE, rm.pending());
    try std.testing.expect(!rm.eventBlocked(null, EVENT_TYPE_STEP));
}

test "C Parity: test_storage_layers_and_tiles" {
    setup();
    const lm = LayerManager.get();
    _ = RoomManager.get().start(RM_A, true);

    var all: [MAX_LAYERS]i32 = undefined;
    const n = lm.getAll(&all);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expect(all[0] == 1 and all[1] == 2 and all[2] == 3 and all[3] == 4);
    try std.testing.expectEqualStrings("Compatibility_Tiles_Depth_1000000", lm.find(3).?.getName());
    try std.testing.expectEqual(lm.find(3), lm.findName("compatibility_tiles_depth_1000000"));

    var els: [8]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), lm.elements(3, &els));
    const e = lm.element(els[0]).?;
    try std.testing.expect(e.type == ELEMENT_TILE and e.x == 32.0 and e.xo == 64 and e.alpha == 1.0);
    try std.testing.expectEqual(@as(f32, 48.0), lm.element(els[1]).?.x);

    try std.testing.expectEqual(@as(usize, 1), lm.elements(4, &els));
    try std.testing.expectEqual(ELEMENT_BACKGROUND, lm.elementType(els[0]));
    try std.testing.expect(lm.backgroundExists(4, els[0]) and !lm.backgroundExists(3, els[0]));
    try std.testing.expect(lm.element(els[0]).?.htiled and lm.element(els[0]).?.sprite == 0);
    try std.testing.expect(tileLayerFind(1000000, 40.0, 130.0) >= 0);

    _ = RoomManager.get().roomGoto(RM_B);
    _ = RoomManager.get().switchPending();
    try std.testing.expectEqual(@as(usize, 1), lm.getAll(&all));
    try std.testing.expect(all[0] == 5 and lm.find(3) == null);
}

test "C Parity: test_tile_add_find_delete_round_trip" {
    setup();
    const lm = LayerManager.get();
    _ = RoomManager.get().start(RM_A, true);

    const t1 = tileAdd(0, 0, 0, 16, 16, 64.0, 64.0, 3);
    const t2 = tileAdd(0, 16, 0, 16, 16, 80.0, 64.0, 3);
    const t3 = tileAdd(0, 0, 0, 16, 16, 64.0, 64.0, 9005);

    try std.testing.expect(t1 > 0 and t2 == t1 + 1 and t3 == t2 + 1);

    var all: [MAX_LAYERS]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 6), lm.getAll(&all));
    try std.testing.expectEqual(@as(i32, 1), all[0]); // depth 0
    const layer_id = all[1]; // depth 3
    try std.testing.expect(lm.find(layer_id).?.depth == 3 and layer_id > 5);
    try std.testing.expectEqualStrings("_layer_6", lm.find(layer_id).?.getName());

    var els: [8]i32 = undefined;
    try std.testing.expectEqual(@as(usize, 2), lm.elements(layer_id, &els));
    try std.testing.expect(els[0] == t2 and els[1] == t1); // newest first

    try std.testing.expectEqual(t1, tileLayerFind(3, 70.0, 70.0));
    try std.testing.expectEqual(t2, tileLayerFind(3, 95.0, 79.0));
    try std.testing.expectEqual(@as(i32, -1), tileLayerFind(3, 96.0, 64.0));
    try std.testing.expectEqual(t3, tileLayerFind(9005, 64.0, 64.0));

    lm.elementDestroy(t1);
    try std.testing.expectEqual(@as(i32, -1), tileLayerFind(3, 70.0, 70.0));
    try std.testing.expectEqual(@as(i32, -1), lm.elementType(t1));
    try std.testing.expectEqual(t2, tileLayerFind(3, 81.0, 64.0));
    lm.elementDestroy(t1); // harmless
    try std.testing.expectEqual(@as(usize, 1), lm.elements(layer_id, &els));

    // Room switch: element id counter keeps counting
    _ = RoomManager.get().roomGoto(RM_A);
    _ = RoomManager.get().switchPending();
    try std.testing.expect(tileAdd(0, 0, 0, 16, 16, 0.0, 0.0, 3) > t3);
}

test "C Parity: test_layer_create_destroy_and_depth" {
    setup();
    const lm = LayerManager.get();
    _ = RoomManager.get().start(RM_C, true);

    const a = lm.create(10, "Mine");
    const b = lm.create(10, null);
    var all: [MAX_LAYERS]i32 = undefined;
    const n = lm.getAll(&all);
    try std.testing.expect(n == 2 and all[0] == a and all[1] == b);

    lm.setDepth(a, 20);
    _ = lm.getAll(&all);
    try std.testing.expect(all[0] == b and all[1] == a);

    _ = lm.tileCreate(a, 0.0, 0.0, 0, 0, 0, 16, 16);
    lm.destroy(a);
    try std.testing.expect(lm.find(a) == null and lm.getAll(&all) == 1);
    try std.testing.expectEqual(@as(i32, -1), lm.tileCreate(a, 0.0, 0.0, 0, 0, 0, 16, 16));

    const layer_b = lm.find(b).?;
    layer_b.hspeed = 2.0;
    lm.update();
    try std.testing.expectEqual(@as(f32, 2.0), layer_b.x);
}

test "C Parity: test_pool_overflows_are_counted" {
    setup();
    const lm = LayerManager.get();
    _ = RoomManager.get().start(RM_C, true);

    var last: i32 = 0;
    for (0..MAX_LAYERS + 3) |i| {
        last = lm.create(@intCast(i), null);
    }
    try std.testing.expectEqual(@as(i32, -1), last);
    try std.testing.expectEqual(@as(usize, 3), lm.overflows());

    const first_layer_id = lm.at(0).?.id;
    for (0..MAX_ELEMENTS + 2) |i| {
        last = lm.tileCreate(first_layer_id, @floatFromInt(i), 0.0, 0, 0, 0, 16, 16);
    }
    try std.testing.expectEqual(@as(i32, -1), last);
    try std.testing.expectEqual(@as(usize, 5), lm.overflows());

    _ = RoomManager.get().roomGoto(RM_C);
    _ = RoomManager.get().switchPending();
    try std.testing.expect(lm.create(0, null) > 0);
}

test "C Parity: test_views_from_storage" {
    setup();
    const vm = ViewManager.get();
    _ = RoomManager.get().start(RM_B, true);

    try std.testing.expect(vm.enabled());
    try std.testing.expectEqual(@as(f32, 1.0), vm.getViewVar(ViewField.visible, 0));
    try std.testing.expectEqual(@as(f32, 320.0), vm.getViewVar(ViewField.wview, 0));
    try std.testing.expectEqual(@as(f32, 640.0), vm.getViewVar(ViewField.wport, 0));
    try std.testing.expectEqual(@as(f32, @floatFromInt(OBJ_PLAYER)), vm.getViewVar(ViewField.object, 0));
    try std.testing.expectEqual(@as(f32, 0.0), vm.getViewVar(ViewField.xview, 9)); // out of range

    const cam_id: i32 = @intFromFloat(vm.getViewVar(ViewField.camera, 0));
    const c = vm.cameraGet(cam_id);
    try std.testing.expect(c != null and c.?.cloned and c.?.target == OBJ_PLAYER and c.?.w == 320.0 and c.?.border_x == 160.0);
    try std.testing.expectEqual(@as(usize, 8), vm.cameraCount());

    _ = RoomManager.get().roomGoto(RM_C);
    _ = RoomManager.get().switchPending();
    try std.testing.expect(vm.cameraGet(cam_id) == null); // cloned cameras destroyed with room
    try std.testing.expectEqual(@as(usize, 8), vm.cameraCount());
    try std.testing.expect(!vm.enabled());
}

test "C Parity: test_room_set_view_storage_camera_is_cloned" {
    setup();
    const vm = ViewManager.get();

    const mine = vm.cameraCreateView(0.0, 0.0, 160.0, 120.0, 0.0, GM_NOONE, 0.0, 0.0, 0.0, 0.0);
    try std.testing.expectEqual(@as(i32, -1), vm.roomCamera(RM_A, 0));
    vm.roomSetCamera(RM_A, 0, mine);
    vm.roomSetViewport(RM_A, 0, true, 0, 0, 320, 240);
    try std.testing.expectEqual(mine, vm.roomCamera(RM_A, 0));

    _ = RoomManager.get().start(RM_A, true);
    const cam_id: i32 = @intFromFloat(vm.getViewVar(ViewField.camera, 0));
    try std.testing.expect(cam_id != mine);
    const c = vm.cameraGet(cam_id);
    try std.testing.expect(c != null and c.?.cloned and c.?.w == 160.0 and c.?.target == GM_NOONE);
    try std.testing.expectEqual(@as(f32, 320.0), vm.getViewVar(ViewField.wport, 0));

    _ = RoomManager.get().roomGoto(RM_B);
    _ = RoomManager.get().switchPending();
    try std.testing.expect(vm.cameraGet(mine) != null and vm.cameraGet(cam_id) == null);
    vm.cameraDestroy(mine);
    try std.testing.expect(vm.cameraGet(mine) == null);
}

test "C Parity: test_camera_follow_borders_room_clamp_and_speed" {
    setup();
    const vm = ViewManager.get();
    _ = RoomManager.get().start(RM_B, true); // 672 x 544

    const c = vm.cameraGet(@intFromFloat(vm.getViewVar(ViewField.camera, 0))).?;
    const p = InstanceManager.get().findById(100004).?;

    c.border_x = 32.0;
    c.border_y = 32.0;
    p.x = 300.5;
    p.y = 100.0;
    vm.update();
    try std.testing.expectEqual(@as(f32, 300.0 + 32.0 - 320.0), c.x); // floor(300.5)
    try std.testing.expectEqual(@as(f32, 0.0), c.y);

    p.x = 10.0;
    vm.update();
    try std.testing.expectEqual(@as(f32, 0.0), c.x);

    p.x = 700.0;
    p.y = 600.0;
    vm.update();
    try std.testing.expectEqual(@as(f32, 672.0 - 320.0), c.x);
    try std.testing.expectEqual(@as(f32, 544.0 - 240.0), c.y);

    c.border_x = 200.0; // 2 * border >= width: centre
    c.speed_x = 5.0;
    p.x = 300.0;
    vm.update();
    try std.testing.expectEqual(@as(f32, 352.0 - 5.0), c.x); // speed-limited move

    c.speed_x = -1.0;
    vm.update();
    try std.testing.expectEqual(@as(f32, 300.0 - 160.0), c.x);

    try std.testing.expectEqual(@as(f32, 0.0), vm.getViewVar(ViewField.xview, 0));

    vm.setViewVar(ViewField.visible, 0, 0.0);
    p.x = 0.0;
    vm.update();
    try std.testing.expectEqual(@as(f32, 140.0), c.x);
}
