# zig_jsonloads

Python-compatible `json.loads` for Zig.

## Requirements

- Zig `0.15.2` or newer

## Quick Start

Run tests:

```bash
zig build test
```

Run the CLI with a JSON input:

```bash
zig build run -- '{"hello":"world"}'
```

## Library Usage

```zig
const std = @import("std");
const zig_jsonloads = @import("zig_jsonloads");

pub fn main() !void {
    const input = "{\"id\":1,\"name\":\"ada\"}";
    const parsed = try zig_jsonloads.loads(std.heap.page_allocator, input);
    defer parsed.deinit();
}
```

Parse bytes (UTF-8/16/32 with BOM detection):

```zig
const parsed = try zig_jsonloads.loadsBytes(std.heap.page_allocator, bytes);
defer parsed.deinit();
```

Low-latency reusable decoder:

```zig
var decoder = zig_jsonloads.Decoder.init(std.heap.page_allocator);
defer decoder.deinit();

const value = try decoder.decode("{\"x\":1}", .{ .copy_input = false });
_ = value;
decoder.reset();
```

Raw decode (value + end index):

```zig
const decoded = try zig_jsonloads.rawDecode(std.heap.page_allocator, "  [1,2] tail");
defer decoded.deinit();
// decoded.end points to the first byte after the parsed JSON value.
```

Use options:

```zig
const options = zig_jsonloads.LoadsOptions{
    .strict_strings = true,
    .allow_nan = false,
};

const parsed = try zig_jsonloads.loadsWithOptions(
    std.heap.page_allocator,
    input,
    options,
);
defer parsed.deinit();
```

## API

- `loads(allocator, source)`
- `loadsWithOptions(allocator, source, options)`
- `loadsBytes(allocator, source)`
- `loadsBytesWithOptions(allocator, source, options)`
- `loadsBorrowed(allocator, source)`
- `loadsLeaky(allocator, source, options)`
- `rawDecode(allocator, source)`
- `rawDecodeWithOptions(allocator, source, options)`
- `rawDecodeLeaky(allocator, source, options)`
- `loadsDetailed(allocator, source, options)`

`LoadsOptions` fields:

- `strict_strings`
- `max_depth`
- `copy_input`
- `allow_nan`
- `duplicate_key_policy` (`use_last`, `use_first`, `reject`, `collect_pairs`)
- `max_int_digits` (`null` disables limit)
- `parse_int`
- `parse_float`
- `parse_constant`
- `object_hook`
- `object_pairs_hook`
- `decoder`

Detailed diagnostics:

- `loadsDetailed(allocator, source, options)` returns line/column/index/message on parse failure.

## Benchmark

```bash
zig build bench -Doptimize=ReleaseFast -- 120000
```

## Differential Fuzzing

```bash
zig build fuzz-diff -- --cases 2000 --seed 1337
```
