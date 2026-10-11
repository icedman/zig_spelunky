//! ABI check of `api.zig` against the SDK headers (`pd_c`: translate-c of
//! C_API/pd_api.h): every table and data struct has the same size, and
//! field for field the same name and offset. The API tables are indexed by
//! position, so a missing or reordered slot would call the wrong function.

const std = @import("std");
const api = @import("api.zig");
const c = @import("pd_c");

/// Zig field name -> C field name, where they differ.
const Alias = struct { zig: []const u8, c: []const u8 };

fn cName(comptime name: []const u8, comptime aliases: []const Alias) []const u8 {
    inline for (aliases) |a| {
        if (comptime std.mem.eql(u8, a.zig, name)) return a.c;
    }
    return name;
}

fn expectSameLayout(comptime Z: type, comptime C: type, comptime aliases: []const Alias) void {
    const zf = @typeInfo(Z).@"struct".fields;
    const cf = @typeInfo(C).@"struct".fields;
    if (zf.len != cf.len) {
        @compileError(std.fmt.comptimePrint("{s}: {d} fields, C {s} has {d}", .{ @typeName(Z), zf.len, @typeName(C), cf.len }));
    }
    inline for (zf, cf) |z, cc| {
        if (!std.mem.eql(u8, cName(z.name, aliases), cc.name)) {
            @compileError(std.fmt.comptimePrint("{s}.{s}: C has {s} at this position", .{ @typeName(Z), z.name, cc.name }));
        }
        if (@offsetOf(Z, z.name) != @offsetOf(C, cc.name)) {
            @compileError(std.fmt.comptimePrint("{s}.{s}: offset {d}, C {d}", .{ @typeName(Z), z.name, @offsetOf(Z, z.name), @offsetOf(C, cc.name) }));
        }
        if (@sizeOf(z.type) != @sizeOf(cc.type)) {
            @compileError(std.fmt.comptimePrint("{s}.{s}: size {d}, C {d}", .{ @typeName(Z), z.name, @sizeOf(z.type), @sizeOf(cc.type) }));
        }
    }
    if (@sizeOf(Z) != @sizeOf(C)) {
        @compileError(std.fmt.comptimePrint("{s}: size {d}, C {d}", .{ @typeName(Z), @sizeOf(Z), @sizeOf(C) }));
    }
}

const Pair = struct { zig: type, c: type, aliases: []const Alias = &.{} };

const pairs = [_]Pair{
    .{ .zig = api.PlaydateAPI, .c = c.struct_PlaydateAPI },
    .{ .zig = api.PlaydateSys, .c = c.struct_playdate_sys, .aliases = &.{.{ .zig = "error", .c = "error" }} },
    .{ .zig = api.PDDateTime, .c = c.struct_PDDateTime },
    .{ .zig = api.PDInfo, .c = c.struct_PDInfo },
    .{ .zig = api.PlaydateFile, .c = c.struct_playdate_file },
    .{ .zig = api.FileStat, .c = c.FileStat },
    .{ .zig = api.LCDRect, .c = c.LCDRect },
    .{ .zig = api.PlaydateVideo, .c = c.struct_playdate_video },
    .{ .zig = api.PlaydateVideostream, .c = c.struct_playdate_videostream },
    .{ .zig = api.PlaydateTilemap, .c = c.struct_playdate_tilemap },
    .{ .zig = api.PlaydateGraphics, .c = c.struct_playdate_graphics },
    .{ .zig = api.PlaydateDisplay, .c = c.struct_playdate_display },
    .{ .zig = api.LuaReg, .c = c.lua_reg },
    .{ .zig = api.LuaVal, .c = c.lua_val },
    .{ .zig = api.PlaydateLua, .c = c.struct_playdate_lua },
    .{ .zig = api.JSONValue, .c = c.json_value },
    .{ .zig = api.JSONDecoder, .c = c.struct_json_decoder },
    .{ .zig = api.JSONReader, .c = c.json_reader },
    // json_encoder has bitfields, which translate-c leaves opaque.
    .{ .zig = api.PlaydateJSON, .c = c.struct_playdate_json },
    .{ .zig = api.PDRect, .c = c.PDRect },
    .{ .zig = api.CollisionPoint, .c = c.CollisionPoint },
    .{ .zig = api.CollisionVector, .c = c.CollisionVector },
    .{ .zig = api.SpriteCollisionInfo, .c = c.struct_SpriteCollisionInfo },
    .{ .zig = api.SpriteQueryInfo, .c = c.struct_SpriteQueryInfo },
    .{ .zig = api.PlaydateSprite, .c = c.struct_playdate_sprite },
    .{ .zig = api.PlaydateSound, .c = c.struct_playdate_sound },
    .{ .zig = api.PlaydateSoundChannel, .c = c.struct_playdate_sound_channel },
    .{ .zig = api.PlaydateSoundSource, .c = c.struct_playdate_sound_source },
    .{ .zig = api.PlaydateSoundFileplayer, .c = c.struct_playdate_sound_fileplayer },
    .{ .zig = api.PlaydateSoundSample, .c = c.struct_playdate_sound_sample },
    .{ .zig = api.PlaydateSoundSampleplayer, .c = c.struct_playdate_sound_sampleplayer },
    .{ .zig = api.PlaydateSoundSignal, .c = c.struct_playdate_sound_signal },
    .{ .zig = api.PlaydateSoundLFO, .c = c.struct_playdate_sound_lfo },
    .{ .zig = api.PlaydateSoundEnvelope, .c = c.struct_playdate_sound_envelope },
    .{ .zig = api.PlaydateSoundSynth, .c = c.struct_playdate_sound_synth },
    .{ .zig = api.PlaydateControlSignal, .c = c.struct_playdate_control_signal },
    .{ .zig = api.PlaydateSoundInstrument, .c = c.struct_playdate_sound_instrument },
    .{ .zig = api.PlaydateSoundTrack, .c = c.struct_playdate_sound_track },
    .{ .zig = api.PlaydateSoundSequence, .c = c.struct_playdate_sound_sequence },
    .{ .zig = api.PlaydateSoundEffect, .c = c.struct_playdate_sound_effect },
    .{ .zig = api.PlaydateSoundEffectTwopolefilter, .c = c.struct_playdate_sound_effect_twopolefilter },
    .{ .zig = api.PlaydateSoundEffectOnepolefilter, .c = c.struct_playdate_sound_effect_onepolefilter },
    .{ .zig = api.PlaydateSoundEffectBitcrusher, .c = c.struct_playdate_sound_effect_bitcrusher },
    .{ .zig = api.PlaydateSoundEffectRingmodulator, .c = c.struct_playdate_sound_effect_ringmodulator },
    .{ .zig = api.PlaydateSoundEffectDelayline, .c = c.struct_playdate_sound_effect_delayline },
    .{ .zig = api.PlaydateSoundEffectOverdrive, .c = c.struct_playdate_sound_effect_overdrive },
    .{ .zig = api.PDScore, .c = c.PDScore },
    .{ .zig = api.PDListScore, .c = c.PDListScore },
    .{ .zig = api.PDScoresList, .c = c.PDScoresList },
    .{ .zig = api.PDBoard, .c = c.PDBoard },
    .{ .zig = api.PDBoardsList, .c = c.PDBoardsList },
    .{ .zig = api.PlaydateScoreboards, .c = c.struct_playdate_scoreboards },
    .{ .zig = api.PlaydateHTTP, .c = c.struct_playdate_http },
    .{ .zig = api.PlaydateTCP, .c = c.struct_playdate_tcp },
    .{ .zig = api.PlaydateNetwork, .c = c.struct_playdate_network },
};

test "api.zig matches the SDK headers" {
    comptime {
        @setEvalBranchQuota(100_000);
        for (pairs) |p| expectSameLayout(p.zig, p.c, p.aliases);
    }
}

test "constants match the SDK headers" {
    try std.testing.expectEqual(c.LCD_COLUMNS, api.LCD_COLUMNS);
    try std.testing.expectEqual(c.LCD_ROWS, api.LCD_ROWS);
    try std.testing.expectEqual(c.LCD_ROWSIZE, api.LCD_ROWSIZE);
    try std.testing.expectEqual(c.kButtonA, api.BUTTON_A);
    try std.testing.expectEqual(c.kButtonB, api.BUTTON_B);
    try std.testing.expectEqual(c.kButtonLeft, api.BUTTON_LEFT);
    try std.testing.expectEqual(c.kButtonDown, api.BUTTON_DOWN);
    try std.testing.expectEqual(c.kFileRead, api.FILE_READ);
    try std.testing.expectEqual(c.kFileReadData, api.FILE_READ_DATA);
    try std.testing.expectEqual(c.kFileWrite, api.FILE_WRITE);
    try std.testing.expectEqual(c.kFileAppend, api.FILE_APPEND);
    try std.testing.expectEqual(c.kEventInit, @intFromEnum(api.PDSystemEvent.EventInit));
    try std.testing.expectEqual(c.kEventTerminate, @intFromEnum(api.PDSystemEvent.EventTerminate));
    try std.testing.expectEqual(c.kEventLowPower, @intFromEnum(api.PDSystemEvent.EventLowPower));
    try std.testing.expectEqual(c.kColorClear, @intFromEnum(api.LCDSolidColor.ColorClear));
    try std.testing.expectEqual(c.kDrawModeFillBlack, @intFromEnum(api.LCDBitmapDrawMode.DrawModeFillBlack));
    try std.testing.expectEqual(c.kBitmapFlippedXY, @intFromEnum(api.LCDBitmapFlip.BitmapFlippedXY));
}
