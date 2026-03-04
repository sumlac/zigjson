#!/usr/bin/env python3
"""Differential fuzzing harness against CPython json.loads.

This script compares:
- CPython `json.loads(payload)`
- zig_jsonloads via `fuzz_diff` helper binary

On success paths it compares semantic equality by parsing the Zig canonical
output back through Python's json.loads.
"""

from __future__ import annotations

import argparse
import json
import random
import string
import subprocess
import sys
from dataclasses import dataclass
from typing import Any


@dataclass
class CaseResult:
    ok: bool
    payload: str
    reason: str


def random_string(rng: random.Random, max_len: int = 16) -> str:
    alphabet = string.ascii_letters + string.digits + " _-:/"
    n = rng.randint(0, max_len)
    return "".join(rng.choice(alphabet) for _ in range(n))


def random_number_literal(rng: random.Random) -> str:
    mode = rng.randint(0, 4)
    if mode == 0:
        return str(rng.randint(-10_000_000, 10_000_000))
    if mode == 1:
        return f"{rng.randint(-9999,9999)}.{rng.randint(0,999999):06d}".rstrip("0").rstrip(".")
    if mode == 2:
        base = f"{rng.randint(1,999)}.{rng.randint(0,999):03d}".rstrip("0").rstrip(".")
        exp = rng.randint(-30, 30)
        sign = "+" if exp >= 0 and rng.random() < 0.5 else ""
        return f"{base}e{sign}{exp}"
    if mode == 3:
        # Large integer path to exercise big-int parity.
        digits = "".join(str(rng.randint(0, 9)) for _ in range(rng.randint(25, 80)))
        digits = "1" + digits[1:]  # avoid leading zero
        return digits
    return str(rng.randint(-2**31, 2**31 - 1))


def random_json_obj(rng: random.Random, depth: int) -> Any:
    if depth <= 0:
        leaf_mode = rng.randint(0, 5)
        if leaf_mode == 0:
            return None
        if leaf_mode == 1:
            return bool(rng.randint(0, 1))
        if leaf_mode == 2:
            return random_string(rng)
        if leaf_mode == 3:
            return int(random_number_literal(rng).split(".", 1)[0].split("e", 1)[0])
        if leaf_mode == 4:
            return rng.uniform(-1e6, 1e6)
        return []

    mode = rng.randint(0, 5)
    if mode <= 1:
        return random_json_obj(rng, 0)
    if mode == 2:
        return [random_json_obj(rng, depth - 1) for _ in range(rng.randint(0, 6))]
    if mode == 3:
        obj = {}
        for _ in range(rng.randint(0, 6)):
            obj[random_string(rng, 8)] = random_json_obj(rng, depth - 1)
        return obj
    if mode == 4:
        return random_string(rng, 64)
    return rng.uniform(-1e8, 1e8)


def make_valid_payload(rng: random.Random) -> str:
    # 20% chance: manually build duplicate-key object for parity checks.
    if rng.random() < 0.2:
        key = random_string(rng, 5) or "x"
        v1 = random_number_literal(rng)
        v2 = random_number_literal(rng)
        tail_key = random_string(rng, 5) or "y"
        tail_val = json.dumps(random_json_obj(rng, 2), ensure_ascii=False, separators=(",", ":"))
        return f'{{"{key}":{v1},"{key}":{v2},"{tail_key}":{tail_val}}}'

    obj = random_json_obj(rng, depth=3)
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def make_invalid_payload(rng: random.Random) -> str:
    base = make_valid_payload(rng)
    mode = rng.randint(0, 5)
    if mode == 0 and len(base) > 1:
        return base[:-1]
    if mode == 1:
        return base + ","
    if mode == 2:
        return base.replace(":", "::", 1)
    if mode == 3:
        return base.replace('"', "", 1)
    if mode == 4:
        return base + " trailing"
    return "[" + base


def run_zig(zig_bin: str, payload: str) -> tuple[bool, Any, str]:
    proc = subprocess.run([zig_bin, payload], capture_output=True, text=True)
    if proc.returncode != 0:
        return False, None, f"zig helper failed rc={proc.returncode}: {proc.stderr.strip()}"

    out = proc.stdout.strip()
    if out.startswith("ERR:"):
        return False, None, out

    try:
        parsed = json.loads(out)
    except Exception as exc:  # pylint: disable=broad-except
        return False, None, f"zig emitted non-json canonical output: {out!r} ({exc})"

    return True, parsed, ""


def run_case(zig_bin: str, payload: str) -> CaseResult:
    py_ok = True
    py_obj = None
    try:
        py_obj = json.loads(payload)
    except Exception:  # pylint: disable=broad-except
        py_ok = False

    zig_ok, zig_obj, zig_reason = run_zig(zig_bin, payload)

    if py_ok != zig_ok:
        return CaseResult(
            ok=False,
            payload=payload,
            reason=f"parse mismatch python_ok={py_ok} zig_ok={zig_ok} zig={zig_reason}",
        )

    if not py_ok and not zig_ok:
        return CaseResult(ok=True, payload=payload, reason="")

    if py_obj != zig_obj:
        return CaseResult(
            ok=False,
            payload=payload,
            reason=f"value mismatch python={py_obj!r} zig={zig_obj!r}",
        )

    return CaseResult(ok=True, payload=payload, reason="")


def main() -> int:
    parser = argparse.ArgumentParser(description="Differential fuzz zig_jsonloads vs CPython json.loads")
    parser.add_argument("--zig-bin", default="zig-out/bin/fuzz_diff", help="path to fuzz_diff helper binary")
    parser.add_argument("--cases", type=int, default=1200, help="number of random cases to run")
    parser.add_argument("--seed", type=int, default=1337, help="rng seed")
    args = parser.parse_args()

    rng = random.Random(args.seed)
    failures: list[CaseResult] = []

    for i in range(args.cases):
        payload = make_valid_payload(rng) if rng.random() < 0.75 else make_invalid_payload(rng)
        result = run_case(args.zig_bin, payload)
        if not result.ok:
            failures.append(result)
            if len(failures) >= 25:
                break
        if (i + 1) % 200 == 0:
            print(f"progress: {i + 1}/{args.cases} failures={len(failures)}")

    if failures:
        print(f"FAIL: {len(failures)} mismatches detected")
        for idx, fail in enumerate(failures[:10], start=1):
            print(f"{idx}. {fail.reason}")
            print(f"   payload={fail.payload}")
        return 1

    print(f"PASS: {args.cases} differential cases matched (seed={args.seed})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
