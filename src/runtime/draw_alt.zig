//! Simplified draw pipeline.
//! Per camera: walk all instances in depth order (deepest first) and blit each
//! one directly (its Draw event, else draw_self). No layers, no Begin/End/Pre/Post
//! passes. GUI is drawn once afterwards in screen space.

const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;
const view_mod = @import("view.zig");
const ViewManager = view_mod.ViewManager;
const ViewField = view_mod.ViewField;
const VIEW_COUNT = view_mod.VIEW_COUNT;
const DrawManager = @import("draw.zig").DrawManager;
const RoomManager = @import("room.zig").RoomManager;
const profile = @import("profile.zig");
const loop_mod = @import("loop.zig");
const std = @import("std");
const ObjectRegistry = @import("object.zig").ObjectRegistry;
const layer_mod = @import("layer.zig");
const LayerManager = layer_mod.LayerManager;
const LoopManager = loop_mod.LoopManager;

pub fn drawPipeline(lm: *LoopManager) void {
    const dm = DrawManager.get();
    const vm = ViewManager.get();

    var t = profile.start();
    dm.beginFrame();
    profile.stop(.draw_frame, t);
    vm.update();

    // World-pass text (the HUD) at the host's scale.
    dm.text_scale = dm.world_text_scale;
    if (vm.enabled()) {
        for (0..VIEW_COUNT) |v| {
            if (vm.getViewVar(ViewField.visible, v) == 0.0) continue;
            vm.setCurrent(@intCast(v));
            dm.passView(v);
            const pin = followTarget(dm, vm, v);
            drawObjects(lm);
            pin.restore();
        }
        vm.setCurrent(7);
    } else {
        vm.setCurrent(0);
        dm.passRoom();
        const pin = followTarget(dm, vm, 0);
        drawObjects(lm);
        pin.restore();
    }

    dm.text_scale = 1.0;
    if (lm.draw_filter.gui) {
        t = profile.start();
        dm.passGui();
        drawGui(lm);
        profile.stop(.draw_gui, t);
    }
    t = profile.start();
    dm.endFrame();
    profile.stop(.draw_frame, t);
}

/// The game camera moved by `followTarget` for one world pass; `restore`
/// puts it back, so step logic only ever sees the game's own camera.
const CameraPin = struct {
    cam: ?*view_mod.Camera = null,
    x: f32 = 0.0,
    y: f32 = 0.0,

    fn restore(self: CameraPin) void {
        if (self.cam) |c| {
            c.x = self.x;
            c.y = self.y;
        }
    }
};

/// oPlayer1's object index (null if the game has none), looked up once per
/// installed object table.
fn playerObject() ?i32 {
    const S = struct {
        var table: ?[*]const @import("object.zig").ObjectDef = null;
        var obj: ?i32 = null;
    };
    const reg = ObjectRegistry.get();
    if (S.table != reg.defs) {
        S.table = reg.defs;
        S.obj = null;
        for (0..reg.countObjects()) |i| {
            const def = reg.getDef(@intCast(i)) orelse continue;
            if (std.mem.eql(u8, def.name, "oPlayer1")) {
                S.obj = @intCast(i);
                break;
            }
        }
    }
    return S.obj;
}

/// HACK: when the host shows only a centred `follow_w` x `follow_h` window
/// of the frame (Playdate 2x), shift the view so the player (else the
/// view's follow object) sits in the middle of that window, clamped to the
/// room, and cull to the window. The view's scale is kept.
///
/// For the world pass the view's camera is moved to the window's top-left:
/// view-relative draws (the HUD at camera x + 8, y + 8) then sit at the top
/// left of the screen instead of sliding with the follow. The returned pin
/// restores the camera after the pass.
fn followTarget(dm: *DrawManager, vm: *ViewManager, v: usize) CameraPin {
    if (dm.follow_w <= 0 or dm.follow_h <= 0) return .{};
    const sx = dm.xf.sx;
    const sy = dm.xf.sy;
    if (!(sx > 0.0 and sy > 0.0)) return .{};

    const app_w: f32 = @floatFromInt(dm.app_w);
    const app_h: f32 = @floatFromInt(dm.app_h);
    const vis_w = @min(@as(f32, @floatFromInt(dm.follow_w)), app_w);
    const vis_h = @min(@as(f32, @floatFromInt(dm.follow_h)), app_h);
    // Visible window in frame pixels.
    const win_x = (app_w - vis_w) * 0.5;
    const win_y = (app_h - vis_h) * 0.5;
    // ...and its size in world units.
    const ww = vis_w / sx;
    const wh = vis_h / sy;

    // World rectangle currently in the window (no follow object: keep it).
    var wx = (win_x - dm.xf.tx) / sx;
    var wy = (win_y - dm.xf.ty) / sy;

    const mgr = InstanceManager.get();
    const player: ?*Instance = if (playerObject()) |p| mgr.find(p, 0, null, null) else null;
    const view_obj: i32 = @intFromFloat(vm.getViewVar(ViewField.object, v));
    const target: ?*Instance = player orelse if (view_obj >= 0) mgr.find(view_obj, 0, null, null) else null;
    {
        if (target) |t| {
            const has_bbox = t.bbox_right > t.bbox_left and t.bbox_bottom > t.bbox_top;
            const px = if (has_bbox) (t.bbox_left + t.bbox_right) * 0.5 else t.x;
            const py = if (has_bbox) (t.bbox_top + t.bbox_bottom) * 0.5 else t.y;
            wx = px - ww * 0.5;
            wy = py - wh * 0.5;

            const rm = RoomManager.get();
            const rw = rm.getWidth();
            const rh = rm.getHeight();
            if (rw > ww) wx = @max(0.0, @min(wx, rw - ww));
            if (rh > wh) wy = @max(0.0, @min(wy, rh - wh));
        }
    }

    // Whole frame pixels, so sprites don't shimmer.
    dm.xf.tx = @round(win_x - wx * sx);
    dm.xf.ty = @round(win_y - wy * sy);
    dm.xf.wx = (win_x - dm.xf.tx) / sx;
    dm.xf.wy = (win_y - dm.xf.ty) / sy;
    dm.xf.ww = ww;
    dm.xf.wh = wh;

    // Exactly the window's top-left in world units (from the rounded
    // offset), so camera-relative draws land on whole screen pixels.
    const cam_id: i32 = @intFromFloat(vm.getViewVar(ViewField.camera, v));
    const cam = vm.cameraGet(cam_id) orelse return .{};
    const pin: CameraPin = .{ .cam = cam, .x = cam.x, .y = cam.y };
    cam.x = dm.xf.wx;
    cam.y = dm.xf.wy;
    return pin;
}

inline fn drawable(inst: *const Instance) bool {
    return inst.in_use and !inst.marked_for_destroy and inst.active and inst.visible;
}

const cull_margin: f32 = 32.0;

/// instanceOffscreen, caching the world box of static instances (their box
/// only changes through collision.touch, which drops the cache entry).
fn offscreen(dm: *const DrawManager, mgr: *InstanceManager, inst: *const Instance, slot: usize) bool {
    switch (mgr.cull_state[slot]) {
        .box => return dm.boxOffscreen(mgr.cull_box[slot], cull_margin),
        .none => return false,
        .unknown => {},
    }
    const box = dm.instanceBox(inst);
    if (!inst.is_dynamic) {
        if (box) |b| {
            mgr.cull_box[slot] = b;
            mgr.cull_state[slot] = .box;
        } else {
            mgr.cull_state[slot] = .none;
        }
    }
    return if (box) |b| dm.boxOffscreen(b, cull_margin) else false;
}

/// Room layers (background images / colour, tiles) merged into the instance
/// pass by depth, deepest first. Instance layers hold nothing to draw.
const Layers = struct {
    lm: *LoopManager,
    /// Next layer to draw, walking from the deepest (highest index) down.
    next: isize,

    fn init(lm: *LoopManager) Layers {
        const on = lm.draw_filter.layer_background or lm.draw_filter.layer_foreground;
        return .{ .lm = lm, .next = if (on) @as(isize, @intCast(LayerManager.get().count())) - 1 else -1 };
    }

    /// Draws every layer at or behind `depth` (null: all that are left).
    fn drawUpTo(self: *Layers, dm: *DrawManager, depth: ?i32) void {
        if (self.next < 0) return;
        const t = profile.start();
        defer profile.stop(.draw_layers, t);
        const layers = LayerManager.get();
        const f = self.lm.draw_filter;
        while (self.next >= 0) : (self.next -= 1) {
            const l = layers.at(@intCast(self.next)) orelse continue;
            if (depth) |d| if (l.depth < d) return;
            if (l.kind == layer_mod.LAYER_INSTANCES) continue;
            const is_bg = @as(f32, @floatFromInt(l.depth)) >= f.bg_depth_threshold;
            if (if (is_bg) f.layer_background else f.layer_foreground) dm.drawLayer(l);
        }
    }
};

/// Instances come back from `drawOrder` already sorted by depth (cached depth
/// buckets), so this is a single linear pass; room layers are drawn in
/// between, by depth.
fn drawObjects(lm: *LoopManager) void {
    const dm = DrawManager.get();
    const rm = RoomManager.get();
    var t = profile.start();
    const n = InstanceManager.get().drawOrder(&lm.draw_scratch);
    profile.stop(.draw_order, t);

    var layers = Layers.init(lm);
    defer layers.drawUpTo(dm, null);

    t = profile.start();
    defer profile.stop(.draw_instances, t);
    const prof = profile.deepEnabled();
    const mgr = InstanceManager.get();
    for (lm.draw_scratch[0..n]) |inst| {
        const slot = mgr.slot(inst);
        if (layers.next >= 0) layers.drawUpTo(dm, mgr.drawDepth(inst));
        // Static instance with a cached box: culled from the compact table,
        // without reading the instance.
        if (mgr.cull_state[slot] == .box and dm.boxOffscreen(mgr.cull_box[slot], cull_margin)) {
            profile.count(.draw_visited, 1);
            profile.count(.draw_culled, 1);
            continue;
        }
        if (!drawable(inst)) continue;
        profile.count(.draw_visited, 1);
        if (offscreen(dm, mgr, inst, slot)) {
            profile.count(.draw_culled, 1);
            continue;
        }

        const t_obj = if (prof) profile.start() else 0;
        if (lm.handlersOf(inst).draw) |fn_ptr| {
            profile.count(.draw_events, 1);
            if (!rm.eventBlocked(inst, loop_mod.EV_TYPE_DRAW)) fn_ptr(inst, inst);
        } else if (lm.hooks) |h| {
            profile.count(.draw_selfs, 1);
            if (h.draw_self) |ds| ds(inst);
        }
        if (prof) profile.stopObject(.draw, inst.object_index, t_obj);
    }
}

fn drawGui(lm: *LoopManager) void {
    const rm = RoomManager.get();
    const n = InstanceManager.get().drawOrder(&lm.draw_scratch);

    for (lm.draw_scratch[0..n]) |inst| {
        // Cached handler first: most objects have no GUI event, and this
        // avoids touching the rest of the instance for them.
        const fn_ptr = lm.handlersOf(inst).draw_gui orelse continue;
        if (!drawable(inst)) continue;
        profile.count(.draw_events, 1);
        const t_obj = profile.startSection();
        if (!rm.eventBlocked(inst, loop_mod.EV_TYPE_DRAW)) fn_ptr(inst, inst);
        profile.stopObject(.draw, inst.object_index, t_obj);
    }
}
