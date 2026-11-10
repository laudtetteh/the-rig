#!/usr/bin/env python3
# Read-only session identity resolver invoked by bin/rig.
import hashlib, json, os, pathlib, subprocess, sys
root = pathlib.Path(os.environ["RIG_ROOT"])
session_dir = pathlib.Path(os.environ["RIG_DIR"]) / "memory" / "sessions"
args = sys.argv[1:]
def confined_session_path(value):
    """Return a canonical session path only when it stays in sessions/."""
    if not value:
        return None
    try:
        candidate = pathlib.Path(value)
        if not candidate.is_absolute():
            candidate = pathlib.Path.cwd() / candidate
        sessions_root = session_dir.resolve()
        resolved = candidate.resolve(strict=False)
        resolved.relative_to(sessions_root)
        if resolved == sessions_root:
            return None
        # Reject symlinks in the file path, including dangling final links.
        probe = candidate
        while True:
            if probe.is_symlink():
                if probe == candidate:
                    return None
                try:
                    probe.resolve(strict=False).relative_to(sessions_root)
                    return None
                except ValueError:
                    pass
            if probe.parent == probe:
                break
            probe = probe.parent
        if candidate.exists() and not candidate.is_file():
            return None
        return resolved
    except (OSError, ValueError, RuntimeError):
        return None
def option(name):
    try: return args[args.index(name) + 1]
    except (ValueError, IndexError): return ""
agent, native_id = option("--agent"), option("--native-session-id")
verbose = "--verbose" in args
def project_identity():
    try:
        common = subprocess.check_output(["git", "-C", str(root), "rev-parse", "--git-common-dir"], text=True, stderr=subprocess.DEVNULL).strip()
        common = pathlib.Path(common if os.path.isabs(common) else root / common).resolve()
        return hashlib.sha256(str(common).encode()).hexdigest()
    except (OSError, subprocess.SubprocessError):
        return hashlib.sha256(str(root.resolve()).encode()).hexdigest()
project_id = project_identity()
def valid_v1_shapes(data):
    if data.get("schema_version") != 1:
        return True
    return (all(isinstance(data.get(key), dict) for key in ("native", "project", "lifecycle")) and
            all(key not in data or isinstance(data[key], dict)
                for key in ("runtime", "lineage", "migration", "names")) and
            all(value is None or isinstance(value, str) for value in
                (data.get("anchor"), data.get("agent"), data["native"].get("session_id"),
                 data["project"].get("identity"), data["lifecycle"].get("state"),
                 (data.get("lineage") or {}).get("parent_anchor"))))
def load(path):
    try:
        data = json.loads(path.read_text())
        if not isinstance(data, dict): return None
        # Sparse v1 records may omit optional objects, but present ones must be maps.
        return data if valid_v1_shapes(data) else None
    except (OSError, ValueError, TypeError): return None
def original_active_path(data):
    recorded = (data.get("runtime") or {}).get("completed_from")
    if recorded:
        if not isinstance(recorded, str):
            return None
        return confined_session_path(recorded)
    # Older launcher-bound records retained their initial PID and anchor.
    legacy_pid = (data.get("migration") or {}).get("legacy_pid")
    anchor = data.get("anchor")
    if (data.get("native") or {}).get("source") == "launcher_hint" and str(legacy_pid).isdigit() and isinstance(anchor, str):
        return confined_session_path(str(session_dir / ("session-" + str(legacy_pid) + "-" + anchor + ".json")))
    return None
def emit(path, data, confidence, reason):
    lifecycle = data.get("lifecycle", {}) if data else {}
    public_lineage = dict(data.get("lineage") or {}) if data else None
    if public_lineage and public_lineage.get("parent_native_session_id") and not verbose:
        public_lineage["parent_native_session_id"] = "<redacted>"
    out = {"ok": confidence == "exact", "schema_version": 1,
           "session_file": str(path) if path else None, "anchor": data.get("anchor") if data else None,
           "agent": data.get("agent") if data else None,
           "branch": (data.get("runtime", {}).get("branch") or data.get("branch")) if data else None,
           "state": lifecycle.get("state", data.get("status")) if data else None,
           "confidence": confidence, "reason": reason,
           "native_session_id": (data.get("native", {}).get("session_id") if verbose and data else None),
           "revision": data.get("revision") if data else None,
           "lineage": public_lineage,
           "parent_anchor": (data.get("lineage") or {}).get("parent_anchor") if data else None,
           "warnings": []}
    if reason in ("unsupported_schema", "invalid_native_binding", "ambiguous_native_provider",
                  "invalid_continuation_lineage", "duplicate_native_id", "invalid_lifecycle_transition",
                  "invalid_session_anchor"):
        out["no_write"] = True
    if reason in ("not_found", "invalid_launcher_file", "ended_record"):
        if agent:
            env_name = "CODEX_THREAD_ID" if agent == "codex" else "CLAUDE_CODE_SESSION_ID"
            recovery_agent = agent if os.environ.get(env_name) == native_id else None
        else:
            recovery_agent = "codex" if os.environ.get("CODEX_THREAD_ID") else "claude" if os.environ.get("CLAUDE_CODE_SESSION_ID") else None
        if recovery_agent:
            out["recovery"] = f"bin/rig session retrofit --agent {recovery_agent} --from-env --source resume --json"
    if "--json" in sys.argv[1:]:
        print(json.dumps(out))
    elif path:
        print(path)
    else:
        print(f"session not resolved: {reason} (confidence: {confidence})", file=sys.stderr)
if bool(agent) != bool(native_id) or (agent and agent not in ("claude", "codex")):
    emit(None, None, "none", "invalid_input"); raise SystemExit(3)
records = []
malformed = False
unsupported = False
unsafe_path = False
ended_states = ("complete", "inactive", "ended_no_wrap", "orphaned")
for base in (session_dir, session_dir / "done"):
    if base.is_dir():
        for p in base.glob("session-*.json"):
            if confined_session_path(str(p)) is None:
                unsafe_path = True
                continue
            d = load(p)
            if d is None: malformed = True
            elif isinstance(d.get("schema_version"), int) and d["schema_version"] > 1: unsupported = True
            else: records.append((p, d))
def lineage_graph(items):
    nodes = [(p, d) for p, d in items if d.get("schema_version") == 1 and isinstance(d.get("anchor"), str) and d.get("anchor")]
    by_anchor = {}
    for p, d in nodes:
        by_anchor.setdefault(d["anchor"], []).append((p, d))
    invalid = {anchor for anchor, values in by_anchor.items() if len(values) != 1}
    invalid_lifecycle = {d["anchor"] for p, d in nodes
                         if d.get("lifecycle", {}).get("state") not in (*ended_states, "active") or
                         (p.parent == session_dir / "done" and d.get("lifecycle", {}).get("state") == "active")}
    invalid.update(invalid_lifecycle)
    invalid.update(d["anchor"] for _, d in nodes if not d.get("native", {}).get("session_id"))
    parents, children = {}, {}
    for _, d in nodes:
        anchor = d["anchor"]
        lineage = d.get("lineage") or {}
        kind = lineage.get("kind") or "root"
        if kind == "root":
            if lineage.get("parent_anchor") or lineage.get("parent_native_session_id"):
                invalid.add(anchor)
                if lineage.get("parent_anchor") in by_anchor:
                    invalid.add(lineage["parent_anchor"])
            continue
        if kind == "fork":
            fork_parent = lineage.get("parent_anchor")
            if fork_parent:
                parent_entries = by_anchor.get(fork_parent, [])
                if (len(parent_entries) != 1 or
                    parent_entries[0][1].get("native", {}).get("session_id") != lineage.get("parent_native_session_id") or
                    parent_entries[0][1].get("project", {}).get("identity") != d.get("project", {}).get("identity") or
                    parent_entries[0][1].get("agent") != d.get("agent")):
                    invalid.add(anchor)
            continue
        if kind != "continuation":
            invalid.add(anchor)
            continue
        parent_anchor = lineage.get("parent_anchor")
        parent_entries = by_anchor.get(parent_anchor, [])
        if len(parent_entries) != 1:
            invalid.add(anchor)
            continue
        parent = parent_entries[0][1]
        parents[anchor] = parent_anchor
        children.setdefault(parent_anchor, []).append(anchor)
        if (not parent.get("native", {}).get("session_id") or
                parent.get("lifecycle", {}).get("state") not in ended_states or
                parent.get("project", {}).get("identity") != d.get("project", {}).get("identity") or
                parent.get("agent") != d.get("agent") or
                parent.get("native", {}).get("session_id") != lineage.get("parent_native_session_id")):
            invalid.add(anchor)
    for parent_anchor, child_anchors in children.items():
        if len(child_anchors) > 1:
            invalid.update([parent_anchor, *child_anchors])
    roots, depths = {}, {}
    for anchor in by_anchor:
        visited = []
        cursor = anchor
        while cursor in parents and cursor not in visited:
            visited.append(cursor)
            cursor = parents[cursor]
        if cursor in visited:
            invalid.update(visited)
            cursor = min(visited)
        roots[anchor] = cursor
        depths[anchor] = len(visited)
    components = {}
    for anchor, root_anchor in roots.items():
        components.setdefault(root_anchor, []).append(anchor)
    leaves = {}
    for root_anchor, members in components.items():
        if invalid.intersection(members) or sum(
                by_anchor[anchor][0][1].get("lifecycle", {}).get("state") == "active"
                for anchor in members) > 1:
            invalid.update(members)
        leaf_members = [anchor for anchor in members if not children.get(anchor)]
        if len(leaf_members) == 1:
            leaves[root_anchor] = leaf_members[0]
        else:
            invalid.update(members)
    native_groups = {}
    for _, d in nodes:
        native_id = d.get("native", {}).get("session_id")
        if native_id:
            key = (d.get("project", {}).get("identity"), d.get("agent"), native_id)
            native_groups.setdefault(key, []).append(d["anchor"])
    duplicate_native = set()
    for anchors in native_groups.values():
        if len(anchors) > 1 and len({roots.get(anchor) for anchor in anchors}) != 1:
            duplicate_native.update(anchors)
    return {"invalid_anchors": sorted(invalid), "invalid_lifecycle_anchors": sorted(invalid_lifecycle),
            "duplicate_native_anchors": sorted(duplicate_native),
            "roots": roots, "depths": depths, "leaves": leaves}
if "--graph-check" in args:
    if unsafe_path or unsupported or malformed:
        reason = "invalid_session_path" if unsafe_path else "unsupported_schema" if unsupported else "malformed_record"
        print(json.dumps({"ok": False, "reason": reason, "no_write": True})); raise SystemExit(4)
    candidate_path = option("--candidate-path")
    if candidate_path:
        try:
            candidate = json.load(sys.stdin)
            if not isinstance(candidate, dict): raise ValueError("candidate is not an object")
        except (ValueError, TypeError):
            print(json.dumps({"ok": False, "reason": "invalid_input", "no_write": True})); raise SystemExit(3)
        records = [(p, d) for p, d in records if str(p) != candidate_path]
        records.append((pathlib.Path(candidate_path), candidate))
    analysis = lineage_graph(records)
    analysis["ok"] = not analysis["invalid_anchors"] and not analysis["duplicate_native_anchors"]
    print(json.dumps(analysis))
    raise SystemExit(0 if analysis["ok"] else 2)
graph = lineage_graph(records)
def graph_conflict(matches):
    anchors = [d.get("anchor") for _, d in matches]
    if len(matches) > 1 and (any(anchor in graph["invalid_anchors"] or anchor in graph["duplicate_native_anchors"]
                                 for anchor in anchors) or len({graph["roots"].get(anchor) for anchor in anchors}) > 1):
        return "duplicate_native_id"
    if any(anchor in graph["invalid_lifecycle_anchors"] for anchor in anchors):
        return "invalid_lifecycle_transition"
    if any(anchor in graph["invalid_anchors"] for anchor in anchors):
        return "invalid_continuation_lineage"
    if any(anchor in graph["duplicate_native_anchors"] for anchor in anchors):
        return "duplicate_native_id"
    return None
def require_valid_graph(matches):
    if any(d.get("schema_version") == 1 and not d.get("anchor") for _, d in matches):
        emit(None, None, "none", "invalid_session_anchor"); raise SystemExit(3)
    reason = graph_conflict(matches)
    if reason:
        emit(None, None, "ambiguous" if reason != "invalid_lifecycle_transition" else "none", reason)
        raise SystemExit(3 if reason == "invalid_lifecycle_transition" else 2)
def select_unique_match(matches):
    if not matches or graph_conflict(matches):
        return None
    return max(matches, key=lambda item: graph["depths"].get(item[1].get("anchor"), 0))
if native_id:
    if unsafe_path: emit(None, None, "none", "invalid_session_path"); raise SystemExit(4)
    if unsupported: emit(None, None, "none", "unsupported_schema"); raise SystemExit(4)
    if malformed: emit(None, None, "none", "malformed_record"); raise SystemExit(4)
    matches = [(p,d) for p,d in records if d.get("schema_version") == 1 and
               d.get("project", {}).get("identity") == project_id and d.get("agent") == agent and
               d.get("native", {}).get("session_id") == native_id]
    if matches: require_valid_graph(matches)
    if len(matches) > 1:
        selected = select_unique_match(matches)
        if selected: matches = [selected]
        else: emit(None, None, "ambiguous", "duplicate_native_id"); raise SystemExit(2)
    if len(matches) == 1:
        p,d = matches[0]
        state = d.get("lifecycle", {}).get("state")
        if state in ended_states:
            emit(None, None, "none", "ended_record"); raise SystemExit(3)
        if "done" in p.parts or state != "active":
            emit(None, None, "none", "invalid_lifecycle_transition"); raise SystemExit(3)
        emit(p,d,"exact","native_id"); raise SystemExit(0)
    cross = [(p,d) for p,d in records if d.get("schema_version") == 1 and d.get("agent") == agent and d.get("native", {}).get("session_id") == native_id]
    emit(None, None, "none", "cross_project" if cross else "not_found"); raise SystemExit(3 if cross else 1)
env_file = os.environ.get("RIG_SESSION_FILE")
if "RIG_SESSION_FILE" in os.environ:
    p = confined_session_path(env_file)
    d = load(p) if p else None
    if p and p.exists() and d is None:
        emit(None, None, "none", "malformed_record"); raise SystemExit(4)
    if d and isinstance(d.get("schema_version"), int) and d["schema_version"] > 1:
        emit(None, None, "none", "unsupported_schema"); raise SystemExit(4)
    # A raw child can inherit its parent's launcher path and native ID.
    if os.environ.get("CODEX_THREAD_ID") and os.environ.get("CLAUDE_CODE_SESSION_ID"):
        emit(None, None, "ambiguous", "ambiguous_native_provider"); raise SystemExit(2)
    state = d.get("lifecycle", {}).get("state", d.get("status")) if d else None
    if p and d and state == "active" and "done" not in p.parts:
        expected_anchor = os.environ.get("RIG_SESSION_ANCHOR")
        if expected_anchor is not None and expected_anchor != d.get("anchor"):
            emit(None, None, "none", "launcher_anchor_conflict"); raise SystemExit(3)
        if d.get("schema_version") == 1 and d.get("project", {}).get("identity") != project_id:
            emit(None, None, "none", "cross_project"); raise SystemExit(3)
        if d.get("schema_version") == 1 and not d.get("native", {}).get("session_id"):
            emit(None, None, "none", "invalid_native_binding"); raise SystemExit(3)
        if d.get("schema_version") == 1: require_valid_graph([(p, d)])
        native_agent = "codex" if os.environ.get("CODEX_THREAD_ID") else "claude" if os.environ.get("CLAUDE_CODE_SESSION_ID") else None
        native_env_id = os.environ.get("CODEX_THREAD_ID") or os.environ.get("CLAUDE_CODE_SESSION_ID")
        if native_agent and (d.get("schema_version") != 1 or d.get("project", {}).get("identity") != project_id or
                             d.get("agent") != native_agent or d.get("native", {}).get("session_id") != native_env_id):
            emit(None, None, "none", "native_conflict"); raise SystemExit(3)
        emit(p, d, "exact", "launcher_file"); raise SystemExit(0)
    # The launcher can keep exporting an ended record's original path. A
    # completed record moves into done/; SessionEnd leaves an inactive record
    # at that path, and an orphaned record remains there too. Require the
    # original anchor and one exact active leaf.
    expected_anchor = os.environ.get("RIG_SESSION_ANCHOR")
    if p and expected_anchor and (not p.exists() or (d and state in ("inactive", "ended_no_wrap", "orphaned") and "done" not in p.parts)):
        if unsafe_path: emit(None, None, "none", "invalid_session_path"); raise SystemExit(4)
        if unsupported: emit(None, None, "none", "unsupported_schema"); raise SystemExit(4)
        if malformed: emit(None, None, "none", "malformed_record"); raise SystemExit(4)
        origins = [(q, record) for q, record in records if record.get("schema_version") == 1 and
                   (("done" in q.parts and record.get("lifecycle", {}).get("state") == "complete" and
                     original_active_path(record) == p) or
                    (q.resolve() == p and record.get("lifecycle", {}).get("state") in ("inactive", "ended_no_wrap", "orphaned")))]
        if len(origins) > 1:
            emit(None, None, "ambiguous", "duplicate_launcher_origin"); raise SystemExit(2)
        if origins:
            _, origin = origins[0]
            if origin.get("anchor") != expected_anchor:
                emit(None, None, "none", "launcher_anchor_conflict"); raise SystemExit(3)
            if origin.get("project", {}).get("identity") != project_id:
                emit(None, None, "none", "cross_project"); raise SystemExit(3)
            origin_agent = origin.get("agent")
            origin_native_id = origin.get("native", {}).get("session_id")
            if not origin_native_id or origin_agent not in ("claude", "codex"):
                emit(None, None, "none", "invalid_launcher_file"); raise SystemExit(3)
            native_env_signals = [("codex", os.environ.get("CODEX_THREAD_ID")),
                                  ("claude", os.environ.get("CLAUDE_CODE_SESSION_ID"))]
            if any(value and (env_agent != origin_agent or value != origin_native_id)
                   for env_agent, value in native_env_signals):
                emit(None, None, "none", "native_conflict"); raise SystemExit(3)
            same_native = [(q, record) for q, record in records if record.get("schema_version") == 1 and
                           record.get("agent") == origin_agent and record.get("native", {}).get("session_id") == origin_native_id]
            if any(record.get("project", {}).get("identity") != project_id for _, record in same_native):
                emit(None, None, "none", "cross_project"); raise SystemExit(3)
            require_valid_graph(same_native)
            selected = select_unique_match(same_native)
            if not selected:
                emit(None, None, "ambiguous", "duplicate_native_id"); raise SystemExit(2)
            active_path, active_record = selected
            if active_record.get("lifecycle", {}).get("state") in ended_states:
                emit(None, None, "none", "ended_record"); raise SystemExit(3)
            if "done" in active_path.parts or active_record.get("lifecycle", {}).get("state") != "active":
                emit(None, None, "none", "invalid_lifecycle_transition"); raise SystemExit(3)
            emit(active_path, active_record, "exact", "launcher_continuation"); raise SystemExit(0)
    emit(None, None, "none", "invalid_launcher_file"); raise SystemExit(3)
if unsupported: emit(None, None, "none", "unsupported_schema"); raise SystemExit(4)
if malformed: emit(None, None, "none", "malformed_record"); raise SystemExit(4)
# Claude Code and Codex both expose native session identity through process
# environment variables, and every subprocess they spawn (hooks, and every
# ad-hoc tool-call shell) inherits those values via normal fork/exec — unlike
# RIG_SESSION_FILE/ANCHOR, which a hook script can only export into its own
# short-lived process, or the PID-sentinel scheme below, which breaks once a
# caller is more than one process hop from the PID that wrote it (e.g. a
# tool-call shell nested inside the `bin/rig` interpreter and an embedded
# python3). This is a genuine native identity signal, not an inferred one, so
# it is tried before the legacy anchor/PID fallbacks. A record naming a
# different project is a definitive cross_project answer, not a reason to keep
# guessing via PID. No matching v1 record at all is not a contradiction
# (older-schema records or a not-yet-native-bound project are still valid) so
# that case falls through unchanged to the legacy fallbacks below.
native_env_signals = []
if os.environ.get("CODEX_THREAD_ID"):
    native_env_signals.append(("codex", os.environ.get("CODEX_THREAD_ID")))
if os.environ.get("CLAUDE_CODE_SESSION_ID"):
    native_env_signals.append(("claude", os.environ.get("CLAUDE_CODE_SESSION_ID")))
# With no exact provider/ID or launcher file, two ambient IDs cannot identify
# which host owns this process.
if len(native_env_signals) > 1:
    emit(None, None, "ambiguous", "ambiguous_native_provider"); raise SystemExit(2)
def fallback_native_conflict(data):
    return (data.get("schema_version") == 1 and native_env_signals and
            (data["project"].get("identity") != project_id or
             any(data.get("agent") != env_agent or data["native"].get("session_id") != env_id
                 for env_agent, env_id in native_env_signals)))
for native_env_agent, native_env_id in native_env_signals:
    matches = [(p, d) for p, d in records if d.get("schema_version") == 1 and
               d.get("project", {}).get("identity") == project_id and d.get("agent") == native_env_agent and
               d.get("native", {}).get("session_id") == native_env_id]
    if matches: require_valid_graph(matches)
    if len(matches) > 1:
        selected = select_unique_match(matches)
        if selected: matches = [selected]
        else: emit(None, None, "ambiguous", "duplicate_native_id"); raise SystemExit(2)
    if len(matches) == 1:
        p, d = matches[0]
        state = d.get("lifecycle", {}).get("state")
        if state in ended_states:
            emit(None, None, "none", "ended_record"); raise SystemExit(3)
        if "done" in p.parts or state != "active":
            emit(None, None, "none", "invalid_lifecycle_transition"); raise SystemExit(3)
        emit(p, d, "exact", "native_id"); raise SystemExit(0)
    cross = [(p, d) for p, d in records if d.get("schema_version") == 1 and d.get("agent") == native_env_agent and d.get("native", {}).get("session_id") == native_env_id]
    if cross: emit(None, None, "none", "cross_project"); raise SystemExit(3)
files = [(p,d) for p,d in records if "done" not in p.parts and d.get("lifecycle", {}).get("state", d.get("status")) == "active"]
explicit_anchor = "RIG_SESSION_ANCHOR" in os.environ
anchor = os.environ.get("RIG_SESSION_ANCHOR", "")
pid_text = os.environ.get("RIG_SESSION_PID") or str(os.getppid())
if not anchor and pid_text.isdigit():
    try: anchor = (pathlib.Path("/tmp") / (".rig-session-" + pid_text + ".uuid")).read_text().strip()
    except OSError: pass
if anchor:
    matches = [(p,d) for p,d in files if d.get("anchor") == anchor]
    if len(matches) == 1:
        p,d = matches[0]
        if fallback_native_conflict(d): emit(None, None, "none", "native_conflict"); raise SystemExit(3)
        if d.get("schema_version") == 1: require_valid_graph(matches)
        emit(p,d,"exact","anchor"); raise SystemExit(0)
    if len(matches) > 1: emit(None, None, "ambiguous", "duplicate_anchor"); raise SystemExit(2)
    if explicit_anchor: emit(None, None, "none", "launcher_anchor_not_found"); raise SystemExit(3)
elif explicit_anchor:
    emit(None, None, "none", "invalid_launcher_anchor"); raise SystemExit(3)
if pid_text.isdigit():
    direct = session_dir / ("session-" + pid_text + ".json"); d = load(direct)
    if d:
        if fallback_native_conflict(d): emit(None, None, "none", "native_conflict"); raise SystemExit(3)
        if d.get("schema_version") == 1: require_valid_graph([(direct, d)])
        emit(direct, d, "exact", "pid"); raise SystemExit(0)
emit(None, None, "none", "not_found"); raise SystemExit(1)
