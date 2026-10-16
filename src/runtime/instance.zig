//! Entity instance pool, lifecycle, lookup, and coupled property setters.
//! Follows reference/GameMaker-HTML5 (yyInstance.js, Function_Instance.js) and packaged_src/src/runtime/gm_instance.h.

const std = @import("std");
const math = @import("math.zig");
const Value = @import("value.zig").Value;
const StringManager = @import("string.zig").StringManager;
const object_mod = @import("object.zig");
const ObjectRegistry = object_mod.ObjectRegistry;
const room = @import("room.zig");
const profile = @import("profile.zig");

/// Instance pool size: 2048 (the C port's GM_INSTANCE_MAX); smaller where
/// RAM is short (the Playdate builds use 1024, like its C build). Set by
/// build.zig through the `runtime_options` module.
pub const MAX_INSTANCES: usize = @import("runtime_options").max_instances;
pub const INSTANCE_ID_BASE: i32 = 100000;

pub const GM_SELF: i32 = -1;
pub const GM_OTHER: i32 = -2;
pub const GM_ALL: i32 = -3;
pub const GM_NOONE: i32 = -4;

/// Variable slots per instance (real / string / value). The generated game
/// checks at comptime that its counts fit (gml_game.zig); RAM-tight builds
/// size them to the game.
pub const VAR_COUNT: usize = @import("runtime_options").var_count;
pub const SVAR_COUNT: usize = @import("runtime_options").svar_count;
pub const VVAR_COUNT: usize = @import("runtime_options").vvar_count;
pub const ALARM_COUNT: usize = 12;
pub const has_builtin_physics: bool = if (@hasDecl(@import("runtime_options"), "has_builtin_physics")) @import("runtime_options").has_builtin_physics else true;

/// Compact ~44-byte core header representation of a static terrain block (ZIG_LOOP.md 3.1).
pub const StaticInstance = struct {
    id: i32 = 0,
    object_index: i32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    depth: f32 = 0.0,
    sprite_index: i32 = -1,
    bbox_left: f32 = 0.0,
    bbox_top: f32 = 0.0,
    bbox_right: f32 = 0.0,
    bbox_bottom: f32 = 0.0,
    flags: u32 = 0,

    pub inline fn fromInstance(inst: *const Instance) StaticInstance {
        return .{
            .id = inst.id,
            .object_index = inst.object_index,
            .x = inst.x,
            .y = inst.y,
            .depth = inst.depth,
            .sprite_index = inst.sprite_index,
            .bbox_left = inst.bbox_left,
            .bbox_top = inst.bbox_top,
            .bbox_right = inst.bbox_right,
            .bbox_bottom = inst.bbox_bottom,
            .flags = @as(u32, @intFromBool(inst.solid)) |
                (@as(u32, @intFromBool(inst.visible)) << 1) |
                (@as(u32, @intFromBool(inst.persistent)) << 2) |
                (@as(u32, @intFromBool(inst.active)) << 3),
        };
    }
};

/// Segregated out-of-line variable payload for an instance.
pub const VariableSlab = struct {
    vars: [VAR_COUNT]f32 = [_]f32{0.0} ** VAR_COUNT,
    strs: [SVAR_COUNT][]const u8 = [_][]const u8{""} ** SVAR_COUNT,
    vals: [VVAR_COUNT]Value = [_]Value{Value.UNDEFINED} ** VVAR_COUNT,

    pub fn reset(self: *VariableSlab) void {
        @memset(&self.vars, 0.0);
        @memset(&self.strs, "");
        @memset(&self.vals, Value.UNDEFINED);
    }
};

pub var dummy_slab: VariableSlab = .{};

/// InstanceManager.cull_state: whether `cull_box` holds a static
/// instance's draw box (`none`: no sprite box, never culled).
pub const CullState = enum(u8) { unknown, box, none };

pub const Instance = struct {
    id: i32 = 0,
    object_index: i32 = 0,
    in_use: bool = false,
    active: bool = false,
    marked_for_destroy: bool = false,
    being_destroyed: bool = false,
    is_dynamic: bool = true,

    x: f32 = 0.0,
    y: f32 = 0.0,
    xprevious: f32 = 0.0,
    yprevious: f32 = 0.0,
    xstart: f32 = 0.0,
    ystart: f32 = 0.0,
    hspeed: f32 = 0.0,
    vspeed: f32 = 0.0,
    speed: f32 = 0.0,
    direction: f32 = 0.0,
    friction: f32 = 0.0,
    gravity: f32 = 0.0,
    gravity_direction: f32 = 270.0,

    sprite_index: i32 = -1,
    image_index: f32 = 0.0,
    image_speed: f32 = 1.0,
    image_xscale: f32 = 1.0,
    image_yscale: f32 = 1.0,
    image_angle: f32 = 0.0,
    image_alpha: f32 = 1.0,
    image_blend: u32 = 0xFFFFFF,
    visible: bool = true,
    solid: bool = false,
    persistent: bool = false,
    depth: f32 = 0.0,

    bbox_left: f32 = 0.0,
    bbox_top: f32 = 0.0,
    bbox_right: f32 = 0.0,
    bbox_bottom: f32 = 0.0,
    mask_index: i32 = -1,

    alarms: [ALARM_COUNT]f32 = [_]f32{-1.0} ** ALARM_COUNT,
    alarm_mask: u16 = 0,

    slab: *VariableSlab = &dummy_slab,
    vars: *[VAR_COUNT]f32 = &dummy_slab.vars,
    strs: *[SVAR_COUNT][]const u8 = &dummy_slab.strs,
    vals: *[VVAR_COUNT]Value = &dummy_slab.vals,

    create_counter: u32 = 0,
    layer_serial: u32 = 0,
    /// Set when the instance joins its object lists (add, activate), so
    /// ascending link_serial == per-object list order.
    link_serial: u32 = 0,
    type_links: [object_mod.MAX_ANCESTOR_LEVELS]Link = @splat(.{}),
    outside_room: bool = false,

    fn clampFloat(f: f32) f32 {
        return @as(f32, @floatFromInt(math.toInt32(f * 1000000.0))) / 1000000.0;
    }

    fn snapNearInt(v: f32) f32 {
        const r = math.round(v);
        return if (@abs(v - r) < 0.0001) r else v;
    }

    fn html5Fmod(x: f32, y: f32) f32 {
        if (x == 0.0) return 0.0;
        return @mod(x * 16777216.0, y * 16777216.0) / 16777216.0;
    }

    pub fn computeSpeed1(self: *Instance) void {
        if (self.hspeed == 0.0) {
            if (self.vspeed > 0.0) {
                self.direction = 270.0;
            } else if (self.vspeed < 0.0) {
                self.direction = 90.0;
            }
        } else {
            const dd = clampFloat(180.0 * std.math.atan2(self.vspeed, self.hspeed) / math.GM_PI);
            self.direction = if (dd <= 0.0) -dd else 360.0 - dd;
        }
        self.direction = snapNearInt(self.direction);
        self.direction = html5Fmod(self.direction, 360.0);

        self.speed = @sqrt(self.hspeed * self.hspeed + self.vspeed * self.vspeed);
        self.speed = snapNearInt(self.speed);
    }

    pub fn computeSpeed2(self: *Instance) void {
        self.hspeed = self.speed * clampFloat(math.dcos(self.direction));
        self.vspeed = -self.speed * clampFloat(math.dsin(self.direction));
        self.hspeed = snapNearInt(self.hspeed);
        self.vspeed = snapNearInt(self.vspeed);
    }

    pub fn setDynamic(self: *Instance, dynamic_val: bool) void {
        if (self.is_dynamic == dynamic_val) return;
        if (dynamic_val) {
            InstanceManager.get().promoteDynamic(self);
        } else {
            InstanceManager.get().demoteStatic(self);
        }
    }

    pub fn promoteDynamic(self: *Instance) void {
        self.setDynamic(true);
    }

    // Coupled motion property setters
    pub fn setSpeed(self: *Instance, spd: f32) void {
        if (self.speed == spd) return;
        if (!self.is_dynamic and spd != 0.0) self.promoteDynamic();
        self.speed = spd;
        self.computeSpeed2();
    }

    pub fn setDirection(self: *Instance, dir: f32) void {
        var v = dir;
        while (v < 0.0) v += 360.0;
        while (v > 360.0) v -= 360.0;
        self.direction = html5Fmod(v, 360.0);
        self.computeSpeed2();
    }

    pub fn setHspeed(self: *Instance, hspd: f32) void {
        if (self.hspeed == hspd) return;
        if (!self.is_dynamic and hspd != 0.0) self.promoteDynamic();
        self.hspeed = hspd;
        self.computeSpeed1();
    }

    pub fn setVspeed(self: *Instance, vspd: f32) void {
        if (self.vspeed == vspd) return;
        if (!self.is_dynamic and vspd != 0.0) self.promoteDynamic();
        self.vspeed = vspd;
        self.computeSpeed1();
    }

    pub fn setDepth(self: *Instance, d: f32) void {
        if (self.depth == d) return;
        if (@floor(self.depth) != @floor(d)) {
            const mgr = InstanceManager.get();
            self.layer_serial = mgr.nextLayerSerial();
            mgr.draw_dirty = true;
            // Pool instances only (tests may use stack instances).
            if (mgr.owns(self)) mgr.depth_bucket[mgr.slot(self)] = InstanceManager.depthBucket(d);
        }
        self.depth = d;
    }

    pub fn setAlarm(self: *Instance, index: usize, val: f32) void {
        if (index >= ALARM_COUNT) return;
        self.alarms[index] = val;
        if (val >= 0.0) {
            if (!self.is_dynamic) self.promoteDynamic();
            self.alarm_mask |= @as(u16, 1) << @intCast(index);
        } else {
            self.alarm_mask &= ~(@as(u16, 1) << @intCast(index));
        }
    }

    pub fn adaptSpeed(self: *Instance) void {
        if (self.friction != 0.0) {
            const ns = if (self.speed > 0.0) self.speed - self.friction else self.speed + self.friction;
            if ((self.speed > 0.0 and ns < 0.0) or (self.speed < 0.0 and ns > 0.0)) {
                self.setSpeed(0.0);
            } else if (self.speed != 0.0) {
                self.setSpeed(ns);
            }
        }
        if (self.gravity != 0.0) {
            const dir = self.gravity_direction;
            self.setHspeed(self.hspeed + self.gravity * clampFloat(math.dcos(dir)));
            self.setVspeed(self.vspeed - self.gravity * clampFloat(math.dsin(dir)));
            self.computeSpeed1();
        }
    }

    pub inline fn getVar(self: *const Instance, var_id: usize) f32 {
        return if (var_id < VAR_COUNT) self.vars[var_id] else 0.0;
    }

    pub inline fn setVar(self: *Instance, var_id: usize, val: f32) void {
        if (var_id < VAR_COUNT) self.vars[var_id] = val;
    }
};

/// One instance's link in a per-object recursive list (gm_instance_link_t).
pub const Link = struct {
    prev: ?*Instance = null,
    next: ?*Instance = null,
};

/// Lifecycle hooks (gm_instance_hooks_t): the collision module keeps its
/// spatial grid in step with the active set through these.
pub const Hooks = struct {
    on_reset: ?*const fn () void = null,
    on_enter: ?*const fn (inst: *Instance) void = null,
    on_leave: ?*const fn (inst: *Instance) void = null,
};

const TypeList = struct {
    head: ?*Instance = null,
    tail: ?*Instance = null,
    count: usize = 0,
};

const ID_HASH_BITS = 12;
const ID_HASH_SIZE: usize = 1 << ID_HASH_BITS;
const ID_EMPTY: i16 = -1;

comptime {
    std.debug.assert(ID_HASH_SIZE >= 2 * MAX_INSTANCES and MAX_INSTANCES <= 32767);
}

pub const DIRECT_ID_CAP: usize = 8192;

/// Port of gm_instance.c: a fixed pool with a LIFO free stack, the active,
/// deactivated and creation-order (`all`) lists, per-object recursive lists
/// (yyObject.m_Instances, ordered by link_serial) and an id hash table.
pub const InstanceManager = struct {
    pool: [MAX_INSTANCES]Instance = [_]Instance{.{}} ** MAX_INSTANCES,
    slabs: [MAX_INSTANCES]VariableSlab = [_]VariableSlab{.{}} ** MAX_INSTANCES,
    initialized: bool = false,
    free: [MAX_INSTANCES]u16 = initialFreeStack(),
    free_count: usize = MAX_INSTANCES,
    /// yyRoom.m_Active
    active_instances: [MAX_INSTANCES]*Instance = undefined,
    active_count: usize = 0,
    /// Dynamic active instances (updated during frame loop)
    active_dynamic: [MAX_INSTANCES]*Instance = undefined,
    dynamic_count: usize = 0,
    /// Static active instances (terrain, inert solids)
    active_static: [MAX_INSTANCES]*Instance = undefined,
    static_count: usize = 0,
    /// yyRoom.m_Deactive (deactivation order)
    deactive_instances: [MAX_INSTANCES]*Instance = undefined,
    deactive_count: usize = 0,
    /// yyInstanceManager.m_Instances (creation order)
    all_instances: [MAX_INSTANCES]*Instance = undefined,
    all_count: usize = 0,
    types: [object_mod.MAX_OBJECTS]TypeList = [_]TypeList{.{}} ** object_mod.MAX_OBJECTS,
    id_table: [ID_HASH_SIZE]i16 = [_]i16{ID_EMPTY} ** ID_HASH_SIZE,
    direct_id: [DIRECT_ID_CAP]i16 = [_]i16{ID_EMPTY} ** DIRECT_ID_CAP,
    next_id: i32 = INSTANCE_ID_BASE,

    /// Active instances in draw order (drawOrder), rebuilt only when the
    /// active list or a draw key (floor(depth), layer_serial) changed. Every
    /// active-list mutation and setDepth sets `draw_dirty`.
    draw_sorted: [MAX_INSTANCES]*Instance = undefined,
    draw_sorted_count: usize = 0,
    draw_dirty: bool = true,
    last_draw_out: ?[*]const *Instance = null,
    last_draw_count: usize = 0,
    marked_count: usize = 0,

    /// Draw-cull world boxes of static instances, by slot: the draw pass
    /// culls them from this compact table without reading the instance.
    /// Dropped by `cullForget` (collision.touch, add, promote/demote).
    cull_box: [MAX_INSTANCES][4]f32 = undefined,
    cull_state: [MAX_INSTANCES]CullState = @splat(.unknown),
    /// Draw bucket of each slot's depth (depthBucket), kept by addInstance
    /// and Instance.setDepth, the only writers of `depth`.
    depth_bucket: [MAX_INSTANCES]u8 = @splat(0),
    /// Mirror of each slot's `marked_for_destroy` (set by `destroy`, the
    /// only writer), so reclaim finds marked instances without reading all.
    marked_slot: [MAX_INSTANCES]bool = @splat(false),

    pass_counter: u32 = 0,
    layer_serial_counter: u32 = 0,
    link_serial_counter: u32 = 0,
    hooks: ?*const Hooks = null,

    var instance: InstanceManager = .{};

    pub fn get() *InstanceManager {
        if (!instance.initialized) {
            instance.initPointers();
        }
        return &instance;
    }

    pub fn initPointers(self: *InstanceManager) void {
        for (0..MAX_INSTANCES) |slot_idx| {
            self.pool[slot_idx].slab = &self.slabs[slot_idx];
            self.pool[slot_idx].vars = &self.slabs[slot_idx].vars;
            self.pool[slot_idx].strs = &self.slabs[slot_idx].strs;
            self.pool[slot_idx].vals = &self.slabs[slot_idx].vals;
        }
        self.initialized = true;
    }

    /// Pop order hands out slot 0 first.
    fn initialFreeStack() [MAX_INSTANCES]u16 {
        @setEvalBranchQuota(10 * MAX_INSTANCES);
        var s: [MAX_INSTANCES]u16 = undefined;
        for (0..MAX_INSTANCES) |i| s[i] = @intCast(MAX_INSTANCES - 1 - i);
        return s;
    }

    /// gm_instance_system_reset: everything gone, ids restart at the base,
    /// slot 0 is handed out first.
    pub fn reset(self: *InstanceManager) void {
        if (!self.initialized) {
            self.initPointers();
        }
        for (0..MAX_INSTANCES) |slot_idx| {
            const slot_inst = &self.pool[slot_idx];
            if (slot_inst.in_use) {
                releaseOwned(slot_inst);
                self.slabs[slot_idx].reset();
            }
            const slab = &self.slabs[slot_idx];
            slot_inst.* = .{
                .slab = slab,
                .vars = &slab.vars,
                .strs = &slab.strs,
                .vals = &slab.vals,
            };
        }
        self.free = initialFreeStack();
        self.free_count = MAX_INSTANCES;
        self.active_count = 0;
        self.dynamic_count = 0;
        self.static_count = 0;
        self.deactive_count = 0;
        self.all_count = 0;
        self.draw_sorted_count = 0;
        self.draw_dirty = true;
        self.last_draw_out = null;
        self.last_draw_count = 0;
        @memset(&self.types, .{});
        @memset(&self.id_table, ID_EMPTY);
        @memset(&self.direct_id, ID_EMPTY);
        self.next_id = INSTANCE_ID_BASE;
        self.marked_count = 0;
        @memset(&self.marked_slot, false);
        self.pass_counter = 0;
        self.layer_serial_counter = 0;
        self.link_serial_counter = 0;
        if (self.hooks) |h| if (h.on_reset) |f| f();
    }

    pub fn setHooks(self: *InstanceManager, hooks: ?*const Hooks) void {
        self.hooks = hooks;
    }

    fn hookEnter(self: *InstanceManager, inst: *Instance) void {
        if (self.hooks) |h| if (h.on_enter) |f| f(inst);
    }

    fn hookLeave(self: *InstanceManager, inst: *Instance) void {
        if (self.hooks) |h| if (h.on_leave) |f| f(inst);
    }

    pub fn nextLayerSerial(self: *InstanceManager) u32 {
        self.layer_serial_counter +%= 1;
        return self.layer_serial_counter;
    }

    pub fn nextId(self: *const InstanceManager) i32 {
        return self.next_id;
    }

    pub fn setNextId(self: *InstanceManager, id: i32) void {
        self.next_id = id;
    }

    // ---- lists ------------------------------------------------------------

    fn listRemove(list: []*Instance, len: *usize, inst: *const Instance) void {
        const i = std.mem.indexOfScalar(*Instance, list[0..len.*], @constCast(inst)) orelse return;
        std.mem.copyForwards(*Instance, list[i .. len.* - 1], list[i + 1 .. len.*]);
        len.* -= 1;
    }

    // ---- id table ---------------------------------------------------------

    fn idHome(id: i32) usize {
        const h = @as(u32, @bitCast(id)) *% 2654435761;
        return h >> (32 - ID_HASH_BITS);
    }

    fn idInsert(self: *InstanceManager, inst: *Instance) void {
        const offset = inst.id - INSTANCE_ID_BASE;
        if (offset >= 0 and offset < DIRECT_ID_CAP) {
            self.direct_id[@intCast(offset)] = @intCast(self.slot(inst));
        }
        var i = idHome(inst.id);
        while (self.id_table[i] != ID_EMPTY) i = (i + 1) & (ID_HASH_SIZE - 1);
        self.id_table[i] = @intCast(self.slot(inst));
    }

    fn idFindIndex(self: *const InstanceManager, id: i32) ?usize {
        var i = idHome(id);
        while (self.id_table[i] != ID_EMPTY) {
            if (self.pool[@intCast(self.id_table[i])].id == id) return i;
            i = (i + 1) & (ID_HASH_SIZE - 1);
        }
        return null;
    }

    /// Linear-probing deletion with backward shift (no tombstones).
    fn idRemove(self: *InstanceManager, id: i32) void {
        const offset = id - INSTANCE_ID_BASE;
        if (offset >= 0 and offset < DIRECT_ID_CAP) {
            self.direct_id[@intCast(offset)] = ID_EMPTY;
        }
        var i = self.idFindIndex(id) orelse return;
        var j = i;
        while (true) {
            j = (j + 1) & (ID_HASH_SIZE - 1);
            if (self.id_table[j] == ID_EMPTY) break;
            const k = idHome(self.pool[@intCast(self.id_table[j])].id);
            // Move entry j into the hole at i if its home is not in (i, j].
            if (if (i <= j) (k <= i or k > j) else (k <= i and k > j)) {
                self.id_table[i] = self.id_table[j];
                i = j;
            }
        }
        self.id_table[i] = ID_EMPTY;
    }

    // ---- per-object recursive lists ----------------------------------------

    fn linkFor(inst: *Instance, list_level: i32) *Link {
        const lvl = ObjectRegistry.get().getLevel(inst.object_index);
        return &inst.type_links[@intCast(lvl - list_level)];
    }

    fn typeLinkAll(self: *InstanceManager, inst: *Instance) void {
        const reg = ObjectRegistry.get();
        self.link_serial_counter +%= 1;
        inst.link_serial = self.link_serial_counter;
        var o = inst.object_index;
        while (o != object_mod.OBJECT_NONE) : (o = reg.getParent(o)) {
            const list = &self.types[@intCast(o)];
            const lvl: i32 = reg.getLevel(o);
            const ln = linkFor(inst, lvl);
            ln.prev = list.tail;
            ln.next = null;
            if (list.tail) |t| linkFor(t, lvl).next = inst else list.head = inst;
            list.tail = inst;
            list.count += 1;
        }
    }

    fn typeUnlinkAll(self: *InstanceManager, inst: *Instance) void {
        const reg = ObjectRegistry.get();
        var o = inst.object_index;
        while (o != object_mod.OBJECT_NONE) : (o = reg.getParent(o)) {
            const list = &self.types[@intCast(o)];
            const lvl: i32 = reg.getLevel(o);
            const ln = linkFor(inst, lvl);
            if (ln.prev) |p| linkFor(p, lvl).next = ln.next else list.head = ln.next;
            if (ln.next) |n| linkFor(n, lvl).prev = ln.prev else list.tail = ln.prev;
            ln.* = .{};
            list.count -= 1;
        }
    }

    // ---- lifecycle ----------------------------------------------------------

    fn addInstance(self: *InstanceManager, x: f32, y: f32, depth: f32, obj_index: i32, id: i32) ?*Instance {
        const def = ObjectRegistry.get().getDef(obj_index) orelse return null;
        if (self.free_count == 0) return null;
        self.free_count -= 1;
        const slot_idx = self.free[self.free_count];
        const inst = &self.pool[slot_idx];
        const slab = &self.slabs[slot_idx];
        slab.reset();
        // yyInstance constructor defaults (yyInstance.js L41-150).
        inst.* = .{
            .object_index = obj_index,
            .x = x,
            .y = y,
            .xprevious = x,
            .yprevious = y,
            .xstart = x,
            .ystart = y,
            .slab = slab,
            .vars = &slab.vars,
            .strs = &slab.strs,
            .vals = &slab.vals,
        };
        inst.id = id;
        inst.in_use = true;
        inst.active = true;
        // SetObjectIndex / UpdateSpriteIndex (L938-990)
        inst.sprite_index = def.default_sprite;
        inst.mask_index = def.default_mask;
        inst.solid = def.default_solid;
        inst.visible = def.default_visible;
        inst.persistent = def.default_persistent;
        // GML_AddInstanceDepth takes yyGetInt32(depth).
        inst.depth = @floatFromInt(math.toInt32(depth));
        inst.create_counter = self.pass_counter;
        inst.layer_serial = self.nextLayerSerial();

        self.active_instances[self.active_count] = inst;
        self.active_count += 1;
        self.draw_dirty = true;
        self.all_instances[self.all_count] = inst;
        self.all_count += 1;
        self.typeLinkAll(inst);
        self.idInsert(inst);
        self.hookEnter(inst);

        inst.is_dynamic = !ObjectRegistry.get().isStatic(obj_index);
        self.cull_state[slot_idx] = .unknown;
        self.depth_bucket[slot_idx] = depthBucket(inst.depth);
        self.marked_slot[slot_idx] = false;
        if (inst.is_dynamic) {
            self.active_dynamic[self.dynamic_count] = inst;
            self.dynamic_count += 1;
        } else {
            self.active_static[self.static_count] = inst;
            self.static_count += 1;
        }

        return inst;
    }

    /// gm_instance_add: a new instance with the next id; no events run.
    pub fn add(self: *InstanceManager, x: f32, y: f32, depth: f32, obj_index: i32) ?*Instance {
        const inst = self.addInstance(x, y, depth, obj_index, self.next_id) orelse return null;
        self.next_id += 1;
        return inst;
    }

    /// `add` at the object's default depth.
    pub fn create(self: *InstanceManager, obj_index: i32, x: f32, y: f32) ?*Instance {
        return self.add(x, y, ObjectRegistry.get().getDepth(obj_index), obj_index);
    }

    /// gm_instance_add_with_id: room instances keep the packer's fixed ids.
    pub fn createWithId(self: *InstanceManager, obj_index: i32, x: f32, y: f32, depth: f32, id: i32) ?*Instance {
        if (id < INSTANCE_ID_BASE or self.idFindIndex(id) != null) return null;
        return self.addInstance(x, y, depth, obj_index, id);
    }

    /// instance_create_depth: adds the instance, then runs its (inherited)
    /// Create event unless a pending room switch gates it.
    pub fn createDepth(self: *InstanceManager, x: f32, y: f32, depth: f32, obj_index: i32) ?*Instance {
        const t0 = profile.startSection();
        defer profile.stopSection(.create, t0);
        const inst = self.add(x, y, depth, obj_index) orelse return null;
        if (ObjectRegistry.get().findEvent(obj_index, .create, 0)) |create_fn| {
            if (!room.RoomManager.get().eventBlocked(inst, room.EVENT_TYPE_CREATE)) create_fn(inst, inst);
        }
        return inst;
    }

    /// yyRoom.DeleteInstance as used by ClearInstances: gone at once, no events.
    pub fn removeNow(self: *InstanceManager, inst_opt: ?*Instance) void {
        const inst = inst_opt orelse return;
        if (!inst.in_use) return;
        if (inst.active) {
            self.hookLeave(inst);
            self.typeUnlinkAll(inst);
            listRemove(&self.active_instances, &self.active_count, inst);
            if (inst.is_dynamic) {
                listRemove(&self.active_dynamic, &self.dynamic_count, inst);
            } else {
                listRemove(&self.active_static, &self.static_count, inst);
            }
            self.draw_dirty = true;
        } else {
            listRemove(&self.deactive_instances, &self.deactive_count, inst);
        }
        listRemove(&self.all_instances, &self.all_count, inst);
        if (inst.marked_for_destroy and self.marked_count > 0) self.marked_count -= 1;
        self.marked_slot[self.slot(inst)] = false;
        self.idRemove(inst.id);
        releaseOwned(inst);
        inst.in_use = false;
        inst.active = false;
        self.free[self.free_count] = @intCast(self.slot(inst));
        self.free_count += 1;
    }

    pub fn activeDetach(self: *InstanceManager, inst: *Instance) void {
        if (inst.in_use and inst.active) {
            listRemove(&self.active_instances, &self.active_count, inst);
            if (inst.is_dynamic) {
                listRemove(&self.active_dynamic, &self.dynamic_count, inst);
            } else {
                listRemove(&self.active_static, &self.static_count, inst);
            }
            self.draw_dirty = true;
        }
    }

    pub fn activeAttach(self: *InstanceManager, inst: *Instance) void {
        if (!inst.in_use or !inst.active) return;
        if (std.mem.indexOfScalar(*Instance, self.active_instances[0..self.active_count], inst) != null) return;
        self.active_instances[self.active_count] = inst;
        self.active_count += 1;
        if (inst.is_dynamic) {
            self.active_dynamic[self.dynamic_count] = inst;
            self.dynamic_count += 1;
        } else {
            self.active_static[self.static_count] = inst;
            self.static_count += 1;
        }
        self.draw_dirty = true;
    }

    /// DoDestroy + Command_Destroy (Function_Instance.js L1348, yyInstance.js
    /// L3807): runs the (inherited) Destroy event once, then marks the
    /// instance for reclamation. Deactivated instances cannot be destroyed.
    pub fn destroy(self: *InstanceManager, inst: *Instance) void {
        if (!inst.in_use or inst.marked_for_destroy or !inst.active or inst.being_destroyed) return;
        inst.being_destroyed = true;
        if (ObjectRegistry.get().findEvent(inst.object_index, .destroy, 0)) |destroy_fn| {
            if (!room.RoomManager.get().eventBlocked(inst, room.EVENT_TYPE_DESTROY)) destroy_fn(inst, inst);
        }
        inst.marked_for_destroy = true;
        self.marked_slot[self.slot(inst)] = true;
        self.marked_count += 1;
    }

    inline fn isMarked(self: *const InstanceManager, inst: *const Instance) bool {
        return self.marked_slot[self.slot(inst)];
    }

    fn compactUnmarked(self: *const InstanceManager, list: []*Instance, len: *usize) void {
        var n: usize = 0;
        for (list[0..len.*]) |inst| {
            if (!self.isMarked(inst)) {
                list[n] = inst;
                n += 1;
            }
        }
        len.* = n;
    }

    /// gm_instance_reclaim_marked: frees every marked instance (in creation
    /// order) and returns how many. Marks are read from the slot-indexed
    /// `marked_slot` table: only the marked instances themselves are touched.
    pub fn reclaimMarked(self: *InstanceManager) usize {
        if (self.marked_count == 0) return 0;
        for (self.all_instances[0..self.all_count]) |inst| {
            if (self.isMarked(inst)) {
                if (inst.active) {
                    self.hookLeave(inst);
                    self.typeUnlinkAll(inst);
                }
                self.idRemove(inst.id);
            }
        }
        self.compactUnmarked(&self.active_instances, &self.active_count);
        self.compactUnmarked(&self.active_dynamic, &self.dynamic_count);
        self.compactUnmarked(&self.active_static, &self.static_count);
        self.compactUnmarked(&self.deactive_instances, &self.deactive_count);
        self.draw_dirty = true;
        var n: usize = 0;
        var removed: usize = 0;
        for (self.all_instances[0..self.all_count]) |inst| {
            if (self.isMarked(inst)) {
                releaseOwned(inst);
                inst.in_use = false;
                inst.active = false;
                inst.marked_for_destroy = false;
                self.marked_slot[self.slot(inst)] = false;
                self.free[self.free_count] = @intCast(self.slot(inst));
                self.free_count += 1;
                removed += 1;
            } else {
                self.all_instances[n] = inst;
                n += 1;
            }
        }
        self.all_count = n;
        self.marked_count = 0;
        return removed;
    }

    pub fn initDetached(_: *InstanceManager, inst: *Instance) void {
        inst.* = .{};
        inst.id = 0;
        inst.in_use = false;
        inst.active = false;
    }

    // ---- activation ---------------------------------------------------------

    pub fn deactivate(self: *InstanceManager, inst: *Instance) void {
        if (!inst.in_use or !inst.active) return;
        self.hookLeave(inst);
        listRemove(&self.active_instances, &self.active_count, inst);
        if (inst.is_dynamic) {
            listRemove(&self.active_dynamic, &self.dynamic_count, inst);
        } else {
            listRemove(&self.active_static, &self.static_count, inst);
        }
        self.draw_dirty = true;
        self.typeUnlinkAll(inst);
        self.deactive_instances[self.deactive_count] = inst;
        self.deactive_count += 1;
        inst.active = false;
    }

    pub fn activate(self: *InstanceManager, inst: *Instance) void {
        if (!inst.in_use or inst.active) return;
        listRemove(&self.deactive_instances, &self.deactive_count, inst);
        self.active_instances[self.active_count] = inst;
        self.active_count += 1;
        if (inst.is_dynamic) {
            self.active_dynamic[self.dynamic_count] = inst;
            self.dynamic_count += 1;
        } else {
            self.active_static[self.static_count] = inst;
            self.static_count += 1;
        }
        self.draw_dirty = true;
        self.typeLinkAll(inst);
        inst.active = true;
        self.hookEnter(inst);
    }

    /// instance_(de)activate_object's filter (Function_Instance.js L1685):
    /// same id, or the object is (or inherits from) target. `skip` never
    /// matches; GM_ALL matches everything else.
    fn bulkPicks(inst: *const Instance, target: i32, skip: ?*const Instance) bool {
        if (inst == skip) return false;
        return target == GM_ALL or inst.id == target or ObjectRegistry.get().isA(inst.object_index, target);
    }

    fn compactActive(list: []*Instance, len: *usize) void {
        var n: usize = 0;
        for (list[0..len.*]) |inst| {
            if (inst.active) {
                list[n] = inst;
                n += 1;
            }
        }
        len.* = n;
    }

    /// Deactivates the matching active instances, in active-list order.
    fn deactivateWhere(self: *InstanceManager, target: i32, skip: ?*const Instance) void {
        self.draw_dirty = true;
        var n: usize = 0;
        for (self.active_instances[0..self.active_count]) |inst| {
            if (bulkPicks(inst, target, skip)) {
                self.hookLeave(inst);
                self.typeUnlinkAll(inst);
                self.deactive_instances[self.deactive_count] = inst;
                self.deactive_count += 1;
                inst.active = false;
            } else {
                self.active_instances[n] = inst;
                n += 1;
            }
        }
        self.active_count = n;
        compactActive(&self.active_dynamic, &self.dynamic_count);
        compactActive(&self.active_static, &self.static_count);
    }

    /// Activates the matching deactivated instances, in deactivation order.
    fn activateWhere(self: *InstanceManager, target: i32) void {
        self.draw_dirty = true;
        var n: usize = 0;
        for (self.deactive_instances[0..self.deactive_count]) |inst| {
            if (bulkPicks(inst, target, null)) {
                self.active_instances[self.active_count] = inst;
                self.active_count += 1;
                if (inst.is_dynamic) {
                    self.active_dynamic[self.dynamic_count] = inst;
                    self.dynamic_count += 1;
                } else {
                    self.active_static[self.static_count] = inst;
                    self.static_count += 1;
                }
                self.typeLinkAll(inst);
                inst.active = true;
                self.hookEnter(inst);
            } else {
                self.deactive_instances[n] = inst;
                n += 1;
            }
        }
        self.deactive_count = n;
    }

    pub fn promoteDynamic(self: *InstanceManager, inst: *Instance) void {
        if (inst.is_dynamic) return;
        inst.is_dynamic = true;
        self.cullForget(inst);
        if (inst.active) {
            listRemove(&self.active_static, &self.static_count, inst);
            if (self.dynamic_count < MAX_INSTANCES) {
                self.active_dynamic[self.dynamic_count] = inst;
                self.dynamic_count += 1;
            }
        }
    }

    pub fn demoteStatic(self: *InstanceManager, inst: *Instance) void {
        if (!inst.is_dynamic) return;
        inst.is_dynamic = false;
        self.cullForget(inst);
        if (inst.active) {
            listRemove(&self.active_dynamic, &self.dynamic_count, inst);
            if (self.static_count < MAX_INSTANCES) {
                self.active_static[self.static_count] = inst;
                self.static_count += 1;
            }
        }
    }

    pub fn dynamicCount(self: *const InstanceManager) usize {
        return self.dynamic_count;
    }

    pub fn dynamicAt(self: *InstanceManager, index: usize) ?*Instance {
        return if (index < self.dynamic_count) self.active_dynamic[index] else null;
    }

    pub fn staticCount(self: *const InstanceManager) usize {
        return self.static_count;
    }

    pub fn staticAt(self: *InstanceManager, index: usize) ?*Instance {
        return if (index < self.static_count) self.active_static[index] else null;
    }

    pub fn deactivateObject(self: *InstanceManager, target: i32) void {
        self.deactivateWhere(target, null);
    }

    /// `instance_activate_object(all)` is a no-op in the HTML5 runner.
    pub fn activateObject(self: *InstanceManager, target: i32) void {
        if (target == GM_ALL) return;
        self.activateWhere(target);
    }

    /// Function_Instance.js L1586
    pub fn deactivateAll(self: *InstanceManager, notme: bool, self_inst: ?*const Instance) void {
        self.deactivateWhere(GM_ALL, if (notme) self_inst else null);
    }

    /// Function_Instance.js L1620
    pub fn activateAll(self: *InstanceManager) void {
        self.activateWhere(GM_ALL);
    }

    pub fn deactiveCount(self: *const InstanceManager) usize {
        return self.deactive_count;
    }

    // ---- passes and slots ----------------------------------------------------

    pub fn passBegin(self: *InstanceManager) u32 {
        const p = self.pass_counter;
        self.pass_counter += 1;
        return p;
    }

    pub fn inPass(_: *const InstanceManager, inst: ?*const Instance, pass: u32) bool {
        return inst != null and inst.?.create_counter <= pass;
    }

    pub fn slot(self: *const InstanceManager, inst: *const Instance) usize {
        const base = @intFromPtr(&self.pool[0]);
        const addr = @intFromPtr(inst);
        return (addr - base) / @sizeOf(Instance);
    }

    /// The depth `inst` is drawn at: its bucket's depth (exact for every
    /// depth in `bucket_depths`), from the slot table without reading `inst`.
    pub inline fn drawDepth(self: *const InstanceManager, inst: *const Instance) i32 {
        return bucket_depths[self.depth_bucket[self.slot(inst)]];
    }

    /// True if `inst` lives in the instance pool.
    pub fn owns(self: *const InstanceManager, inst: *const Instance) bool {
        const base = @intFromPtr(&self.pool[0]);
        const addr = @intFromPtr(inst);
        return addr >= base and addr < base + @sizeOf(@TypeOf(self.pool));
    }

    /// The cached draw-cull box of `inst` (if any) no longer holds.
    pub inline fn cullForget(self: *InstanceManager, inst: *const Instance) void {
        self.cull_state[self.slot(inst)] = .unknown;
    }

    pub fn atSlot(self: *InstanceManager, s: usize) ?*Instance {
        if (s < MAX_INSTANCES and self.pool[s].in_use) {
            return &self.pool[s];
        }
        return null;
    }

    pub fn activeAt(self: *InstanceManager, index: usize) ?*Instance {
        return if (index < self.active_count) self.active_instances[index] else null;
    }

    pub fn activeCount(self: *const InstanceManager) usize {
        return self.active_count;
    }

    /// gm_instance_count: allocated instances (creation-order list).
    pub fn totalCount(self: *const InstanceManager) usize {
        return self.all_count;
    }

    // ---- cursors (GetWithArray / Instance_SearchLoop order) -------------------

    /// Unfiltered cursor of gm_instance.c's cursor_init: `all` walks the
    /// active list, self/other yield that instance, objects their
    /// recursive list, ids the allocated instance.
    fn cursorInit(self: *InstanceManager, c: *InstanceCursor, target: i32, self_inst: ?*Instance, other_inst: ?*Instance) void {
        c.* = .{};
        const reg = ObjectRegistry.get();
        if (target == GM_ALL) {
            c.mode = .active;
        } else if (target == GM_SELF or target == GM_OTHER) {
            c.mode = .single;
            c.node = if (target == GM_SELF) self_inst else other_inst;
        } else if (reg.valid(target)) {
            c.mode = .type;
            c.node = self.types[@intCast(target)].head;
            c.list_level = reg.getLevel(target);
        } else if (target >= INSTANCE_ID_BASE) {
            c.mode = .single;
            c.node = self.findById(target);
        }
    }

    fn cursorNext(self: *InstanceManager, c: *InstanceCursor) ?*Instance {
        switch (c.mode) {
            .single => {
                const inst = c.node;
                c.node = null;
                c.mode = .none;
                return inst;
            },
            .active => {
                if (c.index >= self.active_count) return null;
                c.index += 1;
                return self.active_instances[c.index - 1];
            },
            .pool => {
                if (c.index >= self.all_count) return null;
                c.index += 1;
                return self.all_instances[c.index - 1];
            },
            .type => {
                const inst = c.node orelse return null;
                c.node = linkFor(inst, c.list_level).next;
                return inst;
            },
            .none => return null,
        }
    }

    /// Next instance passing the GetWithArray filter (active, not marked).
    fn cursorNextUsable(self: *InstanceManager, c: *InstanceCursor) ?*Instance {
        while (self.cursorNext(c)) |inst| {
            if (usable(inst) != null) return inst;
        }
        return null;
    }

    fn usable(inst: ?*Instance) ?*Instance {
        const p = inst orelse return null;
        return if (p.in_use and p.active and !p.marked_for_destroy) p else null;
    }

    /// Instance_SearchLoop order: `all` walks the instance manager list
    /// (creation order), self/other/noone find nothing, objects and ids as
    /// the cursor. `searchNext` yields usable instances.
    pub fn searchBegin(self: *InstanceManager, c: *InstanceCursor, target: i32) void {
        if (target == GM_ALL) {
            c.* = .{ .mode = .pool };
        } else if (target < 0) {
            c.* = .{};
        } else {
            self.cursorInit(c, target, null, null);
        }
    }

    pub fn searchNext(self: *InstanceManager, c: *InstanceCursor, target: i32) ?*Instance {
        _ = target;
        return self.cursorNextUsable(c);
    }

    /// The `n`th usable instance a target denotes from the caller's
    /// (self, other): self, other, an id, all, or an object (with children).
    pub fn find(self: *InstanceManager, target: i32, n: i32, self_inst: ?*Instance, other_inst: ?*Instance) ?*Instance {
        if (n < 0) return null;
        const t0 = profile.startSection();
        defer profile.stopSection(.lookup, t0);
        var c: InstanceCursor = .{};
        self.cursorInit(&c, target, self_inst, other_inst);
        var left = n;
        while (self.cursorNextUsable(&c)) |inst| {
            if (left == 0) return inst;
            left -= 1;
        }
        return null;
    }

    pub fn resolve(self: *InstanceManager, target: i32, self_inst: ?*Instance, other_inst: ?*Instance) ?*Instance {
        return self.find(target, 0, self_inst, other_inst);
    }

    /// instance_number: usable instances the target denotes.
    pub fn number(self: *InstanceManager, target: i32, self_inst: ?*Instance, other_inst: ?*Instance) usize {
        const t0 = profile.startSection();
        defer profile.stopSection(.lookup, t0);
        if (target == GM_ALL and self.active_count == 0) return 0;
        if (target >= INSTANCE_ID_BASE) {
            if (self.findById(target)) |inst| {
                return if (usable(inst) != null) 1 else 0;
            }
            return 0;
        }
        const reg = ObjectRegistry.get();
        if (reg.valid(target)) {
            if (self.types[@intCast(target)].count == 0) return 0;
        }
        var c: InstanceCursor = .{};
        self.cursorInit(&c, target, self_inst, other_inst);
        var cnt: usize = 0;
        while (self.cursorNextUsable(&c) != null) cnt += 1;
        return cnt;
    }

    pub fn exists(self: *InstanceManager, target: i32) bool {
        if (target == GM_ALL and self.active_count == 0) return false;
        if (target >= INSTANCE_ID_BASE) {
            if (self.findById(target)) |inst| {
                return usable(inst) != null;
            }
            return false;
        }
        const reg = ObjectRegistry.get();
        if (reg.valid(target)) {
            if (self.types[@intCast(target)].count == 0) return false;
        }
        return self.resolve(target, null, null) != null;
    }

    pub fn count(self: *InstanceManager, target: i32) usize {
        return self.number(target, null, null);
    }

    /// with(): the usable instances a target denotes, in iteration order.
    /// Null when the set does not fit `out` (gm_instance_with_snapshot's -1).
    pub fn withSnapshot(self: *InstanceManager, target: i32, self_inst: ?*Instance, other_inst: ?*Instance, out: []*Instance) ?usize {
        const t0 = profile.startSection();
        defer profile.stopSection(.with, t0);
        var c: InstanceCursor = .{};
        self.cursorInit(&c, target, self_inst, other_inst);
        var n: usize = 0;
        while (self.cursorNextUsable(&c)) |inst| {
            if (n == out.len) return null;
            out[n] = inst;
            n += 1;
        }
        return n;
    }

    /// Instances in an object's recursive list (active ones, incl. marked).
    pub fn objectListCount(self: *const InstanceManager, object_index: i32) usize {
        if (!ObjectRegistry.get().valid(object_index)) return 0;
        return self.types[@intCast(object_index)].count;
    }

    /// The object's recursive list, unfiltered (the collision pass pools).
    pub fn objectPool(self: *InstanceManager, object_index: i32, out: []*Instance) usize {
        if (!ObjectRegistry.get().valid(object_index)) return 0;
        var c: InstanceCursor = .{};
        self.cursorInit(&c, object_index, null, null);
        var n: usize = 0;
        while (self.cursorNext(&c)) |inst| {
            if (n == out.len) break;
            out[n] = inst;
            n += 1;
        }
        return n;
    }

    /// Instance_SearchLoop2 (Globals.js L1549): the nearest usable instance
    /// by squared distance; the first one wins ties. `all` walks the
    /// creation-order list; objects and ids the cursor.
    pub fn nearest(self: *InstanceManager, x: f32, y: f32, target: i32) ?*Instance {
        const t0 = profile.startSection();
        defer profile.stopSection(.nearest, t0);
        var best: f32 = 10000000000.0;
        var found: ?*Instance = null;
        if (target == GM_ALL) {
            for (self.all_instances[0..self.all_count]) |inst| {
                if (usable(inst) != null) nearestConsider(inst, x, y, &best, &found);
            }
        } else if (ObjectRegistry.get().valid(target) or target >= INSTANCE_ID_BASE) {
            var c: InstanceCursor = .{};
            self.cursorInit(&c, target, null, null);
            while (self.cursorNextUsable(&c)) |inst| nearestConsider(inst, x, y, &best, &found);
        }
        return found;
    }

    fn nearestConsider(inst: *Instance, x: f32, y: f32, best: *f32, found: *?*Instance) void {
        const xx = x - inst.x;
        const yy = y - inst.y;
        const d = xx * xx + yy * yy;
        if (d < best.*) {
            best.* = d;
            found.* = inst;
        }
    }

    /// g_pInstanceManager.Get(id) / gm_instance_find_by_id: the allocated
    /// instance with this id, including one already marked for destruction
    /// (ids are only released when the instance is reclaimed). Callers that
    /// need a usable instance check `active` / `marked_for_destroy`.
    pub fn findById(self: *InstanceManager, id: i32) ?*Instance {
        const offset = id - INSTANCE_ID_BASE;
        if (offset >= 0 and offset < DIRECT_ID_CAP) {
            const s = self.direct_id[@intCast(offset)];
            if (s != ID_EMPTY) return &self.pool[@intCast(s)];
            return null;
        }
        const i = self.idFindIndex(id) orelse return null;
        return &self.pool[@intCast(self.id_table[i])];
    }

    /// Draw buckets, deepest first: every depth the game's objects use.
    /// Depths not listed share the bucket of the next shallower entry.
    const bucket_depths = [_]i32{
        1000000000, 99999999, 9999999, 999999, 99999, 10000, 9999, 9003, 9000, 8999,
        1000,       999,      998,     997,    995,   900,   201,  200,  150,  120,
        110,        108,      101,     100,    99,    60,    55,   51,   50,   49,
        40,         30,       20,      10,     2,     1,     0,    -2,   -10,  -999999,
        -99999991,
    };
    const BUCKET_COUNT: usize = bucket_depths.len;

    fn depthBucket(depth: f32) u8 {
        const d = math.toInt32(@floor(depth));
        for (bucket_depths, 0..) |bd, b| {
            if (d >= bd) return @intCast(b);
        }
        return BUCKET_COUNT - 1;
    }

    /// Counting sort into depth buckets, no comparison sort. Within a bucket,
    /// newer instances (later in the active list) draw first. Buckets come
    /// from the slot-indexed `depth_bucket` table, so no instance is read.
    fn rebuildDrawOrder(self: *InstanceManager) void {
        const S = struct {
            var bucket_of: [MAX_INSTANCES]u8 = undefined;
        };
        const n = @min(self.active_count, MAX_INSTANCES);

        var counts = [_]u16{0} ** BUCKET_COUNT;
        for (self.active_instances[0..n], 0..) |inst, i| {
            const b = self.depth_bucket[self.slot(inst)];
            S.bucket_of[i] = b;
            counts[b] += 1;
        }

        var offsets: [BUCKET_COUNT]u16 = undefined;
        var curr: u16 = 0;
        for (0..BUCKET_COUNT) |b| {
            offsets[b] = curr;
            curr += counts[b];
        }

        var i: usize = n;
        while (i > 0) {
            i -= 1;
            const b = S.bucket_of[i];
            self.draw_sorted[offsets[b]] = self.active_instances[i];
            offsets[b] += 1;
        }

        self.draw_sorted_count = n;
    }

    /// Unmarked active instances in draw order (depth buckets).
    /// The order is cached: most frames call this several times (one per draw
    /// event and view) with no change in between. Filtering marked instances
    /// after bucketing gives the same order as filtering before.
    pub fn drawOrder(self: *InstanceManager, out: []*Instance) usize {
        if (!self.draw_dirty and self.last_draw_out == out.ptr and self.marked_count == 0) {
            return self.last_draw_count;
        }

        if (self.draw_dirty) {
            self.rebuildDrawOrder();
            self.draw_dirty = false;
        }

        // Nothing marked (the usual case at draw time: reclaim runs first):
        // a plain copy, without reading every instance's flag.
        if (self.marked_count == 0) {
            const n = @min(self.draw_sorted_count, out.len);
            @memcpy(out[0..n], self.draw_sorted[0..n]);
            self.last_draw_out = out.ptr;
            self.last_draw_count = n;
            return n;
        }

        var n: usize = 0;
        for (self.draw_sorted[0..self.draw_sorted_count]) |inst| {
            if (n == out.len) break;
            if (!inst.marked_for_destroy) {
                out[n] = inst;
                n += 1;
            }
        }
        self.last_draw_out = out.ptr;
        self.last_draw_count = n;
        return n;
    }
};

/// Retires the instance's owned strings and arrays (used by
/// `reset`, `removeNow` and `reclaimMarked`). The slot is about to be reused,
/// so its views must not outlive it.
fn releaseOwned(inst: *Instance) void {
    const sm = StringManager.get();
    for (inst.strs) |*s| sm.release(s);
    for (inst.vals) |*v| sm.releaseValue(v);
}

pub const InstanceCursor = struct {
    mode: enum { none, single, active, type, pool } = .none,
    node: ?*Instance = null,
    index: usize = 0,
    list_level: i32 = 0,
};

pub fn deref(target: i32, self_inst: ?*Instance, other_inst: ?*Instance) ?*Instance {
    if (target == GM_SELF) return self_inst;
    if (target == GM_OTHER) return other_inst;
    if (target >= INSTANCE_ID_BASE) return InstanceManager.get().findById(target);
    return InstanceManager.get().find(target, 0, null, null);
}

const test_defs = [_]object_mod.ObjectDef{ .{ .name = "oZero" }, .{ .name = "oOne" } };

test "Instance creation, coupled properties, and destruction lifecycle" {
    try std.testing.expect(ObjectRegistry.get().initRegistry(&test_defs));
    var mgr = InstanceManager.get();
    mgr.reset();

    const inst1 = mgr.create(1, 100.0, 200.0);
    try std.testing.expect(inst1 != null);
    const p1 = inst1.?;

    try std.testing.expectEqual(@as(i32, INSTANCE_ID_BASE), p1.id);
    try std.testing.expectEqual(@as(f32, 100.0), p1.x);
    try std.testing.expectEqual(@as(f32, 200.0), p1.y);

    // Coupled motion property check: setting speed and direction updates hspeed and vspeed
    p1.setSpeed(10.0);
    p1.setDirection(0.0);
    try std.testing.expectEqual(@as(f32, 10.0), p1.hspeed);
    try std.testing.expectEqual(@as(f32, 0.0), p1.vspeed);

    // Setting hspeed updates speed and direction
    p1.setHspeed(0.0);
    p1.setVspeed(-10.0);
    try std.testing.expectEqual(@as(f32, 10.0), p1.speed);
    try std.testing.expectEqual(@as(f32, 90.0), p1.direction);

    // Existence and counting
    try std.testing.expect(mgr.exists(p1.id));
    try std.testing.expect(mgr.exists(1));
    try std.testing.expectEqual(@as(usize, 1), mgr.count(1));

    // Destroy and reclaim
    mgr.destroy(p1);
    try std.testing.expect(!mgr.exists(p1.id));
    _ = mgr.reclaimMarked();
    try std.testing.expectEqual(@as(usize, 0), mgr.count(1));
}

test "instance teardown releases owned strings and arrays" {
    try std.testing.expect(ObjectRegistry.get().initRegistry(&test_defs));
    const mgr = InstanceManager.get();
    const sm = StringManager.get();
    mgr.reset();
    sm.reset();
    defer sm.reset();

    const a = mgr.create(1, 0.0, 0.0).?;
    const b = mgr.create(1, 0.0, 0.0).?;
    const c = mgr.create(1, 0.0, 0.0).?;
    for ([_]*Instance{ a, b, c }) |inst| {
        sm.assign(&inst.strs[0], "owned string");
        sm.assignValue(&inst.vals[0], Value.fromString("owned value"));
    }
    try std.testing.expectEqual(@as(usize, 6 * 16), sm.store.live_bytes);

    mgr.removeNow(a);
    try std.testing.expectEqualStrings("", a.strs[0]);
    try std.testing.expectEqual(@as(usize, 4 * 16), sm.store.live_bytes);

    mgr.destroy(b);
    _ = mgr.reclaimMarked();
    try std.testing.expectEqual(@as(usize, 2 * 16), sm.store.live_bytes);

    mgr.reset();
    try std.testing.expectEqual(@as(usize, 0), sm.store.live_bytes);
    try std.testing.expect(c.vals[0] == .undefined);

    // Arrays (and their element strings) owned by instance vars go too.
    const arrays = @import("value.zig").ArrayManager.get();
    const d = mgr.create(1, 0.0, 0.0).?;
    arrays.set(.persistent(&d.vals[1]), 2, Value.fromString("element"));
    try std.testing.expectEqual(@as(usize, 1), arrays.liveCount());
    mgr.removeNow(d);
    try std.testing.expectEqual(@as(usize, 0), arrays.liveCount());
    try std.testing.expectEqual(@as(usize, 0), sm.store.live_bytes);
}
