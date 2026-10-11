//! SDL2 video backend: `runtime.PlatformInterface` over SDL_Renderer and
//! SDL_image. Port of the sp_platform half of packaged_src/src/host/main_sdl2.c.
//!
//! The game draws into the application surface (a target texture sized by
//! the runtime each frame), which `present` letterboxes into the window.
//! Static sprites load on first use from ASSETS/sprites/<name>/<frame>.png;
//! sprite_add strips are one texture with the frames side by side.
//! Host-side allocation (frame lists) comes from the host's arena.

const std = @import("std");
const runtime = @import("runtime");
const app_mod = @import("app");
const c = @import("sdl");

const log = std.log.scoped(.host);

const sprite_slots = runtime.sprite.MAX_SPRITES + runtime.draw.ADDED_SPRITE_MAX;
const surface_max = 64;

const SpriteTex = struct {
    tried: bool = false,
    /// Frame textures, or one strip texture when `strip_w > 0`.
    frames: []?*c.SDL_Texture = &.{},
    strip_w: i32 = 0,
};

pub const Video = struct {
    win: ?*c.SDL_Window = null,
    ren: ?*c.SDL_Renderer = null,
    app: ?*c.SDL_Texture = null,
    app_w: i32 = 0,
    app_h: i32 = 0,
    assets_dir: []const u8 = "build/assets",
    arena: std.mem.Allocator = undefined,
    sprites: [sprite_slots]SpriteTex = [_]SpriteTex{.{}} ** sprite_slots,
    /// Index 0 is unused: surface handle 0 is the application surface.
    surfaces: [surface_max + 1]?*c.SDL_Texture = [_]?*c.SDL_Texture{null} ** (surface_max + 1),
    /// Saved (BMP) on the next present when `want_shot`.
    screenshot: ?[:0]const u8 = null,
    want_shot: bool = false,

    pub const Error = error{ NoWindow, NoRenderer };

    /// Opens a resizable window and an accelerated renderer (software as a
    /// fallback, e.g. SDL_VIDEODRIVER=offscreen).
    pub fn open(self: *Video, title: [:0]const u8, w: c_int, h: c_int) Error!void {
        _ = c.SDL_SetHint(c.SDL_HINT_RENDER_SCALE_QUALITY, "0");
        self.win = c.SDL_CreateWindow(title.ptr, c.sp_windowpos_centered, c.sp_windowpos_centered, w, h, c.SDL_WINDOW_RESIZABLE) orelse
            return error.NoWindow;
        self.ren = c.SDL_CreateRenderer(self.win, -1, c.SDL_RENDERER_ACCELERATED | c.SDL_RENDERER_TARGETTEXTURE) orelse
            c.SDL_CreateRenderer(self.win, -1, c.SDL_RENDERER_SOFTWARE) orelse
            return error.NoRenderer;
    }

    pub fn close(self: *Video) void {
        for (&self.sprites) |*s| {
            for (s.frames) |t| if (t) |tex| c.SDL_DestroyTexture(tex);
            s.* = .{};
        }
        for (&self.surfaces) |*s| {
            if (s.*) |tex| c.SDL_DestroyTexture(tex);
            s.* = null;
        }
        if (self.app) |t| c.SDL_DestroyTexture(t);
        self.app = null;
        if (self.ren) |r| c.SDL_DestroyRenderer(r);
        self.ren = null;
        if (self.win) |w| c.SDL_DestroyWindow(w);
        self.win = null;
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
            .display_size_fn = displaySize,
            .set_window_size_fn = setWindowSize,
            .set_fullscreen_fn = setFullscreen,
            .get_ticks_ms_fn = ticks,
            .delay_ms_fn = delay,
        };
    }

    fn loadTexture(self: *Video, path: [*:0]const u8) ?*c.SDL_Texture {
        const t = c.IMG_LoadTexture(self.ren, path) orelse return null;
        _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
        return t;
    }

    /// Texture of a sprite frame; `xoff` is the frame's x in a strip.
    fn frameTexture(self: *Video, sprite: i32, frame: i32, xoff: *i32) ?*c.SDL_Texture {
        xoff.* = 0;
        if (sprite < 0 or sprite >= sprite_slots) return null;
        const s = &self.sprites[@intCast(sprite)];
        if (!s.tried) {
            s.tried = true;
            self.loadFrames(s, sprite);
        }
        if (s.strip_w > 0) {
            xoff.* = frame * s.strip_w;
            return if (s.frames.len > 0) s.frames[0] else null;
        }
        return if (frame >= 0 and frame < s.frames.len) s.frames[@intCast(frame)] else null;
    }

    fn loadFrames(self: *Video, s: *SpriteTex, sprite: i32) void {
        const def = runtime.SpriteRegistry.get().getSprite(sprite) orelse return;
        if (def.frame_count <= 0) return;
        const frames = self.arena.alloc(?*c.SDL_Texture, @intCast(def.frame_count)) catch return;
        for (frames, 0..) |*t, i| {
            var buf: [1024]u8 = undefined;
            const path = std.fmt.bufPrintZ(&buf, "{s}/sprites/{s}/{d}.png", .{ self.assets_dir, def.name, i }) catch {
                t.* = null;
                continue;
            };
            t.* = self.loadTexture(path.ptr);
        }
        s.frames = frames;
    }

    fn saveScreenshot(self: *Video, path: [:0]const u8) void {
        const s = c.SDL_CreateRGBSurfaceWithFormat(0, self.app_w, self.app_h, 32, c.SDL_PIXELFORMAT_ARGB8888) orelse return;
        defer c.SDL_FreeSurface(s);
        _ = c.SDL_SetRenderTarget(self.ren, self.app);
        if (c.SDL_RenderReadPixels(self.ren, null, c.SDL_PIXELFORMAT_ARGB8888, s.*.pixels, s.*.pitch) == 0 and
            c.SDL_SaveBMP_RW(s, c.SDL_RWFromFile(path.ptr, "wb"), 1) == 0)
        {
            log.info("saved {s} ({d}x{d})", .{ path, self.app_w, self.app_h });
        }
    }
};

// ---- PlatformInterface entries -----------------------------------------------

fn self_(ud: ?*anyopaque) *Video {
    return @ptrCast(@alignCast(ud.?));
}

fn byte(alpha: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(alpha, 0.0, 1.0) * 255.0));
}

/// GameMaker colours are 0xBBGGRR.
fn rgb(col: u32) [3]u8 {
    return .{ @truncate(col), @truncate(col >> 8), @truncate(col >> 16) };
}

fn colourMod(t: *c.SDL_Texture, col: u32, alpha: f32) void {
    const v = rgb(col);
    _ = c.SDL_SetTextureColorMod(t, v[0], v[1], v[2]);
    _ = c.SDL_SetTextureAlphaMod(t, byte(alpha));
}

fn drawColour(v: *Video, col: u32, alpha: f32) void {
    const x = rgb(col);
    _ = c.SDL_SetRenderDrawBlendMode(v.ren, c.SDL_BLENDMODE_BLEND);
    _ = c.SDL_SetRenderDrawColor(v.ren, x[0], x[1], x[2], byte(alpha));
}

fn beginFrame(ud: ?*anyopaque, w_in: i32, h_in: i32) void {
    const v = self_(ud);
    const w = if (w_in < 1 or h_in < 1) 320 else w_in;
    const h = if (w_in < 1 or h_in < 1) 240 else h_in;
    if (v.app == null or w != v.app_w or h != v.app_h) {
        if (v.app) |t| c.SDL_DestroyTexture(t);
        v.app = c.SDL_CreateTexture(v.ren, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_TARGET, w, h);
        v.app_w = w;
        v.app_h = h;
    }
    _ = c.SDL_SetRenderTarget(v.ren, v.app);
}

/// The application surface, scaled to fit and centred (letterboxed).
fn present(ud: ?*anyopaque) void {
    const v = self_(ud);
    if (v.want_shot) {
        if (v.screenshot) |path| v.saveScreenshot(path);
        v.want_shot = false;
    }
    _ = c.SDL_SetRenderTarget(v.ren, null);
    _ = c.SDL_SetRenderDrawColor(v.ren, 0, 0, 0, 255);
    _ = c.SDL_RenderClear(v.ren);
    var ww: c_int = 0;
    var wh: c_int = 0;
    _ = c.SDL_GetRendererOutputSize(v.ren, &ww, &wh);
    const r = app_mod.letterbox(v.app_w, v.app_h, ww, wh);
    const dst: c.SDL_FRect = .{ .x = r.x, .y = r.y, .w = r.w, .h = r.h };
    _ = c.SDL_RenderCopyF(v.ren, v.app, null, &dst);
    c.SDL_RenderPresent(v.ren);
}

/// RenderClear writes the colour as is (no blending), alpha included.
fn clear(ud: ?*anyopaque, col: u32, alpha: f32) void {
    const v = self_(ud);
    const x = rgb(col);
    _ = c.SDL_SetRenderDrawColor(v.ren, x[0], x[1], x[2], byte(alpha));
    _ = c.SDL_RenderClear(v.ren);
}

fn spriteLoad(ud: ?*anyopaque, sprite: i32, path: [*:0]const u8, frames: i32, w: *i32, h: *i32) bool {
    const v = self_(ud);
    if (sprite < 0 or sprite >= sprite_slots or frames < 1) return false;
    const t = v.loadTexture(path) orelse return false;
    var tw: c_int = 0;
    var th: c_int = 0;
    _ = c.SDL_QueryTexture(t, null, null, &tw, &th);
    const list = v.arena.alloc(?*c.SDL_Texture, 1) catch {
        c.SDL_DestroyTexture(t);
        return false;
    };
    list[0] = t;
    const s = &v.sprites[@intCast(sprite)];
    s.* = .{ .tried = true, .frames = list, .strip_w = if (@divTrunc(tw, frames) > 0) @divTrunc(tw, frames) else tw };
    w.* = s.strip_w;
    h.* = th;
    return true;
}

fn drawImage(
    ud: ?*anyopaque,
    sprite: i32,
    frame: i32,
    sx: i32,
    sy: i32,
    sw: i32,
    sh: i32,
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
    var xoff: i32 = 0;
    const t = v.frameTexture(sprite, frame, &xoff) orelse return;
    const axs = @abs(xs);
    const ays = @abs(ys);
    if (sw <= 0 or sh <= 0 or axs == 0.0 or ays == 0.0) return;
    var tw: c_int = 0;
    var th: c_int = 0;
    _ = c.SDL_QueryTexture(t, null, null, &tw, &th);
    var src: c.SDL_Rect = .{ .x = sx + xoff, .y = sy, .w = sw, .h = sh };
    // A frame PNG smaller than its sprite.
    if (src.x + src.w > tw) src.w = tw - src.x;
    if (src.y + src.h > th) src.h = th - src.y;
    if (src.w <= 0 or src.h <= 0) return;
    const ox = (if (xs < 0.0) @as(f32, @floatFromInt(sw)) - xo else xo) * axs;
    const oy = (if (ys < 0.0) @as(f32, @floatFromInt(sh)) - yo else yo) * ays;
    var flip: c_uint = c.SDL_FLIP_NONE;
    if (xs < 0.0) flip |= c.SDL_FLIP_HORIZONTAL;
    if (ys < 0.0) flip |= c.SDL_FLIP_VERTICAL;
    const dst: c.SDL_FRect = .{
        .x = x - ox,
        .y = y - oy,
        .w = @as(f32, @floatFromInt(src.w)) * axs,
        .h = @as(f32, @floatFromInt(src.h)) * ays,
    };
    const centre: c.SDL_FPoint = .{ .x = ox, .y = oy };
    colourMod(t, col, alpha);
    _ = c.SDL_RenderCopyExF(v.ren, t, &src, &dst, -@as(f64, angle), &centre, @intCast(flip));
}

/// draw_rectangle covers x1..x2 and y1..y2 inclusive.
fn drawRect(ud: ?*anyopaque, x1: f32, y1: f32, x2: f32, y2: f32, col: u32, alpha: f32, outline: bool) void {
    const v = self_(ud);
    const r: c.SDL_FRect = .{ .x = @min(x1, x2), .y = @min(y1, y2), .w = @abs(x2 - x1) + 1.0, .h = @abs(y2 - y1) + 1.0 };
    drawColour(v, col, alpha);
    _ = if (outline) c.SDL_RenderDrawRectF(v.ren, &r) else c.SDL_RenderFillRectF(v.ren, &r);
}

fn drawCircle(ud: ?*anyopaque, x: f32, y: f32, r: f32, col: u32, alpha: f32, outline: bool) void {
    const v = self_(ud);
    drawColour(v, col, alpha);
    if (r <= 0.0) return;
    if (outline) {
        var pts: [49]c.SDL_FPoint = undefined;
        for (&pts, 0..) |*p, i| {
            const a: f32 = @floatCast(@as(f64, @floatFromInt(i)) * (2.0 * std.math.pi / 48.0));
            p.* = .{ .x = x + r * @cos(a), .y = y + r * @sin(a) };
        }
        _ = c.SDL_RenderDrawLinesF(v.ren, &pts, pts.len);
    } else {
        var dy = -@floor(r);
        while (dy <= @floor(r)) : (dy += 1.0) {
            const dx = @sqrt(r * r - dy * dy);
            _ = c.SDL_RenderDrawLineF(v.ren, x - dx, y + dy, x + dx, y + dy);
        }
    }
}

fn surfaceCreate(ud: ?*anyopaque, w: i32, h: i32) i32 {
    const v = self_(ud);
    const i = for (1..surface_max + 1) |i| {
        if (v.surfaces[i] == null) break i;
    } else return 0;
    const t = c.SDL_CreateTexture(v.ren, c.SDL_PIXELFORMAT_ARGB8888, c.SDL_TEXTUREACCESS_TARGET, w, h) orelse return 0;
    _ = c.SDL_SetTextureBlendMode(t, c.SDL_BLENDMODE_BLEND);
    const prev = c.SDL_GetRenderTarget(v.ren);
    _ = c.SDL_SetRenderTarget(v.ren, t);
    _ = c.SDL_SetRenderDrawColor(v.ren, 0, 0, 0, 0);
    _ = c.SDL_RenderClear(v.ren);
    _ = c.SDL_SetRenderTarget(v.ren, prev);
    v.surfaces[i] = t;
    return @intCast(i);
}

fn surfaceAt(v: *Video, s: i32) ?*c.SDL_Texture {
    return if (s >= 1 and s <= surface_max) v.surfaces[@intCast(s)] else null;
}

fn surfaceFree(ud: ?*anyopaque, s: i32) void {
    const v = self_(ud);
    const t = surfaceAt(v, s) orelse return;
    c.SDL_DestroyTexture(t);
    v.surfaces[@intCast(s)] = null;
}

fn surfaceTarget(ud: ?*anyopaque, s: i32) void {
    const v = self_(ud);
    _ = c.SDL_SetRenderTarget(v.ren, surfaceAt(v, s) orelse v.app);
}

fn drawSurface(ud: ?*anyopaque, s: i32, x: f32, y: f32, w: f32, h: f32, alpha: f32) void {
    const v = self_(ud);
    const t = surfaceAt(v, s) orelse return;
    const dst: c.SDL_FRect = .{ .x = x, .y = y, .w = w, .h = h };
    colourMod(t, 0xFFFFFF, alpha);
    _ = c.SDL_RenderCopyF(v.ren, t, null, &dst);
}

fn windowSize(ud: ?*anyopaque, w: *i32, h: *i32) void {
    c.SDL_GetWindowSize(self_(ud).win, w, h);
}

fn displaySize(_: ?*anyopaque, w: *i32, h: *i32) void {
    var m: c.SDL_DisplayMode = undefined;
    if (c.SDL_GetDesktopDisplayMode(0, &m) == 0 and m.w > 0 and m.h > 0) {
        w.* = m.w;
        h.* = m.h;
    } else {
        // Offscreen / dummy drivers report nothing useful.
        w.* = 1920;
        h.* = 1080;
    }
}

fn setWindowSize(ud: ?*anyopaque, w: i32, h: i32) void {
    const v = self_(ud);
    c.SDL_SetWindowSize(v.win, w, h);
    c.SDL_SetWindowPosition(v.win, c.sp_windowpos_centered, c.sp_windowpos_centered);
}

fn setFullscreen(ud: ?*anyopaque, on: bool) void {
    _ = c.SDL_SetWindowFullscreen(self_(ud).win, if (on) c.SDL_WINDOW_FULLSCREEN_DESKTOP else 0);
}

fn ticks(_: ?*anyopaque) u32 {
    return c.SDL_GetTicks();
}

fn delay(_: ?*anyopaque, ms: u32) void {
    c.SDL_Delay(ms);
}
