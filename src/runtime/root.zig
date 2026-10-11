//! Spelunky Classic GML Runtime in Idiomatic Zig.
//! Core runtime module exposing instance management, collisions, math, and data structures.

const std = @import("std");

pub const config = struct {
    pub const max_instances: usize = instance.MAX_INSTANCES;
    pub const instance_id_base: i32 = 100000;
    pub const var_count: usize = instance.VAR_COUNT;
    pub const svar_count: usize = instance.SVAR_COUNT;
    pub const vvar_count: usize = instance.VVAR_COUNT;
    pub const alarms_count: usize = 12;
};

pub const value = @import("value.zig");
pub const Value = value.Value;
pub const ValueKind = value.ValueKind;
pub const ArrayManager = value.ArrayManager;
pub const Slot = value.Slot;
pub const aget = value.aget;
pub const aset = value.aset;
pub const aref = value.aref;
pub const compare = value.compare;
pub const compareReal = value.compareReal;

pub const string = @import("string.zig");
pub const StringManager = string.StringManager;

pub const file = @import("file.zig");
pub const FileManager = file.FileManager;
pub const Ini = file.Ini;

pub const platform = @import("platform.zig");
pub const InputButton = platform.InputButton;
pub const InputState = platform.InputState;
pub const PlatformInterface = platform.PlatformInterface;
pub const AudioInterface = platform.AudioInterface;

pub const math = @import("math.zig");
pub const ds = @import("ds.zig");
pub const DsManager = ds.DsManager;

pub const sprite = @import("sprite.zig");
pub const SpriteDef = sprite.SpriteDef;
pub const SpriteRegistry = sprite.SpriteRegistry;
pub const ColCheck = sprite.ColCheck;

pub const object = @import("object.zig");
pub const ObjectRegistry = object.ObjectRegistry;
pub const ObjectDef = object.ObjectDef;

pub const instance = @import("instance.zig");
pub const Instance = instance.Instance;
pub const StaticInstance = instance.StaticInstance;
pub const VariableSlab = instance.VariableSlab;
pub const InstanceManager = instance.InstanceManager;
pub const deref = instance.deref;

pub const with_mod = @import("with.zig");
pub const WithIterator = with_mod.WithIterator;
pub const WithStack = with_mod.WithStack;
pub const ContextManager = with_mod.ContextManager;

pub const collision = @import("collision.zig");

pub const layer = @import("layer.zig");
pub const Layer = layer.Layer;
pub const Element = layer.Element;
pub const LayerManager = layer.LayerManager;

pub const view = @import("view.zig");
pub const View = view.View;
pub const Camera = view.Camera;
pub const ViewField = view.ViewField;
pub const ViewManager = view.ViewManager;

pub const room = @import("room.zig");
pub const RoomDef = room.RoomDef;
pub const RoomViewDef = room.RoomViewDef;
pub const RoomLayerDef = room.RoomLayerDef;
pub const RoomTileDef = room.RoomTileDef;
pub const RoomInstDef = room.RoomInstDef;
pub const RoomHooks = room.RoomHooks;
pub const RoomManager = room.RoomManager;

pub const audio = @import("audio.zig");
pub const AudioManager = audio.AudioManager;
pub const AUDIO_HANDLE_BASE = audio.AUDIO_HANDLE_BASE;

pub const input = @import("input.zig");
pub const InputManager = input.InputManager;
pub const VK_NOKEY = input.VK_NOKEY;
pub const VK_ANYKEY = input.VK_ANYKEY;
pub const MAX_KEYS = input.MAX_KEYS;

pub const draw = @import("draw.zig");
pub const DrawManager = draw.DrawManager;
pub const Xform = draw.Xform;
pub const Surface = draw.Surface;
pub const AddedSprite = draw.AddedSprite;
pub const APP_SURFACE = draw.APP_SURFACE;

pub const profile = @import("profile.zig");

pub const loop = @import("loop.zig");
pub const LoopManager = loop.LoopManager;
pub const LoopHooks = loop.LoopHooks;
pub const LoopStatus = loop.LoopStatus;
pub const Pair = loop.Pair;
pub const DrawLayerFilter = loop.DrawLayerFilter;

test "runtime root sanity and submodules" {
    try std.testing.expectEqual(@as(usize, 2048), config.max_instances);
    _ = value;
    _ = string;
    _ = file;
    _ = platform;
    _ = math;
    _ = ds;
    _ = object;
    _ = instance;
    _ = with_mod;
    _ = collision;
    _ = layer;
    _ = view;
    _ = room;
    _ = audio;
    _ = input;
    _ = draw;
    _ = loop;
    _ = profile;
    _ = @import("test_instance.zig");
    _ = @import("test_collision.zig");
    _ = @import("test_room.zig");
    _ = @import("test_draw.zig");
    _ = @import("test_loop.zig");
}
