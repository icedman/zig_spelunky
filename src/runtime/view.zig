//! Views and cameras (GMS2 camera model).
//! Follows CameraManager.js, yyView.js, yyRoom.js, Function_Graphics.js and packaged_src/src/runtime/gm_view.c.

const std = @import("std");
const instance_mod = @import("instance.zig");
const Instance = instance_mod.Instance;
const InstanceManager = instance_mod.InstanceManager;
const InstanceCursor = instance_mod.InstanceCursor;
const room_mod = @import("room.zig");

pub const MAX_CAMERAS: usize = 96;
pub const VIEW_COUNT: usize = 8;

pub const ViewField = enum(usize) {
    visible = 0,
    xview,
    yview,
    wview,
    hview,
    xport,
    yport,
    wport,
    hport,
    angle,
    hborder,
    vborder,
    hspeed,
    vspeed,
    object,
    surface_id,
    camera,
};
pub const VIEW_FIELD_COUNT: usize = 17;

pub const Camera = struct {
    id: i32 = 0,
    x: f32 = 0.0,
    y: f32 = 0.0,
    w: f32 = 0.0,
    h: f32 = 0.0,
    angle: f32 = 0.0,
    speed_x: f32 = 0.0,
    speed_y: f32 = 0.0,
    border_x: f32 = 0.0,
    border_y: f32 = 0.0,
    target: i32 = -1,
    cloned: bool = false,
};

pub const View = struct {
    visible: bool = false,
    worldx: f32 = 0.0,
    worldy: f32 = 0.0,
    worldw: f32 = 0.0,
    worldh: f32 = 0.0,
    portx: f32 = 0.0,
    porty: f32 = 0.0,
    portw: f32 = 0.0,
    porth: f32 = 0.0,
    angle: f32 = 0.0,
    hborder: f32 = 0.0,
    vborder: f32 = 0.0,
    hspeed: f32 = 0.0,
    vspeed: f32 = 0.0,
    objid: f32 = 0.0,
    surface_id: f32 = -1.0,
    camera: f32 = -1.0,
};

pub const ViewStore = struct {
    def: room_mod.RoomViewDef = .{},
    camera: i32 = -1,
};

pub const ViewManager = struct {
    store: [room_mod.MAX_ROOMS][VIEW_COUNT]ViewStore = [_][VIEW_COUNT]ViewStore{[_]ViewStore{.{}} ** VIEW_COUNT} ** room_mod.MAX_ROOMS,
    store_count: usize = 0,

    cams: [MAX_CAMERAS]Camera = [_]Camera{.{}} ** MAX_CAMERAS,
    cam_used: [MAX_CAMERAS]bool = [_]bool{false} ** MAX_CAMERAS,
    next_camera_id: i32 = 0,
    overflow_count: usize = 0,

    views: [VIEW_COUNT]View = [_]View{.{}} ** VIEW_COUNT,
    arrays: [VIEW_FIELD_COUNT][VIEW_COUNT]f32 = [_][VIEW_COUNT]f32{[_]f32{0.0} ** VIEW_COUNT} ** VIEW_FIELD_COUNT,
    is_enabled: bool = false,
    in_room: bool = false,
    current_view_idx: i32 = 0,

    var instance: ViewManager = .{};

    pub fn get() *ViewManager {
        return &instance;
    }

    fn cameraNew(self: *ViewManager) ?*Camera {
        for (0..MAX_CAMERAS) |i| {
            if (!self.cam_used[i]) {
                self.cam_used[i] = true;
                const c = &self.cams[i];
                c.* = .{
                    .id = self.next_camera_id,
                    .target = -1,
                };
                self.next_camera_id += 1;
                return c;
            }
        }
        self.overflow_count += 1;
        return null;
    }

    pub fn cameraGet(self: *ViewManager, id: i32) ?*Camera {
        for (0..MAX_CAMERAS) |i| {
            if (self.cam_used[i] and self.cams[i].id == id) {
                return &self.cams[i];
            }
        }
        return null;
    }

    pub fn cameraCount(self: *const ViewManager) usize {
        var n: usize = 0;
        for (0..MAX_CAMERAS) |i| {
            if (self.cam_used[i]) n += 1;
        }
        return n;
    }

    pub fn cameraCreateView(
        self: *ViewManager,
        x: f32,
        y: f32,
        w: f32,
        h: f32,
        angle: f32,
        target: i32,
        speed_x: f32,
        speed_y: f32,
        border_x: f32,
        border_y: f32,
    ) i32 {
        const c = self.cameraNew() orelse return -1;
        c.x = x;
        c.y = y;
        c.w = w;
        c.h = h;
        c.angle = angle;
        c.target = target;
        c.speed_x = speed_x;
        c.speed_y = speed_y;
        c.border_x = border_x;
        c.border_y = border_y;
        return c.id;
    }

    pub fn cameraDestroy(self: *ViewManager, id: i32) void {
        const c = self.cameraGet(id) orelse return;
        const slot = (@intFromPtr(c) - @intFromPtr(&self.cams[0])) / @sizeOf(Camera);
        self.cam_used[slot] = false;
    }

    fn cameraClone(self: *ViewManager, id: i32) i32 {
        const src = self.cameraGet(id) orelse return -1;
        const c = self.cameraNew() orelse return -1;
        const new_id = c.id;
        c.* = src.*;
        c.id = new_id;
        c.cloned = true;
        return new_id;
    }

    pub fn reset(self: *ViewManager) void {
        @memset(&self.cam_used, false);
        self.next_camera_id = 0;
        self.overflow_count = 0;
        @memset(&self.views, View{});
        for (&self.arrays) |*arr| {
            @memset(arr, 0.0);
        }
        self.is_enabled = false;
        self.in_room = false;
        self.current_view_idx = 0;
    }

    pub fn init(self: *ViewManager, rooms: []const room_mod.RoomDef) void {
        self.reset();
        self.store_count = @min(rooms.len, room_mod.MAX_ROOMS);
        for (0..self.store_count) |r| {
            for (0..VIEW_COUNT) |v| {
                self.store[r][v].def = rooms[r].views[v];
                self.store[r][v].camera = -1;
            }
        }
    }

    pub fn resetAll(self: *ViewManager) void {
        self.reset();
        for (0..self.store_count) |r| {
            for (0..VIEW_COUNT) |v| {
                self.store[r][v].camera = -1;
            }
        }
    }

    pub fn current(self: *const ViewManager) i32 {
        return self.current_view_idx;
    }

    pub fn setCurrent(self: *ViewManager, view: i32) void {
        self.current_view_idx = view;
    }

    pub fn overflows(self: *const ViewManager) usize {
        return self.overflow_count;
    }

    fn viewsToArrays(self: *ViewManager) void {
        for (0..VIEW_COUNT) |i| {
            const v = &self.views[i];
            self.arrays[@intFromEnum(ViewField.visible)][i] = if (v.visible) 1.0 else 0.0;
            self.arrays[@intFromEnum(ViewField.xview)][i] = v.worldx;
            self.arrays[@intFromEnum(ViewField.yview)][i] = v.worldy;
            self.arrays[@intFromEnum(ViewField.wview)][i] = v.worldw;
            self.arrays[@intFromEnum(ViewField.hview)][i] = v.worldh;
            self.arrays[@intFromEnum(ViewField.xport)][i] = v.portx;
            self.arrays[@intFromEnum(ViewField.yport)][i] = v.porty;
            self.arrays[@intFromEnum(ViewField.wport)][i] = v.portw;
            self.arrays[@intFromEnum(ViewField.hport)][i] = v.porth;
            self.arrays[@intFromEnum(ViewField.angle)][i] = v.angle;
            self.arrays[@intFromEnum(ViewField.hborder)][i] = v.hborder;
            self.arrays[@intFromEnum(ViewField.vborder)][i] = v.vborder;
            self.arrays[@intFromEnum(ViewField.hspeed)][i] = v.hspeed;
            self.arrays[@intFromEnum(ViewField.vspeed)][i] = v.vspeed;
            self.arrays[@intFromEnum(ViewField.object)][i] = v.objid;
            self.arrays[@intFromEnum(ViewField.surface_id)][i] = v.surface_id;
            self.arrays[@intFromEnum(ViewField.camera)][i] = v.camera;
        }
    }

    fn arraysToViews(self: *ViewManager) void {
        for (0..VIEW_COUNT) |i| {
            const v = &self.views[i];
            v.visible = self.arrays[@intFromEnum(ViewField.visible)][i] > 0.5;
            v.worldx = self.arrays[@intFromEnum(ViewField.xview)][i];
            v.worldy = self.arrays[@intFromEnum(ViewField.yview)][i];
            v.worldw = self.arrays[@intFromEnum(ViewField.wview)][i];
            v.worldh = self.arrays[@intFromEnum(ViewField.hview)][i];
            v.portx = self.arrays[@intFromEnum(ViewField.xport)][i];
            v.porty = self.arrays[@intFromEnum(ViewField.yport)][i];
            v.portw = self.arrays[@intFromEnum(ViewField.wport)][i];
            v.porth = self.arrays[@intFromEnum(ViewField.hport)][i];
            v.angle = self.arrays[@intFromEnum(ViewField.angle)][i];
            v.hborder = self.arrays[@intFromEnum(ViewField.hborder)][i];
            v.vborder = self.arrays[@intFromEnum(ViewField.vborder)][i];
            v.hspeed = self.arrays[@intFromEnum(ViewField.hspeed)][i];
            v.vspeed = self.arrays[@intFromEnum(ViewField.vspeed)][i];
            v.objid = self.arrays[@intFromEnum(ViewField.object)][i];
            v.surface_id = self.arrays[@intFromEnum(ViewField.surface_id)][i];
            v.camera = self.arrays[@intFromEnum(ViewField.camera)][i];
        }
    }

    pub fn getViewVar(self: *const ViewManager, field: ViewField, index: usize) f32 {
        const f_idx = @intFromEnum(field);
        if (f_idx >= VIEW_FIELD_COUNT or index >= VIEW_COUNT) {
            return 0.0;
        }
        return self.arrays[f_idx][index];
    }

    pub fn setViewVar(self: *ViewManager, field: ViewField, index: usize, val: f32) void {
        const f_idx = @intFromEnum(field);
        if (f_idx < VIEW_FIELD_COUNT and index < VIEW_COUNT) {
            self.arrays[f_idx][index] = val;
        }
    }

    pub fn enabled(self: *const ViewManager) bool {
        return self.is_enabled;
    }

    pub fn setEnabled(self: *ViewManager, val: bool) void {
        self.is_enabled = val;
    }

    pub fn roomStart(self: *ViewManager, room: i32, def: *const room_mod.RoomDef) void {
        self.is_enabled = def.enable_views;
        self.in_room = true;
        const ur: ?usize = if (room >= 0 and @as(usize, @intCast(room)) < self.store_count) @intCast(room) else null;

        for (0..VIEW_COUNT) |i| {
            const st: ?*const ViewStore = if (ur) |r_idx| &self.store[r_idx][i] else null;
            const d = if (st != null) &st.?.def else &def.views[i];
            const v = &self.views[i];

            v.visible = d.visible;
            v.worldx = @floatFromInt(d.xview);
            v.worldy = @floatFromInt(d.yview);
            v.worldw = @floatFromInt(d.wview);
            v.worldh = @floatFromInt(d.hview);
            v.portx = @floatFromInt(d.xport);
            v.porty = @floatFromInt(d.yport);
            v.portw = @floatFromInt(d.wport);
            v.porth = @floatFromInt(d.hport);
            v.angle = 0.0;
            v.hborder = @floatFromInt(d.hborder);
            v.vborder = @floatFromInt(d.vborder);
            v.hspeed = @floatFromInt(d.hspeed);
            v.vspeed = @floatFromInt(d.vspeed);
            v.objid = @floatFromInt(d.object);
            v.surface_id = -1.0;

            var cam_id: i32 = -1;
            if (st != null and st.?.camera >= 0) {
                cam_id = self.cameraClone(st.?.camera);
            } else {
                if (self.cameraNew()) |c| {
                    c.x = v.worldx;
                    c.y = v.worldy;
                    c.w = v.worldw;
                    c.h = v.worldh;
                    c.speed_x = v.hspeed;
                    c.speed_y = v.vspeed;
                    c.border_x = v.hborder;
                    c.border_y = v.vborder;
                    c.target = d.object;
                    c.cloned = true;
                    cam_id = c.id;
                }
            }
            v.camera = @floatFromInt(cam_id);
        }
        self.viewsToArrays();
    }

    pub fn roomEnd(self: *ViewManager) void {
        for (0..MAX_CAMERAS) |i| {
            if (self.cam_used[i] and self.cams[i].cloned) {
                self.cam_used[i] = false;
            }
        }
        self.in_room = false;
    }

    pub fn roomCamera(self: *const ViewManager, room: i32, view: usize) i32 {
        if (room < 0 or @as(usize, @intCast(room)) >= self.store_count or view >= VIEW_COUNT) {
            return -1;
        }
        return self.store[@intCast(room)][view].camera;
    }

    pub fn roomSetCamera(self: *ViewManager, room: i32, view: usize, camera: i32) void {
        if (room >= 0 and @as(usize, @intCast(room)) < self.store_count and view < VIEW_COUNT) {
            self.store[@intCast(room)][view].camera = camera;
        }
    }

    pub fn roomSetViewport(self: *ViewManager, room: i32, view: usize, vis: bool, x: i32, y: i32, w: i32, h: i32) void {
        if (room >= 0 and @as(usize, @intCast(room)) < self.store_count and view < VIEW_COUNT) {
            const d = &self.store[@intCast(room)][view].def;
            d.visible = vis;
            d.xport = x;
            d.yport = y;
            d.wport = w;
            d.hport = h;
        }
    }

    fn cameraTarget(target: i32) ?*Instance {
        if (target < 0) return null;
        const mgr = InstanceManager.get();
        if (target < 10000) {
            var cursor = InstanceCursor{};
            mgr.searchBegin(&cursor, target);
            return mgr.searchNext(&cursor, target);
        }
        const inst = mgr.findById(target);
        return if (inst != null and inst.?.active and !inst.?.marked_for_destroy) inst else null;
    }

    pub fn cameraFollow(cam: *Camera, room_width: f32, room_height: f32) void {
        const inst = cameraTarget(cam.target) orelse return;
        var l = cam.x;
        var t = cam.y;
        const ix = @floor(inst.x);
        const iy = @floor(inst.y);

        if (2.0 * cam.border_x >= cam.w) {
            l = ix - cam.w * 0.5;
        } else if (ix - cam.border_x < cam.x) {
            l = ix - cam.border_x;
        } else if (ix + cam.border_x > cam.x + cam.w) {
            l = ix + cam.border_x - cam.w;
        }

        if (2.0 * cam.border_y >= cam.h) {
            t = iy - cam.h * 0.5;
        } else if (iy - cam.border_y < cam.y) {
            t = iy - cam.border_y;
        } else if (iy + cam.border_y > cam.y + cam.h) {
            t = iy + cam.border_y - cam.h;
        }

        if (l < 0.0) l = 0.0;
        if (l + cam.w > room_width) l = room_width - cam.w;
        if (t < 0.0) t = 0.0;
        if (t + cam.h > room_height) t = room_height - cam.h;

        if (cam.speed_x >= 0.0) {
            if (l < cam.x and cam.x - l > cam.speed_x) {
                l = cam.x - cam.speed_x;
            }
            if (l > cam.x and l - cam.x > cam.speed_x) {
                l = cam.x + cam.speed_x;
            }
        }
        if (cam.speed_y >= 0.0) {
            if (t < cam.y and cam.y - t > cam.speed_y) {
                t = cam.y - cam.speed_y;
            }
            if (t > cam.y and t - cam.y > cam.speed_y) {
                t = cam.y + cam.speed_y;
            }
        }
        cam.x = l;
        cam.y = t;
    }

    pub fn update(self: *ViewManager) void {
        if (!self.is_enabled or !self.in_room) return;
        self.arraysToViews();
        const rm_w = room_mod.RoomManager.get().getWidth();
        const rm_h = room_mod.RoomManager.get().getHeight();
        for (0..VIEW_COUNT) |i| {
            if (!self.views[i].visible) continue;
            const cam_id: i32 = @intFromFloat(self.views[i].camera);
            if (self.cameraGet(cam_id)) |cam| {
                cameraFollow(cam, rm_w, rm_h);
            }
        }
        self.viewsToArrays();
    }
};

test "View and Camera creation, clone, follow clamp, and array sync" {
    var vm = ViewManager.get();
    vm.reset();

    const cam1 = vm.cameraCreateView(0.0, 0.0, 320.0, 240.0, 0.0, -1, -1.0, -1.0, 32.0, 32.0);
    try std.testing.expect(cam1 >= 0);
    try std.testing.expectEqual(@as(usize, 1), vm.cameraCount());

    const c = vm.cameraGet(cam1);
    try std.testing.expect(c != null);
    try std.testing.expectEqual(@as(f32, 320.0), c.?.w);

    vm.cameraDestroy(cam1);
    try std.testing.expectEqual(@as(usize, 0), vm.cameraCount());
    try std.testing.expect(vm.cameraGet(cam1) == null);
}
