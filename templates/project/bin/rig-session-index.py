#!/usr/bin/env python3
"""Read-only index of Rig session records in bounded project locations."""
import datetime
import hashlib
import json
import os
import pathlib
import re
import stat
import subprocess
import sys

ROOT = pathlib.Path(os.environ["RIG_ROOT"]).absolute()
RIG_DIR = pathlib.Path(os.environ["RIG_DIR"]).absolute()
ARGS = sys.argv[1:]
AS_JSON = "--json" in ARGS
VERBOSE = "--verbose" in ARGS


def fail(reason):
    print(json.dumps({"ok": False, "reason": reason, "sessions": [], "errors": []})
          if AS_JSON else reason, file=sys.stdout if AS_JSON else sys.stderr)
    raise SystemExit(3)


options = {"--root": []}
i = 0
while i < len(ARGS):
    key = ARGS[i]
    if key in ("--json", "--verbose"):
        i += 1
        continue
    if key not in ("--root", "--project", "--provider", "--state", "--search", "--sort"):
        fail("invalid_input")
    if i + 1 >= len(ARGS) or not ARGS[i + 1] or ARGS[i + 1].startswith("--"):
        fail("invalid_input")
    if key == "--root":
        options[key].append(ARGS[i + 1])
    elif key in options:
        fail("invalid_input")
    else:
        options[key] = ARGS[i + 1]
    i += 2
if options.get("--provider") not in (None, "claude", "codex"):
    fail("invalid_input")
if options.get("--sort") not in (None, "created", "activity"):
    fail("invalid_input")


def safe_dir(path):
    """Refuse symlinks in a directory's path, including its parents."""
    for part in (path, *path.parents):
        try:
            if not stat.S_ISDIR(part.lstat().st_mode):
                return False
        except OSError:
            return False
    return True


def identity(project):
    try:
        common = subprocess.check_output(
            ["git", "-C", str(project), "rev-parse", "--git-common-dir"],
            text=True, stderr=subprocess.DEVNULL).strip()
        common = pathlib.Path(common if os.path.isabs(common) else project / common).resolve()
    except (OSError, subprocess.SubprocessError):
        common = project.resolve()
    return hashlib.sha256(str(common).encode()).hexdigest()


def project_dir(project):
    if not safe_dir(project):
        return None, "unsafe_project_root"
    pointer = project / ".rigpath"
    if pointer.exists() or pointer.is_symlink():
        try:
            if not stat.S_ISREG(pointer.lstat().st_mode):
                return None, "unsafe_rigpath"
            value = pointer.read_text().strip()
        except OSError:
            return None, "unsafe_rigpath"
        if not value:
            return None, "invalid_rigpath"
        candidate = pathlib.Path(value)
        if not candidate.is_absolute():
            candidate = project / candidate
    else:
        candidate = project / ".rig"
    if not safe_dir(candidate):
        return None, "unsafe_rig_directory"
    return candidate.resolve(), None


errors = []
native_ids = set()
scopes = {}
skipped_code_symlinks = []


def add_scope(directory, source, project=None):
    if not safe_dir(directory):
        errors.append({"scope": str(directory), "reason": "unsafe_rig_directory"})
        return
    key = directory.resolve()
    if key not in scopes:
        scopes[key] = {"sources": [], "projects": {}}
    scopes[key]["sources"].append(source)
    if project is not None:
        scopes[key]["projects"][identity(project)] = str(project)


def catalog_entries(directory, reason):
    try:
        return sorted(directory.iterdir())
    except OSError:
        errors.append({"scope": str(directory), "reason": reason})
        return []


add_scope(RIG_DIR, "current", ROOT)
code_home = pathlib.Path.home() / "code"
if code_home.exists() or code_home.is_symlink():
    if not safe_dir(code_home):
        errors.append({"scope": str(code_home), "reason": "unsafe_code_catalog"})
    else:
        for child in catalog_entries(code_home, "unreadable_code_catalog"):
            if child.is_symlink():
                skipped_code_symlinks.append(str(child))
            elif child.is_dir() and ((child / ".rig").exists() or
                                     (child / ".rigpath").exists() or
                                     (child / ".rigpath").is_symlink()):
                directory, reason = project_dir(child)
                if reason:
                    errors.append({"scope": str(child), "reason": reason})
                else:
                    add_scope(directory, "code_catalog", child.resolve())
external = pathlib.Path.home() / ".rig" / "projects"
if external.exists() or external.is_symlink():
    if not safe_dir(external):
        errors.append({"scope": str(external), "reason": "unsafe_external_catalog"})
    else:
        for child in catalog_entries(external, "unreadable_external_catalog"):
            if child.is_symlink():
                errors.append({"scope": str(child), "reason": "unsafe_external_project"})
            elif child.is_dir():
                add_scope(child, "external_catalog")
for value in options["--root"]:
    project = pathlib.Path(value).absolute()
    directory, reason = project_dir(project)
    if reason:
        errors.append({"scope": str(project), "reason": reason})
    else:
        add_scope(directory, "explicit_root", project.resolve())
project_filter = options.get("--project")
if project_filter == "current":
    filter_id = identity(ROOT)
elif project_filter:
    project = pathlib.Path(project_filter).absolute()
    if not safe_dir(project):
        fail("invalid_project_filter")
    filter_id = identity(project)
else:
    filter_id = None


def read_record(path):
    # Pin every ancestor as a directory; a path swapped to a symlink after
    # discovery must not redirect this read outside the selected Rig root.
    directory_fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in path.parts[1:-1]:
            child_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                               dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = child_fd
        fd = os.open(path.name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK,
                     dir_fd=directory_fd)
    finally:
        os.close(directory_fd)
    try:
        info = os.fstat(fd)
        if not stat.S_ISREG(info.st_mode):
            raise ValueError("nonregular_record")
        if info.st_size > 1024 * 1024:
            raise ValueError("oversized_record")
        with os.fdopen(fd, "r", encoding="utf-8") as stream:
            fd = -1
            return json.load(stream)
    finally:
        if fd != -1:
            os.close(fd)


def record_error(data):
    if not isinstance(data, dict) or type(data.get("schema_version")) is not int:
        return "malformed_record"
    if data["schema_version"] > 1:
        return "unsupported_schema"
    if data["schema_version"] != 1:
        return "malformed_record"
    if any(not isinstance(data.get(key), dict) for key in ("native", "project", "lifecycle")):
        return "malformed_record"
    if any(key in data and not isinstance(data[key], dict) for key in ("runtime", "names", "lineage")):
        return "malformed_record"
    lineage = data.get("lineage") or {}
    if any(key in lineage and lineage[key] is not None and not isinstance(lineage[key], str)
           for key in ("kind", "parent_anchor", "parent_native_session_id")):
        return "malformed_record"
    for owner, fields in (("names", ("final", "tentative", "display_title")),
                          ("runtime", ("branch",))):
        values = data.get(owner) or {}
        if any(key in values and values[key] is not None and not isinstance(values[key], str)
               for key in fields):
            return "malformed_record"
    project = data["project"]
    if data["native"].get("session_id") is None and project.get("identity") is None:
        return "unbound_record"
    if (not isinstance(data.get("anchor"), str) or
        not re.fullmatch(r"[A-Za-z0-9._-]+", data["anchor"]) or
        data.get("agent") not in ("claude", "codex") or
        not isinstance(data["native"].get("session_id"), str) or
        not data["native"]["session_id"] or
        not isinstance(project.get("identity"), str) or
        not re.fullmatch(r"[0-9a-f]{64}", project["identity"]) or
        not isinstance(project.get("root_realpath"), str) or
        not pathlib.Path(project["root_realpath"]).is_absolute() or
        not isinstance(data["lifecycle"].get("state"), str) or
        type(data.get("revision")) is not int):
        return "malformed_record"
    if not 8 <= len(data["native"]["session_id"]) <= 256:
        return "unsafe_native_id_length"
    if data["lifecycle"]["state"] not in (
            "active", "complete", "inactive", "ended_no_wrap", "orphaned"):
        return "invalid_lifecycle"
    return None


def legacy_error(data):
    if not isinstance(data, dict) or "schema_version" in data:
        return "malformed_record"
    if (not isinstance(data.get("anchor"), str) or
        not re.fullmatch(r"[A-Za-z0-9._-]+", data["anchor"]) or
        not isinstance(data.get("started_at"), str) or
        type(data.get("pid")) is not int or data["pid"] <= 0 or
        data.get("status") not in ("active", "complete", "inactive", "ended_no_wrap", "done") or
        any(key in data and data[key] is not None and not isinstance(data[key], str)
            for key in ("branch", "final_name", "tentative_name"))):
        return "malformed_record"
    return None


def time_value(value):
    if not isinstance(value, str):
        return None
    try:
        value = datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
        return value if value.tzinfo else value.replace(tzinfo=datetime.timezone.utc)
    except ValueError:
        return None


rows = []
coverage = []
for rig_dir, scope in scopes.items():
    sessions = rig_dir / "memory" / "sessions"
    item = {"rig_dir": str(rig_dir), "sources": scope["sources"],
            "record_count": 0, "legacy_count": 0}
    coverage.append(item)
    if not sessions.exists():
        item["status"] = "no_session_directory"
        continue
    if not safe_dir(sessions):
        item["status"] = "unsafe"
        errors.append({"scope": str(sessions), "reason": "unsafe_session_directory"})
        continue
    item["status"] = "indexed"
    bases = [sessions]
    done = sessions / "done"
    if done.exists() or done.is_symlink():
        if safe_dir(done):
            bases.append(done)
        else:
            errors.append({"scope": str(done), "reason": "unsafe_done_directory"})
    for base in bases:
        try:
            candidates = sorted(base.glob("session-*.json"))
        except OSError:
            errors.append({"scope": str(base), "reason": "unreadable_session_directory"})
            continue
        for path in candidates:
            relative = str(path.relative_to(sessions))
            data = None
            try:
                data = read_record(path)
                if isinstance(data, dict) and "schema_version" not in data:
                    reason = legacy_error(data)
                    if reason:
                        raise ValueError(reason)
                    started = time_value(data["started_at"])
                    if started is None:
                        raise ValueError("malformed_timestamp")
                    inferred = list(scope["projects"].items())
                    project_id, project_path = inferred[0] if len(inferred) == 1 else (None, None)
                    row = {"anchor": data["anchor"], "provider": "unknown",
                           "project": project_path, "project_label": rig_dir.name,
                           "project_identity": project_id, "project_verified": False,
                           "name": data.get("final_name") or data.get("tentative_name"),
                           "branch": data.get("branch"), "state": data["status"],
                           "location": "done" if base == done else "active",
                           "created_at": data["started_at"], "last_activity_at": data["started_at"],
                           "provider_live_state": "unknown", "schema": "legacy_pid",
                           "provenance": {"rig_dir": str(rig_dir), "record": relative,
                                          "sources": scope["sources"]},
                           "resume_hint": None, "ambiguous": False, "_created": started,
                           "_activity": started, "_native": None, "_lineage": {}}
                    rows.append(row)
                    item["record_count"] += 1
                    item["legacy_count"] += 1
                    continue
                if isinstance(data, dict) and isinstance(data.get("native"), dict):
                    found_id = data["native"].get("session_id")
                    if isinstance(found_id, str) and 0 < len(found_id) <= 256:
                        native_ids.add(found_id)
                reason = record_error(data)
                if reason:
                    raise ValueError(reason)
                if base == done and data["lifecycle"]["state"] == "active":
                    raise ValueError("invalid_lifecycle")
                project = data["project"]
                if (scope["projects"] and project["identity"] not in scope["projects"] and
                    "external_catalog" not in scope["sources"]):
                    raise ValueError("cross_project_record")
                recorded_root = pathlib.Path(project["root_realpath"])
                if (recorded_root.exists() or recorded_root.is_symlink()) and not safe_dir(recorded_root):
                    raise ValueError("unsafe_project_path")
                verified = safe_dir(recorded_root)
                if verified and identity(recorded_root) != project["identity"]:
                    raise ValueError("cross_project_record")
                native_id = data["native"]["session_id"]
                names = data.get("names") or {}
                runtime = data.get("runtime") or {}
                lifecycle = data["lifecycle"]
                lineage = data.get("lineage") or {}
                created = time_value(data.get("created_at"))
                activity_text = data.get("updated_at")
                activity = time_value(activity_text)
                if activity is None:
                    activity_text = lifecycle.get("last_event_at")
                    activity = time_value(activity_text)
                if created is None or activity is None:
                    raise ValueError("malformed_timestamp")
                def redacted(value):
                    return value.replace(native_id, "<redacted>") if isinstance(value, str) else None
                row = {"anchor": data["anchor"], "provider": data["agent"],
                       "project": str(recorded_root), "project_identity": project["identity"],
                       "project_verified": verified,
                       "name": redacted(names.get("final") or names.get("tentative") or names.get("display_title")),
                       "branch": redacted(runtime.get("branch")), "state": lifecycle["state"],
                       "location": "done" if base == done else "active",
                       "created_at": data["created_at"], "last_activity_at": activity_text,
                       "provider_live_state": "unknown", "schema": "v1",
                       "provenance": {"rig_dir": str(rig_dir), "record": relative,
                                      "sources": scope["sources"]},
                       "resume_hint": "claude --resume" if data["agent"] == "claude" else "codex resume --all",
                       "ambiguous": False, "_created": created, "_activity": activity,
                       "_native": native_id, "_lineage": lineage}
                if VERBOSE:
                    row["native_session_id"] = native_id
                rows.append(row)
                item["record_count"] += 1
            except (OSError, UnicodeError, ValueError, TypeError, RecursionError, json.JSONDecodeError) as exc:
                allowed = {"nonregular_record", "oversized_record", "malformed_record",
                           "unsupported_schema", "cross_project_record", "unsafe_project_path",
                           "malformed_timestamp", "invalid_lifecycle", "unbound_record",
                           "unsafe_native_id_length"}
                reason = str(exc) if isinstance(exc, ValueError) and str(exc) in allowed else "unreadable_record"
                error = {"scope": str(rig_dir), "record": relative, "reason": reason}
                if isinstance(data, dict) and isinstance(data.get("project"), dict):
                    recorded_id = data["project"].get("identity")
                    if isinstance(recorded_id, str) and re.fullmatch(r"[0-9a-f]{64}", recorded_id):
                        error["project_identity"] = recorded_id
                errors.append(error)
anchors = {}
cross_store_anchors = {}
natives = {}
v1_by_anchor = {}
for row in rows:
    anchors.setdefault((row["provenance"]["rig_dir"], row["anchor"]), []).append(row)
    if row["project_identity"]:
        cross_store_anchors.setdefault((row["project_identity"], row["anchor"]), []).append(row)
    if row["schema"] == "v1":
        v1_by_anchor.setdefault((row["provenance"]["rig_dir"], row["anchor"]), []).append(row)
        natives.setdefault((row["project_identity"], row["provider"], row["_native"]), []).append(row)
for group in anchors.values():
    if len(group) > 1:
        for row in group:
            row["ambiguous"] = True
            row["resume_hint"] = None
        for project_id in {row["project_identity"] for row in group}:
            errors.append({"reason": "duplicate_anchor", "anchor": group[0]["anchor"],
                           "project_identity": project_id,
                           "scope": group[0]["provenance"]["rig_dir"]})
for group in cross_store_anchors.values():
    if len({row["provenance"]["rig_dir"] for row in group}) > 1:
        for row in group:
            row["ambiguous"] = True
            row["resume_hint"] = None
        for rig_dir in {row["provenance"]["rig_dir"] for row in group}:
            errors.append({"reason": "duplicate_anchor_cross_store", "anchor": group[0]["anchor"],
                           "project_identity": group[0]["project_identity"],
                           "scope": rig_dir})

# Match the resolver's root/fork/continuation constraints before offering a
# resume hint. An index must never present an invalid graph as unambiguous.
parents = {}
children = {}
invalid = set()
v1_rows = [row for row in rows if row["schema"] == "v1"]
for row in v1_rows:
    lineage = row["_lineage"]
    kind = lineage.get("kind") or "root"
    parent_anchor = lineage.get("parent_anchor")
    if kind == "root":
        if parent_anchor or lineage.get("parent_native_session_id"):
            invalid.add(id(row))
            if parent_anchor:
                invalid.update(id(candidate) for candidate in v1_rows
                               if candidate["provenance"]["rig_dir"] == row["provenance"]["rig_dir"] and
                               candidate["anchor"] == parent_anchor)
    elif kind in ("fork", "continuation"):
        if kind == "fork" and not parent_anchor:
            continue
        candidates = v1_by_anchor.get((row["provenance"]["rig_dir"], parent_anchor), [])
        if len(candidates) != 1:
            invalid.add(id(row))
            continue
        parent = candidates[0]
        if kind == "continuation":
            parents[id(row)] = parent
            children.setdefault(id(parent), []).append(row)
        if (parent["_native"] != lineage.get("parent_native_session_id") or
            parent["project_identity"] != row["project_identity"] or
            parent["provider"] != row["provider"]):
            invalid.add(id(row))
            continue
        if kind == "continuation":
            if parent["state"] not in ("complete", "inactive", "ended_no_wrap", "orphaned"):
                invalid.add(id(row))
    else:
        invalid.add(id(row))
for parent_id, group in children.items():
    if len(group) > 1:
        invalid.add(parent_id)
        invalid.update(id(row) for row in group)
roots = {}
for row in v1_rows:
    seen = set()
    cursor = row
    while id(cursor) in parents:
        if id(cursor) in seen:
            invalid.update(seen)
            break
        seen.add(id(cursor))
        cursor = parents[id(cursor)]
    roots[id(row)] = id(cursor)
components = {}
for row in v1_rows:
    components.setdefault(roots[id(row)], []).append(row)
for members in components.values():
    if (any(id(row) in invalid for row in members) or
        sum(row["state"] == "active" for row in members) > 1 or
        sum(not children.get(id(row)) for row in members) != 1):
        invalid.update(id(row) for row in members)
for row in v1_rows:
    if id(row) in invalid:
        row["ambiguous"] = True
        row["resume_hint"] = None
        errors.append({"reason": "invalid_lineage", "anchor": row["anchor"],
                       "project_identity": row["project_identity"],
                       "scope": row["provenance"]["rig_dir"]})
for group in natives.values():
    if len(group) > 1:
        for row in group:
            row["shared_native_binding"] = True
        if (any(row["ambiguous"] for row in group) or
            len({roots[id(row)] for row in group}) != 1):
            for row in group:
                row["ambiguous"] = True
                row["resume_hint"] = None
            for rig_dir in {row["provenance"]["rig_dir"] for row in group}:
                errors.append({"reason": "duplicate_native_binding",
                               "project_identity": group[0]["project_identity"],
                               "provider": group[0]["provider"], "scope": rig_dir})
for item in coverage:
    item["error_count"] = sum(
        error.get("scope") == item["rig_dir"] or
        error.get("scope", "").startswith(item["rig_dir"] + os.sep)
        for error in errors)
omitted_errors = 0
if filter_id:
    selected_scopes = {str(rig_dir) for rig_dir, scope in scopes.items()
                       if filter_id in scope["projects"]}
    scoped_errors = []
    for error in errors:
        if (error.get("project_identity") == filter_id or
            (error.get("project_identity") is None and
             any(error.get("scope") == selected or
                 error.get("scope", "").startswith(selected + os.sep)
                 for selected in selected_scopes))):
            scoped_errors.append(error)
        else:
            omitted_errors += 1
    errors = scoped_errors
if filter_id:
    rows = [row for row in rows if row["project_identity"] == filter_id]
for option, field in (("--provider", "provider"), ("--state", "state")):
    if option in options:
        rows = [row for row in rows if row[field] == options[option]]
query = options.get("--search", "").casefold()
if query:
    rows = [row for row in rows if query in (row["name"] or "").casefold() or
            query in (row["branch"] or "").casefold()]
rows.sort(key=lambda row: (row["_created" if options.get("--sort") == "created" else "_activity"],
                           row["project"] or row["provenance"]["rig_dir"], row["anchor"]), reverse=True)
for row in rows:
    for key in ("_created", "_activity", "_native", "_lineage"):
        row.pop(key)
result = {"ok": not errors,
          "coverage": {"discovery": "current project, ~/code/*, ~/.rig/projects/*, and explicit --root projects",
                       "scopes": coverage, "omitted_unrelated_errors": omitted_errors,
                       "skipped_code_symlinks": skipped_code_symlinks},
          "sessions": rows, "errors": errors}
if not VERBOSE and native_ids:
    sensitive_fields = {"scope", "record", "rig_dir", "project",
                        "skipped_code_symlinks",
                        "project_label", "name", "branch", "anchor"}
    def scrub(value, field=None):
        if isinstance(value, str) and field in sensitive_fields:
            for native_id in sorted(native_ids, key=len, reverse=True):
                if len(native_id) >= 8:
                    value = value.replace(native_id, "<redacted>")
                else:
                    # A rejected one-letter ID must not rewrite every 'a'
                    # in unrelated projects. Hide only a standalone token.
                    pattern = r"(?<![A-Za-z0-9])" + re.escape(native_id) + r"(?![A-Za-z0-9])"
                    value = re.sub(pattern, "<redacted>", value)
            return value
        if isinstance(value, list):
            return [scrub(item, field) for item in value]
        if isinstance(value, dict):
            return {key: scrub(item, key) for key, item in value.items()}
        return value
    result = scrub(result)
if AS_JSON:
    print(json.dumps(result))
else:
    columns = ("provider", "project", "state", "branch", "name", "anchor")
    if VERBOSE:
        columns += ("native_session_id",)
    for row in result["sessions"]:
        print("  ".join(json.dumps(row.get(key), ensure_ascii=True) for key in columns))
    print("Indexed %d records from %d Rig directories." % (
        len(result["sessions"]), len(result["coverage"]["scopes"])))
    for error in result["errors"]:
        print("ERROR  " + json.dumps(error), file=sys.stderr)
raise SystemExit(0 if not errors else 2)
