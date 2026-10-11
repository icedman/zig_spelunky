//! GML math built-ins with GameMaker-HTML5 semantics, plus the WELL512 RNG.
//! Follows reference/GameMaker-HTML5/scripts/functions/Function_Maths.js and packaged_src/src/runtime/gm_math.c.

const std = @import("std");

pub const GM_PI: f32 = 3.14159265;

pub const LUT_STEPS_PER_DEG: usize = 10;
pub const LUT_SIZE: usize = 360 * LUT_STEPS_PER_DEG;

var sin_lut: [LUT_SIZE + 1]f32 = undefined;
var lut_ready: bool = false;

fn lutInit() void {
    for (0..LUT_SIZE + 1) |i| {
        const angle_rad = @as(f32, @floatFromInt(i)) * (GM_PI / 180.0) / @as(f32, @floatFromInt(LUT_STEPS_PER_DEG));
        sin_lut[i] = @sin(angle_rad);
    }
    lut_ready = true;
}

fn lutSinDeg(deg: f32) f32 {
    if (!std.math.isFinite(deg)) return @sin(deg);
    if (!lut_ready) lutInit();

    var t = @mod(deg * @as(f32, @floatFromInt(LUT_STEPS_PER_DEG)), @as(f32, @floatFromInt(LUT_SIZE)));
    if (t < 0.0) t += @as(f32, @floatFromInt(LUT_SIZE));

    var i: usize = @intFromFloat(t);
    if (i >= LUT_SIZE) {
        i = 0;
        t = 0.0;
    }
    const fi: f32 = @floatFromInt(i);
    return sin_lut[i] + (sin_lut[i + 1] - sin_lut[i]) * (t - fi);
}

pub fn dsin(deg: f32) f32 {
    return lutSinDeg(deg);
}

pub fn dcos(deg: f32) f32 {
    return lutSinDeg(deg + 90.0);
}

pub fn toInt32(x: f32) i32 {
    if (std.math.isNan(x) or std.math.isInf(x)) return 0;
    // Floats this large are multiples of 2^40, so ToInt32 (mod 2^32) is 0.
    if (@abs(x) >= 0x1p63) return 0;
    const i: i64 = @intFromFloat(x);
    return @truncate(i);
}

fn jsMathRound(x: f32) f32 {
    var r = @floor(x);
    if (x - r >= 0.5) r += 1.0;
    return r;
}

/// DelphiRound (Function_Maths.js L46-84): round half to even.
pub fn round(x: f32) f32 {
    if (std.math.isNan(x)) return x;
    var i = @floor(@abs(x));
    const odd = @mod(i, 2.0) == 1.0;
    if (x < 0.0) {
        i = -i;
        const f = x - i;
        if (odd) {
            return if (f <= -0.5) i - 1.0 else i;
        }
        return if (f >= -0.5) i else i - 1.0;
    }
    const f = x - i;
    if (odd) {
        return if (f >= 0.5) i + 1.0 else i;
    }
    return if (f <= 0.5) i else i + 1.0;
}

pub fn frac(x: f32) f32 {
    return x - @as(f32, @floatFromInt(toInt32(x)));
}

pub fn sign(x: f32) f32 {
    if (x == 0.0) return 0.0;
    return if (x < 0.0) -1.0 else 1.0;
}

pub inline fn min(a: f32, b: f32) f32 {
    return if (a > b) b else a;
}

pub inline fn max(a: f32, b: f32) f32 {
    return if (a < b) b else a;
}

pub inline fn clamp(value: f32, lo: f32, hi: f32) f32 {
    if (value < lo) return lo;
    if (value > hi) return hi;
    return value;
}

pub inline fn lerp(a: f32, b: f32, amount: f32) f32 {
    return a + ((b - a) * amount);
}

pub inline fn sqr(x: f32) f32 {
    return x * x;
}

pub inline fn power(x: f32, n: f32) f32 {
    return std.math.pow(f32, x, n);
}

pub inline fn degtorad(deg: f32) f32 {
    return deg * 0.0174532925;
}

pub inline fn radtodeg(rad: f32) f32 {
    return rad * 57.2957795;
}

pub fn lengthdirX(len: f32, dir: f32) f32 {
    const v = len * dcos(dir);
    const flv = jsMathRound(v);
    return if (@abs(v - flv) < 0.0001) flv else v;
}

pub fn lengthdirY(len: f32, dir: f32) f32 {
    const v = -(len * dsin(dir));
    const flv = jsMathRound(v);
    return if (@abs(v - flv) < 0.0001) flv else v;
}

pub fn pointDistance(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const dx = x2 - x1;
    const dy = y2 - y1;
    return @sqrt(dx * dx + dy * dy);
}

pub fn pointDirection(x1: f32, y1: f32, x2: f32, y2: f32) f32 {
    const x = x2 - x1;
    const y = y2 - y1;
    if (x == 0.0) {
        if (y > 0.0) return 270.0;
        if (y < 0.0) return 90.0;
        return 0.0;
    }
    var dd = 180.0 * std.math.atan2(y, x) / GM_PI;
    dd = @as(f32, @floatFromInt(toInt32(round(dd * 1000000.0)))) / 1000000.0;
    return if (dd <= 0.0) -dd else 360.0 - dd;
}

// ---- WELL512 PRNG (Function_Maths.js L412-478) ----

const GM_RANDOM_POLY: u32 = 0xDA442D24;

var rng_state: [16]u32 = [_]u32{0} ** 16;
var rng_index: usize = 0;
var rng_seed: i32 = 0;
var rng_seeded: bool = false;

fn sar(v: u32, shift: u5) u32 {
    const sv: i32 = @bitCast(v);
    const shifted = sv >> shift;
    return @bitCast(shifted);
}

pub fn randomSetSeed(seed: i32) void {
    var s: i64 = seed;
    for (0..16) |i| {
        const mult: i64 = s * 214013 + 2531011;
        const u: u32 = @truncate(@as(u64, @bitCast(mult)));
        const v: u32 = sar(u, 16) & 0x7FFFFFFF;
        rng_state[i] = v;
        s = @as(i64, @intCast(v));
    }
    rng_index = 0;
    rng_seed = seed;
    rng_seeded = true;
}

pub fn randomGetSeed() i32 {
    if (!rng_seeded) randomSetSeed(0);
    return rng_seed;
}

const libc = struct {
    extern "c" fn time(t: ?*c_long) c_long;
    extern "c" fn clock() c_long;
};

/// time(NULL) ^ clock(), truncated to 32 bits, like the C port. Without
/// libc 0; such hosts (Playdate) install their own `clock_seed_source`.
pub fn systemClockSeed() u32 {
    if (!@import("builtin").link_libc) return 0;
    return @as(u32, @truncate(@as(c_ulong, @bitCast(libc.time(null))))) ^ @as(u32, @truncate(@as(c_ulong, @bitCast(libc.clock()))));
}

/// Where `randomize` reads its clock value. Deterministic runs (parity
/// traces) pin it; the C trace interposes time()/clock() to the same value.
pub var clock_seed_source: *const fn () u32 = systemClockSeed;

/// gm_randomize: seeds from the clock value, mixed like the C port.
pub fn randomize() i32 {
    const t: u32 = clock_seed_source();
    const mixed: u32 = t ^ ((t >> 16) & 0xFFFF) ^ ((t << 16) & 0xFFFF0000);
    const seed: i32 = toInt32(@floatFromInt(mixed));
    randomSetSeed(seed);
    return seed;
}

pub fn rand01() f32 {
    if (!rng_seeded) randomSetSeed(0);

    var a = rng_state[rng_index];
    var c = rng_state[(rng_index + 13) & 15];
    const b = a ^ c ^ (a << 16) ^ (c << 15);
    c = rng_state[(rng_index + 9) & 15];
    c ^= sar(c, 11);
    a = b ^ c;
    rng_state[rng_index] = a;
    const d = a ^ ((a << 5) & GM_RANDOM_POLY);
    rng_index = (rng_index + 15) & 15;
    a = rng_state[rng_index];
    rng_state[rng_index] = a ^ b ^ d ^ (a << 2) ^ (b << 18) ^ (c << 28);
    return @as(f32, @floatFromInt(rng_state[rng_index] & 0x7FFFFFFF)) / 2147483647.0;
}

pub fn random(x: f32) f32 {
    return rand01() * x;
}

pub fn randomRange(a: f32, b: f32) f32 {
    if (a == b) return a;
    const lower = if (a > b) b else a;
    const higher = if (a > b) a else b;
    const res = lower + (rand01() * (higher - lower));
    _ = rand01(); // Quirk: consumes 2nd random number!
    return res;
}

pub fn irandom(x: f32) f32 {
    return @floor(random(x + 1.0));
}

pub fn irandomRange(a: f32, b: f32) f32 {
    return @floor(randomRange(a, b + 1.0));
}

test "Math Banker's rounding" {
    try std.testing.expectEqual(@as(f32, 2.0), round(2.5));
    try std.testing.expectEqual(@as(f32, 4.0), round(3.5));
    try std.testing.expectEqual(@as(f32, -2.0), round(-2.5));
    try std.testing.expectEqual(@as(f32, -4.0), round(-3.5));
    try std.testing.expectEqual(@as(f32, 1.0), round(1.49));
    try std.testing.expectEqual(@as(f32, 2.0), round(1.51));
}

test "Math lengthdir and angles parity with C" {
    const lx = lengthdirX(10.0, 0.0);
    const ly = lengthdirY(10.0, 0.0);
    try std.testing.expectEqual(@as(f32, 10.0), lx);
    try std.testing.expectEqual(@as(f32, 0.0), ly);

    const dist = pointDistance(10.0, 20.0, 40.0, 60.0);
    try std.testing.expectEqual(@as(f32, 50.0), dist);

    try std.testing.expectEqual(@as(f32, 0.0), pointDirection(0.0, 0.0, 10.0, 0.0));
    try std.testing.expectEqual(@as(f32, 270.0), pointDirection(0.0, 0.0, 0.0, 10.0));
    try std.testing.expectEqual(@as(f32, 90.0), pointDirection(0.0, 0.0, 0.0, -10.0));
    try std.testing.expectEqual(@as(f32, 180.0), pointDirection(0.0, 0.0, -10.0, 0.0));
}

test "WELL512 PRNG reproducible sequence" {
    randomSetSeed(1337);
    const r1 = rand01();
    const r2 = rand01();
    const r3 = randomRange(10.0, 20.0);

    // Re-seed with identical seed
    randomSetSeed(1337);
    try std.testing.expectEqual(r1, rand01());
    try std.testing.expectEqual(r2, rand01());
    try std.testing.expectEqual(r3, randomRange(10.0, 20.0));
}
