const std = @import("std");
pub const sets = @import("sets.zig");

fn bytesNeeded(comptime T: type, value: T) u8 {
    return switch (@typeInfo(T)) {
        .Int => |info| {
            if (info.signedness == .signed and value < 0) {
                return @intCast(@sizeOf(i64));
            } else {
                const U = std.meta.Int(.unsigned, info.bits);
                const x = @as(U, @intCast(value));
                const bits = std.math.log2_int_ceil(U, x);
                return @intCast((bits + 7) / 8);
            }
        },
        .Float => return @sizeOf(f64),
        else => @compileError("Unsupported type for bytesNeeded"),
    };
}

pub const LengthSize = enum(u2) {
    u8,
    u16,
    u32,
    u64,

    pub fn from_value(value: anytype) !LengthSize {
        if (@typeInfo(@TypeOf(value)) != .Int) return error.InvalidType;
        switch (value) {
            0...255 => return .u8,
            256...65535 => return .u16,
            65536...4294967295 => return .u32,
            4294967296...18446744073709551615 => return .u64,
        }
    }

    fn size(ls: LengthSize) usize {
        return @as(usize, 1) << @intFromEnum(ls);
    }
};

pub const Tag = enum(u4) {
    bool,
    int,
    float,
    str,
    array,
    map,
    null,
};

pub const ArrayMetadata = enum(u2) {
    array,
    set,
    uset,
};

pub const ZBucket = []const u8;

pub const ZWriter = struct {
    writer: std.io.AnyWriter,

    pub fn init(writer: std.io.AnyWriter) ZWriter {
        return .{
            .writer = writer,
        };
    }

    pub fn write(zw: ZWriter, value: ZType) anyerror!usize {
        switch (value) {
            .str => |str| {
                return try zw.write_str(str);
            },
            .bool => |b| {
                return try zw.write_bool(b);
            },
            .int => |i| {
                return try zw.write_int(i);
            },
            .float => |f| {
                return try zw.write_float(f);
            },
            .array => |arr| {
                return try zw.write_array(arr.items);
            },
            .map => |map| {
                return try zw.write_map(map);
            },
            .set => |set| {
                return try zw.write_set(set);
            },
            .uset => |uset| {
                return try zw.write_uset(uset);
            },
            .null => {
                return try zw.write_null();
            },
            else => unreachable,
        }
    }

    fn write_null(zw: ZWriter) !usize {
        try zw.writer.writeByte(@intFromEnum(Tag.null));
        return 1;
    }

    fn write_uset(zw: ZWriter, s: sets.SetUnordered(ZType)) !usize {
        const n_elements = s.count();
        const length_size_enum = try LengthSize.from_value(n_elements);
        const length_size = length_size_enum.size();
        var total_size = 1 + length_size;

        const size_bytes = std.mem.asBytes(&n_elements);

        _ = try zw.writer.writeByte(@intFromEnum(Tag.array) | @as(u8, @intFromEnum(length_size_enum)) << 4 | @as(u8, @intFromEnum(ArrayMetadata.uset)) << 6);
        _ = try zw.writer.write(size_bytes[0..length_size]);

        var it = s.iterator();
        while (it.next()) |e| {
            total_size += try zw.write(e.*);
        }

        return total_size;
    }

    fn write_set(zw: ZWriter, s: sets.Set(ZType)) !usize {
        const n_elements = s.count();
        const length_size_enum = try LengthSize.from_value(n_elements);
        const length_size = length_size_enum.size();
        var total_size = 1 + length_size;

        const size_bytes = std.mem.asBytes(&n_elements);

        _ = try zw.writer.writeByte(@intFromEnum(Tag.array) | @as(u8, @intFromEnum(length_size_enum)) << 4 | @as(u8, @intFromEnum(ArrayMetadata.set)) << 6);
        _ = try zw.writer.write(size_bytes[0..length_size]);

        var it = s.iterator();
        while (it.next()) |e| {
            total_size += try zw.write(e.key_ptr.*);
        }

        return total_size;
    }

    fn write_array(zw: ZWriter, arr: []ZType) !usize {
        const n_elements = arr.len;
        const length_size_enum = try LengthSize.from_value(n_elements);
        const length_size = length_size_enum.size();
        var total_size = 1 + length_size;

        const size_bytes = std.mem.asBytes(&n_elements);

        _ = try zw.writer.writeByte(@intFromEnum(Tag.array) | @as(u8, @intFromEnum(length_size_enum)) << 4 | @as(u8, @intFromEnum(ArrayMetadata.array)) << 6);
        _ = try zw.writer.write(size_bytes[0..length_size]);

        for (arr) |elem| {
            total_size += try zw.write(elem);
        }
        return total_size;
    }

    fn write_map(zw: ZWriter, value: std.StringHashMap(ZType)) !usize {
        const n_elements: u64 = @intCast(value.count());
        const length_size_enum = try LengthSize.from_value(n_elements);
        const length_size = length_size_enum.size();

        var total_size = 1 + length_size;
        const size_bytes = std.mem.asBytes(&n_elements);

        _ = try zw.writer.writeByte(@intFromEnum(Tag.map) | @as(u8, @intFromEnum(length_size_enum)) << 4);
        _ = try zw.writer.write(size_bytes[0..length_size]);

        var it = value.iterator();

        while (it.next()) |entry| {
            total_size += try zw.write_str(entry.key_ptr.*);
            total_size += try zw.write(entry.value_ptr.*);
        }

        return total_size;
    }

    fn write_int(zw: ZWriter, value: i64) !usize {
        const bytes_needed = bytesNeeded(i64, value);
        const as_bytes = std.mem.asBytes(&value);
        _ = try zw.writer.writeByte(@intFromEnum(Tag.int) | @as(u8, bytes_needed) << 4);
        _ = try zw.writer.write(as_bytes[0..bytes_needed]);

        return bytes_needed + 1;
    }

    fn write_float(zw: ZWriter, value: f64) !usize {
        const bytes_needed = bytesNeeded(f64, value);
        const as_bytes = std.mem.asBytes(&value);
        _ = try zw.writer.writeByte(@intFromEnum(Tag.float) | @as(u8, bytes_needed) << 4);
        _ = try zw.writer.write(as_bytes[0..bytes_needed]);

        return bytes_needed + 1;
    }

    fn write_str(zw: ZWriter, str: []const u8) !usize {
        const length_size_enum = try LengthSize.from_value(str.len);
        try zw.writer.writeByte(@as(u8, @intFromEnum(Tag.str)) | @as(u8, @intFromEnum(length_size_enum)) << 4);
        const str_len_as_bytes = std.mem.asBytes(&str.len);
        const length_size = length_size_enum.size();
        _ = try zw.writer.write(str_len_as_bytes[0..length_size]);
        const size = try zw.writer.write(str);
        return length_size + size + 1;
    }

    fn write_bool(
        zw: ZWriter,
        value: bool,
    ) !usize {
        try zw.writer.writeByte(@intFromEnum(Tag.bool) | @as(u8, @intFromBool(value)) << 4);
        return 1;
    }
};

pub const ZReader = struct {
    reader: std.io.AnyReader,

    pub fn init(reader: std.io.AnyReader) ZReader {
        return .{ .reader = reader };
    }

    pub fn read(zr: ZReader, out: *ZType, allocator: std.mem.Allocator) !usize {
        var size: usize = 1;
        const byte = try zr.reader.readByte();
        const tag = get_tag(byte);

        switch (tag) {
            .bool => {
                out.* = .{
                    .bool = (byte & 0b11111000) != 0,
                };
            },
            .null => {
                out.* = .{
                    .null = {},
                };
            },
            .int => {
                const bytes_len = @as(usize, byte >> 4);
                const value = try zr.reader.readVarInt(i64, .little, bytes_len);
                size += bytes_len;
                out.* = .{
                    .int = value,
                };
            },
            .float => {
                const bytes_len = @as(usize, byte >> 4);
                var value: [@sizeOf(f64)]u8 = undefined;
                size += try zr.reader.read(value[0..bytes_len]);
                out.* = .{
                    .float = @bitCast(value),
                };
            },
            .str => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> 4));
                const length_size = length_size_enum.size();

                const n_elements = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;
                const str = try allocator.alloc(u8, n_elements);

                size += try zr.reader.read(str);

                out.* = .{
                    .str = str,
                };
            },
            .array => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> 4));
                const length_size = length_size_enum.size();

                const array_metadata: ArrayMetadata = @enumFromInt(@as(u8, byte >> 6));

                const n_elements = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;
                switch (array_metadata) {
                    .array => {
                        var arr = try std.ArrayList(ZType).initCapacity(allocator, n_elements);

                        for (0..n_elements) |_| {
                            var elem: ZType = undefined;
                            size += try zr.read(&elem, allocator);
                            try arr.append(elem);
                        }

                        out.* = .{
                            .array = arr,
                        };
                    },
                    .set => {
                        var set = sets.Set(ZType).init(allocator);

                        for (0..n_elements) |_| {
                            var elem: ZType = undefined;
                            size += try zr.read(&elem, allocator);
                            try set.insert(elem);
                        }

                        out.* = .{
                            .set = set,
                        };
                    },
                    .uset => {
                        var uset = sets.SetUnordered(ZType).init(allocator);

                        for (0..n_elements) |_| {
                            var elem: ZType = undefined;
                            size += try zr.read(&elem, allocator);
                            try uset.insert(elem);
                        }

                        out.* = .{
                            .uset = uset,
                        };
                    },
                }
            },
            .map => {
                const length_size_enum: LengthSize = @enumFromInt(@as(u8, byte >> 4));
                const length_size = length_size_enum.size();

                const n_elements = try zr.reader.readVarInt(usize, .little, length_size);
                size += length_size;
                var map = std.StringHashMap(ZType).init(allocator);

                for (0..n_elements) |_| {
                    // var elem: ZType = undefined;
                    // size += try zr.read(&elem, allocator);
                    // try arr.append(elem);
                    var key: ZType = undefined;
                    var value: ZType = undefined;
                    size += try zr.read(&key, allocator);
                    size += try zr.read(&value, allocator);
                    try map.put(key.str, value);
                }

                out.* = .{
                    .map = map,
                };
            },
        }

        return size;
    }

    fn get_tag(tag_byte: u8) Tag {
        return @enumFromInt(tag_byte & 0b1111);
    }
};

pub const ClientError = struct {
    message: []const u8,
};

pub const ZType = union(enum) {
    str: []const u8,
    int: i64,
    float: f64,
    map: map,
    bool: bool,
    array: array,
    null: void,
    set: set,
    uset: uset,
    // ClientError only for compatibility with ProtocolHandler
    // and it will not be stored in Memory but will be returned
    err: ClientError,

    pub const array = std.ArrayList(ZType);
    pub const map = std.StringHashMap(ZType);
    pub const set = sets.Set(ZType);
    pub const uset = sets.SetUnordered(ZType);
};

pub fn ztype_free(value: *ZType, allocator: std.mem.Allocator) void {
    switch (value.*) {
        .str => |str| allocator.free(str),
        .int, .float, .bool, .null => return,
        .array => |array| {
            defer array.deinit();

            for (array.items) |item| ztype_free(
                @constCast(&item),
                allocator,
            );
        },
        .map => |v| {
            defer @constCast(&v).deinit();

            var iter = v.iterator();
            while (iter.next()) |item| {
                var zkey: ZType = .{ .str = @constCast(item.key_ptr.*) };
                var zvalue: ZType = item.value_ptr.*;

                ztype_free(&zkey, allocator);
                ztype_free(&zvalue, allocator);
            }
        },
        inline .set, .uset => |v, tag| {
            defer @constCast(&v).deinit();

            var iter = v.iterator();
            while (iter.next()) |item| {
                const value_ptr = switch (tag) {
                    .set => item.key_ptr,
                    .uset => item,
                    else => @compileError("not supported tag"),
                };
                ztype_free(
                    value_ptr,
                    allocator,
                );
            }
        },
        else => unreachable,
    }
}

const testing = std.testing;

test "writer/reader int value" {
    const allocator = testing.allocator;
    const z_value = ZType{ .int = 10 };

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    const zwriter = ZWriter.init(data.writer().any());

    _ = try zwriter.write(z_value);

    var fbs = std.io.fixedBufferStream(data.items);
    const zreader = ZReader.init(fbs.reader().any());

    var z_value_out: ZType = undefined;
    const bytes_read = try zreader.read(&z_value_out, allocator);

    try testing.expect(bytes_read == data.items.len);
    try testing.expectEqualDeep(z_value, z_value_out);
}

test "writer/reader float value" {
    const allocator = testing.allocator;
    const z_value = ZType{ .float = -1201.01281890 };

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    const zwriter = ZWriter.init(data.writer().any());

    _ = try zwriter.write(z_value);

    var fbs = std.io.fixedBufferStream(data.items);
    const zreader = ZReader.init(fbs.reader().any());

    var z_value_out: ZType = undefined;
    const bytes_read = try zreader.read(&z_value_out, allocator);

    try testing.expect(bytes_read == data.items.len);
    try testing.expectEqualDeep(z_value, z_value_out);
}

test "writer/reader bool value" {
    const allocator = testing.allocator;
    const z_value = ZType{ .bool = true };

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    const zwriter = ZWriter.init(data.writer().any());

    _ = try zwriter.write(z_value);

    var fbs = std.io.fixedBufferStream(data.items);
    const zreader = ZReader.init(fbs.reader().any());

    var z_value_out: ZType = undefined;
    const bytes_read = try zreader.read(&z_value_out, allocator);

    try testing.expect(bytes_read == data.items.len);
    try testing.expectEqualDeep(z_value, z_value_out);
}

test "writer/reader null value" {
    const allocator = testing.allocator;
    const z_value = ZType{ .null = {} };

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    const zwriter = ZWriter.init(data.writer().any());

    _ = try zwriter.write(z_value);

    var fbs = std.io.fixedBufferStream(data.items);
    const zreader = ZReader.init(fbs.reader().any());

    var z_value_out: ZType = undefined;
    const bytes_read = try zreader.read(&z_value_out, allocator);

    try testing.expect(bytes_read == data.items.len);
    try testing.expectEqualDeep(z_value, z_value_out);
}

test "writer/reader array value" {
    const allocator = testing.allocator;
    var arr = try std.ArrayList(ZType).initCapacity(allocator, 3);
    defer arr.deinit();
    try arr.appendSlice(
        &[_]ZType{
            .{ .int = 10 },
            .{ .bool = false },
            .{ .str = "false" },
        },
    );
    const z_value = ZType{
        .array = arr,
    };

    var data = std.ArrayList(u8).init(allocator);
    defer data.deinit();
    const zwriter = ZWriter.init(data.writer().any());

    _ = try zwriter.write(z_value);

    var fbs = std.io.fixedBufferStream(data.items);
    const zreader = ZReader.init(fbs.reader().any());

    var z_value_out: ZType = undefined;
    const bytes_read = try zreader.read(&z_value_out, allocator);
    defer ztype_free(&z_value_out, allocator);

    try testing.expect(bytes_read == data.items.len);
    try testing.expectEqualDeep(z_value, z_value_out);
}
