//! C parity: the create/destroy event, query, nearest and activation cases
//! of tests/test_instance.c.

const std = @import("std");
const testing = std.testing;
const instance = @import("instance.zig");
const object = @import("object.zig");
const WithIterator = @import("with.zig").WithIterator;
const RoomManager = @import("room.zig").RoomManager;

const Instance = instance.Instance;
const InstanceManager = instance.InstanceManager;
const ObjectDef = object.ObjectDef;
const ObjectRegistry = object.ObjectRegistry;
const GM_ALL = instance.GM_ALL;
const GM_SELF = instance.GM_SELF;
const GM_OTHER = instance.GM_OTHER;
const GM_NOONE = instance.GM_NOONE;

const OBJ_SOLID = 0;
const OBJ_CHARACTER = 1;
const OBJ_ENEMY = 2;
const OBJ_BAT = 3; // parent ENEMY
const OBJ_VAMPIRE_BAT = 4; // parent BAT
const OBJ_SPAWNER = 5; // create: spawns an ENEMY
const OBJ_SELF_DESTRUCT = 6; // create: destroys itself
const OBJ_DESTROY_SPAWN = 7; // destroy: spawns a SOLID
const OBJ_COUNT = 8;

var g_creates: usize = 0;
var g_destroys: usize = 0;
var g_last_self: ?*Instance = null;
var g_last_other: ?*Instance = null;
var g_seen_self_in_with = false;
var g_spawned: ?*Instance = null;

fn mgr() *InstanceManager {
    return InstanceManager.get();
}

fn create(x: f32, y: f32, obj: i32) ?*Instance {
    return mgr().createDepth(x, y, ObjectRegistry.get().getDepth(obj), obj);
}

fn evCharacterCreate(self: *Instance, other: ?*Instance) void {
    g_creates += 1;
    g_last_self = self;
    g_last_other = other;
    self.vars[0] = 42.0;
    // The new instance is already linked when Create runs.
    g_seen_self_in_with = mgr().resolve(OBJ_CHARACTER, self, other) != null and
        mgr().resolve(self.id, null, null) == self;
}

fn evEnemyCreate(self: *Instance, _: ?*Instance) void {
    g_creates += 1;
    self.vars[1] = 7.0;
}

fn evEnemyDestroy(self: *Instance, other: ?*Instance) void {
    g_destroys += 1;
    g_last_self = self;
    g_last_other = other;
    mgr().destroy(self); // must not recurse
}

fn evSpawnerCreate(self: *Instance, _: ?*Instance) void {
    g_spawned = create(self.x + 16.0, self.y, OBJ_ENEMY);
}

fn evSelfDestructCreate(self: *Instance, _: ?*Instance) void {
    mgr().destroy(self);
}

fn evDestroySpawn(self: *Instance, _: ?*Instance) void {
    g_spawned = create(self.x, self.y, OBJ_SOLID);
}

const defs = [OBJ_COUNT]ObjectDef{
    .{ .name = "oSolid", .default_sprite = 3, .default_depth = 1000, .default_solid = true },
    .{ .name = "oCharacter", .default_sprite = 10, .default_mask = 11, .default_depth = -10, .default_persistent = true, .ev_create = evCharacterCreate },
    .{ .name = "oEnemy", .default_depth = 5, .ev_create = evEnemyCreate, .ev_destroy = evEnemyDestroy },
    .{ .name = "oBat", .parent_index = OBJ_ENEMY, .default_depth = 4 },
    .{ .name = "oVampireBat", .parent_index = OBJ_BAT, .default_depth = 4 },
    .{ .name = "oSpawner", .ev_create = evSpawnerCreate },
    .{ .name = "oSelfDestruct", .ev_create = evSelfDestructCreate },
    .{ .name = "oDestroySpawn", .ev_destroy = evDestroySpawn },
};

fn fresh() void {
    RoomManager.get().reset();
    if (!ObjectRegistry.get().initRegistry(&defs)) @panic("object registry");
    mgr().reset();
    mgr().setNextId(instance.INSTANCE_ID_BASE);
    g_creates = 0;
    g_destroys = 0;
    g_last_self = null;
    g_last_other = null;
    g_spawned = null;
    g_seen_self_in_with = false;
}

fn mk(obj: i32, x: f32, y: f32) *Instance {
    return mgr().create(obj, x, y).?;
}

fn iterCollect(target: i32, self: ?*Instance, other: ?*Instance, out: []*Instance) usize {
    var it = WithIterator.init(target, self, other);
    defer it.deinit();
    var n: usize = 0;
    while (it.next()) |inst| : (n += 1) out[n] = inst;
    return n;
}

test "C Parity: test_create_runs_create_event" {
    fresh();
    const c = create(10.0, 20.0, OBJ_CHARACTER).?;
    try testing.expectEqual(@as(usize, 1), g_creates);
    try testing.expect(g_last_self == c and g_last_other == c); // self == other
    try testing.expect(g_seen_self_in_with);
    try testing.expectEqual(@as(f32, 42.0), c.vars[0]);
    try testing.expectEqual(@as(f32, -10.0), c.depth);

    // A child without its own Create inherits the parent's.
    const bat = create(0.0, 0.0, OBJ_VAMPIRE_BAT).?;
    try testing.expectEqual(@as(usize, 2), g_creates);
    try testing.expectEqual(@as(f32, 7.0), bat.vars[1]);
    try testing.expectEqual(@as(f32, 4.0), bat.depth);
    try testing.expect(mgr().createDepth(0, 0, 0, OBJ_COUNT) == null);
}

test "C Parity: test_nested_create_and_self_destroy" {
    fresh();
    const spawner = create(100.0, 50.0, OBJ_SPAWNER).?;
    const spawned = g_spawned.?;
    try testing.expectEqual(@as(i32, OBJ_ENEMY), spawned.object_index);
    try testing.expectEqual(@as(f32, 116.0), spawned.x);
    try testing.expectEqual(spawner.id + 1, spawned.id);
    try testing.expectEqual(@as(usize, 1), g_creates);

    const sd = create(0.0, 0.0, OBJ_SELF_DESTRUCT).?;
    try testing.expect(sd.marked_for_destroy);
    try testing.expect(mgr().resolve(OBJ_SELF_DESTRUCT, null, null) == null);
    try testing.expect(sd.in_use); // until reclaimed
    _ = mgr().reclaimMarked();
    try testing.expect(!sd.in_use);
}

test "C Parity: test_destroy_marks_and_reclaims" {
    fresh();
    const e = create(0.0, 0.0, OBJ_BAT).?;
    const s = mk(OBJ_SOLID, 0.0, 0.0);
    const id = e.id;
    mgr().destroy(e);
    try testing.expectEqual(@as(usize, 1), g_destroys);
    try testing.expect(g_last_self == e and g_last_other == e);
    try testing.expect(e.marked_for_destroy and e.in_use);
    mgr().destroy(e); // already marked: no second Destroy event
    try testing.expectEqual(@as(usize, 1), g_destroys);
    try testing.expect(mgr().resolve(OBJ_ENEMY, null, null) == null);
    try testing.expect(mgr().resolve(id, null, null) == null);
    try testing.expectEqual(@as(usize, 1), mgr().number(GM_ALL, null, null));
    try testing.expectEqual(@as(usize, 2), mgr().totalCount());
    try testing.expectEqual(@as(usize, 2), mgr().activeCount()); // still listed until reclaim

    _ = mgr().reclaimMarked();
    try testing.expectEqual(@as(usize, 1), mgr().totalCount());
    try testing.expectEqual(@as(usize, 1), mgr().activeCount());
    try testing.expect(mgr().activeAt(0) == s);
    try testing.expect(mgr().findById(id) == null);
    try testing.expect(!e.in_use);
    mgr().destroy(e); // stale pointer: ignored
    try testing.expectEqual(@as(usize, 1), g_destroys);
}

test "C Parity: test_destroy_event_can_create" {
    fresh();
    const d = mk(OBJ_DESTROY_SPAWN, 64.0, 80.0);
    mgr().destroy(d);
    try testing.expectEqual(@as(i32, OBJ_SOLID), g_spawned.?.object_index);
    try testing.expectEqual(@as(f32, 80.0), g_spawned.?.y);
    _ = mgr().reclaimMarked();
    try testing.expect(!d.in_use);
    try testing.expect(mgr().resolve(OBJ_SOLID, null, null) != null);
}

test "C Parity: test_deactivated_cannot_be_destroyed_but_marked_can_deactivate" {
    fresh();
    const a = mk(OBJ_ENEMY, 0, 0);
    const b = mk(OBJ_ENEMY, 0, 0);
    mgr().deactivate(a);
    mgr().destroy(a); // DoDestroy requires active
    try testing.expect(!a.marked_for_destroy);
    try testing.expectEqual(@as(usize, 0), g_destroys);

    mgr().destroy(b); // marked, then deactivated before reclaim
    mgr().deactivate(b);
    _ = mgr().reclaimMarked();
    try testing.expect(!b.in_use);
    try testing.expect(a.in_use);
    mgr().activateAll();
    try testing.expectEqual(@as(usize, 1), mgr().activeCount());
    try testing.expect(mgr().activeAt(0) == a);
    try testing.expectEqual(@as(usize, 0), mgr().deactiveCount());
}

test "C Parity: test_queries" {
    fresh();
    const bat = mk(OBJ_BAT, 0, 0);
    const enemy = mk(OBJ_ENEMY, 0, 0);
    const vamp = mk(OBJ_VAMPIRE_BAT, 0, 0);
    const solid = mk(OBJ_SOLID, 0, 0);
    const m = mgr();

    try testing.expectEqual(@as(usize, 3), m.number(OBJ_ENEMY, null, null));
    try testing.expectEqual(@as(usize, 2), m.number(OBJ_BAT, null, null));
    try testing.expectEqual(@as(usize, 1), m.number(OBJ_VAMPIRE_BAT, null, null));
    try testing.expectEqual(@as(usize, 4), m.number(GM_ALL, null, null));
    try testing.expectEqual(@as(usize, 0), m.number(GM_NOONE, null, null));
    try testing.expectEqual(@as(usize, 0), m.number(OBJ_CHARACTER, null, null));
    try testing.expectEqual(@as(usize, 0), m.number(12345, null, null)); // not an object or id
    try testing.expectEqual(@as(usize, 1), m.number(solid.id, null, null));
    try testing.expectEqual(@as(usize, 1), m.number(GM_SELF, bat, null));
    try testing.expectEqual(@as(usize, 0), m.number(GM_OTHER, bat, null));

    try testing.expect(m.resolve(OBJ_ENEMY, null, null) == bat); // first in list
    try testing.expect(m.resolve(GM_OTHER, bat, vamp) == vamp);
    try testing.expect(m.resolve(enemy.id, null, null) == enemy);
    try testing.expect(m.resolve(GM_NOONE, bat, vamp) == null);
    try testing.expect(m.find(OBJ_ENEMY, 0, null, null) == bat);
    try testing.expect(m.find(OBJ_ENEMY, 1, null, null) == enemy);
    try testing.expect(m.find(OBJ_ENEMY, 2, null, null) == vamp);
    try testing.expect(m.find(OBJ_ENEMY, 3, null, null) == null);
    try testing.expect(m.find(OBJ_ENEMY, -1, null, null) == null);
    try testing.expect(m.find(GM_ALL, 3, null, null) == solid);

    // Destroyed instances vanish from queries immediately.
    m.destroy(bat);
    try testing.expect(m.find(OBJ_ENEMY, 0, null, null) == enemy);
    try testing.expectEqual(@as(usize, 1), m.number(OBJ_BAT, null, null));
    try testing.expect(m.resolve(GM_SELF, bat, null) == null);
}

test "C Parity: test_nearest" {
    fresh();
    const m = mgr();
    const a = mk(OBJ_ENEMY, 10, 0);
    const b = mk(OBJ_BAT, -10, 0); // same distance as a from origin
    const c = mk(OBJ_SOLID, 3, 4);
    const d = mk(OBJ_VAMPIRE_BAT, 100, 100);

    try testing.expect(m.nearest(0, 0, GM_ALL) == c);
    try testing.expect(m.nearest(0, 0, OBJ_ENEMY) == a); // tie: first wins
    try testing.expect(m.nearest(0, 0, OBJ_BAT) == b);
    try testing.expect(m.nearest(95, 95, OBJ_ENEMY) == d);
    try testing.expect(m.nearest(0, 0, d.id) == d);
    try testing.expect(m.nearest(0, 0, OBJ_CHARACTER) == null);
    try testing.expect(m.nearest(0, 0, GM_NOONE) == null);
    try testing.expect(m.nearest(1e11, 0, GM_ALL) == null); // beyond 1e10

    // all -> creation order, unaffected by reactivation...
    m.destroy(c);
    m.deactivate(a);
    m.activate(a);
    try testing.expect(m.activeAt(m.activeCount() - 1) == a);
    try testing.expect(m.nearest(0, 0, GM_ALL) == a);
    // ...whereas the object list now has b first.
    try testing.expect(m.nearest(0, 0, OBJ_ENEMY) == b);
}

test "C Parity: test_activation" {
    fresh();
    const m = mgr();
    var out: [8]*Instance = undefined;
    const s = mk(OBJ_SOLID, 0, 0);
    const e = mk(OBJ_ENEMY, 0, 0);
    const b = mk(OBJ_BAT, 0, 0);
    const v = mk(OBJ_VAMPIRE_BAT, 0, 0);
    const ch = mk(OBJ_CHARACTER, 0, 0);

    m.deactivateObject(OBJ_BAT); // bat + vampire bat
    try testing.expect(!b.active and !v.active and e.active);
    try testing.expectEqual(@as(usize, 1), m.number(OBJ_ENEMY, null, null));
    try testing.expect(m.resolve(b.id, null, null) == null);
    try testing.expectEqual(@as(usize, 3), m.activeCount());

    m.activateObject(GM_ALL); // HTML5 quirk: no-op
    try testing.expect(!b.active);
    m.activateObject(OBJ_ENEMY); // reactivates descendants
    try testing.expect(b.active and v.active);
    // Reactivated instances are appended in deactive-list order.
    try testing.expectEqual(@as(usize, 5), iterCollect(GM_ALL, null, null, &out));
    try testing.expect(out[0] == s and out[1] == e and out[2] == ch and out[3] == b and out[4] == v);
    try testing.expectEqual(@as(usize, 3), iterCollect(OBJ_ENEMY, null, null, &out));
    try testing.expect(out[0] == e and out[1] == b and out[2] == v);

    m.deactivateObject(e.id); // by instance id
    try testing.expect(!e.active);
    m.activateObject(e.id);
    try testing.expect(e.active);

    m.deactivateAll(true, ch);
    try testing.expectEqual(@as(usize, 1), m.activeCount());
    try testing.expect(m.activeAt(0) == ch);
    m.activateAll();
    try testing.expectEqual(@as(usize, 5), m.activeCount());
    try testing.expect(m.activeAt(0) == ch);
    try testing.expect(m.activeAt(1) == s);
    m.deactivateAll(false, ch);
    try testing.expectEqual(@as(usize, 0), m.activeCount());
    try testing.expect(m.resolve(GM_ALL, null, null) == null);
    m.deactivateObject(GM_ALL);
    m.activateAll();
    try testing.expectEqual(@as(usize, 5), m.activeCount());
    m.deactivateObject(GM_ALL);
    try testing.expectEqual(@as(usize, 0), m.activeCount());
}

test "instance: draw order bucketing, fallback and caching" {
    fresh();
    const m = mgr();

    const inst1 = m.createDepth(0, 0, 100, OBJ_SOLID).?;
    const inst2 = m.createDepth(0, 0, -10, OBJ_SOLID).?;
    const inst3 = m.createDepth(0, 0, 1000, OBJ_SOLID).?;
    const inst4 = m.createDepth(0, 0, 100, OBJ_SOLID).?;
    const inst5 = m.createDepth(0, 0, 0, OBJ_SOLID).?;

    var out: [16]*Instance = undefined;
    var count_draw = m.drawOrder(&out);
    try testing.expectEqual(@as(usize, 5), count_draw);

    // Order: higher depth drawn first. Same depth: higher layer_serial drawn first.
    try testing.expectEqual(inst3, out[0]);
    try testing.expectEqual(inst4, out[1]);
    try testing.expectEqual(inst1, out[2]);
    try testing.expectEqual(inst5, out[3]);
    try testing.expectEqual(inst2, out[4]);

    // Test cached drawOrder: calling again without changes returns cached count
    const count2 = m.drawOrder(&out);
    try testing.expectEqual(count_draw, count2);

    // Test fallback: create instance with an arbitrary depth not in bucket table
    const i_fallback = m.createDepth(0, 0, 777, OBJ_SOLID).?;
    count_draw = m.drawOrder(&out);
    try testing.expectEqual(@as(usize, 6), count_draw);
    try testing.expectEqual(inst3, out[0]);
    try testing.expectEqual(i_fallback, out[1]);
    try testing.expectEqual(inst4, out[2]);
    try testing.expectEqual(inst1, out[3]);
    try testing.expectEqual(inst5, out[4]);
    try testing.expectEqual(inst2, out[5]);
}

test "instance: tiered pool, static header and variable segregation" {
    // 1. Instance size: should be ~320 bytes (less than 400 bytes, down from 6,400 bytes)
    try testing.expect(@sizeOf(Instance) < 400);

    // 2. StaticInstance size: should be compact (<= 64 bytes)
    try testing.expect(@sizeOf(instance.StaticInstance) <= 64);

    fresh();
    const m = mgr();

    const i_a = m.createDepth(10.0, 20.0, 100, OBJ_SOLID).?;
    const i_b = m.createDepth(30.0, 40.0, 100, OBJ_CHARACTER).?;

    // StaticInstance conversion
    const static_header = instance.StaticInstance.fromInstance(i_a);
    try testing.expectEqual(i_a.id, static_header.id);
    try testing.expectEqual(i_a.object_index, static_header.object_index);
    try testing.expectEqual(@as(f32, 10.0), static_header.x);
    try testing.expectEqual(@as(f32, 20.0), static_header.y);

    // Variable segregation: instances have separate variable slabs
    i_a.vars[10] = 123.45;
    i_b.vars[10] = 678.90;
    try testing.expectEqual(@as(f32, 123.45), i_a.vars[10]);
    try testing.expectEqual(@as(f32, 678.90), i_b.vars[10]);
    try testing.expect(i_a.slab != i_b.slab);

    // Detached / default instance points to dummy slab safely
    const detached: Instance = .{};
    try testing.expect(detached.vars == &instance.dummy_slab.vars);
    try testing.expectEqual(@as(f32, 0.0), detached.vars[0]);
}
