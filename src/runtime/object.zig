//! Object definition registry, event lookup, and inheritance hierarchy.
//! Follows reference/GameMaker-HTML5/scripts/yyObject.js and packaged_src/src/runtime/gm_object.h.

const std = @import("std");
const sprite_mod = @import("sprite.zig");

pub const MAX_OBJECTS: usize = 1024;
pub const MAX_ANCESTOR_LEVELS: usize = 4;
pub const OBJECT_NONE: i32 = -1;
pub const ALARM_COUNT: usize = 12;

// Forward reference to Instance
pub const Instance = @import("instance.zig").Instance;
pub const EventFn = *const fn (self: *Instance, other: ?*Instance) void;

pub const EventKind = enum(i32) {
    create = 0,
    destroy = 1,
    step_begin = 2,
    step = 3,
    step_end = 4,
    draw = 5,
    alarm = 6,
};

pub const ObjectDef = struct {
    name: []const u8 = "",
    parent_index: i32 = OBJECT_NONE,
    default_sprite: i32 = -1,
    default_mask: i32 = -1,
    default_depth: f32 = 0.0,
    default_solid: bool = false,
    default_visible: bool = true,
    default_persistent: bool = false,
    is_static: bool = false,

    ev_create: ?EventFn = null,
    ev_destroy: ?EventFn = null,
    ev_step_begin: ?EventFn = null,
    ev_step: ?EventFn = null,
    ev_step_end: ?EventFn = null,
    ev_draw: ?EventFn = null,
    ev_alarms: [ALARM_COUNT]?EventFn = [_]?EventFn{null} ** ALARM_COUNT,

    collision_events: ?[*]const ?EventFn = null,
};

pub const MASK_WORDS: usize = (MAX_OBJECTS + 31) / 32;

pub const ObjectRegistry = struct {
    defs: ?[*]const ObjectDef = null,
    count: usize = 0,
    levels: [MAX_OBJECTS]i8 = [_]i8{-1} ** MAX_OBJECTS,
    ancestor_masks: [MAX_OBJECTS][MASK_WORDS]u32 = [_][MASK_WORDS]u32{[_]u32{0} ** MASK_WORDS} ** MAX_OBJECTS,
    static_mask: [MASK_WORDS]u32 = [_]u32{0} ** MASK_WORDS,

    var instance: ObjectRegistry = .{};

    pub fn get() *ObjectRegistry {
        return &instance;
    }

    pub fn reset(self: *ObjectRegistry) void {
        self.defs = null;
        self.count = 0;
        @memset(&self.levels, -1);
        @memset(&self.ancestor_masks, [_]u32{0} ** MASK_WORDS);
        @memset(&self.static_mask, 0);
    }

    pub fn initRegistry(self: *ObjectRegistry, defs: []const ObjectDef) bool {
        self.defs = null;
        self.count = 0;
        @memset(&self.levels, -1);
        @memset(&self.ancestor_masks, [_]u32{0} ** MASK_WORDS);
        @memset(&self.static_mask, 0);

        if (defs.len > MAX_OBJECTS) return false;

        const count: i32 = @intCast(defs.len);
        for (defs, 0..) |d, i| {
            var p = d.parent_index;
            var level: i8 = 0;

            // Self is ancestor of self
            self.ancestor_masks[i][i >> 5] |= @as(u32, 1) << @intCast(i & 31);

            while (p != OBJECT_NONE) {
                if (p < 0 or p >= count) return false;
                level += 1;
                if (level >= MAX_ANCESTOR_LEVELS) return false; // Cycle or too deep
                const up: usize = @intCast(p);
                self.ancestor_masks[i][up >> 5] |= @as(u32, 1) << @intCast(up & 31);
                p = defs[up].parent_index;
            }
            self.levels[i] = level;
        }

        self.defs = defs.ptr;
        self.count = defs.len;

        for (defs, 0..) |d, i| {
            if (d.is_static) {
                self.setStatic(@intCast(i), true);
            }
        }
        self.classifyStaticObjects();

        return true;
    }

    pub inline fn isStatic(self: *const ObjectRegistry, object_index: i32) bool {
        if (object_index < 0) return false;
        const u_obj: usize = @intCast(object_index);
        if (u_obj >= MAX_OBJECTS) return false;
        return (self.static_mask[u_obj >> 5] & (@as(u32, 1) << @intCast(u_obj & 31))) != 0;
    }

    pub inline fn setStatic(self: *ObjectRegistry, object_index: i32, static_val: bool) void {
        if (object_index < 0) return;
        const u_obj: usize = @intCast(object_index);
        if (u_obj >= MAX_OBJECTS) return;
        if (static_val) {
            self.static_mask[u_obj >> 5] |= (@as(u32, 1) << @intCast(u_obj & 31));
        } else {
            self.static_mask[u_obj >> 5] &= ~(@as(u32, 1) << @intCast(u_obj & 31));
        }
    }

    pub fn classifyStaticObjects(self: *ObjectRegistry) void {
        var solid_idx: i32 = -1;
        for (0..self.count) |i| {
            if (self.getDef(@intCast(i))) |def| {
                if (std.mem.eql(u8, def.name, "oSolid")) {
                    solid_idx = @intCast(i);
                    break;
                }
            }
        }
        if (solid_idx == -1) return;

        for (0..self.count) |i| {
            const obj: i32 = @intCast(i);
            const def = self.getDef(obj) orelse continue;
            if (def.default_persistent) continue;

            var has_update = false;
            var curr = obj;
            while (curr != OBJECT_NONE) : (curr = self.getParent(curr)) {
                if (self.getDef(curr)) |d| {
                    if (d.ev_step_begin != null or d.ev_step != null or d.ev_step_end != null) {
                        has_update = true;
                        break;
                    }
                    for (0..ALARM_COUNT) |a| {
                        if (d.ev_alarms[a] != null) {
                            has_update = true;
                            break;
                        }
                    }
                    if (has_update) break;
                }
            }
            // Static instances skip the image pass, so their image_index never
            // advances: an animated default sprite needs the dynamic path.
            if (!has_update and !animatedSprite(def.default_sprite)) {
                self.setStatic(obj, true);
            }
        }
    }

    fn animatedSprite(sprite: i32) bool {
        const spr = sprite_mod.SpriteRegistry.get().getSprite(sprite) orelse return false;
        return spr.frame_count > 1;
    }

    pub fn classifyStaticSolids(self: *ObjectRegistry) void {
        self.classifyStaticObjects();
    }

    pub inline fn countObjects(self: *const ObjectRegistry) usize {
        return self.count;
    }

    pub inline fn valid(self: *const ObjectRegistry, index: i32) bool {
        return index >= 0 and @as(usize, @intCast(index)) < self.count;
    }

    pub fn getDef(self: *const ObjectRegistry, index: i32) ?*const ObjectDef {
        if (!self.valid(index) or self.defs == null) return null;
        return &self.defs.?[@as(usize, @intCast(index))];
    }

    pub fn getParent(self: *const ObjectRegistry, index: i32) i32 {
        const def = self.getDef(index) orelse return OBJECT_NONE;
        return def.parent_index;
    }

    pub fn getDepth(self: *const ObjectRegistry, index: i32) f32 {
        const def = self.getDef(index) orelse return 0.0;
        return def.default_depth;
    }

    pub fn getLevel(self: *const ObjectRegistry, index: i32) i8 {
        if (!self.valid(index)) return -1;
        return self.levels[@as(usize, @intCast(index))];
    }

    pub fn isA(self: *const ObjectRegistry, object_index: i32, query: i32) bool {
        if (object_index < 0 or query < 0) return false;
        if (object_index == query) return true;
        if (!self.valid(object_index) or !self.valid(query)) return false;

        const u_obj: usize = @intCast(object_index);
        const u_query: usize = @intCast(query);
        return (self.ancestor_masks[u_obj][u_query >> 5] & (@as(u32, 1) << @intCast(u_query & 31))) != 0;
    }

    fn eventSlot(d: *const ObjectDef, kind: EventKind, subtype: i32) ?EventFn {
        return switch (kind) {
            .create => d.ev_create,
            .destroy => d.ev_destroy,
            .step_begin => d.ev_step_begin,
            .step => d.ev_step,
            .step_end => d.ev_step_end,
            .draw => d.ev_draw,
            .alarm => if (subtype >= 0 and subtype < ALARM_COUNT) d.ev_alarms[@as(usize, @intCast(subtype))] else null,
        };
    }

    pub fn findEvent(self: *const ObjectRegistry, object_index: i32, kind: EventKind, subtype: i32) ?EventFn {
        if (!self.valid(object_index)) return null;

        var curr = object_index;
        while (curr != OBJECT_NONE) {
            const def = self.getDef(curr) orelse break;
            if (eventSlot(def, kind, subtype)) |fn_ptr| {
                return fn_ptr;
            }
            curr = def.parent_index;
        }
        return null;
    }
};

fn dummyCreate(_: *Instance, _: ?*Instance) void {}
fn dummyParentStep(_: *Instance, _: ?*Instance) void {}
fn dummyChildStep(_: *Instance, _: ?*Instance) void {}

test "ObjectRegistry validation, isA fast-reject, and event inheritance" {
    var reg = ObjectRegistry.get();
    reg.reset();

    var defs = [_]ObjectDef{
        .{
            .name = "oItem",
            .parent_index = OBJECT_NONE,
            .ev_create = dummyCreate,
            .ev_step = dummyParentStep,
        },
        .{
            .name = "oWeapon",
            .parent_index = 0, // parent = oItem
            .ev_create = null, // inherits dummyCreate
            .ev_step = dummyChildStep, // overrides dummyParentStep
        },
        .{
            .name = "oWhip",
            .parent_index = 1, // parent = oWeapon
            .ev_create = null, // inherits dummyCreate
            .ev_step = null, // inherits dummyChildStep
        },
    };

    try std.testing.expect(reg.initRegistry(&defs));
    try std.testing.expectEqual(@as(usize, 3), reg.countObjects());
    try std.testing.expectEqual(@as(i8, 0), reg.getLevel(0));
    try std.testing.expectEqual(@as(i8, 1), reg.getLevel(1));
    try std.testing.expectEqual(@as(i8, 2), reg.getLevel(2));

    // Ancestor checks
    try std.testing.expect(reg.isA(2, 2));
    try std.testing.expect(reg.isA(2, 1));
    try std.testing.expect(reg.isA(2, 0));
    try std.testing.expect(!reg.isA(0, 2));
    try std.testing.expect(!reg.isA(1, 2));

    // Event inheritance resolution
    // oWhip inherits create from oItem
    const ev_create_whip = reg.findEvent(2, .create, 0);
    try std.testing.expect(ev_create_whip == dummyCreate);

    // oWhip inherits step from oWeapon (which overrode oItem)
    const ev_step_whip = reg.findEvent(2, .step, 0);
    try std.testing.expect(ev_step_whip == dummyChildStep);

    // oItem gets its own step
    const ev_step_item = reg.findEvent(0, .step, 0);
    try std.testing.expect(ev_step_item == dummyParentStep);

    // Unregistered event returns null
    try std.testing.expect(reg.findEvent(2, .draw, 0) == null);

    // Cycle detection test
    defs[0].parent_index = 2; // Create cycle 0 -> 2 -> 1 -> 0
    try std.testing.expect(!reg.initRegistry(&defs));
}
