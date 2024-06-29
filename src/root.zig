const std = @import("std");
const mem = std.mem;

pub const ZType = union(enum) {
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    slice: []ZType,
    const_slice: []const ZType,
    array: Array,
    map: Map,
    static_map: StaticMap,

    pub const Tag = std.meta.Tag(ZType);
    pub const TagInt = @typeInfo(Tag).Enum.tag_type;
    pub const Array = std.ArrayListUnmanaged(ZType);
    pub const Map = std.StringArrayHashMapUnmanaged(ZType);
    pub const StaticMap = std.StaticStringMap(ZType);
    pub const Kind = enum { scalar, array, map };

    comptime {
        // if this fails, some assumptions may need to be checked
        std.debug.assert(TagInt == u4);
        //@compileLog(@sizeOf(ZType));
    }

    pub fn deinit(zt: *ZType, allocator: mem.Allocator) void {
        switch (zt) {
            .array => |array| {
                for (array.items) |*ele| ele.deinit(allocator);
                array.deinit(allocator);
            },
            .slice => |slice| {
                for (slice) |*ele| ele.deinit(allocator);
                allocator.free(slice);
            },
            .const_slice => |const_slice| {
                // elements are const pointers and can't be deinit
                // for (const_slice) |*ele| ele.deinit(allocator);
                allocator.free(const_slice);
            },
            .map => |map| {
                for (0..map.count()) |i| {
                    map.values()[i].deinit(allocator);
                    allocator.free(map.keys()[i]);
                }
                map.deinit(allocator);
            },
            else => {},
        }
    }

    // -- start eql helpers --
    fn kind(z: ZType) Kind {
        return switch (z) {
            .bool, .float, .int, .string => .scalar,
            .array, .slice, .const_slice => .array,
            .map, .static_map => .map,
        };
    }

    fn arrayLen(z: ZType) usize {
        return switch (z) {
            .array => |x| x.items.len,
            .slice, .const_slice => |x| x.len,
            else => unreachable,
        };
    }

    fn arrayItems(z: ZType) []const ZType {
        return switch (z) {
            .array => |x| x.items,
            .slice, .const_slice => |x| x,
            else => unreachable,
        };
    }

    fn mapLen(z: ZType) usize {
        return switch (z) {
            .map => |x| x.count(),
            .static_map => |x| x.kvs.len,
            else => unreachable,
        };
    }

    fn mapItems(z: ZType) struct { []const []const u8, []const ZType } {
        return switch (z) {
            .map => |x| .{ x.keys(), x.values() },
            .static_map => |x| .{ x.keys(), x.values() },
            else => unreachable,
        };
    }

    fn mapGet(z: ZType, k: []const u8) ?ZType {
        return switch (z) {
            .map => |x| x.get(k),
            .static_map => |x| x.get(k),
            else => unreachable,
        };
    }
    // -- end eql helpers --

    pub fn eql(a: ZType, b: ZType) bool {
        const akind = a.kind();
        // std.debug.print("eql akind={s} bkind={s}\n", .{ @tagName(akind), @tagName(b.kind()) });
        if (akind != b.kind()) return false;
        const atag: Tag = a;

        switch (akind) {
            .scalar => {
                if (atag != @as(Tag, b)) return false;
                switch (a) {
                    inline .bool, .int, .float => |x, tag| {
                        return x == @field(b, @tagName(tag));
                    },
                    .string => |x| return mem.eql(u8, x, b.string),
                    else => unreachable,
                }
            },
            .array => {
                const alen = a.arrayLen();
                if (alen != b.arrayLen()) return false;
                const aitems = a.arrayItems();
                const bitems = b.arrayItems();
                return for (0..alen) |i| {
                    if (!aitems[i].eql(bitems[i])) return false;
                } else true;
            },
            .map => {
                const alen = a.mapLen();
                // std.debug.print("alen={} blen={}\n", .{ alen, b.mapLen() });
                if (alen != b.mapLen()) return false;
                const akvs = a.mapItems();
                return for (akvs[0], akvs[1]) |k, v| {
                    // std.debug.print("k={s}\n", .{k});
                    const bv = b.mapGet(k) orelse return false;
                    if (!v.eql(bv)) return false;
                } else true;
            },
        }
    }

    pub fn write(zt: ZType, writer: anytype) !void {
        // std.debug.print("write {s}\n", .{@tagName(zt)});
        switch (zt) {
            .bool => |x| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.bool)) |
                    (@as(u8, @intFromBool(x)) << @bitSizeOf(TagInt)));
            },
            .int => |x| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.int)));
                try writer.writeInt(i64, x, .little);
            },
            .float => |x| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.float)));
                try writer.writeInt(i64, @bitCast(x), .little);
            },
            .string => |x| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.string)));
                try writer.writeInt(usize, x.len, .little);
                _ = try writer.write(x);
            },
            .array => |array| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.array)));
                try writer.writeInt(usize, array.items.len, .little);
                for (array.items) |ele| try ele.write(writer);
            },
            .slice => |slice| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.slice)));
                try writer.writeInt(usize, slice.len, .little);
                for (slice) |ele| try ele.write(writer);
            },
            .const_slice => |slice| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.const_slice)));
                try writer.writeInt(usize, slice.len, .little);
                for (slice) |ele| try ele.write(writer);
            },
            .map => |map| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.map)));
                try writer.writeInt(usize, map.count(), .little);
                for (map.keys(), map.values()) |k, v| {
                    try writer.writeByte(@intCast(k.len));
                    _ = try writer.write(k);
                    try v.write(writer);
                }
            },
            .static_map => |map| {
                try writer.writeByte(@as(u8, @intFromEnum(Tag.static_map)));
                try writer.writeInt(u32, map.kvs.len, .little);
                for (map.keys(), map.values()) |k, v| {
                    try writer.writeByte(@intCast(k.len));
                    _ = try writer.write(k);
                    try v.write(writer);
                }
            },
        }
    }

    pub const Parsed = struct {
        arena: ?*std.heap.ArenaAllocator = null,
        value: ZType,

        pub fn deinit(self: Parsed) void {
            const arena = self.arena orelse return;
            const allocator = arena.child_allocator;
            arena.deinit();
            allocator.destroy(arena);
        }
    };

    pub const Options = struct { allocator: ?mem.Allocator = null };

    // similar to std.json.parseFromTokenSource()
    pub fn parse(reader: anytype, options: Options) !ZType.Parsed {
        var parsed = Parsed{
            .arena = if (options.allocator) |a| blk: {
                const arena = try a.create(std.heap.ArenaAllocator);
                arena.* = std.heap.ArenaAllocator.init(a);
                break :blk arena;
            } else null,
            .value = undefined,
        };
        errdefer if (options.allocator) |a| {
            parsed.arena.?.deinit();
            a.destroy(parsed.arena.?);
        };

        const new_options: Options = .{ .allocator = if (parsed.arena) |arena|
            arena.allocator()
        else
            null };

        parsed.value = try parseLeaky(reader, new_options);

        return parsed;
    }

    // similar to std.json.parseFromTokenSourceLeaky()
    pub fn parseLeaky(reader: anytype, options: Options) !ZType {
        const byte = try reader.readByte();
        // std.debug.print("parseLeaky byte {b:0>8}\n", .{byte});

        const tag = std.meta.intToEnum(Tag, @as(TagInt, @truncate(byte))) catch {
            return error.InvalidTag;
        };
        // std.debug.print("parseLeaky tag {s}\n", .{@tagName(tag)});
        switch (tag) {
            .bool => {
                const mask = @as(u8, std.math.maxInt(TagInt)) << @bitSizeOf(TagInt);
                return .{ .bool = byte & mask != 0 };
            },
            .int => {
                return .{ .int = try reader.readInt(i64, .little) };
            },
            .float => {
                return .{ .float = @bitCast(try reader.readInt(i64, .little)) };
            },
            .string => {
                const len = try reader.readInt(usize, .little);
                if (len == 0) return .{ .array = .{} };
                const alloc = options.allocator orelse return error.AllocatorRequired;
                const string = try alloc.alloc(u8, len);
                const amt = try reader.read(string);
                if (amt != len) return error.InvalidString;
                return .{ .string = string };
            },
            .array => {
                const len = try reader.readInt(usize, .little);
                if (len == 0) return .{ .array = .{} };
                const alloc = options.allocator orelse return error.AllocatorRequired;
                var array = try Array.initCapacity(alloc, len);
                for (0..len) |_| {
                    const ele = try parseLeaky(reader, options);
                    array.appendAssumeCapacity(ele);
                }
                return .{ .array = array };
            },
            .slice => {
                const len = try reader.readInt(usize, .little);
                if (len == 0) return .{ .slice = &.{} };
                const alloc = options.allocator orelse return error.AllocatorRequired;
                var slice = try alloc.alloc(ZType, len);
                for (0..len) |i| {
                    slice[i] = try parseLeaky(reader, options);
                }
                return .{ .slice = slice };
            },
            .const_slice => {
                const len = try reader.readInt(usize, .little);
                if (len == 0) return .{ .slice = &.{} };
                const alloc = options.allocator orelse return error.AllocatorRequired;
                var slice = try alloc.alloc(ZType, len);
                for (0..len) |i| {
                    slice[i] = try parseLeaky(reader, options);
                }
                return .{ .const_slice = slice };
            },
            .map => {
                const len = try reader.readInt(usize, .little);
                if (len == 0) return .{ .map = .{} };
                const alloc = options.allocator orelse return error.AllocatorRequired;
                var map = Map{};
                try map.ensureTotalCapacity(alloc, len);
                for (0..len) |_| {
                    const klen = try reader.readByte();
                    const buf = try alloc.alloc(u8, klen);
                    const amt = try reader.read(buf);
                    if (amt != klen) return error.InvalidMapKey;
                    map.putAssumeCapacity(buf, try parseLeaky(reader, options));
                }
                return .{ .map = map };
            },
            .static_map => {
                const len = try reader.readInt(u32, .little);
                if (len == 0) return .{ .map = .{} };
                const alloc = options.allocator orelse return error.AllocatorRequired;
                var kvs = try alloc.alloc(struct { []const u8, ZType }, len);

                for (0..len) |i| {
                    const klen = try reader.readByte();
                    const buf = try alloc.alloc(u8, klen);
                    const amt = try reader.read(buf);
                    if (amt != klen) return error.InvalidMapKey;
                    kvs[i] = .{ buf, try parseLeaky(reader, options) };
                }
                return .{ .static_map = try StaticMap.init(kvs, alloc) };
            },
        }
    }

    /// prints json
    pub fn format(
        zt: ZType,
        comptime fmt: []const u8,
        options: std.fmt.FormatOptions,
        writer: anytype,
    ) !void {
        switch (zt) {
            .bool => |x| try std.fmt.formatType(x, "", options, writer, 1),
            inline .int, .float => |x| try std.fmt.formatType(x, fmt, options, writer, 1),
            .string => |x| {
                try writer.writeByte('"');
                _ = try writer.write(x);
                try writer.writeByte('"');
            },
            .array => |x| {
                try writer.writeByte('[');
                for (x.items, 0..) |ele, i| {
                    if (i != 0) _ = try writer.write(", ");
                    try std.fmt.formatType(ele, fmt, options, writer, 1);
                }
                try writer.writeByte(']');
            },
            .slice, .const_slice => |x| {
                try writer.writeByte('[');
                for (x, 0..) |ele, i| {
                    if (i != 0) _ = try writer.write(", ");
                    try std.fmt.formatType(ele, fmt, options, writer, 1);
                }
                try writer.writeByte(']');
            },
            inline .map, .static_map => |x| {
                try writer.writeByte('{');
                for (x.keys(), x.values(), 0..) |k, v, i| {
                    if (i != 0) _ = try writer.write(", ");
                    try writer.writeByte('"');
                    _ = try writer.write(k);
                    try writer.writeByte('"');
                    _ = try writer.write(": ");
                    try std.fmt.formatType(v, fmt, options, writer, 1);
                }
                try writer.writeByte('}');
            },
        }
    }
};
