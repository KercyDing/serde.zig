//! Compile-time expansion of struct fields shared by serialization and parsing.
const std = @import("std");
const reflect = @import("../reflect.zig");
const opts = @import("options.zig");

pub fn leaves(comptime T: type, comptime schema: anytype, comptime dir: opts.Direction) @TypeOf(expand(T, schema, dir, &.{}, 0)) {
    return comptime expand(T, schema, dir, &.{}, 0);
}

fn expand(comptime T: type, comptime schema: anytype, comptime dir: opts.Direction, comptime path: []const []const u8, comptime i: usize) blk: {
    @setEvalBranchQuota(100_000);
    const fs = reflect.structFields(T);
    if (i == fs.len) break :blk @TypeOf(.{});
    const f = fs[i];
    const next = path ++ &[_][]const u8{f.name};
    const head = if (opts.isFlattenedFieldSchema(T, f.name, schema) and !opts.shouldSkipFieldSchema(T, f.name, dir, schema))
        expand(f.type, {}, dir, next, 0)
    else
        .{Leaf(T, schema, f, next)};
    break :blk @TypeOf(head ++ expand(T, schema, dir, path, i + 1));
} {
    const fs = comptime reflect.structFields(T);
    if (comptime i == fs.len) return .{};
    const f = fs[i];
    const next = path ++ &[_][]const u8{f.name};
    const head = comptime if (opts.isFlattenedFieldSchema(T, f.name, schema) and !opts.shouldSkipFieldSchema(T, f.name, dir, schema))
        expand(f.type, {}, dir, next, 0)
    else
        .{Leaf(T, schema, f, next)};
    return head ++ expand(T, schema, dir, path, i + 1);
}

fn Leaf(comptime P: type, comptime s: anytype, comptime f: anytype, comptime p: []const []const u8) type {
    return struct {
        pub const Parent = P;
        pub const schema = s;
        pub const field = f;
        pub const path = p;
        pub fn get(value: anytype) f.type {
            return fieldValue(value, p);
        }
        pub fn ptr(value: anytype) *f.type {
            return fieldPtr(value, p);
        }
    };
}
fn fieldValue(value: anytype, comptime path: []const []const u8) blk: {
    if (path.len == 0) break :blk @TypeOf(value);
    break :blk @TypeOf(fieldValue(@field(value, path[0]), path[1..]));
} {
    if (path.len == 0) return value;
    return fieldValue(@field(value, path[0]), path[1..]);
}
fn fieldPtr(value: anytype, comptime path: []const []const u8) blk: {
    if (path.len == 0) break :blk @TypeOf(value);
    break :blk @TypeOf(fieldPtr(&@field(value.*, path[0]), path[1..]));
} {
    if (path.len == 0) return value;
    return fieldPtr(&@field(value.*, path[0]), path[1..]);
}

pub fn validate(comptime T: type, comptime schema: anytype, comptime dir: opts.Direction) void {
    @setEvalBranchQuota(100_000);
    const fs = leaves(T, schema, dir);
    for (fs, 0..) |A, i| {
        if (opts.shouldSkipFieldSchema(A.Parent, A.field.name, dir, A.schema)) continue;
        for (fs, 0..) |B, j| {
            if (j >= i) continue;
            if (opts.shouldSkipFieldSchema(B.Parent, B.field.name, dir, B.schema)) continue;
            const an = opts.wireFieldNameForDir(A.Parent, A.field.name, A.schema, dir);
            const bn = opts.wireFieldNameForDir(B.Parent, B.field.name, B.schema, dir);
            if (std.mem.eql(u8, an, bn)) @compileError("Ambiguous serde field name: " ++ an);
            if (dir == .deserialize) {
                for (opts.getFieldAliases(A.Parent, A.field.name, A.schema)) |a| {
                    if (opts.matchesDeserializeName(B.Parent, B.field.name, a, B.schema)) @compileError("Ambiguous serde alias: " ++ a);
                }
                for (opts.getFieldAliases(B.Parent, B.field.name, B.schema)) |b| {
                    if (std.mem.eql(u8, an, b)) @compileError("Ambiguous serde alias: " ++ b);
                }
            }
        }
    }
}
