# Minithesis-Zig
Some experiments for property-based testing in Zig. Still learning the language, figured this would be a good project to get to know it better.

## Architectural thoughts
Minithesis heavily relies on exception-based control flow and higher-order functions. In Zig neither of these is feasible. For error handling, Zig relies on a result type, which is fairly straightforward to use as compared to the exception based control flow. The higher order functions are a bit more annoying: it is virtually impossible to build a test runner in the previous design because this test runner has to take a function which can take in arbitrarily complicated data for an arbitrary number of arguments, something which doesn't seem very feasible as every parameter would need its own corresponding comptime type parameter.
One option is to use a struct as arguments. In this case, you would write some test:

````
fn first_greater_ge_10(input: ArrayList(u8)) !void {
    std.testing.expect(input.items.len >= 1);
    std.testing.expect(input.items[0] == 10);
}
````

Then you would wrap that test in some struct type and a test wrapper.
````
const Tmp = struct {
    .content: ArrayList(u8)
}

fn wrapped_test(input: Tmp) !void {
    try first_greater_ge_10(input.content);
}
````

Now a way to generate Tmp objects.

````
fn tmps(alloc: *Allocator, tc: *TestCase) !Tmp {
    return Tmp {
        .content = try arraylists(u8, alloc, tc, u8s, 1, 10),
    };
}
````

Which can now be put into a generic test runner using a single comptime type T.

````
fn run(comptime T: type, test: fn(T) anyerror!void, given: fn(alloc: *Allocator, tc: *TestCase) anyerror!T) !void {
    ...
}

test "run_property_test" {
    try run_test(Tmp, wrapped_test, tmps);
}
````
