const std = @import("std");
const zig_jsonloads = @import("zig_jsonloads");

/// Differential fuzz helper.
///
/// Reads one JSON payload from argv[1], parses with zig_jsonloads, and emits:
/// - canonical JSON on success
/// - `ERR:<ErrorName>` on parse failure
pub fn main() !void {
    var args = std.process.args();
    _ = args.next();

    const source = args.next() orelse {
        std.debug.print("usage: fuzz_diff '<json>'\n", .{});
        return;
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;

    var parsed = zig_jsonloads.loads(std.heap.page_allocator, source) catch |err| {
        try out.print("ERR:{s}\n", .{@errorName(err)});
        try out.flush();
        return;
    };
    defer parsed.deinit();

    try writeCanonical(out, parsed.value, std.heap.page_allocator);
    try out.writeAll("\n");
    try out.flush();
}

/// Emit deterministic JSON for semantic cross-checks.
fn writeCanonical(out: *std.Io.Writer, value: zig_jsonloads.JsonValue, allocator: std.mem.Allocator) !void {
    switch (value) {
        .null => try out.writeAll("null"),
        .bool => |b| try out.writeAll(if (b) "true" else "false"),
        .integer => |iv| switch (iv) {
            .small => |i| try out.print("{d}", .{i}),
            .big => |big| {
                const text = try big.toString(allocator, 10, .lower);
                defer allocator.free(text);
                try out.writeAll(text);
            },
        },
        .float => |f| {
            if (std.math.isNan(f)) {
                try out.writeAll("NaN");
            } else if (f == std.math.inf(f64)) {
                try out.writeAll("Infinity");
            } else if (f == -std.math.inf(f64)) {
                try out.writeAll("-Infinity");
            } else {
                // Always print exponent form so Python preserves float type.
                try out.print("{e}", .{f});
            }
        },
        .string => |s| try std.json.Stringify.value(s, .{}, out),
        .array => |arr| {
            try out.writeAll("[");
            for (arr.items, 0..) |item, idx| {
                if (idx != 0) try out.writeAll(",");
                try writeCanonical(out, item, allocator);
            }
            try out.writeAll("]");
        },
        .object => |obj| {
            try out.writeAll("{");
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) {
                if (idx != 0) try out.writeAll(",");
                try std.json.Stringify.value(entry.key_ptr.*, .{}, out);
                try out.writeAll(":");
                try writeCanonical(out, entry.value_ptr.*, allocator);
            }
            try out.writeAll("}");
        },
        .object_pairs => |pairs| {
            try out.writeAll("[");
            for (pairs, 0..) |pair, idx| {
                if (idx != 0) try out.writeAll(",");
                try out.writeAll("[");
                try std.json.Stringify.value(pair.key, .{}, out);
                try out.writeAll(",");
                try writeCanonical(out, pair.value, allocator);
                try out.writeAll("]");
            }
            try out.writeAll("]");
        },
    }
}
