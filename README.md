# zig_jsonloads

A high-performance, Python-compatible `json.loads` implementation in Zig.

This project focuses on two priorities:
- Full `json.loads` parity for practical behavior and extension hooks.
- Extremely low parsing latency for hot paths.

## Features

- Python-compatible loader entry points:
- `loads` for text-like input (rejects UTF-8 BOM like Python `str` input).
- `loadsBytes` for bytes-like input with UTF-8/16/32 detection and BOM handling.
- Low-latency variants:
- `loadsBorrowed` (no input copy, caller keeps input alive).
- `loadsLeaky` (caller-managed allocator; ideal for arena reset loops).
- Parity hooks:
- `parse_int`
- `parse_float`
- `parse_constant`
- `object_hook`
- `object_pairs_hook` (takes precedence over `object_hook`, matching Python behavior)
- `decoder` (a `cls`-style override hook)
- Numeric behavior:
- Fast-path `i64` parsing.
- Arbitrary-precision integers via `std.math.big.int.Managed` for larger values.
- String behavior:
- `strict_strings` option for Python-style strict control character rules.
- Unicode escape handling including surrogate pair behavior.
- Parity for non-finite tokens:
- `NaN`, `Infinity`, `-Infinity` handling plus configurable rejection/hook handling.

## Project Layout

- `/Users/beast/zig_jsonloads/src/root.zig`: parser library and tests.
- `/Users/beast/zig_jsonloads/src/main.zig`: small CLI demo.
- `/Users/beast/zig_jsonloads/src/bench.zig`: microbenchmarks against Zig std JSON parser.
- `/Users/beast/zig_jsonloads/scripts/compare_python.py`: Zig vs CPython `json.loads` benchmark script.
- `/Users/beast/zig_jsonloads/build.zig`: build graph and tasks.

## Build And Run

```bash
cd /Users/beast/zig_jsonloads
zig build test
zig build run -- '{"hello":"world"}'
```

## Benchmark

Run internal benchmark:

```bash
zig build bench -Doptimize=ReleaseFast -- 120000
```

Run direct Zig-vs-Python benchmark:

```bash
/Users/beast/zig_jsonloads/scripts/compare_python.py --iterations 120000
```

## API Quick Reference

- `loads(allocator, source)`
- `loadsWithOptions(allocator, source, options)`
- `loadsBytes(allocator, source)`
- `loadsBytesWithOptions(allocator, source, options)`
- `loadsBorrowed(allocator, source)`
- `loadsLeaky(allocator, source, options)`

Core options are in `LoadsOptions`:
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

## Development Notes

- The parser favors low-allocation and branch-efficient paths for common JSON.
- Tests in `src/root.zig` validate parity-sensitive behavior.
- Benchmark output varies run-to-run; compare multiple runs for stable estimates.
