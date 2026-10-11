//! GML glue between transpiled code (build/zig_gen) and the runtime:
//! `rt` (expression semantics, variables, events) and `api` (built-in
//! function bindings and runtime-owned built-in variables).

const std = @import("std");

pub const rt = @import("rt.zig");
pub const api = @import("api.zig");

/// References every public declaration of `T` (and of the container types it
/// declares, `depth` levels down) so that Zig's lazy analysis type-checks
/// all of them, referenced by tests or not.
pub fn refAllDeclsRecursive(comptime T: type, comptime depth: usize) void {
    // The generated game has thousands of declarations.
    @setEvalBranchQuota(1_000_000);
    inline for (comptime std.meta.declarations(T)) |decl| {
        const d = @field(T, decl.name);
        if (@TypeOf(d) == type and depth > 0) {
            switch (@typeInfo(d)) {
                .@"struct", .@"union", .@"enum" => refAllDeclsRecursive(d, depth - 1),
                else => {},
            }
        }
        _ = &d;
    }
}

test {
    // Force semantic analysis of every binding and helper, referenced or not.
    refAllDeclsRecursive(rt, 1);
    refAllDeclsRecursive(api, 1);
    _ = @import("test_rt.zig");
    _ = @import("test_api.zig");
}
