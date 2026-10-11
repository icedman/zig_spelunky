//! C comparison tests for LoopManager and InputManager matching tests/test_loop.c.
//! Validates the 14-phase frame pipeline, keyboard events, alarms, collisions,
//! motion, outside room triggers, room transitions, and draw sorting.

const std = @import("std");

const input_mod = @import("input.zig");
const InputManager = input_mod.InputManager;
const VK_NOKEY = input_mod.VK_NOKEY;
const VK_ANYKEY = input_mod.VK_ANYKEY;

const sprite_mod = @import("sprite.zig");
const SpriteDef = sprite_mod.SpriteDef;
const SpriteRegistry = sprite_mod.SpriteRegistry;

const object_mod = @import("object.zig");
const ObjectDef = object_mod.ObjectDef;
const ObjectRegistry = object_mod.ObjectRegistry;
const EventFn = object_mod.EventFn;
const OBJECT_NONE = object_mod.OBJECT_NONE;

const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;

const layer_mod = @import("layer.zig");
const LayerManager = layer_mod.LayerManager;
const LAYER_INSTANCES = layer_mod.LAYER_INSTANCES;

const view_mod = @import("view.zig");
const ViewManager = view_mod.ViewManager;

const room_mod = @import("room.zig");
const RoomDef = room_mod.RoomDef;
const RoomViewDef = room_mod.RoomViewDef;
const RoomLayerDef = room_mod.RoomLayerDef;
const RoomInstDef = room_mod.RoomInstDef;
const RoomHooks = room_mod.RoomHooks;
const RoomManager = room_mod.RoomManager;
const ROOM_NONE = room_mod.ROOM_NONE;
const ROOM_END_GAME = room_mod.ROOM_END_GAME;

const collision_mod = @import("collision.zig");

const draw_mod = @import("draw.zig");
const DrawManager = draw_mod.DrawManager;

const loop_mod = @import("loop.zig");
const LoopManager = loop_mod.LoopManager;
const LoopHooks = loop_mod.LoopHooks;
const LoopStatus = loop_mod.LoopStatus;

const EV_TYPE_ALARM = loop_mod.EV_TYPE_ALARM;
const EV_TYPE_STEP = loop_mod.EV_TYPE_STEP;
const EV_TYPE_COLLISION = loop_mod.EV_TYPE_COLLISION;
const EV_TYPE_KEYBOARD = loop_mod.EV_TYPE_KEYBOARD;
const EV_TYPE_OTHER = loop_mod.EV_TYPE_OTHER;
const EV_TYPE_DRAW = loop_mod.EV_TYPE_DRAW;
const EV_TYPE_KEYPRESS = loop_mod.EV_TYPE_KEYPRESS;
const EV_TYPE_KEYRELEASE = loop_mod.EV_TYPE_KEYRELEASE;

const EV_STEP_NORMAL = loop_mod.EV_STEP_NORMAL;
const EV_STEP_BEGIN = loop_mod.EV_STEP_BEGIN;
const EV_STEP_END = loop_mod.EV_STEP_END;

const EV_OTHER_OUTSIDE = loop_mod.EV_OTHER_OUTSIDE;
const EV_OTHER_ANIMATION_END = loop_mod.EV_OTHER_ANIMATION_END;

const EV_DRAW_NORMAL = loop_mod.EV_DRAW_NORMAL;
const EV_DRAW_GUI = loop_mod.EV_DRAW_GUI;
const EV_DRAW_BEGIN = loop_mod.EV_DRAW_BEGIN;
const EV_DRAW_END = loop_mod.EV_DRAW_END;
const EV_DRAW_GUI_BEGIN = loop_mod.EV_DRAW_GUI_BEGIN;
const EV_DRAW_GUI_END = loop_mod.EV_DRAW_GUI_END;
const EV_DRAW_PRE = loop_mod.EV_DRAW_PRE;
const EV_DRAW_POST = loop_mod.EV_DRAW_POST;

// Object enum
const O_A: i32 = 0;
const O_B: i32 = 1;
const O_WALL: i32 = 2;
const O_PLAIN: i32 = 3;
const O_KEY: i32 = 4;
const O_SELF: i32 = 5;
const O_PERS: i32 = 6;
const O_COUNT: usize = 7;

// Event log types
const L_BEGIN: i32 = 1;
const L_STEP: i32 = 2;
const L_END: i32 = 3;
const L_ALARM0: i32 = 4;
const L_ANIM: i32 = 5;
const L_OUTSIDE: i32 = 6;
const L_COLL: i32 = 7;
const L_DRAW_BEGIN: i32 = 8;
const L_DRAW: i32 = 9;
const L_DRAW_END: i32 = 10;
const L_PRE: i32 = 11;
const L_POST: i32 = 12;
const L_GUI_BEGIN: i32 = 13;
const L_GUI: i32 = 14;
const L_GUI_END: i32 = 15;
const L_KEY: i32 = 16;
const L_ROOM_START: i32 = 17;
const L_DRAW_SELF: i32 = 18;
const L_PERS_STEP: i32 = 19;
const L_CREATE: i32 = 20;

const LOG_MAX: usize = 4096;

const Entry = struct {
    what: i32 = 0,
    id: i32 = -1,
    other: i32 = -1,
    view: i32 = 0,
    number: i32 = 0,
};

var s_log: [LOG_MAX]Entry = [_]Entry{.{}} ** LOG_MAX;
var s_log_count: usize = 0;

var s_goto_in_step: i32 = ROOM_NONE;
var s_restart_in_step: bool = false;
var s_end_in_step: bool = false;
var s_spawn_in_alarm: bool = false;
var s_destroy_in_step: bool = false;
var s_safe_points: usize = 0;

fn logEv(self: ?*Instance, other: ?*Instance, what: i32, number: i32) void {
    if (s_log_count < LOG_MAX) {
        s_log[s_log_count] = .{
            .what = what,
            .id = if (self) |s| s.id else -1,
            .other = if (other) |o| o.id else -1,
            .view = ViewManager.get().current(),
            .number = number,
        };
        s_log_count += 1;
    }
}

fn countOf(what: i32, id: i32) usize {
    var n: usize = 0;
    for (0..s_log_count) |i| {
        if (s_log[i].what == what and (id < 0 or s_log[i].id == id)) {
            n += 1;
        }
    }
    return n;
}

fn first(what: i32, id: i32) isize {
    for (0..s_log_count) |i| {
        if (s_log[i].what == what and (id < 0 or s_log[i].id == id)) {
            return @intCast(i);
        }
    }
    return -1;
}

// Handlers
fn ev_begin(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_BEGIN, 0);
}
fn ev_end(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_END, 0);
}
fn ev_anim(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_ANIM, 0);
}
fn ev_outside(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_OUTSIDE, 0);
}
fn ev_coll(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_COLL, 0);
}
fn ev_draw_begin(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_DRAW_BEGIN, 0);
}
fn ev_draw(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_DRAW, 0);
}
fn ev_draw_end(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_DRAW_END, 0);
}
fn ev_pre(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_PRE, 0);
}
fn ev_post(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_POST, 0);
}
fn ev_gui_begin(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_GUI_BEGIN, 0);
}
fn ev_gui(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_GUI, 0);
}
fn ev_gui_end(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_GUI_END, 0);
}
fn ev_room_start(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_ROOM_START, 0);
}
fn ev_pers_step(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_PERS_STEP, 0);
}
fn ev_key_a(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_KEY, 65);
}
fn ev_key_any(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_KEY, 1);
}
fn ev_key_none(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_KEY, 0);
}
fn ev_create(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_CREATE, 0);
}

fn ev_step(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_STEP, 0);
    if (s_goto_in_step != ROOM_NONE) {
        _ = RoomManager.get().roomGoto(s_goto_in_step);
        s_goto_in_step = ROOM_NONE;
    }
    if (s_restart_in_step) {
        s_restart_in_step = false;
        RoomManager.get().gameRestart();
    }
    if (s_end_in_step) {
        RoomManager.get().gameEnd();
    }
    if (s_destroy_in_step) {
        InstanceManager.get().destroy(s);
    }
}

fn ev_alarm0(s: *Instance, o: ?*Instance) void {
    logEv(s, o, L_ALARM0, 0);
    if (s_spawn_in_alarm) {
        const n = InstanceManager.get().create(O_A, 0.0, 0.0);
        s_spawn_in_alarm = false;
        if (n) |inst| {
            inst.alarms[0] = 1.0;
        }
    }
}

const EvDef = struct {
    object: i32,
    type: i32,
    number: i32,
    fn_ptr: EventFn,
};

const s_events = [_]EvDef{
    .{ .object = O_A, .type = EV_TYPE_ALARM, .number = 0, .fn_ptr = ev_alarm0 },
    .{ .object = O_A, .type = EV_TYPE_STEP, .number = EV_STEP_NORMAL, .fn_ptr = ev_step },
    .{ .object = O_A, .type = EV_TYPE_STEP, .number = EV_STEP_BEGIN, .fn_ptr = ev_begin },
    .{ .object = O_A, .type = EV_TYPE_STEP, .number = EV_STEP_END, .fn_ptr = ev_end },
    .{ .object = O_A, .type = EV_TYPE_COLLISION, .number = O_WALL, .fn_ptr = ev_coll },
    .{ .object = O_A, .type = EV_TYPE_OTHER, .number = EV_OTHER_OUTSIDE, .fn_ptr = ev_outside },
    .{ .object = O_A, .type = EV_TYPE_OTHER, .number = EV_OTHER_ANIMATION_END, .fn_ptr = ev_anim },
    .{ .object = O_A, .type = EV_TYPE_OTHER, .number = 4, .fn_ptr = ev_room_start },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_NORMAL, .fn_ptr = ev_draw },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_BEGIN, .fn_ptr = ev_draw_begin },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_END, .fn_ptr = ev_draw_end },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_PRE, .fn_ptr = ev_pre },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_POST, .fn_ptr = ev_post },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_GUI_BEGIN, .fn_ptr = ev_gui_begin },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_GUI, .fn_ptr = ev_gui },
    .{ .object = O_A, .type = EV_TYPE_DRAW, .number = EV_DRAW_GUI_END, .fn_ptr = ev_gui_end },
    .{ .object = O_B, .type = EV_TYPE_COLLISION, .number = O_WALL, .fn_ptr = ev_coll },
    .{ .object = O_WALL, .type = EV_TYPE_COLLISION, .number = O_A, .fn_ptr = ev_coll },
    .{ .object = O_KEY, .type = EV_TYPE_KEYPRESS, .number = 0, .fn_ptr = ev_key_none },
    .{ .object = O_KEY, .type = EV_TYPE_KEYPRESS, .number = 1, .fn_ptr = ev_key_any },
    .{ .object = O_KEY, .type = EV_TYPE_KEYPRESS, .number = 65, .fn_ptr = ev_key_a },
    .{ .object = O_SELF, .type = EV_TYPE_COLLISION, .number = O_SELF, .fn_ptr = ev_coll },
    .{ .object = O_PERS, .type = EV_TYPE_STEP, .number = EV_STEP_NORMAL, .fn_ptr = ev_pers_step },
};

fn findOwn(object: i32, ev_type: i32, number: i32) ?EventFn {
    for (s_events) |e| {
        if (e.object == object and e.type == ev_type and e.number == number) {
            return e.fn_ptr;
        }
    }
    return null;
}

fn findInherited(object: i32, ev_type: i32, number: i32) ?EventFn {
    var cur = object;
    const reg = ObjectRegistry.get();
    while (cur != OBJECT_NONE) {
        if (findOwn(cur, ev_type, number)) |f| {
            return f;
        }
        cur = reg.getParent(cur);
    }
    return null;
}

fn loopDrawSelf(inst: *Instance) void {
    logEv(inst, null, L_DRAW_SELF, 0);
}

fn loopSafePoint() void {
    s_safe_points += 1;
}

const s_hooks = LoopHooks{
    .find_event = findInherited,
    .find_own_event = findOwn,
    .draw_self = loopDrawSelf,
    .safe_point = loopSafePoint,
};

fn roomPerform(inst: *Instance, ev_type: i32, number: i32) void {
    if (findInherited(inst.object_index, ev_type, number)) |f| {
        f(inst, inst);
    }
}

const s_room_hooks = RoomHooks{
    .perform = roomPerform,
    .room_begin = null,
};

var s_objs: [O_COUNT]ObjectDef = undefined;
var s_sprites: [1]SpriteDef = undefined;

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

fn viewOn(x: i32) RoomViewDef {
    return RoomViewDef{
        .visible = true,
        .xview = x,
        .yview = 0,
        .wview = 320,
        .hview = 240,
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
}

const s_layers = [_]RoomLayerDef{
    .{ .name = "Instances", .id = 1, .kind = LAYER_INSTANCES, .depth = 0, .visible = true },
};

const s_insts0 = [_]RoomInstDef{
    .{ .id = 100000, .object = O_A, .x = 32, .y = 32, .xscale = 1, .yscale = 1, .angle = 0, .colour = 0xffffffff, .image_index = 0, .image_speed = 1, .layer = 0, .code = null },
    .{ .id = 100001, .object = O_PERS, .x = 0, .y = 0, .xscale = 1, .yscale = 1, .angle = 0, .colour = 0xffffffff, .image_index = 0, .image_speed = 1, .layer = 0, .code = null },
};

const R0: i32 = 0;
const R1: i32 = 1;
const R2: i32 = 2;
const R_COUNT: usize = 3;

fn makeR2Views() [8]RoomViewDef {
    var v = [_]RoomViewDef{VIEW_OFF} ** 8;
    v[0] = viewOn(0);
    v[2] = viewOn(100);
    return v;
}

const s_rooms = [_]RoomDef{
    .{
        .name = "r0",
        .width = 320,
        .height = 240,
        .speed = 30,
        .persistent = false,
        .enable_views = false,
        .views = [_]RoomViewDef{VIEW_OFF} ** 8,
        .layer_count = 1,
        .layers = &s_layers,
        .instance_count = 2,
        .instances = &s_insts0,
    },
    .{
        .name = "r1",
        .width = 320,
        .height = 240,
        .speed = 30,
        .persistent = false,
        .enable_views = false,
        .views = [_]RoomViewDef{VIEW_OFF} ** 8,
    },
    .{
        .name = "r2",
        .width = 640,
        .height = 480,
        .speed = 30,
        .persistent = false,
        .enable_views = true,
        .views = makeR2Views(),
    },
};

const s_order = [_]i32{ R0, R1, R2 };

fn resetSwitches() void {
    s_log_count = 0;
    s_goto_in_step = ROOM_NONE;
    s_restart_in_step = false;
    s_end_in_step = false;
    s_spawn_in_alarm = false;
    s_destroy_in_step = false;
    s_safe_points = 0;
}

fn setup(rooms: bool) void {
    for (0..O_COUNT) |i| {
        s_objs[i] = .{
            .name = "obj",
            .parent_index = OBJECT_NONE,
            .default_sprite = 0,
            .default_mask = -1,
            .default_visible = true,
        };
    }
    s_objs[@intCast(O_B)].parent_index = O_A;
    s_objs[@intCast(O_PLAIN)].default_sprite = -1;
    s_objs[@intCast(O_PERS)].default_persistent = true;

    s_sprites[0] = .{
        .name = "spr",
        .width = 16,
        .height = 16,
        .bbox_left = 0,
        .bbox_top = 0,
        .bbox_right = 15,
        .bbox_bottom = 15,
        .colcheck = .aabb,
        .frame_count = 4,
    };

    _ = SpriteRegistry.get().initRegistry(&s_sprites);
    _ = ObjectRegistry.get().initRegistry(&s_objs);
    collision_mod.configureGrid(320.0, 240.0, 32.0);
    InstanceManager.get().reset();
    InputManager.get().reset();
    RoomManager.get().setHooks(s_room_hooks);

    if (rooms) {
        _ = RoomManager.get().registryInit(&s_rooms, &s_order);
    } else {
        _ = RoomManager.get().registryInit(null, null);
    }

    LayerManager.get().reset();
    ViewManager.get().reset();
    DrawManager.get().reset();
    _ = LoopManager.get().init(s_hooks);
    // These tests cover the full GameMaker draw pipeline (events + layers).
    LoopManager.get().use_alt_draw = false;
    resetSwitches();
}

fn add(obj: i32, x: f32, y: f32) *Instance {
    return InstanceManager.get().create(obj, x, y).?;
}

// ---- Unit Tests ----

test "C Parity: test_collision_pairs" {
    setup(false);
    const lm = LoopManager.get();
    try std.testing.expectEqual(@as(usize, 3), lm.pairCount());

    var a: i32 = 0;
    var b: i32 = 0;
    try std.testing.expect(lm.pair(0, &a, &b) and a == O_A and b == O_WALL);
    try std.testing.expect(lm.pair(1, &a, &b) and a == O_B and b == O_WALL);
    try std.testing.expect(lm.pair(2, &a, &b) and a == O_SELF and b == O_SELF);
    try std.testing.expect(!lm.pair(3, &a, &b));

    var bad = s_hooks;
    bad.find_own_event = null;
    try std.testing.expect(!lm.init(bad));
    try std.testing.expectEqual(@as(usize, 0), lm.pairCount());
}

test "C Parity: test_phase_order" {
    setup(false);
    const inst1 = add(O_A, 100, 100);
    const inst2 = add(O_A, 200, 100);
    inst1.alarms[0] = 1.0;
    inst2.alarms[0] = 1.0;

    LoopManager.get().step();

    // Begin Step, Step and End Step from the end of the active list; alarms forward.
    try std.testing.expect(first(L_BEGIN, inst2.id) < first(L_BEGIN, inst1.id));
    try std.testing.expect(first(L_ALARM0, inst1.id) < first(L_ALARM0, inst2.id));
    try std.testing.expect(first(L_STEP, inst2.id) < first(L_STEP, inst1.id));
    try std.testing.expect(first(L_END, inst2.id) < first(L_END, inst1.id));
    try std.testing.expect(first(L_BEGIN, inst1.id) < first(L_ALARM0, inst1.id));
    try std.testing.expect(first(L_ALARM0, inst2.id) < first(L_STEP, inst2.id));
    try std.testing.expect(first(L_STEP, inst1.id) < first(L_END, inst2.id));
    try std.testing.expect(first(L_END, inst1.id) < first(L_PRE, -1));
    try std.testing.expect(first(L_PRE, -1) < first(L_DRAW_BEGIN, -1));
    try std.testing.expect(first(L_DRAW_BEGIN, inst1.id) < first(L_DRAW, -1));
    try std.testing.expect(first(L_DRAW, inst1.id) < first(L_DRAW_END, -1));
    try std.testing.expect(first(L_DRAW_END, inst1.id) < first(L_POST, -1));
    try std.testing.expect(first(L_POST, inst1.id) < first(L_GUI_BEGIN, -1));
    try std.testing.expect(first(L_GUI_BEGIN, inst1.id) < first(L_GUI, -1));
    try std.testing.expect(first(L_GUI, inst1.id) < first(L_GUI_END, -1));

    // Same depth: the newer instance is drawn first.
    try std.testing.expect(first(L_DRAW, inst2.id) < first(L_DRAW, inst1.id));
    try std.testing.expectEqual(@as(usize, 1), LoopManager.get().frameCount());
}

test "C Parity: test_alarms" {
    setup(false);
    const a = add(O_A, 0, 0);
    const plain = add(O_PLAIN, 0, 0);
    a.alarms[0] = 3.0;
    a.alarms[1] = 2.0; // no Alarm 1 handler: never ticks
    plain.alarms[0] = 2.0; // no handler at all

    for (0..2) |_| {
        LoopManager.get().step();
    }
    try std.testing.expectEqual(@as(usize, 0), countOf(L_ALARM0, a.id));
    try std.testing.expectEqual(@as(f32, 1.0), a.alarms[0]);
    try std.testing.expectEqual(@as(f32, 2.0), a.alarms[1]);
    try std.testing.expectEqual(@as(f32, 2.0), plain.alarms[0]);

    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 1), countOf(L_ALARM0, a.id));
    try std.testing.expectEqual(@as(f32, 0.0), a.alarms[0]);

    LoopManager.get().step();
    try std.testing.expectEqual(@as(f32, -1.0), a.alarms[0]);

    LoopManager.get().step();
    try std.testing.expectEqual(@as(f32, -1.0), a.alarms[0]);
    try std.testing.expectEqual(@as(usize, 1), countOf(L_ALARM0, a.id));

    // Fractions truncate (~~alarm); an instance made in the pass waits for the next.
    a.alarms[0] = 1.9;
    s_spawn_in_alarm = true;
    s_log_count = 0;
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 1), countOf(L_ALARM0, a.id));
    try std.testing.expectEqual(@as(usize, 1), countOf(L_ALARM0, -1)); // new A skipped

    s_log_count = 0;
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 1), countOf(L_ALARM0, -1)); // now its 1 -> 0 fires
    try std.testing.expectEqual(@as(usize, 0), countOf(L_ALARM0, a.id));
}

test "C Parity: test_animation_end" {
    setup(false);
    const a = add(O_A, 0, 0);
    const plain = add(O_PLAIN, 0, 0);
    plain.image_speed = 0.5;
    a.image_speed = 1.0;

    for (0..3) |_| {
        LoopManager.get().step();
    }
    try std.testing.expectEqual(@as(f32, 3.0), a.image_index);
    try std.testing.expectEqual(@as(usize, 0), countOf(L_ANIM, a.id));

    LoopManager.get().step();
    try std.testing.expectEqual(@as(f32, 0.0), a.image_index);
    try std.testing.expectEqual(@as(usize, 1), countOf(L_ANIM, a.id));
    try std.testing.expectEqual(@as(f32, 2.0), plain.image_index); // no sprite: image_speed added

    a.image_speed = -1.0;
    LoopManager.get().step();
    try std.testing.expectEqual(@as(f32, 3.0), a.image_index);
    try std.testing.expectEqual(@as(usize, 2), countOf(L_ANIM, a.id));

    // An A without a sprite has 0 frames: Animation End every step
    const nosprite = add(O_A, 0, 0);
    nosprite.sprite_index = -1;
    nosprite.image_speed = 0.0;
    s_log_count = 0;
    LoopManager.get().step();
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 2), countOf(L_ANIM, nosprite.id));
}

test "C Parity: test_motion" {
    setup(false);
    const g = add(O_PLAIN, 10, 10);
    g.gravity = 0.5;
    g.gravity_direction = 270.0;

    LoopManager.get().step();
    try std.testing.expectEqual(@as(f32, 0.0), g.hspeed);
    try std.testing.expectEqual(@as(f32, 270.0), g.direction);
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), g.vspeed, 1e-4);
    try std.testing.expectApproxEqAbs(g.vspeed, g.speed, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 10.5), g.y, 1e-4);
    try std.testing.expectEqual(@as(f32, 10.0), g.yprevious);

    LoopManager.get().step();
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), g.vspeed, 1e-4);
    try std.testing.expectApproxEqAbs(@as(f32, 11.5), g.y, 1e-4);

    const f = add(O_PLAIN, 0, 0);
    f.setHspeed(1.0);
    f.friction = 0.4;
    for (0..4) |_| {
        LoopManager.get().step();
    }
    try std.testing.expectEqual(@as(f32, 0.0), f.speed);
    try std.testing.expectEqual(@as(f32, 0.0), f.hspeed);
    try std.testing.expectApproxEqAbs(@as(f32, 0.8), f.x, 1e-4);
}

test "C Parity: test_outside_room_fires_once" {
    setup(false); // no room: 640 x 480
    const a = add(O_A, 620, 10);
    a.setHspeed(4.0);

    for (0..4) |_| {
        LoopManager.get().step(); // bbox_left 624, 628, 632, 636
    }
    try std.testing.expectEqual(@as(usize, 0), countOf(L_OUTSIDE, a.id));

    for (0..4) |_| {
        LoopManager.get().step(); // 640 still inside, left > width is outside
    }
    try std.testing.expectEqual(@as(usize, 1), countOf(L_OUTSIDE, a.id));
    try std.testing.expect(a.outside_room);

    a.setHspeed(-40.0);
    LoopManager.get().step();
    a.setHspeed(40.0);
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 2), countOf(L_OUTSIDE, a.id));
}

test "C Parity: test_collisions" {
    setup(false);
    const a = add(O_A, 100, 100);
    const wall = add(O_WALL, 108, 100);

    LoopManager.get().step();
    // Pair (A, WALL): both sides' events, self/other set.
    try std.testing.expectEqual(@as(usize, 2), countOf(L_COLL, -1));
    try std.testing.expectEqual(wall.id, s_log[@intCast(first(L_COLL, a.id))].other);
    try std.testing.expectEqual(a.id, s_log[@intCast(first(L_COLL, wall.id))].other);
    try std.testing.expect(first(L_COLL, a.id) < first(L_COLL, wall.id));

    // Solid: both go back to their previous positions.
    wall.solid = true;
    a.setHspeed(2.0);
    s_log_count = 0;
    LoopManager.get().step();
    try std.testing.expectEqual(@as(f32, 100.0), a.x);
    try std.testing.expectEqual(@as(f32, 108.0), wall.x);
    try std.testing.expectEqual(@as(usize, 2), countOf(L_COLL, -1));

    // A B instance (child of A) is in A's pool and in its own pair (B, WALL): twice.
    InstanceManager.get().destroy(a);
    LoopManager.get().step();
    const b = add(O_B, 100, 100);
    wall.solid = false;
    s_log_count = 0;
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 2), countOf(L_COLL, b.id));
    try std.testing.expectEqual(@as(usize, 2), countOf(L_COLL, wall.id));

    // Same-object pair: each overlapping couple once, both directions.
    InstanceManager.get().destroy(b);
    const s1 = add(O_SELF, 300, 300);
    const s2 = add(O_SELF, 304, 300);
    s_log_count = 0;
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 1), countOf(L_COLL, s1.id));
    try std.testing.expectEqual(@as(usize, 1), countOf(L_COLL, s2.id));
}

test "C Parity: test_room_change_ends_the_step" {
    setup(true);
    try std.testing.expect(RoomManager.get().startGame());
    const a = InstanceManager.get().findById(100000);
    try std.testing.expect(a != null);

    s_log_count = 0;
    s_goto_in_step = R1;
    LoopManager.get().step();
    try std.testing.expectEqual(R1, RoomManager.get().pending());
    try std.testing.expectEqual(@as(usize, 1), countOf(L_STEP, -1));

    // The persistent instance is at the end of the list, so its Step ran first;
    // nothing after the Step phase ran.
    try std.testing.expectEqual(@as(usize, 1), countOf(L_PERS_STEP, -1));
    try std.testing.expectEqual(@as(usize, 0), countOf(L_END, -1));
    try std.testing.expectEqual(@as(usize, 0), countOf(L_DRAW, -1));
    try std.testing.expectEqual(a, InstanceManager.get().findById(100000));

    // tick: switch, then a whole step in the new room; one safe point.
    _ = RoomManager.get().roomGoto(R0);
    _ = RoomManager.get().switchPending();
    s_log_count = 0;
    s_goto_in_step = R1;
    try std.testing.expectEqual(LoopStatus.running, LoopManager.get().tick());
    try std.testing.expectEqual(R1, RoomManager.get().current());
    try std.testing.expectEqual(ROOM_NONE, RoomManager.get().pending());
    try std.testing.expectEqual(@as(usize, 2), countOf(L_PERS_STEP, -1));
    try std.testing.expectEqual(@as(usize, 1), s_safe_points);
}

test "C Parity: test_gate_skips_non_persistent_after_goto" {
    setup(false);
    _ = add(O_A, 0, 0);
    const a2 = add(O_A, 0, 0); // runs Step first (end of list) and queues a room
    RoomManager.get().setHooks(s_room_hooks);
    _ = RoomManager.get().registryInit(&s_rooms, &s_order);
    s_goto_in_step = R1;
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 1), countOf(L_STEP, a2.id));
    try std.testing.expectEqual(@as(usize, 0), countOf(L_STEP, 100000)); // gate skips
}

test "C Parity: test_restart_and_end" {
    setup(true);
    try std.testing.expect(RoomManager.get().startGame());
    _ = RoomManager.get().roomGoto(R1);
    _ = RoomManager.get().switchPending();
    try std.testing.expect(InstanceManager.get().findById(100001) != null); // persistent

    _ = InstanceManager.get().create(O_PLAIN, 0, 0);
    const next_id = InstanceManager.get().nextId();

    // game_restart from a Step: every instance goes, r0 starts again
    _ = RoomManager.get().roomGoto(R0);
    _ = RoomManager.get().switchPending();
    s_restart_in_step = true;
    s_log_count = 0;
    try std.testing.expectEqual(LoopStatus.running, LoopManager.get().tick());
    try std.testing.expectEqual(R0, RoomManager.get().current());
    try std.testing.expectEqual(@as(usize, 2), InstanceManager.get().activeCount());
    try std.testing.expect(InstanceManager.get().findById(100000) != null);
    try std.testing.expect(InstanceManager.get().findById(100001) != null);
    try std.testing.expect(InstanceManager.get().nextId() >= next_id);

    s_end_in_step = true;
    try std.testing.expectEqual(LoopStatus.ended, LoopManager.get().tick());
    try std.testing.expectEqual(ROOM_END_GAME, RoomManager.get().pending());
    try std.testing.expect(RoomManager.get().eventBlocked(InstanceManager.get().findById(100000), EV_TYPE_STEP));
}

test "C Parity: test_keyboard_state" {
    setup(false);
    const im = InputManager.get();
    try std.testing.expect(!im.check(65));
    im.keyDown(65);
    im.keyDown(65); // repeat
    im.startStep();
    try std.testing.expect(im.check(65) and im.checkPressed(65) and !im.checkReleased(65));
    try std.testing.expect(im.check(VK_ANYKEY) and !im.check(VK_NOKEY));
    try std.testing.expectEqual(@as(i32, 65), im.getKeyboardKey());

    im.startStep();
    try std.testing.expect(im.check(65) and !im.checkPressed(65));
    im.keyUp(65);
    im.startStep();
    try std.testing.expect(!im.check(65) and im.checkReleased(65));
    try std.testing.expect(im.check(VK_NOKEY) and im.checkReleased(VK_ANYKEY));
    try std.testing.expectEqual(@as(i32, 0), im.getKeyboardKey());
    try std.testing.expectEqual(@as(i32, 65), im.getKeyboardLastkey());

    // Down and up between steps: pressed and released in same step
    im.keyDown(66);
    im.keyUp(66);
    im.startStep();
    try std.testing.expect(im.checkPressed(66) and im.checkReleased(66) and !im.check(66));

    // Mapping
    im.setMap(89, 90);
    im.keyDown(89);
    im.startStep();
    try std.testing.expect(im.check(90) and im.checkPressed(90) and !im.check(89));
    im.clear(90);
    try std.testing.expect(!im.check(90));
    try std.testing.expect(!im.check(-1) and !im.check(256));
}

test "C Parity: test_key_press_events" {
    setup(false);
    const k = add(O_KEY, 0, 0);
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 1), countOf(L_KEY, k.id)); // NOKEY
    try std.testing.expectEqual(@as(i32, 0), s_log[@intCast(first(L_KEY, k.id))].number);

    s_log_count = 0;
    InputManager.get().keyDown(65);
    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 2), countOf(L_KEY, k.id)); // 'A', then ANYKEY
    try std.testing.expectEqual(@as(i32, 65), s_log[0].number);
    try std.testing.expectEqual(@as(i32, 1), s_log[1].number);

    s_log_count = 0;
    LoopManager.get().step(); // held: no press, NOKEY
    try std.testing.expectEqual(@as(usize, 1), countOf(L_KEY, k.id));
    try std.testing.expectEqual(@as(i32, 0), s_log[0].number);

    s_log_count = 0;
    LoopManager.get().eventPerform(k, null, EV_TYPE_KEYPRESS, 65);
    try std.testing.expectEqual(@as(usize, 1), s_log_count);
    try std.testing.expectEqual(@as(i32, 65), s_log[0].number);
    try std.testing.expectEqual(@as(i32, -1), s_log[0].other);

    LoopManager.get().eventPerform(k, k, EV_TYPE_KEYPRESS, 66);
    try std.testing.expectEqual(@as(usize, 1), s_log_count);
}

test "C Parity: test_destroyed_instances_are_reclaimed_before_draw" {
    setup(false);
    const a = add(O_A, 0, 0);
    const id = a.id;
    s_destroy_in_step = true;

    LoopManager.get().step();
    try std.testing.expect(InstanceManager.get().findById(id) == null);
    try std.testing.expectEqual(@as(usize, 0), countOf(L_END, id));
    try std.testing.expectEqual(@as(usize, 0), countOf(L_DRAW, id));
}

test "C Parity: test_sixty_frames" {
    setup(false);
    const a = add(O_A, 50, 50);
    const b = add(O_B, 400, 50);
    a.alarms[0] = 10.0;

    for (0..60) |_| {
        if (a.alarms[0] < 0.0) {
            a.alarms[0] = 10.0;
        }
        LoopManager.get().step();
    }

    try std.testing.expectEqual(@as(usize, 60), LoopManager.get().frameCount());
    try std.testing.expectEqual(@as(usize, 60), countOf(L_BEGIN, a.id));
    try std.testing.expectEqual(@as(usize, 60), countOf(L_STEP, b.id)); // inherited from A
    try std.testing.expectEqual(@as(usize, 60), countOf(L_END, a.id));
    try std.testing.expectEqual(@as(usize, 60), countOf(L_DRAW, b.id));
    try std.testing.expectEqual(@as(usize, 15), countOf(L_ANIM, a.id)); // 4 frames, speed 1
    try std.testing.expectEqual(@as(usize, 5), countOf(L_ALARM0, a.id)); // frames 10, 21, 32, 43, 54
    try std.testing.expectEqual(@as(usize, 0), countOf(L_COLL, -1));
}

test "OPT-4: static vs dynamic partitioning and promotion" {
    setup(false);
    ObjectRegistry.get().setStatic(O_WALL, true);
    defer ObjectRegistry.get().setStatic(O_WALL, false);

    const inst_dyn = add(O_A, 100, 100);
    const inst_stat = add(O_WALL, 200, 200);

    const mgr = InstanceManager.get();
    try std.testing.expectEqual(@as(usize, 2), mgr.activeCount());
    try std.testing.expectEqual(@as(usize, 1), mgr.dynamicCount());
    try std.testing.expectEqual(@as(usize, 1), mgr.staticCount());

    try std.testing.expect(inst_dyn.is_dynamic);
    try std.testing.expect(!inst_stat.is_dynamic);
    try std.testing.expectEqual(inst_dyn, mgr.dynamicAt(0).?);
    try std.testing.expectEqual(inst_stat, mgr.staticAt(0).?);

    LoopManager.get().step();
    try std.testing.expectEqual(@as(usize, 1), countOf(L_BEGIN, inst_dyn.id));
    try std.testing.expectEqual(@as(usize, 0), countOf(L_BEGIN, inst_stat.id));

    // Draw scratch includes both dynamic and static
    var scratch: [16]*Instance = undefined;
    const draw_n = mgr.drawOrder(&scratch);
    try std.testing.expectEqual(@as(usize, 2), draw_n);

    // Promotion: setting motion on static promotes it to dynamic
    inst_stat.setHspeed(2.0);
    try std.testing.expect(inst_stat.is_dynamic);
    try std.testing.expectEqual(@as(usize, 2), mgr.dynamicCount());
    try std.testing.expectEqual(@as(usize, 0), mgr.staticCount());

    // Deactivation and reactivation maintain dynamic list
    mgr.deactivate(inst_stat);
    try std.testing.expectEqual(@as(usize, 1), mgr.dynamicCount());
    try std.testing.expectEqual(@as(usize, 1), mgr.activeCount());

    mgr.activate(inst_stat);
    try std.testing.expectEqual(@as(usize, 2), mgr.dynamicCount());
    try std.testing.expectEqual(@as(usize, 2), mgr.activeCount());
}

