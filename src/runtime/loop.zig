//! GameMaker frame pipeline (GameMaker_Tick and GameMaker_DoAStep).
//! Follows _GameMaker.js, Events.js, yyInstance.js, and packaged_src/src/runtime/gm_loop.c.
//! Operates completely headlessly when no video/audio hardware is attached.

const std = @import("std");
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;
const MAX_INSTANCES = instance_mod.MAX_INSTANCES;
const object_mod = @import("object.zig");
const ObjectRegistry = object_mod.ObjectRegistry;
const EventFn = object_mod.EventFn;
const MAX_OBJECTS = object_mod.MAX_OBJECTS;
const OBJECT_NONE = object_mod.OBJECT_NONE;
const room_mod = @import("room.zig");
const RoomManager = room_mod.RoomManager;
const ROOM_NONE = room_mod.ROOM_NONE;
const ROOM_END_GAME = room_mod.ROOM_END_GAME;
const ROOM_RESTART_GAME = room_mod.ROOM_RESTART_GAME;
const layer_mod = @import("layer.zig");
const LayerManager = layer_mod.LayerManager;
const view_mod = @import("view.zig");
const ViewManager = view_mod.ViewManager;
const ViewField = view_mod.ViewField;
const VIEW_COUNT = view_mod.VIEW_COUNT;
const collision_mod = @import("collision.zig");
const input_mod = @import("input.zig");
const InputManager = input_mod.InputManager;
const VK_NOKEY = input_mod.VK_NOKEY;
const VK_ANYKEY = input_mod.VK_ANYKEY;
const MAX_KEYS = input_mod.MAX_KEYS;
const draw_mod = @import("draw.zig");
const DrawManager = draw_mod.DrawManager;
const sprite_mod = @import("sprite.zig");
const math_mod = @import("math.zig");
const profile = @import("profile.zig");
const draw_alt = @import("draw_alt.zig");
const SpriteRegistry = sprite_mod.SpriteRegistry;

pub const EV_TYPE_ALARM: i32 = 2;
pub const EV_TYPE_STEP: i32 = 3;
pub const EV_TYPE_COLLISION: i32 = 4;
pub const EV_TYPE_KEYBOARD: i32 = 5;
pub const EV_TYPE_OTHER: i32 = 7;
pub const EV_TYPE_DRAW: i32 = 8;
pub const EV_TYPE_KEYPRESS: i32 = 9;
pub const EV_TYPE_KEYRELEASE: i32 = 10;

pub const EV_STEP_NORMAL: i32 = 0;
pub const EV_STEP_BEGIN: i32 = 1;
pub const EV_STEP_END: i32 = 2;

pub const EV_OTHER_OUTSIDE: i32 = 0;
pub const EV_OTHER_BOUNDARY: i32 = 1;
pub const EV_OTHER_ANIMATION_END: i32 = 7;

pub const EV_DRAW_NORMAL: i32 = 0;
pub const EV_DRAW_GUI: i32 = 64;
pub const EV_DRAW_BEGIN: i32 = 72;
pub const EV_DRAW_END: i32 = 73;
pub const EV_DRAW_GUI_BEGIN: i32 = 74;
pub const EV_DRAW_GUI_END: i32 = 75;
pub const EV_DRAW_PRE: i32 = 76;
pub const EV_DRAW_POST: i32 = 77;

pub const MAX_PAIRS: usize = 1024;
pub const MAX_STEPS_PER_TICK: usize = 10;

pub const LoopStatus = enum {
    running,
    ended,
};

pub const LoopHooks = struct {
    find_event: ?*const fn (object_index: i32, ev_type: i32, ev_number: i32) ?EventFn = null,
    find_own_event: ?*const fn (object_index: i32, ev_type: i32, ev_number: i32) ?EventFn = null,
    draw_self: ?*const fn (inst: *Instance) void = null,
    safe_point: ?*const fn () void = null,
};

pub const Pair = struct {
    a: i32 = 0,
    b: i32 = 0,
    handler_a: ?EventFn = null,
    handler_b: ?EventFn = null,
};

pub const ObjectFlags = packed struct(u8) {
    has_step_begin: bool = false,
    has_step: bool = false,
    has_step_end: bool = false,
    has_alarms: bool = false,
    has_keyboard: bool = false,
    has_outside: bool = false,
    is_static: bool = false,
    _pad: u1 = 0,
};

/// Inherited handlers of the per-step events, resolved once per object in
/// `init` so the step phases call them directly (no find_event per instance).
pub const ObjectHandlers = struct {
    step_begin: ?EventFn = null,
    step: ?EventFn = null,
    step_end: ?EventFn = null,
    outside: ?EventFn = null,
    boundary: ?EventFn = null,
    anim_end: ?EventFn = null,
    draw: ?EventFn = null,
    draw_gui: ?EventFn = null,
};

const no_handlers: ObjectHandlers = .{};

/// Whether any object has the event: phases nobody listens to are skipped
/// without walking the instance list.
const AnyHandlers = struct {
    step_begin: bool = false,
    step: bool = false,
    step_end: bool = false,
    alarms: bool = false,
    other: bool = false,
};

const StepKind = enum { step_begin, step, step_end };

pub const DrawLayerFilter = struct {
    static_background: bool = true,
    static_foreground: bool = true,
    dynamic_actors: bool = true,
    gui: bool = true,
    bg_depth_threshold: f32 = 1000.0,
    cull_offscreen: bool = true,
};

pub const LoopManager = struct {
    hooks: ?LoopHooks = null,
    pairs: [MAX_PAIRS]Pair = [_]Pair{.{}} ** MAX_PAIRS,
    pair_count: usize = 0,
    is_draw_enabled: bool = true,
    total_frames: usize = 0,
    has_key_type: [3]bool = [_]bool{false} ** 3,
    has_draw: [8]bool = [_]bool{false} ** 8,
    draw_skip_enabled: bool = false,
    draw_skip: bool = false,
    draw_filter: DrawLayerFilter = .{},
    /// Use the simplified depth-ordered pipeline in draw_alt.zig.
    use_alt_draw: bool = true,
    obj_flags: [MAX_OBJECTS]ObjectFlags = [_]ObjectFlags{.{}} ** MAX_OBJECTS,
    /// Bit a set = the object has an Alarm a handler.
    alarm_handlers: [MAX_OBJECTS]u16 = [_]u16{0} ** MAX_OBJECTS,
    handlers: [MAX_OBJECTS]ObjectHandlers = [_]ObjectHandlers{.{}} ** MAX_OBJECTS,
    any: AnyHandlers = .{},

    draw_scratch: [MAX_INSTANCES]*Instance = undefined,

    var instance: LoopManager = .{};

    pub fn get() *LoopManager {
        return &instance;
    }

    pub inline fn getFlags(self: *const LoopManager, object_index: i32) ObjectFlags {
        if (object_index >= 0 and object_index < MAX_OBJECTS) {
            return self.obj_flags[@intCast(object_index)];
        }
        return .{};
    }

    const draw_numbers = [_]i32{
        EV_DRAW_NORMAL, EV_DRAW_GUI,       EV_DRAW_BEGIN,
        EV_DRAW_END,    EV_DRAW_GUI_BEGIN, EV_DRAW_GUI_END,
        EV_DRAW_PRE,    EV_DRAW_POST,
    };

    fn listed(self: *const LoopManager, a: i32, b: i32) bool {
        for (0..self.pair_count) |i| {
            if (self.pairs[i].a == a and self.pairs[i].b == b) return true;
        }
        return false;
    }

    fn addCollision(self: *LoopManager, id1: i32, done: []bool, ok: *bool) void {
        const uid1: usize = @intCast(id1);
        if (done[uid1]) return;

        const reg = ObjectRegistry.get();
        const parent = reg.getParent(id1);
        if (parent != OBJECT_NONE) {
            self.addCollision(parent, done, ok);
        }

        const count: i32 = @intCast(reg.count);
        var id2: i32 = 0;
        while (id2 < count) : (id2 += 1) {
            if (self.hooks.?.find_own_event.?(id1, EV_TYPE_COLLISION, id2) == null or self.listed(id2, id1)) {
                continue;
            }
            var found = false;
            var check = id1;
            while (check != OBJECT_NONE and !found) : (check = reg.getParent(check)) {
                var check2 = id2;
                while (check2 != OBJECT_NONE) : (check2 = reg.getParent(check2)) {
                    if (self.listed(check2, check)) {
                        found = true;
                        break;
                    }
                }
            }
            if (!found) {
                if (self.pair_count >= MAX_PAIRS) {
                    ok.* = false;
                    return;
                }
                self.pairs[self.pair_count] = .{ .a = id1, .b = id2 };
                self.pair_count += 1;
            }
        }
        done[uid1] = true;
    }

    fn sortPairs(self: *LoopManager) void {
        if (self.pair_count < 2) return;
        var i: usize = 1;
        while (i < self.pair_count) : (i += 1) {
            const p = self.pairs[i];
            var j: isize = @as(isize, @intCast(i)) - 1;
            while (j >= 0) : (j -= 1) {
                const uj: usize = @intCast(j);
                if (self.pairs[uj].a > p.a or (self.pairs[uj].a == p.a and self.pairs[uj].b > p.b)) {
                    self.pairs[uj + 1] = self.pairs[uj];
                } else break;
            }
            const insert_idx: usize = @intCast(j + 1);
            self.pairs[insert_idx] = p;
        }
    }

    pub fn init(self: *LoopManager, hooks: LoopHooks) bool {
        self.hooks = null;
        self.pair_count = 0;
        self.total_frames = 0;
        self.is_draw_enabled = true;
        self.draw_skip_enabled = false;
        self.draw_skip = false;
        self.draw_filter = .{};

        if (hooks.find_event == null or hooks.find_own_event == null) {
            return false;
        }
        self.hooks = hooks;

        const reg = ObjectRegistry.get();
        const count: i32 = @intCast(reg.count);
        var done: [MAX_OBJECTS]bool = [_]bool{false} ** MAX_OBJECTS;
        var ok = true;

        var o: i32 = 0;
        while (o < count and ok) : (o += 1) {
            const parent = reg.getParent(o);
            if (parent != OBJECT_NONE) {
                self.addCollision(parent, &done, &ok);
            }
            self.addCollision(o, &done, &ok);
        }
        if (!ok) {
            self.hooks = null;
            self.pair_count = 0;
            return false;
        }
        self.sortPairs();
        for (self.pairs[0..self.pair_count]) |*p| {
            p.handler_a = self.findCollisionHandler(p.a, p.b);
            p.handler_b = self.findCollisionHandler(p.b, p.a);
        }

        for (0..8) |t| {
            self.has_draw[t] = false;
            var obj: i32 = 0;
            while (obj < count and !self.has_draw[t]) : (obj += 1) {
                self.has_draw[t] = hooks.find_event.?(obj, EV_TYPE_DRAW, draw_numbers[t]) != null;
            }
        }

        const key_types = [_]i32{ EV_TYPE_KEYBOARD, EV_TYPE_KEYPRESS, EV_TYPE_KEYRELEASE };
        for (0..3) |t| {
            self.has_key_type[t] = false;
            var obj: i32 = 0;
            while (obj < count and !self.has_key_type[t]) : (obj += 1) {
                for (0..MAX_KEYS) |k| {
                    if (hooks.find_own_event.?(obj, key_types[t], @intCast(k)) != null) {
                        self.has_key_type[t] = true;
                        break;
                    }
                }
            }
        }

        @memset(&self.obj_flags, .{});
        @memset(&self.alarm_handlers, 0);
        @memset(&self.handlers, .{});
        self.any = .{};
        var obj_i: i32 = 0;
        while (obj_i < count) : (obj_i += 1) {
            const fe = hooks.find_event.?;
            const hs: ObjectHandlers = .{
                .step_begin = fe(obj_i, EV_TYPE_STEP, EV_STEP_BEGIN),
                .step = fe(obj_i, EV_TYPE_STEP, EV_STEP_NORMAL),
                .step_end = fe(obj_i, EV_TYPE_STEP, EV_STEP_END),
                .outside = fe(obj_i, EV_TYPE_OTHER, EV_OTHER_OUTSIDE),
                .boundary = fe(obj_i, EV_TYPE_OTHER, EV_OTHER_BOUNDARY),
                .anim_end = fe(obj_i, EV_TYPE_OTHER, EV_OTHER_ANIMATION_END),
                .draw = fe(obj_i, EV_TYPE_DRAW, EV_DRAW_NORMAL),
                .draw_gui = fe(obj_i, EV_TYPE_DRAW, EV_DRAW_GUI),
            };
            self.handlers[@intCast(obj_i)] = hs;

            var flags: ObjectFlags = .{};
            flags.has_step_begin = hs.step_begin != null;
            flags.has_step = hs.step != null;
            flags.has_step_end = hs.step_end != null;

            var ah: u16 = 0;
            for (0..instance_mod.ALARM_COUNT) |a| {
                if (hooks.find_event.?(obj_i, EV_TYPE_ALARM, @intCast(a)) != null) {
                    ah |= @as(u16, 1) << @intCast(a);
                }
            }
            flags.has_alarms = ah != 0;
            self.alarm_handlers[@intCast(obj_i)] = ah;

            outer_key: for (0..3) |kt| {
                for (0..MAX_KEYS) |k| {
                    if (hooks.find_event.?(obj_i, key_types[kt], @intCast(k)) != null) {
                        flags.has_keyboard = true;
                        break :outer_key;
                    }
                }
            }

            flags.has_outside = hs.outside != null or hs.boundary != null;
            // The image and Other passes only visit dynamic instances.
            if (hs.anim_end != null or flags.has_outside or flags.has_keyboard) {
                reg.setStatic(obj_i, false);
            }
            flags.is_static = reg.isStatic(obj_i);

            self.obj_flags[@intCast(obj_i)] = flags;
            self.any.step_begin = self.any.step_begin or flags.has_step_begin;
            self.any.step = self.any.step or flags.has_step;
            self.any.step_end = self.any.step_end or flags.has_step_end;
            self.any.alarms = self.any.alarms or flags.has_alarms;
            self.any.other = self.any.other or flags.has_outside;
        }

        return true;
    }

    pub fn handler(self: *const LoopManager, inst: *const Instance, ev_type: i32, number: i32) ?EventFn {
        if (self.hooks) |h| {
            if (h.find_event) |fe| {
                return fe(inst.object_index, ev_type, number);
            }
        }
        return null;
    }

    fn perform(self: *LoopManager, inst: *Instance, ev_type: i32, number: i32) void {
        if (RoomManager.get().eventBlocked(inst, ev_type)) return;
        if (self.handler(inst, ev_type, number)) |fn_ptr| {
            fn_ptr(inst, inst);
        }
    }

    pub inline fn handlersOf(self: *const LoopManager, inst: *const Instance) *const ObjectHandlers {
        if (inst.object_index < 0 or inst.object_index >= MAX_OBJECTS) return &no_handlers;
        return &self.handlers[@intCast(inst.object_index)];
    }

    /// Begin Step / Step / End Step over the instance list (newest first, as
    /// the runner does), calling each object's cached handler directly.
    fn stepAll(self: *LoopManager, comptime kind: StepKind) void {
        if (!@field(self.any, @tagName(kind))) return;
        const mgr = InstanceManager.get();
        const rm = RoomManager.get();
        const pass = mgr.passBegin();
        const prof = profile.deepEnabled();
        var i = mgr.dynamicCount();
        while (i > 0) {
            i -= 1;
            if (i >= mgr.dynamicCount()) continue;
            const inst = mgr.dynamicAt(i) orelse continue;
            const fn_ptr = @field(self.handlersOf(inst), @tagName(kind)) orelse continue;
            if (inst.marked_for_destroy or !mgr.inPass(inst, pass) or rm.eventBlocked(inst, EV_TYPE_STEP)) continue;
            if (prof) {
                profile.count(.step_events, 1);
                // Read before the call: the event may change object_index.
                const obj = inst.object_index;
                const t0 = profile.start();
                fn_ptr(inst, inst);
                profile.stopObject(.step, obj, t0);
            } else {
                fn_ptr(inst, inst);
            }
        }
    }

    // The phases below re-read the active count every iteration, as C does:
    // instances created by an event fired mid-phase are visited too (unless
    // the pass filter excludes them).

    /// Fused pass: RememberOldPositions + Animate + UpdateImages
    /// (yyInstance.js L3443, L2203, L3602). Dynamic instances only: static
    /// ones never move by themselves, show a one-frame sprite and have no
    /// Animation End event (ObjectRegistry.classifyStaticObjects,
    /// LoopManager.init); collision.touch promotes one that changes.
    fn updateImagesAndPositions(self: *LoopManager) void {
        const mgr = InstanceManager.get();
        var i: usize = 0;
        while (i < mgr.dynamicCount()) : (i += 1) {
            const inst = mgr.dynamicAt(i) orelse continue;
            inst.xprevious = inst.x;
            inst.yprevious = inst.y;
            inst.image_index += inst.image_speed;
            if (inst.marked_for_destroy or !inst.active) continue;
            self.wrapImage(inst);
        }
    }

    /// Wrap image_index into the sprite's frames; on wrap, run the object's
    /// cached Animation End handler directly (no event lookup when absent).
    inline fn wrapImage(self: *const LoopManager, inst: *Instance) void {
        const spr = SpriteRegistry.get().getSprite(inst.sprite_index);
        const num: f32 = if (spr) |s| @floatFromInt(s.frame_count) else 0.0;
        if (inst.image_index >= num) {
            inst.image_index -= num;
        } else if (inst.image_index < 0.0) {
            inst.image_index += num;
        } else return;

        const fn_ptr = self.handlersOf(inst).anim_end orelse return;
        if (RoomManager.get().eventBlocked(inst, EV_TYPE_OTHER)) return;
        fn_ptr(inst, inst);
    }

    /// Alarms: the per-object mask says which alarms have a handler, so the
    /// handler is only looked up on the frame an alarm fires.
    fn handleAlarms(self: *LoopManager) void {
        if (!self.any.alarms) return;
        const mgr = InstanceManager.get();
        const rm = RoomManager.get();
        const pass = mgr.passBegin();

        var i: usize = 0;
        while (i < mgr.dynamicCount()) : (i += 1) {
            const inst = mgr.dynamicAt(i) orelse continue;
            if (inst.object_index < 0 or inst.object_index >= MAX_OBJECTS) continue;
            var mask = self.alarm_handlers[@intCast(inst.object_index)];
            if (mask == 0 or inst.marked_for_destroy or !mgr.inPass(inst, pass)) continue;

            while (mask != 0) {
                const a: usize = @ctz(mask);
                mask &= mask - 1;

                if (inst.alarms[a] < 0.0) continue;
                const al: i32 = math_mod.toInt32(inst.alarms[a]) - 1;
                inst.alarms[a] = @floatFromInt(al);
                if (al != 0 or rm.eventBlocked(inst, EV_TYPE_ALARM)) continue;
                if (self.handler(inst, EV_TYPE_ALARM, @intCast(a))) |fn_ptr| fn_ptr(inst, inst);
            }
        }
    }

    fn keyEvent(self: *LoopManager, ev_type: i32, key: i32, skip_marked: bool) void {
        const mgr = InstanceManager.get();
        const n = mgr.dynamicCount();
        for (0..n) |i| {
            const inst = mgr.dynamicAt(i) orelse continue;
            if (skip_marked and inst.marked_for_destroy) continue;
            if (!self.getFlags(inst.object_index).has_keyboard) continue;
            self.perform(inst, ev_type, key);
        }
    }

    fn handleKeyboard(self: *LoopManager) void {
        const im = InputManager.get();
        const types = [_]i32{ EV_TYPE_KEYBOARD, EV_TYPE_KEYPRESS, EV_TYPE_KEYRELEASE };

        for (0..3) |t| {
            if (!self.has_key_type[t]) continue;
            var any: i32 = VK_NOKEY;

            for (2..MAX_KEYS) |key| {
                const ikey: i32 = @intCast(key);
                const is_set = if (t == 0)
                    im.check(ikey)
                else if (t == 1)
                    im.checkPressed(ikey)
                else
                    im.checkReleased(ikey);

                if (is_set) {
                    any = VK_ANYKEY;
                    self.keyEvent(types[t], ikey, t == 1);
                }
            }
            self.keyEvent(types[t], any, t == 1);
        }
    }

    fn updatePositions(_: *LoopManager) void {
        const mgr = InstanceManager.get();
        var i: usize = 0;
        while (i < mgr.dynamicCount()) : (i += 1) {
            const inst = mgr.dynamicAt(i) orelse continue;
            if (instance_mod.has_builtin_physics and (inst.friction != 0.0 or inst.gravity != 0.0)) {
                inst.adaptSpeed();
            }
            if (inst.hspeed != 0.0 or inst.vspeed != 0.0) {
                inst.x += inst.hspeed;
                inst.y += inst.vspeed;
                collision_mod.touch(inst);
            }
        }
    }

    /// Outside Room / Intersect Boundary, with the cached handlers.
    fn handleOther(self: *LoopManager) void {
        if (!self.any.other) return;
        const mgr = InstanceManager.get();
        const rm = RoomManager.get();
        const sprites = sprite_mod.SpriteRegistry.get();
        const pass = mgr.passBegin();
        const w = rm.getWidth();
        const h = rm.getHeight();

        var i: usize = 0;
        while (i < mgr.dynamicCount()) : (i += 1) {
            const inst = mgr.dynamicAt(i) orelse continue;
            const hs = self.handlersOf(inst);
            if (hs.outside == null and hs.boundary == null) continue;
            if (inst.marked_for_destroy or !mgr.inPass(inst, pass)) continue;

            const boxed = sprites.valid(inst.sprite_index) or sprites.valid(inst.mask_index);
            if (hs.outside) |fn_ptr| {
                var outside: bool = false;
                if (boxed) {
                    _ = collision_mod.updateBbox(inst);
                    outside = inst.bbox_right < 0.0 or inst.bbox_left > w or inst.bbox_bottom < 0.0 or inst.bbox_top > h;
                } else {
                    outside = inst.x < 0.0 or inst.x > w or inst.y < 0.0 or inst.y > h;
                }
                if (outside and !inst.outside_room and !rm.eventBlocked(inst, EV_TYPE_OTHER)) {
                    fn_ptr(inst, inst);
                }
                inst.outside_room = outside;
            }
            // Re-read: the Outside event may have changed the object.
            if (self.handlersOf(inst).boundary) |fn_ptr| {
                var crossing: bool = false;
                if (boxed) {
                    _ = collision_mod.updateBbox(inst);
                    crossing = inst.bbox_left < 0.0 or inst.bbox_right > w or inst.bbox_top < 0.0 or inst.bbox_bottom > h;
                } else {
                    crossing = inst.x < 0.0 or inst.x > w or inst.y < 0.0 or inst.y > h;
                }
                if (crossing and !rm.eventBlocked(inst, EV_TYPE_OTHER)) {
                    fn_ptr(inst, inst);
                }
            }
        }
    }

    fn findCollisionHandler(self: *const LoopManager, inst_obj: i32, other_obj: i32) ?EventFn {
        const reg = ObjectRegistry.get();
        var child = other_obj;
        while (child != OBJECT_NONE) : (child = reg.getParent(child)) {
            var obj = inst_obj;
            while (obj != OBJECT_NONE) : (obj = reg.getParent(obj)) {
                if (self.hooks.?.find_own_event.?(obj, EV_TYPE_COLLISION, child)) |fn_ptr| {
                    return fn_ptr;
                }
            }
        }
        return null;
    }

    fn performCollision(self: *LoopManager, inst: *Instance, other: *Instance) void {
        if (RoomManager.get().eventBlocked(inst, EV_TYPE_COLLISION)) return;
        if (self.findCollisionHandler(inst.object_index, other.object_index)) |fn_ptr| {
            fn_ptr(inst, other);
        }
    }

    fn collidable(_: *const LoopManager, inst: ?*const Instance, pass: u32) bool {
        const mgr = InstanceManager.get();
        return inst != null and !inst.?.marked_for_destroy and inst.?.active and mgr.inPass(inst.?, pass);
    }

    fn revert(_: *LoopManager, inst: *Instance) void {
        inst.x = inst.xprevious;
        inst.y = inst.yprevious;
        collision_mod.touch(inst);
    }

    /// HandleCollision (Events.js L266). The recursive pools are read as the
    /// runner reads them: pool 1 once per first object, pool 2 afresh for
    /// every instance of pool 1. A pool cannot overflow: it holds at most
    /// every slot.
    fn handleCollisions(self: *LoopManager) void {
        const S = struct {
            var pool1: [MAX_INSTANCES]*Instance = undefined;
            var pool2: [MAX_INSTANCES]*Instance = undefined;
        };
        var p: usize = 0;
        const mgr = InstanceManager.get();

        collision_mod.gridSync();
        while (p < self.pair_count) {
            const id1 = self.pairs[p].a;
            var end = p;
            while (end < self.pair_count and self.pairs[end].a == id1) : (end += 1) {}

            // Empty pools produce no candidates (and so no events): skip them
            // without walking the other side's list.
            var any_second = false;
            var q = p;
            while (q < end and !any_second) : (q += 1) {
                any_second = mgr.objectListCount(self.pairs[q].b) > 0;
            }
            if (!any_second or mgr.objectListCount(id1) == 0) {
                p = end;
                continue;
            }

            const pass = mgr.passBegin();
            const n1 = mgr.objectPool(id1, &S.pool1);
            for (S.pool1[0..n1]) |inst1| {
                if (!self.collidable(inst1, pass)) continue;

                q = p;
                while (q < end) : (q += 1) {
                    if (inst1.marked_for_destroy) break;
                    const id2 = self.pairs[q].b;
                    if (mgr.objectListCount(id2) == 0) continue;

                    const candidates: []*Instance = if (collision_mod.queryGridCandidates(inst1, id2, &S.pool2)) |cnt|
                        S.pool2[0..cnt]
                    else blk: {
                        const n2 = mgr.objectPool(id2, &S.pool2);
                        break :blk S.pool2[0..n2];
                    };

                    for (candidates) |inst2| {
                        if (inst1.marked_for_destroy) break;
                        if (inst1 == inst2) continue;
                        if (!self.collidable(inst2, pass)) continue;
                        if (inst1.object_index == inst2.object_index and inst2.link_serial < inst1.link_serial) continue;
                        profile.count(.collision_pairs, 1);

                        if (collision_mod.testInstance(inst1, inst2, true)) {
                            if (inst1.solid or inst2.solid) {
                                self.revert(inst1);
                                self.revert(inst2);
                            }
                            if (inst1.object_index == id1 and inst2.object_index == id2) {
                                if (self.pairs[q].handler_a) |h| {
                                    if (!RoomManager.get().eventBlocked(inst1, EV_TYPE_COLLISION)) h(inst1, inst2);
                                }
                                if (self.pairs[q].handler_b) |h| {
                                    if (!RoomManager.get().eventBlocked(inst2, EV_TYPE_COLLISION)) h(inst2, inst1);
                                }
                            } else {
                                self.performCollision(inst1, inst2);
                                self.performCollision(inst2, inst1);
                            }
                        }
                    }
                }
            }
            p = end;
        }
    }

    fn anyDrawHandler(self: *const LoopManager, number: i32) bool {
        for (0..8) |t| {
            if (draw_numbers[t] == number) return self.has_draw[t];
        }
        return true;
    }

    inline fn isGuiDraw(number: i32) bool {
        return number == EV_DRAW_GUI or number == EV_DRAW_GUI_BEGIN or number == EV_DRAW_GUI_END;
    }

    fn drawEvent(self: *LoopManager, number: i32, draw_default: bool) void {
        if (!draw_default and !self.anyDrawHandler(number)) return;
        if (isGuiDraw(number) and !self.draw_filter.gui) return;

        const mgr = InstanceManager.get();
        const lm = LayerManager.get();
        const dm = DrawManager.get();
        const n = mgr.drawOrder(&self.draw_scratch);
        var layer: isize = @as(isize, @intCast(lm.count())) - 1;

        for (0..n) |i| {
            const inst = self.draw_scratch[i];
            if (draw_default and layer >= 0 and @as(usize, @intCast(layer)) < lm.count()) {
                while (layer >= 0 and @as(usize, @intCast(layer)) < lm.count()) {
                    const l = lm.at(@intCast(layer)) orelse break;
                    if (@as(f32, @floatFromInt(l.depth)) >= @floor(inst.depth)) {
                        const is_bg_layer = @as(f32, @floatFromInt(l.depth)) >= self.draw_filter.bg_depth_threshold;
                        const allow_layer = if (is_bg_layer) self.draw_filter.static_background else self.draw_filter.static_foreground;
                        if (allow_layer) {
                            const t = profile.start();
                            dm.drawLayer(l);
                            profile.stop(.draw_layers, t);
                        }
                        layer -= 1;
                    } else break;
                }
            }

            if (!inst.in_use or inst.marked_for_destroy or !inst.active or !inst.visible) {
                continue;
            }

            if (!isGuiDraw(number)) {
                if (!inst.is_dynamic) {
                    const is_bg = inst.depth >= self.draw_filter.bg_depth_threshold;
                    if (is_bg and !self.draw_filter.static_background) continue;
                    if (!is_bg and !self.draw_filter.static_foreground) continue;
                } else {
                    if (!self.draw_filter.dynamic_actors) continue;
                }
            }

            if (self.handler(inst, EV_TYPE_DRAW, number)) |fn_ptr| {
                if ((self.draw_filter.cull_offscreen or dm.skip_unseen) and !isGuiDraw(number) and dm.instanceOffscreen(inst, 32.0)) {
                    continue;
                }
                if (!RoomManager.get().eventBlocked(inst, EV_TYPE_DRAW)) {
                    fn_ptr(inst, inst);
                }
            } else if (draw_default) {
                if (!isGuiDraw(number) and dm.instanceOffscreen(inst, 1.0)) {
                    continue;
                }
                if (self.hooks.?.draw_self) |ds| {
                    ds(inst);
                }
            }
        }

        if (draw_default and layer >= 0) {
            while (layer >= 0 and @as(usize, @intCast(layer)) < lm.count()) : (layer -= 1) {
                if (lm.at(@intCast(layer))) |l| {
                    const is_bg_layer = @as(f32, @floatFromInt(l.depth)) >= self.draw_filter.bg_depth_threshold;
                    const allow_layer = if (is_bg_layer) self.draw_filter.static_background else self.draw_filter.static_foreground;
                    if (allow_layer) {
                        const t = profile.start();
                        dm.drawLayer(l);
                        profile.stop(.draw_layers, t);
                    }
                }
            }
        }
    }

    fn drawRoom(self: *LoopManager) void {
        self.drawEvent(EV_DRAW_BEGIN, false);
        self.drawEvent(EV_DRAW_NORMAL, true);
        self.drawEvent(EV_DRAW_END, false);
    }

    fn drawPipeline(self: *LoopManager) void {
        const dm = DrawManager.get();
        const vm = ViewManager.get();
        // _ = self;

        dm.beginFrame();
        self.drawEvent(EV_DRAW_PRE, false);
        vm.update();

        if (vm.enabled()) {
            for (0..VIEW_COUNT) |v| {
                if (vm.getViewVar(ViewField.visible, v) != 0.0) {
                    vm.setCurrent(@intCast(v));
                    dm.passView(v);
                    self.drawRoom();
                }
            }
            vm.setCurrent(7);
        } else {
            vm.setCurrent(0);
            dm.passRoom();
            self.drawRoom();
        }

        self.drawEvent(EV_DRAW_POST, false);
        if (self.draw_filter.gui) {
            dm.passGui();
            self.drawEvent(EV_DRAW_GUI_BEGIN, false);
            self.drawEvent(EV_DRAW_GUI, false);
            self.drawEvent(EV_DRAW_GUI_END, false);
        }
        dm.endFrame();
    }

    pub fn setDrawEnabled(self: *LoopManager, enabled: bool) void {
        self.is_draw_enabled = enabled;
    }

    pub fn setDrawSkip(self: *LoopManager, enabled: bool) void {
        self.draw_skip_enabled = enabled;
        self.draw_skip = false;
    }

    pub fn setDrawFilter(self: *LoopManager, filter: DrawLayerFilter) void {
        self.draw_filter = filter;
    }

    pub fn getDrawFilter(self: *const LoopManager) DrawLayerFilter {
        return self.draw_filter;
    }

    pub fn setStaticBackgroundEnabled(self: *LoopManager, enabled: bool) void {
        self.draw_filter.static_background = enabled;
    }

    pub fn setStaticForegroundEnabled(self: *LoopManager, enabled: bool) void {
        self.draw_filter.static_foreground = enabled;
    }

    pub fn setDynamicActorsEnabled(self: *LoopManager, enabled: bool) void {
        self.draw_filter.dynamic_actors = enabled;
    }

    pub fn setGuiEnabled(self: *LoopManager, enabled: bool) void {
        self.draw_filter.gui = enabled;
    }

    pub fn frameCount(self: *const LoopManager) usize {
        return self.total_frames;
    }

    pub fn pairCount(self: *const LoopManager) usize {
        return self.pair_count;
    }

    pub fn pair(self: *const LoopManager, index: usize, out_a: *i32, out_b: *i32) bool {
        if (index < self.pair_count) {
            out_a.* = self.pairs[index].a;
            out_b.* = self.pairs[index].b;
            return true;
        }
        return false;
    }

    pub fn eventPerform(self: *LoopManager, inst: *Instance, other: ?*Instance, ev_type: i32, number: i32) void {
        if (RoomManager.get().eventBlocked(inst, ev_type)) return;
        if (self.handler(inst, ev_type, number)) |fn_ptr| {
            fn_ptr(inst, other);
        }
    }

    pub fn step(self: *LoopManager) void {
        if (self.hooks == null) return;
        self.total_frames += 1;

        // Phases cut short by a room change are not timed.
        var t = profile.start();
        InputManager.get().startStep();
        self.updateImagesAndPositions();
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.images, t);

        t = profile.start();
        LayerManager.get().update();
        self.stepAll(.step_begin);
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.begin_step, t);

        t = profile.start();
        self.handleAlarms();
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.alarms, t);

        t = profile.start();
        self.handleKeyboard();
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.keyboard, t);

        t = profile.start();
        self.stepAll(.step);
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.step, t);

        t = profile.start();
        self.updatePositions();
        profile.stop(.positions, t);
        t = profile.start();
        self.handleOther();
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.other, t);

        t = profile.start();
        self.handleCollisions();
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.collisions, t);

        t = profile.start();
        self.stepAll(.step_end);
        if (RoomManager.get().pending() != ROOM_NONE) return;
        profile.stop(.end_step, t);

        t = profile.start();
        _ = InstanceManager.get().reclaimMarked();
        profile.stop(.reclaim, t);
        const should_draw = self.is_draw_enabled and (!self.draw_skip_enabled or !self.draw_skip);
        if (should_draw) {
            t = profile.start();
            if (self.use_alt_draw) draw_alt.drawPipeline(self) else self.drawPipeline();
            profile.stop(.draw, t);
        }

        if (self.draw_skip_enabled) {
            self.draw_skip = !self.draw_skip;
        }
    }

    pub fn tick(self: *LoopManager) LoopStatus {
        if (self.hooks == null) return .running;

        const t = profile.start();
        defer profile.stop(.tick, t);
        var steps: usize = 0;
        while (steps < MAX_STEPS_PER_TICK) : (steps += 1) {
            self.step();
            const next_rm = RoomManager.get().pending();
            if (next_rm == ROOM_NONE) {
                break;
            }
            if (next_rm == ROOM_END_GAME) {
                return .ended;
            }
            if (next_rm == ROOM_RESTART_GAME) {
                _ = RoomManager.get().restartGame();
                break;
            }
            _ = RoomManager.get().switchPending();
        }

        if (self.hooks.?.safe_point) |sp| {
            sp();
        }
        return .running;
    }
};

test "LoopManager collision pair derivation and step execution" {
    var lm = LoopManager.get();
    const hooks = LoopHooks{
        .find_event = struct {
            fn f(_: i32, _: i32, _: i32) ?EventFn {
                return null;
            }
        }.f,
        .find_own_event = struct {
            fn f(_: i32, _: i32, _: i32) ?EventFn {
                return null;
            }
        }.f,
    };

    try std.testing.expect(lm.init(hooks));
    lm.step();
    try std.testing.expectEqual(@as(usize, 1), lm.frameCount());
}
