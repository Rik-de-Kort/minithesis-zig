const std = @import("std");
const ArrayList = std.ArrayList;

const MTError = error{Overrun};

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

const InterestTest = fn (tc: *TestCase) MTError!bool;
const MAX_RUNS = 1000;

fn shrink_reduce(history: []u8, interesting: InterestTest) []u8 {
    const interesting_for_slice = struct {
        fn inner(to_check: []u8, itest: InterestTest) bool {
            var alloc: std.heap.FixedBufferAllocator = std.heap.FixedBufferAllocator.init(to_check);

            var list = ArrayList(u8).init(&alloc.allocator);
            list.appendSlice(to_check) catch return false;
            var tc: TestCase = TestCase.for_history(list);
            return itest(&tc) catch false;
        }
    }.inner;

    var i = history.len - 1;
    var new_outer = history;
    while (interesting_for_slice(new_outer, interesting) and i >= 0) : (i -= 1) {
        var best: []u8 = new_outer;
        var new_inner: []u8 = new_outer;
        while (interesting_for_slice(new_inner, interesting) and new_inner[i] >= 0) : (new_inner[i] -= 1) {
            best = new_inner;
        }
        new_outer = best;
    }
    return new_outer;
}

pub fn shrink(history: []u8, interesting: InterestTest) history {
    _ = interesting;
    return history;
}

pub fn run_test(alloc: *std.mem.Allocator, interesting: InterestTest) anyerror!void {
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
        return error.TestExpectedEqual;
    }
}

pub fn main() anyerror!void {
    std.log.info("All your codebase are belong to us.", .{});
}

test "TestCase new bytes" {
    var tc = TestCase.init(std.testing.allocator);
    defer tc.deinit();
    var buf: [4]u8 = undefined;
    try tc.get_bytes(&buf);
    try std.testing.expectEqual(buf[0..buf.len], tc.history.items[0..buf.len]);
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

fn always_interesting(tc: *TestCase) MTError!bool {
    _ = tc;
    return true;
}

test "Always interesting" {
    try run_test(std.testing.allocator, always_interesting);
}

fn never_interesting(tc: *TestCase) MTError!bool {
    _ = tc;
    return false;
}

test "Never interesting" {
    try run_test(std.testing.allocator, never_interesting);
}

fn rarely_interesting(tc: *TestCase) MTError!bool {
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] < 10;
}

test "Hard to find" {
    try run_test(std.testing.allocator, rarely_interesting);
}
