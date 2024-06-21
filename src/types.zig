const std = @import("std");

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
            i64 => {
                const bytes = std.mem.asBytes(&value);
                const n_bytes = @sizeOf(i64);
                var data = try allocator.alloc(u8, n_bytes + 1);
                data[0] = @as(u8, @intFromEnum(Tag.int)) | (@as(u8, n_bytes) << 3);
                @memcpy(data[1..], bytes);
                return ZType{ .data = data };
            },
            f64 => {
                const bytes = std.mem.asBytes(&value);
                const n_bytes = @sizeOf(f64);
                var data = try allocator.alloc(u8, n_bytes + 1);
                data[0] = @as(u8, @intFromEnum(Tag.float)) | (@as(u8, n_bytes) << 3);
                @memcpy(data[1..], bytes);

                return ZType{ .data = data };
            },
            []ZType => {
                const n_elements = value.len;
                var total_size: usize = 1 + @sizeOf(usize); // 1 byte for the tag, usize for length
                for (value) |elem| {
                    total_size += elem.data.len;
                }
                var data = try allocator.alloc(u8, total_size);
                data[0] = @as(u8, @intFromEnum(Tag.array));
                std.mem.writeInt(usize, data[1 .. 1 + @sizeOf(usize)], n_elements, .little);
                var offset: usize = 1 + @sizeOf(usize);
                for (value) |elem| {
                    @memcpy(data[offset..][0..elem.data.len], elem.data);
                    offset += elem.data.len;
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
        return (self.data[0] & 0b00011111) != 0;
    }

    pub fn getInt(self: ZType) !i64 {
        if (self.getTag() != .int) return error.TypeMismatch;
        return std.mem.readVarInt(i64, self.data[1..], .little);
    }
    pub fn getArray(self: ZType, allocator: std.mem.Allocator) ![]ZType {
        if (self.getTag() != .array) return error.TypeMismatch;
        const n_elements = std.mem.readInt(usize, self.data[1 .. 1 + @sizeOf(usize)], .little);
        var result = try allocator.alloc(ZType, n_elements);
        var offset: usize = 1 + @sizeOf(usize);
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
                        };
                        sub_offset += len;
                    }
                    break :blk len;
                },
            };
            result[i] = ZType{ .data = self.data[offset..][0..elem_len] };
            offset += elem_len;
        }
        return result;
    }

    pub fn getFloat(self: ZType) !f64 {
        if (self.getTag() != .float) return error.TypeMismatch;
        var float_bytes: [@sizeOf(f64)]u8 = undefined;
        @memcpy(&float_bytes, self.data[1..]);
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
            };
            const value = ZType{ .data = self.data[offset..][0..value_len] };
            try result.put(try allocator.dupe(u8, key), value);
            offset += value_len;
        }
        return result;
    }
};
