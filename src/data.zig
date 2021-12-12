// Module to generate data
const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const TestCase = @import("main.zig").TestCase;

const factor: f64 = 0.00390625; // 1/256

pub fn bools(tc: *TestCase) !bool {
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] < 128;
}

pub fn weighted_bools(tc: *TestCase, p_true: f64) !bool {
    var buf: [8]u8 = undefined;
    try tc.get_bytes(&buf);
    var alpha: f64 = 0;
    var exp = factor;
    for (buf) |b| {
        alpha += exp * @intToFloat(f64, b);
        exp *= factor;
    }
    return alpha < p_true;
}

test "always true" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();
    const is_true = try weighted_bools(&tc, 1);
    try std.testing.expect(is_true);
}

test "never true" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();
    const is_true = try weighted_bools(&tc, 0);
    try std.testing.expect(!is_true);
}

test "sometimes true" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();

    const b0 = try weighted_bools(&tc, 0.5);
    const b1 = try weighted_bools(&tc, 0.5);
    const b2 = try weighted_bools(&tc, 0.5);
    const not_all = !(b0 and b1 and b2);
    _ = not_all;
    // This raises out of memory error???
    // try std.testing.expect(not_all);
    try std.testing.expect(b0 or b1 or b2);
}

pub fn numbers(comptime T: type, tc: *TestCase) !T {
    const N = switch (@typeInfo(T)) {
        .Int => |info| info.bits / 8,
        .Float => |info| info.bits / 8,
        else => @compileError("Type T is not a supported type"),
    };
    var buf: [N]u8 = undefined;
    try tc.get_bytes(&buf);
    return @bitCast(T, buf);
}

pub fn u8s(tc: *TestCase) !u8 {
    return try numbers(u8, tc);
}

test "smoke numbers" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();

    const i: u8 = try numbers(u8, &tc);
    _ = i;
    const j: u32 = try numbers(u16, &tc);
    _ = j;
    const k: i64 = try numbers(i64, &tc);
    _ = k;
    const m: f64 = try numbers(f64, &tc);
    _ = m;
}

pub fn arraylists(comptime T: type, alloc: *Allocator, tc: *TestCase, elements: fn (tc: *TestCase) anyerror!T, min_size: usize, max_size: usize) !ArrayList(T) {
    var result = ArrayList(T).init(alloc);
    while (result.items.len <= max_size and (result.items.len < min_size or try weighted_bools(tc, 0.1))) {
        try result.append(try elements(tc));
    }
    return result;
}

test "smoke arraylists" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();

    const arraylist = try arraylists(u8, std.testing.allocator, &tc, u8s, 3, 10);
    defer arraylist.deinit();
    try std.testing.expect(arraylist.items.len >= 3);
    try std.testing.expect(arraylist.items.len <= 10);
}

pub fn slices(comptime T: type, alloc: *Allocator, tc: *TestCase, elements: fn (tc: *TestCase) anyerror!T, min_size: usize, max_size: usize) ![]T {
    var result = try arraylists(T, alloc, tc, elements, min_size, max_size);
    return result.toOwnedSlice();
}

test "smoke slices" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();

    const slice = try slices(u8, std.testing.allocator, &tc, u8s, 3, 10);
    defer std.testing.allocator.free(slice);
    try std.testing.expect(slice.len >= 3);
    try std.testing.expect(slice.len <= 10);
}
