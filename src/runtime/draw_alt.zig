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
