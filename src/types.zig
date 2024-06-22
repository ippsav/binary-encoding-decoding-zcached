const std = @import("std");

fn bytesNeeded(comptime T: type, value: T) u8 {
    return switch (@typeInfo(T)) {
        .Int => |info| {
            const U = std.meta.Int(.unsigned, info.bits);
            const x = if (info.signedness == .unsigned) value else @as(U, @intCast(@abs(value)));
            const bits = std.math.log2_int_ceil(U, x);
            return @intCast((bits + 8) / 8);
        },
        .Float => {
            std.debug.assert(T == f64);
            const abs_value: f64 = @abs(value);
            const f32_value: f32 = @floatCast(abs_value);

            if (abs_value == f32_value) return 4 else return 8;
        },
        else => @compileError("Unsupported type for bytesNeeded"),
    };
}

pub const ZType = struct {
    data: []u8,

    pub const Tag = enum(u3) {
        bool,
        int,
        float,
        array,
        map,
    };

    pub fn init(allocator: std.mem.Allocator, value: anytype) !ZType {
        switch (@TypeOf(value)) {
            bool => {
                var data = try allocator.alloc(u8, 1);
                data[0] = @as(u8, @intFromEnum(Tag.bool)) | (@as(u8, @intFromBool(value)) << 3);
                return ZType{ .data = data };
            },
            i64, f64 => {
                const T = @TypeOf(value);
                const bytes_needed = bytesNeeded(T, value);
                const as_bytes = std.mem.asBytes(&value);
                var data = try allocator.alloc(u8, bytes_needed + 1);
                data[0] = switch (T) {
                    f64 => @as(u8, @intFromEnum(Tag.float)),
                    i64 => @as(u8, @intFromEnum(Tag.int)),
                    else => unreachable,
                };
                data[0] |= (@as(u8, bytes_needed) << 3);
                // std.mem.writeInt(T, data[1 .. bytes_needed + 1], value, .little);
                @memcpy(data[1 .. bytes_needed + 1], as_bytes[0..bytes_needed]);

                return ZType{ .data = data };
            },
            []ZType, []const ZType => {
                const n_elements = value.len;
                var total_size: usize = 1;
                if (n_elements >= 32) {
                    total_size += 4; // 4 extra bytes for length if n_elements >= 32
                }
                for (value) |elem| {
                    total_size += elem.data.len;
                }
                var data = try allocator.alloc(u8, total_size);
                data[0] = @as(u8, @intFromEnum(Tag.array));

                if (n_elements < 32) {
                    // If n_elements fits in 5 bits, encode it directly in the first byte
                    data[0] |= @as(u8, @intCast(n_elements)) << 3;
                    var offset: usize = 1;
                    for (value) |elem| {
                        @memcpy(data[offset..][0..elem.data.len], elem.data);
                        offset += elem.data.len;
                    }
                } else {
                    // Otherwise, set the 5 bits to all 1s and use 4 bytes for length
                    data[0] |= 0b11111000;
                    std.mem.writeInt(u32, data[1..5], @intCast(n_elements), .little);
                    var offset: usize = 5;
                    for (value) |elem| {
                        @memcpy(data[offset..][0..elem.data.len], elem.data);
                        offset += elem.data.len;
                    }
                }
                return ZType{ .data = data };
            },
            std.StringHashMap(ZType) => {
                const n_elements = value.count();
                var total_size: usize = 1 + @sizeOf(usize); // 1 byte for tag, usize for element count
                var it = value.iterator();
                while (it.next()) |entry| {
                    total_size += @sizeOf(u16) + entry.key_ptr.len + entry.value_ptr.data.len;
                }
                var data = try allocator.alloc(u8, total_size);
                data[0] = @as(u8, @intFromEnum(Tag.map));
                std.mem.writeInt(usize, data[1 .. 1 + @sizeOf(usize)], n_elements, .little);
                var offset: usize = 1 + @sizeOf(usize);
                it = value.iterator();
                while (it.next()) |entry| {
                    std.mem.writeInt(u16, data[offset..][0..2], @intCast(entry.key_ptr.len), .little);
                    offset += 2;
                    @memcpy(data[offset..][0..entry.key_ptr.len], entry.key_ptr.*);
                    offset += entry.key_ptr.len;
                    @memcpy(data[offset..][0..entry.value_ptr.data.len], entry.value_ptr.data);
                    offset += entry.value_ptr.data.len;
                }
                return ZType{ .data = data };
            },
            else => @compileError("Unsupported type"),
        }
    }

    pub fn deinit(self: *ZType, allocator: std.mem.Allocator) void {
        allocator.free(self.data);
    }

    pub fn getTag(self: ZType) Tag {
        return @enumFromInt(self.data[0] & 0b111);
    }

    pub fn getBool(self: ZType) !bool {
        if (self.getTag() != .bool) return error.TypeMismatch;
        return (self.data[0] & 0b11111000) != 0;
    }

    pub fn getInt(self: ZType) !i64 {
        if (self.getTag() != .int) return error.TypeMismatch;
        const bytes_len = @as(usize, self.data[0] >> 3);

        return std.mem.readVarInt(i64, self.data[1..][0..bytes_len], .little);
    }

    pub fn getArray(self: ZType, allocator: std.mem.Allocator) ![]ZType {
        if (self.getTag() != .array) return error.TypeMismatch;
        const first_byte = self.data[0];
        const encoded_length = (first_byte >> 3) & 0b11111;
        var n_elements: usize = undefined;
        var offset: usize = undefined;
        if (encoded_length == 0b11111) {
            // Length is stored in the next 4 bytes
            n_elements = std.mem.readInt(u32, self.data[1..5], .little);
            offset = 5;
        } else {
            // Length is directly encoded in the first byte
            n_elements = encoded_length;
            offset = 1;
        }
        var result = try allocator.alloc(ZType, n_elements);
        for (0..n_elements) |i| {
            const elem_tag = @as(Tag, @enumFromInt(self.data[offset] & 0b111));
            const elem_len = switch (elem_tag) {
                .bool => 1,
                .int, .float => (self.data[offset] >> 3) + 1,
                .array => blk: {
                    const sub_n_elements = std.mem.readVarInt(usize, self.data[offset + 1 .. offset + 1 + @sizeOf(usize)], .little);
                    var len: usize = 1 + @sizeOf(usize);
                    var sub_offset = offset + 1 + @sizeOf(usize);
                    for (0..sub_n_elements) |_| {
                        const sub_elem_tag = @as(Tag, @enumFromInt(self.data[sub_offset] & 0b111));
                        len += switch (sub_elem_tag) {
                            .bool => 1,
                            .int, .float => (self.data[sub_offset] >> 3) + 1,
                            .array => unreachable, // Nested arrays not supported in this example
                            else => unreachable,
                        };
                        sub_offset += len;
                    }
                    break :blk len;
                },
                else => unreachable,
            };
            result[i] = ZType{ .data = self.data[offset..][0..elem_len] };
            offset += elem_len;
        }
        return result;
    }

    pub fn getFloat(self: ZType) !f64 {
        if (self.getTag() != .float) return error.TypeMismatch;
        var float_bytes: [@sizeOf(f64)]u8 = undefined;
        const bytes_len: u8 = self.data[0] >> 3;
        @memcpy(&float_bytes, self.data[1 .. bytes_len + 1]);
        return @bitCast(float_bytes);
    }

    pub fn getMap(self: ZType, allocator: std.mem.Allocator) !std.StringHashMap(ZType) {
        if (self.getTag() != .map) return error.TypeMismatch;
        const n_elements = std.mem.readVarInt(usize, self.data[1 .. 1 + @sizeOf(usize)], .little);
        var result = std.StringHashMap(ZType).init(allocator);
        var offset: usize = 1 + @sizeOf(usize);
        for (0..n_elements) |_| {
            const key_len = std.mem.readVarInt(u16, self.data[offset..][0..2], .little);
            offset += 2;
            const key = self.data[offset..][0..key_len];
            offset += key_len;
            const value_tag = @as(Tag, @enumFromInt(self.data[offset] & 0b111));
            const value_len = switch (value_tag) {
                .bool => 1,
                .int, .float => (self.data[offset] >> 3) + 1,
                .array, .map => blk: {
                    var len: usize = 1 + @sizeOf(usize);
                    const sub_n_elements = std.mem.readVarInt(usize, self.data[offset + 1 .. offset + 1 + @sizeOf(usize)], .little);
                    var sub_offset = offset + 1 + @sizeOf(usize);
                    for (0..sub_n_elements) |_| {
                        const sub_elem_tag = @as(Tag, @enumFromInt(self.data[sub_offset] & 0b111));
                        len += switch (sub_elem_tag) {
                            .bool => 1,
                            .int, .float => (self.data[sub_offset] >> 3) + 1,
                            .array, .map => unreachable, // Nested arrays/maps not fully supported in this example
                        };
                        sub_offset += len;
                    }
                    break :blk len;
                },
                else => unreachable,
            };
            const value = ZType{ .data = self.data[offset..][0..value_len] };
            try result.put(try allocator.dupe(u8, key), value);
            offset += value_len;
        }
        return result;
    }
};
