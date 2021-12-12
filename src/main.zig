const std = @import("std");
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

pub fn main() anyerror!void {
    // Main funciton is not really used for anything. We test stuff!
    std.debug.print("{any}\n", .{@typeInfo(u32)});
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

test "cloneArrayList with replaceRange" {
    var first = ArrayList(u8).init(std.testing.allocator);
    defer first.deinit();
    var data: [3]u8 = .{ 1, 2, 3 };
    try first.appendSlice(&data);
    var second = try cloneArrayList(first);
    defer second.deinit();
    try std.testing.expectEqualSlices(u8, first.items, second.items);
    try first.replaceRange(0, 2, &.{});
    std.testing.expectEqualSlices(u8, first.items, second.items) catch return;
    return error.TestUnexpectedError;
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

pub const TestCase = struct {
    const Self = @This();
    rng: std.rand.Isaac64,
    history: ArrayList(u8),
    index: usize,
    locked: bool,

    pub fn init(alloc: *Allocator) Self {
        return Self{ .rng = std.rand.Isaac64.init(@intCast(u64, std.time.milliTimestamp())), .history = ArrayList(u8).init(alloc), .index = 0, .locked = false };
    }

    pub fn deinit(self: *Self) void {
        self.history.deinit();
    }

    pub fn for_history(history: ArrayList(u8)) Self {
        return Self{ .rng = std.rand.Isaac64.init(@intCast(u64, std.time.milliTimestamp())), .history = history, .index = 0, .locked = true };
    }

    pub fn get_bytes(self: *Self, buf: []u8) MTError!void {
        var i: usize = 0;
        while (i < buf.len and self.index + i < self.history.items.len) : (i += 1) {
            buf[i] = self.history.items[self.index + i];
        }
        if (i < buf.len) {
            if (self.locked) return MTError.Overrun;
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
const MAX_RUNS = 10000;

///////////////////////////////////////
//       Shrinking and test runner  ///
///////////////////////////////////////

const asc_u8 = std.sort.asc(u8);

// Try sorting every possible contiguous slice of the array.
fn shrink_sort(known_good: *ArrayList(u8), attempt: *ArrayList(u8), interesting: InterestTest) anyerror!bool {
    if (known_good.items.len == 0) return false;
    var is_improved = false;
    var k: usize = known_good.items.len; // Number of items to sort
    while (k > 0) : (k -= 1) {
        // std.debug.print("{}\n", .{k});
        if (k > known_good.items.len) continue;

        var i: usize = known_good.items.len - k; // Start of sorting
        while (i >= 0) : (i -= 1) {
            try dupeArrayList(attempt, known_good.*);
            if (std.sort.isSorted(u8, attempt.items[i .. i + k], {}, asc_u8) and i > 0) continue;
            if (std.sort.isSorted(u8, attempt.items[i .. i + k], {}, asc_u8) and i == 0) break;

            std.sort.sort(u8, attempt.items[i .. i + k], {}, asc_u8);
            if (interesting(&TestCase.for_history(attempt.*)) catch false) {
                // std.debug.print("success! copying attempt={any} into known_good={any}\n", .{ attempt.items, known_good.items });
                is_improved = true;
                try dupeArrayList(known_good, attempt.*);
            }
            if (i == 0) break;
        }
    }
    return is_improved;
}

test "shrink_sort trivial" {
    var known_good = ArrayList(u8).init(std.testing.allocator);
    try known_good.appendSlice(&.{ 3, 2, 1 });
    defer known_good.deinit();

    var attempt = ArrayList(u8).init(std.testing.allocator);
    defer attempt.deinit();

    const is_improved = try shrink_sort(&known_good, &attempt, always_interesting);
    try std.testing.expect(is_improved);
    try std.testing.expectEqualSlices(u8, &.{ 1, 2, 3 }, known_good.items);
}

test "shrink_sort partial" {
    var known_good = ArrayList(u8).init(std.testing.allocator);
    try known_good.appendSlice(&.{ 30, 20, 10, 17 });
    defer known_good.deinit();

    var attempt = ArrayList(u8).init(std.testing.allocator);
    defer attempt.deinit();

    const is_improved = try shrink_sort(&known_good, &attempt, interesting_if_0_gt_1);
    try std.testing.expect(is_improved);
    try std.testing.expectEqualSlices(u8, &.{ 30, 10, 17, 20 }, known_good.items);
}

test "shrink_sort when doesn't improve" {
    var known_good = ArrayList(u8).init(std.testing.allocator);
    try known_good.appendSlice(&.{ 30, 20, 10 });
    defer known_good.deinit();

    var attempt = ArrayList(u8).init(std.testing.allocator);
    defer attempt.deinit();

    const is_improved = try shrink_sort(&known_good, &attempt, interesting_if_desc);
    try std.testing.expectEqualSlices(u8, &.{ 30, 20, 10 }, known_good.items);
    try std.testing.expect(!is_improved);
}

// Try reducing elements towards 0, one at a time.
fn shrink_reduce(known_good: *ArrayList(u8), attempt: *ArrayList(u8), interesting: InterestTest) anyerror!bool {
    if (known_good.items.len == 0) return false;

    var is_improved = false;
    var i: usize = known_good.items.len - 1;
    while (i >= 0) : (i -= 1) {
        try dupeArrayList(attempt, known_good.*);
        if (attempt.items[i] == 0 and i > 0) continue;
        if (attempt.items[i] == 0 and i == 0) break;

        attempt.items[i] -= 1;
        while (interesting(&TestCase.for_history(attempt.*)) catch false) : (attempt.items[i] -= 1) {
            is_improved = true;
            try dupeArrayList(known_good, attempt.*);
            if (attempt.items[i] == 0) break;
        }
        if (i == 0) break;
    }
    return is_improved;
}

test "Reduce shrinking in both positions" {
    var known_good = ArrayList(u8).init(std.testing.allocator);
    try known_good.appendSlice(&.{ 100, 100 });
    defer known_good.deinit();

    var attempt = ArrayList(u8).init(std.testing.allocator);
    defer attempt.deinit();

    const is_improved = try shrink_reduce(&known_good, &attempt, interesting_if_both_ge_10);
    try std.testing.expect(is_improved);
    try std.testing.expectEqualSlices(u8, &.{ 10, 10 }, known_good.items);
}

// Try removing elements, several at a time.
fn shrink_remove(known_good: *ArrayList(u8), attempt: *ArrayList(u8), interesting: InterestTest) anyerror!bool {
    if (known_good.items.len == 0) return false;

    var improved = false;
    var k: usize = known_good.items.len; // Delete k items at a time
    while (k >= 1) : (k -= 1) {
        if (known_good.items.len < k) continue;
        var start: usize = known_good.items.len - k;
        while (start >= 0) : (start -= 1) {
            if (start + k > known_good.items.len and start > 0) continue;
            if (start + k > known_good.items.len and start == 0) break;

            try dupeArrayList(attempt, known_good.*);
            try attempt.replaceRange(start, k, &.{});
            if (interesting(&TestCase.for_history(attempt.*)) catch false) {
                try dupeArrayList(known_good, attempt.*);
                improved = true;
            }

            if (start == 0) break;
        }
    }
    return improved;
}

test "shrink_remove everything" {
    var known_good = ArrayList(u8).init(std.testing.allocator);
    defer known_good.deinit();
    try known_good.appendSlice(&.{ 1, 2, 3, 4, 5 });

    var attempt = ArrayList(u8).init(std.testing.allocator);
    defer attempt.deinit();

    const is_improved = try shrink_remove(&known_good, &attempt, always_interesting);

    try std.testing.expect(is_improved);
    try std.testing.expectEqualSlices(u8, &.{}, known_good.items);
}

/// "Shrinking" means modifying some bytes in the test case so that the test case becomes "smaller",
/// that is, either shorter or having items closer to 0. Generically, a shrinking pass looks like:
///
/// while something is true:
///   copy known_good into attempt
///   modify attempt
///   if interesting(attempt)
///     copy attempt into known_good
///     mark pass as successful
/// return true if pass was successful
///
/// We run these shrinking passes after eachother until there is no improvement.
pub fn shrink(alloc: *Allocator, to_shrink: ArrayList(u8), interesting: InterestTest) !ArrayList(u8) {
    var known_good = ArrayList(u8).init(alloc);
    try dupeArrayList(&known_good, to_shrink);
    var attempt = ArrayList(u8).init(alloc);
    defer attempt.deinit();

    var improved: bool = true;
    while (improved) {
        improved = false;
        improved = improved or (shrink_remove(&known_good, &attempt, interesting) catch false);
        improved = improved or (shrink_reduce(&known_good, &attempt, interesting) catch false);
        improved = improved or (shrink_sort(&known_good, &attempt, interesting) catch false);
    }
    return known_good;
}

test "shrink_remove_curious" {
    var known_good = ArrayList(u8).init(std.testing.allocator);
    defer known_good.deinit();
    try known_good.appendSlice(&.{ 129, 129, 0, 0, 0 });
    var attempt = ArrayList(u8).init(std.testing.allocator);
    defer attempt.deinit();
    const is_improved = try shrink_remove(&known_good, &attempt, first_is_true);

    const expected: [3]u8 = .{ 129, 129, 0 };

    try std.testing.expect(is_improved);
    try std.testing.expectEqualSlices(u8, expected[0..], known_good.items);
}

/// Run a test for `interesting`. Tries to find a TestCase tc such that `interesting(&tc)` is true.
/// It does this by randomly generating TestCases, which then get shrunk to produce a (hopefully)
/// minimal example.
pub fn run_test(alloc: *Allocator, interesting: InterestTest) anyerror!?ArrayList(u8) {
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
        // std.debug.print("Trying to shrink choices {any}.\n", .{tc.history.items});
        const shrunk: ArrayList(u8) = try shrink(alloc, tc.history, interesting);
        // std.debug.print("Got an interesting test case with choices {any}.\n", .{shrunk.items});
        return shrunk;
    } else {
        return null;
    }
}

/////////////////////////////////////
/// Integration tests             ///
/////////////////////////////////////
fn interesting_if_desc(tc: *TestCase) !bool {
    var buf: [3]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] > buf[1] and buf[1] > buf[2];
}

fn interesting_if_0_gt_1(tc: *TestCase) !bool {
    var buf: [4]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] > buf[1];
}

fn interesting_if_ge_10(tc: *TestCase) MTError!bool {
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    // std.debug.print("buf {any}", .{buf});
    return buf[0] >= 10;
}

fn interesting_if_gt_10(x: ArrayList(u8)) bool {
    return x[0] > 10;
}

fn interesting_if_both_ge_10(tc: *TestCase) MTError!bool {
    var buf: [2]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] >= 10 and buf[1] >= 10;
}

fn always_interesting(tc: *TestCase) MTError!bool {
    _ = tc;
    return true;
}

fn never_interesting(tc: *TestCase) MTError!bool {
    _ = tc;
    return false;
}

fn rarely_interesting(tc: *TestCase) MTError!bool {
    var buf: [1]u8 = undefined;
    try tc.get_bytes(&buf);
    return buf[0] < 10;
}

fn first_is_true(tc: *TestCase) MTError!bool {
    var alloc = std.testing.allocator;
    const result = try simple_list_of_bools(alloc, tc);
    defer result.deinit();
    return result.items.len > 0 and result.items[0];
}

pub fn simple_list_of_bools(alloc: *Allocator, tc: *TestCase) MTError!ArrayList(bool) {
    var result = ArrayList(bool).init(alloc);
    errdefer result.deinit();
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
