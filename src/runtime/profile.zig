//! Optional frame profiler: per-phase wall time, hot-path counters and
//! per-object event time ("deep" profiling), averaged over a reporting
//! window. Disabled (every call a null check) until a host installs `clock`;
//! the Playdate host does so with `-Dplaydate-profile=N`.
//!
//! Built for the Playdate's small game-task stack: nothing here formats
//! with std.fmt. A finished window is copied into a static snapshot and
//! printed a few lines per frame (from the host's update callback, at the
//! top of the stack), each line built by hand in a static buffer.

const std = @import("std");
const object_mod = @import("object.zig");

const MAX_OBJECTS = object_mod.MAX_OBJECTS;

/// Timed sections. Nested sections overlap their parent: `draw` includes
/// every draw_* phase; `tick` includes every step phase; `host_frame` is the
/// whole update callback.
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
    /// Backend begin_frame + clear + present (draw_alt).
    draw_frame,
    draw_order,
    /// World pass instance loop, Draw events included (draw_alt).
    draw_instances,
    /// Draw GUI pass (draw_alt).
    draw_gui,
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
    /// Of the queries, ones the grid could not serve (linear scan of the
    /// target's instances).
    query_linear,
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
    /// Instances walked by the world draw pass.
    draw_visited,
    /// Of those, skipped by instanceOffscreen.
    draw_culled,
    /// User Draw events run (world + GUI).
    draw_events,
    /// Default draw_self calls.
    draw_selfs,
    /// Backend rectangles / circles / surface blits / target switches.
    draw_rects,
    draw_circles,
    draw_surfaces,
    surface_targets,
    /// Step events run (Begin Step + Step + End Step).
    step_events,
};

/// Runtime services the game calls from its events, timed inclusively
/// (a section that runs GML, like `create`, includes everything it calls).
pub const Section = enum {
    /// collision_point / _rectangle / _line / _circle, instance_place,
    /// place_meeting, instance_position (collision.runQuery).
    query,
    /// distance_to_object.
    distance,
    /// instance_nearest.
    nearest,
    /// instance_exists / instance_number / instance_find resolution.
    lookup,
    /// `obj.var` with an object index (rt.deref walk).
    deref_obj,
    /// `with (target)` snapshots.
    with,
    /// instance_create_depth, Create event included.
    create,
    /// audio_play_sound.
    sound,
};

/// Per-object time buckets for deep profiling.
pub const ObjectKind = enum {
    /// Begin Step / Step / End Step events.
    step,
    /// Draw / Draw GUI events and draw_self.
    draw,
};

const phase_count = @typeInfo(Phase).@"enum".fields.len;
const counter_count = @typeInfo(Counter).@"enum".fields.len;
const kind_count = @typeInfo(ObjectKind).@"enum".fields.len;
const section_count = @typeInfo(Section).@"enum".fields.len;
const hot_objects = 6;
/// Report lines printed per host frame.
const lines_per_frame = 4;

/// Monotonic microseconds (wrapping is fine: only differences are used).
/// Null disables the profiler.
pub var clock: ?*const fn () u32 = null;

/// Writes one console line. Null falls back to std.log (desktop, tests).
pub var write_line: ?*const fn ([*:0]const u8) void = null;

/// Per-object event and per-section (runtime call) timing. Each costs two
/// clock reads per event/call, which adds up to a lot on the Playdate; off
/// leaves the phase times nearly undisturbed.
pub var deep: bool = true;

/// Deep profiling is on (the profiler is enabled and `deep` is set).
pub inline fn deepEnabled() bool {
    return clock != null and deep;
}

// ---- the window being measured -------------------------------------------

var totals: [phase_count]u64 = @splat(0);
var maxima: [phase_count]u32 = @splat(0);
var counters: [counter_count]u64 = @splat(0);
/// Microseconds per object and kind over the window (u32: a 60-frame window
/// of 100 ms frames is 6e6 us).
var object_us: [kind_count][MAX_OBJECTS]u32 = @splat(@splat(0));
var section_us: [section_count]u64 = @splat(0);
var section_calls: [section_count]u32 = @splat(0);
var frames: u32 = 0;
var instances_sum: u64 = 0;

// ---- the last finished window, being printed -----------------------------

const Hot = struct { obj: u16 = 0, us: u32 = 0 };

const Snapshot = struct {
    frames: u32 = 0,
    instances: u32 = 0,
    avg: [phase_count]u32 = @splat(0),
    max: [phase_count]u32 = @splat(0),
    per_frame: [counter_count]u32 = @splat(0),
    section_avg: [section_count]u32 = @splat(0),
    section_calls: [section_count]u32 = @splat(0),
    hot: [kind_count][hot_objects]Hot = @splat(@splat(.{})),
    hot_len: [kind_count]u8 = @splat(0),
};

var snap: Snapshot = .{};
/// Next report line to print, or null when idle.
var cursor: ?usize = null;

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

/// Charges the time since `t0` to `obj`'s `kind` total.
pub inline fn stopObject(kind: ObjectKind, obj: i32, t0: u32) void {
    if (!deep) return;
    if (clock) |c| {
        if (obj >= 0 and obj < MAX_OBJECTS) {
            const slot = &object_us[@intFromEnum(kind)][@intCast(obj)];
            slot.* +%= c() -% t0;
        }
    }
}

/// Starts a section (0 when deep profiling is off).
pub inline fn startSection() u32 {
    return if (deepEnabled()) clock.?() else 0;
}

/// Charges the time since `t0` (from `startSection`) to a section, and one call.
pub inline fn stopSection(sec: Section, t0: u32) void {
    if (!deep) return;
    if (clock) |c| {
        const i = @intFromEnum(sec);
        section_us[i] += c() -% t0;
        section_calls[i] +%= 1;
    }
}

pub inline fn count(c: Counter, n: u32) void {
    if (clock != null) counters[@intFromEnum(c)] += n;
}

/// Ends one host frame: every `every` frames the window is snapshotted and
/// reset; the snapshot is then printed `lines_per_frame` lines per call.
/// noinline: keeps the report's locals out of the host callback's frame,
/// which the whole game tick runs on top of.
pub noinline fn frameDone(active_instances: usize, every: u32) void {
    if (clock == null) return;
    frames += 1;
    instances_sum += active_instances;
    if (frames >= every) {
        takeSnapshot();
        reset();
        cursor = 0;
    }
    printSome();
}

pub fn reset() void {
    totals = @splat(0);
    maxima = @splat(0);
    counters = @splat(0);
    object_us = @splat(@splat(0));
    section_us = @splat(0);
    section_calls = @splat(0);
    frames = 0;
    instances_sum = 0;
}

fn takeSnapshot() void {
    if (frames == 0) return;
    const n: u64 = frames;
    snap.frames = frames;
    snap.instances = @truncate(instances_sum / n);
    for (0..phase_count) |i| {
        snap.avg[i] = @truncate(totals[i] / n);
        snap.max[i] = maxima[i];
    }
    for (0..counter_count) |i| snap.per_frame[i] = @truncate(counters[i] / n);
    for (0..section_count) |i| {
        snap.section_avg[i] = @truncate(section_us[i] / n);
        snap.section_calls[i] = @truncate(section_calls[i] / n);
    }

    // Top objects per kind; picks are zeroed (the window is reset next).
    for (0..kind_count) |k| {
        // By pointer: iterating the array by value copies 4 KB to the stack.
        const times = &object_us[k];
        var len: u8 = 0;
        while (len < hot_objects) : (len += 1) {
            var best: usize = 0;
            for (times, 0..) |*us, i| {
                if (us.* > times[best]) best = i;
            }
            const us = times[best];
            if (us == 0) break;
            snap.hot[k][len] = .{ .obj = @intCast(best), .us = @truncate(us / n) };
            times[best] = 0;
        }
        snap.hot_len[k] = len;
    }
}

// ---- report lines ----------------------------------------------------------

/// Header, phases, counters, sections, hot step objects, hot draw objects.
const line_count = 1 + phase_count + counter_count + section_count + kind_count * hot_objects;

fn printSome() void {
    var printed: usize = 0;
    while (cursor) |c| {
        if (c >= line_count) {
            cursor = null;
            break;
        }
        cursor = c + 1;
        if (buildLine(c)) {
            emit();
            printed += 1;
            if (printed == lines_per_frame) break;
        }
    }
}

/// Builds report line `idx` into `line`; false if it has nothing to show.
fn buildLine(idx: usize) bool {
    line.len = 0;
    line.put("profile: ");
    if (idx == 0) {
        line.put("--- ");
        line.num(snap.frames);
        line.put(" frames, ");
        line.num(snap.instances);
        line.put(" instances avg ---");
        return true;
    }
    var i = idx - 1;
    if (i < phase_count) {
        // Every phase, zeros included: all zeros means the clock is stuck.
        line.put(@tagName(@as(Phase, @enumFromInt(i))));
        line.padTo(9 + 16);
        line.put("avg ");
        line.ms(snap.avg[i]);
        line.put("  max ");
        line.ms(snap.max[i]);
        return true;
    }
    i -= phase_count;
    if (i < counter_count) {
        if (snap.per_frame[i] == 0) return false;
        line.put(@tagName(@as(Counter, @enumFromInt(i))));
        line.padTo(9 + 16);
        line.num(snap.per_frame[i]);
        line.put("/frame");
        return true;
    }
    i -= counter_count;
    if (i < section_count) {
        if (snap.section_calls[i] == 0 and snap.section_avg[i] == 0) return false;
        line.put("api ");
        line.put(@tagName(@as(Section, @enumFromInt(i))));
        line.padTo(9 + 16);
        line.ms(snap.section_avg[i]);
        line.put("  ");
        line.num(snap.section_calls[i]);
        line.put("/frame");
        return true;
    }
    i -= section_count;
    const k = i / hot_objects;
    const h = i % hot_objects;
    if (h >= snap.hot_len[k]) return false;
    const hot = snap.hot[k][h];
    line.put(switch (@as(ObjectKind, @enumFromInt(k))) {
        .step => "step_obj ",
        .draw => "draw_obj ",
    });
    const name = if (object_mod.ObjectRegistry.get().getDef(hot.obj)) |d| d.name else "?";
    line.put(name);
    line.padTo(9 + 9 + 16);
    line.ms(hot.us);
    return true;
}

noinline fn emit() void {
    const text = line.terminated();
    if (write_line) |w| {
        w(text.ptr);
    } else {
        std.log.scoped(.profile).info("{s}", .{text[9..]});
    }
}

/// Fixed-size line builder (static: no stack, no std.fmt).
const Line = struct {
    buf: [112]u8 = undefined,
    len: usize = 0,

    fn put(self: *Line, s: []const u8) void {
        const room = self.buf.len - 1 - self.len;
        const n = @min(s.len, room);
        @memcpy(self.buf[self.len..][0..n], s[0..n]);
        self.len += n;
    }

    fn padTo(self: *Line, col: usize) void {
        while (self.len < col and self.len < self.buf.len - 1) : (self.len += 1) {
            self.buf[self.len] = ' ';
        }
    }

    fn num(self: *Line, v: u32) void {
        var digits: [10]u8 = undefined;
        var i: usize = digits.len;
        var x = v;
        while (true) {
            i -= 1;
            digits[i] = '0' + @as(u8, @intCast(x % 10));
            x /= 10;
            if (x == 0) break;
        }
        self.put(digits[i..]);
    }

    /// Microseconds as right-aligned "  12.34 ms".
    fn ms(self: *Line, us: u32) void {
        const whole = us / 1000;
        const cents = (us % 1000) / 10;
        var w = whole;
        var width: usize = 1;
        while (w >= 10) : (w /= 10) width += 1;
        var pad = if (width < 4) 4 - width else 0;
        while (pad > 0) : (pad -= 1) self.put(" ");
        self.num(whole);
        self.put(if (cents < 10) ".0" else ".");
        self.num(cents);
        self.put(" ms");
    }

    fn terminated(self: *Line) [:0]const u8 {
        self.buf[self.len] = 0;
        return self.buf[0..self.len :0];
    }
};

var line: Line = .{};

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

test "report lines are built without std.fmt and printed a few per frame" {
    const S = struct {
        var now: u32 = 0;
        var lines: usize = 0;
        var first: [112]u8 = undefined;
        var first_len: usize = 0;
        fn tick() u32 {
            return now;
        }
        fn write(text: [*:0]const u8) void {
            if (lines == 0) {
                const s = std.mem.span(text);
                @memcpy(first[0..s.len], s);
                first_len = s.len;
            }
            lines += 1;
        }
    };
    clock = S.tick;
    write_line = S.write;
    defer {
        clock = null;
        write_line = null;
        cursor = null;
        reset();
    }
    reset();

    const t0 = start();
    S.now += 12345;
    stop(.draw, t0);
    count(.queries, 7);
    frameDone(10, 1);
    try std.testing.expectEqual(@as(usize, lines_per_frame), S.lines);
    try std.testing.expectEqualStrings("profile: --- 1 frames, 10 instances avg ---", S.first[0..S.first_len]);

    // Drain the rest of the report (the window is 1 frame: keep it from
    // restarting by giving frameDone a long window).
    while (cursor != null) frameDone(0, 1000);
    try std.testing.expect(S.lines > lines_per_frame);

    line.len = 0;
    line.ms(12345);
    try std.testing.expectEqualStrings("  12.34 ms", line.buf[0..line.len]);
    line.len = 0;
    line.ms(5);
    try std.testing.expectEqualStrings("   0.00 ms", line.buf[0..line.len]);
}
