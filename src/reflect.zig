const std = @import("std");

pub const StructField = struct {
    name: [:0]const u8,
    type: type,
    default_value_ptr: ?*const anyopaque,
    is_comptime: bool,

    /// Returns `null` if the field has no default value.
    pub inline fn defaultValue(comptime sf: StructField) ?sf.type {
        const dp: *const sf.type = @ptrCast(@alignCast(sf.default_value_ptr orelse return null));
        return dp.*;
    }
};

pub const EnumField = struct {
    name: [:0]const u8,
    value: comptime_int,
};

pub const UnionField = struct {
    name: [:0]const u8,
    type: type,
};

const soa = !@hasField(std.builtin.Type.Struct, "fields");

pub inline fn structFields(comptime T: type) []const if (soa) StructField else std.builtin.Type.StructField {
    const si = @typeInfo(T).@"struct";
    comptime if (!soa) return si.fields;

    comptime var out: []const StructField = &.{};

    inline for (si.field_names, si.field_types, si.field_attrs) |fnam, ft, fa| {
        out = out ++ &[_]StructField{
            StructField{
                .name = fnam,
                .default_value_ptr = fa.default_value_ptr,
                .is_comptime = fa.@"comptime",
                .type = ft,
            },
        };
    }

    return out;
}

pub inline fn enumFields(comptime T: type) []const if (soa) EnumField else std.builtin.Type.EnumField {
    const ei = @typeInfo(T).@"enum";
    comptime if (!soa) return ei.fields;

    comptime var out: []const EnumField = &.{};

    inline for (ei.field_names, ei.field_values) |fnam, fv| {
        out = out ++ &[_]EnumField{.{ .name = fnam, .value = fv }};
    }

    return out;
}

pub inline fn unionFields(comptime T: type) []const if (soa) UnionField else std.builtin.Type.UnionField {
    const ui = @typeInfo(T).@"union";
    comptime if (!soa) return ui.fields;

    comptime var out: []const UnionField = &.{};

    inline for (ui.field_names, ui.field_types) |fnam, ft| {
        out = out ++ &[_]UnionField{.{ .name = fnam, .type = ft }};
    }

    return out;
}

const testing = std.testing;

test "structFields" {
    const S = struct {
        name: []const u8,
        address: *anyopaque,
    };

    const fields = structFields(S);

    try testing.expect(fields.len == 2);
    try testing.expectEqualStrings("name", fields[0].name);
    try testing.expectEqualStrings("address", fields[1].name);
    try testing.expect(fields[0].type == []const u8);
}

test "structFields: default values" {
    const S = struct { a: u32, b: []const u8 = "hi", c: ?f64 = null };
    const fields = comptime structFields(S);

    try testing.expect(comptime fields[0].defaultValue() == null);
    try testing.expectEqualStrings("hi", comptime fields[1].defaultValue().?);
    try testing.expect(comptime fields[2].defaultValue().? == null);
}

test "structFields: tuple, empty struct, anon literal" {
    const tuple = comptime structFields(struct { i32, bool });
    try testing.expect(tuple.len == 2);
    try testing.expect(tuple[1].type == bool);

    try testing.expect(comptime structFields(struct {}).len == 0);

    const attrs = .{ .alpha = @as(u8, 1), .beta = true };
    const anon = comptime structFields(@TypeOf(attrs));
    try testing.expectEqualStrings("alpha", anon[0].name);
    try testing.expectEqual(true, @field(attrs, anon[1].name));
}

test "enumFields: explicit values" {
    const E = enum(u8) { red = 3, green = 7, blue = 9 };
    const fields = comptime enumFields(E);

    try testing.expect(fields.len == 3);
    try testing.expectEqualStrings("green", fields[1].name);
    try testing.expect(fields[1].value == 7);
    try testing.expectEqual(E.blue, @as(E, @enumFromInt(fields[2].value)));
}

test "unionFields: payload and void variants" {
    const U = union(enum) { num: i64, nothing: void, nested: struct { w: f64 } };
    const fields = comptime unionFields(U);

    try testing.expect(fields.len == 3);
    try testing.expect(fields[0].type == i64);
    try testing.expect(fields[1].type == void);
    try testing.expectEqualStrings("nested", fields[2].name);
}

test "inline for mirrors serializer call sites" {
    const S = struct { x: i32 = 5, y: i32 = 6 };
    var s: S = undefined;
    inline for (structFields(S)) |field| {
        if (comptime field.defaultValue()) |dv| @field(s, field.name) = dv;
    }
    try testing.expectEqual(5, s.x);
    try testing.expectEqual(6, s.y);
}

test "runtime key matched against comptime field names" {
    const E = enum { alpha, beta };
    const key: []const u8 = "beta";
    var found: ?E = null;
    inline for (enumFields(E)) |field| {
        if (std.mem.eql(u8, key, field.name)) found = @enumFromInt(field.value);
    }
    try testing.expectEqual(E.beta, found.?);
}

test "non-inline comptime for over fields" {
    const S = struct { a: u8, bb: u8, ccc: u8 };
    const total = comptime blk: {
        var n: usize = 0;
        for (structFields(S)) |field| n += field.name.len;
        break :blk n;
    };
    try testing.expectEqual(6, total);
}

test "field count is usable as a comptime size" {
    const S = struct { a: u8, b: u8, c: u8 };
    const BitSet = std.StaticBitSet(structFields(S).len);
    var seen = if (@hasDecl(BitSet, "empty")) BitSet.empty else BitSet.initEmpty();
    seen.set(1);
    try testing.expect(seen.capacity() == 3);
    try testing.expect(seen.isSet(1));
}
