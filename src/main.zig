const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const MTError = error{ Overrun, Interesting };

const TestCase = struct {
    const Self = @This();
    rng: std.rand.Isaac64,
    history: ArrayList(u8),
    index: usize,

    pub fn init(alloc: *Allocator) Self {
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

const InterestTest = fn (alloc: *Allocator, tc: *TestCase) MTError!bool;
const MAX_RUNS = 1000;

/// Helper to create a test case with history given by to_check and apply the InterestTest on it.
fn interesting_for_slice(alloc: *Allocator, to_check: []u8, itest: InterestTest) bool {
    var list = ArrayList(u8).init(alloc);
    list.appendSlice(to_check) catch return false;
    var tc: TestCase = TestCase.for_history(list);
    defer tc.deinit();
    return itest(alloc, &tc) catch false;
}

fn interesting_if_ge_10(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    // std.debug.print("buf {any}", .{buf});
    return buf[0] >= 10;
}

test "interesting_for_slice" {
    var buf: [1]u8 = .{1};
    try std.testing.expect(!interesting_for_slice(std.testing.allocator, buf[0..1], interesting_if_ge_10));
    buf = .{10};
    try std.testing.expect(interesting_for_slice(std.testing.allocator, buf[0..1], interesting_if_ge_10));
    buf = .{100};
    try std.testing.expect(interesting_for_slice(std.testing.allocator, buf[0..1], interesting_if_ge_10));
}

fn shrink_reduce(alloc: *Allocator, attempt: []u8, interesting: InterestTest) anyerror![]u8 {
    if (attempt.len == 0) return attempt;
    // std.debug.print("shrinking attempt {any}\n", .{attempt});
    var known_good = try std.mem.dupe(alloc, u8, attempt);
    var i: usize = attempt.len - 1;
    while (i >= 0) : (i -= 1) {
        // std.debug.print("Reducing {} for {any}\n", .{ i, attempt });
        std.mem.copy(u8, attempt, known_good);
        while (interesting_for_slice(alloc, attempt, interesting)) {
            std.mem.copy(u8, known_good, attempt);

            if (attempt[i] == 0) break;
            attempt[i] -= 1;
        }
        if (i == 0) break;
    }
    // std.debug.print("I need a drink {}\n", .{interesting_for_slice(known_good, interesting)});
    // std.debug.print("attempt: {any}, known_good: {any}\n", .{ attempt, known_good });
    return known_good;
}

fn shrink_remove(alloc: *Allocator, attempt: []u8, interesting: InterestTest) anyerror![]u8 {
    if (attempt.len == 0) return attempt;
    var known_good = try std.mem.dupe(alloc, u8, attempt);
    var k: usize = 1; // Delete k items at a time
    while (interesting_for_slice(alloc, attempt, interesting)) {
        std.mem.copy(u8, attempt, known_good);
        var i: usize = attempt.len - k;
        while (i > 0) : (i -= 1) {
            _ = i;
            // Todo(Rik): implement this stuff!
        }
        break;
    }
    return known_good;
}

pub fn shrink(alloc: *Allocator, attempt: []u8, interesting: InterestTest) ![]u8 {
    const reduced = shrink_reduce(alloc, attempt, interesting) catch attempt;
    defer alloc.free(reduced);
    const removed = shrink_remove(alloc, reduced, interesting) catch reduced;
    return removed;
}

pub fn run_test(alloc: *Allocator, interesting: InterestTest) anyerror!?[]u8 {
    var tc = TestCase.init(alloc);
    defer tc.deinit();

    var is_interesting: bool = interesting(alloc, &tc) catch false;
    var n_runs: usize = 1;
    while (!is_interesting and n_runs < MAX_RUNS) : (n_runs += 1) {
        tc.deinit();
        tc = TestCase.init(alloc);
        is_interesting = interesting(alloc, &tc) catch false;
    }
    if (is_interesting) {
        const shrunk: []u8 = try shrink_reduce(alloc, tc.history.items, interesting);
        std.debug.print("Got an interesting test case with choices {any}.\n", .{shrunk});
        return shrunk;
    } else {
        return null;
    }
}

pub fn interesting_if_gt_10(x: []u8) bool {
    return x[0] > 10;
}

pub fn simple_list_of_bools(alloc: *Allocator, tc: *TestCase) MTError!ArrayList(bool) {
    var result = ArrayList(bool).init(alloc);
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    while (buf[0] > 128) {
        try tc.get_bytes(&buf);
        result.append(buf[0] > 128) catch return MTError.Overrun;
        try tc.get_bytes(&buf);
    }
    return result;
}

test "simple_list_of_bools_works" {
    var alloc = std.testing.allocator;
    var tc = TestCase.init(alloc);
    defer tc.deinit();
    const result = simple_list_of_bools(alloc, &tc) catch return error.TestExpectedEqual;
    defer result.deinit();
}

pub fn main() anyerror!void {
    var i: usize = 0;
    while (i < 10) : (i += 1) {
        var j: usize = 0;
        while (j < 10) : (j += 1) {
            if (j > 3) break;
        }
        std.debug.print("i={}\n", .{i});
    }
}

fn always_interesting(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    _ = tc;
    return true;
}

test "Always interesting" {
    try std.testing.expect(null != try run_test(std.testing.allocator, always_interesting));
}

fn never_interesting(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    _ = tc;
    return false;
}

test "Never interesting" {
    try std.testing.expect(null == try run_test(std.testing.allocator, never_interesting));
}

fn rarely_interesting(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] < 10;
}

test "Hard to find" {
    const expected: [1]u8 = .{0};
    const result = (try run_test(std.testing.allocator, rarely_interesting)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, expected[0..expected.len], result);
}

test "Reduce shrinking" {
    const expected: [1]u8 = .{10};
    const result = (try run_test(std.testing.allocator, interesting_if_ge_10)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, expected[0..expected.len], result);
}

fn interesting_if_both_ge_10(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    var buf: [2]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] >= 10 and buf[1] >= 10;
}

test "Reduce shrinking in other position" {
    const expected: [2]u8 = .{ 10, 10 };
    const result = (try run_test(std.testing.allocator, interesting_if_both_ge_10)) orelse return error.TestExpectedEqual;
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, expected[0..expected.len], result);
}

fn first_is_true(alloc: *Allocator, tc: *TestCase) MTError!bool {
    const result = try simple_list_of_bools(alloc, tc);
    defer result.deinit();
    return result.items.len > 0 and result.items[0];
}

test "Shrink ArrayList of bools" {
    const expected: [3]u8 = .{ 129, 129, 0 };
    var attempt: [5]u8 = .{ 200, 175, 200, 23, 99 };
    const result = try shrink(std.testing.allocator, attempt[0..], first_is_true);
    defer std.testing.allocator.free(result);
    try std.testing.expectEqualSlices(u8, expected[0..], result);
}
