const std = @import("std");
const ArrayList = std.ArrayList;

const MTError = error{ Overrun, Interesting };

const TestCase = struct {
    const Self = @This();
    rng: std.rand.Isaac64,
    history: ArrayList(u8),
    index: usize,

    pub fn init(alloc: *std.mem.Allocator) Self {
        return Self{ .rng = std.rand.Isaac64.init(@intCast(u64, std.time.milliTimestamp())), .history = ArrayList(u8).init(alloc), .index = 0 };
    }

    pub fn deinit(self: *Self) void {
        self.history.deinit();
    }

    pub fn for_history(history: ArrayList(u8)) Self {
        return Self{ .rng = std.rand.Isaac64.init(@intCast(u64, std.time.milliTimestamp())), .history = history, .index = 0 };
    }

    pub fn get_bytes(self: *Self, buf: []u8) MTError!void {
        var i: usize = 0;
        while (i < buf.len and self.index + i < self.history.items.len) : (i += 1) {
            buf[i] = self.history.items[self.index + i];
        }
        if (i < buf.len) {
            self.rng.fill(buf[i..buf.len]);
            self.history.appendSlice(buf[i..buf.len]) catch return MTError.Overrun;
        }
        self.index += buf.len;
    }
};

test "TestCase new bytes" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();
    var buf: [4]u8 = undefined;
    try tc.get_bytes(&buf);
    // try std.testing.expectEqual(buf[0..buf.len], tc.history.items[0..buf.len]);
}

test "TestCase history" {
    var history: ArrayList(u8) = ArrayList(u8).init(std.testing.allocator);
    defer history.deinit();
    const expected: [4]u8 = .{ 1, 2, 3, 4 };
    try history.appendSlice(&expected);
    var tc = TestCase.for_history(history);

    var buf: [4]u8 = undefined;
    try tc.get_bytes(&buf);
    try std.testing.expectEqual(buf, expected);
}

const InterestTest = fn (tc: *TestCase) MTError!bool;
const MAX_RUNS = 1000;

/// Helper to create a test case with history given by to_check and apply the InterestTest on it.
fn interesting_for_slice(to_check: []u8, itest: InterestTest) bool {
    var arena: std.heap.ArenaAllocator = std.heap.ArenaAllocator.init(std.heap.page_allocator);

    var list = ArrayList(u8).init(&arena.allocator);
    // std.debug.print("Trying to append... {any}\n", .{to_check});
    list.appendSlice(to_check) catch return false;
    // std.debug.print("Append succesful!", .{});
    var tc: TestCase = TestCase.for_history(list);
    return itest(&tc) catch false;
}

fn interesting_if_ge_10(tc: *TestCase) MTError!bool {
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    // std.debug.print("buf {any}", .{buf});
    return buf[0] >= 10;
}

test "interesting_for_slice" {
    var buf: [1]u8 = .{1};
    try std.testing.expect(!interesting_for_slice(buf[0..1], interesting_if_ge_10));
    buf = .{10};
    try std.testing.expect(interesting_for_slice(buf[0..1], interesting_if_ge_10));
    buf = .{100};
    try std.testing.expect(interesting_for_slice(buf[0..1], interesting_if_ge_10));
}

fn shrink_reduce(history: []u8, interesting: InterestTest) []u8 {
    if (history.len == 0) return history;
    while (interesting_for_slice(history, interesting) and history[0] > 0) : (history[0] -= 1) {}
    return history;
}

pub fn shrink(history: []u8, interesting: InterestTest) []u8 {
    _ = interesting;
    return history;
}

pub fn run_test(alloc: *std.mem.Allocator, interesting: InterestTest) ?[]u8 {
    var tc = TestCase.init(alloc);
    defer tc.deinit();

    var is_interesting: bool = interesting(&tc) catch false;
    var n_runs: usize = 1;
    while (!is_interesting and n_runs < MAX_RUNS) : (n_runs += 1) {
        tc.deinit();
        tc = TestCase.init(alloc);
        is_interesting = interesting(&tc) catch false;
    }
    if (is_interesting) {
        const shrunk: []u8 = shrink_reduce(tc.history.items, interesting);
        std.debug.print("Got an interersting test case with choices {any}.\n", .{shrunk});
        return shrunk;
    } else {
        return null;
    }
}

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
    var buf: [1]u8 = .{10};
    const result: bool = interesting_for_slice(buf[0..1], interesting_if_ge_10);
    std.debug.print("{}", .{result});
}

fn always_interesting(tc: *TestCase) MTError!bool {
    _ = tc;
    return true;
}

test "Always interesting" {
    try std.testing.expect(null != run_test(std.testing.allocator, always_interesting));
}

fn never_interesting(tc: *TestCase) MTError!bool {
    _ = tc;
    return false;
}

test "Never interesting" {
    try std.testing.expect(null == run_test(std.testing.allocator, never_interesting));
}

fn rarely_interesting(tc: *TestCase) MTError!bool {
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] < 10;
}

test "Hard to find" {
    const expected: [1]u8 = .{9};
    const result = run_test(std.testing.allocator, rarely_interesting) orelse return error.TestExpectedEqual;
    try std.testing.expectEqualSlices(u8, expected[0..expected.len], result);
}
