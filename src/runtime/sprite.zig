//! Sprite definition registry and collision mask storage.
//! Follows reference/GameMaker-HTML5 (yySprite.js L117-162) and packaged_src/src/runtime/gm_sprite.h.

const std = @import("std");

pub const SPRITE_NONE: i32 = -1;
pub const MAX_SPRITES: usize = 2048;

pub const ColCheck = enum(i32) {
    aabb = 0,
    precise = 1,
    rotated_rect = 2,
};

pub const SpriteDef = struct {
    name: []const u8 = "",
    width: i32 = 0,
    height: i32 = 0,
    xorigin: i32 = 0,
    yorigin: i32 = 0,
    bbox_left: i32 = 0,
    bbox_top: i32 = 0,
    bbox_right: i32 = 0,
    bbox_bottom: i32 = 0,
    colcheck: ColCheck = .aabb,
    frame_count: i32 = 1,
    mask_count: i32 = 0,
    masks: ?[*]const u8 = null,

    pub fn maskStride(self: *const SpriteDef) i32 {
        const bwidth = self.bbox_right - self.bbox_left + 1;
        return if (bwidth > 0) (bwidth + 7) >> 3 else 0;
    }

    pub fn maskSize(self: *const SpriteDef) usize {
        const rows = self.bbox_bottom - self.bbox_top + 1;
        if (rows <= 0) return 0;
        const stride = self.maskStride();
        return @as(usize, @intCast(stride)) * @as(usize, @intCast(rows));
    }

    pub fn getMask(self: *const SpriteDef, n: i32) ?[*]const u8 {
        if (n < 0 or n >= self.mask_count or self.masks == null) return null;
        return self.masks.? + @as(usize, @intCast(n)) * self.maskSize();
    }
};

pub const SpriteRegistry = struct {
    defs: ?[*]const SpriteDef = null,
    count: usize = 0,
    generation: u32 = 0,

    var instance: SpriteRegistry = .{};

    pub fn get() *SpriteRegistry {
        return &instance;
    }

    pub fn reset(self: *SpriteRegistry) void {
        self.defs = null;
        self.count = 0;
        self.generation +%= 1;
    }

    fn defOk(d: *const SpriteDef) bool {
        if (d.colcheck != .aabb and d.colcheck != .precise) return false;
        if (d.frame_count < 0 or d.mask_count < 0) return false;
        if (d.mask_count == 0) return true;
        if (d.masks == null or d.bbox_right < d.bbox_left or d.bbox_bottom < d.bbox_top) return false;
        return (d.mask_count == 1 or d.mask_count == d.frame_count);
    }

    pub fn initRegistry(self: *SpriteRegistry, defs: []const SpriteDef) bool {
        self.defs = null;
        self.count = 0;
        self.generation +%= 1;

        if (defs.len > MAX_SPRITES) return false;

        for (defs) |*d| {
            if (!defOk(d)) return false;
        }

        self.defs = defs.ptr;
        self.count = defs.len;
        return true;
    }

    pub inline fn countSprites(self: *const SpriteRegistry) usize {
        return self.count;
    }

    pub inline fn valid(self: *const SpriteRegistry, index: i32) bool {
        return index >= 0 and @as(usize, @intCast(index)) < self.count;
    }

    pub fn getSprite(self: *const SpriteRegistry, index: i32) ?*const SpriteDef {
        if (!self.valid(index) or self.defs == null) return null;
        return &self.defs.?[@as(usize, @intCast(index))];
    }
};

test "SpriteRegistry validation, mask stride, and mask lookup" {
    var reg = SpriteRegistry.get();
    reg.reset();

    const dummy_mask: [8]u8 = [_]u8{0xFF} ** 8;

    const defs = [_]SpriteDef{
        .{
            .name = "sPlayer",
            .width = 16,
            .height = 16,
            .bbox_left = 2,
            .bbox_top = 2,
            .bbox_right = 13,
            .bbox_bottom = 15,
            .colcheck = .aabb,
            .frame_count = 4,
            .mask_count = 0,
        },
        .{
            .name = "sSolid",
            .width = 16,
            .height = 16,
            .bbox_left = 0,
            .bbox_top = 0,
            .bbox_right = 15,
            .bbox_bottom = 15,
            .colcheck = .precise,
            .frame_count = 1,
            .mask_count = 1,
            .masks = &dummy_mask,
        },
    };

    try std.testing.expect(reg.initRegistry(&defs));
    try std.testing.expectEqual(@as(usize, 2), reg.countSprites());
    try std.testing.expect(reg.valid(0));
    try std.testing.expect(reg.valid(1));
    try std.testing.expect(!reg.valid(2));
    try std.testing.expect(!reg.valid(-1));

    const s0 = reg.getSprite(0).?;
    try std.testing.expectEqualStrings("sPlayer", s0.name);
    // bbox width = 13 - 2 + 1 = 12 -> stride = (12 + 7) >> 3 = 2 bytes
    try std.testing.expectEqual(@as(i32, 2), s0.maskStride());
    // rows = 15 - 2 + 1 = 14 -> size = 2 * 14 = 28 bytes
    try std.testing.expectEqual(@as(usize, 28), s0.maskSize());

    const s1 = reg.getSprite(1).?;
    try std.testing.expect(s1.getMask(0) != null);
    try std.testing.expect(s1.getMask(1) == null);
}
