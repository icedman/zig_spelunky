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
const LoopManager = loop_mod.LoopManager;

pub fn drawPipeline(lm: *LoopManager) void {
    const dm = DrawManager.get();
    const vm = ViewManager.get();

    var t = profile.start();
    dm.beginFrame();
    profile.stop(.draw_frame, t);
    vm.update();

    if (vm.enabled()) {
        for (0..VIEW_COUNT) |v| {
            if (vm.getViewVar(ViewField.visible, v) == 0.0) continue;
            vm.setCurrent(@intCast(v));
            dm.passView(v);
            followTarget(dm, vm, v);
            drawObjects(lm);
        }
        vm.setCurrent(7);
    } else {
        vm.setCurrent(0);
        dm.passRoom();
        drawObjects(lm);
    }

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

/// HACK: when the host shows only a centred `follow_w` x `follow_h` window
/// of the frame (Playdate 2x), shift the view so its follow object sits in
/// the middle of that window, clamped to the room, and cull to the window.
/// The view's scale is kept; the game's own camera is not touched.
fn followTarget(dm: *DrawManager, vm: *ViewManager, v: usize) void {
    if (dm.follow_w <= 0 or dm.follow_h <= 0) return;
    const sx = dm.xf.sx;
    const sy = dm.xf.sy;
    if (!(sx > 0.0 and sy > 0.0)) return;

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

    const obj: i32 = @intFromFloat(vm.getViewVar(ViewField.object, v));
    if (obj >= 0) {
        if (InstanceManager.get().find(obj, 0, null, null)) |t| {
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

/// Instances come back from `drawOrder` already sorted by depth (cached depth
/// buckets), so this is a single linear pass.
fn drawObjects(lm: *LoopManager) void {
    const dm = DrawManager.get();
    const rm = RoomManager.get();
    var t = profile.start();
    const n = InstanceManager.get().drawOrder(&lm.draw_scratch);
    profile.stop(.draw_order, t);

    t = profile.start();
    defer profile.stop(.draw_instances, t);
    const prof = profile.deepEnabled();
    const mgr = InstanceManager.get();
    for (lm.draw_scratch[0..n]) |inst| {
        const slot = mgr.slot(inst);
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
