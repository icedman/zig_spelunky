//! Optional frame profiler: per-phase wall time and hot-path counters,
//! averaged over a reporting window. Disabled (every call a null check)
//! until a host installs `clock`; the Playdate host does so with
//! `-Dplaydate-profile=true`.

const std = @import("std");

const log = std.log.scoped(.profile);

/// Timed sections. Nested sections overlap their parent: `draw` includes
/// `draw_layers` (instance draw events = draw - draw_layers); `tick`
/// includes every step phase; `host_frame` is the whole update callback.
pub const Phase = enum {
    tick,
    images,
    begin_step,
    alarms,
    keyboard,
    step,
    positions,
    other,
    collisions,
    end_step,
    reclaim,
    draw,
    draw_order,
    draw_instances,
    draw_layers,
    host_frame,
};

pub const Counter = enum {
    /// rt.findEvent lookups missing the dispatch cache (parent-chain walk).
    find_event_slow,
    /// `id.var` resolutions through rt.deref with an instance id.
    deref_id,
    /// Collision-event pair tests (handleCollisions -> testInstance).
    collision_pairs,
    /// place_meeting / instance_place / collision_* queries.
    queries,
    /// Candidate instances tested by those queries.
    query_tests,
    /// Images sent to the video backend.
    draw_images,
    /// Of those, images on screen (not culled by the backend).
    draw_blits,
    /// Direct fast-path drawBitmap calls (1:1, non-rotated, plain copy).
    draw_fast,
    /// drawBitmap calls with regions/alpha/tint.
    draw_bitmap,
    /// drawScaledBitmap calls.
    draw_scaled,
    /// drawRotatedBitmap calls.
    draw_rotated,
    /// Layer elements (tiles, sprites, backgrounds) drawn.
    layer_elements,
    /// Screen draws outside the draw pipeline dropped (DrawManager.skip_unseen).
    unseen_draws,
};

const phase_count = @typeInfo(Phase).@"enum".fields.len;
const counter_count = @typeInfo(Counter).@"enum".fields.len;

/// Monotonic microseconds (wrapping is fine: only differences are used).
/// Null disables the profiler.
pub var clock: ?*const fn () u32 = null;

var totals: [phase_count]u64 = @splat(0);
var maxima: [phase_count]u32 = @splat(0);
var counters: [counter_count]u64 = @splat(0);
var frames: u32 = 0;
var instances_sum: u64 = 0;

pub inline fn enabled() bool {
    return clock != null;
}

pub inline fn start() u32 {
    return if (clock) |c| c() else 0;
}

pub inline fn stop(p: Phase, t0: u32) void {
    if (clock) |c| {
        const dt = c() -% t0;
        const i = @intFromEnum(p);
        totals[i] += dt;
        if (dt > maxima[i]) maxima[i] = dt;
    }
}

pub inline fn count(c: Counter, n: u32) void {
    if (clock != null) counters[@intFromEnum(c)] += n;
}

/// Ends one host frame; logs and resets every `every` frames.
pub fn frameDone(active_instances: usize, every: u32) void {
    if (clock == null) return;
    frames += 1;
    instances_sum += active_instances;
    if (frames >= every) {
        report();
        reset();
    }
}

pub fn reset() void {
    totals = @splat(0);
    maxima = @splat(0);
    counters = @splat(0);
    frames = 0;
    instances_sum = 0;
}

/// One line per phase / counter (the Playdate console truncates long lines).
/// Times are average and worst milliseconds per frame.
fn report() void {
    if (frames == 0) return;
    const n: u64 = frames;
    log.info("--- {d} frames, {d} instances avg ---", .{ frames, instances_sum / n });
    // Every phase, zeros included: all zeros means the clock is not advancing.
    inline for (@typeInfo(Phase).@"enum".fields, 0..) |f, i| {
        const avg_us = totals[i] / n;
        log.info("{s:<15} avg {d:>4}.{d:0>2} ms  max {d:>4}.{d:0>2} ms", .{
            f.name,
            avg_us / 1000,
            (avg_us % 1000) / 10,
            maxima[i] / 1000,
            (maxima[i] % 1000) / 10,
        });
    }
    inline for (@typeInfo(Counter).@"enum".fields, 0..) |f, i| {
        if (counters[i] > 0) log.info("{s:<15} {d}/frame", .{ f.name, counters[i] / n });
    }
}

test "disabled profiler records nothing; enabled one accumulates" {
    const S = struct {
        var now: u32 = 0;
        fn tick() u32 {
            return now;
        }
    };
    clock = null;
    reset();
    stop(.step, start());
    count(.queries, 3);
    try std.testing.expectEqual(@as(u64, 0), totals[@intFromEnum(Phase.step)]);
    try std.testing.expectEqual(@as(u64, 0), counters[@intFromEnum(Counter.queries)]);

    clock = S.tick;
    defer clock = null;
    S.now = 4294967290; // wraps inside the section
    const t0 = start();
    S.now +%= 1500;
    stop(.step, t0);
    count(.queries, 3);
    try std.testing.expectEqual(@as(u64, 1500), totals[@intFromEnum(Phase.step)]);
    try std.testing.expectEqual(@as(u32, 1500), maxima[@intFromEnum(Phase.step)]);
    try std.testing.expectEqual(@as(u64, 3), counters[@intFromEnum(Counter.queries)]);
    reset();
}
