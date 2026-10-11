//! Room definitions and runtime: room switching, order, lifecycle, and start sequence.
//! Follows _GameMaker.js StartRoom, Function_Room.js, and packaged_src/src/runtime/gm_room.c.

const std = @import("std");
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;
const MAX_INSTANCES = instance_mod.MAX_INSTANCES;
const INSTANCE_ID_BASE = instance_mod.INSTANCE_ID_BASE;
const object_mod = @import("object.zig");
const ObjectRegistry = object_mod.ObjectRegistry;
const EventFn = object_mod.EventFn;
const layer_mod = @import("layer.zig");
const LayerManager = layer_mod.LayerManager;
const view_mod = @import("view.zig");
const ViewManager = view_mod.ViewManager;
const collision_mod = @import("collision.zig");

pub const VIEW_COUNT: usize = 8;
pub const MAX_ROOMS: usize = 128;
pub const ROOM_NONE: i32 = -1;

pub const ROOM_FIRST_DYNAMIC_ID: i32 = 1000000;
pub const ROOM_END_GAME: i32 = -100;
pub const ROOM_RESTART_GAME: i32 = -200;

pub const EVENT_TYPE_CREATE: i32 = 0;
pub const EVENT_TYPE_DESTROY: i32 = 1;
pub const EVENT_TYPE_ALARM: i32 = 2;
pub const EVENT_TYPE_STEP: i32 = 3;
pub const EVENT_TYPE_OTHER: i32 = 7;
pub const EVENT_TYPE_CLEAN_UP: i32 = 12;
pub const EVENT_TYPE_PRE_CREATE: i32 = 14;

pub const EVENT_OTHER_GAME_START: i32 = 2;
pub const EVENT_OTHER_GAME_END: i32 = 3;
pub const EVENT_OTHER_ROOM_START: i32 = 4;
pub const EVENT_OTHER_ROOM_END: i32 = 5;

pub const RoomViewDef = struct {
    visible: bool = false,
    xview: i32 = 0,
    yview: i32 = 0,
    wview: i32 = 640,
    hview: i32 = 480,
    xport: i32 = 0,
    yport: i32 = 0,
    wport: i32 = 640,
    hport: i32 = 480,
    hborder: i32 = 32,
    vborder: i32 = 32,
    hspeed: i32 = -1,
    vspeed: i32 = -1,
    object: i32 = -1,
};

pub const RoomLayerDef = struct {
    name: []const u8 = "",
    id: i32 = 0,
    kind: i32 = 0,
    depth: i32 = 0,
    visible: bool = true,
    x: f32 = 0.0,
    y: f32 = 0.0,
    hspeed: f32 = 0.0,
    vspeed: f32 = 0.0,
    bg_sprite: i32 = -1,
    bg_htiled: bool = false,
    bg_vtiled: bool = false,
    bg_stretch: bool = false,
    bg_colour: u32 = 0xFFFFFFFF,
    first_tile: i32 = 0,
    tile_count: i32 = 0,
};

pub const RoomTileDef = struct {
    sprite: i32 = 0,
    u: i32 = 0,
    v: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    xscale: f32 = 1.0,
    yscale: f32 = 1.0,
    colour: u32 = 0xFFFFFFFF,
};

pub const RoomInstDef = struct {
    id: i32 = 0,
    object: i32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    xscale: f32 = 1.0,
    yscale: f32 = 1.0,
    angle: f32 = 0.0,
    colour: u32 = 0xFFFFFFFF,
    image_index: f32 = 0.0,
    image_speed: f32 = 1.0,
    layer: usize = 0,
    code: ?EventFn = null,
};

pub const RoomDef = struct {
    name: []const u8 = "",
    width: i32 = 640,
    height: i32 = 480,
    speed: i32 = 30,
    persistent: bool = false,
    enable_views: bool = false,
    views: [VIEW_COUNT]RoomViewDef = [_]RoomViewDef{.{}} ** VIEW_COUNT,
    layer_count: usize = 0,
    layers: ?[]const RoomLayerDef = null,
    tile_count: usize = 0,
    tiles: ?[]const RoomTileDef = null,
    instance_count: usize = 0,
    instances: ?[]const RoomInstDef = null,
    code: ?EventFn = null,
};

pub const RoomHooks = struct {
    perform: ?*const fn (inst: *Instance, event_type: i32, event_number: i32) void = null,
    room_begin: ?*const fn (room: i32) void = null,
};

pub const RoomManager = struct {
    rooms: ?[]const RoomDef = null,
    order: ?[]const i32 = null,
    hooks: ?RoomHooks = null,

    current_room: i32 = ROOM_NONE,
    pending_room: i32 = ROOM_NONE,
    error_count: usize = 0,
    overflow_count: usize = 0,

    width: f32 = 640.0,
    height: f32 = 480.0,
    speed: f32 = 30.0,
    is_persistent: bool = false,
    caption: [128]u8 = [_]u8{0} ** 128,
    caption_len: usize = 0,

    // Scratch buffers for StartRoom
    carry: [MAX_INSTANCES]*Instance = undefined,
    carry_count: usize = 0,
    created: [MAX_INSTANCES]?*Instance = undefined,
    keep: [MAX_INSTANCES]bool = [_]bool{false} ** MAX_INSTANCES,
    dummy: Instance = .{},

    var instance: RoomManager = .{};

    pub fn get() *RoomManager {
        return &instance;
    }

    fn roomOk(r: *const RoomDef) bool {
        if (r.name.len == 0 or r.persistent) return false;
        if (r.instance_count > MAX_INSTANCES) return false;
        if (r.layer_count > 0 and r.layers == null) return false;
        if (r.tile_count > 0 and r.tiles == null) return false;
        if (r.instance_count > 0 and r.instances == null) return false;

        if (r.layers) |layers| {
            for (0..r.layer_count) |i| {
                const l = &layers[i];
                if (l.first_tile < 0 or l.tile_count < 0 or
                    @as(usize, @intCast(l.first_tile + l.tile_count)) > r.tile_count)
                {
                    return false;
                }
            }
        }

        if (r.instances) |insts| {
            const reg = ObjectRegistry.get();
            for (0..r.instance_count) |i| {
                const d = &insts[i];
                if (!reg.valid(d.object) or d.layer >= r.layer_count or
                    d.id < INSTANCE_ID_BASE or d.id >= ROOM_FIRST_DYNAMIC_ID)
                {
                    return false;
                }
            }
        }

        return true;
    }

    pub fn registryInit(
        self: *RoomManager,
        rooms: ?[]const RoomDef,
        order: ?[]const i32,
    ) bool {
        self.rooms = null;
        self.order = null;
        self.reset();

        const rms = rooms orelse {
            if (order != null and order.?.len > 0) return false;
            return true;
        };
        if (rms.len > MAX_ROOMS) return false;

        const ord = order orelse {
            if (rms.len > 0) return false;
            return true;
        };
        if (ord.len > rms.len) return false;

        for (rms) |*r| {
            if (!roomOk(r)) return false;
        }

        for (ord) |rm_idx| {
            if (rm_idx < 0 or @as(usize, @intCast(rm_idx)) >= rms.len) {
                return false;
            }
        }

        self.rooms = rms;
        self.order = ord;

        ViewManager.get().init(rms);
        LayerManager.get().reset();

        var top: i32 = 0;
        for (rms) |*r| {
            if (r.layers) |layers| {
                for (0..r.layer_count) |l| {
                    if (layers[l].id > top) top = layers[l].id;
                }
            }
        }
        LayerManager.get().setWatermark(top);
        return true;
    }

    pub fn setHooks(self: *RoomManager, hooks: ?RoomHooks) void {
        self.hooks = hooks;
    }

    pub fn reset(self: *RoomManager) void {
        self.current_room = ROOM_NONE;
        self.pending_room = ROOM_NONE;
        self.error_count = 0;
        self.overflow_count = 0;
        self.width = 640.0;
        self.height = 480.0;
        self.speed = 30.0;
        self.is_persistent = false;
        self.caption[0] = 0;
        self.caption_len = 0;
    }

    pub fn count(self: *const RoomManager) usize {
        return if (self.rooms) |r| r.len else 0;
    }

    pub fn exists(self: *const RoomManager, room: i32) bool {
        if (room < 0) return false;
        const uroom: usize = @intCast(room);
        return if (self.rooms) |r| uroom < r.len else false;
    }

    pub fn getDef(self: *const RoomManager, room: i32) ?*const RoomDef {
        if (!self.exists(room)) return null;
        return &self.rooms.?[@intCast(room)];
    }

    pub fn getName(self: *const RoomManager, room: i32) []const u8 {
        if (self.getDef(room)) |def| {
            return def.name;
        }
        return "";
    }

    pub fn first(self: *const RoomManager) i32 {
        if (self.order) |ord| {
            if (ord.len > 0) return ord[0];
        }
        return ROOM_NONE;
    }

    pub fn last(self: *const RoomManager) i32 {
        if (self.order) |ord| {
            if (ord.len > 0) return ord[ord.len - 1];
        }
        return ROOM_NONE;
    }

    fn orderIndex(self: *const RoomManager, room: i32) ?usize {
        if (self.order) |ord| {
            for (ord, 0..) |rm, idx| {
                if (rm == room) return idx;
            }
        }
        return null;
    }

    pub fn next(self: *const RoomManager, room: i32) i32 {
        const idx = self.orderIndex(room) orelse return ROOM_NONE;
        if (idx + 1 < self.order.?.len) {
            return self.order.?[idx + 1];
        }
        return ROOM_NONE;
    }

    pub fn previous(self: *const RoomManager, room: i32) i32 {
        const idx = self.orderIndex(room) orelse return ROOM_NONE;
        if (idx > 0) {
            return self.order.?[idx - 1];
        }
        return ROOM_NONE;
    }

    pub fn current(self: *const RoomManager) i32 {
        return self.current_room;
    }

    pub fn pending(self: *const RoomManager) i32 {
        return self.pending_room;
    }

    pub fn eventBlocked(self: *const RoomManager, inst: ?*const Instance, ev_type: i32) bool {
        if (self.pending_room == ROOM_NONE or ev_type == EVENT_TYPE_CLEAN_UP) {
            return false;
        }
        if ((inst != null and inst.?.persistent) or self.is_persistent) {
            return !(ev_type == EVENT_TYPE_CREATE or ev_type == EVENT_TYPE_PRE_CREATE or
                ev_type == EVENT_TYPE_DESTROY or ev_type == EVENT_TYPE_ALARM or
                ev_type == EVENT_TYPE_OTHER);
        }
        return true;
    }

    pub fn roomGoto(self: *RoomManager, room: i32) bool {
        if (!self.exists(room)) {
            self.error_count += 1;
            return false;
        }
        self.pending_room = room;
        return true;
    }

    pub fn gameEnd(self: *RoomManager) void {
        self.pending_room = ROOM_END_GAME;
    }

    pub fn gameRestart(self: *RoomManager) void {
        self.pending_room = ROOM_RESTART_GAME;
    }

    pub fn roomRestart(self: *RoomManager) void {
        if (self.current_room != ROOM_NONE) {
            self.pending_room = self.current_room;
        }
    }

    pub fn roomGotoNext(self: *RoomManager) void {
        const nxt = self.next(self.current_room);
        if (nxt != ROOM_NONE) {
            self.pending_room = nxt;
        }
    }

    pub fn roomGotoPrevious(self: *RoomManager) void {
        const prev = self.previous(self.current_room);
        if (prev != ROOM_NONE) {
            self.pending_room = prev;
        }
    }

    pub fn performEventAll(self: *RoomManager, ev_type: i32, ev_number: i32) void {
        const hooks = self.hooks orelse return;
        const perform_fn = hooks.perform orelse return;

        const mgr = InstanceManager.get();
        const pass = mgr.passBegin();
        var i: isize = @as(isize, @intCast(mgr.activeCount())) - 1;
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            if (ui >= mgr.activeCount()) continue;
            const inst = mgr.activeAt(ui) orelse continue;
            if (!inst.marked_for_destroy and mgr.inPass(inst, pass) and !self.eventBlocked(inst, ev_type)) {
                perform_fn(inst, ev_type, ev_number);
            }
        }
    }

    fn perform(self: *RoomManager, inst: *Instance, ev_type: i32, ev_number: i32) void {
        if (self.hooks) |hooks| {
            if (hooks.perform) |p| {
                if (!self.eventBlocked(inst, ev_type)) {
                    p(inst, ev_type, ev_number);
                }
            }
        }
    }

    fn carried(self: *const RoomManager, id: i32) bool {
        for (0..self.carry_count) |i| {
            if (self.carry[i].id == id) return true;
        }
        return false;
    }

    fn endRoom(self: *RoomManager) void {
        const mgr = InstanceManager.get();
        _ = mgr.reclaimMarked();
        self.performEventAll(EVENT_TYPE_OTHER, EVENT_OTHER_ROOM_END);

        self.carry_count = 0;
        @memset(&self.keep, false);
        var i: isize = @as(isize, @intCast(mgr.activeCount())) - 1;
        while (i >= 0) : (i -= 1) {
            const ui: usize = @intCast(i);
            const inst = mgr.activeAt(ui).?;
            if (inst.persistent) {
                self.carry[self.carry_count] = inst;
                self.carry_count += 1;
                self.keep[mgr.slot(inst)] = true;
            }
        }

        for (0..self.carry_count) |c_idx| {
            mgr.activeDetach(self.carry[c_idx]);
        }

        for (0..MAX_INSTANCES) |slot_idx| {
            if (mgr.atSlot(slot_idx)) |inst| {
                if (!self.keep[slot_idx]) {
                    mgr.removeNow(inst);
                }
            }
        }

        ViewManager.get().roomEnd();
        LayerManager.get().roomEnd();
    }

    fn createStorageInstance(self: *RoomManager, r: *const RoomDef, d: *const RoomInstDef) ?*Instance {
        const depth = @as(f32, @floatFromInt(r.layers.?[d.layer].depth));
        const inst = InstanceManager.get().createWithId(d.object, d.x, d.y, depth, d.id) orelse {
            self.overflow_count += 1;
            return null;
        };
        inst.image_speed = d.image_speed;
        inst.image_index = d.image_index;
        inst.image_xscale = d.xscale;
        inst.image_yscale = d.yscale;
        inst.image_angle = d.angle;
        inst.image_blend = d.colour & 0x00FFFFFF;
        inst.image_alpha = @as(f32, @floatFromInt((d.colour >> 24) & 0xFF)) / 255.0;
        collision_mod.touch(inst);
        return inst;
    }

    pub fn start(self: *RoomManager, room: i32, starting: bool) bool {
        const r = self.getDef(room) orelse {
            self.error_count += 1;
            return false;
        };

        self.pending_room = ROOM_NONE;
        if (self.current_room != ROOM_NONE) {
            self.endRoom();
        } else {
            self.carry_count = 0;
        }

        self.current_room = room;
        self.width = @floatFromInt(r.width);
        self.height = @floatFromInt(r.height);
        self.speed = @floatFromInt(r.speed);
        self.is_persistent = r.persistent;
        self.caption[0] = 0;
        self.caption_len = 0;

        collision_mod.configureGrid(self.width, self.height, 32.0);
        ViewManager.get().roomStart(room, r);
        LayerManager.get().roomStart(r);

        if (self.hooks) |hooks| {
            if (hooks.room_begin) |rb| rb(room);
        }

        if (r.instances) |insts| {
            for (0..r.instance_count) |i| {
                const d = &insts[i];
                self.created[i] = if (self.carried(d.id)) null else self.createStorageInstance(r, d);
            }

            for (0..r.instance_count) |i| {
                const d = &insts[i];
                const inst = self.created[i] orelse continue;

                if (InstanceManager.get().findById(d.id) != inst) {
                    continue;
                }
                self.perform(inst, EVENT_TYPE_PRE_CREATE, 0);
                const create_fn = ObjectRegistry.get().findEvent(inst.object_index, .create, 0);
                if (create_fn != null and !self.eventBlocked(inst, EVENT_TYPE_CREATE)) {
                    create_fn.?(inst, inst);
                }
                if (d.code) |code| {
                    code(inst, inst);
                }
            }
        }

        const mgr = InstanceManager.get();
        for (0..self.carry_count) |c_idx| {
            mgr.activeAttach(self.carry[c_idx]);
        }
        self.carry_count = 0;

        if (starting) {
            self.performEventAll(EVENT_TYPE_OTHER, EVENT_OTHER_GAME_START);
        }
        if (r.code) |code| {
            mgr.initDetached(&self.dummy);
            code(&self.dummy, &self.dummy);
        }
        self.performEventAll(EVENT_TYPE_OTHER, EVENT_OTHER_ROOM_START);
        return true;
    }

    pub fn startGame(self: *RoomManager) bool {
        const fst = self.first();
        if (fst == ROOM_NONE) return false;
        const mgr = InstanceManager.get();
        if (mgr.nextId() < ROOM_FIRST_DYNAMIC_ID) {
            mgr.setNextId(ROOM_FIRST_DYNAMIC_ID);
        }
        return self.start(fst, true);
    }

    pub fn switchPending(self: *RoomManager) bool {
        if (!self.exists(self.pending_room)) {
            return false;
        }
        return self.start(self.pending_room, false);
    }

    pub fn restartGame(self: *RoomManager) bool {
        const mgr = InstanceManager.get();
        for (0..MAX_INSTANCES) |i| {
            mgr.removeNow(mgr.atSlot(i));
        }
        if (self.current_room != ROOM_NONE) {
            ViewManager.get().roomEnd();
            LayerManager.get().roomEnd();
        }
        ViewManager.get().resetAll();
        self.current_room = ROOM_NONE;
        self.pending_room = ROOM_NONE;
        return self.startGame();
    }

    // Built-in getters/setters
    pub fn getWidth(self: *const RoomManager) f32 {
        return self.width;
    }

    pub fn getHeight(self: *const RoomManager) f32 {
        return self.height;
    }

    pub fn getSpeed(self: *const RoomManager) f32 {
        return self.speed;
    }

    pub fn isPersistent(self: *const RoomManager) bool {
        return self.is_persistent;
    }

    pub fn getCaption(self: *const RoomManager) []const u8 {
        return self.caption[0..self.caption_len];
    }

    pub fn setWidth(self: *RoomManager, w: f32) void {
        self.width = w;
    }

    pub fn setHeight(self: *RoomManager, h: f32) void {
        self.height = h;
    }

    pub fn setSpeed(self: *RoomManager, s: f32) void {
        self.speed = s;
    }

    pub fn setPersistent(self: *RoomManager, p: bool) void {
        self.is_persistent = p;
    }

    pub fn setCaption(self: *RoomManager, cap: []const u8) void {
        const len = @min(cap.len, 127);
        @memcpy(self.caption[0..len], cap[0..len]);
        self.caption[len] = 0;
        self.caption_len = len;
    }

    pub fn errors(self: *const RoomManager) usize {
        return self.error_count;
    }

    pub fn overflows(self: *const RoomManager) usize {
        return self.overflow_count;
    }
};

test "RoomManager basic initialization and order" {
    var rm = RoomManager.get();
    rm.reset();

    const rooms = [_]RoomDef{
        .{ .name = "rm1" },
        .{ .name = "rm2" },
    };
    const order = [_]i32{ 1, 0 };

    try std.testing.expect(rm.registryInit(&rooms, &order));
    try std.testing.expectEqual(@as(usize, 2), rm.count());
    try std.testing.expectEqual(@as(i32, 1), rm.first());
    try std.testing.expectEqual(@as(i32, 0), rm.last());
    try std.testing.expectEqual(@as(i32, 0), rm.next(1));
    try std.testing.expectEqual(@as(i32, ROOM_NONE), rm.next(0));
}
