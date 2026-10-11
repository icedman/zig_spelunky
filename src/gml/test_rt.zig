//! gml/rt.zig: expression semantics (gml_rt.h), variable access with
//! ownership, typed ds_map reads, event dispatch and event_inherited.

const std = @import("std");
const testing = std.testing;
const runtime = @import("runtime");
const rt = @import("rt.zig");

const Value = runtime.Value;
const Instance = runtime.Instance;
const InstanceManager = runtime.InstanceManager;

// ---------------------------------------------------------------------------
// Fixture: a small object tree with generated-style event handlers.
// ---------------------------------------------------------------------------

const OBJ_BASE = 0;
const OBJ_MID = 1; // parent BASE
const OBJ_LEAF = 2; // parent MID
const OBJ_OTHER = 3;
const OBJ_COUNT = 4;

const EV_CREATE = 0;
const EV_STEP = 3;
const EV_ALARM = 2;
const EV_DRAW = 8;
const EV_OTHER = 7;

var trace: [16]u8 = undefined;
var trace_len: usize = 0;

fn record(c: u8) void {
    trace[trace_len] = c;
    trace_len += 1;
}

fn traced() []const u8 {
    return trace[0..trace_len];
}

// Generated wrappers bracket their bodies with eventPush / eventPop.
fn baseStep(self: *Instance, other_opt: ?*Instance) void {
    const other = other_opt orelse self;
    const m = rt.eventPush(self, other, OBJ_BASE, EV_STEP, 0);
    defer rt.eventPop(m);
    record('B');
}

fn midStep(self: *Instance, other_opt: ?*Instance) void {
    const other = other_opt orelse self;
    const m = rt.eventPush(self, other, OBJ_MID, EV_STEP, 0);
    defer rt.eventPop(m);
    record('M');
    rt.eventInherited(self, other);
}

fn leafStep(self: *Instance, other_opt: ?*Instance) void {
    const other = other_opt orelse self;
    const m = rt.eventPush(self, other, OBJ_LEAF, EV_STEP, 0);
    defer rt.eventPop(m);
    // A temporary string and array die with the event.
    _ = rt.concat(rt.realStr(1.5), "x");
    _ = rt.arrayLit(&.{rt.vreal(1.0)});
    record('L');
    rt.eventInherited(self, other);
}

fn baseAlarm3(self: *Instance, _: ?*Instance) void {
    self.vars[0] += 1.0;
}

fn midDrawGui(self: *Instance, _: ?*Instance) void {
    self.vars[1] += 1.0;
}

fn otherUser0(self: *Instance, _: ?*Instance) void {
    self.vars[2] += 1.0;
}

fn scriptDouble(_: *Instance, _: *Instance, args: []const Value) Value {
    return rt.vreal(if (args.len > 0) args[0].toReal() * 2.0 else -1.0);
}

const parents = [OBJ_COUNT]i32{ -1, OBJ_BASE, OBJ_MID, -1 };
const events = [_]rt.EventEntry{
    .{ .object_index = OBJ_BASE, .ev_type = EV_ALARM, .number = 3, .func = baseAlarm3 },
    .{ .object_index = OBJ_BASE, .ev_type = EV_STEP, .number = 0, .func = baseStep },
    .{ .object_index = OBJ_MID, .ev_type = EV_STEP, .number = 0, .func = midStep },
    .{ .object_index = OBJ_MID, .ev_type = EV_DRAW, .number = 64, .func = midDrawGui },
    .{ .object_index = OBJ_LEAF, .ev_type = EV_STEP, .number = 0, .func = leafStep },
    .{ .object_index = OBJ_OTHER, .ev_type = EV_OTHER, .number = 10, .func = otherUser0 },
};
const scripts = [_]?rt.ScriptFn{ scriptDouble, null };
const game: rt.Game = .{ .object_parents = &parents, .events = &events, .scripts = &scripts };

const defs = [OBJ_COUNT]runtime.ObjectDef{
    .{ .name = "oBase" },
    .{ .name = "oMid", .parent_index = OBJ_BASE },
    .{ .name = "oLeaf", .parent_index = OBJ_MID },
    .{ .name = "oOther" },
};

fn fresh() void {
    rt.reset();
    runtime.StringManager.get().reset();
    runtime.RoomManager.get().reset();
    runtime.DsManager.get().reset();
    if (!runtime.ObjectRegistry.get().initRegistry(&defs)) @panic("object registry");
    InstanceManager.get().reset();
    InstanceManager.get().setNextId(runtime.instance.INSTANCE_ID_BASE);
    rt.install(&game);
    trace_len = 0;
}

fn mk(obj: i32) *Instance {
    return InstanceManager.get().create(obj, 0, 0).?;
}

// ---------------------------------------------------------------------------
// Values, comparisons, arithmetic
// ---------------------------------------------------------------------------

test "real comparisons use the 1e-5 epsilon and NaN is unordered" {
    try testing.expect(rt.eq(1.000001, 1.0));
    try testing.expect(!rt.ne(1.000001, 1.0));
    try testing.expect(rt.lt(1.0, 1.1) and rt.le(1.0, 1.000001) and !rt.lt(1.0, 1.000001));
    try testing.expect(rt.gt(1.1, 1.0) and rt.ge(1.0, 1.000001));
    const nan = std.math.nan(f32);
    try testing.expect(!rt.eq(nan, 1.0) and rt.ne(nan, 1.0));
    try testing.expect(!rt.lt(nan, 1.0) and !rt.le(nan, 1.0) and !rt.gt(nan, 1.0) and !rt.ge(nan, 1.0));
    try testing.expect(rt.eq(std.math.inf(f32), std.math.inf(f32)));

    try testing.expect(rt.veq(rt.vs("5"), rt.vreal(5.0)));
    try testing.expect(rt.vlt(rt.vs("a"), rt.vs("b")) and rt.vgt(rt.vs("b"), rt.vs("a")));
    try testing.expect(!rt.vlt(rt.vundef(), rt.vreal(1.0)) and !rt.vge(rt.vundef(), rt.vreal(1.0)));
    try testing.expect(rt.vne(rt.vundef(), rt.vreal(1.0)));
    try testing.expect(rt.vle(rt.vundef(), rt.vundef()));

    try testing.expect(rt.strLt("abc", "abd") and rt.strGe("b", "abc") and rt.strEq("x", "x"));
    try testing.expectEqual(@as(i32, 0), rt.strCmp("", ""));
    try testing.expectEqual(@as(i32, -1), rt.strCmp("", "a"));
}

test "switch case matching: same kind only" {
    try testing.expect(rt.case(rt.vreal(2.0), rt.vreal(2.000001)));
    try testing.expect(!rt.case(rt.vreal(2.0), rt.vs("2")));
    try testing.expect(rt.case(rt.vs("a"), rt.vs("a")) and !rt.case(rt.vs("a"), rt.vs("b")));
    try testing.expect(rt.case(rt.vundef(), rt.vundef()));
    try testing.expect(rt.rcase(3.0, 3.000001) and rt.strCase("x", "x"));
}

test "truthiness and conversions" {
    try testing.expect(!rt.truthy(0.5) and rt.truthy(0.51));
    try testing.expect(rt.vtruthy(rt.vs("true")) and !rt.vtruthy(rt.vs(" 1")));
    try testing.expectEqual(@as(f32, 42.0), rt.strReal(" 42 "));
    try testing.expect(rt.strTruthy("0.7"));
    try testing.expectEqual(@as(f32, 26.0), rt.strToReal("0x1A"));
    try testing.expectEqual(@as(f32, 0.0), rt.strToReal("abc"));
    try testing.expectEqual(@as(f32, 12.5), rt.toReal(rt.vs("12.5px")));
    try testing.expectEqual(@as(f32, 0.0), rt.toReal(rt.vundef()));
    try testing.expectEqual(@as(f32, 1.0), rt.toBool(rt.vs("true")));
    try testing.expectEqual(@as(f32, -2.0), rt.int64(-2.9));
    try testing.expectEqual(@as(f32, 0.0), rt.int64(std.math.inf(f32)));
    try testing.expectEqual(@as(f32, 1.0), rt.isReal(rt.vreal(0)));
    try testing.expectEqual(@as(f32, 1.0), rt.isString(rt.vs("")));
    try testing.expectEqual(@as(f32, 1.0), rt.isUndefined(rt.vundef()));
    try testing.expectEqual(@as(i32, 7), rt.repeatCount(7.9));
}

test "string concatenation and string()" {
    runtime.StringManager.get().reset();
    defer runtime.StringManager.get().reset();
    try testing.expectEqualStrings("12 gold", rt.concat(rt.realStr(12.0), " gold"));
    try testing.expectEqualStrings("0.50", rt.asStr(rt.vreal(0.5)));
    try testing.expectEqualStrings("undefined", rt.asStr(rt.vundef()));
    const sum = rt.add(rt.vs("ab"), rt.vs("cd"));
    try testing.expectEqualStrings("abcd", sum.string);
    // A string plus a non-string adds as reals.
    try testing.expectEqual(@as(f32, 7.0), rt.add(rt.vs("3"), rt.vreal(4.0)).real);
    try testing.expectEqual(@as(f32, 4.0), rt.add(rt.vs("abc"), rt.vreal(4.0)).real);
}

test "div, mod, bit operators and shifts (yyfdiv, JS %, ToInt32, Long)" {
    try testing.expectEqual(@as(f32, 3.0), rt.div(7.0, 2.0));
    try testing.expectEqual(@as(f32, -3.0), rt.div(-7.0, 2.0)); // truncation
    try testing.expectEqual(@as(f32, 1.0), rt.div(2.5, 2.5)); // a == b
    try testing.expectEqual(@as(f32, 0.0), rt.div(5.0, 0.4)); // ToInt32(0.4) == 0
    try testing.expectEqual(@as(f32, 2.0), rt.div(5.9, 2.9));
    const nan = std.math.nan(f32);
    try testing.expectEqual(@as(f32, 1.0), rt.div(nan, nan));
    try testing.expect(std.math.isNan(rt.div(nan, 2.0)));
    try testing.expectEqual(@as(f32, 1.0), rt.div(nan, std.math.inf(f32)));
    try testing.expect(std.math.isNan(rt.div(2.0, nan)));

    try testing.expectEqual(@as(f32, -2.0), rt.mod(-5.0, 3.0));
    try testing.expectEqual(@as(f32, 1.5), rt.mod(5.5, 2.0));
    try testing.expect(std.math.isNan(rt.mod(5.0, 0.0)));

    try testing.expectEqual(@as(f32, 2.0), rt.bitand(6.9, 3.0));
    try testing.expectEqual(@as(f32, 7.0), rt.bitor(6.0, 3.0));
    try testing.expectEqual(@as(f32, 5.0), rt.bitxor(6.0, 3.0));
    try testing.expectEqual(@as(f32, -1.0), rt.bitnot(0.0));

    try testing.expectEqual(@as(f32, 40.0), rt.shl(5.0, 3.0));
    try testing.expectEqual(@as(f32, -40.0), rt.shl(-5.0, 3.0)); // magnitude shifted, re-negated
    try testing.expectEqual(@as(f32, 4294967296.0), rt.shl(1.0, 32.0)); // 64-bit Long
    try testing.expectEqual(@as(f32, 0.0), rt.shl(1.0, 64.0));
    try testing.expectEqual(@as(f32, 2.0), rt.shr(5.0, 1.0));
    try testing.expectEqual(@as(f32, -2.0), rt.shr(-5.0, 1.0));
    try testing.expectEqual(@as(f32, 2.0), rt.shl(1.0, -63.0)); // -63 & 63 == 1
}

// ---------------------------------------------------------------------------
// Instances and variables
// ---------------------------------------------------------------------------

test "deref resolves self/other/all, ids (even marked) and own-before-child objects" {
    fresh();
    const leaf = mk(OBJ_LEAF);
    const mid = mk(OBJ_MID);
    const other = mk(OBJ_OTHER);
    try testing.expect(rt.deref(@floatFromInt(rt.GM_SELF), leaf, other) == leaf);
    try testing.expect(rt.deref(@floatFromInt(rt.GM_ALL), leaf, other) == leaf);
    try testing.expect(rt.deref(@floatFromInt(rt.GM_OTHER), leaf, other) == other);
    try testing.expect(rt.deref(@floatFromInt(rt.GM_NOONE), leaf, other) == null);
    // oMid has its own instance after a child one: the own instance wins.
    try testing.expect(rt.deref(OBJ_MID, leaf, other) == mid);
    // oBase is abstract: its first descendant.
    try testing.expect(rt.deref(OBJ_BASE, leaf, other) == leaf);
    try testing.expect(rt.deref(99.0, leaf, other) == null);
    try testing.expect(rt.deref(@floatFromInt(mid.id), leaf, other) == mid);
    mid.marked_for_destroy = true;
    try testing.expect(rt.deref(@floatFromInt(mid.id), leaf, other) == mid); // until reclaimed
    try testing.expect(rt.deref(OBJ_MID, leaf, other) == leaf); // marked: not usable
    try testing.expectEqual(@as(f32, @floatFromInt(rt.GM_NOONE)), rt.id(null));
    try testing.expectEqual(@as(f32, @floatFromInt(leaf.id)), rt.id(leaf));
}

test "variable access: null targets read 0 and drop writes; stores own their data" {
    fresh();
    const sm = runtime.StringManager.get();
    const p = mk(OBJ_OTHER);

    rt.ivarSet(p, 3, 9.0);
    rt.ivarSet(null, 3, 1.0);
    try testing.expectEqual(@as(f32, 9.0), rt.ivar(p, 3));
    try testing.expectEqual(@as(f32, 0.0), rt.ivar(null, 3));

    const m = sm.eventBegin();
    rt.svarSet(p, 1, rt.concat("he", "llo"));
    rt.vvarSet(p, 2, rt.vs(rt.concat("wor", "ld")));
    rt.aset(rt.vvarSlot(p, 3), 1.0, rt.vs(rt.concat("ele", "ment")));
    rt.svarSet(null, 1, "dropped");
    rt.vvarSet(null, 2, rt.vreal(1.0));
    rt.aset(rt.vvarSlot(null, 3), 0.0, rt.vreal(1.0));
    sm.eventEnd(m);

    try testing.expectEqualStrings("hello", rt.svar(p, 1));
    try testing.expectEqualStrings("world", rt.vvar(p, 2).string);
    try testing.expectEqualStrings("element", rt.aget(rt.vvar(p, 3), 1.0).string);
    try testing.expectEqualStrings("", rt.svar(null, 1));
    try testing.expect(rt.vvar(null, 2) == .undefined);
    try testing.expectEqual(@as(f32, 2.0), rt.arrayLength(rt.vvar(p, 3)));
    try testing.expectEqual(@as(usize, 1), runtime.ArrayManager.get().liveCount());
    try testing.expectEqual(@as(usize, 0), sm.failures);
}

test "array literals, nested writes and struct placeholders" {
    fresh();
    var local = rt.arrayLit(&.{ rt.vreal(1.0), rt.vs("a") });
    rt.aset(rt.aref(.local(&local), 2.0), 1.0, rt.vreal(5.0));
    try testing.expectEqual(@as(f32, 3.0), rt.arrayLength(local));
    try testing.expectEqual(@as(f32, 5.0), rt.aget(rt.aget(local, 2.0), 1.0).real);
    try testing.expect(rt.aget(local, -1.0) == .undefined);

    try testing.expect(rt.structGet(local, rt.vs("k")) == .undefined);
    rt.structSet(local, rt.vs("k"), rt.vreal(1.0));
    try testing.expectEqual(@as(usize, 1), rt.pendingCount());
    try testing.expectEqualStrings("struct accessor [$", rt.pendingName(0).?);
}

test "typed ds_map reads copy strings out of map storage" {
    fresh();
    const maps = runtime.DsManager.get();
    const map = maps.create().?;
    _ = maps.replace(map, "name", rt.vs("Spelunky"));
    _ = maps.replace(map, "score", rt.vreal(50.0));
    const fm: f32 = @floatFromInt(map);

    const name = rt.dsMapFindStr(fm, "name");
    try testing.expectEqualStrings("Spelunky", name);
    try testing.expect(runtime.StringManager.get().scratch.owns(name));
    try testing.expectEqualStrings("50", rt.dsMapFindStr(fm, "score"));
    try testing.expectEqualStrings("undefined", rt.dsMapFindStr(fm, "missing"));
    try testing.expectEqual(@as(f32, 50.0), rt.dsMapFindReal(fm, "score"));
    try testing.expectEqual(@as(f32, 0.0), rt.dsMapFindReal(fm, "name"));
    try testing.expectEqual(@as(f32, 1.0), rt.dsMapMissing(fm, "missing"));
    try testing.expectEqual(@as(f32, 0.0), rt.dsMapMissing(fm, "score"));
    try testing.expectEqual(@as(f32, 1.0), rt.dsMapMissing(-1.0, "score"));
}

// ---------------------------------------------------------------------------
// Events and scripts
// ---------------------------------------------------------------------------

test "findEvent inherits through parents; the dispatch cache agrees with the uncached search" {
    fresh();
    try testing.expect(rt.findEvent(OBJ_LEAF, EV_STEP, 0) == @as(?rt.EventFn, leafStep));
    try testing.expect(rt.findEvent(OBJ_LEAF, EV_ALARM, 3) == @as(?rt.EventFn, baseAlarm3));
    try testing.expect(rt.findEvent(OBJ_LEAF, EV_DRAW, 64) == @as(?rt.EventFn, midDrawGui));
    try testing.expect(rt.findEvent(OBJ_BASE, EV_DRAW, 64) == null);
    try testing.expect(rt.findEvent(OBJ_OTHER, EV_OTHER, 10) == @as(?rt.EventFn, otherUser0));
    try testing.expect(rt.findEvent(OBJ_OTHER, EV_STEP, 0) == null);
    try testing.expect(rt.findEvent(-1, EV_STEP, 0) == null);
    try testing.expect(rt.findOwnEvent(OBJ_LEAF, EV_ALARM, 3) == null);
    try testing.expect(rt.findOwnEvent(OBJ_BASE, EV_ALARM, 3) == @as(?rt.EventFn, baseAlarm3));

    // Every (object, type, number) the cache answers matches a walk of the
    // parent chain over the own-event table.
    const numbers = [_]i32{ 0, 1, 2, 3, 10, 11, 64, 72, 73, 74, 75, 76, 77, 99 };
    for (0..OBJ_COUNT) |o| {
        for (0..16) |t| {
            for (numbers) |n| {
                var expected: ?rt.EventFn = null;
                var p: i32 = @intCast(o);
                while (p >= 0) : (p = parents[@intCast(p)]) {
                    expected = rt.findOwnEvent(p, @intCast(t), n);
                    if (expected != null) break;
                }
                try testing.expect(expected == rt.findEvent(@intCast(o), @intCast(t), n));
            }
        }
    }
}

test "event_inherited walks the ancestors of the running handler" {
    fresh();
    const sm = runtime.StringManager.get();
    const leaf = mk(OBJ_LEAF);
    const step = rt.findEvent(OBJ_LEAF, EV_STEP, 0).?;
    step(leaf, leaf);
    try testing.expectEqualStrings("LMB", traced());
    // Every frame was popped and the event's temporaries released.
    try testing.expectEqual(@as(usize, 0), runtime.ContextManager.get().depth);
    try testing.expectEqual(@as(usize, 0), sm.scratch.used());
    try testing.expectEqual(@as(usize, 0), runtime.ArrayManager.get().liveCount());

    // Outside events, event_inherited is a no-op.
    rt.eventInherited(leaf, leaf);
    try testing.expectEqualStrings("LMB", traced());
}

test "creation code brackets context and scratch without an event frame" {
    fresh();
    const sm = runtime.StringManager.get();
    const leaf = mk(OBJ_LEAF);
    const m = rt.codePush(leaf, leaf);
    try testing.expectEqual(@as(usize, 1), runtime.ContextManager.get().depth);
    _ = rt.concat(rt.realStr(2.5), "y");
    _ = rt.arrayLit(&.{rt.vreal(1.0)});
    // Not an event: event_inherited() does nothing.
    rt.eventInherited(leaf, leaf);
    try testing.expectEqualStrings("", traced());
    rt.codePop(m);
    try testing.expectEqual(@as(usize, 0), runtime.ContextManager.get().depth);
    try testing.expectEqual(@as(usize, 0), sm.scratch.used());
    try testing.expectEqual(@as(usize, 0), runtime.ArrayManager.get().liveCount());
}

test "performEvent and loop/room hooks" {
    fresh();
    const p = mk(OBJ_LEAF);
    rt.performEvent(p, EV_ALARM, 3);
    try testing.expectEqual(@as(f32, 1.0), p.vars[0]);
    rt.performEvent(p, EV_ALARM, 4); // not defined: no-op
    try testing.expectEqual(@as(f32, 1.0), p.vars[0]);

    const hooks = rt.loopHooks();
    try testing.expect(hooks.find_event.?(OBJ_LEAF, EV_DRAW, 64) == @as(?rt.EventFn, midDrawGui));
    try testing.expect(hooks.find_own_event.?(OBJ_LEAF, EV_DRAW, 64) == null);
    // The safe point recycles strings released during the tick.
    const sm = runtime.StringManager.get();
    rt.svarSet(p, 0, "owned");
    rt.svarSet(p, 0, "replaced");
    try testing.expectEqual(@as(usize, 1), sm.store.retired_len);
    hooks.safe_point.?();
    try testing.expectEqual(@as(usize, 0), sm.store.retired_len);
    try testing.expect(rt.roomHooks().perform != null);
}

test "script_execute dispatches through the trampolines; invalid indices are recorded" {
    fresh();
    const p = mk(OBJ_OTHER);
    try testing.expectEqual(@as(f32, 8.0), rt.scriptExecute(p, p, 0.0, &.{rt.vreal(4.0)}).real);
    try testing.expect(rt.scriptExecute(p, p, 1.0, &.{}) == .undefined);
    try testing.expect(rt.scriptExecute(p, p, 7.0, &.{}) == .undefined);
    try testing.expectEqual(@as(usize, 1), rt.pendingCount()); // deduplicated
    rt.pendingHit("other");
    rt.pendingHit("other");
    try testing.expectEqual(@as(usize, 2), rt.pendingCount());
    try testing.expectEqualStrings("other", rt.pendingName(1).?);
    try testing.expect(rt.pendingName(2) == null);
    rt.pendingReset();
    try testing.expectEqual(@as(usize, 0), rt.pendingCount());
}

test "global init runs the installed game's pragma scripts" {
    fresh();
    const Init = struct {
        var runs: usize = 0;
        fn run() void {
            runs += 1;
        }
    };
    const with_init: rt.Game = .{ .object_parents = &parents, .events = &events, .scripts = &scripts, .global_init = Init.run };
    rt.install(&with_init);
    rt.globalInit();
    try testing.expectEqual(@as(usize, 1), Init.runs);
    try testing.expect(rt.installedGame() == &with_init);
    rt.reset();
    rt.globalInit(); // nothing installed
    try testing.expectEqual(@as(usize, 1), Init.runs);
}
