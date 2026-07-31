#!/usr/bin/env python3
import json, sys
try:
    with open(sys.argv[1], encoding="utf-8") as handle: state = json.load(handle)
except (OSError, json.JSONDecodeError): sys.exit(2)
if state.get("schema_version") != 1: sys.exit(3)
agents = state.get("agents")
if not isinstance(agents, list) or any(x not in ("claude", "codex") for x in agents) or len(agents) != len(set(agents)): sys.exit(2)
if agents == []: print("none")
elif agents == ["claude"]: print("claude")
elif agents == ["codex"]: print("codex")
elif set(agents) == {"claude", "codex"}: print("both")
else: sys.exit(2)
