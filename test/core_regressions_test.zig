const std = @import("std");
const serde = @import("serde");
const testing = std.testing;
const alloc = testing.allocator;
const de = serde.core;

const Required = struct { text: []const u8 = "default", required: i32 };
const Renamed = struct {
    text: []const u8,
    pub const serde = .{ .alias = .{ .text = &.{"alias"} } };
};
const Leaf = struct {
    text: []const u8,
    optional: ?i32,
    count: i32 = 7,
    pub const serde = .{ .rename = .{ .text = "name" } };
};
const Flat = struct {
    leaf: Leaf,
    pub const serde = .{ .flatten = &.{"leaf"} };
};
const DeepFlat = struct {
    flat: Flat,
    pub const serde = .{ .flatten = &.{"flat"} };
};
const Internal = union(enum) {
    item: Flat,
    none,
    pub const serde = .{ .tag = .internal, .tag_field = "kind" };
};
const Adjacent = union(enum) {
    item: Leaf,
    none,
    pub const serde = .{ .tag = .adjacent, .tag_field = "kind", .content_field = "data" };
};

test "defaults, duplicates and trailing data clean up owned memory" {
    try testing.expectError(error.MissingField, serde.json.fromSlice(Required, alloc, "{}"));
    try testing.expectError(error.MissingField, serde.json.fromSlice(Required, alloc, "{\"text\":\"owned\"}"));
    try testing.expectError(error.DuplicateField, serde.json.fromSlice(Renamed, alloc, "{\"text\":\"a\",\"alias\":\"b\"}"));
    try testing.expectError(error.TrailingData, serde.json.fromSlice(Required, alloc, "{\"required\":1}x"));
    try testing.expectError(error.TrailingData, serde.json.fromSlice(Renamed, alloc, "{\"text\":\"owned\"}x"));
    try testing.expectError(error.MissingField, serde.json.fromSlice(DeepFlat, alloc, "{}"));
}

test "partial and overlong containers release every element" {
    try testing.expectError(error.UnexpectedToken, serde.json.fromSlice([1][]const u8, alloc, "[\"a\",\"b\"]"));
    try testing.expectError(error.UnexpectedToken, serde.json.fromSlice(struct { []const u8 }, alloc, "[\"a\",\"b\"]"));
    try testing.expectError(error.WrongType, serde.json.fromSlice([]const []const u8, alloc, "[\"a\",true]"));
    try testing.expectError(error.UnexpectedToken, serde.json.fromSlice(union(enum) { item: []const u8 }, alloc, "{\"item\":\"a\",\"extra\":1}"));
}

test "borrowed array strings retain input addresses and survive errors" {
    const input = "[\"one\",\"two\"]";
    const value = try serde.json.fromSliceBorrowed([2][]const u8, alloc, input);
    try testing.expectEqual(@intFromPtr(input.ptr) + 2, @intFromPtr(value[0].ptr));
    try testing.expectEqual(@intFromPtr(input.ptr) + 8, @intFromPtr(value[1].ptr));
    try testing.expectError(error.WrongType, serde.json.fromSliceBorrowed([]const []const u8, alloc, "[\"one\",false]"));
    try testing.expectError(error.TrailingData, serde.json.fromSliceBorrowed([2][]const u8, alloc, input ++ "x"));
    try testing.expectError(error.InvalidEscape, serde.json.fromSliceBorrowed([1][]const u8, alloc, "[\"a\\nb\"]"));
}

test "flatten and union payloads obey nested settings in both directions" {
    const inputs = [_][]const u8{
        "{\"kind\":\"item\",\"name\":\"value\"}",
        "{\"name\":\"value\",\"kind\":\"item\"}",
    };
    for (inputs) |input| {
        const value = try serde.json.fromSlice(Internal, alloc, input);
        defer de.freeAllocated(Internal, value, alloc);
        try testing.expectEqualStrings("value", value.item.leaf.text);
        try testing.expectEqual(@as(i32, 7), value.item.leaf.count);
        const bytes = try serde.msgpack.toSlice(alloc, value);
        defer alloc.free(bytes);
        const decoded = try serde.msgpack.fromSlice(Internal, alloc, bytes);
        defer de.freeAllocated(Internal, decoded, alloc);
        try testing.expectEqualStrings("value", decoded.item.leaf.text);
    }
    for ([_][]const u8{
        "{\"kind\":\"item\",\"data\":{\"name\":\"v\"}}",
        "{\"data\":{\"name\":\"v\"},\"kind\":\"item\"}",
    }) |input| {
        const value = try serde.json.fromSlice(Adjacent, alloc, input);
        defer de.freeAllocated(Adjacent, value, alloc);
        try testing.expectEqualStrings("v", value.item.text);
    }
}

fn allocationPaths(allocator: std.mem.Allocator) !void {
    const value = try serde.json.fromSlice(DeepFlat, allocator, "{\"na\\u006de\":\"v\"}");
    defer de.freeAllocated(DeepFlat, value, allocator);
    const array = try serde.json.fromSlice([]const []const u8, allocator, "[\"one\",\"two\"]");
    defer de.freeAllocated(@TypeOf(array), array, allocator);
    const map = try serde.json.fromSlice(std.StringHashMap([]const u8), allocator, "{\"key\":\"old\",\"key\":\"new\"}");
    defer de.freeAllocated(@TypeOf(map), map, allocator);
    try testing.expectEqualStrings("new", map.get("key").?);
    const tagged = try serde.json.fromSlice(Adjacent, allocator, "{\"data\":{\"name\":\"v\"},\"kind\":\"item\"}");
    defer de.freeAllocated(Adjacent, tagged, allocator);
}
test "core paths release all allocations at every allocation failure" {
    try testing.checkAllAllocationFailures(alloc, allocationPaths, .{});
}

fn treePaths(allocator: std.mem.Allocator) !void {
    const T = struct { name: []const u8, values: []const []const u8 };
    const toml = try serde.toml.fromSlice(T, allocator, "name = \"ok\"\nvalues = [\"a\", \"b\"]\n");
    defer de.freeAllocated(T, toml, allocator);
    const yaml = try serde.yaml.fromSlice(T, allocator, "name: ok\nvalues: [a, b]\n");
    defer de.freeAllocated(T, yaml, allocator);
}
test "TOML and YAML temporary trees and result allocation failures" {
    try testing.checkAllAllocationFailures(alloc, treePaths, .{});
}
