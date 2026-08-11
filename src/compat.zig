const std = @import("std");
const builtin = @import("builtin");

comptime {
    const v = builtin.zig_version;
    if (!(v.major == 0 and v.minor == 15 and v.patch >= 2)) {
        @compileError("src/compat.zig requires Zig 0.15.2");
    }
}

pub const Io = std.io;
pub const File = std.fs.File;
pub const Reader = Io.Reader;
pub const Writer = Io.Writer;
pub const Limit = Io.Limit;
pub const AllocatingWriter = Writer.Allocating;
pub const ArrayList = std.ArrayList;
pub const ArrayListUnmanaged = std.ArrayListUnmanaged;
pub const StringHashMap = std.StringHashMap;

pub fn StringArrayHashMap(comptime V: type) type {
    return std.StringArrayHashMapUnmanaged(V);
}

pub fn staticBitSetEmpty(comptime size: usize) std.StaticBitSet(size) {
    const BitSet = std.StaticBitSet(size);
    if (@hasDecl(BitSet, "empty")) return BitSet.empty;
    return BitSet.initEmpty();
}

pub fn intToEnum(comptime T: type, value: anytype) ?T {
    return std.meta.intToEnum(T, value) catch null;
}

pub fn intType(comptime signedness: std.builtin.Signedness, comptime bits: u16) type {
    return std.meta.Int(signedness, bits);
}

pub fn trimEnd(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    return std.mem.trimRight(T, slice, values_to_strip);
}

pub fn openFileForRead(path: []const u8) !File {
    return std.fs.cwd().openFile(path, .{});
}

pub fn closeFile(file: File) void {
    file.close();
}

pub fn writeFile(path: []const u8, data: []const u8) !void {
    try std.fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

pub fn writeStdout(data: []const u8) !void {
    try std.fs.File.stdout().writeAll(data);
}

pub fn deleteFile(path: []const u8) !void {
    try std.fs.cwd().deleteFile(path);
}

pub fn fileReaderStreaming(file: File, buffer: []u8) @TypeOf(file.readerStreaming(buffer)) {
    return file.readerStreaming(buffer);
}

pub fn readerAllocRemaining(reader: anytype, allocator: std.mem.Allocator, limit: Limit) ![]u8 {
    return reader.interface.allocRemaining(allocator, limit);
}

pub fn readFileAlloc(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ![]u8 {
    const file = try openFileForRead(path);
    defer closeFile(file);

    var buffer: [4096]u8 = undefined;
    var reader = fileReaderStreaming(file, &buffer);
    return readerAllocRemaining(&reader, allocator, Limit.limited(max_bytes));
}

/// Version-stable zlib helpers used by ETF's COMPRESSED_EXT support.
///
/// Zig 0.15's std.compress has no flate encoder, so this file carries its own
/// DEFLATE implementation: level 0 emits stored blocks, levels 1-9 emit a
/// single fixed-Huffman block with an LZ77 match search whose effort grows
/// with the level. Newer compatibility layers use std's optimized encoder.
pub fn zlibCompress(allocator: std.mem.Allocator, input: []const u8, level: u4) ![]u8 {
    var aw: Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try aw.ensureTotalCapacity(64);
    try aw.writer.writeAll(&.{ 0x78, if (level == 0) 0x01 else 0x9c });
    if (level == 0) {
        var remaining = input;
        if (remaining.len == 0) try writeStoredBlock(&aw.writer, &.{}, true);
        while (remaining.len != 0) {
            const count = @min(remaining.len, std.math.maxInt(u16));
            try writeStoredBlock(&aw.writer, remaining[0..count], count == remaining.len);
            remaining = remaining[count..];
        }
    } else {
        try deflateFixed(allocator, &aw.writer, input, level);
    }
    var footer: [4]u8 = undefined;
    std.mem.writeInt(u32, &footer, adler32(input), .big);
    try aw.writer.writeAll(&footer);
    return aw.toOwnedSlice();
}

fn writeStoredBlock(writer: *Io.Writer, data: []const u8, final: bool) !void {
    try writer.writeByte(@intFromBool(final));
    var header: [4]u8 = undefined;
    const len: u16 = @intCast(data.len);
    std.mem.writeInt(u16, header[0..2], len, .little);
    std.mem.writeInt(u16, header[2..4], ~len, .little);
    try writer.writeAll(&header);
    try writer.writeAll(data);
}

const window_size = 32768;
const min_match = 3;
const max_match = 258;
const hash_bits = 15;

const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
const length_extra = [29]u4{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
const dist_extra = [30]u4{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

const BitWriter = struct {
    writer: *Io.Writer,
    accumulator: u64 = 0,
    count: u6 = 0,

    fn write(self: *BitWriter, value: u32, len: u6) !void {
        self.accumulator |= @as(u64, value) << self.count;
        self.count += len;
        while (self.count >= 8) {
            try self.writer.writeByte(@truncate(self.accumulator));
            self.accumulator >>= 8;
            self.count -= 8;
        }
    }

    /// Huffman codes are packed starting from the most significant bit.
    fn writeCode(self: *BitWriter, code: u32, len: u6) !void {
        const reversed = @bitReverse(@as(u16, @intCast(code))) >> @intCast(16 - len);
        try self.write(reversed, len);
    }

    fn flush(self: *BitWriter) !void {
        if (self.count > 0) try self.writer.writeByte(@truncate(self.accumulator));
        self.accumulator = 0;
        self.count = 0;
    }
};

fn writeFixedLiteral(bits: *BitWriter, literal: u8) !void {
    if (literal < 144) {
        try bits.writeCode(0x30 + @as(u32, literal), 8);
    } else {
        try bits.writeCode(0x190 + @as(u32, literal) - 144, 9);
    }
}

fn writeFixedMatch(bits: *BitWriter, length: usize, distance: usize) !void {
    var length_code: usize = length_base.len - 1;
    while (length_base[length_code] > length) length_code -= 1;
    const length_symbol = 257 + length_code;
    if (length_symbol < 280) {
        try bits.writeCode(@intCast(length_symbol - 256), 7);
    } else {
        try bits.writeCode(@intCast(0xc0 + length_symbol - 280), 8);
    }
    try bits.write(@intCast(length - length_base[length_code]), length_extra[length_code]);

    var dist_code: usize = dist_base.len - 1;
    while (dist_base[dist_code] > distance) dist_code -= 1;
    try bits.writeCode(@intCast(dist_code), 5);
    try bits.write(@intCast(distance - dist_base[dist_code]), dist_extra[dist_code]);
}

fn hashAt(input: []const u8, pos: usize) usize {
    const word = @as(u32, input[pos]) << 16 | @as(u32, input[pos + 1]) << 8 | input[pos + 2];
    return (word *% 0x9e3779b1) >> (32 - hash_bits);
}

fn matchLength(input: []const u8, candidate: usize, pos: usize, limit: usize) usize {
    var len: usize = 0;
    while (len < limit and input[candidate + len] == input[pos + len]) len += 1;
    return len;
}

/// One final DEFLATE block with fixed Huffman codes. `head` remembers the
/// most recent position of each 3-byte hash; `prev` chains earlier positions
/// within the window, probed `chain_limit` times per lookup.
fn deflateFixed(allocator: std.mem.Allocator, writer: *Io.Writer, input: []const u8, level: u4) !void {
    if (input.len >= std.math.maxInt(u32)) return error.InputTooLarge;
    const chain_limit: usize = switch (level) {
        0 => unreachable,
        1, 2 => 4,
        3, 4 => 16,
        5, 6 => 64,
        7, 8 => 256,
        else => 1024,
    };
    const head = try allocator.alloc(u32, 1 << hash_bits);
    defer allocator.free(head);
    @memset(head, 0);
    const prev = try allocator.alloc(u32, window_size);
    defer allocator.free(prev);
    @memset(prev, 0);

    var bits = BitWriter{ .writer = writer };
    try bits.write(1, 1); // BFINAL
    try bits.write(1, 2); // BTYPE: fixed Huffman

    var pos: usize = 0;
    while (pos < input.len) {
        if (pos + min_match > input.len) {
            try writeFixedLiteral(&bits, input[pos]);
            pos += 1;
            continue;
        }
        const limit = @min(input.len - pos, max_match);
        var best_len: usize = 0;
        var best_dist: usize = 0;
        const slot = hashAt(input, pos);
        var candidate = head[slot];
        var probes = chain_limit;
        while (candidate != 0 and probes != 0) : (probes -= 1) {
            const candidate_pos = candidate - 1;
            if (pos - candidate_pos > window_size) break;
            const len = matchLength(input, candidate_pos, pos, limit);
            if (len > best_len) {
                best_len = len;
                best_dist = pos - candidate_pos;
                if (len == limit) break;
            }
            candidate = prev[candidate_pos % window_size];
        }
        prev[pos % window_size] = head[slot];
        head[slot] = @intCast(pos + 1);
        if (best_len >= min_match) {
            try writeFixedMatch(&bits, best_len, best_dist);
            var inserted = pos + 1;
            const end = pos + best_len;
            while (inserted < end and inserted + min_match <= input.len) : (inserted += 1) {
                const inserted_slot = hashAt(input, inserted);
                prev[inserted % window_size] = head[inserted_slot];
                head[inserted_slot] = @intCast(inserted + 1);
            }
            pos = end;
        } else {
            try writeFixedLiteral(&bits, input[pos]);
            pos += 1;
        }
    }
    try bits.writeCode(0, 7); // end-of-block symbol 256
    try bits.flush();
}

fn adler32(data: []const u8) u32 {
    const modulus = 65521;
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % modulus;
        b = (b + a) % modulus;
    }
    return (b << 16) | a;
}

pub fn zlibDecompress(allocator: std.mem.Allocator, input: []const u8, expected_len: usize) ![]u8 {
    var source: Io.Reader = .fixed(input);
    var window: [std.compress.flate.max_window_len]u8 = undefined;
    var decompressor: std.compress.flate.Decompress = .init(&source, .zlib, &window);
    const limit = std.math.add(usize, expected_len, 1) catch return error.InvalidCompressedData;
    const output = try allocator.alloc(u8, limit);
    errdefer allocator.free(output);
    var sink: Io.Writer = .fixed(output);
    const actual = decompressor.reader.streamRemaining(&sink) catch return error.InvalidCompressedData;
    if (actual != expected_len or decompressor.err != null or source.seek != source.end) return error.InvalidCompressedData;
    const wire_adler = switch (decompressor.container_metadata) {
        // Zig 0.15's Decompress reads the big-endian adler32 footer as
        // little-endian; swap it back to the on-wire value.
        .zlib => |zlib| @byteSwap(zlib.adler),
        else => unreachable,
    };
    if (wire_adler != adler32(output[0..expected_len])) return error.InvalidCompressedData;
    return allocator.realloc(output, expected_len);
}
