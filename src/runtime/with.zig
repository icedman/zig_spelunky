//! Zero-allocation GameMaker `with` iterator and execution context stack.
//! Follows reference/GameMaker-HTML5 (yyObject.js L1599) and packaged_src/src/runtime/gm_with.h.

const std = @import("std");
const Instance = @import("instance.zig").Instance;
const InstanceManager = @import("instance.zig").InstanceManager;
const ObjectRegistry = @import("object.zig").ObjectRegistry;
const GM_SELF = @import("instance.zig").GM_SELF;
const GM_OTHER = @import("instance.zig").GM_OTHER;
const GM_ALL = @import("instance.zig").GM_ALL;
const GM_NOONE = @import("instance.zig").GM_NOONE;
const INSTANCE_ID_BASE = @import("instance.zig").INSTANCE_ID_BASE;
const MAX_INSTANCES = @import("instance.zig").MAX_INSTANCES;

pub const MAX_CTX_DEPTH: usize = 64;

pub const ContextFrame = struct {
    self: ?*Instance = null,
    other: ?*Instance = null,
};

pub const ContextManager = struct {
    frames: [MAX_CTX_DEPTH]ContextFrame = [_]ContextFrame{.{}} ** MAX_CTX_DEPTH,
    depth: usize = 0,

    var instance: ContextManager = .{};

    pub fn get() *ContextManager {
        return &instance;
    }

    pub fn reset(self: *ContextManager) void {
        self.depth = 0;
    }

    pub fn push(self: *ContextManager, self_inst: ?*Instance, other_inst: ?*Instance) void {
        if (self.depth < MAX_CTX_DEPTH) {
            self.frames[self.depth] = .{ .self = self_inst, .other = other_inst };
        }
        self.depth += 1;
    }

    pub fn pop(self: *ContextManager) void {
        if (self.depth > 0) {
            self.depth -= 1;
        }
    }

    pub fn getSelf(self: *const ContextManager) ?*Instance {
        if (self.depth == 0) return null;
        const idx = @min(self.depth, MAX_CTX_DEPTH) - 1;
        return self.frames[idx].self;
    }

    pub fn getOther(self: *const ContextManager) ?*Instance {
        if (self.depth == 0) return null;
        const idx = @min(self.depth, MAX_CTX_DEPTH) - 1;
        return self.frames[idx].other;
    }
};

/// Open `with` statements at once (gm_with.c GM_WITH_MAX_DEPTH).
pub const MAX_WITH_DEPTH: usize = 32;
/// Snapshot slots shared by every open `with` (gm_with.c GM_WITH_SLOT_POOL).
pub const WITH_SLOT_POOL: usize = 4 * MAX_INSTANCES;

/// The snapshots of the open `with` statements, LIFO in one static pool
/// (gm_with.c `s_slots`), so a nested `with` costs no stack: an iterator is a
/// base offset + count into it.
pub const WithStack = struct {
    slots: [WITH_SLOT_POOL]*Instance = undefined,
    top: usize = 0,
    depth: usize = 0,
    overflows: usize = 0,

    var instance: WithStack = .{};

    pub fn get() *WithStack {
        return &instance;
    }

    /// Forgets every open snapshot (game restart, test isolation).
    pub fn reset(self: *WithStack) void {
        self.top = 0;
        self.depth = 0;
        self.overflows = 0;
    }
};

/// with (target) { body }: visits the GetWithArray set snapshotted when the
/// statement starts (yyObject.js L1599); instances created by the body are
/// not visited, those destroyed or deactivated before their turn are
/// skipped. Every `init` must be paired with `deinit` (`defer it.deinit()`),
/// which releases the snapshot even on an early return from the body.
/// Exceeding MAX_WITH_DEPTH or WITH_SLOT_POOL fails soft as in C: that body
/// runs zero times and `WithStack.overflows` counts it.
pub const WithIterator = struct {
    base: usize = 0,
    count: usize = 0,
    cursor: usize = 0,
    stored: bool = false,

    pub fn init(target: i32, self_inst: ?*Instance, other_inst: ?*Instance) WithIterator {
        const ws = WithStack.get();
        defer ws.depth += 1;
        if (ws.depth >= MAX_WITH_DEPTH) {
            ws.overflows += 1;
            return .{};
        }
        var it: WithIterator = .{ .base = ws.top, .stored = true };
        if (InstanceManager.get().withSnapshot(target, self_inst, other_inst, ws.slots[ws.top..])) |n| {
            it.count = n;
            ws.top += n;
        } else {
            ws.overflows += 1;
        }
        return it;
    }

    pub fn deinit(self: *WithIterator) void {
        const ws = WithStack.get();
        if (ws.depth > 0) ws.depth -= 1;
        if (self.stored) ws.top = self.base;
        self.count = 0;
    }

    /// gm_instance_with_slot: the next snapshot instance still usable.
    pub fn next(self: *WithIterator) ?*Instance {
        const ws = WithStack.get();
        while (self.cursor < self.count) {
            const inst = ws.slots[self.base + self.cursor];
            self.cursor += 1;
            if (inst.in_use and inst.active and !inst.marked_for_destroy) {
                return inst;
            }
        }
        return null;
    }
};

test "WithIterator snapshotting, skipping destroyed, and nested contexts" {
    const OBJ_MONKEY: i32 = 1;
    const defs = [_]@import("object.zig").ObjectDef{ .{ .name = "oOther" }, .{ .name = "oMonkey" } };
    try std.testing.expect(ObjectRegistry.get().initRegistry(&defs));
    var mgr = InstanceManager.get();
    mgr.reset();
    var ctx = ContextManager.get();
    ctx.reset();

    const m1 = mgr.create(OBJ_MONKEY, 10.0, 10.0).?;
    const m2 = mgr.create(OBJ_MONKEY, 20.0, 20.0).?;
    const m3 = mgr.create(OBJ_MONKEY, 30.0, 30.0).?;

    // Mark m2 as destroyed before with statement
    mgr.destroy(m2);

    var it = WithIterator.init(OBJ_MONKEY, null, null);
    defer it.deinit();
    var visited_count: usize = 0;

    while (it.next()) |inst| {
        ctx.push(inst, null);
        try std.testing.expect(inst.id == m1.id or inst.id == m3.id);
        visited_count += 1;
        ctx.pop();
    }

    try std.testing.expectEqual(@as(usize, 2), visited_count);
}

test "WithIterator nests LIFO in the shared pool and fails soft on overflow" {
    const defs = [_]@import("object.zig").ObjectDef{.{ .name = "oA" }};
    try std.testing.expect(ObjectRegistry.get().initRegistry(&defs));
    var mgr = InstanceManager.get();
    mgr.reset();
    const ws = WithStack.get();
    ws.reset();
    _ = mgr.create(0, 0.0, 0.0).?;
    _ = mgr.create(0, 0.0, 0.0).?;

    {
        var outer = WithIterator.init(0, null, null);
        defer outer.deinit();
        try std.testing.expectEqual(@as(usize, 2), ws.top);
        var visits: usize = 0;
        while (outer.next()) |_| {
            var inner = WithIterator.init(GM_ALL, null, null);
            defer inner.deinit();
            try std.testing.expectEqual(@as(usize, 4), ws.top);
            while (inner.next()) |_| visits += 1;
        }
        try std.testing.expectEqual(@as(usize, 4), visits);
        try std.testing.expectEqual(@as(usize, 2), ws.top);
    }
    try std.testing.expectEqual(@as(usize, 0), ws.top);
    try std.testing.expectEqual(@as(usize, 0), ws.depth);

    // Too deep: the body runs zero times, the stack stays balanced.
    var its: [MAX_WITH_DEPTH + 1]WithIterator = undefined;
    for (&its) |*it| it.* = WithIterator.init(0, null, null);
    try std.testing.expect(its[MAX_WITH_DEPTH].next() == null);
    try std.testing.expectEqual(@as(usize, 1), ws.overflows);
    var i = its.len;
    while (i > 0) {
        i -= 1;
        its[i].deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), ws.top);
    try std.testing.expectEqual(@as(usize, 0), ws.depth);
}

/// A generated function that `return`s from inside nested with bodies.
fn firstOfThreeNested(target: i32) ?*Instance {
    var w1 = WithIterator.init(target, null, null);
    defer w1.deinit();
    while (w1.next()) |_| {
        var w2 = WithIterator.init(target, null, null);
        defer w2.deinit();
        while (w2.next()) |_| {
            var w3 = WithIterator.init(target, null, null);
            defer w3.deinit();
            while (w3.next()) |inst| return inst;
        }
    }
    return null;
}

test "C Parity: test_unwind_restores_depth_and_slots (early return releases by defer)" {
    const defs = [_]@import("object.zig").ObjectDef{.{ .name = "oA" }};
    try std.testing.expect(ObjectRegistry.get().initRegistry(&defs));
    var mgr = InstanceManager.get();
    mgr.reset();
    const ws = WithStack.get();
    ws.reset();
    _ = mgr.create(0, 0.0, 0.0).?;
    _ = mgr.create(0, 0.0, 0.0).?;

    try std.testing.expect(firstOfThreeNested(0) != null);
    try std.testing.expectEqual(@as(usize, 0), ws.depth);
    try std.testing.expectEqual(@as(usize, 0), ws.top);
    // The slot pool was released: a new with sees a full snapshot.
    var it = WithIterator.init(0, null, null);
    defer it.deinit();
    try std.testing.expectEqual(@as(usize, 2), it.count);
}

test "C Parity: test_slot_pool_overflow_skips_the_body_and_counts" {
    const defs = [_]@import("object.zig").ObjectDef{.{ .name = "oA" }};
    try std.testing.expect(ObjectRegistry.get().initRegistry(&defs));
    var mgr = InstanceManager.get();
    mgr.reset();
    const ws = WithStack.get();
    ws.reset();
    for (0..MAX_INSTANCES) |_| _ = mgr.create(0, 0.0, 0.0).?;

    const levels = WITH_SLOT_POOL / MAX_INSTANCES;
    var its: [levels + 1]WithIterator = undefined;
    for (its[0..levels]) |*it| {
        it.* = WithIterator.init(GM_ALL, null, null);
        try std.testing.expect(it.next() != null);
    }
    try std.testing.expectEqual(@as(usize, 0), ws.overflows);
    its[levels] = WithIterator.init(GM_ALL, null, null);
    try std.testing.expect(its[levels].next() == null);
    try std.testing.expectEqual(@as(usize, 1), ws.overflows);
    var i = its.len;
    while (i > 0) {
        i -= 1;
        its[i].deinit();
    }
    try std.testing.expectEqual(@as(usize, 0), ws.top);
    try std.testing.expectEqual(@as(usize, 0), ws.depth);
    mgr.reset();
}
