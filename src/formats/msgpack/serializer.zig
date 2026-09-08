const std = @import("std");
const compat = @import("compat");
const core_serialize = @import("../../core/serialize.zig");

const Allocator = std.mem.Allocator;

/// `LengthOverflow` is returned when a container holds more than `maxInt(u32)`
/// entries, which MessagePack headers cannot express.
pub const SerializeError = error{ OutOfMemory, WriteFailed, LengthOverflow };

/// Direct containers are handed an element count up front and cannot recover
/// if the caller emits a different number, so the count is verified whenever
/// runtime safety is on. Both the counters and the checks compile out
/// otherwise.
const count_check = std.debug.runtime_safety;

const Counter = if (count_check) usize else void;

fn counter(value: usize) Counter {
    if (count_check) return value;
    return {};
}

fn countMismatch(declared: Counter, written: Counter) void {
    if (count_check and written != declared)
        std.debug.panic("msgpack container declared {d} entries but wrote {d}", .{ declared, written });
}

pub const Serializer = struct {
    out: *compat.Io.Writer,
    allocator: Allocator,

    pub const Error = SerializeError;

    pub fn init(out: *compat.Io.Writer, allocator: Allocator) Serializer {
        return .{ .out = out, .allocator = allocator };
    }

    pub fn serializeBool(self: *Serializer, value: bool) Error!void {
        self.out.writeByte(if (value) 0xc3 else 0xc2) catch return error.WriteFailed;
    }

    pub fn serializeInt(self: *Serializer, value: anytype) Error!void {
        const T = @TypeOf(value);
        const info = @typeInfo(T);

        if (info == .comptime_int) {
            if (value >= 0) {
                writeUint(self.out, @as(u64, @intCast(value))) catch return error.WriteFailed;
            } else {
                writeSint(self.out, @as(i64, @intCast(value))) catch return error.WriteFailed;
            }
            return;
        }

        switch (info.int.signedness) {
            .unsigned => {
                writeUint(self.out, @intCast(value)) catch return error.WriteFailed;
            },
            .signed => {
                const v: i64 = @intCast(value);
                if (v >= 0) {
                    writeUint(self.out, @intCast(v)) catch return error.WriteFailed;
                } else {
                    writeSint(self.out, v) catch return error.WriteFailed;
                }
            },
        }
    }

    pub fn serializeFloat(self: *Serializer, value: anytype) Error!void {
        const T = @TypeOf(value);
        if (T == f32 or T == f16) {
            const v: f32 = if (T == f16) @floatCast(value) else value;
            self.out.writeByte(0xca) catch return error.WriteFailed;
            self.out.writeAll(&toBE(u32, @bitCast(v))) catch return error.WriteFailed;
        } else {
            const v: f64 = @floatCast(value);
            self.out.writeByte(0xcb) catch return error.WriteFailed;
            self.out.writeAll(&toBE(u64, @bitCast(v))) catch return error.WriteFailed;
        }
    }

    pub fn serializeString(self: *Serializer, value: []const u8) Error!void {
        writeStrHeader(self.out, value.len) catch return error.WriteFailed;
        self.out.writeAll(value) catch return error.WriteFailed;
    }

    pub fn serializeBytes(self: *Serializer, value: []const u8) Error!void {
        writeBinHeader(self.out, value.len) catch return error.WriteFailed;
        self.out.writeAll(value) catch return error.WriteFailed;
    }

    pub fn serializeNull(self: *Serializer) Error!void {
        self.out.writeByte(0xc0) catch return error.WriteFailed;
    }

    pub fn serializeVoid(self: *Serializer) Error!void {
        self.out.writeByte(0xc0) catch return error.WriteFailed;
    }

    pub fn beginStruct(self: *Serializer) Error!StructSerializer {
        return .{
            .parent_out = self.out,
            .aw = .init(self.allocator),
            .allocator = self.allocator,
            .field_count = 0,
        };
    }

    pub fn beginArray(self: *Serializer) Error!ArraySerializer {
        return .{
            .parent_out = self.out,
            .aw = .init(self.allocator),
            .allocator = self.allocator,
            .elem_count = 0,
        };
    }

    /// Writes a compact header immediately when the caller already knows the
    /// element count. The generic streaming API remains buffered because its
    /// final count may depend on runtime decisions.
    pub fn beginStructLen(self: *Serializer, len: usize) Error!DirectStructSerializer {
        if (len > std.math.maxInt(u32)) return error.LengthOverflow;
        writeMapHeader(self.out, @intCast(len)) catch return error.WriteFailed;
        return .{ .out = self.out, .allocator = self.allocator, .declared = counter(len) };
    }

    pub fn beginArrayLen(self: *Serializer, len: usize) Error!DirectArraySerializer {
        if (len > std.math.maxInt(u32)) return error.LengthOverflow;
        writeArrayHeader(self.out, @intCast(len)) catch return error.WriteFailed;
        return .{ .out = self.out, .allocator = self.allocator, .declared = counter(len) };
    }
};

/// A container whose header has already been written. This is deliberately a
/// separate type so the hot path has no runtime "buffered or direct" branch.
/// Mirrors the surface of `StructSerializer`.
pub const DirectStructSerializer = struct {
    out: *compat.Io.Writer,
    allocator: Allocator,
    declared: Counter,
    written: Counter = counter(0),

    pub const Error = SerializeError;

    pub fn serializeField(self: *DirectStructSerializer, comptime key: []const u8, value: anytype) Error!void {
        var child = Serializer.init(self.out, self.allocator);
        try child.serializeString(key);
        try core_serialize.serialize(@TypeOf(value), value, &child, .{});
        if (count_check) self.written += 1;
    }

    pub fn serializeEntry(self: *DirectStructSerializer, key: anytype, value: anytype) Error!void {
        var child = Serializer.init(self.out, self.allocator);
        try core_serialize.serialize(@TypeOf(key), key, &child, .{});
        try core_serialize.serialize(@TypeOf(value), value, &child, .{});
        if (count_check) self.written += 1;
    }

    pub fn end(self: *DirectStructSerializer) Error!void {
        countMismatch(self.declared, self.written);
    }
};

pub const DirectArraySerializer = struct {
    out: *compat.Io.Writer,
    allocator: Allocator,
    declared: Counter,
    written: Counter = counter(0),

    pub const Error = SerializeError;

    fn child(self: *DirectArraySerializer) Serializer {
        if (count_check) self.written += 1;
        return Serializer.init(self.out, self.allocator);
    }

    pub fn serializeBool(self: *DirectArraySerializer, value: bool) Error!void {
        var serializer = self.child();
        try serializer.serializeBool(value);
    }

    pub fn serializeInt(self: *DirectArraySerializer, value: anytype) Error!void {
        var serializer = self.child();
        try serializer.serializeInt(value);
    }

    pub fn serializeFloat(self: *DirectArraySerializer, value: anytype) Error!void {
        var serializer = self.child();
        try serializer.serializeFloat(value);
    }

    pub fn serializeString(self: *DirectArraySerializer, value: []const u8) Error!void {
        var serializer = self.child();
        try serializer.serializeString(value);
    }

    pub fn serializeBytes(self: *DirectArraySerializer, value: []const u8) Error!void {
        var serializer = self.child();
        try serializer.serializeBytes(value);
    }

    pub fn serializeNull(self: *DirectArraySerializer) Error!void {
        var serializer = self.child();
        try serializer.serializeNull();
    }

    pub fn serializeVoid(self: *DirectArraySerializer) Error!void {
        var serializer = self.child();
        try serializer.serializeVoid();
    }

    pub fn beginStruct(self: *DirectArraySerializer) Error!StructSerializer {
        var serializer = self.child();
        return serializer.beginStruct();
    }

    pub fn beginArray(self: *DirectArraySerializer) Error!ArraySerializer {
        var serializer = self.child();
        return serializer.beginArray();
    }

    pub fn beginStructLen(self: *DirectArraySerializer, len: usize) Error!DirectStructSerializer {
        var serializer = self.child();
        return serializer.beginStructLen(len);
    }

    pub fn beginArrayLen(self: *DirectArraySerializer, len: usize) Error!DirectArraySerializer {
        var serializer = self.child();
        return serializer.beginArrayLen(len);
    }

    pub fn end(self: *DirectArraySerializer) Error!void {
        countMismatch(self.declared, self.written);
    }
};

// Buffers serialized fields, writes map header + buffered data on end().
// MessagePack maps require the element count in the header, but we don't know
// the count until all fields are serialized (skip_if_null etc. are runtime decisions).
pub const StructSerializer = struct {
    parent_out: *compat.Io.Writer,
    aw: compat.Io.Writer.Allocating,
    allocator: Allocator,
    field_count: u32,

    pub const Error = SerializeError;

    pub fn serializeField(self: *StructSerializer, comptime key: []const u8, value: anytype) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeString(key);
        try core_serialize.serialize(@TypeOf(value), value, &child, .{});
        self.field_count += 1;
    }

    pub fn serializeEntry(self: *StructSerializer, key: anytype, value: anytype) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try core_serialize.serialize(@TypeOf(key), key, &child, .{});
        try core_serialize.serialize(@TypeOf(value), value, &child, .{});
        self.field_count += 1;
    }

    pub fn end(self: *StructSerializer) Error!void {
        writeMapHeader(self.parent_out, self.field_count) catch {
            self.aw.deinit();
            return error.WriteFailed;
        };
        const data = self.aw.writer.buffer[0..self.aw.writer.end];
        self.parent_out.writeAll(data) catch {
            self.aw.deinit();
            return error.WriteFailed;
        };
        self.aw.deinit();
    }
};

pub const ArraySerializer = struct {
    parent_out: *compat.Io.Writer,
    aw: compat.Io.Writer.Allocating,
    allocator: Allocator,
    elem_count: u32,

    pub const Error = SerializeError;

    pub fn serializeBool(self: *ArraySerializer, value: bool) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeBool(value);
        self.elem_count += 1;
    }

    pub fn serializeInt(self: *ArraySerializer, value: anytype) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeInt(value);
        self.elem_count += 1;
    }

    pub fn serializeFloat(self: *ArraySerializer, value: anytype) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeFloat(value);
        self.elem_count += 1;
    }

    pub fn serializeString(self: *ArraySerializer, value: []const u8) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeString(value);
        self.elem_count += 1;
    }

    pub fn serializeBytes(self: *ArraySerializer, value: []const u8) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeBytes(value);
        self.elem_count += 1;
    }

    pub fn serializeNull(self: *ArraySerializer) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeNull();
        self.elem_count += 1;
    }

    pub fn serializeVoid(self: *ArraySerializer) Error!void {
        var child = Serializer.init(&self.aw.writer, self.allocator);
        try child.serializeVoid();
        self.elem_count += 1;
    }

    pub fn beginStruct(self: *ArraySerializer) Error!StructSerializer {
        self.elem_count += 1;
        return .{
            .parent_out = &self.aw.writer,
            .aw = .init(self.allocator),
            .allocator = self.allocator,
            .field_count = 0,
        };
    }

    pub fn beginArray(self: *ArraySerializer) Error!ArraySerializer {
        self.elem_count += 1;
        return .{
            .parent_out = &self.aw.writer,
            .aw = .init(self.allocator),
            .allocator = self.allocator,
            .elem_count = 0,
        };
    }

    pub fn end(self: *ArraySerializer) Error!void {
        writeArrayHeader(self.parent_out, self.elem_count) catch {
            self.aw.deinit();
            return error.WriteFailed;
        };
        const data = self.aw.writer.buffer[0..self.aw.writer.end];
        self.parent_out.writeAll(data) catch {
            self.aw.deinit();
            return error.WriteFailed;
        };
        self.aw.deinit();
    }
};

// Wire format helpers.

fn writeUint(out: *compat.Io.Writer, v: u64) !void {
    if (v <= 0x7f) {
        try out.writeByte(@intCast(v));
    } else if (v <= 0xff) {
        try out.writeByte(0xcc);
        try out.writeByte(@intCast(v));
    } else if (v <= 0xffff) {
        try out.writeByte(0xcd);
        try out.writeAll(&toBE(u16, @intCast(v)));
    } else if (v <= 0xffffffff) {
        try out.writeByte(0xce);
        try out.writeAll(&toBE(u32, @intCast(v)));
    } else {
        try out.writeByte(0xcf);
        try out.writeAll(&toBE(u64, v));
    }
}

fn writeSint(out: *compat.Io.Writer, v: i64) !void {
    if (v >= -32) {
        try out.writeByte(@bitCast(@as(i8, @intCast(v))));
    } else if (v >= -128) {
        try out.writeByte(0xd0);
        try out.writeByte(@bitCast(@as(i8, @intCast(v))));
    } else if (v >= -32768) {
        try out.writeByte(0xd1);
        try out.writeAll(&toBE(u16, @bitCast(@as(i16, @intCast(v)))));
    } else if (v >= -2147483648) {
        try out.writeByte(0xd2);
        try out.writeAll(&toBE(u32, @bitCast(@as(i32, @intCast(v)))));
    } else {
        try out.writeByte(0xd3);
        try out.writeAll(&toBE(u64, @bitCast(v)));
    }
}

fn writeStrHeader(out: *compat.Io.Writer, len: usize) !void {
    if (len <= 31) {
        try out.writeByte(@as(u8, 0xa0) | @as(u8, @intCast(len)));
    } else if (len <= 0xff) {
        try out.writeByte(0xd9);
        try out.writeByte(@intCast(len));
    } else if (len <= 0xffff) {
        try out.writeByte(0xda);
        try out.writeAll(&toBE(u16, @intCast(len)));
    } else {
        try out.writeByte(0xdb);
        try out.writeAll(&toBE(u32, @intCast(len)));
    }
}

fn writeBinHeader(out: *compat.Io.Writer, len: usize) !void {
    if (len <= 0xff) {
        try out.writeByte(0xc4);
        try out.writeByte(@intCast(len));
    } else if (len <= 0xffff) {
        try out.writeByte(0xc5);
        try out.writeAll(&toBE(u16, @intCast(len)));
    } else {
        try out.writeByte(0xc6);
        try out.writeAll(&toBE(u32, @intCast(len)));
    }
}

fn writeMapHeader(out: *compat.Io.Writer, count: u32) !void {
    if (count <= 15) {
        try out.writeByte(@as(u8, 0x80) | @as(u8, @intCast(count)));
    } else if (count <= 0xffff) {
        try out.writeByte(0xde);
        try out.writeAll(&toBE(u16, @intCast(count)));
    } else {
        try out.writeByte(0xdf);
        try out.writeAll(&toBE(u32, count));
    }
}

fn writeArrayHeader(out: *compat.Io.Writer, count: u32) !void {
    if (count <= 15) {
        try out.writeByte(@as(u8, 0x90) | @as(u8, @intCast(count)));
    } else if (count <= 0xffff) {
        try out.writeByte(0xdc);
        try out.writeAll(&toBE(u16, @intCast(count)));
    } else {
        try out.writeByte(0xdd);
        try out.writeAll(&toBE(u32, count));
    }
}

fn toBE(comptime T: type, v: T) [@sizeOf(T)]u8 {
    return @bitCast(std.mem.nativeTo(T, v, .big));
}

// Tests.

const testing = std.testing;

fn serializeToBytes(value: anytype) ![]u8 {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, testing.allocator);
    try core_serialize.serialize(@TypeOf(value), value, &ser, .{});
    return aw.toOwnedSlice();
}

test "serialize bool" {
    const t = try serializeToBytes(true);
    defer testing.allocator.free(t);
    try testing.expectEqualSlices(u8, &.{0xc3}, t);

    const f = try serializeToBytes(false);
    defer testing.allocator.free(f);
    try testing.expectEqualSlices(u8, &.{0xc2}, f);
}

test "serialize positive fixint" {
    const out = try serializeToBytes(@as(u8, 42));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{42}, out);
}

test "serialize zero" {
    const out = try serializeToBytes(@as(u8, 0));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{0x00}, out);
}

test "serialize uint8" {
    const out = try serializeToBytes(@as(u8, 200));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0xcc, 200 }, out);
}

test "serialize uint16" {
    const out = try serializeToBytes(@as(u16, 0x1234));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0xcd, 0x12, 0x34 }, out);
}

test "serialize uint32" {
    const out = try serializeToBytes(@as(u32, 0x12345678));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0xce, 0x12, 0x34, 0x56, 0x78 }, out);
}

test "serialize uint64" {
    const out = try serializeToBytes(@as(u64, 0x123456789abcdef0));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0xcf, 0x12, 0x34, 0x56, 0x78, 0x9a, 0xbc, 0xde, 0xf0 }, out);
}

test "serialize negative fixint" {
    const out = try serializeToBytes(@as(i8, -1));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{0xff}, out);

    const out2 = try serializeToBytes(@as(i8, -32));
    defer testing.allocator.free(out2);
    try testing.expectEqualSlices(u8, &.{0xe0}, out2);
}

test "serialize int8" {
    const out = try serializeToBytes(@as(i8, -33));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0xd0, @as(u8, @bitCast(@as(i8, -33))) }, out);
}

test "serialize int16" {
    const out = try serializeToBytes(@as(i16, -200));
    defer testing.allocator.free(out);
    const expected = toBE(u16, @bitCast(@as(i16, -200)));
    try testing.expectEqualSlices(u8, &(.{0xd1} ++ expected), out);
}

test "serialize positive signed int uses uint encoding" {
    const out = try serializeToBytes(@as(i32, 42));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{42}, out);
}

test "serialize float32" {
    const out = try serializeToBytes(@as(f32, 1.5));
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u8, 0xca), out[0]);
    try testing.expectEqual(@as(usize, 5), out.len);
}

test "serialize float64" {
    const out = try serializeToBytes(@as(f64, 3.14));
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u8, 0xcb), out[0]);
    try testing.expectEqual(@as(usize, 9), out.len);
}

test "serialize null" {
    const out = try serializeToBytes(@as(?i32, null));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{0xc0}, out);
}

test "serialize void" {
    const out = try serializeToBytes({});
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{0xc0}, out);
}

test "serialize fixstr" {
    const out = try serializeToBytes(@as([]const u8, "hi"));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0xa2, 'h', 'i' }, out);
}

test "serialize empty string" {
    const out = try serializeToBytes(@as([]const u8, ""));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{0xa0}, out);
}

test "serialize struct" {
    const Point = struct { x: i32, y: i32 };
    const out = try serializeToBytes(Point{ .x = 1, .y = 2 });
    defer testing.allocator.free(out);
    // fixmap with 2 entries
    try testing.expectEqual(@as(u8, 0x82), out[0]);
}

test "serialize array" {
    const out = try serializeToBytes([3]u8{ 1, 2, 3 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x93, 1, 2, 3 }, out);
}

test "serialize enum" {
    const Color = enum { red, green, blue };
    const out = try serializeToBytes(Color.green);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u8, 0xa0 | 5), out[0]);
    try testing.expectEqualStrings("green", out[1..6]);
}

test "serialize union void variant" {
    const Cmd = union(enum) { ping: void, quit: void };
    const out = try serializeToBytes(Cmd.ping);
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(u8, 0xa0 | 4), out[0]);
    try testing.expectEqualStrings("ping", out[1..5]);
}

test "serialize bytes bin8" {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, testing.allocator);
    try ser.serializeBytes("hello");
    const out = aw.toOwnedSlice() catch unreachable;
    defer testing.allocator.free(out);
    // bin8 header: 0xc4, length 5, then "hello"
    try testing.expectEqualSlices(u8, &.{ 0xc4, 5, 'h', 'e', 'l', 'l', 'o' }, out);
}

test "serialize bytes empty" {
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    var ser = Serializer.init(&aw.writer, testing.allocator);
    try ser.serializeBytes("");
    const out = aw.toOwnedSlice() catch unreachable;
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0xc4, 0 }, out);
}

// The buffered containers are no longer reached through the core encoder,
// which always knows the length of Zig's own aggregates. They stay part of the
// public interface for custom `zerdeSerialize` implementations, so exercise
// them directly.

const CustomSeq = struct {
    items: []const i32,

    pub fn zerdeSerialize(self: @This(), serializer: anytype) !void {
        var arr = try serializer.beginArray();
        for (self.items) |v| try arr.serializeInt(v);
        try arr.end();
    }
};

const CustomNested = struct {
    pub fn zerdeSerialize(_: @This(), serializer: anytype) !void {
        var arr = try serializer.beginArray();
        var inner = try arr.beginStruct();
        try inner.serializeEntry(@as([]const u8, "k"), @as(u8, 1));
        try inner.end();
        var deep = try arr.beginArray();
        try deep.serializeBool(true);
        try deep.end();
        try arr.serializeNull();
        try arr.end();
    }
};

test "buffered array serializer via custom serializer" {
    const out = try serializeToBytes(CustomSeq{ .items = &.{ 1, 2, 3 } });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x93, 1, 2, 3 }, out);
}

test "buffered array serializer counts nested containers" {
    const out = try serializeToBytes(CustomNested{});
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x93, 0x81, 0xa1, 'k', 1, 0x91, 0xc3, 0xc0 }, out);
}

test "buffered array serializer inside a known-length container" {
    const Doc = struct { seq: CustomSeq, tail: u8 };
    const out = try serializeToBytes(Doc{ .seq = .{ .items = &.{ 7, 8 } }, .tail = 9 });
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{
        0x82, 0xa3, 's', 'e', 'q', 0x92, 7, 8,
        0xa4, 't',  'a', 'i', 'l', 9,
    }, out);
}

test "buffered array serializer as a known-length array element" {
    const out = try serializeToBytes(@as([]const CustomSeq, &.{
        .{ .items = &.{1} },
        .{ .items = &.{ 2, 3 } },
    }));
    defer testing.allocator.free(out);
    try testing.expectEqualSlices(u8, &.{ 0x92, 0x91, 1, 0x92, 2, 3 }, out);
}

test "beginArrayLen rejects counts beyond a u32 header" {
    if (@sizeOf(usize) <= 4) return error.SkipZigTest;
    var aw: compat.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var ser = Serializer.init(&aw.writer, testing.allocator);
    try testing.expectError(error.LengthOverflow, ser.beginArrayLen(@as(usize, std.math.maxInt(u32)) + 1));
    try testing.expectError(error.LengthOverflow, ser.beginStructLen(@as(usize, std.math.maxInt(u32)) + 1));
}

test "serialize union with payload" {
    const Cmd = union(enum) { set: i32, ping: void };
    const out = try serializeToBytes(Cmd{ .set = 42 });
    defer testing.allocator.free(out);
    // External tagging: fixmap(1) + "set" + 42
    try testing.expectEqual(@as(u8, 0x81), out[0]);
}
