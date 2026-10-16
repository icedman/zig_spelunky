//! GameMaker drawing pipeline on top of PlatformInterface.
//! Follows Function_Texture.js, Function_Graphics.js, Function_Surface.js, Function_Font.js,
//! and packaged_src/src/runtime/gm_draw.c. Fully supports headless execution.

const std = @import("std");
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const layer_mod = @import("layer.zig");
const Layer = layer_mod.Layer;
const LayerManager = layer_mod.LayerManager;
const ELEMENT_BACKGROUND = layer_mod.ELEMENT_BACKGROUND;
const ELEMENT_TILE = layer_mod.ELEMENT_TILE;
const sprite_mod = @import("sprite.zig");
const SpriteRegistry = sprite_mod.SpriteRegistry;
const MAX_SPRITES = sprite_mod.MAX_SPRITES;
const view_mod = @import("view.zig");
const ViewManager = view_mod.ViewManager;
const ViewField = view_mod.ViewField;
const room_mod = @import("room.zig");
const RoomManager = room_mod.RoomManager;
const platform_mod = @import("platform.zig");
const PlatformInterface = platform_mod.PlatformInterface;
const profile = @import("profile.zig");

pub const APP_SURFACE: i32 = 0;
pub const SURFACE_MAX: usize = 32;
pub const ADDED_SPRITE_MAX: usize = 64;
pub const FONT_MAX: usize = 16;
pub const TARGET_STACK: usize = 8;

pub const Xform = struct {
    sx: f32 = 1.0,
    sy: f32 = 1.0,
    tx: f32 = 0.0,
    ty: f32 = 0.0,
    wx: f32 = 0.0,
    wy: f32 = 0.0,
    ww: f32 = 0.0,
    wh: f32 = 0.0,
};

pub const Surface = struct {
    used: bool = false,
    handle: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
};

pub const AddedSprite = struct {
    used: bool = false,
    frames: i32 = 1,
    w: i32 = 0,
    h: i32 = 0,
    xorig: f32 = 0.0,
    yorig: f32 = 0.0,
};

/// Monospaced sprite font (font_add_sprite with a contiguous charset): frame
/// `c - first` is the glyph of character `c`, the frame size is the cell.
/// The runtime lays the text out and draws the glyphs through `draw_image_fn`,
/// so a host needs no text support of its own.
pub const SpriteFont = struct {
    sprite: i32,
    /// Character of frame 0.
    first: u8 = ' ',
};

/// A font id's face: drawn by the host (`font_load_fn` / `draw_text_fn`) or a
/// sprite font drawn by the runtime.
pub const Font = union(enum) {
    host: i32,
    sprite: SpriteFont,
};

const Glyphs = struct {
    frames: i32,
    w: i32,
    h: i32,
};

pub const DrawManager = struct {
    colour: u32 = 0x00FFFFFF,
    alpha: f32 = 1.0,
    font: i32 = -1,

    app_w: i32 = 0,
    app_h: i32 = 0,
    base_app_w: i32 = 0,
    base_app_h: i32 = 0,
    viewport_scale: f32 = 1.0,
    gui_w: i32 = 0,
    gui_h: i32 = 0,

    xf: Xform = .{},
    stack: [TARGET_STACK]Xform = [_]Xform{.{}} ** TARGET_STACK,
    stack_target: [TARGET_STACK]i32 = [_]i32{0} ** TARGET_STACK,
    stack_depth: usize = 0,
    target: i32 = APP_SURFACE,

    surfaces: [SURFACE_MAX]Surface = [_]Surface{.{}} ** SURFACE_MAX,
    added_sprites: [ADDED_SPRITE_MAX]AddedSprite = [_]AddedSprite{.{}} ** ADDED_SPRITE_MAX,
    fonts: [FONT_MAX]Font = [_]Font{.{ .host = 0 }} ** FONT_MAX,
    font_count: usize = 0,
    /// Font drawn when draw_set_font names no font; null = the host's default
    /// face (`draw_text_fn` handle 0).
    default_font: ?i32 = null,

    overflow_count: usize = 0,
    backend: PlatformInterface = .{},
    headless_surface_counter: i32 = 0,

    /// Between beginFrame and endFrame (the draw pipeline).
    in_frame: bool = false,
    /// Drop draws to the screen made outside the draw pipeline (e.g. in a
    /// step event). beginFrame clears the screen, so they are never seen;
    /// draws into game surfaces are kept. Opt-in (Playdate host): the
    /// headless parity tests see every backend call.
    skip_unseen: bool = false,
    /// Screen draws dropped by `skip_unseen` (diagnostics).
    unseen_skipped: usize = 0,

    /// HACK (draw_alt): size, in application-surface pixels, of the part of
    /// the frame the host actually shows, centred (e.g. the Playdate at 2x
    /// shows 200 x 120 of 320 x 240). When set, views re-centre on their
    /// follow object and cull to this window. 0 = off.
    follow_w: i32 = 0,
    follow_h: i32 = 0,
    /// HACK (draw_alt): extra scale of text drawn in the world pass (the
    /// HUD); GUI text is unaffected.
    world_text_scale: f32 = 1.0,
    /// Scale applied to draw_text right now (set by the draw pipeline).
    text_scale: f32 = 1.0,

    win_w: i32 = 640,
    win_h: i32 = 480,
    is_fullscreen: bool = false,

    var instance: DrawManager = .{};

    pub fn get() *DrawManager {
        return &instance;
    }

    pub fn setBackend(self: *DrawManager, backend: PlatformInterface) void {
        self.backend = backend;
    }

    fn identity(self: *DrawManager, w: f32, h: f32) void {
        self.xf = .{
            .sx = 1.0,
            .sy = 1.0,
            .tx = 0.0,
            .ty = 0.0,
            .wx = 0.0,
            .wy = 0.0,
            .ww = w,
            .wh = h,
        };
    }

    pub fn reset(self: *DrawManager) void {
        self.colour = 0x00FFFFFF;
        self.alpha = 1.0;
        self.font = -1;
        self.app_w = 0;
        self.app_h = 0;
        self.gui_w = 0;
        self.gui_h = 0;
        self.stack_depth = 0;
        self.target = APP_SURFACE;
        @memset(&self.surfaces, Surface{});
        @memset(&self.added_sprites, AddedSprite{});
        self.font_count = 0;
        self.default_font = null;
        self.overflow_count = 0;
        self.headless_surface_counter = 0;
        self.identity(0.0, 0.0);
    }

    pub fn setColour(self: *DrawManager, col: f32) void {
        const c: i32 = @intFromFloat(col);
        self.colour = @as(u32, @bitCast(c)) & 0x00FFFFFF;
    }

    pub fn setAlpha(self: *DrawManager, a: f32) void {
        self.alpha = @min(1.0, @max(0.0, a));
    }

    pub fn setFont(self: *DrawManager, f: i32) void {
        self.font = f;
    }

    pub fn getColour(self: *const DrawManager) u32 {
        return self.colour;
    }

    pub fn getAlpha(self: *const DrawManager) f32 {
        return self.alpha;
    }

    fn defaultAppSize(self: *DrawManager) void {
        if (self.app_w > 0 and self.app_h > 0) return;
        const vm = ViewManager.get();
        if (vm.enabled() and vm.getViewVar(ViewField.wport, 0) > 0.0 and vm.getViewVar(ViewField.hport, 0) > 0.0) {
            const pw = vm.getViewVar(ViewField.wport, 0);
            const ph = vm.getViewVar(ViewField.hport, 0);
            self.base_app_w = @intFromFloat(pw);
            self.base_app_h = @intFromFloat(ph);
            self.app_w = @intFromFloat(pw * self.viewport_scale);
            self.app_h = @intFromFloat(ph * self.viewport_scale);
        } else {
            const rw = RoomManager.get().getWidth();
            const rh = RoomManager.get().getHeight();
            self.base_app_w = @intFromFloat(rw);
            self.base_app_h = @intFromFloat(rh);
            self.app_w = @intFromFloat(rw * self.viewport_scale);
            self.app_h = @intFromFloat(rh * self.viewport_scale);
        }
    }

    /// True for a screen draw that cannot be seen (see `skip_unseen`).
    fn unseen(self: *DrawManager) bool {
        if (!self.skip_unseen or self.in_frame or self.target != APP_SURFACE) return false;
        self.unseen_skipped +%= 1;
        profile.count(.unseen_draws, 1);
        return true;
    }

    pub fn beginFrame(self: *DrawManager) void {
        self.in_frame = true;
        self.defaultAppSize();
        self.stack_depth = 0;
        self.target = APP_SURFACE;
        if (self.backend.begin_frame_fn) |bf| {
            bf(self.backend.user_data, self.app_w, self.app_h);
        }
        if (self.backend.clear_fn) |c| {
            c(self.backend.user_data, 0x000000, 1.0);
        }
    }

    pub fn passView(self: *DrawManager, view_idx: usize) void {
        const vm = ViewManager.get();
        const cam_id: i32 = @intFromFloat(vm.getViewVar(ViewField.camera, view_idx));
        const cam = vm.cameraGet(cam_id);
        const cw = if (cam != null and cam.?.w > 0.0) cam.?.w else 1.0;
        const ch = if (cam != null and cam.?.h > 0.0) cam.?.h else 1.0;
        const cx = if (cam != null) cam.?.x else 0.0;
        const cy = if (cam != null) cam.?.y else 0.0;

        const pw = vm.getViewVar(ViewField.wport, view_idx) * self.viewport_scale;
        const ph = vm.getViewVar(ViewField.hport, view_idx) * self.viewport_scale;
        const px = vm.getViewVar(ViewField.xport, view_idx) * self.viewport_scale;
        const py = vm.getViewVar(ViewField.yport, view_idx) * self.viewport_scale;

        self.xf.sx = pw / cw;
        self.xf.sy = ph / ch;
        self.xf.tx = px - cx * self.xf.sx;
        self.xf.ty = py - cy * self.xf.sy;
        self.xf.wx = cx;
        self.xf.wy = cy;
        self.xf.ww = cw;
        self.xf.wh = ch;
    }

    pub fn passRoom(self: *DrawManager) void {
        const rw = RoomManager.get().getWidth();
        const rh = RoomManager.get().getHeight();
        self.identity(rw, rh);
        self.xf.sx = self.viewport_scale;
        self.xf.sy = self.viewport_scale;
    }

    pub fn passGui(self: *DrawManager) void {
        if (self.gui_w <= 0 or self.gui_h <= 0) {
            self.gui_w = if (self.base_app_w > 0) self.base_app_w else self.app_w;
            self.gui_h = if (self.base_app_h > 0) self.base_app_h else self.app_h;
        }
        const gw = if (self.gui_w > 0) @as(f32, @floatFromInt(self.gui_w)) else 1.0;
        const gh = if (self.gui_h > 0) @as(f32, @floatFromInt(self.gui_h)) else 1.0;
        const aw = @as(f32, @floatFromInt(self.app_w));
        const ah = @as(f32, @floatFromInt(self.app_h));

        self.xf.sx = aw / gw;
        self.xf.sy = ah / gh;
        self.xf.tx = 0.0;
        self.xf.ty = 0.0;
        self.xf.wx = 0.0;
        self.xf.wy = 0.0;
        self.xf.ww = gw;
        self.xf.wh = gh;
    }

    pub fn endFrame(self: *DrawManager) void {
        while (self.stack_depth > 0) {
            _ = self.surfaceResetTarget();
        }
        if (self.backend.present_fn) |pres| {
            pres(self.backend.user_data);
        }
        self.in_frame = false;
    }

    pub fn appWidth(self: *const DrawManager) i32 {
        return self.app_w;
    }

    pub fn appHeight(self: *const DrawManager) i32 {
        return self.app_h;
    }

    pub fn setViewportScale(self: *DrawManager, scale: f32) void {
        if (scale <= 0.0) return;
        self.viewport_scale = scale;
        if (self.base_app_w > 0 and self.base_app_h > 0) {
            self.app_w = @intFromFloat(@as(f32, @floatFromInt(self.base_app_w)) * self.viewport_scale);
            self.app_h = @intFromFloat(@as(f32, @floatFromInt(self.base_app_h)) * self.viewport_scale);
        }
    }

    pub fn getViewportScale(self: *const DrawManager) f32 {
        return self.viewport_scale;
    }

    fn frameOf(subimg: f32, frames: i32) i32 {
        if (subimg >= 0.0 and subimg < @as(f32, @floatFromInt(frames))) {
            return @intFromFloat(subimg);
        }
        const f = @floor(subimg);
        if (std.math.isNan(f) or frames <= 0) {
            return 0;
        }
        const m = @mod(f, @as(f32, @floatFromInt(frames)));
        var i: i32 = @intFromFloat(m);
        if (i < 0) i += frames;
        return i;
    }

    /// True if an image cannot touch the visible world rectangle of the
    /// current pass (xf.wx/wy/ww/wh: view, room, GUI or surface). World
    /// coordinates; (xo, yo) is the origin inside the w x h image. Rotated
    /// images use the circle around the origin that holds every corner.
    /// Conservative (1 px margin), so nothing visible is ever dropped.
    fn offscreen(self: *const DrawManager, x: f32, y: f32, xo: f32, yo: f32, w: f32, h: f32, xs: f32, ys: f32, angle: f32) bool {
        return self.offscreenMargin(x, y, xo, yo, w, h, xs, ys, angle, 1.0);
    }

    pub fn offscreenMargin(self: *const DrawManager, x: f32, y: f32, xo: f32, yo: f32, w: f32, h: f32, xs: f32, ys: f32, angle: f32, margin: f32) bool {
        return self.boxOffscreen(imageBox(x, y, xo, yo, w, h, xs, ys, angle), margin);
    }

    /// True if a world box (left, top, right, bottom) cannot touch the
    /// visible world rectangle of the current pass, with `margin`.
    /// NaN-safe: any comparison with NaN is false, so the box is kept.
    pub inline fn boxOffscreen(self: *const DrawManager, box: [4]f32, margin: f32) bool {
        if (!(self.xf.ww > 0.0 and self.xf.wh > 0.0)) return false;
        return box[2] < self.xf.wx - margin or box[0] > self.xf.wx + self.xf.ww + margin or
            box[3] < self.xf.wy - margin or box[1] > self.xf.wy + self.xf.wh + margin;
    }

    /// World box of an image; rotated images use the circle around the
    /// origin that holds every corner.
    fn imageBox(x: f32, y: f32, xo: f32, yo: f32, w: f32, h: f32, xs: f32, ys: f32, angle: f32) [4]f32 {
        var l: f32 = undefined;
        var r: f32 = undefined;
        var t: f32 = undefined;
        var b: f32 = undefined;
        if (angle == 0.0) {
            const x0 = x - xo * xs;
            const x1 = x + (w - xo) * xs;
            const y0 = y - yo * ys;
            const y1 = y + (h - yo) * ys;
            l = @min(x0, x1);
            r = @max(x0, x1);
            t = @min(y0, y1);
            b = @max(y0, y1);
        } else {
            const dx = @max(@abs(xo), @abs(w - xo)) * @abs(xs);
            const dy = @max(@abs(yo), @abs(h - yo)) * @abs(ys);
            const rad = @sqrt(dx * dx + dy * dy);
            l = x - rad;
            r = x + rad;
            t = y - rad;
            b = y + rad;
        }
        return .{ l, t, r, b };
    }

    /// True if an instance's sprite bounds cannot touch the visible viewport (with margin).
    /// Instances without a sprite or with invalid dimensions return false (not culled).
    pub fn instanceOffscreen(self: *const DrawManager, inst: *const Instance, margin: f32) bool {
        if (!(self.xf.ww > 0.0 and self.xf.wh > 0.0)) return false;
        const box = self.instanceBox(inst) orelse return false;
        return self.boxOffscreen(box, margin);
    }

    /// World box of an instance's sprite (null: no sprite / unknown size,
    /// never culled).
    pub fn instanceBox(self: *const DrawManager, inst: *const Instance) ?[4]f32 {
        const sprite = inst.sprite_index;
        var w: f32 = 0.0;
        var h: f32 = 0.0;
        var xo: f32 = 0.0;
        var yo: f32 = 0.0;
        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            if (SpriteRegistry.get().getSprite(sprite)) |spr| {
                if (spr.frame_count <= 0 or spr.width <= 0 or spr.height <= 0) return null;
                w = @floatFromInt(spr.width);
                h = @floatFromInt(spr.height);
                xo = @floatFromInt(spr.xorigin);
                yo = @floatFromInt(spr.yorigin);
            } else return null;
        } else if (sprite >= @as(i32, @intCast(MAX_SPRITES)) and @as(usize, @intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))) < ADDED_SPRITE_MAX) {
            const added = &self.added_sprites[@intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))];
            if (!added.used or added.frames <= 0 or added.w <= 0 or added.h <= 0) return null;
            w = @floatFromInt(added.w);
            h = @floatFromInt(added.h);
            xo = added.xorig;
            yo = added.yorig;
        } else return null;

        return imageBox(inst.x, inst.y, xo, yo, w, h, inst.image_xscale, inst.image_yscale, inst.image_angle);
    }

    pub fn drawSpriteExt(
        self: *DrawManager,
        sprite: i32,
        subimg: f32,
        x: f32,
        y: f32,
        xscale: f32,
        yscale: f32,
        angle: f32,
        col: f32,
        a: f32,
    ) void {
        const draw_fn = self.backend.draw_image_fn orelse return;
        if (self.unseen()) return;

        var frames: i32 = 1;
        var w: i32 = 0;
        var h: i32 = 0;
        var xo: f32 = 0.0;
        var yo: f32 = 0.0;

        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            if (SpriteRegistry.get().getSprite(sprite)) |spr| {
                frames = spr.frame_count;
                w = spr.width;
                h = spr.height;
                xo = @floatFromInt(spr.xorigin);
                yo = @floatFromInt(spr.yorigin);
            } else return;
        } else if (sprite >= @as(i32, @intCast(MAX_SPRITES)) and @as(usize, @intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))) < ADDED_SPRITE_MAX) {
            const added = &self.added_sprites[@intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))];
            if (!added.used) return;
            frames = added.frames;
            w = added.w;
            h = added.h;
            xo = added.xorig;
            yo = added.yorig;
        } else return;

        if (frames <= 0) return;
        if (self.offscreen(x, y, xo, yo, @floatFromInt(w), @floatFromInt(h), xscale, yscale, angle)) return;
        const frame = frameOf(subimg, frames);

        const tx = x * self.xf.sx + self.xf.tx;
        const ty = y * self.xf.sy + self.xf.ty;
        const xs = xscale * self.xf.sx;
        const ys = yscale * self.xf.sy;
        const blend = @as(u32, @bitCast(@as(i32, @intFromFloat(col)))) & 0x00FFFFFF;
        const alpha_clamped = @min(1.0, @max(0.0, a));

        draw_fn(
            self.backend.user_data,
            sprite,
            frame,
            0,
            0,
            w,
            h,
            tx,
            ty,
            xo,
            yo,
            xs,
            ys,
            angle,
            blend,
            alpha_clamped,
        );
    }

    pub fn drawSprite(self: *DrawManager, sprite: i32, subimg: f32, x: f32, y: f32) void {
        self.drawSpriteExt(sprite, subimg, x, y, 1.0, 1.0, 0.0, 16777215.0, self.alpha);
    }

    pub fn drawSpriteStretched(self: *DrawManager, sprite: i32, subimg: f32, x: f32, y: f32, w: f32, h: f32) void {
        const draw_fn = self.backend.draw_image_fn orelse return;
        if (self.unseen()) return;

        var frames: i32 = 1;
        var sw: i32 = 0;
        var sh: i32 = 0;

        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            if (SpriteRegistry.get().getSprite(sprite)) |spr| {
                frames = spr.frame_count;
                sw = spr.width;
                sh = spr.height;
            } else return;
        } else if (sprite >= @as(i32, @intCast(MAX_SPRITES)) and @as(usize, @intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))) < ADDED_SPRITE_MAX) {
            const added = &self.added_sprites[@intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))];
            if (!added.used) return;
            frames = added.frames;
            sw = added.w;
            sh = added.h;
        } else return;

        if (frames <= 0 or sw <= 0 or sh <= 0) return;
        if (self.offscreen(x, y, 0.0, 0.0, w, h, 1.0, 1.0, 0.0)) return;
        const frame = frameOf(subimg, frames);

        const tx = x * self.xf.sx + self.xf.tx;
        const ty = y * self.xf.sy + self.xf.ty;
        const xs = (w / @as(f32, @floatFromInt(sw))) * self.xf.sx;
        const ys = (h / @as(f32, @floatFromInt(sh))) * self.xf.sy;

        draw_fn(
            self.backend.user_data,
            sprite,
            frame,
            0,
            0,
            sw,
            sh,
            tx,
            ty,
            0.0,
            0.0,
            xs,
            ys,
            0.0,
            0x00FFFFFF,
            self.alpha,
        );
    }

    pub fn drawSelf(self: *DrawManager, inst: ?*Instance) void {
        const target_inst = inst orelse return;
        if (self.unseen()) return;
        const sprite = target_inst.sprite_index;
        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            if (SpriteRegistry.get().getSprite(sprite)) |spr| {
                if (spr.frame_count <= 0) return;
                const draw_fn = self.backend.draw_image_fn orelse return;
                if (self.offscreen(
                    target_inst.x,
                    target_inst.y,
                    @floatFromInt(spr.xorigin),
                    @floatFromInt(spr.yorigin),
                    @floatFromInt(spr.width),
                    @floatFromInt(spr.height),
                    target_inst.image_xscale,
                    target_inst.image_yscale,
                    target_inst.image_angle,
                )) return;
                const frame = frameOf(target_inst.image_index, spr.frame_count);
                const alpha = @min(1.0, @max(0.0, target_inst.image_alpha));
                const blend = target_inst.image_blend & 0x00FFFFFF;

                const tx = target_inst.x * self.xf.sx + self.xf.tx;
                const ty = target_inst.y * self.xf.sy + self.xf.ty;
                const xs = target_inst.image_xscale * self.xf.sx;
                const ys = target_inst.image_yscale * self.xf.sy;

                draw_fn(
                    self.backend.user_data,
                    sprite,
                    frame,
                    0,
                    0,
                    spr.width,
                    spr.height,
                    tx,
                    ty,
                    @floatFromInt(spr.xorigin),
                    @floatFromInt(spr.yorigin),
                    xs,
                    ys,
                    target_inst.image_angle,
                    blend,
                    alpha,
                );
                return;
            }
        }
        self.drawSpriteExt(
            sprite,
            target_inst.image_index,
            target_inst.x,
            target_inst.y,
            target_inst.image_xscale,
            target_inst.image_yscale,
            target_inst.image_angle,
            @floatFromInt(target_inst.image_blend),
            target_inst.image_alpha,
        );
    }

    fn fontOf(self: *const DrawManager, id: i32) ?Font {
        return if (id >= 0 and @as(usize, @intCast(id)) < self.font_count) self.fonts[@intCast(id)] else null;
    }

    /// draw_text (Function_Font.js L59): draw colour and alpha, left/top aligned.
    pub fn drawText(self: *DrawManager, x: f32, y: f32, text: [*:0]const u8) void {
        if (text[0] == 0) return;
        if (self.unseen()) return;
        const font = self.fontOf(self.font) orelse
            (if (self.default_font) |d| self.fontOf(d) else null) orelse
            Font{ .host = 0 };
        const tx = x * self.xf.sx + self.xf.tx;
        const ty = y * self.xf.sy + self.xf.ty;
        switch (font) {
            .host => |handle| {
                const text_fn = self.backend.draw_text_fn orelse return;
                text_fn(self.backend.user_data, handle, text, tx, ty, self.xf.sx * self.text_scale, self.colour, self.alpha);
            },
            .sprite => |sf| self.drawSpriteText(sf, tx, ty, std.mem.span(text)),
        }
    }

    /// Lays out `text` in a sprite font at device position (x, y): "\n",
    /// "\r" and "\r\n" start a new line, characters without a glyph advance
    /// one cell, and lower case is drawn in upper case when the font has no
    /// lower-case glyphs.
    fn drawSpriteText(self: *DrawManager, sf: SpriteFont, x: f32, y: f32, text: []const u8) void {
        const draw_fn = self.backend.draw_image_fn orelse return;
        const g = self.glyphs(sf.sprite) orelse return;
        const sx = self.xf.sx * self.text_scale;
        const sy = self.xf.sy * self.text_scale;
        const adv = @as(f32, @floatFromInt(g.w)) * sx;
        const line = @as(f32, @floatFromInt(g.h)) * sy;
        var lx = x;
        var ly = y;
        var i: usize = 0;
        while (i < text.len) : (i += 1) {
            const ch = text[i];
            if (ch == '\r' or ch == '\n') {
                if (ch == '\r' and i + 1 < text.len and text[i + 1] == '\n') i += 1;
                lx = x;
                ly += line;
                continue;
            }
            if (glyphIndex(sf.first, g.frames, ch)) |frame| {
                draw_fn(self.backend.user_data, sf.sprite, frame, 0, 0, g.w, g.h, lx, ly, 0.0, 0.0, sx, sy, 0.0, self.colour, self.alpha);
            }
            lx += adv;
        }
    }

    /// Frame of `ch` in a font whose frame 0 is `first`; null for blanks and
    /// characters the font lacks.
    fn glyphIndex(first: u8, frames: i32, ch: u8) ?i32 {
        const c = if (!hasGlyph(first, frames, ch) and std.ascii.isLower(ch)) std.ascii.toUpper(ch) else ch;
        if (c == ' ' or !hasGlyph(first, frames, c)) return null;
        return c - first;
    }

    fn hasGlyph(first: u8, frames: i32, c: u8) bool {
        return c >= first and @as(i32, c - first) < frames;
    }

    fn glyphs(self: *const DrawManager, sprite: i32) ?Glyphs {
        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            const s = SpriteRegistry.get().getSprite(sprite) orelse return null;
            if (s.frame_count <= 0 or s.width <= 0 or s.height <= 0) return null;
            return .{ .frames = s.frame_count, .w = s.width, .h = s.height };
        }
        if (sprite >= @as(i32, @intCast(MAX_SPRITES)) and @as(usize, @intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))) < ADDED_SPRITE_MAX) {
            const a = &self.added_sprites[@intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))];
            if (!a.used or a.frames <= 0 or a.w <= 0 or a.h <= 0) return null;
            return .{ .frames = a.frames, .w = a.w, .h = a.h };
        }
        return null;
    }

    pub fn drawRectangle(self: *DrawManager, x1: f32, y1: f32, x2: f32, y2: f32, outline: bool) void {
        const rect_fn = self.backend.draw_rect_fn orelse return;
        if (self.unseen()) return;
        const tx1 = x1 * self.xf.sx + self.xf.tx;
        const ty1 = y1 * self.xf.sy + self.xf.ty;
        const tx2 = x2 * self.xf.sx + self.xf.tx;
        const ty2 = y2 * self.xf.sy + self.xf.ty;
        rect_fn(self.backend.user_data, tx1, ty1, tx2, ty2, self.colour, self.alpha, outline);
    }

    pub fn drawCircle(self: *DrawManager, x: f32, y: f32, r: f32, outline: bool) void {
        const circ_fn = self.backend.draw_circle_fn orelse return;
        if (self.unseen()) return;
        const tx = x * self.xf.sx + self.xf.tx;
        const ty = y * self.xf.sy + self.xf.ty;
        const tr = r * self.xf.sx;
        circ_fn(self.backend.user_data, tx, ty, tr, self.colour, self.alpha, outline);
    }

    pub fn drawClear(self: *DrawManager, col: f32) void {
        const clr_fn = self.backend.clear_fn orelse return;
        if (self.unseen()) return;
        const c: i32 = @intFromFloat(col);
        clr_fn(self.backend.user_data, @as(u32, @bitCast(c)) & 0x00FFFFFF, 1.0);
    }

    pub fn drawLayer(self: *DrawManager, l: *const Layer) void {
        if (!l.visible) return;

        if (l.kind == layer_mod.LAYER_BACKGROUND) {
            var cur = l.head;
            while (cur >= 0) {
                const ucur: usize = @intCast(cur);
                const e = LayerManager.get().elementSlot(ucur) orelse break;
                if (e.visible and e.type == ELEMENT_BACKGROUND) {
                    var spr_frames: i32 = 0;
                    var spr_w: i32 = 0;
                    var spr_h: i32 = 0;
                    if (e.sprite >= 0 and @as(usize, @intCast(e.sprite)) < MAX_SPRITES) {
                        if (SpriteRegistry.get().getSprite(e.sprite)) |spr| {
                            spr_frames = spr.frame_count;
                            spr_w = spr.width;
                            spr_h = spr.height;
                        }
                    }
                    if (spr_frames <= 0 or spr_w <= 0 or spr_h <= 0) {
                        if (self.backend.draw_rect_fn) |rect_fn| {
                            const rx1 = self.xf.wx * self.xf.sx + self.xf.tx;
                            const ry1 = self.xf.wy * self.xf.sy + self.xf.ty;
                            const rx2 = (self.xf.wx + self.xf.ww) * self.xf.sx + self.xf.tx;
                            const ry2 = (self.xf.wy + self.xf.wh) * self.xf.sy + self.xf.ty;
                            rect_fn(self.backend.user_data, rx1, ry1, rx2, ry2, e.blend, e.alpha, false);
                        }
                    } else if (self.backend.draw_image_fn) |draw_fn| {
                        const xs = if (e.stretch) (if (e.xscale != 0.0) e.xscale else 1.0) else 1.0;
                        const ys = if (e.stretch) (if (e.yscale != 0.0) e.yscale else 1.0) else 1.0;
                        const w = @as(f32, @floatFromInt(spr_w)) * xs;
                        const h = @as(f32, @floatFromInt(spr_h)) * ys;
                        if (w > 0.0 and h > 0.0) {
                            const frame = frameOf(e.image_index, spr_frames);
                            var x0 = l.x;
                            var y0 = l.y;
                            if (e.htiled) {
                                x0 -= @ceil((x0 - self.xf.wx) / w) * w;
                            }
                            if (e.vtiled) {
                                y0 -= @ceil((y0 - self.xf.wy) / h) * h;
                            }
                            var y = y0;
                            while (y < self.xf.wy + self.xf.wh or y == y0) : (y += h) {
                                var x = x0;
                                while (x < self.xf.wx + self.xf.ww or x == x0) : (x += w) {
                                    const tx = x * self.xf.sx + self.xf.tx;
                                    const ty = y * self.xf.sy + self.xf.ty;
                                    draw_fn(
                                        self.backend.user_data,
                                        e.sprite,
                                        frame,
                                        0,
                                        0,
                                        spr_w,
                                        spr_h,
                                        tx,
                                        ty,
                                        0.0,
                                        0.0,
                                        xs * self.xf.sx,
                                        ys * self.xf.sy,
                                        0.0,
                                        e.blend,
                                        e.alpha,
                                    );
                                    if (!e.htiled) break;
                                }
                                if (!e.vtiled) break;
                            }
                        }
                    }
                }
                cur = e.next;
            }
        } else if (l.kind == layer_mod.LAYER_ASSETS) {
            var cur = l.head;
            while (cur >= 0) {
                const ucur: usize = @intCast(cur);
                const e = LayerManager.get().elementSlot(ucur) orelse break;
                profile.count(.layer_elements, 1);
                if (e.visible and e.type == ELEMENT_TILE and e.sprite >= 0) {
                    const x = e.x + l.x;
                    const y = e.y + l.y;
                    if (x <= self.xf.wx + self.xf.ww and
                        y <= self.xf.wy + self.xf.wh and
                        x + @as(f32, @floatFromInt(e.w)) * e.xscale >= self.xf.wx and
                        y + @as(f32, @floatFromInt(e.h)) * e.yscale >= self.xf.wy and
                        self.spriteExists(e.sprite))
                    {
                        if (self.backend.draw_image_fn) |draw_fn| {
                            const tx = x * self.xf.sx + self.xf.tx;
                            const ty = y * self.xf.sy + self.xf.ty;
                            draw_fn(
                                self.backend.user_data,
                                e.sprite,
                                0,
                                e.xo,
                                e.yo,
                                e.w,
                                e.h,
                                tx,
                                ty,
                                0.0,
                                0.0,
                                e.xscale * self.xf.sx,
                                e.yscale * self.xf.sy,
                                0.0,
                                e.blend,
                                e.alpha,
                            );
                        }
                    }
                }
                cur = e.next;
            }
        }
    }

    // Sprites & Fonts
    pub fn spriteAdd(self: *DrawManager, path: [*:0]const u8, frames: i32, xorig: f32, yorig: f32) i32 {
        if (frames < 1) return -1;
        for (0..ADDED_SPRITE_MAX) |i| {
            if (!self.added_sprites[i].used) {
                const s = &self.added_sprites[i];
                var w: i32 = 0;
                var h: i32 = 0;
                const sprite_idx: i32 = @intCast(MAX_SPRITES + i);
                // No loader is the null platform (sp__null_sprite_load): the
                // file cannot be loaded, so the sprite does not exist.
                const load_fn = self.backend.sprite_load_fn orelse return -1;
                if (!load_fn(self.backend.user_data, sprite_idx, path, frames, &w, &h)) {
                    return -1;
                }
                s.used = true;
                s.frames = frames;
                s.w = w;
                s.h = h;
                s.xorig = xorig;
                s.yorig = yorig;
                return sprite_idx;
            }
        }
        self.overflow_count += 1;
        return -1;
    }

    pub fn spriteExists(self: *const DrawManager, sprite: i32) bool {
        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            return SpriteRegistry.get().valid(sprite);
        }
        if (sprite >= @as(i32, @intCast(MAX_SPRITES)) and @as(usize, @intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))) < ADDED_SPRITE_MAX) {
            return self.added_sprites[@intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))].used;
        }
        return false;
    }

    pub fn spriteWidth(self: *const DrawManager, sprite: i32) i32 {
        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            return if (SpriteRegistry.get().getSprite(sprite)) |s| s.width else 0;
        }
        if (sprite >= @as(i32, @intCast(MAX_SPRITES)) and @as(usize, @intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))) < ADDED_SPRITE_MAX) {
            return self.added_sprites[@intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))].w;
        }
        return 0;
    }

    pub fn spriteHeight(self: *const DrawManager, sprite: i32) i32 {
        if (sprite >= 0 and @as(usize, @intCast(sprite)) < MAX_SPRITES) {
            return if (SpriteRegistry.get().getSprite(sprite)) |s| s.height else 0;
        }
        if (sprite >= @as(i32, @intCast(MAX_SPRITES)) and @as(usize, @intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))) < ADDED_SPRITE_MAX) {
            return self.added_sprites[@intCast(sprite - @as(i32, @intCast(MAX_SPRITES)))].h;
        }
        return 0;
    }

    fn pushFont(self: *DrawManager, f: Font) i32 {
        if (self.font_count >= FONT_MAX) {
            self.overflow_count += 1;
            return -1;
        }
        const idx: i32 = @intCast(self.font_count);
        self.fonts[self.font_count] = f;
        self.font_count += 1;
        return idx;
    }

    /// font_add: a face the host loads (`font_load_fn`, handle > 0). Without
    /// one (no loader, or it fails) the id aliases the registered sprite font
    /// that best fits `size` (the tallest no taller than `size`, else the
    /// shortest); with no sprite fonts either, -1.
    pub fn fontAdd(self: *DrawManager, path: [*:0]const u8, size: i32) i32 {
        if (self.font_count >= FONT_MAX) {
            self.overflow_count += 1;
            return -1;
        }
        if (self.backend.font_load_fn) |load_fn| {
            const handle = load_fn(self.backend.user_data, path, size);
            if (handle > 0) return self.pushFont(.{ .host = handle });
        }
        const alias = self.spriteFontFor(size) orelse return -1;
        return self.pushFont(alias);
    }

    /// Registers a sprite font (drawn by the runtime); -1 if the sprite has
    /// no frames.
    pub fn fontAddSprite(self: *DrawManager, font: SpriteFont) i32 {
        if (self.glyphs(font.sprite) == null) return -1;
        return self.pushFont(.{ .sprite = font });
    }

    /// Font drawn while draw_set_font names no font (null: host default).
    pub fn setDefaultFont(self: *DrawManager, id: ?i32) void {
        self.default_font = id;
    }

    pub fn getFont(self: *const DrawManager, id: i32) ?Font {
        return self.fontOf(id);
    }

    fn spriteFontFor(self: *const DrawManager, size: i32) ?Font {
        var best: ?Font = null;
        var best_h: i32 = 0;
        for (self.fonts[0..self.font_count]) |f| {
            const sf = switch (f) {
                .sprite => |sf| sf,
                .host => continue,
            };
            const h = (self.glyphs(sf.sprite) orelse continue).h;
            const better = if (best == null)
                true
            else if (h <= size)
                best_h > size or h > best_h
            else
                best_h > size and h < best_h;
            if (better) {
                best = f;
                best_h = h;
            }
        }
        return best;
    }

    // Surfaces
    pub fn surfaceCreate(self: *DrawManager, w: i32, h: i32) i32 {
        if (w < 1 or h < 1) return -1;
        for (1..SURFACE_MAX) |i| {
            if (!self.surfaces[i].used) {
                var handle: i32 = 0;
                if (self.backend.surface_create_fn) |sc| {
                    handle = sc(self.backend.user_data, w, h);
                    if (handle <= 0) return -1;
                } else {
                    self.headless_surface_counter += 1;
                    handle = self.headless_surface_counter;
                }
                self.surfaces[i] = .{
                    .used = true,
                    .handle = handle,
                    .w = w,
                    .h = h,
                };
                return @intCast(i);
            }
        }
        self.overflow_count += 1;
        return -1;
    }

    pub fn surfaceExists(self: *const DrawManager, id: i32) bool {
        if (id == APP_SURFACE) return true;
        if (id < 1 or @as(usize, @intCast(id)) >= SURFACE_MAX) return false;
        return self.surfaces[@intCast(id)].used;
    }

    pub fn surfaceFree(self: *DrawManager, id: i32) void {
        if (id < 1 or @as(usize, @intCast(id)) >= SURFACE_MAX) return;
        const s = &self.surfaces[@intCast(id)];
        if (!s.used) return;
        if (self.backend.surface_free_fn) |sf| {
            sf(self.backend.user_data, s.handle);
        }
        s.used = false;
    }

    pub fn surfaceResize(self: *DrawManager, id: i32, w: i32, h: i32) void {
        if (id == APP_SURFACE) {
            self.base_app_w = w;
            self.base_app_h = h;
            self.app_w = if (self.viewport_scale != 1.0)
                @intFromFloat(@as(f32, @floatFromInt(w)) * self.viewport_scale)
            else
                w;
            self.app_h = if (self.viewport_scale != 1.0)
                @intFromFloat(@as(f32, @floatFromInt(h)) * self.viewport_scale)
            else
                h;
            return;
        }
        if (id < 1 or @as(usize, @intCast(id)) >= SURFACE_MAX) return;
        const s = &self.surfaces[@intCast(id)];
        if (!s.used) return;
        if (self.backend.surface_free_fn) |sf| {
            sf(self.backend.user_data, s.handle);
        }
        if (self.backend.surface_create_fn) |sc| {
            s.handle = sc(self.backend.user_data, w, h);
        }
        s.w = w;
        s.h = h;
    }

    pub fn surfaceSetTarget(self: *DrawManager, id: i32) bool {
        if (self.stack_depth >= TARGET_STACK or !self.surfaceExists(id)) return false;
        self.stack[self.stack_depth] = self.xf;
        self.stack_target[self.stack_depth] = self.target;
        self.stack_depth += 1;
        self.target = id;

        const w = if (id == APP_SURFACE) self.app_w else self.surfaces[@intCast(id)].w;
        const h = if (id == APP_SURFACE) self.app_h else self.surfaces[@intCast(id)].h;
        self.identity(@floatFromInt(w), @floatFromInt(h));

        if (self.backend.surface_target_fn) |st| {
            const handle = if (id == APP_SURFACE) 0 else self.surfaces[@intCast(id)].handle;
            st(self.backend.user_data, handle);
        }
        return true;
    }

    pub fn surfaceResetTarget(self: *DrawManager) bool {
        if (self.stack_depth == 0) return false;
        self.stack_depth -= 1;
        self.xf = self.stack[self.stack_depth];
        self.target = self.stack_target[self.stack_depth];

        if (self.backend.surface_target_fn) |st| {
            const handle = if (self.target == APP_SURFACE) 0 else self.surfaces[@intCast(self.target)].handle;
            st(self.backend.user_data, handle);
        }
        return true;
    }

    pub fn drawSurface(self: *DrawManager, id: i32, x: f32, y: f32) void {
        if (!self.surfaceExists(id)) return;
        const s = &self.surfaces[@intCast(id)];
        self.drawSurfaceStretched(id, x, y, @floatFromInt(s.w), @floatFromInt(s.h));
    }

    pub fn drawSurfaceStretched(self: *DrawManager, id: i32, x: f32, y: f32, w: f32, h: f32) void {
        if (!self.surfaceExists(id) or id == self.target) return;
        const ds_fn = self.backend.draw_surface_fn orelse return;
        if (self.unseen()) return;
        const s = &self.surfaces[@intCast(id)];
        const tx = x * self.xf.sx + self.xf.tx;
        const ty = y * self.xf.sy + self.xf.ty;
        const tw = w * self.xf.sx;
        const th = h * self.xf.sy;
        ds_fn(self.backend.user_data, s.handle, tx, ty, tw, th, 1.0);
    }

    // Window / Display
    pub fn windowWidth(self: *const DrawManager) i32 {
        var w: i32 = self.win_w;
        var h: i32 = self.win_h;
        if (self.backend.window_size_fn) |ws| {
            ws(self.backend.user_data, &w, &h);
        }
        return w;
    }

    pub fn windowHeight(self: *const DrawManager) i32 {
        var w: i32 = self.win_w;
        var h: i32 = self.win_h;
        if (self.backend.window_size_fn) |ws| {
            ws(self.backend.user_data, &w, &h);
        }
        return h;
    }

    pub fn displayWidth(self: *const DrawManager) i32 {
        var w: i32 = 0;
        var h: i32 = 0;
        if (self.backend.display_size_fn) |ds| {
            ds(self.backend.user_data, &w, &h);
        }
        return w;
    }

    pub fn displayHeight(self: *const DrawManager) i32 {
        var w: i32 = 0;
        var h: i32 = 0;
        if (self.backend.display_size_fn) |ds| {
            ds(self.backend.user_data, &w, &h);
        }
        return h;
    }

    pub fn windowSetSize(self: *DrawManager, w: i32, h: i32) void {
        if (w < 1 or h < 1) return;
        self.win_w = w;
        self.win_h = h;
        if (self.backend.set_window_size_fn) |sws| {
            sws(self.backend.user_data, w, h);
        }
    }

    pub fn windowSetFullscreen(self: *DrawManager, f: bool) void {
        self.is_fullscreen = f;
        if (self.backend.set_fullscreen_fn) |sfs| {
            sfs(self.backend.user_data, f);
        }
    }

    pub fn displaySetGuiSize(self: *DrawManager, w: i32, h: i32) void {
        self.gui_w = w;
        self.gui_h = h;
    }

    pub fn overflows(self: *const DrawManager) usize {
        return self.overflow_count;
    }
};

test "Headless DrawManager transforms, surfaces, and window operations" {
    var dm = DrawManager.get();
    dm.reset();

    // Color and alpha
    dm.setColour(0x00FF00);
    dm.setAlpha(0.5);
    try std.testing.expectEqual(@as(u32, 0x0000FF00), dm.getColour());
    try std.testing.expectEqual(@as(f32, 0.5), dm.getAlpha());

    // Headless frame cycle
    dm.beginFrame();
    dm.passRoom();
    dm.endFrame();

    // Headless surfaces
    const s1 = dm.surfaceCreate(320, 240);
    try std.testing.expect(s1 > 0);
    try std.testing.expect(dm.surfaceExists(s1));

    try std.testing.expect(dm.surfaceSetTarget(s1));
    dm.drawRectangle(0.0, 0.0, 100.0, 100.0, false);
    try std.testing.expect(dm.surfaceResetTarget());

    dm.surfaceFree(s1);
    try std.testing.expect(!dm.surfaceExists(s1));
}

test "skip_unseen drops screen draws outside the frame, keeps surface draws" {
    const S = struct {
        var rects: usize = 0;
        fn rect(_: ?*anyopaque, _: f32, _: f32, _: f32, _: f32, _: u32, _: f32, _: bool) void {
            rects += 1;
        }
    };
    var dm: DrawManager = .{};
    dm.backend = .{ .draw_rect_fn = S.rect };
    dm.drawRectangle(0, 0, 4, 4, false); // off by default
    try std.testing.expectEqual(@as(usize, 1), S.rects);

    dm.skip_unseen = true;
    dm.drawRectangle(0, 0, 4, 4, false); // step-time screen draw
    try std.testing.expectEqual(@as(usize, 1), S.rects);
    try std.testing.expectEqual(@as(usize, 1), dm.unseen_skipped);

    const s = dm.surfaceCreate(8, 8);
    try std.testing.expect(dm.surfaceSetTarget(s));
    dm.drawRectangle(0, 0, 4, 4, false); // into a surface: kept
    try std.testing.expectEqual(@as(usize, 2), S.rects);
    try std.testing.expect(dm.surfaceResetTarget());

    dm.beginFrame();
    dm.drawRectangle(0, 0, 4, 4, false); // in the frame: kept
    dm.endFrame();
    try std.testing.expectEqual(@as(usize, 3), S.rects);
}

test "offscreen culls only images that cannot touch the visible rectangle" {
    var dm: DrawManager = .{};
    dm.xf = .{ .wx = 100.0, .wy = 50.0, .ww = 320.0, .wh = 240.0 };
    const T = std.testing;
    // 16x16, origin 8,8: inside, just touching, and clear of each edge.
    try T.expect(!dm.offscreen(200, 100, 8, 8, 16, 16, 1, 1, 0));
    try T.expect(!dm.offscreen(93, 100, 8, 8, 16, 16, 1, 1, 0));
    try T.expect(dm.offscreen(90, 100, 8, 8, 16, 16, 1, 1, 0));
    try T.expect(dm.offscreen(430, 100, 8, 8, 16, 16, 1, 1, 0));
    try T.expect(dm.offscreen(200, 30, 8, 8, 16, 16, 1, 1, 0));
    try T.expect(dm.offscreen(200, 300, 8, 8, 16, 16, 1, 1, 0));
    // Mirrored: the image extends left of x.
    try T.expect(!dm.offscreen(425, 100, 0, 0, 16, 16, -1, 1, 0));
    try T.expect(dm.offscreen(425, 100, 0, 0, 16, 16, 1, 1, 0));
    // Scaled up reaches back on screen.
    try T.expect(!dm.offscreen(80, 100, 0, 0, 16, 16, 2, 1, 0));
    // Rotated: bounded by the circle around the origin.
    try T.expect(!dm.offscreen(90, 100, 0, 0, 16, 16, 1, 1, 45));
    try T.expect(dm.offscreen(70, 100, 0, 0, 16, 16, 1, 1, 45));
    // NaN and an unset rectangle never cull.
    try T.expect(!dm.offscreen(std.math.nan(f32), 100, 0, 0, 16, 16, 1, 1, 0));
    dm.xf.ww = 0.0;
    try T.expect(!dm.offscreen(-1000, -1000, 0, 0, 16, 16, 1, 1, 0));
}
