const std = @import("std");
const ZType = @import("types.zig").ZType;

pub fn main() !void {
    const allocator = std.heap.c_allocator;
    const value: bool = true;
    const z_value = try ZType.init(allocator, value);

    std.debug.print("{s}\n", .{z_value.data});

    std.debug.print("{any}\n", .{z_value.getTag()});
    std.debug.print("{any}\n", .{z_value.getBool()});

    const int_val: i64 = -1234567890;
    const z_int_value = try ZType.init(allocator, int_val);
    std.debug.print("{any}\n", .{z_int_value.getTag()});
    std.debug.print("{d}\n", .{try z_int_value.getInt()});

    const float_val: f64 = -12.8012;
    const z_float_value = try ZType.init(allocator, float_val);
    std.debug.print("{any}\n", .{z_float_value.getTag()});
    std.debug.print("{d}\n", .{try z_float_value.getFloat()});

    // const array_elem: [3]ZType = .{ z_value, z_int_value, z_float_value };
    var array_elem = std.ArrayList(ZType).init(allocator);
    try array_elem.append(z_value);
    try array_elem.append(z_int_value);
    try array_elem.append(z_float_value);

    // const z_array_val = try ZType.init(allocator, array_elem.items);
    // std.debug.print("{any}\n", .{z_array_val.getTag()});
    // const array_val = try z_array_val.getArray(allocator);
    //
    // for (array_val) |elem| {
    //     switch (elem.getTag()) {
    //         .bool => {
    //             std.debug.print("{any}\n", .{try elem.getBool()});
    //         },
    //         .int => {
    //             std.debug.print("{d}\n", .{try elem.getInt()});
    //         },
    //         .float => {
    //             std.debug.print("{d}\n", .{try elem.getFloat()});
    //         },
    //         .array => unreachable,
    //     }
    // }

    var hash_map = std.StringHashMap(ZType).init(allocator);
    try hash_map.put("bool", z_value);
    try hash_map.put("int", z_int_value);
    try hash_map.put("float", z_float_value);

    const z_map_val = try ZType.init(allocator, hash_map);
    std.debug.print("{any}\n", .{z_map_val.getTag()});

    const map_val = try z_map_val.getMap(allocator);
    var it = map_val.iterator();
    while (it.next()) |entry| {
        std.debug.print("{s}: {any}\n", .{ entry.key_ptr.*, entry.value_ptr.getTag() });
        switch (entry.value_ptr.*.getTag()) {
            .bool => {
                std.debug.print("{any}\n", .{try entry.value_ptr.getBool()});
            },
            .int => {
                std.debug.print("{d}\n", .{try entry.value_ptr.getInt()});
            },
            .float => {
                std.debug.print("{d}\n", .{try entry.value_ptr.getFloat()});
            },
            else => unreachable,
        }
    }
}
