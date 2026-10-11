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

    dm.beginFrame();
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
        dm.passGui();
        drawGui(lm);
    }
    dm.endFrame();
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

/// Instances come back from `drawOrder` already sorted by depth (cached depth
/// buckets), so this is a single linear pass.
fn drawObjects(lm: *LoopManager) void {
    const dm = DrawManager.get();
    const rm = RoomManager.get();
    const n = InstanceManager.get().drawOrder(&lm.draw_scratch);

    for (lm.draw_scratch[0..n]) |inst| {
        if (!drawable(inst)) continue;
        if (dm.instanceOffscreen(inst, 32.0)) continue;

        if (lm.handler(inst, loop_mod.EV_TYPE_DRAW, loop_mod.EV_DRAW_NORMAL)) |fn_ptr| {
            if (!rm.eventBlocked(inst, loop_mod.EV_TYPE_DRAW)) fn_ptr(inst, inst);
        } else if (lm.hooks) |h| {
            if (h.draw_self) |ds| ds(inst);
        }
    }
}

fn drawGui(lm: *LoopManager) void {
    const rm = RoomManager.get();
    const n = InstanceManager.get().drawOrder(&lm.draw_scratch);

    for (lm.draw_scratch[0..n]) |inst| {
        if (!drawable(inst)) continue;
        if (lm.handler(inst, loop_mod.EV_TYPE_DRAW, loop_mod.EV_DRAW_GUI)) |fn_ptr| {
            if (!rm.eventBlocked(inst, loop_mod.EV_TYPE_DRAW)) fn_ptr(inst, inst);
        }
    }
}
