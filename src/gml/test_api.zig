//! gml/api.zig bindings, by family (ports the behaviour of
//! packaged_src/src/gml/gml_api*.c).

const std = @import("std");
const testing = std.testing;
const runtime = @import("runtime");
const rt = @import("rt.zig");
const api = @import("api.zig");

const Value = runtime.Value;
const Instance = runtime.Instance;
const InstanceManager = runtime.InstanceManager;

const OBJ_BLOCK = 0;
const OBJ_ENEMY = 1;
const OBJ_BAT = 2; // parent ENEMY
const OBJ_COUNT = 3;
const SPR_BLOCK = 0;

var creates: usize = 0;
var destroys: usize = 0;

fn enemyCreate(self: *Instance, _: ?*Instance) void {
    creates += 1;
    self.vars[0] = 7.0;
}

fn enemyDestroy(_: *Instance, _: ?*Instance) void {
    destroys += 1;
}

const objects = [OBJ_COUNT]runtime.ObjectDef{
    .{ .name = "oBlock", .default_sprite = SPR_BLOCK },
    .{ .name = "oEnemy", .default_depth = 5, .ev_create = enemyCreate, .ev_destroy = enemyDestroy },
    .{ .name = "oBat", .parent_index = OBJ_ENEMY },
};

const sprites = [_]runtime.SpriteDef{
    .{ .name = "sBlock", .width = 16, .height = 16, .xorigin = 8, .yorigin = 4, .bbox_right = 15, .bbox_bottom = 15, .frame_count = 3 },
};

const rooms = [_]runtime.RoomDef{
    .{ .name = "rTitle" },
    .{ .name = "rLevel" },
};
const room_order = [_]i32{ 0, 1 };

fn fresh() *Instance {
    rt.reset();
    runtime.StringManager.get().reset();
    runtime.RoomManager.get().reset();
    runtime.DsManager.get().reset();
    runtime.LayerManager.get().reset();
    runtime.ViewManager.get().reset();
    runtime.InputManager.get().reset();
    if (!runtime.ObjectRegistry.get().initRegistry(&objects)) @panic("objects");
    if (!runtime.SpriteRegistry.get().initRegistry(&sprites)) @panic("sprites");
    if (!runtime.RoomManager.get().registryInit(&rooms, &room_order)) @panic("rooms");
    InstanceManager.get().reset();
    InstanceManager.get().setNextId(runtime.instance.INSTANCE_ID_BASE);
    creates = 0;
    destroys = 0;
    return InstanceManager.get().create(OBJ_BLOCK, 0, 0).?;
}

fn inst(id: f32) *Instance {
    return InstanceManager.get().findById(@intFromFloat(id)).?;
}

test "maths: move_snap rounds half away from zero (gm_move_snap)" {
    const self = fresh();
    self.x = -24.0;
    self.y = 24.0;
    api.move_snap(self, self, 16.0, 16.0);
    try testing.expectEqual(@as(f32, -32.0), self.x);
    try testing.expectEqual(@as(f32, 32.0), self.y);
    self.x = 5.0;
    api.move_snap(self, self, 0.0, -1.0); // non-positive snaps are ignored
    try testing.expectEqual(@as(f32, 5.0), self.x);
    _ = api.randomize(self, self);
}

test "instances: create runs Create, queries see self/other, destroy runs Destroy" {
    const self = fresh();
    const e = api.instance_create_depth(self, self, 10.0, 20.0, -3.0, OBJ_ENEMY);
    try testing.expectEqual(@as(usize, 1), creates);
    try testing.expectEqual(@as(f32, 7.0), inst(e).vars[0]);
    try testing.expectEqual(@as(f32, -3.0), inst(e).depth);
    const bat = api.instance_create_depth(self, self, 50.0, 0.0, 0.0, OBJ_BAT);
    try testing.expectEqual(@as(usize, 2), creates); // inherited Create
    try testing.expectEqual(@as(f32, -4.0), api.instance_create_depth(self, self, 0, 0, 0, 99));

    try testing.expectEqual(@as(f32, 2.0), api.instance_number(self, self, OBJ_ENEMY));
    try testing.expectEqual(@as(f32, 1.0), api.instance_number(self, self, @floatFromInt(runtime.instance.GM_SELF)));
    try testing.expectEqual(@as(f32, 1.0), api.instance_exists(self, inst(e), @floatFromInt(runtime.instance.GM_OTHER)));
    try testing.expectEqual(bat, api.instance_find(self, self, OBJ_ENEMY, 1.0));
    try testing.expectEqual(@as(f32, -4.0), api.instance_find(self, self, OBJ_ENEMY, 2.0));
    try testing.expectEqual(e, api.instance_nearest(self, self, 0.0, 0.0, OBJ_ENEMY));
    try testing.expectEqual(@as(f32, OBJ_ENEMY), api.object_get_parent(self, self, OBJ_BAT));
    try testing.expectEqual(@as(f32, -1.0), api.object_get_parent(self, self, OBJ_BLOCK));

    // instance_destroy(obj): every matching instance, through a with snapshot.
    api.instance_destroy(self, self, &.{rt.vreal(OBJ_ENEMY)});
    try testing.expectEqual(@as(usize, 2), destroys);
    try testing.expectEqual(@as(f32, 0.0), api.instance_exists(self, self, OBJ_ENEMY));
    api.instance_destroy(self, self, &.{ rt.vreal(@floatFromInt(self.id)), rt.vreal(0.0) });
    try testing.expectEqual(@as(usize, 1), rt.pendingCount()); // destroy without event
    try testing.expect(self.marked_for_destroy);
    // No argument: self.
    const other = InstanceManager.get().create(OBJ_BLOCK, 0, 0).?;
    api.instance_destroy(other, other, &.{});
    try testing.expect(other.marked_for_destroy);
}

test "instances: activation bindings" {
    const self = fresh();
    const e = inst(api.instance_create_depth(self, self, 0, 0, 0, OBJ_ENEMY));
    const b = inst(api.instance_create_depth(self, self, 0, 0, 0, OBJ_BAT));
    api.instance_deactivate_object(self, self, OBJ_BAT);
    try testing.expect(e.active and !b.active);
    api.instance_activate_object(self, self, OBJ_ENEMY);
    try testing.expect(b.active);
    api.instance_deactivate_all(self, self, 1.0); // notme
    try testing.expect(self.active and !e.active and !b.active);
    api.instance_activate_all(self, self);
    try testing.expect(e.active and b.active);
    try testing.expectEqual(@as(f32, 3.0), api.gget_instance_count());
}

test "assets: asset_get_index searches objects, sprites, rooms" {
    const self = fresh();
    try testing.expectEqual(@as(f32, OBJ_BAT), api.asset_get_index(self, self, "oBat"));
    try testing.expectEqual(@as(f32, SPR_BLOCK), api.asset_get_index(self, self, "sBlock"));
    try testing.expectEqual(@as(f32, 1.0), api.asset_get_index(self, self, "rLevel"));
    try testing.expectEqual(@as(f32, -1.0), api.asset_get_index(self, self, "nothing"));
    try testing.expectEqual(@as(f32, 1.0), api.sprite_exists(self, self, SPR_BLOCK));
    try testing.expectEqual(@as(f32, 0.0), api.sprite_exists(self, self, 5.0));
}

test "collisions: place/position queries and distances use sprite bboxes" {
    const self = fresh(); // oBlock at (0, 0): bbox [-8, 8) x [-4, 12)
    const other = InstanceManager.get().create(OBJ_BLOCK, 40, 0).?;
    try testing.expectEqual(@as(f32, 0.0), api.place_meeting(self, self, 0, 0, OBJ_BLOCK));
    try testing.expectEqual(@as(f32, 1.0), api.place_meeting(self, self, 30, 0, OBJ_BLOCK));
    try testing.expectEqual(@as(f32, @floatFromInt(other.id)), api.instance_place(self, self, 30, 0, OBJ_BLOCK));
    try testing.expectEqual(@as(f32, @floatFromInt(other.id)), api.instance_position(self, self, 40, 0, OBJ_BLOCK));
    try testing.expectEqual(@as(f32, -4.0), api.instance_position(self, self, 100, 100, OBJ_BLOCK));
    try testing.expectEqual(@as(f32, @floatFromInt(self.id)), api.collision_point(self, self, 0, 0, OBJ_BLOCK, 1, 0));
    try testing.expectEqual(@as(f32, -4.0), api.collision_point(self, self, 0, 0, OBJ_BLOCK, 1, 1)); // notme
    try testing.expectEqual(@as(f32, @floatFromInt(other.id)), api.collision_rectangle(self, self, 20, -10, 60, 10, OBJ_BLOCK, 0, 1));
    try testing.expectEqual(@as(f32, @floatFromInt(other.id)), api.collision_line(self, self, 20, 0, 60, 0, OBJ_BLOCK, 0, 1));
    // Like gm_collision_distance_to_object, self is not excluded.
    try testing.expectEqual(@as(f32, 0.0), api.distance_to_object(self, self, OBJ_BLOCK));
    try testing.expectEqual(@as(f32, 24.0), api.distance_to_object(self, self, @floatFromInt(other.id))); // 32 - 8
    try testing.expectEqual(runtime.collision.NO_DISTANCE, api.distance_to_object(self, self, OBJ_ENEMY));
    try testing.expectEqual(@as(f32, 2.0), api.distance_to_point(self, self, 10, 0));
}

test "ds_map bindings copy strings out and reject arrays" {
    const self = fresh();
    const sm = runtime.StringManager.get();
    const map = api.ds_map_create(self, self);
    try testing.expect(map >= 0.0);
    api.ds_map_replace(self, self, map, "who", rt.vs(rt.concat("Spel", "unky")));
    api.ds_map_replace(self, self, map, "n", rt.vreal(3.0));
    try testing.expectEqual(@as(f32, 2.0), api.ds_map_size(self, self, map));
    try testing.expectEqual(@as(f32, 1.0), api.ds_map_exists(self, self, map, "who"));
    const who = api.ds_map_find_value(self, self, map, "who");
    try testing.expectEqualStrings("Spelunky", who.string);
    try testing.expect(sm.scratch.owns(who.string));
    try testing.expectEqualStrings("who", api.ds_map_find_first(self, self, map).string);
    try testing.expectEqualStrings("n", api.ds_map_find_next(self, self, map, "who").string);
    try testing.expect(api.ds_map_find_value(self, self, map, "none") == .undefined);

    var arr = rt.arrayLit(&.{rt.vreal(1.0)});
    _ = &arr;
    api.ds_map_replace(self, self, map, "arr", arr);
    try testing.expect(api.ds_map_find_value(self, self, map, "arr") == .undefined);
    try testing.expectEqualStrings("ds_map_replace(<array value>)", rt.pendingName(0).?);
    api.ds_map_destroy(self, self, map);
    try testing.expectEqual(@as(f32, 0.0), api.ds_map_size(self, self, map));
}

test "file bindings: write, read back into scratch, delete" {
    const self = fresh();
    const path = "/tmp/zig_spelunky_api_file.txt";
    const w = api.file_text_open_write(self, self, path);
    try testing.expect(w >= 0.0);
    api.file_text_write_string(self, self, w, "first");
    api.file_text_writeln(self, self, w);
    api.file_text_write_string(self, self, w, "second");
    api.file_text_close(self, self, w);
    try testing.expectEqual(@as(f32, 1.0), api.file_exists(self, self, path));

    const r = api.file_text_open_read(self, self, path);
    const first = api.file_text_read_string(self, self, r);
    try testing.expectEqualStrings("first", first);
    try testing.expect(runtime.StringManager.get().scratch.owns(first));
    _ = api.file_text_readln(self, self, r);
    try testing.expectEqualStrings("second", api.file_text_read_string(self, self, r));
    try testing.expectEqual(@as(f32, 1.0), api.file_text_eof(self, self, r));
    api.file_text_close(self, self, r);
    try testing.expectEqual(@as(f32, 1.0), api.file_delete(self, self, path));
    try testing.expectEqual(@as(f32, 0.0), api.file_exists(self, self, path));
    try testing.expectEqual(@as(f32, -1.0), api.file_text_open_read(self, self, path));
    try testing.expectEqualStrings("./", api.gget_working_directory());
}

test "string bindings (Function_String.js, yyGetInt32 indices)" {
    const self = fresh();
    try testing.expectEqualStrings("12", api.string(self, self, rt.vreal(12.0)));
    try testing.expectEqualStrings("[ 1 ]", api.string(self, self, rt.arrayLit(&.{rt.vreal(1.0)})));
    try testing.expectEqual(@as(f32, 89.0), api.ord(self, self, "Y"));
    try testing.expectEqualStrings("e", api.string_char_at(self, self, "hello", 2.9));
    try testing.expectEqualStrings("hlo", api.string_delete(self, self, "hello", 2, 2));
    try testing.expectEqualStrings("heXYllo", api.string_insert(self, self, "XY", "hello", 3));
    try testing.expectEqual(@as(f32, 4.0), api.string_length(self, self, "caf\xc3\xa9"));
    try testing.expectEqualStrings("abc", api.string_lower(self, self, "AbC"));
    try testing.expectEqualStrings("ABC", api.string_upper(self, self, "aBc"));
    try testing.expectEqual(@as(f32, 3.0), api.string_pos(self, self, "ll", "hello"));
    try testing.expectEqualStrings("a\r\nb", api.string_hash_to_newline(self, self, "a#b"));
}

test "rooms and built-in room globals" {
    const self = fresh();
    const rm = runtime.RoomManager.get();
    try testing.expectEqualStrings("rLevel", api.room_get_name(self, self, 1.0));
    try testing.expectEqualStrings("", api.room_get_name(self, self, 9.0));
    try testing.expectEqual(@as(f32, 1.0), api.room_exists(self, self, 0.0));
    try testing.expectEqual(@as(f32, 0.0), api.room_exists(self, self, 2.0));
    try testing.expectEqual(@as(f32, 0.0), api.gget_room_first());
    try testing.expectEqual(@as(f32, 1.0), api.gget_room_last());
    api.room_goto(self, self, 1.0);
    try testing.expectEqual(@as(i32, 1), rm.pending());
    api.gset_room(0.0);
    try testing.expectEqual(@as(i32, 0), rm.pending());

    api.gset_room_width(320.0);
    api.gset_room_speed(60.0);
    api.gset_room_persistent(1.0);
    api.gset_room_caption("Spelunky");
    try testing.expectEqual(@as(f32, 320.0), api.gget_room_width());
    try testing.expectEqual(@as(f32, 60.0), api.gget_room_speed());
    try testing.expectEqual(@as(f32, 1.0), api.gget_room_persistent());
    try testing.expectEqualStrings("Spelunky", api.gget_room_caption());
}

test "views and cameras" {
    const self = fresh();
    api.gset_view_enabled(1.0);
    try testing.expectEqual(@as(f32, 1.0), api.gget_view_enabled());
    api.gset_view_xview(1.0, 33.5);
    try testing.expectEqual(@as(f32, 33.5), api.gget_view_xview(1.0));
    try testing.expectEqual(@as(f32, 0.0), api.gget_view_xview(-1.0)); // out of range
    api.gset_view_xview(8.0, 1.0); // dropped
    api.view_set_wport(self, self, 0.0, 320.7); // yyGetInt32 on writes
    try testing.expectEqual(@as(f32, 320.0), api.view_get_wport(self, self, 0.0));
    try testing.expectEqual(@as(f32, 320.0), api.gget_view_wport(0.0));

    const cam = api.camera_create_view(self, self, &.{ rt.vreal(1), rt.vreal(2), rt.vreal(320), rt.vreal(240) });
    try testing.expect(cam >= 0.0);
    try testing.expectEqual(@as(f32, 320.0), api.camera_get_view_width(self, self, cam));
    try testing.expectEqual(@as(f32, -1.0), api.camera_get_view_target(self, self, cam)); // default
    try testing.expectEqual(@as(f32, -1.0), api.camera_get_view_speed_x(self, self, cam));
    api.camera_set_view_pos(self, self, cam, 10, 20);
    api.camera_set_view_border(self, self, cam, 64, 48);
    api.camera_set_view_target(self, self, cam, OBJ_ENEMY);
    api.camera_set_view_angle(self, self, cam, 90);
    try testing.expectEqual(@as(f32, 20.0), api.camera_get_view_y(self, self, cam));
    try testing.expectEqual(@as(f32, 48.0), api.camera_get_view_border_y(self, self, cam));
    try testing.expectEqual(@as(f32, OBJ_ENEMY), api.camera_get_view_target(self, self, cam));
    try testing.expectEqual(@as(f32, 90.0), api.camera_get_view_angle(self, self, cam));
    api.view_set_camera(self, self, 0.0, cam);
    try testing.expectEqual(cam, api.view_get_camera(self, self, 0.0));
    api.camera_destroy(self, self, cam);
    try testing.expectEqual(@as(f32, -1.0), api.camera_get_view_x(self, self, cam));
    try testing.expectEqual(@as(f32, -1.0), api.room_get_camera(self, self, 0.0, -1.0));
}

test "layers: ids or names, backgrounds and tiles" {
    const self = fresh();
    const sm = runtime.StringManager.get();
    const l = api.layer_create(self, self, &.{ rt.vreal(100), rt.vs("Back") });
    try testing.expect(l >= 0.0);
    try testing.expectEqual(@as(f32, -1.0), api.layer_create(self, self, &.{}));
    try testing.expectEqual(@as(f32, 100.0), api.layer_get_depth(self, self, rt.vs("Back")));
    api.layer_depth(self, self, rt.vreal(l), 50);
    try testing.expectEqual(@as(f32, 50.0), api.layer_get_depth(self, self, rt.vreal(l)));
    const name = api.layer_get_name(self, self, rt.vreal(l));
    try testing.expectEqualStrings("Back", name);
    try testing.expect(sm.scratch.owns(name));
    try testing.expectEqual(@as(f32, -1.0), api.layer_get_depth(self, self, rt.vs("missing")));
    api.layer_x(self, self, rt.vs("Back"), 12.5);
    api.layer_set_visible(self, self, rt.vs("Back"), 0.0);
    try testing.expectEqual(@as(f32, 12.5), api.layer_get_x(self, self, rt.vreal(l)));
    try testing.expectEqual(@as(f32, 0.0), api.layer_get_visible(self, self, rt.vreal(l)));

    const all = api.layer_get_all(self, self);
    try testing.expectEqual(@as(f32, 1.0), rt.arrayLength(all));
    try testing.expectEqual(l, rt.aget(all, 0).real);

    const bg = api.layer_background_create(self, self, rt.vs("Back"), SPR_BLOCK);
    try testing.expectEqual(@as(f32, 1.0), api.layer_background_exists(self, self, rt.vreal(l), bg));
    try testing.expectEqual(@as(f32, 1.0), api.layer_get_element_type(self, self, bg));
    api.layer_background_blend(self, self, bg, -1.0); // masked to 24-bit BGR
    api.layer_background_htiled(self, self, bg, 1.0);
    api.layer_background_xscale(self, self, bg, 2.0);
    try testing.expectEqual(@as(f32, 0xFFFFFF), api.layer_background_get_blend(self, self, bg));
    try testing.expectEqual(@as(f32, 1.0), api.layer_background_get_htiled(self, self, bg));
    try testing.expectEqual(@as(f32, 2.0), api.layer_background_get_xscale(self, self, bg));
    try testing.expectEqual(@as(f32, SPR_BLOCK), api.layer_background_get_sprite(self, self, bg));
    try testing.expectEqual(@as(f32, -1.0), api.layer_background_get_sprite(self, self, 9999));

    const t = api.layer_tile_create(self, self, rt.vreal(l), 16, 32, SPR_BLOCK, 1, 2, 3, 4);
    const region = api.layer_tile_get_region(self, self, t);
    try testing.expectEqual(@as(f32, 4.0), rt.arrayLength(region));
    try testing.expectEqual(@as(f32, 3.0), rt.aget(region, 2).real);
    try testing.expectEqual(@as(f32, 32.0), api.layer_tile_get_y(self, self, t));
    try testing.expectEqual(@as(f32, -1.0), api.layer_tile_get_region(self, self, bg).real); // not a tile
    try testing.expectEqual(@as(f32, 0.0), api.layer_tile_create(self, self, rt.vs("missing"), 0, 0, 0, 0, 0, 0, 0));
    try testing.expectEqual(@as(f32, 2.0), rt.arrayLength(api.layer_get_all_elements(self, self, rt.vs("Back"))));
    api.layer_tile_destroy(self, self, t);
    try testing.expectEqual(@as(f32, 1.0), rt.arrayLength(api.layer_get_all_elements(self, self, rt.vs("Back"))));
    api.layer_destroy(self, self, rt.vs("Back"));
    try testing.expectEqual(@as(f32, 0.0), rt.arrayLength(api.layer_get_all(self, self)));
}

test "input bindings and keyboard globals" {
    const self = fresh();
    const in = runtime.InputManager.get();
    in.keyDown(37);
    in.startStep();
    try testing.expectEqual(@as(f32, 1.0), api.keyboard_check(self, self, 37.9));
    try testing.expectEqual(@as(f32, 1.0), api.keyboard_check_pressed(self, self, 37));
    try testing.expectEqual(@as(f32, 0.0), api.keyboard_check_released(self, self, 37));
    api.gset_keyboard_lastkey(65);
    try testing.expectEqual(@as(f32, 65.0), api.gget_keyboard_lastkey());
    api.gset_keyboard_key(66);
    try testing.expectEqual(@as(f32, 66.0), api.gget_keyboard_key());
}

test "drawing state, computed sprite variables, game control" {
    const self = fresh();
    api.draw_set_alpha(self, self, 0.25);
    try testing.expectEqual(@as(f32, 0.25), runtime.DrawManager.get().getAlpha());
    api.draw_set_colour(self, self, 255);
    try testing.expectEqual(@as(u32, 255), runtime.DrawManager.get().getColour());
    try testing.expectEqual(@as(f32, 0.0), api.gget_application_surface());

    self.image_xscale = -2.0;
    try testing.expectEqual(@as(f32, 3.0), api.iget_image_number(self));
    try testing.expectEqual(@as(f32, -32.0), api.iget_sprite_width(self));
    try testing.expectEqual(@as(f32, 16.0), api.iget_sprite_height(self));
    try testing.expectEqual(@as(f32, -16.0), api.iget_sprite_xoffset(self));
    try testing.expectEqual(@as(f32, 4.0), api.iget_sprite_yoffset(self));
    try testing.expectEqual(@as(f32, 0.0), api.iget_image_number(null));

    api.game_end(self, self);
    try testing.expectEqual(runtime.room.ROOM_END_GAME, runtime.RoomManager.get().pending());
}
