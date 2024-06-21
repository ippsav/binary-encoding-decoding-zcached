# ZType Serialization Library

## Overview

The `ZType` library provides a way to serialize and deserialize various data types into a compact binary format. It supports the following types:
- Boolean (`bool`)
- Integer (`int`)
- Floating-point (`float`)
- Arrays (`[]ZType`)
- Maps (`std.StringHashMap(ZType)`)

This is WIP and might not be the most optimal way to do this.

## Usage

### Initialization

To initialize a `ZType` instance, use the `init` function. The function takes an allocator and a value of any supported type.

```zig
const std = @import("std");
const ZType = @import("path/to/ztype.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const zbool = try ZType.init(allocator, true);
    const zint = try ZType.init(allocator, 42);
    const zfloat = try ZType.init(allocator, 3.14);
    const zarray = try ZType.init(allocator, &[_]ZType{zbool, zint, zfloat});
    // Deinitialize when done
    zbool.deinit(allocator);
    zint.deinit(allocator);
    zfloat.deinit(allocator);
    zarray.deinit(allocator);
}
```

### Deinitialization

To free the memory allocated for a `ZType` instance, use the `deinit` function.


ztype.deinit(allocator);


### Accessing Values

To access the original values stored in a `ZType` instance, use the appropriate getter functions:

- `getBool()`
- `getInt()`
- `getFloat()`
- `getArray()`
- `getMap()`

Each getter function returns an error if the type does not match.


const value = try ztype.getInt();


## Example

Here is a complete example demonstrating the usage of the `ZType` library:

```zig
const std = @import("std");
const ZType = @import("path/to/ztype.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    const zbool = try ZType.init(allocator, true);
    defer zbool.deinit(allocator);
    const zint = try ZType.init(allocator, 42);
    defer zint.deinit(allocator);

    const zfloat = try ZType.init(allocator, 3.14);
    defer zfloat.deinit(allocator);

    const zarray = try ZType.init(allocator, &[_]ZType{zbool, zint, zfloat});
    defer zarray.deinit(allocator);

    const bool_value = try zbool.getBool();
    const int_value = try zint.getInt();
    const float_value = try zfloat.getFloat();
    const array_value = try zarray.getArray(allocator);

    std.debug.print("Bool: {}\n", .{bool_value});
    std.debug.print("Int: {}\n", .{int_value});
    std.debug.print("Float: {}\n", .{float_value});
    std.debug.print("Array: {}\n", .{array_value});
}
```
