#!/usr/bin/env python3
"""Write the shared snapshot without discarding another session's handoff."""

import argparse
import contextlib
import datetime
import errno
import fcntl
import hashlib
import io
import json
import os
import pathlib
import re
import stat
import subprocess
import sys
import tempfile
import uuid

TASK_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
HEADING_RE = re.compile(r"^## Resuming from: ([^\n]+)$", re.M)
ANNOTATED_TASK_RE = re.compile(r"^([A-Za-z0-9][A-Za-z0-9._-]*) \(([^()\n]+)\)$")
START_RE = re.compile(r"^<!-- rig:handoff-start task=([^ ]+) owner=([^ ]+) -->$", re.M)
END_MARKER = "<!-- rig:handoff-end -->"
BACKUP_RE = re.compile(r"^(retired|transferred|legacy|restore)-([0-9a-f]{64})\.md$")


def fail(reason, **detail):
    print(json.dumps({"ok": False, "reason": reason, "no_write": True, **detail}))
    raise SystemExit(3)


def valid_task(task):
    return bool(TASK_RE.fullmatch(task)) and task not in (".", "..")


def heading_task(heading):
    """Use the slug for ownership while retaining legacy heading annotations."""
    text = heading.group(1).strip()
    if valid_task(text):
        return text
    annotated = ANNOTATED_TASK_RE.fullmatch(text)
    if annotated and annotated.group(2).strip() and valid_task(annotated.group(1)):
        return annotated.group(1)
    return None


def normalize(content):
    return content.rstrip() + "\n" if content.strip() else ""


def split_legacy(content):
    matches = list(HEADING_RE.finditer(content))
    if not matches:
        return content, {}, False
    shared = content[: matches[0].start()]
    sections = {}
    for index, match in enumerate(matches):
        task = heading_task(match)
        if task is None or task in sections:
            fail("invalid_task_sections")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(content)
        raw_body = content[match.start() : end]
        sections[task] = {"owner": None, "body": normalize(raw_body), "raw_body": raw_body}
    return shared, sections, True


def split_marked(content):
    matches = list(START_RE.finditer(content))
    if not matches:
        if "<!-- rig:handoff-" in content:
            fail("malformed_handoff_markers")
        shared, sections, _ = split_legacy(content)
        return shared, sections, bool(content)
    shared = content[: matches[0].start()]
    sections = {}
    cursor = matches[0].start()
    for match in matches:
        if content[cursor : match.start()].strip():
            fail("malformed_handoff_markers")
        task, owner = match.groups()
        if not valid_task(task) or task in sections:
            fail("invalid_task_sections")
        end = content.find(END_MARKER, match.end())
        if end < 0 or (len(matches) and any(match.end() < other.start() < end for other in matches)):
            fail("malformed_handoff_markers")
        body = content[match.end() : end].strip("\n") + "\n"
        heading = HEADING_RE.search(body)
        if not heading or heading.start() != 0 or heading_task(heading) != task:
            fail("malformed_handoff_markers")
        sections[task] = {"owner": None if owner == "legacy" else owner, "body": body}
        cursor = end + len(END_MARKER)
    if content[cursor:].strip():
        fail("malformed_handoff_markers")
    return shared, sections, False


def render(shared, sections):
    output = normalize(shared).rstrip("\n")
    for task, entry in sections.items():
        owner = entry["owner"] or "legacy"
        output += ("\n\n" if output else "") + f"<!-- rig:handoff-start task={task} owner={owner} -->\n"
        output += normalize(entry["body"])
        output += END_MARKER + "\n"
    return normalize(output)


def render_preserving_shared(shared, sections):
    """Mark legacy sections while retaining the current shared header byte for byte."""
    output = shared
    for task, entry in sections.items():
        if output and not output.endswith("\n\n"):
            output += "\n" if output.endswith("\n") else "\n\n"
        owner = entry["owner"] or "legacy"
        output += f"<!-- rig:handoff-start task={task} owner={owner} -->\n"
        body = entry.get("raw_body", normalize(entry["body"]))
        output += body + ("" if body.endswith("\n") else "\n") + END_MARKER + "\n"
    return output


def atomic_write(path, content, mode):
    fd, tmp = tempfile.mkstemp(prefix=".snapshot-", suffix=".tmp", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
        dir_fd = os.open(str(path.parent), os.O_RDONLY)
        try:
            try:
                os.fsync(dir_fd)
            except OSError as exc:
                if exc.errno not in (errno.EINVAL, errno.ENOTSUP):
                    raise
        finally:
            os.close(dir_fd)
    finally:
        try:
            os.unlink(tmp)
        except FileNotFoundError:
            pass


def read_regular_text(path, missing_ok=False, quiet=False, anchor=None):
    """Read through pinned directories without following symlinks or pipes."""
    def reject(reason):
        if quiet:
            raise ValueError(reason)
        fail(reason, file=str(path))

    anchor = anchor or path.parent
    try:
        relative = path.relative_to(anchor)
    except ValueError:
        reject("invalid_snapshot_path")
    directory_flags = (os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) |
                       getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
    file_flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    directory_fd = None
    try:
        directory_fd = os.open(str(anchor), directory_flags)
        for part in relative.parts[:-1]:
            next_fd = os.open(part, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        fd = os.open(relative.parts[-1], file_flags, dir_fd=directory_fd)
    except FileNotFoundError:
        if missing_ok:
            return None
        reject("snapshot_file_missing")
    except OSError:
        reject("invalid_snapshot_path")
    finally:
        if directory_fd is not None:
            os.close(directory_fd)
    with os.fdopen(fd, "rb") as handle:
        if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
            reject("invalid_snapshot_path")
        try:
            return handle.read().decode("utf-8")
        except (OSError, UnicodeDecodeError):
            reject("invalid_snapshot_content")


def project_identity(root):
    try:
        common = subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--git-common-dir"],
            text=True,
            stderr=subprocess.DEVNULL,
        ).strip()
        common = pathlib.Path(common if os.path.isabs(common) else root / common).resolve()
    except (OSError, subprocess.SubprocessError):
        common = root.resolve()
    return hashlib.sha256(str(common).encode()).hexdigest()


def legacy_record(record):
    """Recognize the schema-less session shape written by the old launcher."""
    return (isinstance(record, dict) and "schema_version" not in record
            and isinstance(record.get("anchor"), str) and valid_task(record["anchor"])
            and type(record.get("pid")) is int and record["pid"] > 0)


def anchor_records(anchor, sessions):
    matches = []
    for directory in (sessions, sessions / "done"):
        if not directory.is_dir() or directory.is_symlink():
            continue
        for path in directory.glob("session-*.json"):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                record = json.loads(path.read_text())
            except (OSError, ValueError, TypeError):
                continue
            if isinstance(record, dict) and record.get("anchor") == anchor:
                matches.append((path, record))
    return matches


def verify_owner(expected_json, root, rig_dir):
    try:
        expected = json.loads(expected_json)
        path = pathlib.Path(expected["session_file"])
        sessions = (rig_dir / "memory" / "sessions").resolve()
        path.resolve(strict=True).relative_to(sessions)
        if path.is_symlink() or not path.is_file() or expected.get("confidence") != "exact":
            fail("unresolved_owner")
        record = json.loads(path.read_text())
    except (OSError, ValueError, KeyError, TypeError, RuntimeError):
        fail("unresolved_owner")
    if (not isinstance(record, dict) or record.get("anchor") != expected.get("anchor")
            or "done" in path.parts):
        fail("unresolved_owner")
    if record.get("schema_version") == 1:
        if (record.get("agent") != expected.get("agent")
                or record.get("native", {}).get("session_id") != expected.get("native_session_id")
                or record.get("project", {}).get("identity") != project_identity(root)
                or record.get("lifecycle", {}).get("state") != "active"):
            fail("unresolved_owner")
    elif legacy_record(record):
        launcher_file = os.environ.get("RIG_SESSION_FILE")
        if (expected.get("reason") != "launcher_file" or expected.get("state") != "active"
                or not launcher_file or pathlib.Path(launcher_file).resolve() != path.resolve()
                or os.environ.get("RIG_SESSION_ANCHOR") != record["anchor"]
                or path.name != f"session-{record['pid']}-{record['anchor']}.json"
                or record.get("status") != "active"
                or ("project" in record and record["project"] != {"identity": project_identity(root)})
                or len(anchor_records(record["anchor"], sessions)) != 1):
            fail("unresolved_owner")
    else:
        fail("unresolved_owner")
    return record["anchor"]


def completed_owner(anchor, root, rig_dir):
    """Permit a handoff transfer only after its exact prior session ended."""
    sessions = rig_dir / "memory" / "sessions"
    matches = anchor_records(anchor, sessions)
    if len(matches) != 1:
        return False
    path, record = matches[0]
    if legacy_record(record):
        return (path.parent == sessions / "done"
                and re.fullmatch(r"session-\d{8}-" + re.escape(anchor) + r"\.json", path.name) is not None
                and record.get("status") == "complete"
                and ("project" not in record or record["project"] == {"identity": project_identity(root)}))
    if record.get("schema_version") != 1:
        return False
    project = record.get("project")
    lifecycle = record.get("lifecycle")
    return (isinstance(project, dict) and project.get("identity") == project_identity(root)
            and isinstance(lifecycle, dict)
            and lifecycle.get("state") in ("complete", "inactive", "ended_no_wrap"))


def backup_snapshot(memory, content, kind):
    backup_dir = memory / "snapshot-backups"
    if backup_dir.is_symlink():
        fail("invalid_backup_path")
    backup_dir.mkdir(mode=0o700, exist_ok=True)
    digest = hashlib.sha256(content.encode()).hexdigest()
    backup = backup_dir / f"{kind}-{digest}.md"
    if backup.is_symlink():
        fail("invalid_backup_path")
    if backup.exists():
        if read_regular_text(backup, anchor=memory.parent) != content:
            fail("backup_conflict")
    else:
        atomic_write(backup, content, 0o600)
    return str(backup)


def restore_snapshot_main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--rig-dir", required=True)
    selection = parser.add_mutually_exclusive_group(required=True)
    selection.add_argument("--list", action="store_true")
    selection.add_argument("--from", dest="backup_name")
    parser.add_argument("--section")
    parser.add_argument("--confirm", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.list and (args.section or args.confirm):
        fail("invalid_restore_options")
    if args.section and not valid_task(args.section):
        fail("invalid_task")

    rig_dir = pathlib.Path(args.rig_dir).resolve()
    memory = rig_dir / "memory"
    if memory.is_symlink() or not memory.is_dir():
        fail("invalid_memory_path")
    backups = memory / "snapshot-backups"
    if backups.is_symlink() or (backups.exists() and not backups.is_dir()):
        fail("invalid_backup_path")
    lock_path = memory / ".snapshot-write.lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0)
    try:
        lock_fd = os.open(str(lock_path), flags, 0o600)
    except OSError:
        fail("invalid_lock_path")
    with os.fdopen(lock_fd, "r+") as lock:
        if not stat.S_ISREG(os.fstat(lock.fileno()).st_mode):
            fail("invalid_lock_path")
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        if args.list:
            entries = []
            if backups.is_dir():
                for backup in sorted(backups.glob("*.md")):
                    match = BACKUP_RE.fullmatch(backup.name)
                    if not match:
                        continue
                    valid, reason = True, None
                    try:
                        content = read_regular_text(backup, quiet=True, anchor=rig_dir)
                    except ValueError:
                        valid, reason, content = False, "unsafe_or_unreadable", ""
                    if valid and hashlib.sha256(content.encode()).hexdigest() != match.group(2):
                        valid, reason = False, "hash_mismatch"
                    if valid:
                        with contextlib.redirect_stdout(io.StringIO()):
                            try:
                                split_marked(content)
                            except SystemExit:
                                valid, reason = False, "invalid_snapshot_content"
                    entries.append({"name": backup.name, "kind": match.group(1),
                                    "valid": valid, "reason": reason})
            result = {"ok": True, "backups": entries}
        else:
            named = pathlib.Path(args.backup_name)
            if ((named.is_absolute() and named.parent.resolve() != backups)
                    or (not named.is_absolute() and named.name != args.backup_name)
                    or not BACKUP_RE.fullmatch(named.name)):
                fail("invalid_backup_name")
            backup = backups / named.name
            if not backups.is_dir():
                fail("backup_missing")
            content = read_regular_text(backup, anchor=rig_dir)
            if hashlib.sha256(content.encode()).hexdigest() != BACKUP_RE.fullmatch(backup.name).group(2):
                fail("backup_hash_mismatch")
            _, old_sections, _ = split_marked(content)
            if args.section and args.section not in old_sections:
                fail("section_missing", section=args.section)
            selected = {task: entry for task, entry in old_sections.items()
                        if args.section is None or task == args.section}
            snapshot = memory / "CONTEXT_SNAPSHOT.md"
            current = read_regular_text(snapshot, missing_ok=True, anchor=rig_dir) or ""
            shared, current_sections, legacy_current = split_marked(current)
            present = sorted(set(selected) & set(current_sections))
            missing = sorted(set(selected) - set(current_sections))
            result = {"ok": True, "status": "preview" if missing else "already_present",
                      "file": str(snapshot), "from": str(backup), "restore_sections": missing,
                      "present_sections": present, "no_write": True}
            if args.confirm and missing:
                sentinel = memory / ".snapshot-write-in-progress"
                if sentinel.is_symlink():
                    fail("invalid_lock_path")
                if sentinel.exists():
                    marker = read_regular_text(sentinel, anchor=rig_dir)
                    if not marker and datetime.datetime.now().timestamp() - sentinel.stat().st_mtime < 1800:
                        fail("legacy_lock_active")
                    if marker:
                        try:
                            state = json.loads(marker)
                        except (ValueError, TypeError):
                            fail("invalid_lock_path")
                        if not isinstance(state, dict) or not state.get("token"):
                            fail("invalid_lock_path")
                token = str(uuid.uuid4())
                try:
                    try:
                        atomic_write(sentinel, json.dumps({"token": token, "anchor": None,
                                     "pid": os.getpid(), "started_at": datetime.datetime.now(
                                         datetime.timezone.utc).isoformat()}) + "\n", 0o600)
                    except OSError:
                        fail("invalid_lock_path")
                    try:
                        prior_backup = backup_snapshot(memory, current, "restore")
                    except OSError:
                        fail("backup_write_failed")
                    additions = {task: selected[task] for task in missing}
                    if current and not legacy_current:
                        separator = "" if current.endswith("\n\n") else ("\n" if current.endswith("\n") else "\n\n")
                        updated = current + separator + render("", additions)
                    else:
                        current_sections.update(additions)
                        updated = render_preserving_shared(shared, current_sections)
                    mode = stat.S_IMODE(snapshot.stat().st_mode) if snapshot.exists() else 0o644
                    try:
                        atomic_write(snapshot, updated, mode)
                    except OSError:
                        observed = read_regular_text(snapshot, missing_ok=True, anchor=rig_dir)
                        fail("snapshot_write_failed", no_write=(observed or "") == current)
                    result.update(status="restored", restore_sections=missing,
                                  pre_restore_backup=prior_backup, no_write=False)
                finally:
                    try:
                        if json.loads(read_regular_text(sentinel, quiet=True, anchor=rig_dir)).get("token") == token:
                            sentinel.unlink()
                    except (OSError, ValueError, TypeError, SystemExit):
                        pass
    if args.json:
        print(json.dumps(result, separators=(",", ":")))
    elif args.list:
        for item in result["backups"]:
            print(item["name"] + ("" if item["valid"] else f" (invalid: {item['reason']})"))
    else:
        print(f"{result['status']}: {', '.join(result['restore_sections']) or 'no missing sections'}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--rig-dir", required=True)
    parser.add_argument("--root", required=True)
    parser.add_argument("--file", required=True)
    parser.add_argument("--mode", choices=("replace", "shared", "owned"), required=True)
    parser.add_argument("--owned-task", action="append", default=[])
    parser.add_argument("--retire-task", action="append", default=[])
    parser.add_argument("--done-task-file", action="append", default=[])
    parser.add_argument("--expected-session")
    parser.add_argument("--adopt-legacy", action="store_true")
    parser.add_argument("--if-missing", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    if any(not valid_task(task) for task in args.owned_task) or len(set(args.owned_task)) != len(args.owned_task):
        fail("invalid_task")
    if (any(not valid_task(task) for task in args.retire_task)
            or len(set(args.retire_task)) != len(args.retire_task)
            or len(args.retire_task) != len(args.done_task_file)):
        fail("invalid_retirement")
    if args.mode == "owned" and (not args.owned_task or not args.expected_session):
        fail("unresolved_owner")
    if args.mode != "owned" and args.owned_task:
        fail("invalid_input")
    if args.retire_task and args.mode != "shared":
        fail("invalid_retirement")
    if args.if_missing and (args.mode != "shared" or args.retire_task):
        fail("invalid_input")
    source = pathlib.Path(args.file)
    if source.is_symlink() or not source.is_file():
        fail("source_missing")
    candidate = source.read_text()
    if "<!-- rig:handoff-" in candidate:
        fail("candidate_has_markers")
    new_shared, new_sections, _ = split_legacy(candidate)
    if args.mode == "owned" and set(new_sections) != set(args.owned_task):
        fail("owned_section_mismatch")
    if args.mode == "shared" and new_sections:
        fail("unexpected_task_sections")
    if args.mode == "replace" and new_sections:
        fail("workstream_guard_required")

    rig_dir = pathlib.Path(args.rig_dir).resolve()
    root = pathlib.Path(args.root).resolve()
    memory = rig_dir / "memory"
    if memory.is_symlink():
        fail("invalid_memory_path")
    memory.mkdir(parents=True, exist_ok=True)
    lock_path = memory / ".snapshot-write.lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    try:
        lock_fd = os.open(str(lock_path), flags, 0o600)
    except OSError:
        fail("invalid_lock_path")
    with os.fdopen(lock_fd, "r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        sentinel = memory / ".snapshot-write-in-progress"
        recovered = False
        if sentinel.is_symlink():
            fail("invalid_lock_path")
        if sentinel.exists():
            raw = sentinel.read_text()
            if raw:
                try:
                    old = json.loads(raw)
                except (ValueError, TypeError):
                    fail("invalid_lock_path")
                if not isinstance(old, dict) or not old.get("token"):
                    fail("invalid_lock_path")
                recovered = True
            elif datetime.datetime.now().timestamp() - sentinel.stat().st_mtime < 1800:
                fail("legacy_lock_active")
            else:
                recovered = True

        token = str(uuid.uuid4())
        owner = None
        if args.mode == "owned":
            bind_lock = memory / "sessions" / ".bind.lock"
            bind_lock.parent.mkdir(parents=True, exist_ok=True)
            with open(bind_lock, "a+") as binding:
                fcntl.flock(binding.fileno(), fcntl.LOCK_EX)
                owner = verify_owner(args.expected_session, root, rig_dir)
                result = write_snapshot(memory, rig_dir, sentinel, token, args, new_shared, new_sections, owner, recovered)
        else:
            result = write_snapshot(memory, rig_dir, sentinel, token, args, new_shared, new_sections, owner, recovered)
    print(json.dumps(result, separators=(",", ":")) if args.json else "Wrote CONTEXT_SNAPSHOT.md")


def write_snapshot(memory, rig_dir, sentinel, token, args, new_shared, new_sections, owner, recovered):
    marker = {"token": token, "anchor": owner, "pid": os.getpid(),
              "started_at": datetime.datetime.now(datetime.timezone.utc).isoformat()}
    atomic_write(sentinel, json.dumps(marker) + "\n", 0o600)
    try:
        path = memory / "CONTEXT_SNAPSHOT.md"
        if path.is_symlink():
            fail("invalid_snapshot_path")
        if args.if_missing and path.exists():
            return {"ok": True, "file": str(path), "no_write": True,
                    "preserved_tasks": [], "updated_tasks": [], "retired_tasks": [],
                    "legacy_backup": None, "recovered_lock": recovered}
        previous = path.read_text() if path.exists() else ""
        old_shared, old_sections, legacy = split_marked(previous)
        retired = []
        if args.retire_task:
            done_root = (rig_dir / "tasks" / "done").resolve()
            active_root = (rig_dir / "tasks" / "active").resolve()
            for task, named_file in zip(args.retire_task, args.done_task_file):
                done_file = pathlib.Path(named_file)
                if done_file.is_symlink() or not done_file.is_file():
                    fail("done_task_unverified", task=task)
                try:
                    done_file.resolve(strict=True).relative_to(done_root)
                except (OSError, ValueError, RuntimeError):
                    fail("done_task_unverified", task=task)
                if done_file.stem not in (task, f"TASK_{task}", f"TASK-{task}"):
                    fail("done_task_mismatch", task=task)
                active_names = (f"{task}.md", f"TASK_{task}.md", f"TASK-{task}.md")
                if any((active_root / name).exists() or (active_root / name).is_symlink()
                       for name in active_names):
                    fail("task_still_active", task=task)
                if task in old_sections:
                    retired.append(task)
            if retired:
                backup_snapshot(memory, previous, "retired")
                for task in retired:
                    del old_sections[task]
        if args.mode == "replace":
            if old_sections:
                fail("workstream_guard_required")
            content = normalize(new_shared)
        else:
            if args.mode == "owned":
                for task in args.owned_task:
                    current = old_sections.get(task)
                    if current and current["owner"] not in (None, owner):
                        if not completed_owner(current["owner"], pathlib.Path(args.root).resolve(), rig_dir):
                            fail("owner_conflict")
                        backup_snapshot(memory, previous, "transferred")
                    if current and current["owner"] is None and not args.adopt_legacy:
                        fail("legacy_adoption_required")
                    old_sections[task] = {"owner": owner, "body": new_sections[task]["body"]}
            # An owned-task draft may contain only handoffs, or an older copy of
            # the shared header. Only shared-mode writes may replace that header.
            shared = old_shared if args.mode == "owned" and previous else new_shared
            content = render(shared, old_sections)
        backup = backup_snapshot(memory, previous, "legacy") if legacy and previous and (old_sections or recovered) else None
        mode = stat.S_IMODE(path.stat().st_mode) if path.exists() else 0o644
        atomic_write(path, content, mode)
        return {"ok": True, "file": str(path), "preserved_tasks": sorted(set(old_sections) - set(args.owned_task)),
                "updated_tasks": sorted(args.owned_task), "retired_tasks": retired,
                "legacy_backup": backup, "recovered_lock": recovered}
    finally:
        try:
            if json.loads(sentinel.read_text()).get("token") == token:
                sentinel.unlink()
        except (OSError, ValueError, TypeError):
            pass


def workflow_lock_main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("action", choices=("acquire", "release"))
    parser.add_argument("--rig-dir", required=True)
    parser.add_argument("--owner-anchor")
    parser.add_argument("--provider-pid", type=int)
    parser.add_argument("--token")
    parser.add_argument("--recover-stale", action="store_true")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args(argv)
    if args.action == "release" and not args.token:
        fail("token_required")
    if args.action == "acquire" and args.token:
        fail("invalid_input")
    if args.action == "release" and args.recover_stale:
        fail("invalid_input")
    if args.provider_pid is not None and args.provider_pid <= 0:
        fail("invalid_provider_pid")
    memory = pathlib.Path(args.rig_dir).resolve() / "memory"
    if memory.is_symlink():
        fail("invalid_memory_path")
    memory.mkdir(parents=True, exist_ok=True)
    gate_path = memory / ".memory-workflow-gate.lock"
    flags = os.O_CREAT | os.O_RDWR | getattr(os, "O_NOFOLLOW", 0)
    try:
        gate_fd = os.open(str(gate_path), flags, 0o600)
    except OSError:
        fail("invalid_lock_path")
    with os.fdopen(gate_fd, "r+") as gate:
        fcntl.flock(gate.fileno(), fcntl.LOCK_EX)
        path = memory / ".memory-workflow-in-progress"
        if path.is_symlink():
            fail("invalid_lock_path")
        state = None
        if path.exists():
            try:
                state = json.loads(path.read_text())
            except (OSError, ValueError, TypeError):
                fail("invalid_lock_path")
            if not isinstance(state, dict) or not state.get("token") or not isinstance(state.get("started_epoch"), (int, float)):
                fail("invalid_lock_path")
            try:
                uuid.UUID(state["token"])
            except (ValueError, TypeError, AttributeError):
                fail("invalid_lock_path")
        if args.action == "release":
            if not state or state.get("token") != args.token:
                fail("lock_owner_mismatch", owner_anchor=state.get("owner_anchor") if state else None)
            path.unlink()
            result = {"ok": True, "released": True}
        else:
            recovered = False
            if state:
                age = max(0, int(datetime.datetime.now().timestamp() - state["started_epoch"]))
                pid = state.get("pid")
                dead = False
                provider_pid = state.get("pid_source") == "provider" and isinstance(pid, int) and pid > 0
                if provider_pid:
                    try:
                        os.kill(pid, 0)
                    except ProcessLookupError:
                        dead = True
                    except PermissionError:
                        pass
                # Tool subprocess PIDs cannot prove the provider has stopped.
                # Their age fallback requires an explicit recovery request.
                if not dead and (provider_pid or age <= 1800 or not args.recover_stale):
                    fail("workflow_busy", owner_anchor=state.get("owner_anchor"), pid=pid, age_seconds=age)
                archive = memory / "workflow-lock-archive"
                if archive.is_symlink():
                    fail("invalid_lock_path")
                archive.mkdir(mode=0o700, exist_ok=True)
                archived = archive / ("stale-" + state["token"] + ".json")
                if archived.exists() or archived.is_symlink():
                    fail("lock_archive_conflict")
                atomic_write(archived, json.dumps(state, sort_keys=True) + "\n", 0o600)
                recovered = True
            now = datetime.datetime.now(datetime.timezone.utc)
            token = str(uuid.uuid4())
            owner = {"token": token, "owner_anchor": args.owner_anchor,
                     "pid": args.provider_pid or os.getppid(),
                     "pid_source": "provider" if args.provider_pid else "tool",
                     "started_at": now.isoformat(), "started_epoch": now.timestamp()}
            atomic_write(path, json.dumps(owner, sort_keys=True) + "\n", 0o600)
            result = {"ok": True, "token": token, "owner_anchor": args.owner_anchor,
                      "pid": owner["pid"], "recovered_stale": recovered}
    print(json.dumps(result, separators=(",", ":")) if args.json else (result.get("token") or "Released Rig memory workflow lock"))


if __name__ == "__main__":
    if len(sys.argv) > 1 and sys.argv[1] == "workflow-lock":
        workflow_lock_main(sys.argv[2:])
    elif len(sys.argv) > 1 and sys.argv[1] == "restore-snapshot":
        restore_snapshot_main(sys.argv[2:])
    else:
        main()
