//! Playdate video backend: `runtime.PlatformInterface` on 1-bit LCDBitmaps.
//! Port of the sp_platform half of src/host/playdate/main_playdate.c.
//!
//! The application surface (320 x 240) is drawn straight to the screen,
//! centred on the 400 x 240 LCD through the draw offset; `present` blacks
//! out the side bars. Colours map to 8x8 ordered-dither patterns by
//! luminance; draw alpha becomes a dithered stencil. Dark tints draw a sprite
//! as a black silhouette.
//!
//! Sprite frames come from the .pdx (tools/playdate_assets.py, pre-dithered
//! to 1 bit): assets/sprites/<name>/<frame>, loaded on first use. Flipped
//! copies are made once, on demand, for the scaled and rotated paths.

const std = @import("std");
const runtime = @import("runtime");
const pd_mod = @import("pd.zig");
const api = pd_mod.api;

const sprite_slots = runtime.sprite.MAX_SPRITES + runtime.draw.ADDED_SPRITE_MAX;
const surface_max = 64;
/// Dither levels 0 (none) .. 16 (all).
const levels = 17;
const screen_w = api.LCD_COLUMNS;
const screen_h = api.LCD_ROWS;

const flips = [4]api.LCDBitmapFlip{ .BitmapUnflipped, .BitmapFlippedX, .BitmapFlippedY, .BitmapFlippedXY };
const black: api.LCDColor = @intFromEnum(api.LCDSolidColor.ColorBlack);
const white: api.LCDColor = @intFromEnum(api.LCDSolidColor.ColorWhite);
const clear_colour: api.LCDColor = @intFromEnum(api.LCDSolidColor.ColorClear);

const SpriteBitmaps = struct {
    tried: bool = false,
    table: ?*api.LCDBitmapTable = null,
    /// Frame bitmaps, or 1 strip bitmap (sprite_add) when `strip_w > 0`.
    count: usize = 0,
    strip_w: i32 = 0,
    /// Strip size (sprite_add), or frame dimensions.
    w: i32 = 0,
    h: i32 = 0,
    /// Single frame bitmaps when table is null.
    frames: []?*api.LCDBitmap = &.{},
};

pub const Video = struct {
    display_scale: u32 = 1,
    app_w: i32 = 320,
    app_h: i32 = 240,
    /// 0 = the application surface (the screen).
    target: i32 = 0,
    /// A surface context is pushed.
    pushed: bool = false,
    sprites: [sprite_slots]SpriteBitmaps = @splat(.{}),
    surfaces: [surface_max + 1]?*api.LCDBitmap = @splat(null),
    surface_size: [surface_max + 1][2]i32 = @splat(.{ 0, 0 }),
    /// [colour level][alpha level]: rows 0..7 colour, 8..15 mask.
    patterns: [levels][levels]api.LCDPattern = undefined,
    /// White pixels are drawn; tiled stencils must be 32 px wide.
    stencils: [levels]?*api.LCDBitmap = @splat(null),
    stencil_active: bool = false,
    show_fps: bool = false,
    current_draw_mode: api.LCDBitmapDrawMode = .DrawModeCopy,

    pub fn screenW(self: *const Video) i32 {
        return @divTrunc(api.LCD_COLUMNS, @as(i32, @intCast(self.display_scale)));
    }

    pub fn screenH(self: *const Video) i32 {
        return @divTrunc(api.LCD_ROWS, @as(i32, @intCast(self.display_scale)));
    }

    pub fn setDisplayScale(self: *Video, scale: u32) void {
        const s: u32 = if (scale >= 2) 2 else 1;
        self.display_scale = s;
        pd_mod.pd.display.setScale(s);
        // No viewport scale-down: the game still renders at 1x and the
        // hardware doubles it, so only the centre of the frame is visible.
        self.pushTarget();
    }

    pub fn toggleDisplayScale(self: *Video) void {
        self.setDisplayScale(if (self.display_scale == 1) 2 else 1);
    }

    pub fn setDrawMode(self: *Video, mode: api.LCDBitmapDrawMode) void {
        if (self.current_draw_mode != mode) {
            _ = pd_mod.pd.graphics.setDrawMode(mode);
            self.current_draw_mode = mode;
        }
    }

    pub fn init(self: *Video) void {
        const gfx = pd_mod.pd.graphics;
        for (0..levels) |c| {
            for (0..levels) |a| {
                for (0..8) |row| {
                    self.patterns[c][a][row] = bayerRow(c, row);
                    self.patterns[c][a][row + 8] = bayerRow(a, row);
                }
            }
        }
        for (1..levels - 1) |a| {
            const bm = gfx.newBitmap(32, 32, black) orelse continue;
            gfx.pushContext(bm);
            gfx.fillRect(0, 0, 32, 32, @intFromPtr(&self.patterns[a][levels - 1]));
            gfx.popContext();
            self.stencils[a] = bm;
        }
        pd_mod.pd.display.setScale(self.display_scale);
    }

    pub fn deinit(self: *Video) void {
        const gfx = pd_mod.pd.graphics;
        if (self.pushed) gfx.popContext();
        self.pushed = false;
        for (&self.sprites) |*s| {
            if (s.table) |t| gfx.freeBitmapTable(t);
            for (s.frames) |f| if (f) |bm| gfx.freeBitmap(bm);
            if (s.frames.len > 0) pd_mod.free(s.frames);
            s.* = .{};
        }
        for (&self.surfaces) |*s| {
            if (s.*) |bm| gfx.freeBitmap(bm);
            s.* = null;
        }
        for (&self.stencils) |*s| {
            if (s.*) |bm| gfx.freeBitmap(bm);
            s.* = null;
        }
    }

    pub fn interface(self: *Video) runtime.PlatformInterface {
        return .{
            .user_data = self,
            .begin_frame_fn = beginFrame,
            .present_fn = present,
            .clear_fn = clear,
            .sprite_load_fn = spriteLoad,
            .draw_image_fn = drawImage,
            .draw_rect_fn = drawRect,
            .draw_circle_fn = drawCircle,
            .surface_create_fn = surfaceCreate,
            .surface_free_fn = surfaceFree,
            .surface_target_fn = surfaceTarget,
            .draw_surface_fn = drawSurface,
            .window_size_fn = windowSize,
            .display_size_fn = windowSize,
            .set_window_size_fn = setWindowSize,
            .set_fullscreen_fn = setFullscreen,
            .get_ticks_ms_fn = ticks,
            .delay_ms_fn = delay,
            .directory_exists_fn = directoryExists,
        };
    }

    // ---- colours -------------------------------------------------------------

    /// GameMaker colour + alpha -> a solid colour or a dither pattern.
    fn colour(self: *const Video, col: u32, alpha: f32) api.LCDColor {
        const lv = colourLevel(col);
        const al = alphaLevel(alpha);
        if (al == levels - 1 and lv == 0) return black;
        if (al == levels - 1 and lv == levels - 1) return white;
        return @intFromPtr(&self.patterns[lv][al]);
    }

    /// Applies draw alpha to bitmap drawing; false when nothing would show.
    fn beginAlpha(self: *Video, alpha: f32) bool {
        const al = alphaLevel(alpha);
        if (al == 0) return false;
        if (al < levels - 1) {
            if (self.stencils[al]) |st| {
                pd_mod.pd.graphics.setStencilImage(st, 1);
                self.stencil_active = true;
            }
        }
        return true;
    }

    fn endAlpha(self: *Video) void {
        if (!self.stencil_active) return;
        pd_mod.pd.graphics.setStencilImage(null, 0);
        self.stencil_active = false;
    }

    // ---- targets -------------------------------------------------------------

    /// Draws into the current target: a pushed surface, or the screen with
    /// the application surface centred.
    fn pushTarget(self: *Video) void {
        const gfx = pd_mod.pd.graphics;
        if (self.pushed) {
            gfx.popContext();
            self.pushed = false;
        }
        if (self.surfaceAt(self.target)) |bm| {
            gfx.pushContext(bm);
            gfx.setDrawOffset(0, 0);
            self.pushed = true;
        } else {
            const sw = self.screenW();
            const sh = self.screenH();
            // Negative when the frame is larger than the (scaled) screen:
            // centred, with the edges cropped.
            gfx.setDrawOffset(@divTrunc(sw - self.app_w, 2), @divTrunc(sh - self.app_h, 2));
        }
    }

    fn surfaceAt(self: *const Video, s: i32) ?*api.LCDBitmap {
        return if (s >= 1 and s <= surface_max) self.surfaces[@intCast(s)] else null;
    }

    fn targetSize(self: *const Video) [2]i32 {
        if (self.surfaceAt(self.target) != null) return self.surface_size[@intCast(self.target)];
        return .{ self.app_w, self.app_h };
    }

    // ---- sprites -------------------------------------------------------------

    /// Static sprites: assets/sprites/<name>-table-<w>-<h> or assets/sprites/<name>/<frame>.
    fn spriteBitmaps(self: *Video, sprite: i32) ?*SpriteBitmaps {
        if (sprite < 0 or sprite >= sprite_slots) return null;
        const s = &self.sprites[@intCast(sprite)];
        if (s.tried) return s;
        s.tried = true;
        const def = runtime.SpriteRegistry.get().getSprite(sprite) orelse return s;
        if (def.frame_count <= 0) return s;
        const count: usize = @intCast(def.frame_count);
        const w = def.width;
        const h = def.height;

        // Try loading bitmap table first for multi-frame sprites
        if (count > 1 and w > 0 and h > 0) {
            if (pd_mod.path("assets/sprites/{s}", .{def.name})) |table_path| {
                if (loadBitmapTable(table_path)) |tbl| {
                    s.table = tbl;
                    s.count = count;
                    s.w = w;
                    s.h = h;
                    s.frames = &.{};
                    return s;
                }
            }
            if (pd_mod.path("assets/sprites/{s}-table-{d}-{d}", .{ def.name, w, h })) |table_path| {
                if (loadBitmapTable(table_path)) |tbl| {
                    s.table = tbl;
                    s.count = count;
                    s.w = w;
                    s.h = h;
                    s.frames = &.{};
                    return s;
                }
            }
        }

        s.frames = pd_mod.allocZeroed(?*api.LCDBitmap, count) orelse return s;
        s.count = count;
        s.w = w;
        s.h = h;
        if (count == 1) {
            // Try flat "assets/sprites/<name>" first, fallback to "assets/sprites/<name>/0"
            if (pd_mod.path("assets/sprites/{s}", .{def.name})) |flat_path| {
                if (loadBitmap(flat_path)) |bm| {
                    s.frames[0] = bm;
                    return s;
                }
            }
            if (pd_mod.path("assets/sprites/{s}/0", .{def.name})) |sub_path| {
                s.frames[0] = loadBitmap(sub_path);
            }
            return s;
        }

        for (0..count) |i| {
            const path = pd_mod.path("assets/sprites/{s}/{d}", .{ def.name, i }) orelse continue;
            s.frames[i] = loadBitmap(path);
        }
        return s;
    }

    fn frameBitmap(s: *SpriteBitmaps, index: usize) ?*api.LCDBitmap {
        if (index >= s.count) return null;
        if (s.table) |t| {
            return pd_mod.pd.graphics.getTableBitmap(t, @intCast(index));
        }
        return if (index < s.frames.len) s.frames[index] else null;
    }
};

// ---- helpers --------------------------------------------------------------------

const bayer = [8][8]u8{
    .{ 0, 32, 8, 40, 2, 34, 10, 42 },  .{ 48, 16, 56, 24, 50, 18, 58, 26 },
    .{ 12, 44, 4, 36, 14, 46, 6, 38 }, .{ 60, 28, 52, 20, 62, 30, 54, 22 },
    .{ 3, 35, 11, 43, 1, 33, 9, 41 },  .{ 51, 19, 59, 27, 49, 17, 57, 25 },
    .{ 15, 47, 7, 39, 13, 45, 5, 37 }, .{ 63, 31, 55, 23, 61, 29, 53, 21 },
};

/// Row of an 8x8 ordered-dither pattern with `level` / 16 of its bits set.
fn bayerRow(level: usize, row: usize) u8 {
    var bits: u8 = 0;
    for (0..8) |x| {
        if (bayer[row][x] < level * 4) bits |= @as(u8, 0x80) >> @intCast(x);
    }
    return bits;
}

fn alphaLevel(alpha: f32) usize {
    if (!(alpha > 0.0)) return 0;
    if (alpha >= 1.0) return levels - 1;
    return @intFromFloat(@round(alpha * (levels - 1)));
}

/// GameMaker colour (0x00BBGGRR) -> 0 (black) .. 16 (white).
fn colourLevel(c: u32) usize {
    const r = c & 0xFF;
    const g = (c >> 8) & 0xFF;
    const b = (c >> 16) & 0xFF;
    const lum = (299 * r + 587 * g + 114 * b) / 1000;
    return (lum * 16 + 127) / 255;
}

/// Dark tints draw the sprite as a black silhouette; anything lighter as is.
fn tintMode(c: u32) api.LCDBitmapDrawMode {
    return if (colourLevel(c) <= 4) .DrawModeFillBlack else .DrawModeCopy;
}

fn ifloor(v: f32) c_int {
    return @intFromFloat(std.math.clamp(@floor(v), -1e9, 1e9));
}

fn iround(v: f32) c_int {
    return @intFromFloat(std.math.clamp(@round(v), -1e9, 1e9));
}

fn iceil(v: f32) c_int {
    return @intFromFloat(std.math.clamp(@ceil(v), -1e9, 1e9));
}

/// pdc compiles x.png into x.pdi: loads `path` without its extension and
/// without a leading "./".
fn loadBitmap(path_in: [:0]const u8) ?*api.LCDBitmap {
    var path: []const u8 = path_in;
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        if (slash == null or dot > slash.?) path = path[0..dot];
    }
    // Static (the game task's stack is small); `path_in` may be in pd.path's buffer.
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    const clean = pd_mod.pathZ(&S.buf, "{s}", .{path}) orelse return null;
    var err: ?[*:0]const u8 = null;
    const bm = pd_mod.pd.graphics.loadBitmap(clean, &err);
    if (bm == null) pd_mod.log("host: bitmap {s}: {s}", .{ clean, if (err) |e| std.mem.span(e) else "not found" });
    return bm;
}

fn loadBitmapTable(path_in: [:0]const u8) ?*api.LCDBitmapTable {
    var path: []const u8 = path_in;
    while (std.mem.startsWith(u8, path, "./")) path = path[2..];
    const slash = std.mem.lastIndexOfScalar(u8, path, '/');
    if (std.mem.lastIndexOfScalar(u8, path, '.')) |dot| {
        if (slash == null or dot > slash.?) path = path[0..dot];
    }
    const S = struct {
        var buf: [256]u8 = undefined;
    };
    const clean = pd_mod.pathZ(&S.buf, "{s}", .{path}) orelse return null;
    var err: ?[*:0]const u8 = null;
    return pd_mod.pd.graphics.loadBitmapTable(clean, &err);
}

fn self_(ud: ?*anyopaque) *Video {
    return @ptrCast(@alignCast(ud.?));
}

// ---- PlatformInterface entries ---------------------------------------------------

fn beginFrame(ud: ?*anyopaque, w: i32, h: i32) void {
    const v = self_(ud);
    v.app_w = if (w < 1 or h < 1) 320 else w;
    v.app_h = if (w < 1 or h < 1) 240 else h;
    v.target = 0;
    v.pushTarget();
    _ = pd_mod.pd.graphics.setDrawMode(.DrawModeCopy);
    v.current_draw_mode = .DrawModeCopy;
}

/// The frame is already on the screen: black out the bars around the
/// application surface (and the FPS counter on top).
fn present(ud: ?*anyopaque) void {
    const v = self_(ud);
    const gfx = pd_mod.pd.graphics;
    if (v.pushed) {
        gfx.popContext();
        v.pushed = false;
    }
    const sw = v.screenW();
    const sh = v.screenH();
    const ox = @divTrunc(sw - v.app_w, 2);
    const oy = @divTrunc(sh - v.app_h, 2);
    gfx.setDrawOffset(0, 0);
    if (ox > 0 or oy > 0) {
        v.setDrawMode(.DrawModeCopy);
        gfx.clearClipRect();
        if (ox > 0) {
            gfx.fillRect(0, 0, ox, sh, black);
            gfx.fillRect(sw - ox, 0, ox, sh, black);
        }
        if (oy > 0) {
            gfx.fillRect(0, 0, sw, oy, black);
            gfx.fillRect(0, sh - oy, sw, oy, black);
        }
    }
    if (v.show_fps) {
        v.setDrawMode(.DrawModeFillWhite);
        gfx.clearClipRect();
        pd_mod.pd.system.drawFPS(0, 0);
        v.setDrawMode(.DrawModeCopy);
    }
}

fn clear(ud: ?*anyopaque, col: u32, alpha: f32) void {
    const v = self_(ud);
    pd_mod.pd.graphics.clear(if (alphaLevel(alpha) == 0) clear_colour else v.colour(col, 1.0));
}

fn spriteLoad(ud: ?*anyopaque, sprite: i32, path: [*:0]const u8, frames: i32, w: *i32, h: *i32) bool {
    const v = self_(ud);
    if (sprite < 0 or sprite >= sprite_slots or frames < 1) return false;
    const bm = loadBitmap(std.mem.span(path)) orelse return false;
    const list = pd_mod.allocZeroed(?*api.LCDBitmap, 1) orelse {
        pd_mod.pd.graphics.freeBitmap(bm);
        return false;
    };
    var bw: c_int = 0;
    var bh: c_int = 0;
    pd_mod.pd.graphics.getBitmapData(bm, &bw, &bh, null, null, null);
    list[0] = bm;
    const s = &v.sprites[@intCast(sprite)];
    if (s.table) |t| pd_mod.pd.graphics.freeBitmapTable(t);
    if (s.frames.len > 0) pd_mod.free(s.frames);
    s.* = .{
        .tried = true,
        .table = null,
        .count = 1,
        .strip_w = if (@divTrunc(bw, frames) > 0) @divTrunc(bw, frames) else bw,
        .w = bw,
        .h = bh,
        .frames = list,
    };
    w.* = s.strip_w;
    h.* = bh;
    return true;
}

fn drawImage(
    ud: ?*anyopaque,
    sprite: i32,
    frame: i32,
    sx_in: i32,
    sy: i32,
    sw_in: i32,
    sh_in: i32,
    x: f32,
    y: f32,
    xo: f32,
    yo: f32,
    xs: f32,
    ys: f32,
    angle: f32,
    col: u32,
    alpha: f32,
) void {
    const v = self_(ud);
    const gfx = pd_mod.pd.graphics;
    runtime.profile.count(.draw_images, 1);
    var sx = sx_in;
    var sw = sw_in;
    var sh = sh_in;
    if (sw <= 0 or sh <= 0) return;
    const axs = @abs(xs);
    const ays = @abs(ys);
    if (axs == 0.0 or ays == 0.0) return;
    const al = alphaLevel(alpha);
    if (al == 0) return;
    const s = v.spriteBitmaps(sprite) orelse return;
    if (s.count == 0) return;
    const fx = xs < 0.0;
    const fy = ys < 0.0;
    const fsw: f32 = @floatFromInt(sw);
    const fsh: f32 = @floatFromInt(sh);

    // Cull images fully outside the target.
    if (angle == 0.0) {
        const t = v.targetSize();
        if (t[0] > 0 and t[1] > 0) {
            const dl = ifloor(x - (if (fx) fsw - xo else xo) * axs);
            const dt = ifloor(y - (if (fy) fsh - yo else yo) * ays);
            if (dl >= t[0] or dl + iceil(fsw * axs) <= 0 or dt >= t[1] or dt + iceil(fsh * ays) <= 0) return;
        }
    }

    var index: usize = if (frame >= 0) @intCast(frame) else return;
    runtime.profile.count(.draw_blits, 1);
    if (s.strip_w > 0) {
        sx += frame * s.strip_w;
        index = 0;
    }
    const bm = Video.frameBitmap(s, index) orelse return;
    var bw = s.w;
    var bh = s.h;
    if (bw <= 0 or bh <= 0) {
        var cw: c_int = 0;
        var ch: c_int = 0;
        gfx.getBitmapData(bm, &cw, &ch, null, null, null);
        bw = cw;
        bh = ch;
        s.w = bw;
        s.h = bh;
    }
    // A frame bitmap smaller than its sprite.
    if (sx + sw > bw) sw = bw - sx;
    if (sy + sh > bh) sh = bh - sy;
    if (sw <= 0 or sh <= 0) return;
    const flip: usize = @as(usize, @intFromBool(fx)) | @as(usize, @intFromBool(fy)) << 1;
    const region = sx != 0 or sy != 0 or sw != bw or sh != bh;
    const fw: f32 = @floatFromInt(sw);
    const fh: f32 = @floatFromInt(sh);

    // Plain image: one blit.
    if (angle == 0.0 and axs == 1.0 and ays == 1.0 and !region and al == levels - 1 and tintMode(col) == .DrawModeCopy) {
        runtime.profile.count(.draw_fast, 1);
        v.setDrawMode(.DrawModeCopy);
        gfx.drawBitmap(bm, ifloor(x - (if (fx) fw - xo else xo)), ifloor(y - (if (fy) fh - yo else yo)), flips[flip]);
        return;
    }

    if (!v.beginAlpha(alpha)) return;
    defer v.endAlpha();
    const ox = (if (fx) fw - xo else xo) * axs;
    const oy = (if (fy) fh - yo else yo) * ays;
    // Offset of the region in the (flipped) bitmap.
    const rsx: f32 = @floatFromInt(if (fx) bw - sx - sw else sx);
    const rsy: f32 = @floatFromInt(if (fy) bh - sy - sh else sy);
    v.setDrawMode(tintMode(col));
    defer v.setDrawMode(.DrawModeCopy);

    if (angle == 0.0) {
        const dl = ifloor(x - ox);
        const dt = ifloor(y - oy);
        const px = dl - iround(rsx * axs);
        const py = dt - iround(rsy * ays);
        if (region) gfx.setClipRect(dl, dt, iceil(fw * axs), iceil(fh * ays));
        if (axs == 1.0 and ays == 1.0) {
            runtime.profile.count(.draw_bitmap, 1);
            gfx.drawBitmap(bm, px, py, flips[flip]);
        } else if (flip == 0) {
            runtime.profile.count(.draw_scaled, 1);
            gfx.drawScaledBitmap(bm, px, py, axs, ays);
        } else {
            runtime.profile.count(.draw_rotated, 1);
            const xs_signed = if (fx) -axs else axs;
            const ys_signed = if (fy) -ays else ays;
            const cx = (rsx + ox / axs) / @as(f32, @floatFromInt(bw));
            const cy = (rsy + oy / ays) / @as(f32, @floatFromInt(bh));
            gfx.drawRotatedBitmap(bm, iround(x), iround(y), 0.0, cx, cy, xs_signed, ys_signed);
        }
        if (region) gfx.clearClipRect();
    } else {
        runtime.profile.count(.draw_rotated, 1);
        const cx = (rsx + ox / axs) / @as(f32, @floatFromInt(bw));
        const cy = (rsy + oy / ays) / @as(f32, @floatFromInt(bh));
        const xs_signed = if (fx) -axs else axs;
        const ys_signed = if (fy) -ays else ays;
        gfx.drawRotatedBitmap(bm, iround(x), iround(y), -angle, cx, cy, xs_signed, ys_signed);
    }
}

/// draw_rectangle covers x1..x2 and y1..y2 inclusive.
fn drawRect(ud: ?*anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, col: u32, alpha: f32, outline: bool) void {
    const v = self_(ud);
    if (alphaLevel(alpha) == 0) return;
    const x = ifloor(@min(x1, x2));
    const y = ifloor(@min(y1, y2));
    const w = ifloor(@abs(x2 - x1)) + 1;
    const h = ifloor(@abs(y2 - y1)) + 1;
    const gfx = pd_mod.pd.graphics;
    if (outline) gfx.drawRect(x, y, w, h, v.colour(col, alpha)) else gfx.fillRect(x, y, w, h, v.colour(col, alpha));
}

fn drawCircle(ud: ?*anyopaque, x: f32, y: f32, r: f32, col: u32, alpha: f32, outline: bool) void {
    const v = self_(ud);
    if (r <= 0.0 or alphaLevel(alpha) == 0) return;
    const d = iround(r * 2.0);
    const left = iround(x - r);
    const top = iround(y - r);
    const gfx = pd_mod.pd.graphics;
    if (outline) {
        gfx.drawEllipse(left, top, d, d, 1, 0.0, 0.0, v.colour(col, alpha));
    } else {
        gfx.fillEllipse(left, top, d, d, 0.0, 0.0, v.colour(col, alpha));
    }
}

fn surfaceCreate(ud: ?*anyopaque, w: i32, h: i32) i32 {
    const v = self_(ud);
    if (w < 1 or h < 1) return 0;
    const i = for (1..surface_max + 1) |i| {
        if (v.surfaces[i] == null) break i;
    } else return 0;
    v.surfaces[i] = pd_mod.pd.graphics.newBitmap(w, h, clear_colour) orelse return 0;
    v.surface_size[i] = .{ w, h };
    return @intCast(i);
}

fn surfaceFree(ud: ?*anyopaque, s: i32) void {
    const v = self_(ud);
    const bm = v.surfaceAt(s) orelse return;
    if (v.target == s) {
        v.target = 0;
        v.pushTarget();
    }
    pd_mod.pd.graphics.freeBitmap(bm);
    v.surfaces[@intCast(s)] = null;
    v.surface_size[@intCast(s)] = .{ 0, 0 };
}

fn surfaceTarget(ud: ?*anyopaque, s: i32) void {
    const v = self_(ud);
    v.target = if (v.surfaceAt(s) != null) s else 0;
    v.pushTarget();
}

fn drawSurface(ud: ?*anyopaque, s: i32, x: f32, y: f32, w: f32, h: f32, alpha: f32) void {
    const v = self_(ud);
    const bm = v.surfaceAt(s) orelse return;
    if (!v.beginAlpha(alpha)) return;
    defer v.endAlpha();
    const size = v.surface_size[@intCast(s)];
    const gfx = pd_mod.pd.graphics;
    v.setDrawMode(.DrawModeCopy);
    if (iround(w) == size[0] and iround(h) == size[1]) {
        gfx.drawBitmap(bm, ifloor(x), ifloor(y), .BitmapUnflipped);
    } else {
        gfx.drawScaledBitmap(bm, ifloor(x), ifloor(y), w / @as(f32, @floatFromInt(size[0])), h / @as(f32, @floatFromInt(size[1])));
    }
}

/// The window is the application surface: the game never scales it.
fn windowSize(ud: ?*anyopaque, w: *i32, h: *i32) void {
    const v = self_(ud);
    w.* = v.app_w;
    h.* = v.app_h;
}

fn setWindowSize(_: ?*anyopaque, _: i32, _: i32) void {}

fn setFullscreen(_: ?*anyopaque, _: bool) void {}

fn ticks(_: ?*anyopaque) u32 {
    return pd_mod.pd.system.getCurrentTimeMilliseconds();
}

/// Frame pacing is the system's (setRefreshRate); blocking only stalls it.
fn delay(_: ?*anyopaque, _: u32) void {}

fn directoryExists(_: ?*anyopaque, path: [*:0]const u8) bool {
    var st: api.FileStat = undefined;
    return pd_mod.pd.file.stat(path, &st) == 0 and st.isdir != 0;
}

test "dither levels" {
    try std.testing.expectEqual(@as(usize, 0), colourLevel(0x000000));
    try std.testing.expectEqual(@as(usize, 16), colourLevel(0xFFFFFF));
    try std.testing.expectEqual(@as(usize, 0), alphaLevel(0.0));
    try std.testing.expectEqual(@as(usize, 16), alphaLevel(1.0));
    try std.testing.expectEqual(@as(usize, 8), alphaLevel(0.5));
    try std.testing.expectEqual(@as(u8, 0x00), bayerRow(0, 3));
    try std.testing.expectEqual(@as(u8, 0xFF), bayerRow(16, 3));
    // Half the bits of every row at level 8.
    for (0..8) |row| try std.testing.expectEqual(@as(u16, 4), @popCount(bayerRow(8, row)));
    try std.testing.expectEqual(api.LCDBitmapDrawMode.DrawModeFillBlack, tintMode(0x202020));
    try std.testing.expectEqual(api.LCDBitmapDrawMode.DrawModeCopy, tintMode(0xFFFFFF));
}
