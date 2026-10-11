//! Tagged GML values and arrays without a garbage collector.
//!
//! Conversions and comparison port packaged_src/src/runtime/gm_value.c
//! (GameMaker-HTML5 yyTypes.js yyGetReal / yyGetBool, Function_Maths.js
//! yyCompareVal / g_NumberRE). Runner errors become soft results (0, false).
//!
//! Arrays replace gm_heap's semispace arrays with ownership (see
//! agents/zig/WORKER.md section 5):
//!
//! * Every array is either *temporary* or *owned*. An array created through a
//!   local slot is temporary: it is recorded against the current event mark
//!   and released by `StringManager.eventEnd` (or the tick safe point).
//! * Persistent slots (instance and global variables) and array elements own
//!   their array. Storing a temporary into such a slot adopts it; storing an
//!   array that is already owned stores a deep copy (GameMaker arrays are
//!   copy-on-write between variables, so a copy is closer to GML than C's
//!   shared reference). Ownership therefore always forms trees: no cycles,
//!   no reference counts, no tracing.
//! * Overwriting or releasing an owning slot retires its array, recursively
//!   with its strings and child arrays. Retired arrays, element blocks and
//!   strings stay readable until `safePoint()` recycles them, so a value read
//!   earlier in the tick never dangles.
//! * Elements live in size-classed blocks of one static pool; growing past a
//!   block moves the elements to the next class and retires the old block.
//! * Array refs carry a generation, so a ref that outlived its array (only
//!   possible through a raw store that bypassed ownership) reads as undefined
//!   instead of aliasing a reused array.

const std = @import("std");
const math = @import("math.zig");
const string = @import("string.zig");
const StringManager = string.StringManager;

pub const ValueKind = enum {
    undefined,
    real,
    string,
    array_ref,
};

/// g_GMLMathEpsilon (Function_Maths.js L19).
pub const EPSILON: f32 = 1e-5;

/// yyCompareVal's "unordered" result (NaN involved, or undefined operand).
pub const CMP_UNORDERED: i32 = -2;

pub const Value = union(ValueKind) {
    undefined: void,
    real: f32,
    string: []const u8,
    array_ref: i32,

    pub const UNDEFINED: Value = .{ .undefined = {} };

    pub inline fn fromReal(r: f32) Value {
        return .{ .real = r };
    }

    pub inline fn fromBool(b: bool) Value {
        return .{ .real = if (b) 1.0 else 0.0 };
    }

    pub inline fn fromString(s: []const u8) Value {
        return .{ .string = s };
    }

    pub inline fn fromArrayRef(ref: i32) Value {
        return .{ .array_ref = ref };
    }

    pub inline fn isUndefined(self: Value) bool {
        return self == .undefined;
    }

    pub inline fn isReal(self: Value) bool {
        return self == .real;
    }

    pub inline fn isString(self: Value) bool {
        return self == .string;
    }

    pub inline fn isArray(self: Value) bool {
        return self == .array_ref;
    }

    /// yyGetReal (yyTypes.js L173): strings are trimmed and must start with a
    /// number (g_NumberRE prefix); everything else non-real is 0.
    pub fn toReal(self: Value) f32 {
        return switch (self) {
            .real => |r| r,
            .string => |s| stringNumber(s, true) orelse 0.0,
            .undefined, .array_ref => 0.0,
        };
    }

    /// yyGetBool (yyTypes.js L318): reals above 0.5; "true" / "false" or an
    /// untrimmed numeric prefix above 0.5; undefined and arrays are false.
    pub fn toBool(self: Value) bool {
        return switch (self) {
            .real => |r| r > 0.5,
            .string => |s| blk: {
                if (std.mem.eql(u8, s, "true")) break :blk true;
                if (std.mem.eql(u8, s, "false")) break :blk false;
                const d = stringNumber(s, false) orelse break :blk false;
                break :blk d > 0.5;
            },
            .undefined, .array_ref => false,
        };
    }
};

// ---------------------------------------------------------------------------
// Number parsing and comparison (gm_value.c).
// ---------------------------------------------------------------------------

/// Longest g_NumberRE match: sign + 30 digits + '.' + 30 digits + e+29.
const number_max = 72;

inline fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn countDigits(s: []const u8, max: usize) usize {
    var n: usize = 0;
    while (n < max and n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return n;
}

fn at(s: []const u8, i: usize) u8 {
    return if (i < s.len) s[i] else 0;
}

/// Length of the g_NumberRE match at the start of `s` (0 = no match):
/// `[-+]?(?:[0-9]{0,30}\.)?[0-9]{1,30}(?:[Ee][-+]?[1-2]?[0-9])?`.
pub fn numberPrefix(s: []const u8) usize {
    var i: usize = 0;
    var end: usize = 0;
    if (at(s, 0) == '+' or at(s, 0) == '-') i += 1;
    var n = countDigits(s[i..], 31);
    if (n <= 30 and at(s, i + n) == '.') {
        const frac = countDigits(s[@min(s.len, i + n + 1)..], 30);
        if (frac > 0) end = i + n + 1 + frac;
    }
    if (end == 0) {
        n = countDigits(s[i..], 30);
        if (n == 0) return 0;
        end = i + n;
    }
    if (at(s, end) == 'e' or at(s, end) == 'E') {
        var p = end + 1;
        if (at(s, p) == '+' or at(s, p) == '-') p += 1;
        if ((at(s, p) == '1' or at(s, p) == '2') and std.ascii.isDigit(at(s, p + 1))) {
            end = p + 2;
        } else if (std.ascii.isDigit(at(s, p))) {
            end = p + 1;
        }
    }
    return end;
}

/// yyGetReal-style string conversion: optionally trimmed, g_NumberRE prefix.
fn stringNumber(s: []const u8, trim: bool) ?f32 {
    var t = s;
    if (trim) {
        var i: usize = 0;
        while (i < t.len and isSpace(t[i])) i += 1;
        t = t[i..];
    }
    const n = numberPrefix(t);
    if (n == 0) return null;
    // The prefix is always valid float syntax (fuzzed against gm_value.c).
    return std.fmt.parseFloat(f32, t[0..@min(n, number_max)]) catch 0.0;
}

/// yyCompareVal for two numbers: 0 when |a - b| <= EPSILON, else -1 / 1;
/// CMP_UNORDERED for NaN (equal infinities compare equal).
pub fn compareReal(a: f32, b: f32) i32 {
    const f = a - b;
    if (std.math.isNan(f)) {
        return if (!std.math.isNan(a) and !std.math.isNan(b)) 0 else CMP_UNORDERED;
    }
    return if (@abs(f) <= EPSILON) 0 else if (f < 0.0) -1 else 1;
}

/// yyCompareVal (Function_Maths.js L1654): numbers with epsilon, strings by
/// byte, undefined == undefined, arrays by length then identity, otherwise
/// both sides converted to numbers where possible. Returns -1, 0, 1 or
/// CMP_UNORDERED.
pub fn compare(a: Value, b: Value) i32 {
    if (a == .real and b == .real) return compareReal(a.real, b.real);
    if (a == .string and b == .string) {
        return switch (std.mem.order(u8, a.string, b.string)) {
            .lt => -1,
            .eq => 0,
            .gt => 1,
        };
    }
    if (a == .undefined and b == .undefined) return 0;
    if (a == .array_ref and b == .array_ref) {
        const arrays = ArrayManager.get();
        const la = arrays.length(a.array_ref);
        const lb = arrays.length(b.array_ref);
        if (la != lb) return if (la < lb) -1 else 1;
        return if (a.array_ref == b.array_ref) 0 else 1;
    }
    if ((a == .undefined and b == .array_ref) or (b == .undefined and a == .array_ref)) return 1;

    // Mixed kinds (Function_Maths.js L1737-1818).
    var ret_set = false;
    var ret_nan = false;
    var ret: i32 = 0;
    var na: ?f32 = null;
    var nb: ?f32 = null;
    switch (a) {
        .real => |r| na = r,
        .string => |s| {
            na = stringNumber(s, true);
            if (na == null) {
                ret_set = true;
                ret_nan = true;
            }
        },
        .array_ref => {
            ret_set = true;
            ret = 1;
        },
        .undefined => {
            ret_set = true;
            ret = CMP_UNORDERED;
        },
    }
    switch (b) {
        .real => |r| nb = r,
        .string => |s| {
            nb = stringNumber(s, true);
            if (nb == null) {
                ret_set = true;
                ret_nan = true;
            }
        },
        .array_ref => {}, // runner error only
        .undefined => {
            ret_set = true;
            ret_nan = false;
            ret = CMP_UNORDERED;
        },
    }
    if (!ret_set) {
        return if (na != null and nb != null) compareReal(na.?, nb.?) else 1;
    }
    if (ret_nan or ret != CMP_UNORDERED) return if (na != null) -1 else 1;
    return ret;
}

// ---------------------------------------------------------------------------
// Arrays.
// ---------------------------------------------------------------------------

pub const max_arrays: usize = 4096;
/// Elements per array (GM_ARRAY_MAX_LENGTH).
pub const max_length: usize = 65536;
/// Elements in the shared pool.
pub const pool_len: usize = 2 * max_length;
/// Temporary arrays alive at once (across nested events).
pub const max_temps: usize = 1024;
/// Element blocks retired within one tick before they are recycled.
pub const max_retired_blocks: usize = 4096;

const idx_bits: u5 = std.math.log2_int(usize, max_arrays);
const idx_mask: u32 = max_arrays - 1;
const gen_mask: u32 = (@as(u32, 1) << (31 - idx_bits)) - 1;
const min_class_len: usize = 4;
const class_count = std.math.log2_int(usize, max_length / min_class_len) + 1;
const none: u32 = std.math.maxInt(u32);

comptime {
    std.debug.assert(std.math.isPowerOfTwo(max_arrays));
    std.debug.assert(min_class_len << (class_count - 1) == max_length);
    std.debug.assert(pool_len % min_class_len == 0);
}

fn classLen(k: usize) usize {
    return min_class_len << @intCast(k);
}

fn classFor(n: usize) ?u8 {
    var k: u8 = 0;
    while (k < class_count) : (k += 1) {
        if (classLen(k) >= n) return k;
    }
    return null;
}

/// Who owns the array a slot holds (see the module doc).
pub const Owner = union(enum) {
    /// GML local or expression temporary: arrays created here are temporary
    /// and plain assignment aliases.
    local,
    /// Instance or global variable.
    persistent,
    /// Element of the array with this index.
    element: u32,
};

/// A writable value slot and its ownership kind.
pub const Slot = struct {
    ptr: *Value,
    owner: Owner,

    pub fn local(ptr: *Value) Slot {
        return .{ .ptr = ptr, .owner = .local };
    }

    pub fn persistent(ptr: *Value) Slot {
        return .{ .ptr = ptr, .owner = .persistent };
    }
};

const State = enum(u8) { free, temp, owned, retired };

const Header = struct {
    state: State = .free,
    /// Block class, or null for an array that never had elements.
    class: ?u8 = null,
    gen: u32 = 0,
    offset: u32 = 0,
    len: u32 = 0,
    /// Owning array when owned by an element, else `none`.
    parent: u32 = none,
};

const RetiredBlock = struct { offset: u32, class: u8 };

pub const ArrayManager = struct {
    headers: [max_arrays]Header = @splat(.{}),
    /// Headers handed out so far; recycled ones go to `free_ids`.
    next_header: u32 = 0,
    free_ids: [max_arrays]u16 = undefined,
    free_len: usize = 0,

    elements: *[pool_len]Value,
    bump: usize = 0,
    free_blocks: [class_count]u32 = @splat(none),
    /// Free-list links, one per `min_class_len` elements of the pool.
    next_block: *[pool_len / min_class_len]u32,
    retired_blocks: [max_retired_blocks]RetiredBlock = undefined,
    retired_len: usize = 0,
    /// Blocks lost because the retired queue was full (reclaimed by `reset`).
    leaked: usize = 0,

    temps: [max_temps]i32 = undefined,
    temps_len: usize = 0,

    /// Stand-in target for element refs that could not be created.
    sink: Value = Value.UNDEFINED,

    var pool: [pool_len]Value = undefined;
    var links: [pool_len / min_class_len]u32 = undefined;
    var instance: ArrayManager = .{ .elements = &pool, .next_block = &links };

    pub fn get() *ArrayManager {
        return &instance;
    }

    /// Forgets every array (game restart, test isolation). Called by
    /// `StringManager.reset`, since elements hold store strings.
    pub fn reset(self: *ArrayManager) void {
        self.* = .{ .elements = self.elements, .next_block = self.next_block };
    }

    // ---- refs ----

    fn encode(self: *const ArrayManager, idx: u32) i32 {
        return @intCast(idx | (self.headers[idx].gen << idx_bits));
    }

    /// Index of a readable (live or retired-this-tick) array.
    fn lookup(self: *const ArrayManager, ref: i32) ?u32 {
        if (ref < 0) return null;
        const r: u32 = @intCast(ref);
        const idx: u32 = r & idx_mask;
        const h = &self.headers[idx];
        if (h.state == .free or h.gen != r >> idx_bits) return null;
        return idx;
    }

    fn lookupValue(self: *const ArrayManager, v: Value) ?u32 {
        return if (v == .array_ref) self.lookup(v.array_ref) else null;
    }

    fn items(self: *const ArrayManager, idx: u32) []Value {
        const h = &self.headers[idx];
        return self.elements[h.offset..][0..h.len];
    }

    // ---- reads ----

    pub fn valid(self: *const ArrayManager, v: Value) bool {
        return self.lookupValue(v) != null;
    }

    /// 0 for non-arrays.
    pub fn length(self: *const ArrayManager, ref: i32) usize {
        const idx = self.lookup(ref) orelse return 0;
        return self.headers[idx].len;
    }

    pub fn getElement(self: *const ArrayManager, ref: i32, i: usize) Value {
        const idx = self.lookup(ref) orelse return Value.UNDEFINED;
        const elems = self.items(idx);
        return if (i < elems.len) elems[i] else Value.UNDEFINED;
    }

    /// gm_array_get: undefined for non-arrays and out-of-range indices.
    pub fn read(self: *const ArrayManager, v: Value, index: i32) Value {
        if (v != .array_ref or index < 0) return Value.UNDEFINED;
        return self.getElement(v.array_ref, @intCast(index));
    }

    // ---- creation ----

    fn newHeader(self: *ArrayManager, owner: Owner) ?u32 {
        if (owner == .local and self.temps_len == max_temps) return null;
        const idx: u32 = if (self.free_len > 0) blk: {
            self.free_len -= 1;
            break :blk self.free_ids[self.free_len];
        } else if (self.next_header < max_arrays) blk: {
            self.next_header += 1;
            break :blk self.next_header - 1;
        } else return null;
        const h = &self.headers[idx];
        h.* = .{ .gen = h.gen };
        switch (owner) {
            .local => {
                h.state = .temp;
                self.temps[self.temps_len] = self.encode(idx);
                self.temps_len += 1;
            },
            .persistent => h.state = .owned,
            .element => |p| {
                h.state = .owned;
                h.parent = p;
            },
        }
        return idx;
    }

    /// gm_array_new: a temporary array of `n` undefined elements.
    pub fn newArray(self: *ArrayManager, n: usize) Value {
        const idx = self.newHeader(.local) orelse return failValue();
        if (!self.grow(idx, n)) return failValue();
        return .{ .array_ref = self.encode(idx) };
    }

    /// Array literal `[a, b, c]`: a temporary array.
    pub fn literal(self: *ArrayManager, values: []const Value) Value {
        const v = self.newArray(values.len);
        const idx = self.lookupValue(v) orelse return v;
        for (values, 0..) |item, i| {
            self.store(.{ .ptr = &self.items(idx)[i], .owner = .{ .element = idx } }, item);
        }
        return v;
    }

    // ---- writes ----

    /// `slot[index] = v`. A non-array slot becomes a new array first; writes
    /// past the end grow the array and the skipped elements read undefined.
    pub fn set(self: *ArrayManager, slot: Slot, index: i32, v: Value) void {
        var val = v;
        // `a[i] = a` (or an ancestor of a): GML evaluates the right side
        // first, so store a copy taken before the target grows.
        if (self.lookupValue(v)) |src| {
            if (self.lookupValue(slot.ptr.*)) |target| {
                if (self.isAncestorOrSelf(src, target)) val = self.copy(src, .local);
            }
        }
        const elem = self.elementSlot(slot, index) orelse return;
        self.store(elem, val);
    }

    /// Slot of element `index` of the array in `slot` (created and grown as
    /// for `set`), for nested writes `slot[index][j] = v`. Valid until the
    /// next write that grows the same array.
    pub fn elementRef(self: *ArrayManager, slot: Slot, index: i32) Slot {
        return self.elementSlot(slot, index) orelse blk: {
            self.sink = Value.UNDEFINED;
            break :blk Slot.local(&self.sink);
        };
    }

    fn elementSlot(self: *ArrayManager, slot: Slot, index: i32) ?Slot {
        if (index < 0 or index >= max_length) return failNull(Slot);
        const i: usize = @intCast(index);
        const idx = self.ensureArray(slot) orelse return null;
        if (!self.grow(idx, i + 1)) return failNull(Slot);
        return .{ .ptr = &self.items(idx)[i], .owner = .{ .element = idx } };
    }

    fn ensureArray(self: *ArrayManager, slot: Slot) ?u32 {
        if (self.lookupValue(slot.ptr.*)) |idx| {
            // Writes through a stale alias of a retired array are dropped.
            return if (self.headers[idx].state == .retired) null else idx;
        }
        const idx = self.newHeader(slot.owner) orelse return failNull(u32);
        if (slot.owner != .local) self.release(slot.ptr);
        slot.ptr.* = .{ .array_ref = self.encode(idx) };
        return idx;
    }

    /// Makes room for `n` elements, moving to a larger block if needed.
    fn grow(self: *ArrayManager, idx: u32, n: usize) bool {
        const h = &self.headers[idx];
        if (n <= h.len) return true;
        if (h.class == null or n > classLen(h.class.?)) {
            const k = classFor(n) orelse return false;
            const offset = self.allocBlock(k) orelse return false;
            @memcpy(self.elements[offset..][0..h.len], self.items(idx));
            if (h.class) |old| self.retireBlock(h.offset, old);
            h.offset = offset;
            h.class = k;
        }
        h.len = @intCast(n);
        return true;
    }

    /// `slot = v` with ownership: strings are copied into the store, arrays
    /// adopted (temporaries) or deep-copied (already owned). Local slots just
    /// alias.
    pub fn store(self: *ArrayManager, slot: Slot, v: Value) void {
        const parent: u32 = switch (slot.owner) {
            .local => {
                slot.ptr.* = v;
                return;
            },
            .persistent => none,
            .element => |p| p,
        };
        const sm = StringManager.get();
        const new: Value = switch (v) {
            .string => |s| blk: {
                if (slot.ptr.* == .string and slot.ptr.string.ptr == s.ptr and slot.ptr.string.len == s.len) return;
                break :blk .{ .string = sm.store.dupe(s) catch sm.fail() };
            },
            .array_ref => |r| blk: {
                if (slot.ptr.* == .array_ref and slot.ptr.array_ref == r) return;
                const idx = self.lookup(r) orelse break :blk Value.UNDEFINED;
                const h = &self.headers[idx];
                if (h.state == .temp and !self.isAncestorOrSelf(idx, parent)) {
                    h.state = .owned;
                    h.parent = parent;
                    break :blk v;
                }
                break :blk self.copy(idx, if (parent == none) .persistent else .{ .element = parent });
            },
            .real, .undefined => v,
        };
        self.release(slot.ptr);
        slot.ptr.* = new;
    }

    /// Clears an owning slot, retiring its string or array.
    pub fn release(self: *ArrayManager, slot: *Value) void {
        switch (slot.*) {
            .string => |s| StringManager.get().store.retire(s),
            .array_ref => |r| if (self.lookup(r)) |idx| {
                if (self.headers[idx].state == .owned) self.retireArray(idx);
            },
            .real, .undefined => {},
        }
        slot.* = Value.UNDEFINED;
    }

    fn isAncestorOrSelf(self: *const ArrayManager, idx: u32, start: u32) bool {
        var p = start;
        while (p != none) : (p = self.headers[p].parent) {
            if (p == idx) return true;
        }
        return false;
    }

    /// Deep copy of array `src` for a slot with the given owner.
    fn copy(self: *ArrayManager, src: u32, owner: Owner) Value {
        const idx = self.newHeader(owner) orelse return failValue();
        const result: Value = .{ .array_ref = self.encode(idx) };
        const n = self.headers[src].len;
        if (!self.grow(idx, n)) {
            _ = StringManager.get().fail();
            return result;
        }
        const sm = StringManager.get();
        for (self.items(src), self.items(idx)) |from, *to| {
            to.* = switch (from) {
                .string => |s| .{ .string = sm.store.dupe(s) catch sm.fail() },
                .array_ref => |r| if (self.lookup(r)) |child| self.copy(child, .{ .element = idx }) else Value.UNDEFINED,
                .real, .undefined => from,
            };
        }
        return result;
    }

    fn retireArray(self: *ArrayManager, idx: u32) void {
        const h = &self.headers[idx];
        h.state = .retired;
        const sm = StringManager.get();
        for (self.items(idx)) |e| switch (e) {
            .string => |s| sm.store.retire(s),
            .array_ref => |r| if (self.lookup(r)) |child| {
                const c = &self.headers[child];
                if (c.state == .owned and c.parent == idx) self.retireArray(child);
            },
            .real, .undefined => {},
        };
        if (h.class) |k| self.retireBlock(h.offset, k);
    }

    // ---- lifetimes ----

    /// Temporaries created so far; pass to `endTemps`.
    pub fn tempMark(self: *const ArrayManager) usize {
        return self.temps_len;
    }

    /// Releases the temporaries created since `mark` that were not adopted.
    pub fn endTemps(self: *ArrayManager, mark: usize) void {
        std.debug.assert(mark <= self.temps_len);
        for (self.temps[mark..self.temps_len]) |r| {
            const idx = self.lookup(r) orelse continue;
            if (self.headers[idx].state == .temp) self.retireArray(idx);
        }
        self.temps_len = mark;
    }

    /// End-of-tick safe point: releases leftover temporaries and recycles
    /// retired arrays and blocks.
    pub fn safePoint(self: *ArrayManager) void {
        self.endTemps(0);
        for (self.headers[0..self.next_header], 0..) |*h, i| {
            if (h.state != .retired) continue;
            h.* = .{ .gen = (h.gen + 1) & gen_mask };
            self.free_ids[self.free_len] = @intCast(i);
            self.free_len += 1;
        }
        for (self.retired_blocks[0..self.retired_len]) |b| {
            self.next_block[b.offset / min_class_len] = self.free_blocks[b.class];
            self.free_blocks[b.class] = b.offset;
        }
        self.retired_len = 0;
    }

    pub fn liveCount(self: *const ArrayManager) usize {
        var n: usize = 0;
        for (self.headers[0..self.next_header]) |h| n += @intFromBool(h.state == .temp or h.state == .owned);
        return n;
    }

    // ---- element blocks ----

    fn allocBlock(self: *ArrayManager, k: u8) ?u32 {
        const size = classLen(k);
        const offset: u32 = if (self.free_blocks[k] != none) blk: {
            const o = self.free_blocks[k];
            self.free_blocks[k] = self.next_block[o / min_class_len];
            break :blk o;
        } else blk: {
            if (self.bump + size > pool_len) return null;
            self.bump += size;
            break :blk @intCast(self.bump - size);
        };
        @memset(self.elements[offset..][0..size], Value.UNDEFINED);
        return offset;
    }

    fn retireBlock(self: *ArrayManager, offset: u32, k: u8) void {
        if (self.retired_len == max_retired_blocks) {
            self.leaked += 1;
            return;
        }
        self.retired_blocks[self.retired_len] = .{ .offset = offset, .class = k };
        self.retired_len += 1;
    }

    fn failValue() Value {
        _ = StringManager.get().fail();
        return Value.UNDEFINED;
    }

    fn failNull(comptime T: type) ?T {
        _ = StringManager.get().fail();
        return null;
    }
};

// ---- GML-facing helpers (gml_aget / gml_aset / gml_aref) ----

pub fn aget(v: Value, index: f32) Value {
    return ArrayManager.get().read(v, math.toInt32(index));
}

pub fn aset(slot: Slot, index: f32, v: Value) void {
    ArrayManager.get().set(slot, math.toInt32(index), v);
}

pub fn aref(slot: Slot, index: f32) Slot {
    return ArrayManager.get().elementRef(slot, math.toInt32(index));
}

// ---------------------------------------------------------------------------
// Tests: tests/test_value.c, the array parts of tests/test_heap.c, ownership.
// ---------------------------------------------------------------------------

const testing = std.testing;

fn freshHeap() *ArrayManager {
    StringManager.get().reset(); // also resets the arrays
    return ArrayManager.get();
}

test "numberPrefix follows g_NumberRE (test_number_prefix)" {
    try testing.expectEqual(@as(usize, 2), numberPrefix("12abc"));
    try testing.expectEqual(@as(usize, 2), numberPrefix("12."));
    try testing.expectEqual(@as(usize, 2), numberPrefix(".5"));
    try testing.expectEqual(@as(usize, 6), numberPrefix("-1.5e3x"));
    try testing.expectEqual(@as(usize, 4), numberPrefix("1e25"));
    try testing.expectEqual(@as(usize, 3), numberPrefix("1e35")); // exponent is [1-2]?[0-9]
    try testing.expectEqual(@as(usize, 1), numberPrefix("1e"));
    try testing.expectEqual(@as(usize, 0), numberPrefix("e5"));
    try testing.expectEqual(@as(usize, 0), numberPrefix("+"));
    try testing.expectEqual(@as(usize, 0), numberPrefix(" 1"));
    try testing.expectEqual(@as(usize, 0), numberPrefix(""));
    try testing.expectEqual(@as(usize, 30), numberPrefix("1" ** 40)); // [0-9]{1,30}
}

test "toReal and toBool (test_to_real_and_bool)" {
    try testing.expectEqual(@as(f32, 42.0), Value.fromString(" 42 ").toReal());
    try testing.expectEqual(@as(f32, -1500.0), Value.fromString("-1.5e3px").toReal());
    try testing.expectEqual(@as(f32, 0.0), Value.fromString("abc").toReal());
    try testing.expectEqual(@as(f32, 0.0), Value.UNDEFINED.toReal());
    try testing.expectEqual(@as(f32, 2.5), Value.fromReal(2.5).toReal());

    try testing.expect(!Value.fromReal(0.5).toBool());
    try testing.expect(Value.fromReal(0.51).toBool());
    try testing.expect(Value.fromString("true").toBool());
    try testing.expect(!Value.fromString("false").toBool());
    try testing.expect(Value.fromString("0.7").toBool());
    try testing.expect(!Value.fromString(" 1").toBool()); // untrimmed match
    try testing.expect(!Value.UNDEFINED.toBool());
}

test "compare (test_compare)" {
    const arrays = freshHeap();
    defer _ = freshHeap();

    try testing.expectEqual(@as(i32, 0), compareReal(1.000001, 1.0));
    try testing.expectEqual(@as(i32, -1), compareReal(1.0, 1.1));
    try testing.expectEqual(@as(i32, 1), compareReal(1.1, 1.0));
    try testing.expectEqual(@as(i32, 0), compareReal(std.math.inf(f32), std.math.inf(f32)));
    try testing.expectEqual(CMP_UNORDERED, compareReal(std.math.nan(f32), 1.0));

    const s = Value.fromString;
    const r = Value.fromReal;
    try testing.expectEqual(@as(i32, -1), compare(s("a"), s("b")));
    try testing.expectEqual(@as(i32, 0), compare(s("a"), s("a")));
    try testing.expectEqual(@as(i32, 0), compare(Value.UNDEFINED, Value.UNDEFINED));
    try testing.expectEqual(CMP_UNORDERED, compare(Value.UNDEFINED, r(1.0)));
    try testing.expectEqual(CMP_UNORDERED, compare(r(1.0), Value.UNDEFINED));
    try testing.expectEqual(@as(i32, 0), compare(s("5"), r(5.0)));
    try testing.expectEqual(@as(i32, 1), compare(s("abc"), r(5.0)));
    try testing.expectEqual(@as(i32, -1), compare(r(5.0), s("abc")));
    // b == undefined overrides a's failed string conversion (L1795).
    try testing.expectEqual(CMP_UNORDERED, compare(s(""), Value.UNDEFINED));

    var arr = Value.UNDEFINED;
    var other = Value.UNDEFINED;
    arrays.set(.local(&arr), 0, r(1.0));
    arrays.set(.local(&other), 0, r(1.0));
    try testing.expectEqual(@as(i32, 0), compare(arr, arr));
    try testing.expectEqual(@as(i32, 1), compare(arr, other));
    try testing.expectEqual(@as(i32, 1), compare(arr, Value.UNDEFINED));
    arrays.set(.local(&other), 1, r(1.0));
    try testing.expectEqual(@as(i32, -1), compare(arr, other));
}

test "array basics (test_array_basics)" {
    const arrays = freshHeap();
    defer _ = freshHeap();
    const sm = StringManager.get();

    const a = arrays.newArray(3);
    try testing.expect(arrays.valid(a));
    try testing.expectEqual(@as(usize, 3), arrays.length(a.array_ref));
    try testing.expect(arrays.read(a, 0) == .undefined);

    // Writing to a non-array slot creates an array; holes read undefined.
    var slot = Value.UNDEFINED;
    arrays.set(.local(&slot), 5, Value.fromReal(7.0));
    try testing.expect(arrays.valid(slot));
    try testing.expectEqual(@as(usize, 6), arrays.length(slot.array_ref));
    try testing.expect(arrays.read(slot, 2) == .undefined);
    try testing.expectEqual(@as(f32, 7.0), arrays.read(slot, 5).real);

    // Growth keeps existing elements.
    arrays.set(.local(&slot), 100, Value.fromString("far"));
    try testing.expectEqual(@as(usize, 101), arrays.length(slot.array_ref));
    try testing.expectEqual(@as(f32, 7.0), arrays.read(slot, 5).real);
    try testing.expectEqualStrings("far", arrays.read(slot, 100).string);

    // Out-of-range reads and bad writes are soft.
    try testing.expect(arrays.read(slot, -1) == .undefined);
    try testing.expect(arrays.read(slot, 101) == .undefined);
    try testing.expect(arrays.read(Value.fromReal(3.0), 0) == .undefined);
    try testing.expectEqual(@as(usize, 0), arrays.length(-1));
    arrays.set(.local(&slot), -1, Value.fromReal(1.0));
    try testing.expectEqual(@as(usize, 101), arrays.length(slot.array_ref));
    try testing.expectEqual(@as(usize, 1), sm.failures);

    // GML helpers truncate the index like gml_aget / gml_aset.
    aset(.local(&slot), 2.9, Value.fromReal(4.0));
    try testing.expectEqual(@as(f32, 4.0), aget(slot, 2.2).real);
}

test "array aliasing and nested arrays (test_array_reference_semantics)" {
    const arrays = freshHeap();
    defer _ = freshHeap();

    // Plain assignment between locals aliases, like the C port.
    var a = Value.UNDEFINED;
    arrays.set(.local(&a), 0, Value.fromReal(1.0));
    var alias = a;
    arrays.set(.local(&alias), 0, Value.fromReal(2.0));
    try testing.expectEqual(@as(f32, 2.0), arrays.read(a, 0).real);

    // Nested (2D) arrays through element refs.
    arrays.set(arrays.elementRef(.local(&a), 1), 2, Value.fromReal(9.0));
    try testing.expect(arrays.valid(arrays.read(a, 1)));
    try testing.expectEqual(@as(f32, 9.0), arrays.read(arrays.read(a, 1), 2).real);
}

test "persistent slots adopt temporaries and copy owned arrays" {
    const arrays = freshHeap();
    defer _ = freshHeap();
    const sm = StringManager.get();

    var global_a = Value.UNDEFINED;
    var global_b = Value.UNDEFINED;

    const m = sm.eventBegin();
    var tmp = Value.UNDEFINED;
    arrays.set(.local(&tmp), 0, Value.fromString(sm.concat("te", "mp")));
    arrays.store(.persistent(&global_a), tmp); // adopted: no copy
    try testing.expectEqual(tmp.array_ref, global_a.array_ref);
    arrays.store(.persistent(&global_b), global_a); // already owned: copied
    try testing.expect(global_b.array_ref != global_a.array_ref);
    arrays.set(.persistent(&global_b), 0, Value.fromReal(5.0));
    sm.eventEnd(m);

    try testing.expectEqual(@as(usize, 0), sm.scratch.used());
    try testing.expectEqualStrings("temp", arrays.read(global_a, 0).string);
    try testing.expectEqual(@as(f32, 5.0), arrays.read(global_b, 0).real);
    try testing.expectEqual(@as(usize, 2), arrays.liveCount());

    // Persistent writes into a fresh slot create an owned array directly.
    var global_c = Value.UNDEFINED;
    arrays.set(arrays.elementRef(.persistent(&global_c), 3), 1, Value.fromReal(1.0));
    sm.safePoint();
    try testing.expectEqual(@as(f32, 1.0), arrays.read(arrays.read(global_c, 3), 1).real);
    try testing.expectEqual(@as(usize, 4), arrays.liveCount());
    try testing.expectEqual(@as(usize, 0), sm.failures);
}

test "temporaries are released at eventEnd, nested events keep theirs" {
    const arrays = freshHeap();
    defer _ = freshHeap();
    const sm = StringManager.get();

    const outer = sm.eventBegin();
    var a = arrays.literal(&.{ Value.fromReal(1.0), Value.fromString("x") });
    const inner = sm.eventBegin();
    _ = arrays.newArray(4);
    try testing.expectEqual(@as(usize, 2), arrays.liveCount());
    sm.eventEnd(inner);
    try testing.expectEqual(@as(usize, 1), arrays.liveCount());
    try testing.expectEqualStrings("x", arrays.read(a, 1).string);
    sm.eventEnd(outer);
    try testing.expectEqual(@as(usize, 0), arrays.liveCount());
    // Released, but still readable until the safe point.
    try testing.expectEqualStrings("x", arrays.read(a, 1).string);
    sm.safePoint();
    try testing.expect(!arrays.valid(a));
    try testing.expect(arrays.read(a, 0) == .undefined); // stale ref: generation mismatch
    a = Value.UNDEFINED;
    try testing.expectEqual(@as(usize, 0), sm.store.live_bytes);
}

test "overwriting an owning slot retires the array tree after the safe point" {
    const arrays = freshHeap();
    defer _ = freshHeap();
    const sm = StringManager.get();

    var g = Value.UNDEFINED;
    arrays.set(.persistent(&g), 0, Value.fromString("outer string"));
    arrays.set(arrays.elementRef(.persistent(&g), 1), 0, Value.fromString("inner string"));
    const old = g;
    const inner = arrays.read(g, 1);
    try testing.expectEqual(@as(usize, 2), arrays.liveCount());

    sm.assignValue(&g, Value.fromReal(3.0));
    try testing.expectEqual(@as(usize, 0), arrays.liveCount());
    try testing.expectEqual(@as(usize, 0), sm.store.live_bytes);
    // Views taken earlier in the tick stay readable.
    try testing.expectEqualStrings("outer string", arrays.read(old, 0).string);
    try testing.expectEqualStrings("inner string", arrays.read(inner, 0).string);
    // Writes through a stale alias of a retired array are dropped.
    var alias = old;
    arrays.set(.local(&alias), 0, Value.fromReal(1.0));
    try testing.expectEqualStrings("outer string", arrays.read(old, 0).string);

    sm.safePoint();
    try testing.expect(!arrays.valid(old));
    // Recycled blocks and headers are reused.
    var h = Value.UNDEFINED;
    arrays.set(.persistent(&h), 0, Value.fromReal(1.0));
    try testing.expect(arrays.valid(h));
    try testing.expect(h.array_ref != old.array_ref and h.array_ref != inner.array_ref);
    try testing.expectEqual(@as(u32, 2), arrays.next_header);
}

test "self-insertion copies instead of creating a cycle (test_cyclic_arrays)" {
    const arrays = freshHeap();
    defer _ = freshHeap();
    const sm = StringManager.get();

    const m = sm.eventBegin();
    var arr = Value.UNDEFINED;
    arrays.set(.local(&arr), 0, Value.fromReal(1.0));
    arrays.set(.local(&arr), 1, Value.fromString("a"));
    arrays.set(.local(&arr), 2, arr);
    const inner = arrays.read(arr, 2);
    try testing.expect(inner.array_ref != arr.array_ref);
    try testing.expectEqual(@as(usize, 2), arrays.length(inner.array_ref));
    try testing.expectEqualStrings("[ 1,\"a\",[ 1,\"a\" ] ]", sm.fromValue(arr));

    // A temporary stored into its own descendant is copied too.
    arrays.set(arrays.elementRef(.local(&arr), 3), 0, Value.fromReal(0.0));
    arrays.set(arrays.elementRef(.local(&arr), 3), 1, arr);
    try testing.expect(arrays.read(arrays.read(arr, 3), 1).array_ref != arr.array_ref);
    sm.eventEnd(m);
    try testing.expectEqual(@as(usize, 0), arrays.liveCount());
}

test "array literals copy element strings out of scratch" {
    const arrays = freshHeap();
    defer _ = freshHeap();
    const sm = StringManager.get();

    var g = Value.UNDEFINED;
    const m = sm.eventBegin();
    sm.assignValue(&g, arrays.literal(&.{ Value.fromString(sm.fromReal(2.5)), Value.fromReal(1.0) }));
    sm.eventEnd(m);
    _ = sm.concat("overwrite", " the scratch");
    try testing.expectEqualStrings("2.50", arrays.read(g, 0).string);
    try testing.expectEqual(@as(usize, 1), arrays.liveCount());
}

test "exhaustion is soft" {
    const arrays = freshHeap();
    defer _ = freshHeap();
    const sm = StringManager.get();

    var a = Value.UNDEFINED;
    arrays.set(.persistent(&a), max_length - 1, Value.fromReal(1.0));
    try testing.expectEqual(max_length, arrays.length(a.array_ref));
    arrays.set(.persistent(&a), max_length, Value.fromReal(1.0)); // too long
    try testing.expectEqual(@as(usize, 1), sm.failures);

    var b = Value.UNDEFINED;
    arrays.set(.persistent(&b), max_length - 1, Value.fromReal(1.0));
    var c = Value.UNDEFINED;
    arrays.set(.persistent(&c), 0, Value.fromReal(1.0)); // pool full
    try testing.expectEqual(@as(usize, 2), sm.failures);
    try testing.expect(arrays.read(c, 0) == .undefined);

    // Releasing makes room again after the safe point (blocks are reused
    // within their size class).
    arrays.release(&a);
    sm.safePoint();
    arrays.set(.persistent(&c), max_length - 1, Value.fromReal(1.0));
    try testing.expectEqual(@as(f32, 1.0), arrays.read(c, max_length - 1).real);
    try testing.expectEqual(@as(usize, 2), sm.failures);
}
