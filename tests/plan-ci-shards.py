#!/usr/bin/env python3
"""Plan GitHub Actions Bats shards from per-file timing weights."""

import argparse
import glob
import json
import math
import sys


def load_weights(path):
    with open(path) as fh:
        data = json.load(fh)
    default = float(data.get("_default", 5.0))
    weights = {key: float(value) for key, value in data.items() if not key.startswith("_")}
    return default, weights


def verify_explicit_weights(files, weights):
    missing = [path for path in files if path not in weights]
    if not missing:
        return True
    print(
        json.dumps(
            {"ok": False, "missing_weights": missing},
            separators=(",", ":"),
        ),
        file=sys.stderr,
    )
    return False


def plan(files, weights, default_weight, shard_count):
    shards = [{"shard": i, "files": [], "weight": 0.0} for i in range(shard_count)]
    weighted_files = sorted(
        ((weights.get(path, default_weight), path) for path in files),
        key=lambda item: (-item[0], item[1]),
    )
    for weight, path in weighted_files:
        target = min(shards, key=lambda shard: (shard["weight"], shard["shard"]))
        target["files"].append(path)
        target["weight"] += weight
    for shard in shards:
        shard["files"].sort()
        shard["file_list"] = " ".join(shard["files"])
        shard["weight"] = round(shard["weight"], 1)
    return shards


def verify_exact_once(files, shards):
    expected = sorted(files)
    actual = sorted(path for shard in shards for path in shard["files"])
    if actual != expected:
        missing = sorted(set(expected) - set(actual))
        duplicate = sorted(path for path in set(actual) if actual.count(path) > 1)
        extra = sorted(set(actual) - set(expected))
        print(
            json.dumps(
                {"ok": False, "missing": missing, "duplicate": duplicate, "extra": extra},
                separators=(",", ":"),
            ),
            file=sys.stderr,
        )
        return False
    return True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--weights", default="tests/.ci-shard-weights.json")
    parser.add_argument("--pattern", default="tests/*.bats")
    parser.add_argument("--shards", type=int, default=8)
    parser.add_argument("--target-seconds", type=float)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    files = sorted(glob.glob(args.pattern))
    if not files:
        raise SystemExit("no Bats test files matched")

    default_weight, weights = load_weights(args.weights)
    if not verify_explicit_weights(files, weights):
        return 1

    shard_count = args.shards
    if args.target_seconds:
        total = sum(weights.get(path, default_weight) for path in files)
        shard_count = max(1, int(math.ceil(total / args.target_seconds)))

    shards = plan(files, weights, default_weight, shard_count)
    if not verify_exact_once(files, shards):
        return 1

    matrix = {
        "include": [
            {"shard": shard["shard"], "files": shard["file_list"], "weight": shard["weight"]}
            for shard in shards
            if shard["files"]
        ]
    }
    if args.check:
        print(f"OK: {len(files)} test files assigned exactly once across {len(matrix['include'])} shards.")
    else:
        print(json.dumps(matrix, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
