//! GameMaker Data Structures (ds_map) used by Spelunky Classic HD.
//! Static pools guarantee zero dynamic heap allocation in frame updates.
//! Follows reference/GameMaker-HTML5/scripts/functions/collections/ds_map.js and packaged_src/src/runtime/gm_ds.c.

const std = @import("std");
const Value = @import("value.zig").Value;

pub const MAX_MAPS: usize = 32;
pub const MAX_ENTRIES: usize = 128;
pub const STRING_BYTES: usize = 8192;

const MapEntry = struct {
    key_offset: u16 = 0,
    val_offset: u16 = 0,
    value: Value = Value.UNDEFINED,
    is_string_val: bool = false,
    in_use: bool = false,
};

const DsMap = struct {
    in_use: bool = false,
    entries: [MAX_ENTRIES]MapEntry = [_]MapEntry{.{}} ** MAX_ENTRIES,
    order: [MAX_ENTRIES]u8 = [_]u8{0} ** MAX_ENTRIES,
    entry_count: usize = 0,
    strings: [STRING_BYTES]u8 = undefined,
    string_used: usize = 0,

    fn clear(self: *DsMap) void {
        self.entry_count = 0;
        self.string_used = 0;
        for (&self.entries) |*entry| {
            entry.in_use = false;
        }
    }

    fn getKey(self: *const DsMap, entry: *const MapEntry) []const u8 {
        const start = entry.key_offset;
        var end = start;
        while (end < self.string_used and self.strings[end] != 0) : (end += 1) {}
        return self.strings[start..end];
    }

    fn getStringVal(self: *const DsMap, entry: *const MapEntry) []const u8 {
        const start = entry.val_offset;
        var end = start;
        while (end < self.string_used and self.strings[end] != 0) : (end += 1) {}
        return self.strings[start..end];
    }

    fn allocString(self: *DsMap, str: []const u8) ?u16 {
        const needed = str.len + 1;
        if (self.string_used + needed > STRING_BYTES) return null;
        const off = self.string_used;
        @memcpy(self.strings[off .. off + str.len], str);
        self.strings[off + str.len] = 0;
        self.string_used += needed;
        return @intCast(off);
    }

    fn findIndex(self: *const DsMap, key: []const u8) ?usize {
        for (0..self.entry_count) |ord_i| {
            const ent_idx = self.order[ord_i];
            const ent = &self.entries[ent_idx];
            if (ent.in_use and std.mem.eql(u8, self.getKey(ent), key)) {
                return ent_idx;
            }
        }
        return null;
    }
};

pub const DsManager = struct {
    maps: [MAX_MAPS]DsMap = [_]DsMap{.{}} ** MAX_MAPS,

    var instance: DsManager = .{};

    pub fn get() *DsManager {
        return &instance;
    }

    pub fn reset(self: *DsManager) void {
        for (&self.maps) |*m| {
            m.in_use = false;
            m.clear();
        }
    }

    pub fn create(self: *DsManager) ?i32 {
        for (&self.maps, 0..) |*m, idx| {
            if (!m.in_use) {
                m.in_use = true;
                m.clear();
                return @intCast(idx);
            }
        }
        return null;
    }

    pub fn destroy(self: *DsManager, id: i32) void {
        if (id < 0 or id >= MAX_MAPS) return;
        const u_id: usize = @intCast(id);
        self.maps[u_id].in_use = false;
        self.maps[u_id].clear();
    }

    pub fn isValid(self: *const DsManager, id: i32) bool {
        if (id < 0 or id >= MAX_MAPS) return false;
        return self.maps[@intCast(id)].in_use;
    }

    pub fn clear(self: *DsManager, id: i32) void {
        if (id < 0 or id >= MAX_MAPS) return;
        self.maps[@intCast(id)].clear();
    }

    pub fn size(self: *const DsManager, id: i32) usize {
        if (id < 0 or id >= MAX_MAPS) return 0;
        const m = &self.maps[@intCast(id)];
        return if (m.in_use) m.entry_count else 0;
    }

    pub fn exists(self: *const DsManager, id: i32, key: []const u8) bool {
        if (id < 0 or id >= MAX_MAPS) return false;
        const m = &self.maps[@intCast(id)];
        if (!m.in_use) return false;
        return m.findIndex(key) != null;
    }

    pub fn replace(self: *DsManager, id: i32, key: []const u8, val: Value) bool {
        if (id < 0 or id >= MAX_MAPS) return false;
        var m = &self.maps[@intCast(id)];
        if (!m.in_use) return false;

        // Existing key update
        if (m.findIndex(key)) |ent_idx| {
            var ent = &m.entries[ent_idx];
            if (val == .string) {
                const val_off = m.allocString(val.string) orelse return false;
                ent.val_offset = val_off;
                ent.is_string_val = true;
                ent.value = Value.fromString(m.getStringVal(ent));
            } else {
                ent.is_string_val = false;
                ent.value = val;
            }
            return true;
        }

        // New key insertion
        if (m.entry_count >= MAX_ENTRIES) return false;

        const key_off = m.allocString(key) orelse return false;
        var val_off: u16 = 0;
        var is_str = false;
        var final_val = val;

        if (val == .string) {
            val_off = m.allocString(val.string) orelse return false;
            is_str = true;
        }

        const ent_idx = for (&m.entries, 0..) |*e, i| {
            if (!e.in_use) break i;
        } else return false;

        var ent = &m.entries[ent_idx];
        ent.in_use = true;
        ent.key_offset = key_off;
        ent.val_offset = val_off;
        ent.is_string_val = is_str;
        if (is_str) {
            final_val = Value.fromString(m.getStringVal(ent));
        }
        ent.value = final_val;

        m.order[m.entry_count] = @intCast(ent_idx);
        m.entry_count += 1;
        return true;
    }

    pub fn findValue(self: *const DsManager, id: i32, key: []const u8) Value {
        if (id < 0 or id >= MAX_MAPS) return Value.UNDEFINED;
        const m = &self.maps[@intCast(id)];
        if (!m.in_use) return Value.UNDEFINED;
        const ent_idx = m.findIndex(key) orelse return Value.UNDEFINED;
        return m.entries[ent_idx].value;
    }

    pub fn findFirst(self: *const DsManager, id: i32) Value {
        if (id < 0 or id >= MAX_MAPS) return Value.UNDEFINED;
        const m = &self.maps[@intCast(id)];
        if (!m.in_use or m.entry_count == 0) return Value.UNDEFINED;
        const ent = &m.entries[m.order[0]];
        return Value.fromString(m.getKey(ent));
    }

    pub fn findNext(self: *const DsManager, id: i32, key: []const u8) Value {
        if (id < 0 or id >= MAX_MAPS) return Value.UNDEFINED;
        const m = &self.maps[@intCast(id)];
        if (!m.in_use) return Value.UNDEFINED;

        var found_curr = false;
        for (0..m.entry_count) |ord_i| {
            const ent = &m.entries[m.order[ord_i]];
            if (found_curr) {
                return Value.fromString(m.getKey(ent));
            }
            if (std.mem.eql(u8, m.getKey(ent), key)) {
                found_curr = true;
            }
        }
        return Value.UNDEFINED;
    }
};

test "DsManager ds_map create, replace, find, iterate, delete" {
    var mgr = DsManager.get();
    mgr.reset();

    const m = mgr.create();
    try std.testing.expect(m != null);
    const map_id = m.?;

    try std.testing.expect(mgr.isValid(map_id));
    try std.testing.expectEqual(@as(usize, 0), mgr.size(map_id));

    _ = mgr.replace(map_id, "score", Value.fromReal(50000.0));
    _ = mgr.replace(map_id, "player", Value.fromString("Guy Spelunky"));

    try std.testing.expectEqual(@as(usize, 2), mgr.size(map_id));
    try std.testing.expect(mgr.exists(map_id, "score"));
    try std.testing.expect(mgr.exists(map_id, "player"));
    try std.testing.expect(!mgr.exists(map_id, "bombs"));

    const score_val = mgr.findValue(map_id, "score");
    try std.testing.expectEqual(@as(f32, 50000.0), score_val.toReal());

    const player_val = mgr.findValue(map_id, "player");
    try std.testing.expectEqualStrings("Guy Spelunky", player_val.string);

    // Iteration follows insertion order
    const first_key = mgr.findFirst(map_id);
    try std.testing.expectEqualStrings("score", first_key.string);

    const next_key = mgr.findNext(map_id, "score");
    try std.testing.expectEqualStrings("player", next_key.string);

    const end_key = mgr.findNext(map_id, "player");
    try std.testing.expect(end_key.isUndefined());

    mgr.destroy(map_id);
    try std.testing.expect(!mgr.isValid(map_id));
}
