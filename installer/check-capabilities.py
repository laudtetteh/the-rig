#!/usr/bin/env python3
"""Validate The Rig's capability manifest and run allowlisted smoke checks."""
import argparse
import json
import os
import sys

ALLOWED_TYPES = {"exists", "executable", "json-key", "command"}


def load(path):
    try:
        with open(path, encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"cannot load capability manifest: {exc}") from exc
    if data.get("schema_version") != 1:
        raise ValueError("unsupported capability manifest schema_version")
    for capability in data.get("capabilities", []):
        for smoke in capability.get("smoke", []):
            if smoke.get("type") not in ALLOWED_TYPES:
                raise ValueError(f"unknown smoke type: {smoke.get('type')}")
    return data


def smoke(data, layer, agents, root):
    results = []
    selected = set(agents)
    for capability in data.get("capabilities", []):
        if capability.get("layer") != layer or (not capability.get("always") and not selected.intersection(capability.get("agents", []))):
            continue
        for check in capability.get("smoke", []):
            target = os.path.join(root, check["target"])
            kind = check["type"]
            if kind == "exists":
                passed = os.path.exists(target)
            elif kind == "executable":
                passed = os.path.isfile(target) and os.access(target, os.X_OK)
            elif kind == "json-key":
                try:
                    with open(target, encoding="utf-8") as handle:
                        value = json.load(handle)
                    passed = all(part in value for part in check.get("key", "").split(".") if part)
                except (OSError, json.JSONDecodeError):
                    passed = False
            else:  # command: allowlisted argv only, never shell text
                argv = check.get("argv", [])
                passed = argv in [["bin/rig", "--help"]] and os.access(os.path.join(root, argv[0]), os.X_OK)
            results.append({"id": check["id"], "type": kind, "target": check["target"],
                            "required": bool(check.get("required")), "status": "pass" if passed else "fail"})
    return results


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("manifest")
    parser.add_argument("--layer", choices=["global", "project"])
    parser.add_argument("--agents", default="")
    parser.add_argument("--root")
    args = parser.parse_args()
    try:
        data = load(args.manifest)
        results = smoke(data, args.layer, [x for x in args.agents.split(",") if x], args.root) if args.layer else []
        ok = all(item["status"] == "pass" or not item["required"] for item in results)
        print(json.dumps({"ok": ok, "results": results}, separators=(",", ":")))
        return 0 if ok else 1
    except ValueError as exc:
        print(json.dumps({"ok": False, "error": {"code": "capability-manifest-invalid", "message": str(exc)}}))
        return 2


if __name__ == "__main__":
    sys.exit(main())
