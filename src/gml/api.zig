//! Hand-written bindings for the GML built-ins the runtime implements
//! (`impl == runtime` in tools/gml2c/gml_builtins.py, bound as `bind` by
//! tools/gml2c/c_api.py). Ports packaged_src/src/gml/gml_api*.c.
//!
//! Bindings are named after the GML built-in and take `(self, other,
//! args...)` with the parameter kinds of c_api's signature table: `f32` (r),
//! `[]const u8` (s) or `Value` (v); variadic built-ins take `[]const Value`.
//! The generated gml_api.zig resolves every `runtime` built-in to the
//! declaration of the same name here (tests/tools/test_zig_api_bindings.py
//! keeps the two sets equal).
//!
//! Conventions: instance results are ids (noone when absent), booleans 0/1,
//! integer arguments go through yyGetInt32, and strings borrowed from runtime
//! storage (ds_map entries, file read buffers, layer names) are copied into
//! the event scratch before they reach GML code.
//!
//! Built-in variables: `gget_<name>` / `gset_<name>` for the hand-owned
//! globals (c_api.HAND_GLOBALS) and `iget_<name>` for the computed instance
//! variables (c_api.HAND_COMPUTED_IVARS).

const std = @import("std");
const runtime = @import("runtime");
const rt = @import("rt.zig");

const math = runtime.math;
const collision = runtime.collision;
const rt_string = runtime.string;
const Value = runtime.Value;
const Instance = runtime.Instance;
const Layer = runtime.Layer;
const Element = runtime.Element;
const ViewField = runtime.ViewField;

const id = rt.id;
const b2r = rt.b2r;
const target = rt.target;
const truthy = rt.truthy;

fn i32_(d: f32) i32 {
    return math.toInt32(d);
}

fn sm() *runtime.StringManager {
    return runtime.StringManager.get();
}

fn instances() *runtime.InstanceManager {
    return runtime.InstanceManager.get();
}

/// Detaches a value from runtime-owned string storage.
fn own(v: Value) Value {
    return if (v == .string) Value.fromString(sm().temp(v.string)) else v;
}

/// NUL-terminated copy for the platform layer (event scratch).
fn cstr(s: []const u8) [*:0]const u8 {
    const buf = sm().scratch.allocator().allocSentinel(u8, s.len, 0) catch {
        _ = sm().fail();
        return "";
    };
    @memcpy(buf, s);
    return buf.ptr;
}

/// A temporary GML array of reals.
fn realArray(items: []const i32) Value {
    const arrays = runtime.ArrayManager.get();
    var a = arrays.newArray(items.len);
    for (items, 0..) |item, i| arrays.set(.local(&a), @intCast(i), Value.fromReal(@floatFromInt(item)));
    return a;
}

// ---------------------------------------------------------------------------
// Maths
// ---------------------------------------------------------------------------

pub fn randomize(_: *Instance, _: *Instance) f32 {
    return @floatFromInt(math.randomize());
}

pub fn move_snap(self: *Instance, _: *Instance, h: f32, v: f32) void {
    collision.moveSnap(self, h, v);
}

// ---------------------------------------------------------------------------
// Instances
// ---------------------------------------------------------------------------

pub fn instance_create_depth(_: *Instance, _: *Instance, x: f32, y: f32, depth: f32, obj: f32) f32 {
    return id(instances().createDepth(x, y, depth, target(obj)));
}

/// instance_destroy([id [, execute_event]]) (Function_Instance.js L1370): the
/// GetWithArray snapshot, like with(id).
pub fn instance_destroy(self: *Instance, other: *Instance, args: []const Value) void {
    if (args.len >= 2 and !args[1].toBool()) {
        // Destroy without the Destroy event is not supported by the runtime.
        rt.pendingHit("instance_destroy(id, false)");
    }
    if (args.len == 0) {
        instances().destroy(self);
        return;
    }
    var it = runtime.WithIterator.init(target(args[0].toReal()), self, other);
    defer it.deinit();
    while (it.next()) |p| instances().destroy(p);
}

pub fn instance_exists(self: *Instance, other: *Instance, obj: f32) f32 {
    return b2r(instances().resolve(target(obj), self, other) != null);
}

pub fn instance_number(self: *Instance, other: *Instance, obj: f32) f32 {
    return @floatFromInt(instances().number(target(obj), self, other));
}

pub fn instance_find(self: *Instance, other: *Instance, obj: f32, n: f32) f32 {
    return id(instances().find(target(obj), i32_(n), self, other));
}

pub fn instance_nearest(_: *Instance, _: *Instance, x: f32, y: f32, obj: f32) f32 {
    return id(instances().nearest(x, y, target(obj)));
}

pub fn instance_activate_all(_: *Instance, _: *Instance) void {
    instances().activateAll();
}

pub fn instance_activate_object(_: *Instance, _: *Instance, obj: f32) void {
    instances().activateObject(target(obj));
}

pub fn instance_deactivate_all(self: *Instance, _: *Instance, notme: f32) void {
    instances().deactivateAll(truthy(notme), self);
}

pub fn instance_deactivate_object(_: *Instance, _: *Instance, obj: f32) void {
    instances().deactivateObject(target(obj));
}

pub fn object_get_parent(_: *Instance, _: *Instance, obj: f32) f32 {
    return @floatFromInt(runtime.ObjectRegistry.get().getParent(target(obj)));
}

/// asset_get_index: objects, then sprites, then rooms; -1 when no asset has
/// that name.
pub fn asset_get_index(_: *Instance, _: *Instance, name: []const u8) f32 {
    const objects = runtime.ObjectRegistry.get();
    for (0..objects.countObjects()) |i| {
        const def = objects.getDef(@intCast(i)) orelse continue;
        if (std.mem.eql(u8, def.name, name)) return @floatFromInt(i);
    }
    const sprites = runtime.SpriteRegistry.get();
    for (0..sprites.count) |i| {
        const def = sprites.getSprite(@intCast(i)) orelse continue;
        if (std.mem.eql(u8, def.name, name)) return @floatFromInt(i);
    }
    const room_mgr = runtime.RoomManager.get();
    for (0..room_mgr.count()) |i| {
        if (std.mem.eql(u8, room_mgr.getName(@intCast(i)), name)) return @floatFromInt(i);
    }
    return -1.0;
}

pub fn event_perform(self: *Instance, other: *Instance, ev_type: f32, number: f32) void {
    runtime.LoopManager.get().eventPerform(self, other, i32_(ev_type), i32_(number));
}

// ---------------------------------------------------------------------------
// Collisions
// ---------------------------------------------------------------------------

pub fn place_meeting(self: *Instance, _: *Instance, x: f32, y: f32, obj: f32) f32 {
    return b2r(collision.placeMeeting(self, x, y, target(obj)));
}

pub fn instance_place(self: *Instance, _: *Instance, x: f32, y: f32, obj: f32) f32 {
    return id(collision.instancePlace(self, x, y, target(obj)));
}

pub fn instance_position(_: *Instance, _: *Instance, x: f32, y: f32, obj: f32) f32 {
    return id(collision.instancePosition(x, y, target(obj)));
}

pub fn collision_point(self: *Instance, _: *Instance, x: f32, y: f32, obj: f32, prec: f32, notme: f32) f32 {
    return id(collision.collisionPoint(self, x, y, target(obj), truthy(prec), truthy(notme)));
}

pub fn collision_rectangle(self: *Instance, _: *Instance, x1: f32, y1: f32, x2: f32, y2: f32, obj: f32, prec: f32, notme: f32) f32 {
    return id(collision.collisionRectangle(self, x1, y1, x2, y2, target(obj), truthy(prec), truthy(notme)));
}

pub fn collision_line(self: *Instance, _: *Instance, x1: f32, y1: f32, x2: f32, y2: f32, obj: f32, prec: f32, notme: f32) f32 {
    return id(collision.collisionLine(self, x1, y1, x2, y2, target(obj), truthy(prec), truthy(notme)));
}

pub fn distance_to_object(self: *Instance, _: *Instance, obj: f32) f32 {
    return collision.distanceToObject(self, target(obj));
}

pub fn distance_to_point(self: *Instance, _: *Instance, x: f32, y: f32) f32 {
    return collision.distanceToPoint(self, x, y);
}

// ---------------------------------------------------------------------------
// ds_map
// ---------------------------------------------------------------------------

fn maps() *runtime.DsManager {
    return runtime.DsManager.get();
}

pub fn ds_map_create(_: *Instance, _: *Instance) f32 {
    return if (maps().create()) |m| @floatFromInt(m) else -1.0;
}

pub fn ds_map_destroy(_: *Instance, _: *Instance, map: f32) void {
    maps().destroy(target(map));
}

pub fn ds_map_exists(_: *Instance, _: *Instance, map: f32, key: []const u8) f32 {
    return b2r(maps().exists(target(map), key));
}

pub fn ds_map_find_first(_: *Instance, _: *Instance, map: f32) Value {
    return own(maps().findFirst(target(map)));
}

pub fn ds_map_find_next(_: *Instance, _: *Instance, map: f32, key: []const u8) Value {
    return own(maps().findNext(target(map), key));
}

pub fn ds_map_find_value(_: *Instance, _: *Instance, map: f32, key: []const u8) Value {
    return own(maps().findValue(target(map), key));
}

pub fn ds_map_replace(_: *Instance, _: *Instance, map: f32, key: []const u8, v: Value) void {
    var val = v;
    if (val == .array_ref) {
        rt.pendingHit("ds_map_replace(<array value>)");
        val = Value.UNDEFINED;
    }
    _ = maps().replace(target(map), key, val);
}

pub fn ds_map_size(_: *Instance, _: *Instance, map: f32) f32 {
    return @floatFromInt(maps().size(target(map)));
}

// ---------------------------------------------------------------------------
// Files
// ---------------------------------------------------------------------------

fn files() *runtime.FileManager {
    return runtime.FileManager.get();
}

pub fn file_exists(_: *Instance, _: *Instance, path: []const u8) f32 {
    return b2r(files().fileExists(path));
}

pub fn file_delete(_: *Instance, _: *Instance, path: []const u8) f32 {
    return b2r(files().fileDelete(path));
}

pub fn file_text_open_read(_: *Instance, _: *Instance, path: []const u8) f32 {
    return if (files().openRead(path)) |h| @floatFromInt(h) else -1.0;
}

pub fn file_text_open_write(_: *Instance, _: *Instance, path: []const u8) f32 {
    return if (files().openWrite(path)) |h| @floatFromInt(h) else -1.0;
}

pub fn file_text_close(_: *Instance, _: *Instance, h: f32) void {
    files().close(target(h));
}

pub fn file_text_eof(_: *Instance, _: *Instance, h: f32) f32 {
    return b2r(files().eof(target(h)));
}

pub fn file_text_read_string(_: *Instance, _: *Instance, h: f32) []const u8 {
    return sm().temp(files().readString(target(h)));
}

pub fn file_text_readln(_: *Instance, _: *Instance, h: f32) []const u8 {
    return sm().temp(files().readln(target(h)));
}

pub fn file_text_write_string(_: *Instance, _: *Instance, h: f32, s: []const u8) void {
    files().writeString(target(h), s);
}

pub fn file_text_writeln(_: *Instance, _: *Instance, h: f32) void {
    files().writeln(target(h));
}

fn ini() *runtime.Ini {
    return runtime.Ini.get();
}

pub fn ini_open(_: *Instance, _: *Instance, path: []const u8) void {
    ini().open(path);
}

pub fn ini_close(_: *Instance, _: *Instance) []const u8 {
    return sm().temp(ini().close());
}

pub fn ini_read_real(_: *Instance, _: *Instance, section: []const u8, key: []const u8, def: f32) f32 {
    return ini().readReal(section, key, def);
}

pub fn ini_write_real(_: *Instance, _: *Instance, section: []const u8, key: []const u8, v: f32) void {
    _ = ini().writeReal(section, key, v);
}

pub fn ini_write_string(_: *Instance, _: *Instance, section: []const u8, key: []const u8, v: []const u8) void {
    _ = ini().writeString(section, key, v);
}

// ---------------------------------------------------------------------------
// Strings (Function_String.js; indices through yyGetInt32)
// ---------------------------------------------------------------------------

pub fn string(_: *Instance, _: *Instance, v: Value) []const u8 {
    return rt.asStr(v);
}

pub fn ord(_: *Instance, _: *Instance, s: []const u8) f32 {
    return rt_string.ord(s);
}

pub fn string_char_at(_: *Instance, _: *Instance, s: []const u8, index: f32) []const u8 {
    return sm().charAt(s, index);
}

pub fn string_delete(_: *Instance, _: *Instance, s: []const u8, index: f32, count: f32) []const u8 {
    return sm().delete(s, index, count);
}

pub fn string_insert(_: *Instance, _: *Instance, substr: []const u8, s: []const u8, index: f32) []const u8 {
    return sm().insert(substr, s, index);
}

pub fn string_length(_: *Instance, _: *Instance, s: []const u8) f32 {
    return @floatFromInt(rt_string.length(s));
}

pub fn string_lower(_: *Instance, _: *Instance, s: []const u8) []const u8 {
    return sm().lower(s);
}

pub fn string_upper(_: *Instance, _: *Instance, s: []const u8) []const u8 {
    return sm().upper(s);
}

pub fn string_pos(_: *Instance, _: *Instance, substr: []const u8, s: []const u8) f32 {
    return @floatFromInt(rt_string.pos(substr, s));
}

pub fn string_hash_to_newline(_: *Instance, _: *Instance, s: []const u8) []const u8 {
    return sm().hashToNewline(s);
}

// ---------------------------------------------------------------------------
// Sprites and fonts
// ---------------------------------------------------------------------------

fn drawing() *runtime.DrawManager {
    return runtime.DrawManager.get();
}

pub fn sprite_exists(_: *Instance, _: *Instance, spr: f32) f32 {
    return b2r(runtime.SpriteRegistry.get().getSprite(target(spr)) != null);
}

pub fn sprite_get_width(_: *Instance, _: *Instance, spr: f32) f32 {
    return @floatFromInt(drawing().spriteWidth(i32_(spr)));
}

pub fn sprite_get_height(_: *Instance, _: *Instance, spr: f32) f32 {
    return @floatFromInt(drawing().spriteHeight(i32_(spr)));
}

/// `removeback` and `smooth` do not apply to the port's renderer.
pub fn sprite_add(_: *Instance, _: *Instance, path: []const u8, n: f32, removeback: f32, smooth: f32, xorig: f32, yorig: f32) f32 {
    _ = removeback;
    _ = smooth;
    return @floatFromInt(drawing().spriteAdd(cstr(path), i32_(n), xorig, yorig));
}

/// Only the size is used: the host renders a fixed font face.
pub fn font_add(_: *Instance, _: *Instance, path: []const u8, size: f32, bold: f32, italic: f32, first: f32, last: f32) f32 {
    _ = bold;
    _ = italic;
    _ = first;
    _ = last;
    return @floatFromInt(drawing().fontAdd(cstr(path), i32_(size)));
}

var font_sprite_calls: u32 = 0;

/// The host registers the sprite fonts at start-up: font 0 = sFont (16 px
/// glyphs), font 1 = sFontSmall (8 px). setLocale passes sprite_add copies of
/// the locale charset, so the glyph width picks the font. A host that cannot
/// load them (width unknown) gets setLocale's order: large, then small.
pub fn font_add_sprite_ext(_: *Instance, _: *Instance, spr: f32, map: []const u8, prop: f32, sep: f32) f32 {
    _ = map;
    _ = prop;
    _ = sep;
    const w = drawing().spriteWidth(i32_(spr));
    if (w <= 0) {
        const font: f32 = @floatFromInt(font_sprite_calls % 2);
        font_sprite_calls +%= 1;
        return font;
    }
    return if (w >= 16) 0.0 else 1.0;
}

// ---------------------------------------------------------------------------
// Rooms (Function_Room.js)
// ---------------------------------------------------------------------------

fn rooms() *runtime.RoomManager {
    return runtime.RoomManager.get();
}

pub fn room_goto(_: *Instance, _: *Instance, r: f32) void {
    _ = rooms().roomGoto(i32_(r));
}

pub fn room_goto_next(_: *Instance, _: *Instance) void {
    rooms().roomGotoNext();
}

pub fn room_restart(_: *Instance, _: *Instance) void {
    rooms().roomRestart();
}

pub fn room_exists(_: *Instance, _: *Instance, r: f32) f32 {
    return b2r(rooms().exists(i32_(r)));
}

/// Static table strings.
pub fn room_get_name(_: *Instance, _: *Instance, r: f32) []const u8 {
    return rooms().getName(i32_(r));
}

fn viewIndex(v: f32) ?usize {
    const i = i32_(v);
    return if (i < 0) null else @intCast(i);
}

pub fn room_get_camera(_: *Instance, _: *Instance, r: f32, v: f32) f32 {
    const vi = viewIndex(v) orelse return -1.0;
    return @floatFromInt(views().roomCamera(i32_(r), vi));
}

pub fn room_set_camera(_: *Instance, _: *Instance, r: f32, v: f32, cam: f32) void {
    const vi = viewIndex(v) orelse return;
    views().roomSetCamera(i32_(r), vi, i32_(cam));
}

pub fn room_set_viewport(_: *Instance, _: *Instance, r: f32, v: f32, vis: f32, x: f32, y: f32, w: f32, h: f32) void {
    const vi = viewIndex(v) orelse return;
    views().roomSetViewport(i32_(r), vi, truthy(vis), i32_(x), i32_(y), i32_(w), i32_(h));
}

/// room (get_current_room / set_current_room = room_goto, yyBuiltIn.js L194).
pub fn gget_room() f32 {
    return @floatFromInt(rooms().current());
}

pub fn gset_room(v: f32) void {
    _ = rooms().roomGoto(i32_(v));
}

pub fn gget_room_first() f32 {
    return @floatFromInt(rooms().first());
}

pub fn gget_room_last() f32 {
    return @floatFromInt(rooms().last());
}

pub fn gget_room_width() f32 {
    return rooms().getWidth();
}

pub fn gset_room_width(v: f32) void {
    rooms().setWidth(v);
}

pub fn gget_room_height() f32 {
    return rooms().getHeight();
}

pub fn gset_room_height(v: f32) void {
    rooms().setHeight(v);
}

pub fn gget_room_speed() f32 {
    return rooms().getSpeed();
}

pub fn gset_room_speed(v: f32) void {
    rooms().setSpeed(v);
}

pub fn gget_room_persistent() f32 {
    return b2r(rooms().isPersistent());
}

pub fn gset_room_persistent(v: f32) void {
    rooms().setPersistent(truthy(v));
}

pub fn gget_room_caption() []const u8 {
    return sm().temp(rooms().getCaption());
}

pub fn gset_room_caption(v: []const u8) void {
    rooms().setCaption(v);
}

// ---------------------------------------------------------------------------
// Views (Function_Graphics.js L2876-2930)
// ---------------------------------------------------------------------------

fn views() *runtime.ViewManager {
    return runtime.ViewManager.get();
}

fn viewGet(field: ViewField, i: f32) f32 {
    const vi = viewIndex(i) orelse return 0.0;
    return views().getViewVar(field, vi);
}

fn viewSet(field: ViewField, i: f32, v: f32) void {
    const vi = viewIndex(i) orelse return;
    views().setViewVar(field, vi, v);
}

pub fn gget_view_enabled() f32 {
    return b2r(views().enabled());
}

pub fn gset_view_enabled(v: f32) void {
    views().setEnabled(truthy(v));
}

/// Set while the loop draws each view.
pub fn gget_view_current() f32 {
    return @floatFromInt(views().current());
}

fn ViewArray(comptime field: ViewField) type {
    return struct {
        fn get(i: f32) f32 {
            return viewGet(field, i);
        }
        fn set(i: f32, v: f32) void {
            viewSet(field, i, v);
        }
    };
}

pub const gget_view_visible = ViewArray(.visible).get;
pub const gset_view_visible = ViewArray(.visible).set;
pub const gget_view_xview = ViewArray(.xview).get;
pub const gset_view_xview = ViewArray(.xview).set;
pub const gget_view_yview = ViewArray(.yview).get;
pub const gset_view_yview = ViewArray(.yview).set;
pub const gget_view_wview = ViewArray(.wview).get;
pub const gset_view_wview = ViewArray(.wview).set;
pub const gget_view_hview = ViewArray(.hview).get;
pub const gset_view_hview = ViewArray(.hview).set;
pub const gget_view_angle = ViewArray(.angle).get;
pub const gset_view_angle = ViewArray(.angle).set;
pub const gget_view_hborder = ViewArray(.hborder).get;
pub const gset_view_hborder = ViewArray(.hborder).set;
pub const gget_view_vborder = ViewArray(.vborder).get;
pub const gset_view_vborder = ViewArray(.vborder).set;
pub const gget_view_hspeed = ViewArray(.hspeed).get;
pub const gset_view_hspeed = ViewArray(.hspeed).set;
pub const gget_view_vspeed = ViewArray(.vspeed).get;
pub const gset_view_vspeed = ViewArray(.vspeed).set;
pub const gget_view_object = ViewArray(.object).get;
pub const gset_view_object = ViewArray(.object).set;
pub const gget_view_xport = ViewArray(.xport).get;
pub const gset_view_xport = ViewArray(.xport).set;
pub const gget_view_yport = ViewArray(.yport).get;
pub const gset_view_yport = ViewArray(.yport).set;
pub const gget_view_wport = ViewArray(.wport).get;
pub const gset_view_wport = ViewArray(.wport).set;
pub const gget_view_hport = ViewArray(.hport).get;
pub const gset_view_hport = ViewArray(.hport).set;
pub const gget_view_surface_id = ViewArray(.surface_id).get;
pub const gset_view_surface_id = ViewArray(.surface_id).set;
pub const gget_view_camera = ViewArray(.camera).get;
pub const gset_view_camera = ViewArray(.camera).set;

/// view_get_* / view_set_* read and write the arrays, with yyGetInt32 on writes.
fn ViewGetSet(comptime field: ViewField) type {
    return struct {
        fn get(_: *Instance, _: *Instance, i: f32) f32 {
            return viewGet(field, i);
        }
        fn set(_: *Instance, _: *Instance, i: f32, v: f32) void {
            viewSet(field, i, @floatFromInt(i32_(v)));
        }
    };
}

pub const view_get_camera = ViewGetSet(.camera).get;
pub const view_set_camera = ViewGetSet(.camera).set;
pub const view_get_visible = ViewGetSet(.visible).get;
pub const view_set_visible = ViewGetSet(.visible).set;
pub const view_get_xport = ViewGetSet(.xport).get;
pub const view_set_xport = ViewGetSet(.xport).set;
pub const view_get_yport = ViewGetSet(.yport).get;
pub const view_set_yport = ViewGetSet(.yport).set;
pub const view_get_wport = ViewGetSet(.wport).get;
pub const view_set_wport = ViewGetSet(.wport).set;
pub const view_get_hport = ViewGetSet(.hport).get;
pub const view_set_hport = ViewGetSet(.hport).set;
pub const view_get_surface_id = ViewGetSet(.surface_id).get;
pub const view_set_surface_id = ViewGetSet(.surface_id).set;

// ---------------------------------------------------------------------------
// Cameras (CameraManager.js L704-1148)
// ---------------------------------------------------------------------------

/// camera_create_view(x, y, w, h [, angle, target, speedx, speedy, borderx, bordery]).
pub fn camera_create_view(_: *Instance, _: *Instance, args: []const Value) f32 {
    var a = [10]f32{ 0, 0, 0, 0, 0, -1, -1, -1, 0, 0 };
    for (args[0..@min(args.len, a.len)], 0..) |v, i| a[i] = v.toReal();
    return @floatFromInt(views().cameraCreateView(a[0], a[1], a[2], a[3], a[4], i32_(a[5]), a[6], a[7], a[8], a[9]));
}

pub fn camera_destroy(_: *Instance, _: *Instance, cam: f32) void {
    views().cameraDestroy(i32_(cam));
}

fn camera(cam: f32) ?*runtime.Camera {
    return views().cameraGet(i32_(cam));
}

fn CameraGet(comptime field: []const u8) type {
    return struct {
        fn get(_: *Instance, _: *Instance, cam: f32) f32 {
            const c = camera(cam) orelse return -1.0;
            const v = @field(c, field);
            return if (@TypeOf(v) == f32) v else @floatFromInt(v);
        }
    };
}

pub const camera_get_view_x = CameraGet("x").get;
pub const camera_get_view_y = CameraGet("y").get;
pub const camera_get_view_width = CameraGet("w").get;
pub const camera_get_view_height = CameraGet("h").get;
pub const camera_get_view_angle = CameraGet("angle").get;
pub const camera_get_view_border_x = CameraGet("border_x").get;
pub const camera_get_view_border_y = CameraGet("border_y").get;
pub const camera_get_view_speed_x = CameraGet("speed_x").get;
pub const camera_get_view_speed_y = CameraGet("speed_y").get;
pub const camera_get_view_target = CameraGet("target").get;

fn CameraSet2(comptime fa: []const u8, comptime fb: []const u8) type {
    return struct {
        fn set(_: *Instance, _: *Instance, cam: f32, a: f32, b: f32) void {
            const c = camera(cam) orelse return;
            @field(c, fa) = a;
            @field(c, fb) = b;
        }
    };
}

pub const camera_set_view_pos = CameraSet2("x", "y").set;
pub const camera_set_view_size = CameraSet2("w", "h").set;
pub const camera_set_view_border = CameraSet2("border_x", "border_y").set;
pub const camera_set_view_speed = CameraSet2("speed_x", "speed_y").set;

pub fn camera_set_view_angle(_: *Instance, _: *Instance, cam: f32, angle: f32) void {
    if (camera(cam)) |c| c.angle = angle;
}

pub fn camera_set_view_target(_: *Instance, _: *Instance, cam: f32, obj: f32) void {
    if (camera(cam)) |c| c.target = i32_(obj);
}

// ---------------------------------------------------------------------------
// Layers (Function_Layers.js): "layer" arguments are an id or, for strings,
// a layer name (layerGetObj, L2317).
// ---------------------------------------------------------------------------

fn layers() *runtime.LayerManager {
    return runtime.LayerManager.get();
}

fn layerOf(v: Value) ?*Layer {
    if (v == .string) return layers().findName(v.string);
    return layers().find(i32_(v.toReal()));
}

/// layer_create(depth [, name])
pub fn layer_create(_: *Instance, _: *Instance, args: []const Value) f32 {
    if (args.len < 1) return -1.0;
    const name: ?[]const u8 = if (args.len >= 2) rt.asStr(args[1]) else null;
    return @floatFromInt(layers().create(i32_(args[0].toReal()), name));
}

pub fn layer_destroy(_: *Instance, _: *Instance, l: Value) void {
    if (layerOf(l)) |layer| layers().destroy(layer.id);
}

pub fn layer_depth(_: *Instance, _: *Instance, l: Value, depth: f32) void {
    if (layerOf(l)) |layer| layers().setDepth(layer.id, i32_(depth));
}

pub fn layer_get_depth(_: *Instance, _: *Instance, l: Value) f32 {
    const layer = layerOf(l) orelse return -1.0;
    return @floatFromInt(layer.depth);
}

/// Layer names can change: copied.
pub fn layer_get_name(_: *Instance, _: *Instance, l: Value) []const u8 {
    const layer = layerOf(l) orelse return "";
    return sm().temp(layer.getName());
}

pub fn layer_get_all(_: *Instance, _: *Instance) Value {
    var ids: [runtime.layer.MAX_LAYERS]i32 = undefined;
    return realArray(ids[0..layers().getAll(&ids)]);
}

var element_ids: [runtime.layer.MAX_ELEMENTS]i32 = undefined;

pub fn layer_get_all_elements(_: *Instance, _: *Instance, l: Value) Value {
    const layer = layerOf(l) orelse return realArray(&.{});
    return realArray(element_ids[0..layers().elements(layer.id, &element_ids)]);
}

pub fn layer_get_element_type(_: *Instance, _: *Instance, el: f32) f32 {
    return @floatFromInt(layers().elementType(i32_(el)));
}

pub fn layer_get_visible(_: *Instance, _: *Instance, l: Value) f32 {
    const layer = layerOf(l) orelse return 0.0;
    return b2r(layer.visible);
}

pub fn layer_set_visible(_: *Instance, _: *Instance, l: Value, v: f32) void {
    if (layerOf(l)) |layer| layer.visible = truthy(v);
}

fn LayerField(comptime field: []const u8) type {
    return struct {
        fn get(_: *Instance, _: *Instance, l: Value) f32 {
            const layer = layerOf(l) orelse return 0.0;
            return @field(layer, field);
        }
        fn set(_: *Instance, _: *Instance, l: Value, v: f32) void {
            if (layerOf(l)) |layer| @field(layer, field) = v;
        }
    };
}

pub const layer_get_x = LayerField("x").get;
pub const layer_x = LayerField("x").set;
pub const layer_get_y = LayerField("y").get;
pub const layer_y = LayerField("y").set;
pub const layer_get_hspeed = LayerField("hspeed").get;
pub const layer_hspeed = LayerField("hspeed").set;
pub const layer_get_vspeed = LayerField("vspeed").get;
pub const layer_vspeed = LayerField("vspeed").set;

// ---- backgrounds (layerBackgroudGetElement, Function_Layers.js L2721) ----

fn elementOfType(el: f32, kind: i32) ?*Element {
    const e = layers().element(i32_(el)) orelse return null;
    return if (e.type == kind) e else null;
}

fn background(el: f32) ?*Element {
    return elementOfType(el, runtime.layer.ELEMENT_BACKGROUND);
}

pub fn layer_background_create(_: *Instance, _: *Instance, l: Value, spr: f32) f32 {
    const layer = layerOf(l) orelse return -1.0;
    return @floatFromInt(layers().backgroundCreate(layer.id, i32_(spr)));
}

pub fn layer_background_exists(_: *Instance, _: *Instance, l: Value, el: f32) f32 {
    const layer = layerOf(l) orelse return 0.0;
    return b2r(layers().backgroundExists(layer.id, i32_(el)));
}

pub fn layer_background_change(_: *Instance, _: *Instance, el: f32, spr: f32) void {
    if (background(el)) |e| e.sprite = i32_(spr);
}

fn toReal(v: anytype) f32 {
    return switch (@TypeOf(v)) {
        f32 => v,
        bool => b2r(v),
        else => @floatFromInt(v),
    };
}

fn BackgroundGet(comptime field: []const u8, comptime missing: f32) type {
    return struct {
        fn get(_: *Instance, _: *Instance, el: f32) f32 {
            const e = background(el) orelse return missing;
            return toReal(@field(e, field));
        }
    };
}

pub const layer_background_get_sprite = BackgroundGet("sprite", -1.0).get;
pub const layer_background_get_index = BackgroundGet("image_index", -1.0).get;
pub const layer_background_get_alpha = BackgroundGet("alpha", 0.0).get;
pub const layer_background_get_blend = BackgroundGet("blend", 0.0).get;
pub const layer_background_get_htiled = BackgroundGet("htiled", 0.0).get;
pub const layer_background_get_vtiled = BackgroundGet("vtiled", 0.0).get;
pub const layer_background_get_stretch = BackgroundGet("stretch", 0.0).get;
pub const layer_background_get_xscale = BackgroundGet("xscale", 1.0).get;
pub const layer_background_get_yscale = BackgroundGet("yscale", 1.0).get;

fn BackgroundSet(comptime field: []const u8) type {
    return struct {
        fn set(_: *Instance, _: *Instance, el: f32, v: f32) void {
            const e = background(el) orelse return;
            const T = @TypeOf(@field(e, field));
            @field(e, field) = switch (T) {
                f32 => v,
                bool => truthy(v),
                u32 => @as(u32, @bitCast(i32_(v))) & 0xFFFFFF, // blend: BGR colour
                else => @compileError("unsupported background field " ++ field),
            };
        }
    };
}

pub const layer_background_alpha = BackgroundSet("alpha").set;
pub const layer_background_blend = BackgroundSet("blend").set;
pub const layer_background_htiled = BackgroundSet("htiled").set;
pub const layer_background_vtiled = BackgroundSet("vtiled").set;
pub const layer_background_stretch = BackgroundSet("stretch").set;
pub const layer_background_visible = BackgroundSet("visible").set;
pub const layer_background_xscale = BackgroundSet("xscale").set;
pub const layer_background_yscale = BackgroundSet("yscale").set;

// ---- tiles ----

fn tile(el: f32) ?*Element {
    return elementOfType(el, runtime.layer.ELEMENT_TILE);
}

/// layer_tile_create(layer, x, y, sprite, left, top, width, height) (L5057).
pub fn layer_tile_create(_: *Instance, _: *Instance, l: Value, x: f32, y: f32, spr: f32, left: f32, top: f32, w: f32, h: f32) f32 {
    const layer = layerOf(l) orelse return 0.0; // the runner returns undefined
    return @floatFromInt(layers().tileCreate(layer.id, x, y, i32_(spr), i32_(left), i32_(top), i32_(w), i32_(h)));
}

pub fn layer_tile_destroy(_: *Instance, _: *Instance, el: f32) void {
    layers().elementDestroy(i32_(el));
}

pub fn layer_tile_get_region(_: *Instance, _: *Instance, el: f32) Value {
    const e = tile(el) orelse return Value.fromReal(-1.0);
    return realArray(&.{ e.xo, e.yo, e.w, e.h });
}

fn TileGet(comptime field: []const u8, comptime missing: f32) type {
    return struct {
        fn get(_: *Instance, _: *Instance, el: f32) f32 {
            const e = tile(el) orelse return missing;
            return @field(e, field);
        }
    };
}

pub const layer_tile_get_x = TileGet("x", 0.0).get;
pub const layer_tile_get_y = TileGet("y", 0.0).get;
pub const layer_tile_get_xscale = TileGet("xscale", 1.0).get;
pub const layer_tile_get_yscale = TileGet("yscale", 1.0).get;

// ---------------------------------------------------------------------------
// Input (Function_IO.js) and game control (Function_Room.js L875-910)
// ---------------------------------------------------------------------------

fn input() *runtime.InputManager {
    return runtime.InputManager.get();
}

pub fn keyboard_check(_: *Instance, _: *Instance, key: f32) f32 {
    return b2r(input().check(i32_(key)));
}

pub fn keyboard_check_pressed(_: *Instance, _: *Instance, key: f32) f32 {
    return b2r(input().checkPressed(i32_(key)));
}

pub fn keyboard_check_released(_: *Instance, _: *Instance, key: f32) f32 {
    return b2r(input().checkReleased(i32_(key)));
}

pub fn keyboard_set_map(_: *Instance, _: *Instance, from: f32, to: f32) void {
    input().setMap(i32_(from), i32_(to));
}

pub fn gget_keyboard_key() f32 {
    return @floatFromInt(input().getKeyboardKey());
}

pub fn gset_keyboard_key(v: f32) void {
    input().setKeyboardKey(i32_(v));
}

pub fn gget_keyboard_lastkey() f32 {
    return @floatFromInt(input().getKeyboardLastkey());
}

pub fn gset_keyboard_lastkey(v: f32) void {
    input().setKeyboardLastkey(i32_(v));
}

pub fn game_end(_: *Instance, _: *Instance) void {
    rooms().gameEnd();
}

/// The runner also zeroes score / lives / health, which Spelunky does not read.
pub fn game_restart(_: *Instance, _: *Instance) void {
    rooms().gameRestart();
}

// ---------------------------------------------------------------------------
// Drawing (Function_Texture.js: a negative subimage means the calling
// instance's image_index), surfaces, window, audio
// ---------------------------------------------------------------------------

fn subimage(self: *const Instance, sub: f32) f32 {
    return if (sub < 0.0) self.image_index else sub;
}

pub fn draw_self(self: *Instance, _: *Instance) void {
    drawing().drawSelf(self);
}

pub fn draw_sprite(self: *Instance, _: *Instance, spr: f32, sub: f32, x: f32, y: f32) void {
    drawing().drawSprite(i32_(spr), subimage(self, sub), x, y);
}

pub fn draw_sprite_ext(self: *Instance, _: *Instance, spr: f32, sub: f32, x: f32, y: f32, xs: f32, ys: f32, rot: f32, col: f32, alpha: f32) void {
    drawing().drawSpriteExt(i32_(spr), subimage(self, sub), x, y, xs, ys, rot, col, alpha);
}

pub fn draw_sprite_stretched(self: *Instance, _: *Instance, spr: f32, sub: f32, x: f32, y: f32, w: f32, h: f32) void {
    drawing().drawSpriteStretched(i32_(spr), subimage(self, sub), x, y, w, h);
}

pub fn draw_text(_: *Instance, _: *Instance, x: f32, y: f32, text: []const u8) void {
    drawing().drawText(x, y, cstr(text));
}

pub fn draw_rectangle(_: *Instance, _: *Instance, x1: f32, y1: f32, x2: f32, y2: f32, outline: f32) void {
    drawing().drawRectangle(x1, y1, x2, y2, truthy(outline));
}

pub fn draw_circle(_: *Instance, _: *Instance, x: f32, y: f32, r: f32, outline: f32) void {
    drawing().drawCircle(x, y, r, truthy(outline));
}

pub fn draw_clear(_: *Instance, _: *Instance, col: f32) void {
    drawing().drawClear(col);
}

pub fn draw_set_alpha(_: *Instance, _: *Instance, a: f32) void {
    drawing().setAlpha(a);
}

pub fn draw_set_color(_: *Instance, _: *Instance, col: f32) void {
    drawing().setColour(col);
}

pub fn draw_set_colour(_: *Instance, _: *Instance, col: f32) void {
    drawing().setColour(col);
}

pub fn draw_set_font(_: *Instance, _: *Instance, font: f32) void {
    drawing().setFont(i32_(font));
}

pub fn gget_application_surface() f32 {
    return @floatFromInt(runtime.APP_SURFACE);
}

pub fn surface_create(_: *Instance, _: *Instance, w: f32, h: f32) f32 {
    return @floatFromInt(drawing().surfaceCreate(i32_(w), i32_(h)));
}

pub fn surface_exists(_: *Instance, _: *Instance, surf: f32) f32 {
    return b2r(drawing().surfaceExists(i32_(surf)));
}

pub fn surface_free(_: *Instance, _: *Instance, surf: f32) void {
    drawing().surfaceFree(i32_(surf));
}

pub fn surface_resize(_: *Instance, _: *Instance, surf: f32, w: f32, h: f32) void {
    drawing().surfaceResize(i32_(surf), i32_(w), i32_(h));
}

pub fn surface_set_target(_: *Instance, _: *Instance, surf: f32) f32 {
    return b2r(drawing().surfaceSetTarget(i32_(surf)));
}

pub fn surface_reset_target(_: *Instance, _: *Instance) f32 {
    return b2r(drawing().surfaceResetTarget());
}

pub fn draw_surface(_: *Instance, _: *Instance, surf: f32, x: f32, y: f32) void {
    drawing().drawSurface(i32_(surf), x, y);
}

pub fn draw_surface_stretched(_: *Instance, _: *Instance, surf: f32, x: f32, y: f32, w: f32, h: f32) void {
    drawing().drawSurfaceStretched(i32_(surf), x, y, w, h);
}

pub fn window_get_width(_: *Instance, _: *Instance) f32 {
    return @floatFromInt(drawing().windowWidth());
}

pub fn window_get_height(_: *Instance, _: *Instance) f32 {
    return @floatFromInt(drawing().windowHeight());
}

pub fn display_get_width(_: *Instance, _: *Instance) f32 {
    return @floatFromInt(drawing().displayWidth());
}

pub fn display_get_height(_: *Instance, _: *Instance) f32 {
    return @floatFromInt(drawing().displayHeight());
}

pub fn window_set_size(_: *Instance, _: *Instance, w: f32, h: f32) void {
    drawing().windowSetSize(i32_(w), i32_(h));
}

pub fn window_set_fullscreen(_: *Instance, _: *Instance, full: f32) void {
    drawing().windowSetFullscreen(truthy(full));
}

pub fn display_set_gui_size(_: *Instance, _: *Instance, w: f32, h: f32) void {
    drawing().displaySetGuiSize(i32_(w), i32_(h));
}

fn audio() *runtime.AudioManager {
    return runtime.AudioManager.get();
}

pub fn audio_play_sound(_: *Instance, _: *Instance, snd: f32, prio: f32, loop: f32) f32 {
    return audio().playSound(snd, prio, b2r(truthy(loop)));
}

pub fn audio_stop_sound(_: *Instance, _: *Instance, snd: f32) void {
    audio().stopSound(snd);
}

pub fn audio_stop_all(_: *Instance, _: *Instance) void {
    audio().stopAll();
}

pub fn audio_is_playing(_: *Instance, _: *Instance, snd: f32) f32 {
    return b2r(audio().isPlaying(snd));
}

pub fn audio_sound_gain(_: *Instance, _: *Instance, snd: f32, vol: f32, ms: f32) void {
    audio().soundGain(snd, vol, ms);
}

pub fn audio_master_gain(_: *Instance, _: *Instance, vol: f32) void {
    audio().masterGain(vol);
}

pub fn audio_pause_all(_: *Instance, _: *Instance) void {
    audio().pauseAll();
}

pub fn audio_resume_all(_: *Instance, _: *Instance) void {
    audio().resumeAll();
}

// ---------------------------------------------------------------------------
// Built-in variables owned by the runtime
// ---------------------------------------------------------------------------

pub fn gget_working_directory() []const u8 {
    return files().workingDirectory();
}

/// instance_count: g_RunRoom.m_Active.length.
pub fn gget_instance_count() f32 {
    return @floatFromInt(instances().activeCount());
}

// yyInstance.js L509-561: sprite metrics scaled by the instance.

fn spriteOf(p: ?*const Instance) ?*const runtime.SpriteDef {
    const inst = p orelse return null;
    return runtime.SpriteRegistry.get().getSprite(inst.sprite_index);
}

pub fn iget_image_number(p: ?*const Instance) f32 {
    const spr = spriteOf(p) orelse return 0.0;
    return @floatFromInt(spr.frame_count);
}

pub fn iget_sprite_width(p: ?*const Instance) f32 {
    const spr = spriteOf(p) orelse return 0.0;
    return @as(f32, @floatFromInt(spr.width)) * p.?.image_xscale;
}

pub fn iget_sprite_height(p: ?*const Instance) f32 {
    const spr = spriteOf(p) orelse return 0.0;
    return @as(f32, @floatFromInt(spr.height)) * p.?.image_yscale;
}

pub fn iget_sprite_xoffset(p: ?*const Instance) f32 {
    const spr = spriteOf(p) orelse return 0.0;
    return @as(f32, @floatFromInt(spr.xorigin)) * p.?.image_xscale;
}

pub fn iget_sprite_yoffset(p: ?*const Instance) f32 {
    const spr = spriteOf(p) orelse return 0.0;
    return @as(f32, @floatFromInt(spr.yorigin)) * p.?.image_yscale;
}
