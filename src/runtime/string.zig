//! GML strings without a garbage collector.
//!
//! The C port (gm_heap.c) keeps every string in a semispace and runs a copying
//! collector at safe points. This module replaces tracing with ownership rules
//! that fall out of how GML code is structured:
//!
//! * Strings are `[]const u8` views. Operations that only select part of a
//!   string (`string_char_at`, prefix/suffix `string_delete`, results equal to
//!   the input) return subslices and copy nothing.
//! * Temporaries live in `Scratch`, a LIFO bump arena. Every GML event marks
//!   it on entry and releases the mark on exit. GML locals never outlive the
//!   event that declared them, so no temporary can be observed afterwards.
//!   `safePoint()` resets it wholesale as a backstop.
//! * Persistent slots (instance string/value variables, globals, array
//!   elements) own their bytes uniquely: `assign` copies into a size-classed
//!   block from `Store` and retires the previous block. Unique ownership needs
//!   neither reference counts nor tracing.
//! * Retired blocks are only recycled at `safePoint()` (end of tick), so a view
//!   taken from a slot stays valid for the rest of the tick even if the slot is
//!   overwritten meanwhile.
//!
//! GML has no string errors: running out of space yields "" and bumps
//! `failures`, mirroring gm_heap_failures().
//!
//! The algorithms follow GameMaker-HTML5 Function_String.js (line numbers
//! below) and packaged_src/src/runtime/gm_string.c, counting UTF-8 code points
//! as characters like the JS runner.

const std = @import("std");
const Allocator = std.mem.Allocator;
const value_mod = @import("value.zig");
const Value = value_mod.Value;
const math = @import("math.zig");

// ---------------------------------------------------------------------------
// Pure string algorithms. Allocating ones take an explicit allocator.
// ---------------------------------------------------------------------------

inline fn isCont(c: u8) bool {
    return (c & 0xC0) == 0x80;
}

/// Byte offset after `n` code points from the start of `s` (clamped to the end).
fn advance(s: []const u8, n: i64) usize {
    var i: usize = 0;
    var left = n;
    while (left > 0 and i < s.len) : (left -= 1) {
        i += 1;
        while (i < s.len and isCont(s[i])) i += 1;
    }
    return i;
}

/// Number of characters (code points) in `s`.
pub fn length(s: []const u8) usize {
    var n: usize = 0;
    for (s) |c| n += @intFromBool(!isCont(c));
    return n;
}

/// L544: 1-based; indices below 1 give the first character, past the end "".
/// Returns a view into `s`.
pub fn charAt(s: []const u8, index: i32) []const u8 {
    const i: i64 = index;
    if (s.len == 0 or @as(i64, @intCast(length(s))) <= i - 1) return "";
    const start = advance(s, if (i > 1) i - 1 else 0);
    const end = start + advance(s[start..], 1);
    return s[start..end];
}

/// L781: removes `count` characters starting at 1-based `index`. Deletions at
/// either end return views into `s`.
pub fn delete(gpa: Allocator, s: []const u8, index: i32, count: i32) Allocator.Error![]const u8 {
    if (count <= 0 or index <= 0) return s;
    const start = advance(s, @as(i64, index) - 1);
    const end = start + advance(s[start..], count);
    if (start == end) return s;
    if (end == s.len) return s[0..start];
    if (start == 0) return s[end..];
    const buf = try gpa.alloc(u8, s.len - (end - start));
    @memcpy(buf[0..start], s[0..start]);
    @memcpy(buf[start..], s[end..]);
    return buf;
}

/// L828: inserts `substr` before 1-based `index`; positions before 1 insert at
/// the front, past the end append.
pub fn insert(gpa: Allocator, substr: []const u8, s: []const u8, index: i32) Allocator.Error![]const u8 {
    if (substr.len == 0) return s;
    const i: i64 = index;
    const start = advance(s, if (i > 1) i - 1 else 0);
    const buf = try gpa.alloc(u8, s.len + substr.len);
    @memcpy(buf[0..start], s[0..start]);
    @memcpy(buf[start..][0..substr.len], substr);
    @memcpy(buf[start + substr.len ..], s[start..]);
    return buf;
}

/// L439: indexOf + 1 in characters; an empty substring is found at 1, a
/// missing one gives 0.
pub fn pos(substr: []const u8, s: []const u8) usize {
    const hit = std.mem.indexOf(u8, s, substr) orelse return 0;
    return length(s[0..hit]) + 1;
}

fn mapCase(gpa: Allocator, s: []const u8, comptime lo: u8, comptime hi: u8) Allocator.Error![]const u8 {
    const first = for (s, 0..) |c, i| {
        if (c >= lo and c <= hi) break i;
    } else return s;
    const buf = try gpa.alloc(u8, s.len);
    @memcpy(buf[0..first], s[0..first]);
    for (s[first..], buf[first..]) |c, *out| {
        out.* = if (c >= lo and c <= hi) c ^ 0x20 else c;
    }
    return buf;
}

/// ASCII-only, like gm_string_lower. Unchanged input is returned as is.
pub fn lower(gpa: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return mapCase(gpa, s, 'A', 'Z');
}

/// ASCII-only, like gm_string_upper. Unchanged input is returned as is.
pub fn upper(gpa: Allocator, s: []const u8) Allocator.Error![]const u8 {
    return mapCase(gpa, s, 'a', 'z');
}

/// L956: each `#` becomes "\r\n"; an escaped `\#` becomes `#`.
pub fn hashToNewline(gpa: Allocator, s: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '#') == null) return s;
    var size = s.len;
    for (s, 0..) |c, i| {
        if (c != '#') continue;
        if (i > 0 and s[i - 1] == '\\') size -= 1 else size += 1;
    }
    const buf = try gpa.alloc(u8, size);
    var n: usize = 0;
    for (s, 0..) |c, i| {
        if (c == '#' and (i == 0 or s[i - 1] != '\\')) {
            buf[n] = '\r';
            buf[n + 1] = '\n';
            n += 2;
        } else if (c == '#') {
            buf[n - 1] = '#'; // "\#": the backslash becomes the hash
        } else {
            buf[n] = c;
            n += 1;
        }
    }
    std.debug.assert(n == size);
    return buf;
}

/// L76: the first code point. Malformed UTF-8 (only possible with raw file
/// bytes; JS strings are always well formed) yields the first byte's value.
pub fn ord(s: []const u8) f32 {
    if (s.len == 0) return 0.0;
    const b0 = s[0];
    if (b0 < 0x80) return @floatFromInt(b0);
    var cp: u32 = undefined;
    var extra: usize = undefined;
    if ((b0 & 0xE0) == 0xC0) {
        cp = b0 & 0x1F;
        extra = 1;
    } else if ((b0 & 0xF0) == 0xE0) {
        cp = b0 & 0x0F;
        extra = 2;
    } else if ((b0 & 0xF8) == 0xF0) {
        cp = b0 & 0x07;
        extra = 3;
    } else {
        return @floatFromInt(b0);
    }
    if (s.len <= extra) return @floatFromInt(b0);
    for (s[1 .. 1 + extra]) |c| {
        if (!isCont(c)) return @floatFromInt(b0);
        cp = (cp << 6) | (c & 0x3F);
    }
    return @floatFromInt(cp);
}

/// String.fromCharCode(code): the UTF-8 encoding of the UTF-16 unit `code`
/// (ToUint16), written into `buf`. Lone surrogates encode as 3-byte WTF-8.
pub fn chr(buf: *[3]u8, code: f32) []const u8 {
    const u: u16 = @truncate(@as(u32, @bitCast(math.toInt32(code))));
    if (u < 0x80) {
        buf[0] = @intCast(u);
        return buf[0..1];
    }
    if (u < 0x800) {
        buf[0] = @intCast(0xC0 | (u >> 6));
        buf[1] = @intCast(0x80 | (u & 0x3F));
        return buf[0..2];
    }
    buf[0] = @intCast(0xE0 | (u >> 12));
    buf[1] = @intCast(0x80 | ((u >> 6) & 0x3F));
    buf[2] = @intCast(0x80 | (u & 0x3F));
    return buf[0..3];
}

/// `a ++ b`. Returns an operand untouched when the other is empty.
pub fn concat(gpa: Allocator, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
    if (b.len == 0) return a;
    if (a.len == 0) return b;
    const buf = try gpa.alloc(u8, a.len + b.len);
    @memcpy(buf[0..a.len], a);
    @memcpy(buf[a.len..], b);
    return buf;
}

/// Large enough for every `formatReal` result.
pub const real_buf_len = 64;

/// GML string(real) (yyGetString -> number formatting), matching
/// gm_real_format: integers in int32 range print without decimals, other
/// values print toFixed(2) with exact ties rounded away from zero.
pub fn formatReal(buf: *[real_buf_len]u8, x: f32) []const u8 {
    if (std.math.isNan(x)) return "NaN";
    if (std.math.isInf(x)) return if (x < 0.0) "-inf" else "inf";
    const as_int = math.toInt32(x);
    if (@as(f32, @floatFromInt(as_int)) == x) {
        // (~~v) == v: integer in int32 range; -0 prints as "0".
        return std.fmt.bufPrint(buf, "{d}", .{as_int}) catch unreachable;
    }
    const ax = @abs(x);
    // From 2^24 on every f32 is an integer. printf prints the exact binary
    // value, while std.fmt prints the shortest round-trip digits, so format
    // the exact integer instead (f32 max < 2^128).
    if (ax >= 0x1p24) {
        const n: u128 = @intFromFloat(ax);
        const sign: []const u8 = if (x < 0.0) "-" else "";
        if (ax >= 1e21) return formatGeneral17(buf, sign, n);
        return std.fmt.bufPrint(buf, "{s}{d}.00", .{ sign, n }) catch unreachable;
    }
    // ax == k/8 exactly (ax * 8 is exact in float); ax * 100 == 12.5k is a
    // tie iff k is odd, rounded away to (25k + 1) / 2 hundredths.
    const k: i64 = if (ax < 1e15 and @mod(ax * 8.0, 1.0) == 0.0) @intFromFloat(ax * 8.0) else 0;
    if (k & 1 == 1) {
        const n: i64 = @divTrunc(25 * k + 1, 2);
        const sign: []const u8 = if (x < 0.0) "-" else "";
        const whole: u64 = @intCast(@divTrunc(n, 100));
        const cents: u64 = @intCast(@rem(n, 100));
        return std.fmt.bufPrint(buf, "{s}{d}.{d:0>2}", .{ sign, whole, cents }) catch unreachable;
    }
    return std.fmt.bufPrint(buf, "{d:.2}", .{@as(f64, x)}) catch unreachable;
}

/// printf("%.17g") of the integer `n` >= 1e21: the exact decimal expansion
/// rounded to 17 significant digits (ties to even, like glibc), trailing
/// zeros trimmed, exponent with explicit sign.
fn formatGeneral17(buf: *[real_buf_len]u8, sign: []const u8, n: u128) []const u8 {
    const sig = 17;
    var digits_buf: [40]u8 = undefined;
    const digits = std.fmt.bufPrint(&digits_buf, "{d}", .{n}) catch unreachable;
    std.debug.assert(digits.len > sig);
    var exp = digits.len - 1;

    var mant: [sig]u8 = digits[0..sig].*;
    const rest = digits[sig..];
    const tail_zero = for (rest[1..]) |c| {
        if (c != '0') break false;
    } else true;
    const round_up = rest[0] > '5' or (rest[0] == '5' and (!tail_zero or (mant[sig - 1] - '0') % 2 == 1));
    if (round_up) {
        var i: usize = sig;
        while (i > 0) {
            i -= 1;
            if (mant[i] != '9') {
                mant[i] += 1;
                break;
            }
            mant[i] = '0';
        } else {
            // 99..9 carried into a new leading digit.
            mant[0] = '1';
            exp += 1;
        }
    }
    const frac = std.mem.trimEnd(u8, mant[1..], "0");
    const dot: []const u8 = if (frac.len > 0) "." else "";
    return std.fmt.bufPrint(buf, "{s}{c}{s}{s}e+{d:0>2}", .{ sign, mant[0], dot, frac, exp }) catch unreachable;
}

inline fn isSpace(c: u8) bool {
    return c == ' ' or (c >= '\t' and c <= '\r');
}

fn countDigits(s: []const u8) usize {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return n;
}

/// real(string): parseInt for "0x" prefixes, otherwise parseFloat of the
/// longest StrDecimalLiteral prefix after leading whitespace
/// (gm_string_parse_real). Returns null when nothing parses (NaN in JS).
pub fn parseReal(s: []const u8) ?f32 {
    if (std.mem.startsWith(u8, s, "0x")) {
        var r: f32 = 0.0;
        var digits: usize = 0;
        for (s[2..]) |c| {
            const h = std.fmt.charToDigit(c, 16) catch break;
            r = r * 16.0 + @as(f32, @floatFromInt(h));
            digits += 1;
        }
        return if (digits == 0) null else r;
    }
    var start: usize = 0;
    while (start < s.len and isSpace(s[start])) start += 1;
    var p = start;
    var neg = false;
    if (p < s.len and (s[p] == '+' or s[p] == '-')) {
        neg = s[p] == '-';
        p += 1;
    }
    if (std.mem.startsWith(u8, s[p..], "Infinity")) {
        return if (neg) -std.math.inf(f32) else std.math.inf(f32);
    }
    const d1 = countDigits(s[p..]);
    p += d1;
    var d2: usize = 0;
    if (p < s.len and s[p] == '.') {
        d2 = countDigits(s[p + 1 ..]);
        if (d1 + d2 > 0) p += 1 + d2;
    }
    if (d1 + d2 == 0) return null;
    if (p < s.len and (s[p] == 'e' or s[p] == 'E')) {
        var q = p + 1;
        if (q < s.len and (s[q] == '+' or s[q] == '-')) q += 1;
        const de = countDigits(s[q..]);
        if (de > 0) p = q + de;
    }
    return std.fmt.parseFloat(f32, s[start..p]) catch null;
}

// ---------------------------------------------------------------------------
// Scratch: per-event LIFO arena for temporaries.
// ---------------------------------------------------------------------------

pub const Scratch = struct {
    fba: std.heap.FixedBufferAllocator,

    pub const Mark = enum(usize) { _ };

    pub fn init(buffer: []u8) Scratch {
        return .{ .fba = .init(buffer) };
    }

    pub fn allocator(self: *Scratch) Allocator {
        return self.fba.allocator();
    }

    pub fn mark(self: *const Scratch) Mark {
        return @enumFromInt(self.fba.end_index);
    }

    /// Frees everything allocated since `m`. Marks must be released in LIFO order.
    pub fn release(self: *Scratch, m: Mark) void {
        const idx = @intFromEnum(m);
        std.debug.assert(idx <= self.fba.end_index);
        self.fba.end_index = idx;
    }

    pub fn reset(self: *Scratch) void {
        self.fba.reset();
    }

    pub fn used(self: *const Scratch) usize {
        return self.fba.end_index;
    }

    pub fn owns(self: *const Scratch, s: []const u8) bool {
        const base = @intFromPtr(self.fba.buffer.ptr);
        const p = @intFromPtr(s.ptr);
        return s.len > 0 and p >= base and p < base + self.fba.end_index;
    }

    /// `a ++ b`, appending in place when `a` is the newest allocation so that
    /// `s = s + x` loops stay linear in time and space.
    pub fn concat(self: *Scratch, a: []const u8, b: []const u8) Allocator.Error![]const u8 {
        if (b.len == 0) return a;
        if (a.len > 0 and self.owns(a) and self.fba.isLastAllocation(@constCast(a))) {
            const end = self.fba.end_index;
            if (end + b.len > self.fba.buffer.len) return error.OutOfMemory;
            @memcpy(self.fba.buffer[end..][0..b.len], b);
            self.fba.end_index = end + b.len;
            return self.fba.buffer[end - a.len .. end + b.len];
        }
        return string_concat(self.allocator(), a, b);
    }
};

const string_concat = concat;

// ---------------------------------------------------------------------------
// Store: uniquely owned, size-classed blocks for persistent slots.
// ---------------------------------------------------------------------------

pub const Store = struct {
    pub const classes = [_]usize{ 16, 32, 64, 128, 256, 512, 1024, 4096 };
    pub const max_len = classes[classes.len - 1];
    pub const block_align = 16;

    /// Blocks retired within one tick before they are recycled.
    pub const max_retired = 8192;

    const Node = struct { next: ?*Node };

    comptime {
        std.debug.assert(@sizeOf(Node) <= classes[0]);
        std.debug.assert(classes.len <= block_align);
        for (classes) |c| std.debug.assert(c % block_align == 0);
    }

    buffer: []align(block_align) u8,
    bump: usize = 0,
    free: [classes.len]?*Node = @splat(null),
    /// Retired blocks as `offset | class`: offsets are multiples of
    /// `block_align`, leaving the low bits for the class. Kept out of line so
    /// a retired block's bytes stay readable until `recycle`.
    retired: [max_retired]u32 = undefined,
    retired_len: usize = 0,
    /// Blocks lost because the retired queue was full (reclaimed by `reset`).
    leaked: usize = 0,
    live_bytes: usize = 0,

    pub fn init(buffer: []align(block_align) u8) Store {
        std.debug.assert(buffer.len <= std.math.maxInt(u32));
        return .{ .buffer = buffer };
    }

    pub fn reset(self: *Store) void {
        self.* = .init(self.buffer);
    }

    fn classIndex(len: usize) ?usize {
        for (classes, 0..) |c, i| {
            if (len <= c) return i;
        }
        return null;
    }

    pub fn owns(self: *const Store, s: []const u8) bool {
        const base = @intFromPtr(self.buffer.ptr);
        const p = @intFromPtr(s.ptr);
        return s.len > 0 and p >= base and p < base + self.bump;
    }

    /// Copies `s` into a block owned by the caller. "" never allocates.
    pub fn dupe(self: *Store, s: []const u8) Allocator.Error![]const u8 {
        if (s.len == 0) return "";
        const ci = classIndex(s.len) orelse return error.OutOfMemory;
        const block: [*]u8 = if (self.free[ci]) |node| blk: {
            self.free[ci] = node.next;
            break :blk @ptrCast(node);
        } else blk: {
            const size = classes[ci];
            if (self.bump + size > self.buffer.len) return error.OutOfMemory;
            const b = self.buffer[self.bump..].ptr;
            self.bump += size;
            break :blk b;
        };
        @memcpy(block[0..s.len], s);
        self.live_bytes += classes[ci];
        return block[0..s.len];
    }

    /// Gives back a block returned by `dupe`; it becomes reusable at the next
    /// `recycle`. Views that this store does not own are ignored.
    pub fn retire(self: *Store, s: []const u8) void {
        if (!self.owns(s)) return;
        const ci = classIndex(s.len).?;
        self.live_bytes -= classes[ci];
        if (self.retired_len == max_retired) {
            self.leaked += 1;
            return;
        }
        const offset = @intFromPtr(s.ptr) - @intFromPtr(self.buffer.ptr);
        std.debug.assert(offset % block_align == 0);
        self.retired[self.retired_len] = @intCast(offset | ci);
        self.retired_len += 1;
    }

    /// Makes retired blocks available again. Only call when no view of a
    /// retired block can still be in use (the tick safe point).
    pub fn recycle(self: *Store) void {
        for (self.retired[0..self.retired_len]) |packed_block| {
            const ci = packed_block % block_align;
            const offset = packed_block - ci;
            const node: *Node = @ptrCast(@alignCast(self.buffer[offset..].ptr));
            node.next = self.free[ci];
            self.free[ci] = node;
        }
        self.retired_len = 0;
    }
};

// ---------------------------------------------------------------------------
// StringManager: the runtime's scratch + store, with GML (fail-soft) entry points.
// It also brackets array lifetimes (value.ArrayManager): event marks release
// temporary arrays, the safe point recycles retired ones, and value slots
// own their arrays.
// ---------------------------------------------------------------------------

pub const scratch_bytes: usize = 1024 * 1024;
pub const store_bytes: usize = 1024 * 1024;

pub const StringManager = struct {
    scratch: Scratch,
    store: Store,
    /// Operations that ran out of space and produced "" instead.
    failures: usize = 0,

    var scratch_buffer: [scratch_bytes]u8 = undefined;
    var store_buffer: [store_bytes]u8 align(Store.block_align) = undefined;
    var instance: StringManager = .{
        .scratch = .{ .fba = .{ .buffer = &scratch_buffer, .end_index = 0 } },
        .store = .{ .buffer = &store_buffer },
    };

    pub fn get() *StringManager {
        return &instance;
    }

    /// Forgets every string and array (game restart, test isolation). Slots
    /// still holding owned views must be cleared by their owners.
    pub fn reset(self: *StringManager) void {
        self.scratch.reset();
        self.store.reset();
        value_mod.ArrayManager.get().reset();
        self.failures = 0;
    }

    /// End-of-tick safe point: no GML code is on the stack. Leftover
    /// temporary arrays are released before retired strings are recycled.
    pub fn safePoint(self: *StringManager) void {
        value_mod.ArrayManager.get().safePoint();
        self.scratch.reset();
        self.store.recycle();
    }

    pub const EventMark = struct {
        scratch: Scratch.Mark,
        arrays: usize,
    };

    /// Called on entry of every GML event; pass the result to `eventEnd`.
    pub fn eventBegin(self: *StringManager) EventMark {
        return .{ .scratch = self.scratch.mark(), .arrays = value_mod.ArrayManager.get().tempMark() };
    }

    /// Releases the event's string temporaries and its unadopted arrays.
    pub fn eventEnd(self: *StringManager, m: EventMark) void {
        value_mod.ArrayManager.get().endTemps(m.arrays);
        self.scratch.release(m.scratch);
    }

    /// Records a failed operation; returns the fail-soft result "".
    pub fn fail(self: *StringManager) []const u8 {
        self.failures += 1;
        return "";
    }

    fn tmp(self: *StringManager) Allocator {
        return self.scratch.allocator();
    }

    // ---- temporaries (valid until the current event returns) ----

    /// Copies a transient runtime buffer (file reads, formatting) into scratch.
    pub fn temp(self: *StringManager, s: []const u8) []const u8 {
        if (s.len == 0) return "";
        return self.tmp().dupe(u8, s) catch self.fail();
    }

    pub fn concat(self: *StringManager, a: []const u8, b: []const u8) []const u8 {
        return self.scratch.concat(a, b) catch self.fail();
    }

    pub fn charAt(_: *StringManager, s: []const u8, index: f32) []const u8 {
        return string_char_at(s, math.toInt32(index));
    }

    pub fn delete(self: *StringManager, s: []const u8, index: f32, count: f32) []const u8 {
        return string_delete(self.tmp(), s, math.toInt32(index), math.toInt32(count)) catch self.fail();
    }

    pub fn insert(self: *StringManager, substr: []const u8, s: []const u8, index: f32) []const u8 {
        return string_insert(self.tmp(), substr, s, math.toInt32(index)) catch self.fail();
    }

    pub fn lower(self: *StringManager, s: []const u8) []const u8 {
        return string_lower(self.tmp(), s) catch self.fail();
    }

    pub fn upper(self: *StringManager, s: []const u8) []const u8 {
        return string_upper(self.tmp(), s) catch self.fail();
    }

    pub fn hashToNewline(self: *StringManager, s: []const u8) []const u8 {
        return string_hash_to_newline(self.tmp(), s) catch self.fail();
    }

    pub fn chr(self: *StringManager, code: f32) []const u8 {
        var buf: [3]u8 = undefined;
        return self.temp(string_chr(&buf, code));
    }

    pub fn fromReal(self: *StringManager, x: f32) []const u8 {
        var buf: [real_buf_len]u8 = undefined;
        return self.temp(formatReal(&buf, x));
    }

    /// GML string(value).
    pub fn fromValue(self: *StringManager, v: Value) []const u8 {
        return switch (v) {
            .string => |s| s,
            .real => |r| self.fromReal(r),
            .undefined => "undefined",
            .array_ref => blk: {
                const m = self.scratch.mark();
                var out: []const u8 = "";
                var visited: [visit_max]i32 = undefined;
                if (!self.formatArray(&out, v.array_ref, &visited, 0)) {
                    self.scratch.release(m);
                    break :blk self.fail();
                }
                break :blk out;
            },
        };
    }

    const visit_max = 16;
    const recursive_warning = "\"Warning: Recursive array found\"";

    fn formatArray(self: *StringManager, out: *[]const u8, ref: i32, visited: *[visit_max]i32, depth: usize) bool {
        for (visited[0..depth]) |seen| {
            if (seen == ref) return self.append(out, recursive_warning);
        }
        if (depth >= visit_max) return self.append(out, recursive_warning);
        visited[depth] = ref;
        if (!self.append(out, "[ ")) return false;
        const arrays = value_mod.ArrayManager.get();
        for (0..arrays.length(ref)) |i| {
            if (i != 0 and !self.append(out, ",")) return false;
            const ok = switch (arrays.getElement(ref, i)) {
                .string => |s| self.append(out, "\"") and self.append(out, s) and self.append(out, "\""),
                .real => |r| blk: {
                    var buf: [real_buf_len]u8 = undefined;
                    break :blk self.append(out, formatReal(&buf, r));
                },
                .undefined => self.append(out, "undefined"),
                .array_ref => |inner| self.formatArray(out, inner, visited, depth + 1),
            };
            if (!ok) return false;
        }
        return self.append(out, " ]");
    }

    fn append(self: *StringManager, out: *[]const u8, s: []const u8) bool {
        // Always copy so the result is a single scratch allocation.
        out.* = if (out.len == 0) (self.tmp().dupe(u8, s) catch return false) else (self.scratch.concat(out.*, s) catch return false);
        return true;
    }

    // ---- persistent slots ----

    /// `slot = s` for a slot that outlives the current event.
    pub fn assign(self: *StringManager, slot: *[]const u8, s: []const u8) void {
        if (s.ptr == slot.ptr and s.len == slot.len) return;
        const owned = self.store.dupe(s) catch self.fail();
        self.store.retire(slot.*);
        slot.* = owned;
    }

    /// `slot = literal`: string literals are static, so they are borrowed.
    pub fn assignStatic(self: *StringManager, slot: *[]const u8, comptime s: []const u8) void {
        self.store.retire(slot.*);
        slot.* = s;
    }

    /// `slot = v` for a value slot that outlives the current event (instance
    /// or global variable). Strings are copied into the store; arrays are
    /// adopted (temporaries) or deep-copied (already owned elsewhere).
    pub fn assignValue(_: *StringManager, slot: *Value, v: Value) void {
        value_mod.ArrayManager.get().store(.persistent(slot), v);
    }

    pub fn release(self: *StringManager, slot: *[]const u8) void {
        self.store.retire(slot.*);
        slot.* = "";
    }

    /// Clears a value slot that owns its string or array.
    pub fn releaseValue(_: *StringManager, slot: *Value) void {
        value_mod.ArrayManager.get().release(slot);
    }
};

const string_char_at = charAt;
const string_delete = delete;
const string_insert = insert;
const string_lower = lower;
const string_upper = upper;
const string_hash_to_newline = hashToNewline;
const string_chr = chr;

// ---------------------------------------------------------------------------
// Tests (mirror tests/test_string.c, plus the ownership model).
// ---------------------------------------------------------------------------

const testing = std.testing;

test "length and charAt count code points" {
    try testing.expectEqual(@as(usize, 0), length(""));
    try testing.expectEqual(@as(usize, 5), length("hello"));
    try testing.expectEqual(@as(usize, 4), length("caf\xc3\xa9"));
    try testing.expectEqualStrings("h", charAt("hello", 1));
    try testing.expectEqualStrings("o", charAt("hello", 5));
    try testing.expectEqualStrings("", charAt("hello", 6));
    try testing.expectEqualStrings("h", charAt("hello", 0));
    try testing.expectEqualStrings("h", charAt("hello", std.math.minInt(i32)));
    try testing.expectEqualStrings("", charAt("", 1));
    try testing.expectEqualStrings("\xc3\xa9", charAt("caf\xc3\xa9", 4));
}

test "delete, insert and pos" {
    const gpa = testing.allocator;
    try testing.expectEqualStrings("he", try delete(gpa, "hello", 3, 99));
    try testing.expectEqualStrings("hello", try delete(gpa, "hello", 0, 2));
    try testing.expectEqualStrings("hello", try delete(gpa, "hello", 2, 0));
    try testing.expectEqualStrings("caf", try delete(gpa, "caf\xc3\xa9", 4, 1));
    try testing.expectEqualStrings("llo", try delete(gpa, "hello", 1, 2));

    const mid = try delete(gpa, "hello", 2, 2);
    defer gpa.free(mid);
    try testing.expectEqualStrings("hlo", mid);

    const ins = try insert(gpa, "XY", "hello", 3);
    defer gpa.free(ins);
    try testing.expectEqualStrings("heXYllo", ins);
    const front = try insert(gpa, "XY", "hello", -5);
    defer gpa.free(front);
    try testing.expectEqualStrings("XYhello", front);
    const back = try insert(gpa, "XY", "hello", 99);
    defer gpa.free(back);
    try testing.expectEqualStrings("helloXY", back);

    try testing.expectEqual(@as(usize, 3), pos("ll", "hello"));
    try testing.expectEqual(@as(usize, 0), pos("z", "hello"));
    try testing.expectEqual(@as(usize, 1), pos("", "hello"));
    try testing.expectEqual(@as(usize, 5), pos("!", "caf\xc3\xa9!"));
}

test "views avoid copies" {
    const s: []const u8 = "hello";
    const c = charAt(s, 2);
    try testing.expect(c.ptr == s.ptr + 1);
    const tail = try delete(testing.failing_allocator, s, 1, 2);
    try testing.expect(tail.ptr == s.ptr + 2);
    const head = try delete(testing.failing_allocator, s, 4, 9);
    try testing.expect(head.ptr == s.ptr);
    try testing.expect((try lower(testing.failing_allocator, s)).ptr == s.ptr);
    try testing.expect((try hashToNewline(testing.failing_allocator, s)).ptr == s.ptr);
}

test "room template splice (scrRoomGen)" {
    var buf: [256]u8 = undefined;
    var scratch = Scratch.init(&buf);
    const gpa = scratch.allocator();
    var t = try delete(gpa, "11111000001111111111", 6, 5);
    t = try insert(gpa, "22222", t, 6);
    try testing.expectEqualStrings("11111222221111111111", t);
    try testing.expectEqualStrings("2", charAt(t, 8));
}

test "case mapping, hash_to_newline, ord and chr" {
    const gpa = testing.allocator;
    const lo = try lower(gpa, "AbC-1");
    defer gpa.free(lo);
    try testing.expectEqualStrings("abc-1", lo);
    const up = try upper(gpa, "aBc-1");
    defer gpa.free(up);
    try testing.expectEqualStrings("ABC-1", up);

    const cases = [_][2][]const u8{
        .{ "a#b", "a\r\nb" },
        .{ "a\\#b", "a#b" },
        .{ "##", "\r\n\r\n" },
    };
    for (cases) |case| {
        const out = try hashToNewline(gpa, case[0]);
        defer gpa.free(out);
        try testing.expectEqualStrings(case[1], out);
    }

    try testing.expectEqual(@as(f32, 89.0), ord("Y"));
    try testing.expectEqual(@as(f32, 0.0), ord(""));
    try testing.expectEqual(@as(f32, 233.0), ord("\xc3\xa9"));
    try testing.expectEqual(@as(f32, 8364.0), ord("\xe2\x82\xac"));
    try testing.expectEqual(@as(f32, 255.0), ord("\xff"));
    try testing.expectEqual(@as(f32, 226.0), ord("\xe2\x82"));

    var cbuf: [3]u8 = undefined;
    try testing.expectEqualStrings("A", chr(&cbuf, 65.0));
    try testing.expectEqualStrings("\xc3\xa9", chr(&cbuf, 233.0));
    try testing.expectEqualStrings("\xe2\x82\xac", chr(&cbuf, 8364.0));
}

test "formatReal matches gm_real_format" {
    var buf: [real_buf_len]u8 = undefined;
    const cases = [_]struct { f32, []const u8 }{
        .{ 0.0, "0" },
        .{ -0.0, "0" },
        .{ 42.0, "42" },
        .{ -7.0, "-7" },
        .{ 0.1, "0.10" },
        .{ 3.14159, "3.14" },
        .{ 2.675, "2.67" }, // binary value is below the tie
        .{ -1.5, "-1.50" },
        .{ 0.375, "0.38" }, // exact tie: away from zero
        .{ -0.125, "-0.13" },
        .{ 1.0e10, "10000000000.00" },
        .{ 1.0e21, "1.0000000200408773e+21" },
        .{ std.math.nan(f32), "NaN" },
        .{ -std.math.inf(f32), "-inf" },
        // tests/test_value.c test_real_format
        .{ 3.0, "3" },
        .{ 1.0 / 3.0, "0.33" },
        .{ 0.125, "0.13" },
        .{ 2.375, "2.38" },
        .{ 1.005, "1.00" },
        .{ 0.005, "0.00" },
        .{ 2147483647.0, "2147483648.00" },
        .{ 3e9, "3000000000.00" },
        .{ std.math.inf(f32), "inf" },
        // printf prints the exact binary value, not the shortest round trip
        // (found by fuzzing against gm_real_format).
        .{ @bitCast(@as(u32, 0xdf01c6e6)), "-9351414563955802112.00" },
        .{ @bitCast(@as(u32, 0x5a84009f)), "18577689912803328.00" },
        .{ @bitCast(@as(u32, 0x6dc588d3)), "7.6417446582000567e+27" },
        .{ @bitCast(@as(u32, 0xf9563be1)), "-6.9522876014352142e+34" },
        .{ std.math.floatMax(f32), "3.4028234663852886e+38" },
    };
    for (cases) |case| {
        try testing.expectEqualStrings(case[1], formatReal(&buf, case[0]));
    }
}

test "parseReal follows parseFloat / parseInt" {
    try testing.expectEqual(@as(?f32, 12.5), parseReal("  12.5abc"));
    try testing.expectEqual(@as(?f32, -3.0), parseReal("-3"));
    try testing.expectEqual(@as(?f32, 255.0), parseReal("0xff"));
    try testing.expectEqual(@as(?f32, 0.5), parseReal(".5"));
    try testing.expectEqual(@as(?f32, 100.0), parseReal("1e2x"));
    try testing.expectEqual(@as(?f32, 1.0), parseReal("1e"));
    try testing.expectEqual(@as(?f32, null), parseReal("abc"));
    try testing.expectEqual(@as(?f32, null), parseReal("."));
    try testing.expectEqual(@as(?f32, null), parseReal("0x"));
    try testing.expectEqual(std.math.inf(f32), parseReal("Infinity").?);
    // tests/test_value.c test_parse_real
    try testing.expectEqual(@as(?f32, 12.5), parseReal("12.5px"));
    try testing.expectEqual(@as(?f32, 26.0), parseReal("0x1A"));
    try testing.expectEqual(@as(?f32, -3.0), parseReal("  -3"));
    try testing.expectEqual(@as(?f32, 0.0), parseReal(" 0x10")); // parseFloat stops at x
    try testing.expectEqual(@as(?f32, 5.0), parseReal("5."));
    try testing.expectEqual(@as(?f32, 0.5), parseReal(".5e0"));
    try testing.expectEqual(@as(?f32, null), parseReal("inf"));
}

test "scratch marks free event temporaries and concat grows in place" {
    var buf: [64]u8 = undefined;
    var scratch = Scratch.init(&buf);

    var s: []const u8 = "";
    for (0..10) |_| s = try scratch.concat(s, "ab");
    try testing.expectEqualStrings("abababababababababab", s);
    try testing.expectEqual(@as(usize, 20), scratch.used());

    const m = scratch.mark();
    _ = try scratch.allocator().dupe(u8, "temporary");
    try testing.expect(scratch.used() > 20);
    scratch.release(m);
    try testing.expectEqual(@as(usize, 20), scratch.used());

    try testing.expectError(error.OutOfMemory, scratch.concat(s, "x" ** 64));
}

test "store blocks are uniquely owned and recycled only after the safe point" {
    var buf: [256]u8 align(Store.block_align) = undefined;
    var store = Store.init(&buf);

    const a = try store.dupe("first");
    try testing.expect(store.owns(a));
    try testing.expectEqual(@as(usize, 16), store.live_bytes);

    store.retire(a);
    try testing.expectEqual(@as(usize, 0), store.live_bytes);
    // Retired, not yet recycled: a new block must not alias the old view.
    const b = try store.dupe("second");
    try testing.expect(b.ptr != a.ptr);
    try testing.expectEqualStrings("first", a);

    store.recycle();
    const c = try store.dupe("third");
    try testing.expect(c.ptr == a.ptr);

    store.retire("literal"); // not owned: ignored
    try testing.expectError(error.OutOfMemory, store.dupe("x" ** (Store.max_len + 1)));
}

test "StringManager slots copy temporaries and survive event release" {
    const sm = StringManager.get();
    sm.reset();
    defer sm.reset();

    var slot: []const u8 = "";
    var val: Value = Value.UNDEFINED;

    const m = sm.eventBegin();
    const t = sm.concat(sm.fromReal(12.0), " gold");
    sm.assign(&slot, t);
    sm.assignValue(&val, Value.fromString(sm.insert("X", "ab", 2)));
    sm.eventEnd(m);

    try testing.expectEqual(@as(usize, 0), sm.scratch.used());
    try testing.expectEqualStrings("12 gold", slot);
    try testing.expectEqualStrings("aXb", val.string);

    const view = slot;
    sm.assignStatic(&slot, "literal");
    try testing.expectEqualStrings("12 gold", view); // retired, still readable this tick
    sm.release(&slot);
    sm.releaseValue(&val);
    sm.safePoint();
    try testing.expectEqual(@as(usize, 0), sm.store.live_bytes);
    try testing.expectEqual(@as(usize, 0), sm.failures);
}

test "string(value) formats arrays like the runner" {
    const sm = StringManager.get();
    sm.reset();
    defer sm.reset();

    var arr: Value = Value.UNDEFINED;
    value_mod.aset(.local(&arr), 0, Value.fromReal(1.0));
    value_mod.aset(.local(&arr), 1, Value.fromString("a"));
    value_mod.aset(.local(&arr), 3, Value.fromReal(0.5));
    try testing.expectEqualStrings("[ 1,\"a\",undefined,0.50 ]", sm.fromValue(arr));
    try testing.expectEqualStrings("undefined", sm.fromValue(Value.UNDEFINED));
    try testing.expectEqualStrings("7", sm.fromValue(Value.fromReal(7.0)));
}

test "%.17g rounding carries into the exponent" {
    var buf: [real_buf_len]u8 = undefined;
    // Seventeen 9s followed by a tie: rounds up and carries into a new digit.
    try testing.expectEqualStrings("1e+22", formatGeneral17(&buf, "", 9999999999999999950000));
    // Exact ties round half to even.
    try testing.expectEqualStrings("-1.2345678901234568e+21", formatGeneral17(&buf, "-", 1234567890123456750000));
    try testing.expectEqualStrings("1.2345678901234568e+21", formatGeneral17(&buf, "", 1234567890123456850000));
}
