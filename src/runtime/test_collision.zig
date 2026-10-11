//! C parity: tests/test_collision.c. Golden data comes from the
//! GameMaker-HTML5 runner's own collision code
//! (tests/golden/gen_collision_golden.js), read through translate-c so the C
//! and Zig suites share one copy.

const std = @import("std");
const testing = std.testing;
const golden = @import("collision_golden");
const collision = @import("collision.zig");
const instance = @import("instance.zig");
const object = @import("object.zig");
const sprite = @import("sprite.zig");

const Instance = instance.Instance;
const InstanceManager = instance.InstanceManager;
const ObjectDef = object.ObjectDef;
const ObjectRegistry = object.ObjectRegistry;
const SpriteDef = sprite.SpriteDef;
const SpriteRegistry = sprite.SpriteRegistry;
const GM_ALL = instance.GM_ALL;
const GM_SELF = instance.GM_SELF;
const GM_NOONE = instance.GM_NOONE;

const OBJ_BLOCK = 0; // oSolid-like root, grid indexed
const OBJ_BRICK = 1; // parent BLOCK
const OBJ_PUSH = 2; // parent BLOCK (a "moving solid")
const OBJ_THING = 3; // unrelated root
const OBJ_ITEM = 4; // parent THING
const OBJ_COUNT = 5;

// Sprite indices into GOLDEN_SPRITES (see gen_collision_golden.js).
const SPR_BOX16 = 0; // 16x16 box, origin 0,0
const SPR_PRECISE16 = 1; // precise, origin 8,8, 2 masks
const SPR_ARROW = 2; // precise 8x8, shared mask
const SPR_CHAR = 3; // box, origin 8,16, bbox 4..11 x 0..15
const SPR_NOFRAMES = 5; // no frames
const SPR_SOLID16 = 7; // precise, mostly solid
const SPR_TINY = 8;

const sprite_count = golden.GOLDEN_SPRITES.len;
var g_sprites: [sprite_count]SpriteDef = undefined;
var g_defs: [OBJ_COUNT]ObjectDef = undefined;

fn mgr() *InstanceManager {
    return InstanceManager.get();
}

fn setupSprites() void {
    for (&golden.GOLDEN_SPRITES, &g_sprites) |*g, *s| {
        s.* = .{
            .name = "golden",
            .width = g.width,
            .height = g.height,
            .xorigin = g.xorigin,
            .yorigin = g.yorigin,
            .bbox_left = g.bbox_left,
            .bbox_top = g.bbox_top,
            .bbox_right = g.bbox_right,
            .bbox_bottom = g.bbox_bottom,
            .colcheck = @enumFromInt(g.colcheck),
            .frame_count = g.frame_count,
            .mask_count = g.mask_count,
            .masks = if (g.mask_count > 0) golden.GOLDEN_MASK_BYTES[@intCast(g.mask_offset)..].ptr else null,
        };
    }
}

fn defObject(index: usize, name: []const u8, parent: i32, spr: i32) void {
    g_defs[index] = .{ .name = name, .parent_index = parent, .default_sprite = spr, .default_mask = -1, .default_visible = true };
}

/// Fresh world: registries, empty instance pool, collision module without grid.
fn setupWorld() !void {
    defObject(OBJ_BLOCK, "oBlock", object.OBJECT_NONE, SPR_BOX16);
    defObject(OBJ_BRICK, "oBrick", OBJ_BLOCK, SPR_BOX16);
    defObject(OBJ_PUSH, "oPush", OBJ_BLOCK, SPR_BOX16);
    defObject(OBJ_THING, "oThing", object.OBJECT_NONE, SPR_CHAR);
    defObject(OBJ_ITEM, "oItem", OBJ_THING, SPR_ARROW);
    setupSprites();
    try testing.expect(ObjectRegistry.get().initRegistry(&g_defs));
    try testing.expect(SpriteRegistry.get().initRegistry(&g_sprites));
    collision.init();
    mgr().reset();
}

fn spawn(obj: i32, x: f32, y: f32) *Instance {
    return mgr().add(x, y, 0.0, obj).?;
}

// ---- Sprite registry -------------------------------------------------------

test "C Parity: test_sprite_registry" {
    try setupWorld();
    const reg = SpriteRegistry.get();
    try testing.expectEqual(sprite_count, reg.countSprites());
    try testing.expect(reg.valid(0) and !reg.valid(-1) and !reg.valid(@intCast(sprite_count)));
    try testing.expect(reg.getSprite(-1) == null);
    // 12-px-wide bbox -> 2 bytes per row, 15 rows.
    try testing.expectEqual(@as(i32, 2), g_sprites[SPR_PRECISE16].maskStride());
    try testing.expectEqual(@as(usize, 30), g_sprites[SPR_PRECISE16].maskSize());
    try testing.expect(g_sprites[SPR_PRECISE16].getMask(2) == null);
    try testing.expect(g_sprites[SPR_PRECISE16].getMask(1).? == g_sprites[SPR_PRECISE16].masks.? + 30);

    const gen = reg.generation;
    const one_mask = [2]u8{ 0xFF, 0xFF };
    var bad = [1]SpriteDef{.{ .width = 8, .height = 8, .bbox_right = 7, .bbox_bottom = 7, .frame_count = 2, .colcheck = .rotated_rect }};
    try testing.expect(!reg.initRegistry(&bad));
    try testing.expectEqual(@as(usize, 0), reg.countSprites());
    try testing.expect(reg.generation != gen);

    bad[0].colcheck = .precise;
    bad[0].mask_count = 3; // neither 1 nor frame_count
    bad[0].masks = &one_mask;
    try testing.expect(!reg.initRegistry(&bad));
    bad[0].mask_count = 1;
    bad[0].masks = null;
    try testing.expect(!reg.initRegistry(&bad));
    bad[0].masks = &one_mask;
    bad[0].bbox_right = 7;
    bad[0].bbox_bottom = 0;
    try testing.expect(reg.initRegistry(&bad));
    try testing.expect(reg.initRegistry(&.{}));
}

// ---- Golden parity with the HTML5 runner ------------------------------------

var g_golden: [golden.GOLDEN_INSTS.len]*Instance = undefined;

fn setupGolden() !void {
    try setupWorld();
    for (&golden.GOLDEN_INSTS, &g_golden) |*g, *slot| {
        const inst = spawn(OBJ_THING, g.x, g.y);
        inst.sprite_index = g.sprite_index;
        inst.mask_index = g.mask_index;
        inst.image_xscale = g.xscale;
        inst.image_yscale = g.yscale;
        inst.image_angle = g.angle;
        inst.image_index = g.image_index;
        slot.* = inst;
    }
}

test "C Parity: test_golden_bbox" {
    try setupGolden();
    for (&golden.GOLDEN_INSTS, g_golden, 0..) |*g, inst, i| {
        const colcheck = collision.updateBbox(inst);
        if (@abs(inst.bbox_left - g.left) > 1e-3 or @abs(inst.bbox_top - g.top) > 1e-3 or
            @abs(inst.bbox_right - g.right) > 1e-3 or @abs(inst.bbox_bottom - g.bottom) > 1e-3 or
            @intFromEnum(colcheck) != g.colcheck)
        {
            std.debug.print("inst {d}: bbox ({d},{d},{d},{d})/{d}, expected ({d},{d},{d},{d})/{d}\n", .{
                i, inst.bbox_left, inst.bbox_top, inst.bbox_right, inst.bbox_bottom, @intFromEnum(colcheck), g.left, g.top, g.right, g.bottom, g.colcheck,
            });
            return error.TestUnexpectedResult;
        }
    }
}

const ShapeFn = *const fn (*Instance, f32, f32, f32, f32, bool) bool;

fn pointAdapter(inst: *Instance, x1: f32, y1: f32, _: f32, _: f32, prec: bool) bool {
    return collision.testPoint(inst, x1, y1, prec);
}

/// The oracle runs in f64, the runtime in f32: as in the C suite, up to 15
/// boundary cases per kind may differ. `mismatch_log` records them so the
/// cross-check test can compare the exact set with the C build's.
const max_mismatches = 15;

fn checkShapes(what: []const u8, cases: []const golden.golden_shape_t, f: ShapeFn) !void {
    var mismatches: usize = 0;
    for (cases, 0..) |c, i| {
        const hit = f(g_golden[@intCast(c.inst)], c.x1, c.y1, c.x2, c.y2, c.prec != 0);
        if (hit != (c.hit != 0)) {
            mismatches += 1;
            if (mismatches > max_mismatches) {
                std.debug.print("{s} case {d} (inst {d}, {d},{d} -> {d},{d}, prec {d}): got {}\n", .{ what, i, c.inst, c.x1, c.y1, c.x2, c.y2, c.prec, hit });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "C Parity: test_golden_point" {
    try setupGolden();
    try checkShapes("point", &golden.GOLDEN_POINTS, pointAdapter);
}

test "C Parity: test_golden_rectangle" {
    try setupGolden();
    try checkShapes("rectangle", &golden.GOLDEN_RECTS, collision.testRectangle);
}

test "C Parity: test_golden_line" {
    try setupGolden();
    try checkShapes("line", &golden.GOLDEN_LINES, collision.testLine);
}

test "C Parity: test_golden_instance" {
    try setupGolden();
    var mismatches: usize = 0;
    for (&golden.GOLDEN_PAIRS, 0..) |*p, i| {
        const hit = collision.testInstance(g_golden[@intCast(p.a)], g_golden[@intCast(p.b)], p.prec != 0);
        if (hit != (p.hit != 0)) {
            mismatches += 1;
            if (mismatches > max_mismatches) {
                std.debug.print("pair {d} ({d} vs {d}, prec {d}): got {}\n", .{ i, p.a, p.b, p.prec, hit });
                return error.TestUnexpectedResult;
            }
        }
    }
}

// ---- Bounding boxes -----------------------------------------------------------

test "C Parity: test_bbox_basics" {
    try setupWorld();
    const a = spawn(OBJ_THING, 100.0, 50.0); // SPR_CHAR: origin 8,16, bbox 4..11 x 0..15
    try testing.expectEqual(sprite.ColCheck.aabb, collision.updateBbox(a));
    try testing.expectEqual(@as(f32, 96.0), a.bbox_left);
    try testing.expectEqual(@as(f32, 104.0), a.bbox_right);
    try testing.expectEqual(@as(f32, 34.0), a.bbox_top);
    try testing.expectEqual(@as(f32, 50.0), a.bbox_bottom);

    // Plain field writes are picked up without any notification.
    a.x = 10.0;
    a.image_xscale = -1.0;
    _ = collision.updateBbox(a);
    try testing.expectEqual(@as(f32, 6.0), a.bbox_left);
    try testing.expectEqual(@as(f32, 14.0), a.bbox_right);

    // mask_index overrides sprite_index
    a.image_xscale = 1.0;
    a.mask_index = SPR_BOX16;
    _ = collision.updateBbox(a);
    try testing.expectEqual(@as(f32, 10.0), a.bbox_left);
    try testing.expectEqual(@as(f32, 26.0), a.bbox_right);
    try testing.expectEqual(@as(f32, 50.0), a.bbox_top);

    // No sprite: a point box that never collides
    a.mask_index = -1;
    a.sprite_index = -1;
    _ = collision.updateBbox(a);
    try testing.expectEqual(@as(f32, 10.0), a.bbox_left);
    try testing.expectEqual(@as(f32, 10.0), a.bbox_right);
    try testing.expect(!collision.testPoint(a, 10.0, 50.0, false));
    try testing.expect(!collision.testRectangle(a, 0.0, 0.0, 100.0, 100.0, false));

    // Frameless sprites never collide either
    a.sprite_index = SPR_NOFRAMES;
    try testing.expect(!collision.testPoint(a, 10.0, 50.0, false));

    // A new sprite table invalidates cached boxes
    a.sprite_index = SPR_BOX16;
    _ = collision.updateBbox(a);
    try testing.expectEqual(@as(f32, 26.0), a.bbox_right);
    g_sprites[SPR_BOX16].bbox_right = 7;
    try testing.expect(SpriteRegistry.get().initRegistry(&g_sprites));
    _ = collision.updateBbox(a);
    try testing.expectEqual(@as(f32, 18.0), a.bbox_right);
    g_sprites[SPR_BOX16].bbox_right = 15;
}

test "C Parity: test_point_and_rect_edges" {
    try setupWorld();
    const b = spawn(OBJ_BLOCK, 32.0, 32.0); // [32, 48) x [32, 48)

    try testing.expect(collision.testPoint(b, 32.0, 32.0, true));
    try testing.expect(collision.testPoint(b, 47.99, 47.99, true));
    try testing.expect(!collision.testPoint(b, 48.0, 40.0, true));
    try testing.expect(!collision.testPoint(b, 40.0, 48.0, true));
    try testing.expect(!collision.testPoint(b, 31.999, 40.0, true));

    // Rectangles need a non-empty rounded overlap in the AABB path.
    try testing.expect(collision.testRectangle(b, 40.0, 40.0, 60.0, 60.0, false));
    try testing.expect(!collision.testRectangle(b, 48.0, 32.0, 60.0, 47.0, false)); // touching
    try testing.expect(!collision.testRectangle(b, 0.0, 32.0, 32.0, 47.0, false)); // 0-wide
    try testing.expect(collision.testRectangle(b, 0.0, 32.0, 33.0, 47.0, false));
    try testing.expect(collision.testRectangle(b, 60.0, 60.0, 40.0, 40.0, false)); // swapped

    // Lines: the Spelunky probes (isCollisionLeft etc.)
    try testing.expect(collision.testLine(b, 31.0, 40.0, 32.0, 40.0, true));
    try testing.expect(!collision.testLine(b, 30.0, 40.0, 31.0, 40.0, true));
    try testing.expect(collision.testLine(b, 20.0, 20.0, 60.0, 60.0, true));
    try testing.expect(!collision.testLine(b, 20.0, 30.0, 60.0, 31.0, true));

    // Marked instances never collide
    mgr().destroy(b);
    try testing.expect(!collision.testPoint(b, 40.0, 40.0, true));
}

test "C Parity: test_instance_touching" {
    try setupWorld();
    const a = spawn(OBJ_BLOCK, 0.0, 0.0);
    const b = spawn(OBJ_BLOCK, 16.0, 0.0);
    try testing.expect(!collision.testInstance(a, b, true)); // edge contact is not a collision
    b.x = 15.5; // overlap [15.5, 16] rounds to nothing
    try testing.expect(!collision.testInstance(a, b, true));
    b.x = 15.0;
    try testing.expect(collision.testInstance(a, b, true));
    try testing.expect(collision.testInstance(b, a, true));
    try testing.expect(!collision.testInstance(a, a, true)); // never with itself
    b.x = 15.6; // overlap rounds to nothing: floor(15.6+.5) == floor(16+.5)
    try testing.expect(!collision.testInstance(a, b, false));
}

// ---- Queries ----------------------------------------------------------------------

test "C Parity: test_queries_order_and_filters" {
    try setupWorld();
    const b1 = spawn(OBJ_BLOCK, 0.0, 0.0);
    const brick = spawn(OBJ_BRICK, 0.0, 0.0);
    const b2 = spawn(OBJ_BLOCK, 0.0, 0.0);
    const thing = spawn(OBJ_THING, 8.0, 16.0); // bbox [4, 12) x [0, 16)

    // First instance in the object's (recursive) list wins.
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, OBJ_BLOCK, false, false) == b1);
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, OBJ_BRICK, false, false) == brick);
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, OBJ_ITEM, false, false) == null);
    // `all` walks creation order
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, GM_ALL, false, false) == b1);
    // notme skips the caller; an id target yields that instance
    try testing.expect(collision.collisionPoint(b1, 5.0, 5.0, OBJ_BLOCK, false, true) == brick);
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, b2.id, false, false) == b2);
    try testing.expect(collision.collisionPoint(b2, 5.0, 5.0, b2.id, false, true) == null);
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, 999999, false, false) == null);
    // self/other/noone find nothing (Instance_SearchLoop)
    try testing.expect(collision.collisionPoint(b1, 5.0, 5.0, GM_SELF, false, false) == null);
    try testing.expect(collision.collisionPoint(b1, 5.0, 5.0, GM_NOONE, false, false) == null);

    // Marked and deactivated instances are skipped.
    mgr().destroy(b1);
    try testing.expect(collision.collisionRectangle(null, 0.0, 0.0, 8.0, 8.0, OBJ_BLOCK, true, false) == brick);
    mgr().deactivate(brick);
    try testing.expect(collision.collisionLine(null, 0.0, 4.0, 8.0, 4.0, OBJ_BLOCK, true, false) == b2);
    // Reactivation appends to the object list: brick now comes last.
    mgr().activate(brick);
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, OBJ_BLOCK, false, false) == b2);
    _ = mgr().reclaimMarked();
    try testing.expect(collision.collisionPoint(null, 5.0, 5.0, OBJ_BLOCK, false, true) == b2);

    // instance_position / position_meeting
    try testing.expect(collision.instancePosition(6.0, 6.0, OBJ_THING) == thing);
    try testing.expect(collision.positionMeeting(11.9, 15.9, OBJ_THING));
    try testing.expect(!collision.positionMeeting(12.0, 8.0, OBJ_THING));

    // place_meeting moves the instance temporarily and restores it.
    try testing.expect(collision.placeMeeting(thing, 8.0, 16.0, OBJ_BLOCK));
    try testing.expect(!collision.placeMeeting(thing, 24.0, 16.0, OBJ_BLOCK)); // [20,28): clear
    const hit = collision.instancePlace(thing, 19.0, 16.0, OBJ_BLOCK); // [15,23) overlaps
    try testing.expect(hit == b2);
    try testing.expectEqual(@as(f32, 8.0), thing.x);
    try testing.expectEqual(@as(f32, 16.0), thing.y);
    try testing.expectEqual(@as(f32, 4.0), thing.bbox_left);
    // An instance never meets itself.
    try testing.expect(!collision.placeMeeting(thing, 8.0, 16.0, OBJ_THING));
    try testing.expect(collision.instancePlace(b2, 0.0, 0.0, OBJ_BLOCK) == brick);
}

test "C Parity: test_distance" {
    try setupWorld();
    const a = spawn(OBJ_BLOCK, 0.0, 0.0); // [0,16] box
    _ = spawn(OBJ_BRICK, 40.0, 30.0); // [40,56] x [30,46]

    try testing.expectEqual(@as(f32, 0.0), collision.distanceToPoint(a, 8.0, 8.0));
    try testing.expectEqual(@as(f32, 5.0), collision.distanceToPoint(a, 19.0, 20.0));
    try testing.expectEqual(@sqrt(@as(f32, 24.0 * 24.0 + 14.0 * 14.0)), collision.distanceToObject(a, OBJ_BRICK));
    // Self is included (Instance_SearchLoop2 with notme = false).
    try testing.expectEqual(@as(f32, 0.0), collision.distanceToObject(a, OBJ_BLOCK));
    try testing.expectEqual(collision.NO_DISTANCE, collision.distanceToObject(a, OBJ_ITEM));
    try testing.expectEqual(collision.NO_DISTANCE, collision.distanceToObject(a, 12345678));
}

// ---- Grid -----------------------------------------------------------------------------

test "C Parity: test_grid_setup" {
    try setupWorld();
    var a = spawn(OBJ_BLOCK, 0.0, 0.0);
    _ = spawn(OBJ_THING, 20.0, 20.0);

    try testing.expect(!collision.indexObject(OBJ_COUNT));
    try testing.expect(collision.indexObject(OBJ_BLOCK));
    try testing.expect(collision.indexObject(OBJ_BLOCK)); // idempotent
    try testing.expect(collision.isIndexed(OBJ_BRICK));
    try testing.expect(!collision.isIndexed(OBJ_THING));
    try testing.expectEqual(@as(usize, 0), collision.gridIndexedCount()); // not configured yet

    collision.configureGrid(320.0, 240.0, 16.0);
    try testing.expectEqual(@as(f32, 16.0), collision.gridCellSize());
    try testing.expectEqual(@as(usize, 1), collision.gridIndexedCount());
    const b = spawn(OBJ_BRICK, 16.0, 0.0);
    try testing.expectEqual(@as(usize, 2), collision.gridIndexedCount());

    // Large rooms grow the cell size instead of the storage.
    collision.configureGrid(5000.0, 100.0, 16.0);
    try testing.expectEqual(@as(f32, 64.0), collision.gridCellSize());
    try testing.expectEqual(@as(usize, 2), collision.gridIndexedCount());

    // Lifecycle: deactivate / reclaim leave, activate re-enters, reset clears.
    mgr().deactivate(b);
    try testing.expectEqual(@as(usize, 1), collision.gridIndexedCount());
    mgr().activate(b);
    try testing.expectEqual(@as(usize, 2), collision.gridIndexedCount());
    mgr().destroy(b);
    try testing.expectEqual(@as(usize, 2), collision.gridIndexedCount()); // until reclaim
    try testing.expect(collision.collisionPoint(null, 20.0, 4.0, OBJ_BLOCK, false, false) == null);
    _ = mgr().reclaimMarked();
    try testing.expectEqual(@as(usize, 1), collision.gridIndexedCount());
    mgr().reset();
    try testing.expectEqual(@as(usize, 0), collision.gridIndexedCount());
    try testing.expect(collision.isIndexed(OBJ_BLOCK)); // configuration survives

    // Invalid configuration disables the grid; queries still work.
    a = spawn(OBJ_BLOCK, 0.0, 0.0);
    collision.configureGrid(0.0, 240.0, 16.0);
    try testing.expectEqual(@as(usize, 0), collision.gridIndexedCount());
    try testing.expect(collision.collisionPoint(null, 4.0, 4.0, OBJ_BLOCK, false, false) == a);
}

test "C Parity: test_grid_order_big_and_outside" {
    try setupWorld();
    try testing.expect(collision.indexObject(OBJ_BLOCK));
    collision.configureGrid(256.0, 256.0, 16.0);
    collision.setVerify(true);
    defer collision.setVerify(false);

    // Two blocks on the same cell: list order decides, not cell order.
    const second = spawn(OBJ_BLOCK, 64.0, 64.0);
    const first = spawn(OBJ_BRICK, 72.0, 64.0);
    try testing.expect(collision.collisionPoint(null, 74.0, 70.0, OBJ_BLOCK, false, false) == second);
    mgr().deactivate(second);
    mgr().activate(second);
    try testing.expect(collision.collisionPoint(null, 74.0, 70.0, OBJ_BLOCK, false, false) == first);
    try testing.expect(collision.collisionPoint(null, 74.0, 70.0, OBJ_BRICK, false, false) == first);

    // Oversized (scaled) instances live in the always-tested list.
    const big = spawn(OBJ_PUSH, 128.0, 128.0);
    big.image_xscale = 6.0;
    big.image_yscale = 6.0;
    collision.touch(big);
    try testing.expect(collision.collisionPoint(null, 200.0, 200.0, OBJ_BLOCK, true, false) == big);

    // Out-of-room instances clamp to border cells and are still found.
    const outside = spawn(OBJ_BLOCK, -100.0, 300.0);
    try testing.expect(collision.collisionPoint(null, -90.0, 310.0, OBJ_BLOCK, true, false) == outside);
    try testing.expect(collision.collisionRectangle(null, -200.0, 290.0, -95.0, 1000.0, OBJ_BLOCK, true, false) == outside);

    // A moved instance is found at its new place after touch().
    first.x = 200.0;
    first.y = 16.0;
    collision.touch(first);
    try testing.expect(collision.collisionPoint(null, 204.0, 20.0, OBJ_BLOCK, true, false) == first);

    // place_meeting for an indexed caller excludes itself.
    try testing.expect(collision.instancePlace(first, 200.0, 16.0, OBJ_BLOCK) == null);
    try testing.expectEqual(@as(usize, 0), collision.verifyFailures());

    // Untracked moves are what verify mode is for; sync repairs the grid.
    first.x = 32.0;
    first.y = 200.0;
    try testing.expect(collision.collisionPoint(null, 36.0, 204.0, OBJ_BLOCK, true, false) == null);
    try testing.expectEqual(@as(usize, 1), collision.verifyFailures());
    collision.gridSync();
    try testing.expect(collision.collisionPoint(null, 36.0, 204.0, OBJ_BLOCK, true, false) == first);
    try testing.expectEqual(@as(usize, 1), collision.verifyFailures());
}

// Deterministic LCG for the differential test (C uses double arithmetic).
var g_lcg: u32 = 0;

fn lcg() u32 {
    g_lcg = g_lcg *% 1664525 +% 1013904223;
    return g_lcg >> 8;
}

fn lcgRange(lo: f32, hi: f32) f32 {
    const t: f64 = @as(f64, @floatFromInt(lcg() & 0xFFFF)) / 65536.0;
    return @floatCast(@as(f64, lo) + @as(f64, hi - lo) * t);
}

fn lcgCoord(lo: f32, hi: f32) f32 {
    const v: f64 = lcgRange(lo, hi);
    return @floatCast(switch (lcg() % 4) {
        0 => @floor(v / 16.0) * 16.0, // tile aligned
        1 => @floor(v),
        2 => @floor(v * 4.0) / 4.0,
        else => v,
    });
}

const block_objs = [_]i32{ OBJ_BLOCK, OBJ_BRICK, OBJ_PUSH };
const block_sprites = [_]i32{ SPR_BOX16, SPR_BOX16, SPR_SOLID16, SPR_PRECISE16, SPR_TINY };

fn spawnRandomBlock() *Instance {
    const obj = block_objs[lcg() % block_objs.len];
    const x = lcgCoord(-40.0, 360.0);
    const b = spawn(obj, x, lcgCoord(-40.0, 280.0));
    b.sprite_index = block_sprites[lcg() % block_sprites.len];
    if (lcg() % 16 == 0) {
        b.image_xscale = lcgRange(0.5, 5.0);
        b.image_yscale = b.image_xscale;
    }
    b.image_index = @floatFromInt(lcg() % 3);
    collision.touch(b);
    return b;
}

fn coin() bool {
    return lcg() % 2 == 0;
}

// Randomized differential test: every grid query is checked against the
// linear Instance_SearchLoop walk while instances are created, moved,
// rescaled, destroyed, reclaimed, deactivated and reactivated.
test "C Parity: test_grid_differential" {
    try setupWorld();
    try testing.expect(collision.indexObject(OBJ_BLOCK));
    collision.configureGrid(320.0, 240.0, 16.0);
    g_lcg = 12345;

    var ids: [400]i32 = undefined; // by id: reclaimed slots are reused
    var nblocks: usize = 0;
    for (0..300) |_| {
        ids[nblocks] = spawnRandomBlock().id;
        nblocks += 1;
    }
    const actor = spawn(OBJ_THING, 100.0, 100.0);
    collision.setVerify(true);
    defer collision.setVerify(false);

    var found: usize = 0;
    for (0..6000) |_| {
        const op = lcg() % 100;
        var target = block_objs[lcg() % block_objs.len];
        const x = lcgCoord(-60.0, 380.0);
        const y = lcgCoord(-60.0, 300.0);
        const pick = mgr().findById(ids[lcg() % @as(u32, @intCast(nblocks))]) orelse return error.TestUnexpectedResult;
        var hit: ?*Instance = null;

        if (lcg() % 8 == 0) target = OBJ_BLOCK;
        if (op < 20) {
            const prec = coin();
            hit = collision.collisionPoint(pick, x, y, target, prec, coin());
        } else if (op < 35) {
            const x2 = x + lcgRange(-40.0, 40.0);
            const y2 = y + lcgRange(-40.0, 40.0);
            const prec = coin();
            hit = collision.collisionRectangle(pick, x, y, x2, y2, target, prec, coin());
        } else if (op < 50) {
            const x2 = x + lcgRange(-60.0, 60.0);
            const y2 = y + lcgRange(-60.0, 60.0);
            const prec = coin();
            hit = collision.collisionLine(pick, x, y, x2, y2, target, prec, coin());
        } else if (op < 60) {
            actor.image_xscale = if (lcg() % 4 == 0) -1.0 else 1.0;
            hit = collision.instancePlace(actor, x, y, target);
        } else if (op < 65) {
            // an indexed instance probing around itself
            hit = collision.instancePlace(pick, pick.x + lcgRange(-2.0, 2.0), pick.y + 1.0, target);
        } else if (op < 70) {
            hit = collision.instancePosition(x, y, target);
        } else if (op < 82) {
            pick.x += lcgRange(-24.0, 24.0);
            pick.y += lcgRange(-24.0, 24.0);
            if (lcg() % 10 == 0) pick.image_xscale = -pick.image_xscale;
            collision.touch(pick);
        } else if (op < 86) {
            mgr().destroy(pick);
        } else if (op < 89) {
            _ = mgr().reclaimMarked();
            for (ids[0..nblocks]) |*id| {
                if (mgr().findById(id.*) == null) id.* = spawnRandomBlock().id;
            }
        } else if (op < 93) {
            mgr().deactivate(pick);
        } else if (op < 97) {
            mgr().activate(pick);
        } else if (nblocks < ids.len) {
            ids[nblocks] = spawnRandomBlock().id;
            nblocks += 1;
        }
        if (hit != null) found += 1;
    }
    try testing.expectEqual(@as(usize, 0), collision.verifyFailures());
    try testing.expect(found > 500); // the test must actually exercise hits
}

// Re-entering a room re-creates its instances with the same fixed ids, often
// in the same slot (LIFO free stack). The stale bbox cache must not survive.
test "fixed-id instance recreated in the same slot" {
    try setupWorld();
    const id = instance.INSTANCE_ID_BASE + 7;
    for (0..2) |pass| {
        if (pass == 1) {
            try testing.expect(collision.indexObject(OBJ_BLOCK));
            collision.configureGrid(320.0, 240.0, 16.0);
            collision.setVerify(true);
        }
        const a = mgr().createWithId(OBJ_BLOCK, 32.0, 48.0, 0.0, id).?;
        try testing.expect(collision.collisionPoint(null, 40.0, 56.0, OBJ_BLOCK, false, false) == a);
        mgr().removeNow(a);

        const b = mgr().createWithId(OBJ_BLOCK, 32.0, 48.0, 0.0, id).?;
        try testing.expect(b == a); // same slot: the case the cache got wrong
        try testing.expect(collision.collisionPoint(null, 40.0, 56.0, OBJ_BLOCK, false, false) == b);
        try testing.expectEqual(@as(f32, 32.0), b.bbox_left);
        mgr().removeNow(b);
    }
    try testing.expectEqual(@as(usize, 0), collision.verifyFailures());
    collision.setVerify(false);
}

test "queryGridCandidates broadphase culling and ordering" {
    try setupWorld();
    var out: [16]*Instance = undefined;

    const actor = spawn(OBJ_THING, 32.0, 32.0);

    // 1. Unindexed target returns null even before grid config
    try testing.expect(collision.queryGridCandidates(actor, OBJ_THING, &out) == null);

    // 2. Target indexed, but grid not active returns null
    try testing.expect(collision.indexObject(OBJ_BLOCK));
    try testing.expect(collision.queryGridCandidates(actor, OBJ_BLOCK, &out) == null);

    // 3. Configure grid (16px cells in 320x240 room)
    collision.configureGrid(320.0, 240.0, 16.0);

    // Spawn 3 blocks: block1 and block2 near actor, block3 far away (cell (10, 10))
    const b1 = spawn(OBJ_BLOCK, 30.0, 30.0);
    const b2 = spawn(OBJ_BLOCK, 34.0, 34.0);
    const b3 = spawn(OBJ_BLOCK, 160.0, 160.0);

    // queryGridCandidates should cull b3 and return only b1 and b2
    const cnt1 = collision.queryGridCandidates(actor, OBJ_BLOCK, &out);
    try testing.expect(cnt1 != null);
    try testing.expectEqual(@as(usize, 2), cnt1.?);
    try testing.expectEqual(b1, out[0]);
    try testing.expectEqual(b2, out[1]);

    // 4. Creation-order parity: b1 has lower link_serial than b2
    try testing.expect(b1.link_serial < b2.link_serial);
    try testing.expect(out[0].link_serial < out[1].link_serial);

    // 5. Destroyed instance is excluded
    mgr().destroy(b1);
    const cnt2 = collision.queryGridCandidates(actor, OBJ_BLOCK, &out);
    try testing.expect(cnt2 != null);
    try testing.expectEqual(@as(usize, 1), cnt2.?);
    try testing.expectEqual(b2, out[0]);

    // 6. Child object (OBJ_BRICK has parent OBJ_BLOCK)
    const brick = spawn(OBJ_BRICK, 36.0, 36.0);
    const cnt3 = collision.queryGridCandidates(actor, OBJ_BLOCK, &out);
    try testing.expect(cnt3 != null);
    try testing.expectEqual(@as(usize, 2), cnt3.?);
    try testing.expectEqual(b2, out[0]);
    try testing.expectEqual(brick, out[1]);

    // 7. Oversize block (> 4 cells, lives in big_head) is also returned
    const big = spawn(OBJ_BLOCK, 20.0, 20.0);
    big.image_xscale = 4.0;
    big.image_yscale = 4.0;
    collision.touch(big);
    const cnt4 = collision.queryGridCandidates(actor, OBJ_BLOCK, &out);
    try testing.expect(cnt4 != null);
    // Contains b2, brick, big (b1 is destroyed, b3 is distant)
    try testing.expectEqual(@as(usize, 3), cnt4.?);
    // All 3 sorted strictly by link_serial
    try testing.expect(out[0].link_serial < out[1].link_serial);
    try testing.expect(out[1].link_serial < out[2].link_serial);

    _ = b3;
}

test "collision teardown" {
    collision.shutdown();
    mgr().reset();
}
