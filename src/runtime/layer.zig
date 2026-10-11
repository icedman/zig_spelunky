//! Room layers and their tile/background elements.
//! Follows Function_Layers.js and packaged_src/src/runtime/gm_layer.c.

const std = @import("std");
const SpriteRegistry = @import("sprite.zig").SpriteRegistry;
const room_mod = @import("room.zig");

pub const MAX_LAYERS: usize = 64;
pub const MAX_ELEMENTS: usize = 4096;
pub const MAX_NAME_LEN: usize = 64;

pub const EL_HASH_BITS = 13;
pub const EL_HASH_SIZE: usize = 1 << EL_HASH_BITS; // 8192

pub const ELEMENT_BACKGROUND: i32 = 1;
pub const ELEMENT_TILE: i32 = 7;

pub const LAYER_BACKGROUND: i32 = 1;
pub const LAYER_INSTANCES: i32 = 2;
pub const LAYER_ASSETS: i32 = 3;

pub const Layer = struct {
    id: i32 = 0,
    depth: i32 = 0,
    kind: i32 = 0,
    dynamic: bool = false,
    visible: bool = true,
    x: f32 = 0.0,
    y: f32 = 0.0,
    hspeed: f32 = 0.0,
    vspeed: f32 = 0.0,
    name: [MAX_NAME_LEN]u8 = [_]u8{0} ** MAX_NAME_LEN,
    name_len: usize = 0,
    head: i32 = -1,
    tail: i32 = -1,
    count: usize = 0,

    pub fn getName(self: *const Layer) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Element = struct {
    id: i32 = 0,
    type: i32 = 0, // ELEMENT_BACKGROUND or ELEMENT_TILE
    layer: usize = 0, // layer slot
    prev: i32 = -1, // element slot, -1 end
    next: i32 = -1, // element slot, -1 end
    visible: bool = true,
    sprite: i32 = -1,
    x: f32 = 0.0,
    y: f32 = 0.0,
    xo: i32 = 0,
    yo: i32 = 0,
    w: i32 = 0,
    h: i32 = 0,
    xscale: f32 = 1.0,
    yscale: f32 = 1.0,
    blend: u32 = 0x00FFFFFF,
    alpha: f32 = 1.0,
    htiled: bool = false,
    vtiled: bool = false,
    stretch: bool = false,
    image_index: f32 = 0.0,
    image_speed: f32 = 1.0,
};

pub const LayerManager = struct {
    layers: [MAX_LAYERS]Layer = [_]Layer{.{}} ** MAX_LAYERS,
    layer_used: [MAX_LAYERS]bool = [_]bool{false} ** MAX_LAYERS,
    order: [MAX_LAYERS]usize = [_]usize{0} ** MAX_LAYERS,
    order_count: usize = 0,

    elems: [MAX_ELEMENTS]Element = [_]Element{.{}} ** MAX_ELEMENTS,
    elem_used: [MAX_ELEMENTS]bool = [_]bool{false} ** MAX_ELEMENTS,
    elem_free: [MAX_ELEMENTS]usize = undefined,
    elem_free_count: usize = 0,

    hash_table: [EL_HASH_SIZE]i16 = [_]i16{-1} ** EL_HASH_SIZE,

    watermark: i32 = 0,
    current_layer_id: i32 = 0,
    next_element_id: i32 = 0,
    overflow_count: usize = 0,

    var instance: LayerManager = .{};

    pub fn get() *LayerManager {
        return &instance;
    }

    fn home(id: i32) usize {
        const uid: u32 = @bitCast(id);
        const shift: u5 = 32 - EL_HASH_BITS;
        return @intCast((uid *% 2654435761) >> shift);
    }

    fn hashInsert(self: *LayerManager, slot: usize) void {
        var i = home(self.elems[slot].id);
        while (self.hash_table[i] >= 0) {
            i = (i + 1) & (EL_HASH_SIZE - 1);
        }
        self.hash_table[i] = @intCast(slot);
    }

    fn hashIndex(self: *const LayerManager, id: i32) ?usize {
        var i = home(id);
        while (self.hash_table[i] >= 0) {
            const slot: usize = @intCast(self.hash_table[i]);
            if (self.elems[slot].id == id) {
                return i;
            }
            i = (i + 1) & (EL_HASH_SIZE - 1);
        }
        return null;
    }

    fn hashRemove(self: *LayerManager, id: i32) void {
        const found = self.hashIndex(id) orelse return;
        var i = found;
        var j = i;
        while (true) {
            j = (j + 1) & (EL_HASH_SIZE - 1);
            if (self.hash_table[j] < 0) break;
            const slot: usize = @intCast(self.hash_table[j]);
            const k = home(self.elems[slot].id);
            const should_move = if (i <= j)
                (k <= i or k > j)
            else
                (k <= i and k > j);
            if (should_move) {
                self.hash_table[i] = self.hash_table[j];
                i = j;
            }
        }
        self.hash_table[i] = -1;
    }

    fn clearPools(self: *LayerManager) void {
        @memset(&self.layer_used, false);
        self.order_count = 0;
        @memset(&self.elem_used, false);
        for (0..MAX_ELEMENTS) |i| {
            self.elem_free[i] = MAX_ELEMENTS - 1 - i;
        }
        self.elem_free_count = MAX_ELEMENTS;
        @memset(&self.hash_table, -1);
    }

    pub fn reset(self: *LayerManager) void {
        self.clearPools();
        self.watermark = 0;
        self.current_layer_id = 0;
        self.next_element_id = 0;
        self.overflow_count = 0;
    }

    pub fn setWatermark(self: *LayerManager, id: i32) void {
        self.watermark = id;
    }

    pub fn overflows(self: *const LayerManager) usize {
        return self.overflow_count;
    }

    fn orderInsert(self: *LayerManager, slot: usize) void {
        var insert_at: usize = self.order_count;
        for (0..self.order_count) |i| {
            if (self.layers[slot].depth < self.layers[self.order[i]].depth) {
                insert_at = i;
                break;
            }
        }
        var i = self.order_count;
        while (i > insert_at) : (i -= 1) {
            self.order[i] = self.order[i - 1];
        }
        self.order[insert_at] = slot;
        self.order_count += 1;
    }

    fn orderRemove(self: *LayerManager, slot: usize) void {
        for (0..self.order_count) |i| {
            if (self.order[i] == slot) {
                var j = i;
                while (j + 1 < self.order_count) : (j += 1) {
                    self.order[j] = self.order[j + 1];
                }
                self.order_count -= 1;
                return;
            }
        }
    }

    fn layerAdd(self: *LayerManager, id: i32, depth: i32, name: ?[]const u8, kind: i32, dynamic: bool) ?*Layer {
        var slot: usize = 0;
        while (slot < MAX_LAYERS and self.layer_used[slot]) : (slot += 1) {}
        if (slot == MAX_LAYERS) {
            self.overflow_count += 1;
            return null;
        }
        self.layer_used[slot] = true;
        const l = &self.layers[slot];
        l.* = .{
            .id = id,
            .depth = depth,
            .kind = kind,
            .dynamic = dynamic,
            .visible = true,
            .head = -1,
            .tail = -1,
            .count = 0,
        };
        if (name) |n| {
            const len = @min(n.len, MAX_NAME_LEN);
            @memcpy(l.name[0..len], n[0..len]);
            l.name_len = len;
        }
        self.orderInsert(slot);
        return l;
    }

    fn nextLayerId(self: *LayerManager) i32 {
        if (self.current_layer_id < self.watermark) {
            self.current_layer_id = self.watermark;
        }
        self.current_layer_id += 1;
        return self.current_layer_id;
    }

    pub fn count(self: *const LayerManager) usize {
        return self.order_count;
    }

    pub fn at(self: *LayerManager, index: usize) ?*Layer {
        if (index < self.order_count) {
            return &self.layers[self.order[index]];
        }
        return null;
    }

    pub fn find(self: *LayerManager, id: i32) ?*Layer {
        for (0..self.order_count) |i| {
            const slot = self.order[i];
            if (self.layers[slot].id == id) {
                return &self.layers[slot];
            }
        }
        return null;
    }

    pub fn findName(self: *LayerManager, name: []const u8) ?*Layer {
        if (name.len == 0) return null;
        for (0..self.order_count) |i| {
            const slot = self.order[i];
            const l = &self.layers[slot];
            if (l.name_len > 0 and std.ascii.eqlIgnoreCase(l.getName(), name)) {
                return l;
            }
        }
        return null;
    }

    pub fn getAll(self: *const LayerManager, out: []i32) usize {
        var n: usize = 0;
        for (0..self.order_count) |i| {
            if (n >= out.len) break;
            const slot = self.order[i];
            if (!self.layers[slot].dynamic) {
                out[n] = self.layers[slot].id;
                n += 1;
            }
        }
        return n;
    }

    pub fn create(self: *LayerManager, depth: i32, name: ?[]const u8) i32 {
        const id = self.nextLayerId();
        var buf: [32]u8 = undefined;
        const actual_name = if (name) |n|
            n
        else
            std.fmt.bufPrint(&buf, "_layer_{x}", .{@as(u32, @bitCast(id))}) catch "_layer";
        const l = self.layerAdd(id, depth, actual_name, 0, false);
        return if (l) |layer| layer.id else -1;
    }

    fn elementFree(self: *LayerManager, slot: usize) void {
        const e = &self.elems[slot];
        const l = &self.layers[e.layer];

        if (e.prev >= 0) {
            self.elems[@intCast(e.prev)].next = e.next;
        } else {
            l.head = e.next;
        }
        if (e.next >= 0) {
            self.elems[@intCast(e.next)].prev = e.prev;
        } else {
            l.tail = e.prev;
        }
        if (l.count > 0) l.count -= 1;
        self.hashRemove(e.id);
        self.elem_used[slot] = false;
        self.elem_free[self.elem_free_count] = slot;
        self.elem_free_count += 1;
    }

    fn elementAdd(self: *LayerManager, l: *Layer, el_type: i32) ?*Element {
        if (self.elem_free_count == 0) {
            self.overflow_count += 1;
            return null;
        }
        self.elem_free_count -= 1;
        const slot = self.elem_free[self.elem_free_count];
        self.elem_used[slot] = true;
        const e = &self.elems[slot];
        const layer_slot = (@intFromPtr(l) - @intFromPtr(&self.layers[0])) / @sizeOf(Layer);
        const eid = self.next_element_id;
        self.next_element_id += 1;

        e.* = .{
            .id = eid,
            .type = el_type,
            .layer = layer_slot,
            .visible = true,
            .sprite = -1,
            .xscale = 1.0,
            .yscale = 1.0,
            .blend = 0x00FFFFFF,
            .alpha = 1.0,
            .prev = -1,
            .next = l.head,
        };

        if (l.head >= 0) {
            self.elems[@intCast(l.head)].prev = @intCast(slot);
        } else {
            l.tail = @intCast(slot);
        }
        l.head = @intCast(slot);
        l.count += 1;
        self.hashInsert(slot);
        return e;
    }

    pub fn elementSlot(self: *LayerManager, slot: usize) ?*Element {
        if (slot < MAX_ELEMENTS and self.elem_used[slot]) {
            return &self.elems[slot];
        }
        return null;
    }

    pub fn element(self: *LayerManager, element_id: i32) ?*Element {
        const idx = self.hashIndex(element_id) orelse return null;
        const slot: usize = @intCast(self.hash_table[idx]);
        return &self.elems[slot];
    }

    pub fn elementType(self: *LayerManager, element_id: i32) i32 {
        const e = self.element(element_id) orelse return -1;
        return e.type;
    }

    pub fn elementDestroy(self: *LayerManager, element_id: i32) void {
        const idx = self.hashIndex(element_id) orelse return;
        const slot: usize = @intCast(self.hash_table[idx]);
        self.elementFree(slot);
    }

    pub fn elements(self: *LayerManager, layer_id: i32, out: []i32) usize {
        const l = self.find(layer_id) orelse return 0;
        var n: usize = 0;
        var cur = l.head;
        while (cur >= 0 and n < out.len) {
            const ucur: usize = @intCast(cur);
            out[n] = self.elems[ucur].id;
            n += 1;
            cur = self.elems[ucur].next;
        }
        return n;
    }

    pub fn tileCreate(self: *LayerManager, layer_id: i32, x: f32, y: f32, sprite: i32, left: i32, top: i32, w: i32, h: i32) i32 {
        const l = self.find(layer_id) orelse return -1;
        const e = self.elementAdd(l, ELEMENT_TILE) orelse return -1;
        e.sprite = sprite;
        e.x = x;
        e.y = y;
        e.xo = left;
        e.yo = top;
        e.w = w;
        e.h = h;
        return e.id;
    }

    pub fn backgroundCreate(self: *LayerManager, layer_id: i32, sprite: i32) i32 {
        const l = self.find(layer_id) orelse return -1;
        const e = self.elementAdd(l, ELEMENT_BACKGROUND) orelse return -1;
        e.sprite = sprite;
        e.image_speed = 1.0;
        return e.id;
    }

    pub fn backgroundExists(self: *LayerManager, layer_id: i32, element_id: i32) bool {
        const e = self.element(element_id) orelse return false;
        const l = self.find(layer_id) orelse return false;
        const layer_slot = (@intFromPtr(l) - @intFromPtr(&self.layers[0])) / @sizeOf(Layer);
        return e.layer == layer_slot and e.type == ELEMENT_BACKGROUND;
    }

    pub fn destroy(self: *LayerManager, id: i32) void {
        const l = self.find(id) orelse return;
        while (l.head >= 0) {
            self.elementFree(@intCast(l.head));
        }
        const slot = (@intFromPtr(l) - @intFromPtr(&self.layers[0])) / @sizeOf(Layer);
        self.orderRemove(slot);
        self.layer_used[slot] = false;
    }

    pub fn setDepth(self: *LayerManager, id: i32, depth: i32) void {
        const l = self.find(id) orelse return;
        if (l.depth == depth) return;
        l.depth = depth;
        const slot = (@intFromPtr(l) - @intFromPtr(&self.layers[0])) / @sizeOf(Layer);
        self.orderRemove(slot);
        self.orderInsert(slot);
    }

    pub fn roomStart(self: *LayerManager, room: *const room_mod.RoomDef) void {
        if (room.layers == null or room.layer_count == 0) return;
        const layers = room.layers.?;
        var j: isize = @as(isize, @intCast(room.layer_count)) - 1;
        while (j >= 0) : (j -= 1) {
            const uj: usize = @intCast(j);
            const d = &layers[uj];
            const l = self.layerAdd(d.id, d.depth, d.name, d.kind, false) orelse continue;

            l.visible = d.visible;
            l.x = d.x;
            l.y = d.y;
            l.hspeed = d.hspeed;
            l.vspeed = d.vspeed;

            if (d.kind == LAYER_BACKGROUND) {
                const e = self.elementAdd(l, ELEMENT_BACKGROUND) orelse continue;
                const spr = SpriteRegistry.get().getSprite(d.bg_sprite);
                e.sprite = d.bg_sprite;
                e.visible = d.visible;
                e.htiled = d.bg_htiled;
                e.vtiled = d.bg_vtiled;
                e.stretch = d.bg_stretch;
                e.blend = d.bg_colour & 0x00FFFFFF;
                e.alpha = @as(f32, @floatFromInt((d.bg_colour >> 24) & 0xFF)) / 255.0;
                e.image_speed = 1.0;
                if (d.bg_stretch and spr != null and spr.?.width > 0 and spr.?.height > 0) {
                    e.xscale = @as(f32, @floatFromInt(room.width)) / @as(f32, @floatFromInt(spr.?.width));
                    e.yscale = @as(f32, @floatFromInt(room.height)) / @as(f32, @floatFromInt(spr.?.height));
                }
            } else if (d.kind == LAYER_ASSETS and room.tiles != null) {
                const tiles = room.tiles.?;
                var i: isize = @as(isize, @intCast(d.tile_count)) - 1;
                while (i >= 0) : (i -= 1) {
                    const ui: usize = @intCast(i);
                    const t_idx = @as(usize, @intCast(d.first_tile)) + ui;
                    if (t_idx >= room.tile_count) break;
                    const t = &tiles[t_idx];
                    const e = self.elementAdd(l, ELEMENT_TILE) orelse break;

                    e.sprite = t.sprite;
                    e.x = t.x;
                    e.y = t.y;
                    e.xo = t.u;
                    e.yo = t.v;
                    e.w = t.w;
                    e.h = t.h;
                    e.xscale = t.xscale;
                    e.yscale = t.yscale;
                    e.blend = t.colour & 0x00FFFFFF;
                    e.alpha = @as(f32, @floatFromInt((t.colour >> 24) & 0xFF)) / 255.0;
                }
            }
        }
    }

    pub fn roomEnd(self: *LayerManager) void {
        self.clearPools();
    }

    pub fn update(self: *LayerManager) void {
        for (0..self.order_count) |i| {
            const slot = self.order[i];
            const l = &self.layers[slot];
            l.x += l.hspeed;
            l.y += l.vspeed;
        }
    }
};

test "Layer and Element creation, depth ordering, lookup and hash table" {
    var lm = LayerManager.get();
    lm.reset();

    const l1 = lm.create(100, "Background_Layer");
    const l2 = lm.create(0, "Instances_Layer");
    const l3 = lm.create(50, "Tiles_Layer");

    try std.testing.expectEqual(@as(usize, 3), lm.count());

    var all: [8]i32 = undefined;
    const n = lm.getAll(&all);
    try std.testing.expectEqual(@as(usize, 3), n);
    // Depth ascending: 0 (l2), 50 (l3), 100 (l1)
    try std.testing.expectEqual(l2, all[0]);
    try std.testing.expectEqual(l3, all[1]);
    try std.testing.expectEqual(l1, all[2]);

    // Name lookup
    const found = lm.findName("instances_layer");
    try std.testing.expect(found != null);
    try std.testing.expectEqual(l2, found.?.id);

    // Tile creation and elements
    const t1 = lm.tileCreate(l3, 10.0, 20.0, 1, 0, 0, 16, 16);
    const t2 = lm.tileCreate(l3, 30.0, 40.0, 1, 16, 0, 16, 16);
    try std.testing.expect(t1 >= 0);
    try std.testing.expect(t2 > t1);

    var els: [8]i32 = undefined;
    const el_count = lm.elements(l3, &els);
    try std.testing.expectEqual(@as(usize, 2), el_count);
    // Newest first
    try std.testing.expectEqual(t2, els[0]);
    try std.testing.expectEqual(t1, els[1]);

    // Element destroy and hash lookup
    lm.elementDestroy(t1);
    try std.testing.expect(lm.element(t1) == null);
    try std.testing.expect(lm.element(t2) != null);
}
