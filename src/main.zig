const std = @import("std");
const zig_jsonloads = @import("zig_jsonloads");

/// Minimal CLI demonstration.
///
/// Usage:
/// `zig build run -- '{"x":1}'`
pub fn main() !void {
    // Access process arguments as an iterator.
    var args = std.process.args();

    // Skip executable name (`argv[0]`).
    _ = args.next();

    // Expect exactly one JSON argument.
    const source = args.next() orelse {
        std.debug.print("usage: zig_jsonloads '<json>'\n", .{});
        return;
    };

    // Parse using the safe default API (input copy + managed arena lifecycle).
    const parsed = try zig_jsonloads.loads(std.heap.page_allocator, source);

    // Always release parser-owned memory.
    defer parsed.deinit();

    // Print the top-level tag to confirm parse succeeded.
    std.debug.print("parsed JSON root type: {s}\n", .{@tagName(parsed.value)});
}
