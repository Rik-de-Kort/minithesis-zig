const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn main() anyerror!void {
    // Main funciton is not really used for anything. We test stuff!
    const r: usize = std.math.sub(usize, 64, 128) catch 1;
    _ = r;
}

fn cloneArrayList(arr: ArrayList(u8)) !ArrayList(u8) {
    var buf = try arr.allocator.alloc(u8, arr.items.len);
    std.mem.copy(u8, buf, arr.items);
    return ArrayList(u8).fromOwnedSlice(arr.allocator, buf);
}

test "cloneArrayList" {
    var first = ArrayList(u8).init(std.testing.allocator);
    defer first.deinit();
    var data: [3]u8 = .{ 1, 2, 3 };
    try first.appendSlice(&data);
    var second = try cloneArrayList(first);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.items, second.items);
    first.items[0] = 0;
    try std.testing.expect(first.items[0] != second.items[0]);
}

fn dupeArrayList(dest: *ArrayList(u8), source: ArrayList(u8)) !void {
    try dest.ensureTotalCapacity(source.items.len);
    dest.items.len = source.items.len;
    std.mem.copy(u8, dest.items, source.items);
}

test "dupeArrayList" {
    var data: [3]u8 = .{ 1, 2, 3 };
    var first = ArrayList(u8).fromOwnedSlice(std.testing.allocator, &data);
    // defer first.deinit();
    var second = ArrayList(u8).init(std.testing.allocator);
    defer second.deinit();

    try dupeArrayList(&second, first);

    // try std.testing.expectEqualSlices(u8, first.items, second.items);
    // first.items[0] = 0;
    // try std.testing.expect(first.items[0] != second.items[0]);
}

fn bytes_to_slice(bytes: [8]u8) []u8 {
    var buf: [4]u8 = undefined;
    var i: usize = 0;
    while (buf[i] > 128) : (i += 2) {
        buf[i / 2] = bytes[i];
    }
    return buf[0..i];
}

pub fn arrayLists(alloc: *Allocator, tc: *TestCase) !ArrayList(u8) {
    var result = ArrayList(u8).init(alloc);

    var buf: [8]u8 = undefined;
    var i: usize = 0;
    while (true) : (i = (i + 2) % 8) {
        if (i == 0) try tc.get_bytes(&buf);

        // Continue with about 20/256 chance
        if (buf[i] < 230) break;
        try result.append(buf[i + 1]);
    }

    return result;
}

test "arrayLists basic" {
    var alloc = std.testing.allocator;
    var tc = TestCase.init(alloc);
    defer tc.deinit();
    const result = try arrayLists(alloc, &tc);
    defer result.deinit();
    try std.testing.expectEqual(@TypeOf(result), ArrayList(u8));
}

test "cloneArrayLists property test" {
    var alloc = std.testing.allocator;

    var i: usize = 0;
    var tc: TestCase = undefined;
    var input: ArrayList(u8) = undefined;
    var copy: ArrayList(u8) = undefined;
    while (i < MAX_RUNS) : (i += 1) {
        tc = TestCase.init(alloc);
        defer tc.deinit();
        input = try arrayLists(alloc, &tc);
        defer input.deinit();
        copy = try cloneArrayList(input);
        defer copy.deinit();
        try std.testing.expectEqualSlices(u8, input.items, copy.items);
    }
}

/////////////////////////////////////
///  TestCase                     ///
/////////////////////////////////////

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
const MAX_RUNS = 10000;

///////////////////////////////////////
//       Shrinking and test runner  ///
///////////////////////////////////////

fn shrink_reduce(alloc: *Allocator, old_attempt: ArrayList(u8), interesting: InterestTest) anyerror!ArrayList(u8) {
    if (old_attempt.items.len == 0) return old_attempt;
    // std.debug.print("shrinking attempt {any}\n", .{old_attempt.items});
    var attempt = try cloneArrayList(old_attempt);
    defer attempt.deinit();

    var known_good = try cloneArrayList(attempt);
    var i: usize = attempt.items.len - 1;
    while (i >= 0) : (i -= 1) {
        attempt.deinit();
        attempt = try cloneArrayList(known_good);

        // std.debug.print("Reducing {} for {any}\n", .{ i, attempt.items });
        // std.debug.print("Known good is {any}\n", .{known_good.items});
        while (try interesting(alloc, &TestCase.for_history(attempt))) {
            known_good.deinit();
            known_good = try cloneArrayList(attempt);

            if (attempt.items[i] == 0) break;
            attempt.items[i] -= 1;
        }
        // std.debug.print("after a reduction, known good is {any}\n", .{known_good.items});
        if (i == 0) break;
    }
    return known_good;
}

test "Reduce shrinking in both positions" {
    const expected: [2]u8 = .{ 10, 10 };
    var attempt: [2]u8 = .{ 100, 100 };
    var alloc = std.testing.allocator;
    const result = try shrink_reduce(alloc, ArrayList(u8).fromOwnedSlice(alloc, attempt[0..]), interesting_if_both_ge_10);
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, expected[0..], result.items[0..]);
}

fn shrink_remove(alloc: *Allocator, old_attempt: ArrayList(u8), interesting: InterestTest) anyerror!ArrayList(u8) {
    _ = alloc;
    if (old_attempt.items.len == 0) return old_attempt;
    var attempt = try cloneArrayList(old_attempt);
    defer attempt.deinit();
    var known_good = try cloneArrayList(attempt);

    var k: usize = 2; // Delete k items at a time
    while (k >= 1) : (k -= 1) {
        known_good.deinit();
        known_good = try cloneArrayList(attempt);
        var start: usize = known_good.items.len - k;
        while (start >= 0) : (start -= 1) {
            if (start + k > attempt.items.len) {
                if (start > 0) continue;
                break;
            }
            try attempt.replaceRange(start, k, &.{});
            if (interesting(alloc, &TestCase.for_history(attempt)) catch false) {
                // Todo(Rik): ask in zig-help if this is the right pattern
                known_good.deinit();
                known_good = try cloneArrayList(attempt);

                start = std.math.sub(usize, known_good.items.len, k) catch 1;
            }
            if (start == 0) break;
        }
    }
    return known_good;
}

test "shrink_remove ez" {
    var alloc = std.testing.allocator;
    var attempt_array: [5]u8 = .{ 1, 2, 3, 4, 5 };
    var attempt = ArrayList(u8).fromOwnedSlice(alloc, attempt_array[0..]);
    const expected: [0]u8 = .{};
    const result = try shrink_remove(std.testing.allocator, attempt, always_interesting);
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, expected[0..], result.items);
}

pub fn shrink(alloc: *Allocator, attempt: ArrayList(u8), interesting: InterestTest) !ArrayList(u8) {
    const reduced = shrink_reduce(alloc, attempt, interesting) catch attempt;
    defer reduced.deinit();
    const removed = shrink_remove(alloc, reduced, interesting) catch reduced;
    return removed;
}

pub fn run_test(alloc: *Allocator, interesting: InterestTest) anyerror!?ArrayList(u8) {
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
        const shrunk: ArrayList(u8) = try shrink_reduce(alloc, tc.history, interesting);
        std.debug.print("Got an interesting test case with choices {any}.\n", .{shrunk.items});
        return shrunk;
    } else {
        return null;
    }
}

////////////////////////////////////////
/// Interestingness functions        ///
////////////////////////////////////////

fn interesting_if_ge_10(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    // std.debug.print("buf {any}", .{buf});
    return buf[0] >= 10;
}

pub fn interesting_if_gt_10(x: ArrayList(u8)) bool {
    return x[0] > 10;
}

fn interesting_if_both_ge_10(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    var buf: [2]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] >= 10 and buf[1] >= 10;
}

fn always_interesting(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    _ = tc;
    return true;
}

fn never_interesting(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    _ = tc;
    return false;
}

fn rarely_interesting(alloc: *Allocator, tc: *TestCase) MTError!bool {
    _ = alloc;
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] < 10;
}

fn first_is_true(alloc: *Allocator, tc: *TestCase) MTError!bool {
    const result = try simple_list_of_bools(alloc, tc);
    defer result.deinit();
    return result.items.len > 0 and result.items[0];
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

test "Always interesting" {
    try std.testing.expect(null != try run_test(std.testing.allocator, always_interesting));
}

test "Never interesting" {
    try std.testing.expect(null == try run_test(std.testing.allocator, never_interesting));
}

test "Hard to find" {
    const expected: [1]u8 = .{0};
    const result = (try run_test(std.testing.allocator, rarely_interesting)) orelse return error.TestExpectedEqual;
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, expected[0..expected.len], result.items);
}

test "Shrink ArrayList of bools" {
    const expected: [3]u8 = .{ 129, 129, 0 };
    var attempt_array: [5]u8 = .{ 200, 175, 200, 23, 99 };
    var attempt = ArrayList(u8).fromOwnedSlice(std.testing.allocator, attempt_array[0..]);
    const result = try shrink(std.testing.allocator, attempt, first_is_true);
    defer result.deinit();
    try std.testing.expectEqualSlices(u8, expected[0..], result.items);
}
