#!/usr/bin/env python3
"""Compare Zig parser latency against CPython's json.loads.

This script intentionally keeps the benchmark simple and repeatable:
- it runs `zig build bench` and parses the fast-path numbers
- it runs Python `json.loads` on matching payload shapes
- it fails non-zero if Zig is slower in either case
"""

import argparse
import json
import re
import subprocess
import sys
import timeit

# Small payload: useful for pure parser overhead and branch behavior.
SMALL_PAYLOAD = '{"id":1234567,"ok":true,"name":"alpha","nums":[1,2,3,4],"meta":{"a":"x","b":"y"}}'

# Medium payload: exercises deeper objects/arrays and mixed value types.
MEDIUM_PAYLOAD = (
    '{"users":[{"id":1,"name":"Ada","active":true,"score":98.5},'
    '{"id":2,"name":"Linus","active":false,"score":87.25},'
    '{"id":3,"name":"Grace","active":true,"score":91.0}],'
    '"teams":[{"name":"infra","members":[1,2]},{"name":"runtime","members":[2,3]}],'
    '"events":[{"kind":"push","repo":"core","ts":1700000001},'
    '{"kind":"deploy","repo":"api","ts":1700000100}],'
    '"flags":{"canary":true,"dark_launch":false},'
    '"limits":{"qps":1200,"burst":1800},'
    '"stamp":1234567,'
    '"notes":"benchmark-payload-with-enough-shape-to-exercise-objects-arrays-and-strings"}'
)

# Regex extracts the fast-path line from `zig build bench` output.
BENCH_LINE = re.compile(
    r'^(small|medium) \(\d+ iters\): fast=([0-9.]+) ns/op .* std=([0-9.]+) ns/op',
    re.MULTILINE,
)


def run_zig_bench(iterations: int) -> dict[str, float]:
    """Run Zig benchmark executable and return fast-path ns/op per case."""
    cmd = ["zig", "build", "bench", "-Doptimize=ReleaseFast", "--", str(iterations)]
    result = subprocess.run(cmd, capture_output=True, text=True, check=True)

    parsed: dict[str, float] = {}
    for name, fast_ns, _std_ns in BENCH_LINE.findall(result.stdout):
        # Keep only the custom parser fast-path timing.
        parsed[name] = float(fast_ns)

    if "small" not in parsed or "medium" not in parsed:
        print(result.stdout)
        raise RuntimeError("failed to parse zig bench output")

    return parsed


def run_python_bench(iterations_small: int, iterations_medium: int) -> dict[str, float]:
    """Run CPython json.loads benchmark and return ns/op metrics."""
    small_total = timeit.timeit("json.loads(SMALL_PAYLOAD)", number=iterations_small, globals=globals())
    medium_total = timeit.timeit("json.loads(MEDIUM_PAYLOAD)", number=iterations_medium, globals=globals())

    return {
        "small": (small_total / iterations_small) * 1e9,
        "medium": (medium_total / iterations_medium) * 1e9,
    }


def main() -> int:
    """CLI entry point.

    Returns non-zero if Zig loses to Python in either benchmark case.
    """
    parser = argparse.ArgumentParser(description="Compare Zig fast-path parser against Python json.loads")
    parser.add_argument("--iterations", type=int, default=200_000, help="small-payload iteration count")
    args = parser.parse_args()

    # Keep medium workload lower so total script runtime stays reasonable.
    zig_ns = run_zig_bench(args.iterations)
    py_ns = run_python_bench(args.iterations, max(args.iterations // 8, 10_000))

    print(
        f"small: zig={zig_ns['small']:.2f} ns/op "
        f"python={py_ns['small']:.2f} ns/op "
        f"speedup={py_ns['small']/zig_ns['small']:.2f}x"
    )
    print(
        f"medium: zig={zig_ns['medium']:.2f} ns/op "
        f"python={py_ns['medium']:.2f} ns/op "
        f"speedup={py_ns['medium']/zig_ns['medium']:.2f}x"
    )

    # Regression gate: fail if Zig fast-path loses in either profile.
    if zig_ns["small"] >= py_ns["small"] or zig_ns["medium"] >= py_ns["medium"]:
        print("regression: Zig fast parser is slower than Python for at least one case", file=sys.stderr)
        return 1

    return 0


if __name__ == "__main__":
    sys.exit(main())
