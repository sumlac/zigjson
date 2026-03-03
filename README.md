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

`LoadsOptions` fields:

- `strict_strings`
- `max_depth`
- `copy_input`
- `allow_nan`
- `parse_int`
- `parse_float`
- `parse_constant`
- `object_hook`
- `object_pairs_hook`
- `decoder`

## Benchmark

```bash
zig build bench -Doptimize=ReleaseFast -- 120000
```
