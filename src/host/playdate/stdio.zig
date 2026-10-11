//! `runtime.file.Stdio` on the Playdate file API (port of
//! src/host/playdate/pd_stdio.c).
//!
//! Reads look in the game's data folder first and then in the .pdx
//! (FILE_READ | FILE_READ_DATA); writes always go to the data folder.
//! Reads are buffered: a pd->file->read per character is slow on the device.

const std = @import("std");
const runtime = @import("runtime");
const pd_mod = @import("pd.zig");
const api = pd_mod.api;

const FILE = runtime.file.FILE;
const EOF = runtime.file.EOF;

/// runtime.file keeps at most a few files open at once (INI, text files).
const file_max = 8;
const buf_len = 512;

const File = struct {
    sd: ?*api.SDFile = null,
    in_use: bool = false,
    writing: bool = false,
    err: bool = false,
    /// EOF when empty.
    pushback: c_int = EOF,
    pos: usize = 0,
    len: usize = 0,
    buf: [buf_len]u8 = undefined,
};

var files: [file_max]File = @splat(.{});

pub const stdio: runtime.file.Stdio = .{
    .fopen = fopen,
    .fclose = fclose,
    .fgetc = fgetc,
    .ungetc = ungetc,
    .fputs = fputs,
    .ferror = ferror,
    .remove = remove,
};

fn of(stream: *FILE) *File {
    return @ptrCast(@alignCast(stream));
}

fn fopen(path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*FILE {
    if (path[0] == 0) return null;
    const writing = mode[0] == 'w' or mode[0] == 'a';
    const opt: api.FileOptions = if (mode[0] == 'a')
        api.FILE_APPEND
    else if (writing)
        api.FILE_WRITE
    else
        api.FILE_READ | api.FILE_READ_DATA;
    const f = for (&files) |*f| {
        if (!f.in_use) break f;
    } else return null;
    const sd = pd_mod.pd.file.open(path, opt) orelse return null;
    f.* = .{ .sd = sd, .in_use = true, .writing = writing };
    return @ptrCast(f);
}

fn fclose(stream: *FILE) callconv(.c) c_int {
    const f = of(stream);
    if (!f.in_use) return EOF;
    const r = pd_mod.pd.file.close(f.sd);
    f.* = .{};
    return if (r == 0) 0 else EOF;
}

fn fgetc(stream: *FILE) callconv(.c) c_int {
    const f = of(stream);
    if (!f.in_use or f.writing) return EOF;
    if (f.pushback != EOF) {
        defer f.pushback = EOF;
        return f.pushback;
    }
    if (f.pos >= f.len) {
        const n = pd_mod.pd.file.read(f.sd, &f.buf, buf_len);
        if (n < 0) {
            f.err = true;
            return EOF;
        }
        f.pos = 0;
        f.len = @intCast(n);
        if (n == 0) return EOF;
    }
    defer f.pos += 1;
    return f.buf[f.pos];
}

fn ungetc(c: c_int, stream: *FILE) callconv(.c) c_int {
    const f = of(stream);
    if (!f.in_use or c == EOF or f.pushback != EOF) return EOF;
    f.pushback = c & 0xFF;
    return f.pushback;
}

fn ferror(stream: *FILE) callconv(.c) c_int {
    return @intFromBool(of(stream).err);
}

fn fputs(s: [*:0]const u8, stream: *FILE) callconv(.c) c_int {
    const f = of(stream);
    if (!f.in_use or !f.writing) return EOF;
    const n = std.mem.len(s);
    if (n > 0 and pd_mod.pd.file.write(f.sd, s, @intCast(n)) != @as(c_int, @intCast(n))) {
        f.err = true;
        return EOF;
    }
    return 1;
}

fn remove(path: [*:0]const u8) callconv(.c) c_int {
    return pd_mod.pd.file.unlink(path, 0);
}
