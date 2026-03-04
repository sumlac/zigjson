const std = @import("std");
const zig_jsonloads = @import("zig_jsonloads");

/// Microbenchmark entry point.
///
/// This compares three paths:
/// - `fast`: custom parser + leaky mode + arena reset
/// - `safe`: custom parser + managed parsed wrapper
/// - `std`: Zig stdlib dynamic parser + leaky mode + arena reset
pub fn main() !void {
    // Parse optional iteration count from CLI.
    var args = std.process.args();
    _ = args.next();

    const iterations = if (args.next()) |s|
        std.fmt.parseInt(usize, s, 10) catch 100_000
    else
        100_000;

    // Runtime-generated payloads prevent constant-folding artifacts in ReleaseFast.
    var small_buf: [256]u8 = undefined;
    var medium_buf: [2048]u8 = undefined;

    // Add a run-specific stamp to payload fields.
    var seed_timer = try std.time.Timer.start();
    const stamp = seed_timer.read() % 10_000_000;

    // Small object payload: mostly scalar/object/array mix.
    const small_payload = try std.fmt.bufPrint(
        &small_buf,
        "{{\"id\":{d},\"ok\":true,\"name\":\"alpha\",\"nums\":[1,2,3,4],\"meta\":{{\"a\":\"x\",\"b\":\"y\"}}}}",
        .{stamp},
    );

    // Medium payload: deeper nesting and many object fields.
    const medium_payload = try std.fmt.bufPrint(
        &medium_buf,
        "{{\"users\":[{{\"id\":1,\"name\":\"Ada\",\"active\":true,\"score\":98.5}},{{\"id\":2,\"name\":\"Linus\",\"active\":false,\"score\":87.25}},{{\"id\":3,\"name\":\"Grace\",\"active\":true,\"score\":91.0}}],\"teams\":[{{\"name\":\"infra\",\"members\":[1,2]}},{{\"name\":\"runtime\",\"members\":[2,3]}}],\"events\":[{{\"kind\":\"push\",\"repo\":\"core\",\"ts\":1700000001}},{{\"kind\":\"deploy\",\"repo\":\"api\",\"ts\":1700000100}}],\"flags\":{{\"canary\":true,\"dark_launch\":false}},\"limits\":{{\"qps\":1200,\"burst\":1800}},\"stamp\":{d},\"notes\":\"benchmark-payload-with-enough-shape-to-exercise-objects-arrays-and-strings\"}}",
        .{stamp},
    );

    // Buffered stdout for stable benchmark output behavior.
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const out = &stdout_writer.interface;

    // Run both payload profiles.
    try runCase(out, "small", small_payload, iterations);
    try runCase(out, "medium", medium_payload, @max(iterations / 8, 10_000));
    try out.flush();
}

/// Execute one benchmark case and print formatted ns/op metrics.
fn runCase(out: *std.Io.Writer, name: []const u8, payload: []const u8, iterations: usize) !void {
    const fast_ns = try benchCustomLeaky(payload, iterations);
    const safe_ns = try benchCustomSafe(payload, iterations);
    const std_ns = try benchStdJsonLeaky(payload, iterations);

    const fast_per = nsPerOp(fast_ns, iterations);
    const safe_per = nsPerOp(safe_ns, iterations);
    const std_per = nsPerOp(std_ns, iterations);

    try out.print(
        "{s} ({d} iters): fast={d:.2} ns/op safe={d:.2} ns/op std={d:.2} ns/op fast-vs-std={d:.2}x\n",
        .{ name, iterations, fast_per, safe_per, std_per, std_per / fast_per },
    );
}

/// Fast-path benchmark:
/// - uses `loadsLeaky`
/// - reuses one arena and resets each iteration
fn benchCustomLeaky(payload: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Checksum prevents dead-code elimination.
    var checksum: usize = 0;

    // Start high-resolution timer after setup.
    var timer = try std.time.Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const value = try zig_jsonloads.loadsLeaky(arena.allocator(), payload, .{ .copy_input = false });
        checksum +%= digestCustom(value);

        // Retain arena capacity to minimize allocator churn between iterations.
        _ = arena.reset(.retain_capacity);
    }

    std.mem.doNotOptimizeAway(checksum);
    return timer.read();
}

/// Safe-path benchmark:
/// - uses `loads`
/// - each iteration allocates/deallocates through `ParsedJson` lifecycle
fn benchCustomSafe(payload: []const u8, iterations: usize) !u64 {
    var checksum: usize = 0;
    var timer = try std.time.Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const parsed = try zig_jsonloads.loads(std.heap.page_allocator, payload);
        checksum +%= digestCustom(parsed.value);
        parsed.deinit();
    }

    std.mem.doNotOptimizeAway(checksum);
    return timer.read();
}

/// Zig stdlib baseline benchmark.
fn benchStdJsonLeaky(payload: []const u8, iterations: usize) !u64 {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    var checksum: usize = 0;
    var timer = try std.time.Timer.start();

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        const value = try std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), payload, .{
            .duplicate_field_behavior = .use_last,
        });
        checksum +%= digestStd(value);
        _ = arena.reset(.retain_capacity);
    }

    std.mem.doNotOptimizeAway(checksum);
    return timer.read();
}

/// Recursive digest for custom value type.
///
/// The exact hash quality is not important; this only needs to ensure
/// parsed values are actually consumed.
fn digestCustom(value: zig_jsonloads.JsonValue) usize {
    return switch (value) {
        .null => 0x9E37,
        .bool => |b| if (b) 0xA5 else 0x5A,
        .integer => |iv| switch (iv) {
            .small => |i| @as(usize, @truncate(@as(u64, @bitCast(i)))),
            .big => |b| b.limbs.len *% 2654435761 +% @intFromBool(b.isPositive()),
        },
        .float => |f| @as(usize, @truncate(@as(u64, @bitCast(f)))),
        .string => |s| 0xC3 +% s.len,
        .array => |arr| blk: {
            var acc: usize = arr.items.len;
            for (arr.items) |item| {
                acc +%= digestCustom(item);
            }
            break :blk acc;
        },
        .object => |obj| blk: {
            var acc: usize = obj.count();
            var it = obj.iterator();
            while (it.next()) |entry| {
                acc +%= entry.key_ptr.*.len *% 131;
                acc +%= digestCustom(entry.value_ptr.*);
            }
            break :blk acc;
        },
        .object_pairs => |pairs| blk: {
            var acc: usize = pairs.len;
            for (pairs) |pair| {
                acc +%= pair.key.len *% 131;
                acc +%= digestCustom(pair.value);
            }
            break :blk acc;
        },
    };
}

/// Recursive digest for stdlib dynamic value type.
fn digestStd(value: std.json.Value) usize {
    return switch (value) {
        .null => 0x9E37,
        .bool => |b| if (b) 0xA5 else 0x5A,
        .integer => |i| @as(usize, @truncate(@as(u64, @bitCast(i)))),
        .float => |f| @as(usize, @truncate(@as(u64, @bitCast(f)))),
        .number_string => |s| 0xB1 +% s.len,
        .string => |s| 0xC3 +% s.len,
        .array => |arr| blk: {
            var acc: usize = arr.items.len;
            for (arr.items) |item| {
                acc +%= digestStd(item);
            }
            break :blk acc;
        },
        .object => |obj| blk: {
            var acc: usize = obj.count();
            var it = obj.iterator();
            while (it.next()) |entry| {
                acc +%= entry.key_ptr.*.len *% 131;
                acc +%= digestStd(entry.value_ptr.*);
            }
            break :blk acc;
        },
    };
}

/// Convert total nanoseconds to nanoseconds per operation.
fn nsPerOp(total_ns: u64, iterations: usize) f64 {
    return @as(f64, @floatFromInt(total_ns)) / @as(f64, @floatFromInt(iterations));
}
