const std = @import("std");
const testing = std.testing;
const root = @import("ztype");
const ZType = root.ZType;
const talloc = testing.allocator;

fn testRoundTrip(expected: ZType) !void {
    var l = std.ArrayList(u8).init(talloc);
    defer l.deinit();

    try expected.write(l.writer());
    // std.debug.print("l len {}\n", .{l.items.len});
    var fbs = std.io.fixedBufferStream(l.items);
    var actual = try ZType.parse(fbs.reader(), .{ .allocator = talloc });

    defer actual.deinit();
    // std.debug.print("expected {}\n", .{expected});
    // std.debug.print("actual {}\n", .{actual.value});
    try testing.expect(expected.eql(actual.value));
}

const const_slice = [_]ZType{
    .{ .bool = true },
    .{ .int = 42 },
    .{ .float = 100.1 },
    .{ .string = "foo" },
};

test "scalars" {
    try testRoundTrip(.{ .bool = true });
    try testRoundTrip(.{ .bool = false });
    try testRoundTrip(.{ .int = 42 });
    try testRoundTrip(.{ .float = 100.1 });
    try testRoundTrip(.{ .string = "foo" });
}

test "arrays" {
    var array = ZType.Array{};
    defer array.deinit(talloc);
    try array.appendSlice(talloc, &const_slice);
    try testRoundTrip(.{ .array = array });

    var slice = const_slice;
    try testRoundTrip(.{ .slice = &slice });
    try testRoundTrip(.{ .const_slice = &const_slice });

    try testing.expect((ZType{ .array = array }).eql(.{ .slice = &slice }));
    try testing.expect((ZType{ .array = array }).eql(.{ .const_slice = &const_slice }));
    try testing.expect((ZType{ .slice = &slice }).eql(.{ .const_slice = &const_slice }));
    try testing.expect((ZType{ .slice = &slice }).eql(.{ .array = array }));
    try testing.expect((ZType{ .const_slice = &const_slice }).eql(.{ .array = array }));
    try testing.expect((ZType{ .const_slice = &const_slice }).eql(.{ .slice = &slice }));
}

const static_map = blk: {
    var kvs: [const_slice.len + 1]struct { []const u8, ZType } = undefined;
    for (0..const_slice.len) |i| {
        kvs[i] = .{ @tagName(const_slice[i]), const_slice[i] };
    }
    kvs[const_slice.len] = .{ "const_slice", .{ .const_slice = &const_slice } };
    break :blk ZType.StaticMap.initComptime(kvs);
};

test "maps" {
    try testRoundTrip(.{ .static_map = static_map });

    var map = ZType.Map{};
    defer map.deinit(talloc);
    for (static_map.keys(), static_map.values()) |k, v| {
        try map.put(talloc, k, v);
    }
    try testRoundTrip(.{ .map = map });

    try testing.expect((ZType{ .map = map }).eql(.{ .static_map = static_map }));
    try testing.expect((ZType{ .static_map = static_map }).eql(.{ .map = map }));
}

test "nested maps" {
    const static_map2 = comptime blk: {
        var kvs: [static_map.kvs.len + 1]struct { []const u8, ZType } = undefined;
        for (0..static_map.kvs.len) |i| {
            kvs[i] = .{ static_map.keys()[i], static_map.values()[i] };
        }

        kvs[static_map.kvs.len] = .{ "static_map", .{ .static_map = static_map } };
        break :blk ZType.StaticMap.initComptime(kvs);
    };
    try testRoundTrip(.{ .static_map = static_map2 });

    var map2 = ZType.Map{};
    defer map2.deinit(talloc);
    for (static_map2.keys(), static_map2.values()) |k, v| {
        try map2.put(talloc, k, v);
    }
    try testRoundTrip(.{ .map = map2 });

    try testing.expect((ZType{ .map = map2 }).eql(.{ .static_map = static_map2 }));
    try testing.expect((ZType{ .static_map = static_map2 }).eql(.{ .map = map2 }));

    try testing.expectFmt(
        \\{"int": 42, "bool": true, "float": 100.1, "string": "foo", "static_map": {"int": 42, "bool": true, "float": 100.1, "string": "foo", "const_slice": [true, 42, 100.1, "foo"]}, "const_slice": [true, 42, 100.1, "foo"]}
    , "{d}", .{ZType{ .static_map = static_map2 }});
}
