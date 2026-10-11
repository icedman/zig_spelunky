//! GameMaker file system subset for text file reading/writing (templates, stats, settings).
//! Follows reference/GameMaker-HTML5/scripts/functions/Function_File.js and packaged_src/src/runtime/gm_file.c.
//! Uses C stdio primitives for exact cross-platform behavior and 1-char lookahead via ungetc.
//! The primitives go through `stdio`: libc's when linked, else none until
//! the host installs its own (the Playdate host routes them to pd->file).

const std = @import("std");
const builtin = @import("builtin");
const string = @import("string.zig");

pub const MAX_HANDLES: usize = 32;
pub const STRING_RING_COUNT: usize = 8;
pub const STRING_MAX_LEN: usize = 4096;

/// A stream of the installed `Stdio` (libc's FILE, or the host's own).
pub const FILE = opaque {};

pub const EOF: c_int = -1;

/// The slice of C stdio this module uses, with C semantics (EOF, 0 on
/// success). Modes are "rb" and "wb".
pub const Stdio = struct {
    fopen: *const fn (path: [*:0]const u8, mode: [*:0]const u8) callconv(.c) ?*FILE,
    fclose: *const fn (stream: *FILE) callconv(.c) c_int,
    fgetc: *const fn (stream: *FILE) callconv(.c) c_int,
    ungetc: *const fn (c: c_int, stream: *FILE) callconv(.c) c_int,
    fputs: *const fn (s: [*:0]const u8, stream: *FILE) callconv(.c) c_int,
    ferror: *const fn (stream: *FILE) callconv(.c) c_int,
    remove: *const fn (path: [*:0]const u8) callconv(.c) c_int,

    const libc = struct {
        extern "c" fn fopen(filename: [*:0]const u8, modes: [*:0]const u8) ?*FILE;
        extern "c" fn fclose(stream: *FILE) c_int;
        extern "c" fn fgetc(stream: *FILE) c_int;
        extern "c" fn ungetc(c: c_int, stream: *FILE) c_int;
        extern "c" fn fputs(s: [*:0]const u8, stream: *FILE) c_int;
        extern "c" fn ferror(stream: *FILE) c_int;
        extern "c" fn remove(filename: [*:0]const u8) c_int;
        extern "c" fn snprintf(buf: [*]u8, n: usize, fmt: [*:0]const u8, ...) c_int;
    };

    /// Without a C library and before the host installs one: no files.
    const none = struct {
        fn fopen(_: [*:0]const u8, _: [*:0]const u8) callconv(.c) ?*FILE {
            return null;
        }
        fn fail(_: *FILE) callconv(.c) c_int {
            return EOF;
        }
        fn ungetc(_: c_int, _: *FILE) callconv(.c) c_int {
            return EOF;
        }
        fn fputs(_: [*:0]const u8, _: *FILE) callconv(.c) c_int {
            return EOF;
        }
        fn remove(_: [*:0]const u8) callconv(.c) c_int {
            return -1;
        }
    };

    pub const default: Stdio = if (builtin.link_libc) .{
        .fopen = libc.fopen,
        .fclose = libc.fclose,
        .fgetc = libc.fgetc,
        .ungetc = libc.ungetc,
        .fputs = libc.fputs,
        .ferror = libc.ferror,
        .remove = libc.remove,
    } else .{
        .fopen = none.fopen,
        .fclose = none.fail,
        .fgetc = none.fail,
        .ungetc = none.ungetc,
        .fputs = none.fputs,
        .ferror = none.fail,
        .remove = none.remove,
    };
};

/// The file backend; hosts without libc set it before `App.boot`.
pub var stdio: Stdio = .default;

fn fopen(path: [*:0]const u8, mode: [*:0]const u8) ?*FILE {
    return stdio.fopen(path, mode);
}
fn fclose(stream: *FILE) c_int {
    return stdio.fclose(stream);
}
fn fgetc(stream: *FILE) c_int {
    return stdio.fgetc(stream);
}
fn ungetc(c: c_int, stream: *FILE) c_int {
    return stdio.ungetc(c, stream);
}
fn fputs(s: [*:0]const u8, stream: *FILE) c_int {
    return stdio.fputs(s, stream);
}
fn ferror(stream: *FILE) c_int {
    return stdio.ferror(stream);
}
fn remove(path: [*:0]const u8) c_int {
    return stdio.remove(path);
}

/// NUL-terminated copies of paths and lines for the stdio calls. Static, not
/// on the stack: the Playdate's game task has a small stack, and these sit
/// under deep event chains (ini_open from a Step event). Single-threaded and
/// never held across calls: each use ends with the stdio call it feeds.
var z_buf: [STRING_MAX_LEN]u8 = undefined;

/// `s` NUL-terminated in `z_buf`, or null if it does not fit.
fn toZ(s: []const u8) ?[*:0]const u8 {
    if (s.len >= z_buf.len) return null;
    return toZTrunc(s);
}

/// `s` NUL-terminated in `z_buf`, truncated to fit.
fn toZTrunc(s: []const u8) [*:0]const u8 {
    const n = @min(s.len, z_buf.len - 1);
    @memcpy(z_buf[0..n], s[0..n]);
    z_buf[n] = 0;
    return @ptrCast(&z_buf);
}

/// Ini.load's line buffer (static for the same reason as `z_buf`).
var ini_line: [STRING_MAX_LEN - 1]u8 = undefined;

const TextFile = struct {
    fp: ?*FILE = null,
    writing: bool = false,
};

pub const FileManager = struct {
    files: [MAX_HANDLES]TextFile = [_]TextFile{.{}} ** MAX_HANDLES,
    string_ring: [STRING_RING_COUNT][STRING_MAX_LEN]u8 = undefined,
    string_next: usize = 0,
    working_dir: [STRING_MAX_LEN]u8 = [_]u8{ '.', '/' } ++ [_]u8{0} ** (STRING_MAX_LEN - 2),
    working_dir_len: usize = 2,

    var instance: FileManager = .{};

    pub fn get() *FileManager {
        return &instance;
    }

    fn nextStringBuffer(self: *FileManager) *[STRING_MAX_LEN]u8 {
        const buf = &self.string_ring[self.string_next];
        self.string_next = (self.string_next + 1) % STRING_RING_COUNT;
        buf[0] = 0;
        return buf;
    }

    fn getFile(self: *FileManager, handle: i32, want_write: bool) ?*FILE {
        if (handle < 0 or handle >= MAX_HANDLES) return null;
        const u_idx: usize = @intCast(handle);
        const f = &self.files[u_idx];
        if (f.fp == null or f.writing != want_write) return null;
        return f.fp;
    }

    fn peekChar(fp: *FILE) c_int {
        const c = fgetc(fp);
        if (c != EOF) {
            _ = ungetc(c, fp);
        }
        return c;
    }

    fn isNewline(c: c_int) bool {
        return c == '\r' or c == '\n';
    }

    pub fn openRead(self: *FileManager, path_slice: []const u8) ?i32 {
        const path_z = toZ(path_slice) orelse return null;

        const slot_idx = for (&self.files, 0..) |*f, i| {
            if (f.fp == null) break i;
        } else return null;

        const fp = fopen(path_z, "rb") orelse return null;
        self.files[slot_idx] = .{ .fp = fp, .writing = false };
        return @intCast(slot_idx);
    }

    pub fn openWrite(self: *FileManager, path_slice: []const u8) ?i32 {
        const path_z = toZ(path_slice) orelse return null;

        const slot_idx = for (&self.files, 0..) |*f, i| {
            if (f.fp == null) break i;
        } else return null;

        const fp = fopen(path_z, "wb") orelse return null;
        self.files[slot_idx] = .{ .fp = fp, .writing = true };
        return @intCast(slot_idx);
    }

    pub fn close(self: *FileManager, handle: i32) void {
        if (handle < 0 or handle >= MAX_HANDLES) return;
        const u_idx: usize = @intCast(handle);
        if (self.files[u_idx].fp) |fp| {
            _ = fclose(fp);
            self.files[u_idx].fp = null;
            self.files[u_idx].writing = false;
        }
    }

    pub fn closeAll(self: *FileManager) void {
        for (0..MAX_HANDLES) |idx| {
            self.close(@intCast(idx));
        }
    }

    pub fn eof(self: *FileManager, handle: i32) bool {
        const fp = self.getFile(handle, false) orelse return true;
        return peekChar(fp) == EOF;
    }

    pub fn readString(self: *FileManager, handle: i32) []const u8 {
        const fp = self.getFile(handle, false) orelse return "";
        const buf = self.nextStringBuffer();
        var len: usize = 0;

        while (true) {
            const next_c = peekChar(fp);
            if (next_c == EOF or isNewline(next_c)) break;
            const c = fgetc(fp);
            if (c == EOF) break;
            if (len + 1 < STRING_MAX_LEN) {
                buf[len] = @intCast(c);
                len += 1;
            }
        }
        buf[len] = 0;
        return buf[0..len];
    }

    pub fn readln(self: *FileManager, handle: i32) []const u8 {
        const fp = self.getFile(handle, false) orelse return "";
        const buf = self.nextStringBuffer();
        var len: usize = 0;

        // 1. Consume text up to newline
        while (true) {
            const next_c = peekChar(fp);
            if (next_c == EOF or isNewline(next_c)) break;
            const c = fgetc(fp);
            if (c == EOF) break;
            if (len + 1 < STRING_MAX_LEN) {
                buf[len] = @intCast(c);
                len += 1;
            }
        }

        // 2. Consume newline sequence (\r, \n, or \r\n)
        const first = fgetc(fp);
        if (first != EOF) {
            if (isNewline(first) and len + 1 < STRING_MAX_LEN) {
                buf[len] = @intCast(first);
                len += 1;
            }
            if (first == '\r') {
                const second = peekChar(fp);
                if (second == '\n') {
                    _ = fgetc(fp);
                    if (len + 1 < STRING_MAX_LEN) {
                        buf[len] = '\n';
                        len += 1;
                    }
                }
            }
        }

        buf[len] = 0;
        return buf[0..len];
    }

    pub fn writeString(self: *FileManager, handle: i32, str_slice: []const u8) void {
        const fp = self.getFile(handle, true) orelse return;
        _ = fputs(toZ(str_slice) orelse return, fp);
    }

    pub fn writeln(self: *FileManager, handle: i32) void {
        const fp = self.getFile(handle, true) orelse return;
        _ = fputs("\r\n", fp);
    }

    /// file_delete: true if the file was removed.
    pub fn fileDelete(_: *FileManager, path_slice: []const u8) bool {
        if (path_slice.len == 0) return false;
        return remove(toZ(path_slice) orelse return false) == 0;
    }

    /// working_directory: always ends with a separator ("./" by default).
    pub fn workingDirectory(self: *const FileManager) []const u8 {
        return self.working_dir[0..self.working_dir_len];
    }

    /// gm_set_working_directory: "" means "./"; a separator is appended when
    /// missing. Fails (unchanged) when the result would not fit.
    pub fn setWorkingDirectory(self: *FileManager, dir_in: []const u8) bool {
        const dir: []const u8 = if (dir_in.len == 0) "./" else dir_in;
        if (dir.len > STRING_MAX_LEN - 2) return false;
        @memcpy(self.working_dir[0..dir.len], dir);
        var len = dir.len;
        const last = dir[len - 1];
        if (last != '/' and last != '\\') {
            self.working_dir[len] = '/';
            len += 1;
        }
        self.working_dir_len = len;
        return true;
    }

    pub fn fileExists(_: *FileManager, path_slice: []const u8) bool {
        const fp = fopen(toZ(path_slice) orelse return false, "rb") orelse return false;
        _ = fclose(fp);
        return true;
    }
};

// ---- INI files (Function_ini.js, yyIniFile.js; gm_file.c gm_ini_*) -----------

pub const INI_MAX_SECTIONS: usize = 16;
pub const INI_MAX_KEYS: usize = 128;
/// Section and key names (gm_file.h GM_INI_NAME_MAX minus the NUL).
pub const INI_NAME_MAX: usize = 63;
pub const INI_VALUE_MAX: usize = 255;
pub const INI_TEXT_MAX: usize = 16383;

fn BoundedText(comptime cap: usize) type {
    return struct {
        buf: [cap]u8 = undefined,
        len: usize = 0,

        /// Stores `s`, truncated to the capacity.
        fn set(self: *@This(), s: []const u8) void {
            self.len = @min(s.len, cap);
            @memcpy(self.buf[0..self.len], s[0..self.len]);
        }

        fn slice(self: *const @This()) []const u8 {
            return self.buf[0..self.len];
        }
    };
}

const IniName = BoundedText(INI_NAME_MAX);

const IniKey = struct {
    section: usize = 0,
    key: IniName = .{},
    value: BoundedText(INI_VALUE_MAX) = .{},
};

fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// The one open INI file. Same limits, parsing and output as gm_file.c: one
/// file at a time, sections and keys in insertion order, saved by `close`
/// only after a write, as `[section]` / `key="value"` lines ending in "\r\n".
/// Relative names resolve against working_directory (CheckWorkingDirectory).
pub const Ini = struct {
    is_open: bool = false,
    changed: bool = false,
    path: BoundedText(STRING_MAX_LEN - 1) = .{},
    sections: [INI_MAX_SECTIONS]IniName = undefined,
    section_count: usize = 0,
    keys: [INI_MAX_KEYS]IniKey = undefined,
    key_count: usize = 0,
    text: BoundedText(INI_TEXT_MAX) = .{},

    var instance: Ini = .{};

    pub fn get() *Ini {
        return &instance;
    }

    /// Names compare after the truncation they get when stored.
    fn nameEq(stored: []const u8, name: []const u8) bool {
        return std.mem.eql(u8, stored, name[0..@min(name.len, INI_NAME_MAX)]);
    }

    fn findSection(self: *const Ini, name: []const u8) ?usize {
        for (self.sections[0..self.section_count], 0..) |*s, i| {
            if (nameEq(s.slice(), name)) return i;
        }
        return null;
    }

    fn section(self: *Ini, name: []const u8) ?usize {
        if (self.findSection(name)) |i| return i;
        if (self.section_count >= INI_MAX_SECTIONS) return null;
        self.sections[self.section_count].set(name);
        self.section_count += 1;
        return self.section_count - 1;
    }

    fn findKey(self: *Ini, section_name: []const u8, key: []const u8) ?*IniKey {
        const sec = self.findSection(section_name) orelse return null;
        for (self.keys[0..self.key_count]) |*k| {
            if (k.section == sec and nameEq(k.key.slice(), key)) return k;
        }
        return null;
    }

    /// yyIniFile.SetKey without the change flag (shared with the loader).
    fn set(self: *Ini, sec_opt: ?usize, key: []const u8, value: []const u8) bool {
        const sec = sec_opt orelse return false;
        const entry = for (self.keys[0..self.key_count]) |*k| {
            if (k.section == sec and nameEq(k.key.slice(), key)) break k;
        } else blk: {
            if (self.key_count >= INI_MAX_KEYS) return false;
            const fresh = &self.keys[self.key_count];
            self.key_count += 1;
            fresh.* = .{ .section = sec };
            fresh.key.set(key);
            break :blk fresh;
        };
        entry.value.set(value);
        return true;
    }

    /// One line of yyIniFile.ReadIniFile: a `[section]` header or a
    /// `key = value` pair of the current section. Text before the first
    /// section, blank lines and '#' / ';' lines are ignored.
    fn parseLine(self: *Ini, line: []const u8, sec: *?usize) void {
        var p: usize = 0;
        while (p < line.len and isBlank(line[p])) p += 1;
        if (p == line.len or line[p] == '#' or line[p] == ';') return;
        if (line[p] == '[') {
            if (std.mem.indexOfScalarPos(u8, line, p + 1, ']')) |end| {
                sec.* = self.section(line[p + 1 .. end]);
            }
            return;
        }
        if (sec.* == null) return;
        const eq = std.mem.indexOfScalarPos(u8, line, p, '=') orelse return;
        const key = std.mem.trimEnd(u8, line[p..eq], " \t");

        var v = eq + 1;
        while (v < line.len and isBlank(line[v])) v += 1;
        // Value terminators besides the end of the line.
        var stops: []const u8 = "#;";
        var quoted = false;
        if (v < line.len and (line[v] == '"' or line[v] == '\'')) {
            // Quoted: up to the matching quote (or the end of the line).
            stops = line[v .. v + 1];
            quoted = true;
            v += 1;
        } else if (v < line.len and (line[v] == '[' or line[v] == '{')) {
            stops = ""; // JSON: no trailing comments
        }
        var end = v;
        var ws: ?usize = null;
        while (end < line.len and std.mem.indexOfScalar(u8, stops, line[end]) == null) : (end += 1) {
            if (isBlank(line[end])) {
                if (ws == null) ws = end;
            } else {
                ws = null;
            }
            // No escapes: the backslash and the next char are kept.
            if (line[end] == '\\' and end + 1 < line.len) end += 1;
        }
        const value_end = if (quoted) end else (ws orelse end);
        _ = self.set(sec.*, key, line[v..value_end]);
    }

    fn load(self: *Ini, fp: *FILE) void {
        const line = &ini_line;
        var len: usize = 0;
        var sec: ?usize = null;
        while (true) {
            const c = fgetc(fp);
            if (c == EOF or c == '\r' or c == '\n') {
                self.parseLine(line[0..len], &sec);
                len = 0;
                if (c == EOF) break;
            } else if (len < line.len) {
                line[len] = @intCast(c);
                len += 1;
            }
        }
    }

    /// CheckWorkingDirectory: relative names live in working_directory.
    fn resolve(self: *Ini, name: []const u8) void {
        const wd = FileManager.get().workingDirectory();
        const absolute = (name.len > 0 and (name[0] == '/' or name[0] == '\\')) or (name.len > 1 and name[1] == ':');
        if (absolute or std.mem.startsWith(u8, name, wd)) {
            self.path.set(name);
            return;
        }
        // Joined in z_buf: `name` may not alias `self.path`.
        const buf = z_buf[0 .. z_buf.len - 1];
        const n = @min(wd.len, buf.len);
        @memcpy(buf[0..n], wd[0..n]);
        const m = @min(name.len, buf.len - n);
        @memcpy(buf[n .. n + m], name[0..m]);
        self.path.set(buf[0 .. n + m]);
    }

    /// ini_open: closes (and saves) any open INI first. A missing or
    /// unreadable file opens as an empty INI that `close` will create.
    pub fn open(self: *Ini, name: []const u8) void {
        if (self.is_open) _ = self.close();
        self.section_count = 0;
        self.key_count = 0;
        self.changed = false;
        self.resolve(name);
        if (openRegularForRead(toZTrunc(self.path.slice()))) |fp| {
            self.load(fp);
            _ = fclose(fp);
        }
        self.is_open = true;
    }

    fn emit(self: *Ini, fp: ?*FILE, s: []const u8) void {
        if (fp) |f| _ = fputs(toZTrunc(s), f);
        const room = INI_TEXT_MAX - self.text.len;
        const n = @min(s.len, room);
        @memcpy(self.text.buf[self.text.len..][0..n], s[0..n]);
        self.text.len += n;
    }

    /// ini_close (yyIniFile.WriteIniFile): saves if changed and returns the
    /// INI text (valid until the next close; truncated at INI_TEXT_MAX, the
    /// file is not), or "" when nothing was open.
    pub fn close(self: *Ini) []const u8 {
        self.text.len = 0;
        if (!self.is_open) return "";
        var fp: ?*FILE = null;
        if (self.changed) fp = fopen(toZTrunc(self.path.slice()), "wb");
        for (self.sections[0..self.section_count], 0..) |*s, sec| {
            self.emit(fp, "[");
            self.emit(fp, s.slice());
            self.emit(fp, "]\r\n");
            for (self.keys[0..self.key_count]) |*k| {
                if (k.section != sec) continue;
                const value = k.value.slice();
                // Double quotes unless the value has some, then single, then none.
                const quote: []const u8 = if (std.mem.indexOfScalar(u8, value, '"') == null)
                    "\""
                else if (std.mem.indexOfScalar(u8, value, '\'') == null) "'" else "";
                self.emit(fp, k.key.slice());
                self.emit(fp, "=");
                self.emit(fp, quote);
                self.emit(fp, value);
                self.emit(fp, quote);
                self.emit(fp, "\r\n");
            }
        }
        if (fp) |f| _ = fclose(f);
        self.is_open = false;
        self.changed = false;
        self.section_count = 0;
        self.key_count = 0;
        return self.text.slice();
    }

    pub fn isOpen(self: *const Ini) bool {
        return self.is_open;
    }

    /// The stored string, or `def` when the key (or the INI) is missing.
    pub fn readString(self: *Ini, section_name: []const u8, key: []const u8, def: []const u8) []const u8 {
        if (!self.is_open) return def;
        const k = self.findKey(section_name, key) orelse return def;
        return k.value.slice();
    }

    /// parseFloat of the stored string, or `def` when the key is missing.
    /// Values that do not parse also give `def` (NaN in the HTML5 runner,
    /// which would poison every later comparison against the saved score).
    pub fn readReal(self: *Ini, section_name: []const u8, key: []const u8, def: f32) f32 {
        if (!self.is_open) return def;
        const k = self.findKey(section_name, key) orelse return def;
        return string.parseReal(k.value.slice()) orelse def;
    }

    /// False when no INI is open or the tables are full.
    pub fn writeString(self: *Ini, section_name: []const u8, key: []const u8, value: []const u8) bool {
        if (!self.is_open) return false;
        if (!self.set(self.section(section_name), key, value)) return false;
        self.changed = true;
        return true;
    }

    /// Stores the JS ToString of `value` ("" + value): integers exactly,
    /// other values with printf("%.9g") like gm_file.c (round-trips a float).
    pub fn writeReal(self: *Ini, section_name: []const u8, key: []const u8, value: f32) bool {
        var buf: [64]u8 = undefined;
        const text: []const u8 = if (std.math.isNan(value))
            "NaN"
        else if (std.math.isInf(value))
            (if (value < 0.0) "-Infinity" else "Infinity")
        else
            formatIniReal(&buf, value);
        return self.writeString(section_name, key, text);
    }
};

/// printf("%.0f") for integers below 1e21, else printf("%.9g"), of a finite
/// value; -0 prints as "0". libc's printf when linked, else `formatIniRealZig`.
fn formatIniReal(buf: *[64]u8, value: f32) []const u8 {
    if (!builtin.link_libc) return formatIniRealZig(buf, value);
    const integral = @abs(value) < 1e21 and @floor(value) == value;
    const fmt: [*:0]const u8 = if (integral) "%.0f" else "%.9g";
    const v: f64 = if (value == 0.0) 0.0 else value;
    const n = Stdio.libc.snprintf(buf, buf.len, fmt, v);
    return buf[0..if (n < 0) 0 else @min(@as(usize, @intCast(n)), buf.len - 1)];
}

/// `formatIniReal` without libc (checked against printf in the tests).
fn formatIniRealZig(buf: *[64]u8, value: f32) []const u8 {
    if (value == 0.0) return "0";
    if (@abs(value) < 1e21 and @floor(value) == value) {
        return std.fmt.bufPrint(buf, "{d}", .{@as(i128, @intFromFloat(value))}) catch unreachable;
    }
    var exp: i32 = undefined;
    const digits = significantDigits9(@abs(value), &exp);

    var w: std.Io.Writer = .fixed(buf);
    if (value < 0.0) w.writeByte('-') catch unreachable;
    if (exp < -4 or exp >= 9) {
        // %e: d[.ddd]e[+-]XX, trailing zeros removed.
        const frac = std.mem.trimEnd(u8, digits[1..], "0");
        w.writeByte(digits[0]) catch unreachable;
        if (frac.len > 0) w.print(".{s}", .{frac}) catch unreachable;
        w.print("e{c}{d:0>2}", .{ @as(u8, if (exp < 0) '-' else '+'), @abs(exp) }) catch unreachable;
    } else if (exp >= 0) {
        // %f with 8 - exp decimals: the point after digit exp.
        const point: usize = @intCast(exp + 1);
        const frac = std.mem.trimEnd(u8, digits[point..], "0");
        w.writeAll(digits[0..point]) catch unreachable;
        if (frac.len > 0) w.print(".{s}", .{frac}) catch unreachable;
    } else {
        // 0.000ddd: -exp - 1 zeros after the point.
        w.writeAll("0.") catch unreachable;
        w.splatByteAll('0', @intCast(-exp - 1)) catch unreachable;
        w.writeAll(std.mem.trimEnd(u8, &digits, "0")) catch unreachable;
    }
    return w.buffered();
}

/// The 9 significant digits of `v` > 0 rounded like printf (to nearest,
/// ties to even) and the decimal exponent of the first one.
fn significantDigits9(v: f32, exp: *i32) [9]u8 {
    const sig = 9;
    // v = m * 2^e with m odd (or e == 0).
    const bits: u32 = @bitCast(v);
    const biased: i32 = @intCast(bits >> 23);
    var m: u32 = bits & 0x7FFFFF;
    var e: i32 = -149;
    if (biased != 0) {
        m |= 0x800000;
        e = biased - 150;
    }
    while (m & 1 == 0 and e < 0) : (e += 1) m >>= 1;

    // m * 2^e < 2^128; m * 5^k < 2^127 for k <= 44.
    const k: u32 = if (e < 0) @intCast(-e) else 0;
    if (k > 44) {
        // At least 31 significant digits: never a tie, std.fmt rounds alike.
        var sci_buf: [32]u8 = undefined;
        const sci = std.fmt.bufPrint(&sci_buf, "{e:.8}", .{@as(f64, v)}) catch unreachable;
        const e_at = std.mem.indexOfScalar(u8, sci, 'e').?;
        exp.* = std.fmt.parseInt(i32, sci[e_at + 1 ..], 10) catch unreachable;
        var d: [sig]u8 = undefined;
        d[0] = sci[0];
        @memcpy(d[1..], sci[2..e_at]);
        return d;
    }
    // Exact decimal expansion: v = n * 10^-k.
    const n: u128 = if (e >= 0) @as(u128, m) << @intCast(e) else @as(u128, m) * std.math.pow(u128, 5, k);
    var all_buf: [40]u8 = undefined;
    const all = std.fmt.bufPrint(&all_buf, "{d}", .{n}) catch unreachable;
    exp.* = @as(i32, @intCast(all.len)) - 1 - @as(i32, @intCast(k));

    var d: [sig]u8 = @splat('0');
    const head = @min(all.len, sig);
    @memcpy(d[0..head], all[0..head]);
    if (all.len > sig) {
        const rest = all[sig..];
        const tail_zero = std.mem.allEqual(u8, rest[1..], '0');
        if (rest[0] > '5' or (rest[0] == '5' and (!tail_zero or (d[sig - 1] - '0') % 2 == 1))) {
            var i: usize = sig;
            while (i > 0) {
                i -= 1;
                if (d[i] != '9') {
                    d[i] += 1;
                    break;
                }
                d[i] = '0';
            } else {
                d[0] = '1';
                exp.* += 1;
            }
        }
    }
    return d;
}

test "formatIniRealZig matches printf" {
    if (!builtin.link_libc) return error.SkipZigTest;
    var prng = std.Random.DefaultPrng.init(0x5be1);
    const rand = prng.random();
    const fixed = [_]f32{ 0.0, -0.0, 0.5, -0.5, 1.5, 0.1, 1e-5, 1.25e-4, 9.99999999e-5, 123456789.0, 0.123456789, 1234567.125, 3.3333333, -2.75e9, 1e21, 1.5e21, -1e30, 3.4e38, 1e-38, 1.4e-45, 99999.996, 999999999.0, 1e20 };
    var want: [64]u8 = undefined;
    var got: [64]u8 = undefined;
    for (0..200_000) |i| {
        const v: f32 = if (i < fixed.len) fixed[i] else switch (i % 3) {
            // Any finite bit pattern.
            0 => blk: {
                const f: f32 = @bitCast(rand.int(u32));
                break :blk if (std.math.isFinite(f)) f else 1.0;
            },
            // Game-like magnitudes, with and without a fraction.
            1 => (rand.float(f32) - 0.5) * 2e6,
            else => @as(f32, @floatFromInt(rand.intRangeAtMost(i32, -100_000, 100_000))) / 8.0,
        };
        try std.testing.expectEqualStrings(formatIniReal(&want, v), formatIniRealZig(&got, v));
    }
}

/// Opens a regular file for reading (gm_file.c open_regular_for_read): stdio
/// lets fopen succeed on a directory with the first read failing.
fn openRegularForRead(path: [*:0]const u8) ?*FILE {
    if (path[0] == 0) return null;
    const fp = fopen(path, "rb") orelse return null;
    const c = fgetc(fp);
    if (c == EOF) {
        if (ferror(fp) != 0) {
            _ = fclose(fp);
            return null;
        }
    } else {
        _ = ungetc(c, fp);
    }
    return fp;
}

test "working directory and file_delete (test_working_directory)" {
    const fm = FileManager.get();
    try std.testing.expectEqualStrings("./", fm.workingDirectory());
    try std.testing.expect(fm.setWorkingDirectory("build"));
    try std.testing.expectEqualStrings("build/", fm.workingDirectory());
    try std.testing.expect(fm.setWorkingDirectory("saves/"));
    try std.testing.expectEqualStrings("saves/", fm.workingDirectory());
    try std.testing.expect(fm.setWorkingDirectory(""));
    try std.testing.expectEqualStrings("./", fm.workingDirectory());
    const long_dir = "d" ** (STRING_MAX_LEN - 1);
    try std.testing.expect(!fm.setWorkingDirectory(long_dir));
    try std.testing.expectEqualStrings("./", fm.workingDirectory());
    try std.testing.expect(fm.setWorkingDirectory(long_dir[0 .. STRING_MAX_LEN - 2]));
    try std.testing.expectEqual(STRING_MAX_LEN - 1, fm.workingDirectory().len);
    try std.testing.expect(fm.setWorkingDirectory("./"));

    const path = "/tmp/zig_spelunky_delete_test.txt";
    const h = fm.openWrite(path).?;
    fm.close(h);
    try std.testing.expect(fm.fileDelete(path));
    try std.testing.expect(!fm.fileExists(path));
    try std.testing.expect(!fm.fileDelete(path));
    try std.testing.expect(!fm.fileDelete(""));
}

test "FileManager exact C-parity file reading and writing" {
    var fm = FileManager.get();
    defer fm.closeAll();

    const test_file = "/tmp/zig_spelunky_test_file.txt";

    const wh = fm.openWrite(test_file);
    try std.testing.expect(wh != null);
    const write_handle = wh.?;

    fm.writeString(write_handle, "SPELUNKY");
    fm.writeln(write_handle);
    fm.writeString(write_handle, "CLASSIC");
    fm.close(write_handle);

    try std.testing.expect(fm.fileExists(test_file));

    const rh = fm.openRead(test_file);
    try std.testing.expect(rh != null);
    const read_handle = rh.?;

    const s1 = fm.readString(read_handle);
    try std.testing.expectEqualStrings("SPELUNKY", s1);

    const nl = fm.readln(read_handle);
    try std.testing.expectEqualStrings("\r\n", nl);

    const s2 = fm.readString(read_handle);
    try std.testing.expectEqualStrings("CLASSIC", s2);

    fm.close(read_handle);
}

fn writeRaw(path: [*:0]const u8, bytes: []const u8) !void {
    const fp = fopen(path, "wb") orelse return error.Open;
    defer _ = fclose(fp);
    var buf: [1024]u8 = undefined;
    @memcpy(buf[0..bytes.len], bytes);
    buf[bytes.len] = 0;
    _ = fputs(@ptrCast(&buf), fp);
}

fn readRaw(path: [*:0]const u8, buf: []u8) []const u8 {
    const fp = fopen(path, "rb") orelse return "";
    defer _ = fclose(fp);
    var n: usize = 0;
    while (n < buf.len) {
        const c = fgetc(fp);
        if (c == EOF) break;
        buf[n] = @intCast(c);
        n += 1;
    }
    return buf[0..n];
}

// C parity: tests/test_file.c test_ini_highscore_round_trip.
test "ini: highscore round trip against the shipped spelunky.ini" {
    const fm = FileManager.get();
    const ini = Ini.get();
    try writeRaw("/tmp/zig_spelunky_ini_test.ini", "[highscore]\nvalue10=\"0.000000\"\nvalue9=\"200001.000000\"\nvalue1=\"0.000000\"\n");
    try std.testing.expect(fm.setWorkingDirectory("/tmp"));
    defer _ = fm.setWorkingDirectory("./");

    ini.open("zig_spelunky_ini_test.ini"); // relative: resolved in working_directory
    try std.testing.expect(ini.isOpen());
    try std.testing.expectEqual(@as(f32, 200001.0), ini.readReal("highscore", "value9", -1.0));
    try std.testing.expectEqual(@as(f32, 0.0), ini.readReal("highscore", "value1", -1.0));
    try std.testing.expectEqual(@as(f32, -1.0), ini.readReal("highscore", "value3", -1.0));
    try std.testing.expectEqual(@as(f32, -1.0), ini.readReal("other", "value1", -1.0));
    try std.testing.expect(ini.writeString("highscore", "name1", "MONEY"));
    try std.testing.expect(ini.writeReal("highscore", "value1", 12345.0));
    try std.testing.expect(ini.writeReal("highscore", "value7", 1.0));
    try std.testing.expect(ini.writeReal("highscore", "value2", -0.0));
    try std.testing.expect(ini.writeReal("x", "half", 0.5));
    const expected = "[highscore]\r\nvalue10=\"0.000000\"\r\nvalue9=\"200001.000000\"\r\n" ++
        "value1=\"12345\"\r\nname1=\"MONEY\"\r\nvalue7=\"1\"\r\nvalue2=\"0\"\r\n[x]\r\nhalf=\"0.5\"\r\n";
    try std.testing.expectEqualStrings(expected, ini.close());
    try std.testing.expect(!ini.isOpen());
    var buf: [512]u8 = undefined;
    try std.testing.expectEqualStrings(expected, readRaw("/tmp/zig_spelunky_ini_test.ini", &buf));

    // The next ini_open sees the saved values.
    ini.open("zig_spelunky_ini_test.ini");
    try std.testing.expectEqual(@as(f32, 12345.0), ini.readReal("highscore", "value1", 0.0));
    try std.testing.expectEqual(@as(f32, 1.0), ini.readReal("highscore", "value7", 0.0));
    try std.testing.expectEqualStrings("MONEY", ini.readString("highscore", "name1", ""));
    _ = ini.close();
    try std.testing.expect(fm.fileDelete("/tmp/zig_spelunky_ini_test.ini"));
}

// C parity: tests/test_file.c test_ini_parse_and_save_rules.
test "ini: parse and save rules" {
    const fm = FileManager.get();
    const ini = Ini.get();
    const path_a = "/tmp/zig_spelunky_ini_a.ini";
    const path_b = "/tmp/zig_spelunky_ini_b.ini";
    const text = "orphan=1\r\n; comment\r\n  [ s ]\r\n  a  =  7 trailing  ; comment\r\n" ++
        "b='single \"q\"' rest\r\nc=junk\r\nd= 2.5e1\r\ne=1\r\ne=2\r\n";
    try writeRaw(path_a, text);
    ini.open(path_a);
    try std.testing.expectEqualStrings("7 trailing", ini.readString(" s ", "a", ""));
    try std.testing.expectEqual(@as(f32, 7.0), ini.readReal(" s ", "a", 0.0)); // parseFloat prefix
    try std.testing.expectEqual(@as(f32, 2.0), ini.readReal(" s ", "e", 0.0)); // later key wins
    try std.testing.expectEqualStrings("single \"q\"", ini.readString(" s ", "b", ""));
    try std.testing.expectEqual(@as(f32, 3.0), ini.readReal(" s ", "c", 3.0)); // unparseable -> default
    try std.testing.expectEqual(@as(f32, 25.0), ini.readReal(" s ", "d", 0.0));
    try std.testing.expectEqualStrings("none", ini.readString(" s ", "orphan", "none"));

    // Unchanged: closing does not touch the file.
    _ = ini.close();
    var buf: [256]u8 = undefined;
    try std.testing.expectEqualStrings(text, readRaw(path_a, &buf));
    try std.testing.expect(fm.fileDelete(path_a));

    // Missing file: empty, and only created by a write.
    ini.open(path_b);
    try std.testing.expectEqualStrings("", ini.close());
    try std.testing.expect(!fm.fileExists(path_b));
    ini.open(path_b);
    try std.testing.expect(ini.writeString("q", "v", "has \" and '"));
    ini.open(path_b); // re-open saves the open file first
    try std.testing.expectEqualStrings("has \" and '", ini.readString("q", "v", ""));
    try std.testing.expectEqualStrings("[q]\r\nv=has \" and '\r\n", ini.close());
    try std.testing.expect(fm.fileDelete(path_b));

    // Nothing open.
    try std.testing.expect(!ini.writeReal("s", "k", 1.0));
    try std.testing.expectEqual(@as(f32, 4.0), ini.readReal("s", "k", 4.0));
    try std.testing.expectEqualStrings("", ini.close());
}
