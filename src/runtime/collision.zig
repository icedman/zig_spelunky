//! Bounding boxes, collision primitives, collision queries and a spatial grid
//! for the heavily queried static object trees (oSolid). Port of
//! packaged_src/src/runtime/gm_collision.c, which keeps the reference's
//! operation order so that floating-point results match the GameMaker-HTML5
//! runner with collision compatibility mode OFF:
//!  - bounding boxes: yyInstance.Compute_BoundingBox (yyInstance.js L1455)
//!  - instance tests: yyInstance.Collision_Point / _Rectangle / _Line /
//!    _Instance (L1730, L1807, L2053, L2539)
//!  - precise tests: yySprite.PreciseCollisionPoint / _Rectangle / _Line /
//!    PreciseCollision and ColMaskSet (yySprite.js L2126-2801, L1626)
//!  - queries: Function_Collision.js, Function_Movement.js, Function_Instance.js,
//!    iterating in Instance_SearchLoop order (Globals.js L1464).
//!
//! Omissions (Spelunky never needs them): rotated-rect sprites, collision
//! domains, ellipse/circle queries. self/other/noone as targets find nothing.
//!
//! The bbox is cached against its inputs (x, y, sprite_index, mask_index,
//! image_xscale, image_yscale, image_angle, sprite table generation) and
//! recomputed on use, so plain field writes are always safe for the tests.
//! Grid-indexed instances must be re-bucketed after moving: callers use
//! `touch` after writing a bbox input, and the loop calls `gridSync` between
//! event phases. All state is static; nothing allocates.

const std = @import("std");
const math = @import("math.zig");
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;
const InstanceCursor = instance_mod.InstanceCursor;
const MAX_INSTANCES = instance_mod.MAX_INSTANCES;
const object_mod = @import("object.zig");
const ObjectRegistry = object_mod.ObjectRegistry;
const sprite_mod = @import("sprite.zig");
const SpriteDef = sprite_mod.SpriteDef;
const SpriteRegistry = sprite_mod.SpriteRegistry;
const ColCheck = sprite_mod.ColCheck;
const profile = @import("profile.zig");

/// Grid limits. Cells are square; the cell size doubles until the room fits.
/// Coordinates outside the room clamp to the border cells.
pub const GRID_MAX_COLS: usize = 128;
pub const GRID_MAX_ROWS: usize = 128;
pub const GRID_MAX_ROOTS: usize = 8;
/// Instances spanning more cells than this live in an "always test" list.
pub const GRID_CELLS_PER_INSTANCE: usize = 4;
/// Queries spanning more cells than this walk the object list instead.
pub const GRID_MAX_QUERY_CELLS: i32 = 64;

/// distance_to_object's result when no instance matches (Globals.js L1554).
pub const NO_DISTANCE: f32 = 10000000000.0;

/// g_GMLMathEpsilon default (Function_Maths.js L19).
const GML_MATH_EPSILON: f32 = 1e-5;
/// Collision_Point / Collision_Line col_delta (compatibility mode off).
const COL_DELTA: f32 = -0.00001;
/// Loops below step floats by 1.0; beyond 2^52 that would never terminate.
const LOOP_LIMIT: f32 = 4503599627370496.0;

const BBox = struct {
    left: f32,
    top: f32,
    right: f32,
    bottom: f32,
};

/// yymin / yymax (Function_Maths.js L336): NaN and signed-zero behaviour
/// differs from @min / @max.
fn yymin(a: f32, b: f32) f32 {
    return if (a < b) a else b;
}

fn yymax(a: f32, b: f32) f32 {
    return if (a > b) a else b;
}

fn loopRangeOk(lo: f32, hi: f32) bool {
    return lo > -LOOP_LIMIT and hi < LOOP_LIMIT;
}

fn fi(i: i32) f32 {
    return @floatFromInt(i);
}

// ---- Per-slot state --------------------------------------------------------

const CollState = struct {
    // bbox cache key: the inputs the cached bbox was computed from
    valid: bool = false,
    id: i32 = 0,
    sprite_gen: u32 = 0,
    sprite_index: i32 = 0,
    mask_index: i32 = 0,
    x: f32 = 0,
    y: f32 = 0,
    xscale: f32 = 0,
    yscale: f32 = 0,
    angle: f32 = 0,
    colcheck: ColCheck = .aabb,

    // grid membership
    in_grid: bool = false,
    /// bbox recomputed since the cells below were derived
    cells_stale: bool = false,
    /// in the oversize list instead of cells
    big: bool = false,
    ncells: usize = 0,
    cx0: i32 = 0,
    cy0: i32 = 0,
    cx1: i32 = 0,
    cy1: i32 = 0,
};

const GRID_MAX_CELLS = GRID_MAX_COLS * GRID_MAX_ROWS;
const GRID_MAX_ENTRIES = MAX_INSTANCES * GRID_CELLS_PER_INSTANCE;
const NIL: i16 = -1;

comptime {
    std.debug.assert(GRID_MAX_CELLS <= 32767 and GRID_MAX_ENTRIES <= 32767 and MAX_INSTANCES <= 32767);
}

const State = struct {
    cs: [MAX_INSTANCES]CollState = @splat(.{}),

    cell_head: [GRID_MAX_CELLS]i16 = @splat(NIL),
    /// Entry e belongs to slot e / GRID_CELLS_PER_INSTANCE.
    entry_next: [GRID_MAX_ENTRIES]i16 = @splat(NIL),
    entry_prev: [GRID_MAX_ENTRIES]i16 = @splat(NIL),
    entry_cell: [GRID_MAX_ENTRIES]i16 = @splat(0),

    big_head: i16 = NIL,
    big_next: [MAX_INSTANCES]i16 = @splat(NIL),
    big_prev: [MAX_INSTANCES]i16 = @splat(NIL),

    /// 0 = grid not configured
    cols: i32 = 0,
    rows: i32 = 0,
    cell_size: f32 = 0,
    grid_count: usize = 0,

    roots: [GRID_MAX_ROOTS]i32 = @splat(0),
    root_count: usize = 0,
    indexed: [object_mod.MAX_OBJECTS]bool = @splat(false),

    /// Dedupe stamps for candidate collection.
    stamp: [MAX_INSTANCES]u32 = @splat(0),
    stamp_counter: u32 = 0,

    verify: bool = false,
    verify_failures: usize = 0,
};

var s: State = .{};

fn mgr() *InstanceManager {
    return InstanceManager.get();
}

fn slotOf(inst: *const Instance) usize {
    return mgr().slot(inst);
}

// ---- Bounding boxes (Compute_BoundingBox, yyInstance.js L1455) -------------

fn collisionSprite(inst: *const Instance) ?*const SpriteDef {
    return SpriteRegistry.get().getSprite(if (inst.mask_index >= 0) inst.mask_index else inst.sprite_index);
}

fn computeBbox(inst: *Instance, cs: *CollState) void {
    var l: f32 = undefined;
    var t: f32 = undefined;
    var r: f32 = undefined;
    var b: f32 = undefined;
    if (collisionSprite(inst)) |spr| {
        if (inst.image_angle == 0.0) {
            // L1539-1577 (non-compatibility branches)
            const width = fi((spr.bbox_right + 1) - spr.bbox_left);
            const height = fi((spr.bbox_bottom + 1) - spr.bbox_top);
            l = inst.x + inst.image_xscale * fi(spr.bbox_left - spr.xorigin);
            r = l + inst.image_xscale * width;
            if (l > r) std.mem.swap(f32, &l, &r);
            t = inst.y + inst.image_yscale * fi(spr.bbox_top - spr.yorigin);
            b = t + inst.image_yscale * height;
            if (t > b) std.mem.swap(f32, &t, &b);
        } else {
            // Rotated: axis-aligned box around the rotated rectangle (L1609-1672).
            const xmin = inst.image_xscale * fi(spr.bbox_left - spr.xorigin);
            const xmax = inst.image_xscale * fi(spr.bbox_right - spr.xorigin + 1);
            const ymin = inst.image_yscale * fi(spr.bbox_top - spr.yorigin);
            const ymax = inst.image_yscale * fi(spr.bbox_bottom - spr.yorigin + 1);
            const cc = math.dcos(inst.image_angle);
            const ss = math.dsin(inst.image_angle);
            var cc_xmax = cc * xmax;
            var cc_xmin = cc * xmin;
            var ss_ymax = ss * ymax;
            var ss_ymin = ss * ymin;
            var cc_ymax = cc * ymax;
            var cc_ymin = cc * ymin;
            var ss_xmax = ss * xmax;
            var ss_xmin = ss * xmin;
            if (cc_xmax < cc_xmin) std.mem.swap(f32, &cc_xmin, &cc_xmax);
            if (ss_ymax < ss_ymin) std.mem.swap(f32, &ss_ymin, &ss_ymax);
            l = inst.x + cc_xmin + ss_ymin;
            r = inst.x + cc_xmax + ss_ymax;
            if (cc_ymax < cc_ymin) std.mem.swap(f32, &cc_ymin, &cc_ymax);
            if (ss_xmax < ss_xmin) std.mem.swap(f32, &ss_xmin, &ss_xmax);
            t = inst.y + cc_ymin - ss_xmax;
            b = inst.y + cc_ymax - ss_xmin;
        }
        cs.colcheck = spr.colcheck;
    } else {
        // No sprite: a point box, never collides (L1507-1518).
        l = inst.x;
        r = inst.x;
        t = inst.y;
        b = inst.y;
        cs.colcheck = .aabb;
    }

    inst.bbox_left = l;
    inst.bbox_top = t;
    inst.bbox_right = r;
    inst.bbox_bottom = b;

    cs.valid = true;
    cs.cells_stale = true;
    cs.id = inst.id;
    cs.sprite_gen = SpriteRegistry.get().generation;
    cs.sprite_index = inst.sprite_index;
    cs.mask_index = inst.mask_index;
    cs.x = inst.x;
    cs.y = inst.y;
    cs.xscale = inst.image_xscale;
    cs.yscale = inst.image_yscale;
    cs.angle = inst.image_angle;
}

fn bboxCurrent(inst: *const Instance, cs: *const CollState) bool {
    return cs.valid and cs.id == inst.id and cs.sprite_gen == SpriteRegistry.get().generation and
        cs.sprite_index == inst.sprite_index and cs.mask_index == inst.mask_index and
        cs.x == inst.x and cs.y == inst.y and cs.xscale == inst.image_xscale and
        cs.yscale == inst.image_yscale and cs.angle == inst.image_angle;
}

fn ensureBbox(inst: *Instance) *CollState {
    const cs = &s.cs[slotOf(inst)];
    if (!bboxCurrent(inst, cs)) computeBbox(inst, cs);
    return cs;
}

fn bboxOf(inst: *const Instance) BBox {
    return .{ .left = inst.bbox_left, .top = inst.bbox_top, .right = inst.bbox_right, .bottom = inst.bbox_bottom };
}

/// Maybe_Compute_BoundingBox: brings inst.bbox_* up to date and returns the
/// collision type in effect.
pub fn updateBbox(inst: *Instance) ColCheck {
    return ensureBbox(inst).colcheck;
}

// ---- Masks (ColMaskSet, yySprite.js L1626) ---------------------------------

/// A null mask stands for the runner's missing colmask entry: always set.
fn colmaskSet(spr: *const SpriteDef, u_in: f32, v_in: f32, mask: ?[*]const u8) bool {
    const m = mask orelse return true;
    var u = u_in;
    var v = v_in;
    if (u < fi(spr.bbox_left) or u > fi(spr.bbox_right)) return false;
    if (v < fi(spr.bbox_top) or v > fi(spr.bbox_bottom)) return false;
    if (v != v) return false; // NaN row: the JS array index is NaN -> undefined -> 0
    u -= fi(spr.bbox_left);
    v -= fi(spr.bbox_top);
    const ui = math.toInt32(u); // `u >> 3` and `u & 7` apply ToInt32
    const vi = math.toInt32(v); // integral at every call site
    const idx: usize = @intCast(vi * spr.maskStride() + (ui >> 3));
    return (m[idx] & (@as(u8, 1) << @intCast(7 - (ui & 7)))) != 0;
}

/// Math.floor(img) % colmask.length, made non-negative. -1 for NaN/Inf
/// (colmask[NaN] is undefined, which getMask maps to null).
fn wrapFrameFloor(img: f32, len: i32) i32 {
    const flen = fi(len);
    var r = @rem(@floor(img), flen);
    if (r < 0.0) r += flen;
    return if (r >= 0.0 and r < flen) @intFromFloat(r) else -1;
}

/// (img | 0) % colmask.length, made non-negative (len > 0).
fn wrapFrameInt(img: i32, len: i32) i32 {
    const r = @rem(img, len);
    return if (r < 0) r + len else r;
}

// ---- Precise tests (yySprite.js) -------------------------------------------

/// PreciseCollisionPoint (L2126). img is the unfloored image_index.
fn precisePoint(spr: *const SpriteDef, img: f32, x1_in: f32, y1_in: f32, scalex: f32, scaley: f32, angle: f32, x: f32, y: f32) bool {
    if (spr.mask_count == 0) return true;
    if (spr.frame_count <= 0) return false;
    const n = wrapFrameFloor(img, spr.mask_count);
    const x1 = x1_in - 0.5;
    const y1 = y1_in - 0.5;
    var xx: f32 = undefined;
    var yy: f32 = undefined;
    if (@abs(angle) < 0.0001) {
        xx = @floor((x - x1) / scalex + fi(spr.xorigin));
        yy = @floor((y - y1) / scaley + fi(spr.yorigin));
    } else {
        const ss = math.dsin(-angle);
        const cc = math.dcos(-angle);
        xx = @floor((cc * (x - x1) + ss * (y - y1)) / scalex + fi(spr.xorigin));
        yy = @floor((cc * (y - y1) - ss * (x - x1)) / scaley + fi(spr.yorigin));
    }
    return colmaskSet(spr, xx, yy, spr.getMask(n));
}

/// PreciseCollisionRectangle (L2171). img is floored by the callee.
fn preciseRectangle(spr: *const SpriteDef, img: f32, bb1: BBox, x1_in: f32, y1_in: f32, scalex: f32, scaley: f32, angle: f32, rr: BBox) bool {
    if (spr.mask_count == 0) return true;
    if (spr.frame_count <= 0) return false;
    const mask = spr.getMask(wrapFrameFloor(img, spr.mask_count));

    const l = yymax(bb1.left, rr.left);
    const r = yymin(bb1.right, rr.right);
    const t = yymax(bb1.top, rr.top);
    const b = yymin(bb1.bottom, rr.bottom);
    if (!loopRangeOk(l, r) or !loopRangeOk(t, b)) return false;

    const x1 = x1_in - 0.5;
    const y1 = y1_in - 0.5;
    const w = fi(spr.width);
    const h = fi(spr.height);
    if (scalex == 1.0 and scaley == 1.0 and @abs(angle) < 0.0001) {
        var i = l;
        while (i <= r) : (i += 1.0) {
            var j = t;
            while (j <= b) : (j += 1.0) {
                const xx = math.toInt32(i - x1 + fi(spr.xorigin));
                const yy = math.toInt32(j - y1 + fi(spr.yorigin));
                if (xx < 0 or xx >= spr.width) continue;
                if (yy < 0 or yy >= spr.height) continue;
                if (colmaskSet(spr, fi(xx), fi(yy), mask)) return true;
            }
        }
    } else {
        const ss = math.dsin(-angle);
        const cc = math.dcos(-angle);
        const onescalex = 1.0 / scalex;
        const onescaley = 1.0 / scaley;
        var i = l;
        while (i <= r) : (i += 1.0) {
            var j = t;
            while (j <= b) : (j += 1.0) {
                const xx = @floor((cc * (i - x1) + ss * (j - y1)) * onescalex + fi(spr.xorigin));
                const yy = @floor((cc * (j - y1) - ss * (i - x1)) * onescaley + fi(spr.yorigin));
                if (xx < 0 or xx >= w) continue;
                if (yy < 0 or yy >= h) continue;
                if (colmaskSet(spr, xx, yy, mask)) return true;
            }
        }
    }
    return false;
}

/// PreciseCollisionLine (L2709). img is image_index | 0.
fn preciseLine(spr: *const SpriteDef, img: i32, bb1: BBox, x1_in: f32, y1_in: f32, scalex: f32, scaley: f32, angle: f32, xl_in: f32, yl_in: f32, xr_in: f32, yr_in: f32) bool {
    if (spr.mask_count == 0) return true;
    if (spr.frame_count <= 0) return false;
    const n = wrapFrameInt(img, spr.mask_count);
    var xl = xl_in;
    var yl = yl_in;
    var xr = xr_in;
    var yr = yr_in;

    // Vertical, horizontal or a single pixel: rectangle test with the
    // unshifted origin (the reference passes left = xl, right = xr as is).
    if (xl == xr or yl == yr) {
        const rc: BBox = .{ .left = xl, .top = yymin(yl, yr), .right = xr, .bottom = yymax(yl, yr) };
        return preciseRectangle(spr, fi(n), bb1, x1_in, y1_in, scalex, scaley, angle, rc);
    }
    const mask = spr.getMask(n);

    const ss = math.dsin(-angle);
    const cc = math.dcos(-angle);
    const x1 = x1_in - 0.5;
    const y1 = y1_in - 0.5;
    const xo = fi(spr.xorigin);
    const yo = fi(spr.yorigin);

    if (@abs(xr - xl) >= @abs(yr - yl)) {
        if (xr < xl) {
            std.mem.swap(f32, &xl, &xr);
            std.mem.swap(f32, &yl, &yr);
        }
        const dd = (yr - yl) / (xr - xl);
        const lo = yymax(bb1.left, xl);
        const hi = yymin(bb1.right, xr);
        if (!loopRangeOk(lo, hi)) return false;
        var i = lo;
        while (i <= hi) : (i += 1.0) {
            const xx = @floor((cc * (i - x1) + ss * (yl + (i - xl) * dd - y1)) / scalex + xo);
            const yy = @floor((cc * (yl + (i - xl) * dd - y1) - ss * (i - x1)) / scaley + yo);
            if (colmaskSet(spr, xx, yy, mask)) return true;
        }
    } else {
        if (yr < yl) {
            std.mem.swap(f32, &yl, &yr);
            std.mem.swap(f32, &xl, &xr);
        }
        const dd = (xr - xl) / (yr - yl);
        const lo = yymax(bb1.top, yl);
        const hi = yymin(bb1.bottom, yr);
        if (!loopRangeOk(lo, hi)) return false;
        var i = lo;
        while (i <= hi) : (i += 1.0) {
            const xx = @floor((cc * (xl + (i - yl) * dd - x1) + ss * (i - y1)) / scalex + xo);
            const yy = @floor((cc * (i - y1) - ss * (xl + (i - yl) * dd - x1)) / scaley + yo);
            if (colmaskSet(spr, xx, yy, mask)) return true;
        }
    }
    return false;
}

/// One side of a precise instance/instance test.
const PreciseSide = struct {
    spr: *const SpriteDef,
    img: i32,
    bb: BBox,
    x: f32,
    y: f32,
    scalex: f32,
    scaley: f32,
    angle: f32,
};

/// Precise instance/instance test (yySprite.PreciseCollision, L2364).
fn preciseCollision(a: *const PreciseSide, o: *const PreciseSide) bool {
    const s1 = a.spr;
    const s2 = o.spr;
    var mask1: ?[*]const u8 = null;
    var mask2: ?[*]const u8 = null;
    const prec1 = s1.colcheck == .precise;
    const prec2 = s2.colcheck == .precise;

    if (s1.frame_count <= 0 or s2.frame_count <= 0) return false;
    if (s1.mask_count > 0) mask1 = s1.getMask(wrapFrameInt(a.img, s1.mask_count));
    if (s2.mask_count > 0) mask2 = s2.getMask(wrapFrameInt(o.img, s2.mask_count));

    const sc1x = 1.0 / a.scalex;
    const sc1y = 1.0 / a.scaley;
    const sc2x = 1.0 / o.scalex;
    const sc2y = 1.0 / o.scaley;

    const l = @floor(yymax(a.bb.left, o.bb.left)) + 0.5;
    const r = yymin(a.bb.right, o.bb.right);
    const t = @floor(yymax(a.bb.top, o.bb.top)) + 0.5;
    const b = yymin(a.bb.bottom, o.bb.bottom);
    if (!loopRangeOk(l, r) or !loopRangeOk(t, b)) return false;

    // The reference clamps these edges to the texture only when
    // `colcheck === yySprite.PRECISE` - an undefined property - so the
    // clamping never happens (L2401, L2420). Reproduced by omission.
    const leftedge = fi(s1.bbox_left);
    const rightedge = fi(s1.bbox_right) + 1.0;
    const topedge = fi(s1.bbox_top);
    const bottomedge = fi(s1.bbox_bottom) + 1.0;
    const sleftedge = fi(s2.bbox_left);
    const srightedge = fi(s2.bbox_right) + 1.0;
    const stopedge = fi(s2.bbox_top);
    const sbottomedge = fi(s2.bbox_bottom) + 1.0;
    const xo1 = fi(s1.xorigin);
    const yo1 = fi(s1.yorigin);
    const xo2 = fi(s2.xorigin);
    const yo2 = fi(s2.yorigin);

    const hasrot1 = a.angle > GML_MATH_EPSILON or a.angle < -GML_MATH_EPSILON;
    const hasrot2 = o.angle > GML_MATH_EPSILON or o.angle < -GML_MATH_EPSILON;

    if (!hasrot1 and !hasrot2) {
        const dsu1 = sc1x;
        const dsu2 = sc2x;
        var su1 = (l - a.x) * sc1x + xo1;
        var su2 = (l - o.x) * sc2x + xo2;
        var i = l;
        while (i < r) : ({
            i += 1.0;
            su1 += dsu1;
            su2 += dsu2;
        }) {
            if (su1 < leftedge or su1 >= rightedge) continue;
            if (su2 < sleftedge or su2 >= srightedge) continue;
            const u1i = fi(math.toInt32(su1));
            const u2i = fi(math.toInt32(su2));
            var j = t;
            while (j < b) : (j += 1.0) {
                if (prec1) {
                    const v1 = (j - a.y) * sc1y + yo1;
                    if (v1 < topedge or v1 >= bottomedge) continue;
                    if (s1.mask_count > 0 and !colmaskSet(s1, u1i, fi(math.toInt32(v1)), mask1)) continue;
                }
                if (prec2) {
                    const v2 = (j - o.y) * sc2y + yo2;
                    if (v2 < stopedge or v2 >= sbottomedge) continue;
                    if (s2.mask_count > 0 and !colmaskSet(s2, u2i, fi(math.toInt32(v2)), mask2)) continue;
                }
                return true;
            }
        }
    } else {
        var ss1: f32 = 0.0;
        var cc1: f32 = 0.0;
        var ss2: f32 = 0.0;
        var cc2: f32 = 0.0;
        var su1: f32 = 0.0;
        var su2: f32 = 0.0;
        if (hasrot1) {
            ss1 = math.dsin(-a.angle);
            cc1 = math.dcos(-a.angle);
        }
        if (hasrot2) {
            ss2 = math.dsin(-o.angle);
            cc2 = math.dcos(-o.angle);
        }
        var i = l;
        while (i < r) : (i += 1.0) {
            if (!hasrot1) {
                su1 = (i - a.x) * sc1x + xo1;
                if (su1 < leftedge or su1 >= rightedge) continue;
            }
            if (!hasrot2) {
                su2 = (i - o.x) * sc2x + xo2;
                if (su2 < sleftedge or su2 >= srightedge) continue;
            }
            var j = t;
            while (j < b) : (j += 1.0) {
                var v1: f32 = undefined;
                if (hasrot1) {
                    su1 = (cc1 * (i - a.x) + ss1 * (j - a.y)) * sc1x + xo1;
                    if (su1 < leftedge or su1 >= rightedge) continue;
                    v1 = (cc1 * (j - a.y) - ss1 * (i - a.x)) * sc1y + yo1;
                } else {
                    v1 = (j - a.y) * sc1y + yo1;
                }
                if (v1 < topedge or v1 >= bottomedge) continue;
                if (prec1 and s1.mask_count > 0 and
                    !colmaskSet(s1, fi(math.toInt32(su1)), fi(math.toInt32(v1)), mask1)) continue;

                var v2: f32 = undefined;
                if (hasrot2) {
                    su2 = (cc2 * (i - o.x) + ss2 * (j - o.y)) * sc2x + xo2;
                    if (su2 < sleftedge or su2 >= srightedge) continue;
                    v2 = (cc2 * (j - o.y) - ss2 * (i - o.x)) * sc2y + yo2;
                } else {
                    v2 = (j - o.y) * sc2y + yo2;
                }
                if (v2 < stopedge or v2 >= sbottomedge) continue;
                // The reference passes su2 untruncated here (L2563).
                if (prec2 and s2.mask_count > 0 and !colmaskSet(s2, su2, fi(math.toInt32(v2)), mask2)) continue;
                return true;
            }
        }
    }
    return false;
}

// ---- Instance primitives (yyInstance.js) -----------------------------------

fn framedSprite(inst: *const Instance) ?*const SpriteDef {
    const spr = collisionSprite(inst) orelse return null;
    return if (spr.frame_count == 0) null else spr;
}

/// Collision_Point (L1730)
pub fn testPoint(inst: *Instance, x: f32, y: f32, prec: bool) bool {
    if (inst.marked_for_destroy) return false;
    const cs = ensureBbox(inst);
    const bb = bboxOf(inst);
    if (x >= bb.right + COL_DELTA) return false;
    if (x < bb.left) return false;
    if (y >= bb.bottom + COL_DELTA) return false;
    if (y < bb.top) return false;
    const spr = framedSprite(inst) orelse return false;
    if (!prec or cs.colcheck == .aabb) return true;
    return precisePoint(spr, inst.image_index, math.round(inst.x), math.round(inst.y), inst.image_xscale, inst.image_yscale, inst.image_angle, math.round(x), math.round(y));
}

/// Collision_Rectangle (L1807)
pub fn testRectangle(inst: *Instance, x1: f32, y1: f32, x2: f32, y2: f32, prec: bool) bool {
    if (inst.marked_for_destroy) return false;
    const cs = ensureBbox(inst);
    const bb = bboxOf(inst);

    const bl = yymin(x1, x2);
    if (bl >= bb.right) return false;
    const br = yymax(x1, x2);
    if (br < bb.left) return false;
    const bt = yymin(y1, y2);
    if (bt >= bb.bottom) return false;
    const bbm = yymax(y1, y2);
    if (bbm < bb.top) return false;

    const spr = framedSprite(inst) orelse return false;
    if (!prec or cs.colcheck == .aabb) {
        const l = yymax(bl, bb.left);
        const t = yymax(bt, bb.top);
        const r = yymin(br, bb.right);
        const b = yymin(bbm, bb.bottom);
        if (@floor(l + 0.5) == @floor(r + 0.5)) return false;
        if (@floor(t + 0.5) == @floor(b + 0.5)) return false;
        return true;
    }
    const rr: BBox = .{
        .left = math.round(yymin(x1, x2)),
        .top = math.round(yymin(y1, y2)),
        .right = math.round(yymax(x1, x2)),
        .bottom = math.round(yymax(y1, y2)),
    };
    return preciseRectangle(spr, inst.image_index, bb, math.round(inst.x), math.round(inst.y), inst.image_xscale, inst.image_yscale, inst.image_angle, rr);
}

/// Collision_Line (L2053)
pub fn testLine(inst: *Instance, x1_in: f32, y1_in: f32, x2_in: f32, y2_in: f32, prec: bool) bool {
    if (inst.marked_for_destroy) return false;
    const cs = ensureBbox(inst);
    const bb = bboxOf(inst);
    var x1 = x1_in;
    var y1 = y1_in;
    var x2 = x2_in;
    var y2 = y2_in;

    if (yymin(x1, x2) >= bb.right) return false;
    if (yymax(x1, x2) < bb.left) return false;
    if (yymin(y1, y2) >= bb.bottom) return false;
    if (yymax(y1, y2) < bb.top) return false;

    // make the line run left to right, then clip it to the box
    if (x2 < x1) {
        std.mem.swap(f32, &x1, &x2);
        std.mem.swap(f32, &y1, &y2);
    }
    if (x1 < bb.left) {
        y1 = y1 + (bb.left - x1) * (y2 - y1) / (x2 - x1);
        x1 = bb.left;
    }
    if (x2 > (bb.right + COL_DELTA)) {
        y2 = y2 + (bb.right + COL_DELTA - x2) * (y2 - y1) / (x2 - x1);
        x2 = bb.right + COL_DELTA;
    }
    if (y1 < bb.top and y2 < bb.top) return false;
    if (y1 > bb.bottom and y2 > bb.bottom) return false;

    const spr = framedSprite(inst) orelse return false;
    if (!prec or cs.colcheck == .aabb) return true;
    return preciseLine(spr, math.toInt32(inst.image_index), bb, math.round(inst.x), math.round(inst.y), inst.image_xscale, inst.image_yscale, inst.image_angle, math.round(x1), math.round(y1), math.round(x2), math.round(y2));
}

/// Collision_Instance (L2539): `inst` is `this`, `other` is `_pInst`;
/// order matters for precise tests.
pub fn testInstance(inst: *Instance, other: *Instance, prec: bool) bool {
    if (inst == other or inst.marked_for_destroy or other.marked_for_destroy) return false;
    // b1 = other's box, b2 = inst's box, as in the reference
    const cs2 = ensureBbox(inst);
    const b2 = bboxOf(inst);
    const cs1 = ensureBbox(other);
    const b1 = bboxOf(other);

    if (b1.left >= b2.right) return false;
    if (b1.right <= b2.left) return false;
    if (b1.top >= b2.bottom) return false;
    if (b1.bottom <= b2.top) return false;

    const spr1 = framedSprite(inst) orelse return false;
    const spr2 = framedSprite(other) orelse return false;

    if (!prec or (cs2.colcheck == .aabb and cs1.colcheck == .aabb)) {
        const l = yymax(b1.left, b2.left);
        const t = yymax(b1.top, b2.top);
        const r = yymin(b1.right, b2.right);
        const b = yymin(b1.bottom, b2.bottom);
        if (@floor(l + 0.5) == @floor(r + 0.5)) return false;
        if (@floor(t + 0.5) == @floor(b + 0.5)) return false;
        return true;
    }

    const side1: PreciseSide = .{
        .spr = spr1,
        .img = math.toInt32(inst.image_index),
        .bb = b2,
        .x = math.round(inst.x),
        .y = math.round(inst.y),
        .scalex = inst.image_xscale,
        .scaley = inst.image_yscale,
        .angle = inst.image_angle,
    };
    const side2: PreciseSide = .{
        .spr = spr2,
        .img = math.toInt32(other.image_index),
        .bb = b1,
        .x = math.round(other.x),
        .y = math.round(other.y),
        .scalex = other.image_xscale,
        .scaley = other.image_yscale,
        .angle = other.image_angle,
    };
    return preciseCollision(&side1, &side2);
}

// ---- Grid ------------------------------------------------------------------

fn gridActive() bool {
    return s.cols > 0;
}

fn cellClamp(c: f32, n: i32) i32 {
    if (!(c > 0.0)) return 0;
    if (c >= fi(n - 1)) return n - 1;
    return @intFromFloat(c);
}

fn finite(x: f32) bool {
    return std.math.isFinite(x);
}

const CellRange = struct { cx0: i32, cy0: i32, cx1: i32, cy1: i32 };

/// Cell range covered by the half-open box [l, r) x [t, b): the region in
/// which every hit test can succeed. Null when the box is degenerate or not
/// finite.
fn instanceCells(inst: *const Instance) ?CellRange {
    const l = inst.bbox_left;
    const t = inst.bbox_top;
    const r = inst.bbox_right;
    const b = inst.bbox_bottom;
    if (!(r > l and b > t) or !finite(l) or !finite(r) or !finite(t) or !finite(b)) return null;
    return .{
        .cx0 = cellClamp(@floor(l / s.cell_size), s.cols),
        .cx1 = cellClamp(@ceil(r / s.cell_size) - 1.0, s.cols),
        .cy0 = cellClamp(@floor(t / s.cell_size), s.rows),
        .cy1 = cellClamp(@ceil(b / s.cell_size) - 1.0, s.rows),
    };
}

fn fitsCells(c: CellRange) bool {
    return (c.cx1 - c.cx0 + 1) * (c.cy1 - c.cy0 + 1) <= GRID_CELLS_PER_INSTANCE;
}

fn bigLink(slot: usize) void {
    s.big_prev[slot] = NIL;
    s.big_next[slot] = s.big_head;
    if (s.big_head != NIL) s.big_prev[@intCast(s.big_head)] = @intCast(slot);
    s.big_head = @intCast(slot);
}

fn bigUnlink(slot: usize) void {
    if (s.big_prev[slot] != NIL) {
        s.big_next[@intCast(s.big_prev[slot])] = s.big_next[slot];
    } else {
        s.big_head = s.big_next[slot];
    }
    if (s.big_next[slot] != NIL) s.big_prev[@intCast(s.big_next[slot])] = s.big_prev[slot];
}

fn entryLink(e: usize, cell: usize) void {
    s.entry_cell[e] = @intCast(cell);
    s.entry_prev[e] = NIL;
    s.entry_next[e] = s.cell_head[cell];
    if (s.cell_head[cell] != NIL) s.entry_prev[@intCast(s.cell_head[cell])] = @intCast(e);
    s.cell_head[cell] = @intCast(e);
}

fn entryUnlink(e: usize) void {
    const cell: usize = @intCast(s.entry_cell[e]);
    if (s.entry_prev[e] != NIL) {
        s.entry_next[@intCast(s.entry_prev[e])] = s.entry_next[e];
    } else {
        s.cell_head[cell] = s.entry_next[e];
    }
    if (s.entry_next[e] != NIL) s.entry_prev[@intCast(s.entry_next[e])] = s.entry_prev[e];
}

fn gridRemove(inst: *Instance) void {
    const slot = slotOf(inst);
    const cs = &s.cs[slot];
    if (!cs.in_grid) return;
    if (cs.big) {
        bigUnlink(slot);
    } else {
        for (0..cs.ncells) |k| entryUnlink(slot * GRID_CELLS_PER_INSTANCE + k);
    }
    cs.in_grid = false;
    s.grid_count -= 1;
}

fn gridInsert(inst: *Instance) void {
    const slot = slotOf(inst);
    const cs = ensureBbox(inst);
    cs.big = true;
    cs.ncells = 0;
    if (instanceCells(inst)) |c| {
        if (fitsCells(c)) {
            var k: usize = 0;
            var cy = c.cy0;
            while (cy <= c.cy1) : (cy += 1) {
                var cx = c.cx0;
                while (cx <= c.cx1) : (cx += 1) {
                    entryLink(slot * GRID_CELLS_PER_INSTANCE + k, @intCast(cy * s.cols + cx));
                    k += 1;
                }
            }
            cs.big = false;
            cs.ncells = k;
            cs.cx0 = c.cx0;
            cs.cy0 = c.cy0;
            cs.cx1 = c.cx1;
            cs.cy1 = c.cy1;
        }
    }
    if (cs.big) bigLink(slot);
    cs.cells_stale = false;
    cs.in_grid = true;
    s.grid_count += 1;
}

/// Re-buckets an in-grid instance whose cells changed. Compares against the
/// stored buckets (not the bbox cache, which other queries may already have
/// refreshed after an untracked move).
fn gridRefresh(inst: *Instance) void {
    const cs = &s.cs[slotOf(inst)];
    if (!cs.in_grid) return;
    _ = ensureBbox(inst);
    if (!cs.cells_stale) return; // bbox unchanged since the cells were computed
    cs.cells_stale = false;
    const cells = instanceCells(inst);
    const same = if (cells != null and fitsCells(cells.?))
        (!cs.big and cells.?.cx0 == cs.cx0 and cells.?.cy0 == cs.cy0 and cells.?.cx1 == cs.cx1 and cells.?.cy1 == cs.cy1)
    else
        cs.big;
    if (same) return;
    gridRemove(inst);
    gridInsert(inst);
}

fn gridClearContents() void {
    @memset(&s.cell_head, NIL);
    s.big_head = NIL;
    for (&s.cs) |*cs| cs.in_grid = false;
    s.grid_count = 0;
}

fn wantsGrid(inst: *const Instance) bool {
    return gridActive() and inst.active and !inst.marked_for_destroy and
        ObjectRegistry.get().valid(inst.object_index) and s.indexed[@intCast(inst.object_index)];
}

fn gridInsertAll() void {
    const m = mgr();
    for (0..m.activeCount()) |i| {
        const inst = m.activeAt(i).?;
        if (!s.cs[slotOf(inst)].in_grid and wantsGrid(inst)) gridInsert(inst);
    }
}

// ---- Instance hooks ---------------------------------------------------------

fn hookReset() void {
    @memset(&s.cs, .{});
    gridClearContents();
}

fn hookEnter(inst: *Instance) void {
    // Room instances reuse fixed ids, so a re-created instance can land in its
    // old slot with an identical cache key while inst.bbox_* was reset.
    s.cs[slotOf(inst)].valid = false;
    if (wantsGrid(inst)) gridInsert(inst);
}

fn hookLeave(inst: *Instance) void {
    gridRemove(inst);
}

const hooks: instance_mod.Hooks = .{ .on_reset = hookReset, .on_enter = hookEnter, .on_leave = hookLeave };

/// gm_collision_init: installs the instance hooks and clears grid
/// configuration and caches. Call after the object and sprite registries.
pub fn init() void {
    shutdown();
    mgr().setHooks(&hooks);
}

/// Removes the hooks and clears all state.
pub fn shutdown() void {
    mgr().setHooks(null);
    s = .{};
}

// ---- Grid configuration ------------------------------------------------------

/// Finds oSolid in the object registry and registers it as a grid root.
pub fn indexDefaultRoots() void {
    const reg = ObjectRegistry.get();
    for (0..reg.countObjects()) |o| {
        const def = reg.getDef(@intCast(o)) orelse continue;
        if (std.mem.eql(u8, def.name, "oSolid")) {
            _ = indexObject(@intCast(o));
            break;
        }
    }
}

/// Sizes the grid for a room and re-buckets indexed instances.
pub fn configureGrid(room_width: f32, room_height: f32, cell_size_in: f32) void {
    gridClearContents();
    s.cols = 0;
    s.rows = 0;
    s.cell_size = 0.0;
    var cell_size = cell_size_in;
    if (!(cell_size > 0.0) or !finite(cell_size) or !(room_width > 0.0) or !(room_height > 0.0) or
        !finite(room_width) or !finite(room_height)) return;
    if (s.root_count == 0) indexDefaultRoots();
    var cols: f32 = undefined;
    var rows: f32 = undefined;
    while (true) : (cell_size *= 2.0) {
        cols = @ceil(room_width / cell_size);
        rows = @ceil(room_height / cell_size);
        if (cols <= fi(GRID_MAX_COLS) and rows <= fi(GRID_MAX_ROWS)) break;
    }
    s.cols = @intFromFloat(cols);
    s.rows = @intFromFloat(rows);
    s.cell_size = cell_size;
    gridInsertAll();
}

/// Indexes `object_index` and all its descendants. Queries whose target is
/// an indexed object use the grid. False if the object is invalid or
/// GRID_MAX_ROOTS roots are already registered.
pub fn indexObject(object_index: i32) bool {
    const reg = ObjectRegistry.get();
    if (!reg.valid(object_index)) return false;
    for (s.roots[0..s.root_count]) |r| if (r == object_index) return true;
    if (s.root_count >= GRID_MAX_ROOTS) return false;
    s.roots[s.root_count] = object_index;
    s.root_count += 1;
    for (0..reg.countObjects()) |o| {
        if (reg.isA(@intCast(o), object_index)) s.indexed[o] = true;
    }
    gridInsertAll();
    return true;
}

pub fn isIndexed(object_index: i32) bool {
    return ObjectRegistry.get().valid(object_index) and s.indexed[@intCast(object_index)];
}

/// Re-buckets `inst` if it is grid-indexed and its bbox changed. Cheap no-op
/// for other instances. Call after writing a bbox input.
pub fn touch(inst: *Instance) void {
    if (s.cs[slotOf(inst)].in_grid) gridRefresh(inst);
}

/// Re-buckets every indexed instance whose bbox changed.
pub fn gridSync() void {
    const m = mgr();
    for (0..m.activeCount()) |i| {
        const inst = m.activeAt(i).?;
        const cs = &s.cs[slotOf(inst)];
        if (!cs.in_grid) continue;
        if (inst.x == inst.xprevious and inst.y == inst.yprevious and !cs.cells_stale) continue;
        gridRefresh(inst);
    }
}

/// Verification mode: every grid query is repeated as a linear walk and
/// mismatches are counted (tests and parity debugging).
pub fn setVerify(enabled: bool) void {
    s.verify = enabled;
    s.verify_failures = 0;
}

pub fn verifyFailures() usize {
    return s.verify_failures;
}

pub fn gridCellSize() f32 {
    return s.cell_size;
}

/// Indexed instances in cells + the oversize list.
pub fn gridIndexedCount() usize {
    return s.grid_count;
}

// ---- Queries ------------------------------------------------------------------

const Query = struct {
    kind: enum { point, rect, line, place },
    x1: f32 = 0,
    y1: f32 = 0,
    x2: f32 = 0,
    y2: f32 = 0,
    prec: bool = false,
    /// .place: the placed instance (_pInst)
    place: ?*Instance = null,
    /// notme
    skip: ?*Instance = null,
};

fn queryHit(q: *const Query, cand: *Instance) bool {
    return switch (q.kind) {
        .point => testPoint(cand, q.x1, q.y1, q.prec),
        .rect => testRectangle(cand, q.x1, q.y1, q.x2, q.y2, q.prec),
        .line => testLine(cand, q.x1, q.y1, q.x2, q.y2, q.prec),
        // Command_InstancePlace: _pInstance.Collision_Instance(_pInst, true)
        .place => testInstance(cand, q.place.?, true),
    };
}

/// Instance_SearchLoop: the first hit in list order.
fn queryLinear(q: *const Query, target: i32) ?*Instance {
    const m = mgr();
    var c: InstanceCursor = .{};
    m.searchBegin(&c, target);
    while (m.searchNext(&c, target)) |inst| {
        if (inst == q.skip) continue;
        profile.count(.query_tests, 1);
        if (queryHit(q, inst)) return inst;
    }
    return null;
}

/// Closed query box [x0, x1] x [y0, y1] -> cell range. Every hit test
/// rejects candidates whose half-open box misses the query box, and
/// floor/ceil/clamp are monotonic, so the cell ranges of any hit intersect.
/// Null when the range is unusable (non-finite or too big).
fn gridQueryCells(x0: f32, y0: f32, x1: f32, y1: f32) ?CellRange {
    if (!finite(x0) or !finite(x1) or !finite(y0) or !finite(y1)) return null;
    const c: CellRange = .{
        .cx0 = cellClamp(@floor(x0 / s.cell_size), s.cols),
        .cx1 = cellClamp(@floor(x1 / s.cell_size), s.cols),
        .cy0 = cellClamp(@floor(y0 / s.cell_size), s.rows),
        .cy1 = cellClamp(@floor(y1 / s.cell_size), s.rows),
    };
    return if ((c.cx1 - c.cx0 + 1) * (c.cy1 - c.cy0 + 1) <= GRID_MAX_QUERY_CELLS) c else null;
}

fn consider(q: *const Query, target: i32, slot: usize, best: *?*Instance) void {
    if (s.stamp[slot] == s.stamp_counter) return;
    s.stamp[slot] = s.stamp_counter;
    const inst = mgr().atSlot(slot) orelse return;
    if (!inst.active or inst.marked_for_destroy or inst == q.skip or
        !ObjectRegistry.get().isA(inst.object_index, target)) return;
    // The object list is in link_serial order: keep the earliest hit.
    if (best.*) |b| if (inst.link_serial >= b.link_serial) return;
    profile.count(.query_tests, 1);
    if (queryHit(q, inst)) best.* = inst;
}

/// Null when the grid cannot serve the query (caller goes linear).
fn queryGrid(q: *const Query, target: i32, x0: f32, y0: f32, x1: f32, y1: f32) ??*Instance {
    if (!gridActive() or !isIndexed(target)) return null;
    const c = gridQueryCells(x0, y0, x1, y1) orelse return null;
    s.stamp_counter +%= 1;
    if (s.stamp_counter == 0) {
        @memset(&s.stamp, 0);
        s.stamp_counter = 1;
    }
    var best: ?*Instance = null;
    var cy = c.cy0;
    while (cy <= c.cy1) : (cy += 1) {
        var cx = c.cx0;
        while (cx <= c.cx1) : (cx += 1) {
            var e = s.cell_head[@intCast(cy * s.cols + cx)];
            while (e != NIL) : (e = s.entry_next[@intCast(e)]) {
                consider(q, target, @as(usize, @intCast(e)) / GRID_CELLS_PER_INSTANCE, &best);
            }
        }
    }
    var slot = s.big_head;
    while (slot != NIL) : (slot = s.big_next[@intCast(slot)]) consider(q, target, @intCast(slot), &best);
    return best;
}

/// Gathers all active, non-destroyed candidates of type `target` whose grid cells
/// overlap `inst`'s bounding box. Deduplicates entries across cells and sorts the
/// returned candidates by `link_serial` ascending to guarantee exact GameMaker
/// creation-order parity.
/// Returns null if the target object is not indexed in the spatial grid, or if the
/// grid is inactive, or if the bounding box spans more than GRID_MAX_QUERY_CELLS.
pub fn queryGridCandidates(inst: *Instance, target: i32, out: []*Instance) ?usize {
    if (!gridActive() or !isIndexed(target)) return null;
    _ = ensureBbox(inst);
    const c = gridQueryCells(inst.bbox_left, inst.bbox_top, inst.bbox_right, inst.bbox_bottom) orelse return null;

    s.stamp_counter +%= 1;
    if (s.stamp_counter == 0) {
        @memset(&s.stamp, 0);
        s.stamp_counter = 1;
    }

    const reg = ObjectRegistry.get();
    const m = mgr();
    var count: usize = 0;

    var cy = c.cy0;
    while (cy <= c.cy1) : (cy += 1) {
        var cx = c.cx0;
        while (cx <= c.cx1) : (cx += 1) {
            var e = s.cell_head[@intCast(cy * s.cols + cx)];
            while (e != NIL) : (e = s.entry_next[@intCast(e)]) {
                const slot = @as(usize, @intCast(e)) / GRID_CELLS_PER_INSTANCE;
                if (s.stamp[slot] == s.stamp_counter) continue;
                s.stamp[slot] = s.stamp_counter;

                const cand = m.atSlot(slot) orelse continue;
                if (!cand.active or cand.marked_for_destroy) continue;
                if (!reg.isA(cand.object_index, target)) continue;
                if (count < out.len) {
                    out[count] = cand;
                    count += 1;
                }
            }
        }
    }

    var slot = s.big_head;
    while (slot != NIL) : (slot = s.big_next[@intCast(slot)]) {
        const u_slot: usize = @intCast(slot);
        if (s.stamp[u_slot] == s.stamp_counter) continue;
        s.stamp[u_slot] = s.stamp_counter;

        const cand = m.atSlot(u_slot) orelse continue;
        if (!cand.active or cand.marked_for_destroy) continue;
        if (!reg.isA(cand.object_index, target)) continue;
        if (count < out.len) {
            out[count] = cand;
            count += 1;
        }
    }

    if (count > 1) {
        var k: usize = 1;
        while (k < count) : (k += 1) {
            const item = out[k];
            var j: usize = k;
            while (j > 0 and out[j - 1].link_serial > item.link_serial) : (j -= 1) {
                out[j] = out[j - 1];
            }
            out[j] = item;
        }
    }
    return count;
}

fn runQuery(q: *const Query, target: i32, x0: f32, y0: f32, x1: f32, y1: f32) ?*Instance {
    profile.count(.queries, 1);
    if (queryGrid(q, target, x0, y0, x1, y1)) |hit| {
        if (s.verify and queryLinear(q, target) != hit) s.verify_failures += 1;
        return hit;
    }
    return queryLinear(q, target);
}

pub fn collisionPoint(self: ?*Instance, x: f32, y: f32, target: i32, prec: bool, notme: bool) ?*Instance {
    const q: Query = .{ .kind = .point, .x1 = x, .y1 = y, .x2 = x, .y2 = y, .prec = prec, .skip = if (notme) self else null };
    return runQuery(&q, target, x, y, x, y);
}

pub fn collisionRectangle(self: ?*Instance, x1: f32, y1: f32, x2: f32, y2: f32, target: i32, prec: bool, notme: bool) ?*Instance {
    const q: Query = .{ .kind = .rect, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .prec = prec, .skip = if (notme) self else null };
    return runQuery(&q, target, yymin(x1, x2), yymin(y1, y2), yymax(x1, x2), yymax(y1, y2));
}

pub fn collisionLine(self: ?*Instance, x1: f32, y1: f32, x2: f32, y2: f32, target: i32, prec: bool, notme: bool) ?*Instance {
    const q: Query = .{ .kind = .line, .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .prec = prec, .skip = if (notme) self else null };
    return runQuery(&q, target, yymin(x1, x2), yymin(y1, y2), yymax(x1, x2), yymax(y1, y2));
}

/// Command_InstancePlace (Function_Movement.js L473): move self to (x, y),
/// search (notme = false; Collision_Instance skips self), move back.
pub fn instancePlace(self: *Instance, x: f32, y: f32, target: i32) ?*Instance {
    const xx = self.x;
    const yy = self.y;
    self.x = x;
    self.y = y;
    _ = updateBbox(self);
    const q: Query = .{ .kind = .place, .prec = true, .place = self };
    const hit = runQuery(&q, target, self.bbox_left, self.bbox_top, self.bbox_right, self.bbox_bottom);
    self.x = xx;
    self.y = yy;
    _ = updateBbox(self);
    return hit;
}

pub fn placeMeeting(self: *Instance, x: f32, y: f32, target: i32) bool {
    return instancePlace(self, x, y, target) != null;
}

/// Command_InstancePosition (Function_Movement.js L503) and position_meeting
/// (Command_CollisionPoint with prec = true, notme = false): identical walks.
pub fn instancePosition(x: f32, y: f32, target: i32) ?*Instance {
    return collisionPoint(null, x, y, target, true, false);
}

pub fn positionMeeting(x: f32, y: f32, target: i32) bool {
    return instancePosition(x, y, target) != null;
}

/// gm_move_snap: roundf (half away from zero) to the grid.
pub fn moveSnap(inst: *Instance, hsnap: f32, vsnap: f32) void {
    if (hsnap > 0.0) inst.x = @round(inst.x / hsnap) * hsnap;
    if (vsnap > 0.0) inst.y = @round(inst.y / vsnap) * vsnap;
}

/// distance_to_object (Function_Movement.js L902) via Instance_SearchLoop2:
/// bbox gap to the nearest match (self included); NO_DISTANCE when none.
pub fn distanceToObject(self: *Instance, target: i32) f32 {
    var dist: f32 = NO_DISTANCE;
    _ = ensureBbox(self);
    const sb = bboxOf(self);
    const m = mgr();
    var c: InstanceCursor = .{};
    m.searchBegin(&c, target);
    while (m.searchNext(&c, target)) |inst| {
        _ = ensureBbox(inst);
        const r = bboxOf(inst);
        var xd: f32 = 0.0;
        var yd: f32 = 0.0;
        if (r.left > sb.right) xd = r.left - sb.right;
        if (r.right < sb.left) xd = r.right - sb.left;
        if (r.top > sb.bottom) yd = r.top - sb.bottom;
        if (r.bottom < sb.top) yd = r.bottom - sb.top;
        const d = @sqrt(xd * xd + yd * yd);
        if (d < dist) dist = d;
    }
    return dist;
}

/// distance_to_point (Function_Movement.js L869)
pub fn distanceToPoint(self: *Instance, x: f32, y: f32) f32 {
    _ = ensureBbox(self);
    const r = bboxOf(self);
    var xd: f32 = 0.0;
    var yd: f32 = 0.0;
    if (x > r.right) xd = x - r.right;
    if (x < r.left) xd = x - r.left;
    if (y > r.bottom) yd = y - r.bottom;
    if (y < r.top) yd = y - r.top;
    return @sqrt(xd * xd + yd * yd);
}
