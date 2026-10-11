//! The Playdate API pointer (set on kEventInit) and small helpers shared by
//! the Playdate host's backends.

const std = @import("std");
pub const api = @import("api.zig");

pub var pd: *const api.PlaydateAPI = undefined;

// Scratch buffers in RAM, not on the game task's small stack: logging and
// asset paths run inside deep game event chains (first draw of a sprite,
// first play of a sound). Everything here runs on the game task, and each
// buffer is consumed by the pd call it was formatted for.
var log_buf: [512]u8 = undefined;
var path_buf: [256]u8 = undefined;

/// Formats into a static buffer and writes one console line (truncated).
pub fn log(comptime fmt: []const u8, args: anytype) void {
    const line = std.fmt.bufPrintZ(&log_buf, fmt, args) catch blk: {
        log_buf[log_buf.len - 1] = 0;
        break :blk log_buf[0 .. log_buf.len - 1 :0];
    };
    pd.system.logToConsole("%s", line.ptr);
}

/// Zero-filled memory from the system allocator (the C host's calloc), or
/// null. Freed with `free`.
pub fn allocZeroed(comptime T: type, n: usize) ?[]T {
    const p = pd.system.realloc(null, n * @sizeOf(T)) orelse return null;
    const items: [*]T = @ptrCast(@alignCast(p));
    @memset(std.mem.sliceAsBytes(items[0..n]), 0);
    return items[0..n];
}

pub fn free(items: anytype) void {
    _ = pd.system.realloc(@ptrCast(items.ptr), 0);
}

/// NUL-terminated copy of `fmt` / `args` in `buf`, or null if it does not fit.
pub fn pathZ(buf: []u8, comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    return std.fmt.bufPrintZ(buf, fmt, args) catch null;
}

/// `pathZ` into the shared static path buffer: valid until the next call.
pub fn path(comptime fmt: []const u8, args: anytype) ?[:0]const u8 {
    return pathZ(&path_buf, fmt, args);
}
