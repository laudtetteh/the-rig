#!/usr/bin/env python3
"""Explicit, content-bound archive and restore of current-project v1 sessions."""
import contextlib
import ctypes
import datetime as dt
import fcntl
import hashlib
import json
import os
import pathlib
import re
import secrets
import stat
import subprocess
import sys
import uuid

ROOT = pathlib.Path(os.environ['RIG_ROOT']).resolve()
RIG = pathlib.Path(os.environ['RIG_DIR'])
MEMORY = RIG / 'memory'
SESSIONS = MEMORY / 'sessions'
ARCHIVE = SESSIONS / 'archive'
JSON = '--json' in sys.argv[1:]
HEX = re.compile(r'[0-9a-f]{20}\Z')
NAME = re.compile(r'(?:done/)?session-[A-Za-z0-9._-]+\.json\Z')
ANCHOR = re.compile(r'[A-Za-z0-9][A-Za-z0-9._-]*\Z')


class Refusal(Exception):
    def __init__(self, reason, detail=None):
        self.reason, self.detail = reason, detail or {}


def emit(ok, reason, detail=None, status=0):
    result = {'ok': ok, 'reason': reason, **(detail or {})}
    print(json.dumps(result) if JSON else json.dumps(result, indent=2))
    raise SystemExit(status)


def sha(raw):
    return hashlib.sha256(raw).hexdigest()


def audit_event(action, archive_id, members):
    event = {'schema_version': 1, 'action': action, 'archive_id': archive_id,
             'at': dt.datetime.now(dt.timezone.utc).isoformat(), 'member_count': len(members),
             'anchors_sha256': [sha(member['anchor'].encode()) for member in members]}
    try:
        with pinned_dir(SESSIONS) as directory:
            fd = os.open('archive-audit.jsonl', os.O_CREAT | os.O_APPEND | os.O_WRONLY |
                         getattr(os, 'O_NOFOLLOW', 0), 0o600, dir_fd=directory)
            with os.fdopen(fd, 'ab') as stream:
                if stat.S_IMODE(os.fstat(stream.fileno()).st_mode) & 0o077:
                    return False
                stream.write((json.dumps(event, sort_keys=True) + '\n').encode())
                stream.flush()
                os.fsync(stream.fileno())
        return True
    except (OSError, Refusal):
        return False


def audit_preflight():
    try:
        with pinned_dir(SESSIONS) as directory:
            try:
                fd = os.open('archive-audit.jsonl', os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0), dir_fd=directory)
            except FileNotFoundError:
                return
            with os.fdopen(fd, 'rb') as stream:
                info = os.fstat(stream.fileno())
                if not stat.S_ISREG(info.st_mode) or stat.S_IMODE(info.st_mode) & 0o077:
                    raise Refusal('unsafe_storage')
    except OSError:
        raise Refusal('unsafe_storage') from None


def safe_dir(path, private=False):
    if path.is_symlink() or any(parent.is_symlink() for parent in path.parents):
        raise Refusal('unsafe_storage')
    if not path.is_dir() or (private and stat.S_IMODE(path.stat().st_mode) & 0o077):
        raise Refusal('unsafe_storage')


def read_file(path):
    # Pin each ancestor and the leaf with no-follow opens. A path swap after
    # discovery cannot redirect a record read through a symlink.
    absolute = path.absolute()
    directory = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in absolute.parts[1:-1]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_NOFOLLOW', 0), dir_fd=directory)
            os.close(directory)
            directory = child
        leaf = os.open(absolute.name, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0) | getattr(os, 'O_NONBLOCK', 0),
                       dir_fd=directory)
    except OSError:
        raise Refusal('unsafe_record_path') from None
    finally:
        os.close(directory)
    with os.fdopen(leaf, 'rb') as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size > 1048576:
            raise Refusal('unsafe_record_path')
        return stream.read(1048577)


@contextlib.contextmanager
def pinned_dir(path):
    absolute = path.absolute()
    fd = os.open('/', os.O_RDONLY | os.O_DIRECTORY)
    try:
        for component in absolute.parts[1:]:
            child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_NOFOLLOW', 0),
                            dir_fd=fd)
            os.close(fd)
            fd = child
        yield fd
    except OSError:
        raise Refusal('unsafe_storage') from None
    finally:
        os.close(fd)


def secure_mkdir(path):
    with pinned_dir(path.parent) as parent:
        os.mkdir(path.name, 0o700, dir_fd=parent)
        os.fsync(parent)
    safe_dir(path, private=True)


def move_file(source, destination):
    # Pin the source inode and both parents. The kernel moves it atomically and
    # refuses an occupied destination; a swap can only strand a pending journal.
    with pinned_dir(source.parent) as source_fd, pinned_dir(destination.parent) as dest_fd:
        source_handle = os.open(source.name, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0), dir_fd=source_fd)
        try:
            source_info = os.fstat(source_handle)
            if not stat.S_ISREG(source_info.st_mode):
                raise Refusal('unsafe_record_path')
            if os.stat(source.name, dir_fd=source_fd, follow_symlinks=False).st_ino != source_info.st_ino:
                raise Refusal('record_changed')
            rename_no_replace(source_fd, source.name, dest_fd, destination.name)
            moved_info = os.stat(destination.name, dir_fd=dest_fd, follow_symlinks=False)
            if (moved_info.st_dev, moved_info.st_ino) != (source_info.st_dev, source_info.st_ino):
                raise Refusal('record_changed')
        finally:
            os.close(source_handle)
        os.fsync(dest_fd)
        os.fsync(source_fd)


def safe_unlink(path, expected_sha=None):
    with pinned_dir(path.parent) as parent:
        fd = os.open(path.name, os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0), dir_fd=parent)
        try:
            info = os.fstat(fd)
            if not stat.S_ISREG(info.st_mode):
                raise Refusal('unsafe_record_path')
            if expected_sha is not None and sha(os.read(fd, 1048577)) != expected_sha:
                raise Refusal('recovery_changed')
            if os.stat(path.name, dir_fd=parent, follow_symlinks=False).st_ino != info.st_ino:
                raise Refusal('record_changed')
            os.unlink(path.name, dir_fd=parent)
            os.fsync(parent)
        finally:
            os.close(fd)


def rename_no_replace(source_fd, source_name, dest_fd, dest_name):
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == 'darwin':
        function = getattr(libc, 'renameatx_np', None)
        flag = 0x00000004  # RENAME_EXCL from sys/stdio.h
    elif sys.platform.startswith('linux'):
        function = getattr(libc, 'renameat2', None)
        flag = 0x00000001  # RENAME_NOREPLACE from linux/fs.h
    else:
        function = None
    if function is None:
        raise Refusal('atomic_no_replace_unavailable')
    function.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(source_fd, os.fsencode(source_name), dest_fd, os.fsencode(dest_name), flag) != 0:
        if ctypes.get_errno() == 17:  # EEXIST
            raise Refusal('destination_exists')
        raise Refusal('atomic_rename_failed')


def rename_directory(source, destination):
    with pinned_dir(source.parent) as parent:
        rename_no_replace(parent, source.name, parent, destination.name)
        os.fsync(parent)


def safe_remove_tree(path, expected_inode=None):
    """Remove only the pinned pending directory and its no-follow contents."""
    def empty(fd):
        for name in os.listdir(fd):
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            if stat.S_ISDIR(info.st_mode):
                child = os.open(name, os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_NOFOLLOW', 0), dir_fd=fd)
                try:
                    if os.fstat(child).st_ino != info.st_ino:
                        raise Refusal('unsafe_storage')
                    empty(child)
                    if os.stat(name, dir_fd=fd, follow_symlinks=False).st_ino != info.st_ino:
                        raise Refusal('unsafe_storage')
                    os.rmdir(name, dir_fd=fd)
                finally:
                    os.close(child)
            else:
                os.unlink(name, dir_fd=fd)
    with pinned_dir(path.parent) as parent:
        info = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
        if not stat.S_ISDIR(info.st_mode) or (expected_inode is not None and info.st_ino != expected_inode):
            raise Refusal('unsafe_storage')
        child = os.open(path.name, os.O_RDONLY | os.O_DIRECTORY | getattr(os, 'O_NOFOLLOW', 0), dir_fd=parent)
        try:
            if os.fstat(child).st_ino != info.st_ino:
                raise Refusal('unsafe_storage')
            empty(child)
            if os.stat(path.name, dir_fd=parent, follow_symlinks=False).st_ino != info.st_ino:
                raise Refusal('unsafe_storage')
            os.rmdir(path.name, dir_fd=parent)
            os.fsync(parent)
        finally:
            os.close(child)


def project_identity():
    try:
        common = subprocess.check_output(['git', '-C', str(ROOT), 'rev-parse', '--git-common-dir'],
                                         text=True, stderr=subprocess.DEVNULL).strip()
        common = pathlib.Path(common if os.path.isabs(common) else ROOT / common).resolve()
    except (OSError, subprocess.SubprocessError):
        common = ROOT
    return sha(str(common).encode())


PROJECT_ID = project_identity()


def timestamp(value):
    try:
        parsed = dt.datetime.fromisoformat(value.replace('Z', '+00:00'))
        if parsed.tzinfo is None:
            raise ValueError
        return parsed.astimezone(dt.timezone.utc)
    except (AttributeError, ValueError):
        raise Refusal('malformed_record') from None


def records():
    for directory in (RIG, MEMORY, SESSIONS):
        safe_dir(directory)
    found = []
    for base in (SESSIONS, SESSIONS / 'done'):
        if base != SESSIONS and not base.exists():
            continue
        safe_dir(base)
        for path in sorted(base.glob('session-*.json')):
            raw = read_file(path)
            try:
                data = json.loads(raw)
            except (UnicodeError, ValueError):
                raise Refusal('malformed_record') from None
            if not isinstance(data, dict) or type(data.get('schema_version')) is not int or data['schema_version'] != 1:
                raise Refusal('unsupported_or_malformed_record')
            if not all(isinstance(data.get(key), dict) for key in ('native', 'project', 'lifecycle')):
                # The existing legacy command owns historical flat records.
                if not any(key in data for key in ('native', 'project', 'lifecycle')):
                    continue
                raise Refusal('historical_or_malformed_record')
            if any(key in data and not isinstance(data[key], dict)
                   for key in ('runtime', 'lineage', 'flags', 'obligations')):
                raise Refusal('malformed_record')
            anchor = data.get('anchor')
            if not isinstance(anchor, str) or not ANCHOR.fullmatch(anchor) or data.get('agent') not in ('claude', 'codex'):
                raise Refusal('malformed_record')
            if not isinstance(data['native'].get('session_id'), str) or not data['native']['session_id']:
                raise Refusal('malformed_record')
            if data['project'].get('identity') != PROJECT_ID:
                raise Refusal('cross_project')
            state = data['lifecycle'].get('state')
            if state not in ('active', 'inactive', 'orphaned', 'complete', 'ended_no_wrap') or (base != SESSIONS and state == 'active'):
                raise Refusal('invalid_lifecycle')
            found.append({'path': path, 'name': str(path.relative_to(SESSIONS)), 'raw': raw, 'data': data})
    return found


def marker_state(path, anchor):
    if not path.exists() and not path.is_symlink():
        return 'none'
    try:
        lines = read_file(path).decode().splitlines()
    except UnicodeError:
        return 'ambiguous'
    if not lines or any(not line.startswith(('anchor=', 'merge_sha=', 'merged_at=')) for line in lines):
        return 'ambiguous'
    if any(line.startswith('anchor=') and not ANCHOR.fullmatch(line[7:]) for line in lines):
        return 'ambiguous'
    if not any(line.startswith('anchor=') for line in lines):
        return 'ambiguous'
    if any(line.startswith('merge_sha=') and not line[10:] for line in lines):
        return 'ambiguous'
    if any(line == 'anchor=' + anchor for line in lines):
        return 'pending'
    return 'none'


def handoff_owner(anchor):
    path = MEMORY / 'CONTEXT_SNAPSHOT.md'
    if not path.exists() and not path.is_symlink():
        return False
    return any('rig:handoff-start' in line and 'owner=' + anchor in line
               for line in read_file(path).decode(errors='replace').splitlines())


def pid_observation(data):
    pid = (data.get('runtime') or {}).get('pid')
    if type(pid) is not int or pid < 1:
        return 'not_recorded'
    try:
        os.kill(pid, 0)
        return 'alive_local'
    except ProcessLookupError:
        return 'not_running_local'
    except PermissionError:
        return 'alive_local'


def evidence(item, days):
    data = item['data']
    last = max(timestamp(data.get('updated_at')), timestamp(data['lifecycle'].get('last_event_at')))
    age = max(0, (dt.datetime.now(dt.timezone.utc) - last).total_seconds() / 86400)
    anchor = data['anchor']
    markers = {'wrap': marker_state(MEMORY / '.wrap-needed', anchor),
               'post_merge': marker_state(MEMORY / '.post-merge-pending', anchor)}
    flags = data.get('flags') or {}
    obligations = data.get('obligations') or {}
    embedded_pending = (not isinstance(obligations, dict) or any(
        not isinstance(obligations.get(kind), dict) or obligations[kind].get('pending') is not False
        for kind in ('wrap', 'post_merge') if kind in obligations))
    reasons = []
    if age < days:
        reasons.append('too_recent')
    state = data['lifecycle']['state']
    if state == 'ended_no_wrap':
        reasons.append('ended_no_wrap')
    if (any(value != 'none' for value in markers.values()) or flags.get('wrap_needed') or
            flags.get('post_merge_pending') or embedded_pending):
        reasons.append('pending_or_ambiguous_obligation')
    owner = handoff_owner(anchor)
    if owner:
        reasons.append('handoff_owner')
    pid = pid_observation(data)
    if pid == 'alive_local':
        reasons.append('live_pid')
    event = data['lifecycle'].get('last_event')
    end_observed = 'complete' if state == 'complete' else 'session_end' if event == 'session_end' else 'none'
    return {'anchor': anchor, 'agent': data['agent'], 'state': state, 'record': item['name'],
            'last_activity_at': last.isoformat(), 'age_days': round(age, 2),
            'end_observed': end_observed,
            'pid_observation': pid, 'provider_live_state': 'unknown', 'obligations': markers,
            'handoff_owner': owner, 'checkpoint': owner and state == 'active',
            'archive_eligible': not reasons, 'refusal_reasons': reasons}


def components(items):
    by_anchor = {}
    for item in items:
        by_anchor.setdefault(item['data']['anchor'], []).append(item)
    if any(len(group) != 1 for group in by_anchor.values()):
        raise Refusal('duplicate_anchor')
    links = {anchor: set() for anchor in by_anchor}
    for anchor, group in by_anchor.items():
        data = group[0]['data']
        lineage = data.get('lineage') or {}
        kind = lineage.get('kind') or 'root'
        parent = lineage.get('parent_anchor')
        if kind == 'root':
            if parent or lineage.get('parent_native_session_id'):
                raise Refusal('invalid_lineage')
        elif kind in ('continuation', 'fork'):
            if not parent and kind == 'fork':
                continue
            if parent not in by_anchor:
                raise Refusal('invalid_lineage')
            parent_data = by_anchor[parent][0]['data']
            if (parent_data['agent'] != data['agent'] or
                    parent_data['native']['session_id'] != lineage.get('parent_native_session_id') or
                    parent_data['project']['identity'] != data['project']['identity']):
                raise Refusal('invalid_lineage')
            links[anchor].add(parent)
            links[parent].add(anchor)
        else:
            raise Refusal('invalid_lineage')
    groups = {}
    for anchor in by_anchor:
        seen, pending = {anchor}, [anchor]
        while pending:
            for neighbor in links[pending.pop()]:
                if neighbor not in seen:
                    seen.add(neighbor)
                    pending.append(neighbor)
        groups[anchor] = seen
    return groups


def content_token(items, days, acknowledge):
    baseline = {'project_identity': PROJECT_ID, 'older_than': days, 'acknowledge_active': acknowledge,
                'records': [(item['name'], sha(item['raw'])) for item in items]}
    for name in ('.wrap-needed', '.post-merge-pending', 'CONTEXT_SNAPSHOT.md'):
        path = MEMORY / name
        baseline[name] = sha(read_file(path)) if path.exists() or path.is_symlink() else 'missing'
    return sha(json.dumps(baseline, sort_keys=True).encode())[:20]


def selected(anchors, days, acknowledge):
    items = records()
    groups = components(items)
    graph = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('rig-session-resolve.py')),
                            '--graph-check'], capture_output=True, env=os.environ, check=False)
    if graph.returncode != 0:
        raise Refusal('invalid_lineage')
    chosen_anchors = set(anchors)
    if not chosen_anchors or not chosen_anchors <= groups.keys():
        raise Refusal('anchor_not_found')
    for anchor in chosen_anchors:
        if not groups[anchor] <= chosen_anchors:
            raise Refusal('lineage_component_incomplete', {'missing_anchors': sorted(groups[anchor] - chosen_anchors)})
    chosen = sorted((item for item in items if item['data']['anchor'] in chosen_anchors), key=lambda item: item['name'])
    reports = [evidence(item, days) for item in chosen]
    reasons = sorted({reason for report in reports for reason in report['refusal_reasons']})
    if not acknowledge and any(report['state'] == 'active' for report in reports):
        reasons.append('active_record_acknowledgment_required')
    return chosen, reports, reasons, content_token(chosen, days, acknowledge)


@contextlib.contextmanager
def locks(items):
    paths = [MEMORY / '.memory-workflow-gate.lock', MEMORY / '.snapshot-write.lock',
             MEMORY / '.session-obligations.lock', SESSIONS / '.bind.lock']
    paths.extend(item['path'].with_name(item['path'].name + '.lock') for item in items)
    held = []
    try:
        for path in paths:
            if path.is_symlink():
                raise Refusal('unsafe_lock')
            fd = os.open(path, os.O_CREAT | os.O_RDWR | getattr(os, 'O_NOFOLLOW', 0), 0o600)
            handle = os.fdopen(fd, 'a+')
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
            held.append(handle)
        yield
    finally:
        for handle in reversed(held):
            handle.close()


def private_write(path, raw, staging_dir=None):
    if staging_dir is not None:
        with pinned_dir(staging_dir) as staging, pinned_dir(path.parent) as parent:
            temp_name = '.archive-' + uuid.uuid4().hex
            fd = os.open(temp_name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=staging)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            os.fsync(staging)
            try:
                os.link(temp_name, path.name, src_dir_fd=staging, dst_dir_fd=parent,
                        follow_symlinks=False)
            except FileExistsError:
                raise Refusal('destination_exists') from None
            os.fsync(parent)
            os.unlink(temp_name, dir_fd=staging)
            os.fsync(staging)
        return
    with pinned_dir(path.parent) as parent:
        temp_name = '.archive-' + uuid.uuid4().hex
        fd = os.open(temp_name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            try:
                os.link(temp_name, path.name, src_dir_fd=parent, dst_dir_fd=parent,
                        follow_symlinks=False)
            except FileExistsError:
                raise Refusal('destination_exists') from None
            os.fsync(parent)
        finally:
            os.unlink(temp_name, dir_fd=parent)


def private_replace(path, raw):
    with pinned_dir(path.parent) as parent:
        temp_name = '.manifest-' + uuid.uuid4().hex
        fd = os.open(temp_name, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600, dir_fd=parent)
        try:
            with os.fdopen(fd, 'wb') as stream:
                stream.write(raw)
                stream.flush()
                os.fsync(stream.fileno())
            current = os.stat(path.name, dir_fd=parent, follow_symlinks=False)
            if not stat.S_ISREG(current.st_mode):
                raise Refusal('unsafe_storage')
            os.replace(temp_name, path.name, src_dir_fd=parent, dst_dir_fd=parent)
            os.fsync(parent)
        finally:
            try:
                os.unlink(temp_name, dir_fd=parent)
            except FileNotFoundError:
                pass


def workflow_busy():
    path = MEMORY / '.memory-workflow-in-progress'
    return path.exists() or path.is_symlink()


def pending_transactions():
    if not ARCHIVE.exists():
        return []
    safe_dir(ARCHIVE, private=True)
    return sorted(path for path in ARCHIVE.iterdir() if path.name.startswith('.pending-'))


def recovery_required():
    pending = pending_transactions()
    if pending:
        raise Refusal('archive_recovery_required',
                      {'pending': [path.name for path in pending],
                       'next_step': 'bin/rig session archive --recover ID --json'})


def recover_state(archive_id):
    safe_dir(ARCHIVE, private=True)
    candidates = [(ARCHIVE / ('.pending-' + archive_id), 'archive'),
                  (ARCHIVE / ('.pending-restore-' + archive_id), 'restore')]
    present = [(path, kind) for path, kind in candidates if path.exists() or path.is_symlink()]
    if len(present) != 1:
        raise Refusal('recovery_unavailable')
    path, kind = present[0]
    safe_dir(path, private=True)
    pending_inode = path.stat().st_ino
    manifest_path = path / 'manifest.json'
    if kind == 'archive' and not manifest_path.exists():
        # Source moves only begin after the complete manifest is durable.
        if (path / 'moved').exists() and any((path / 'moved').rglob('session-*.json')):
            raise Refusal('recovery_ambiguous')
        return path, kind, [], sha((path.name + str(pending_inode)).encode())[:20], pending_inode
    if kind == 'restore':
        manifest_path = ARCHIVE / archive_id / 'manifest.json'
    raw_manifest = read_file(manifest_path)
    try:
        manifest = json.loads(raw_manifest)
    except (UnicodeError, ValueError):
        raise Refusal('invalid_manifest') from None
    if (not isinstance(manifest, dict) or type(manifest.get('schema_version')) is not int or
            manifest['schema_version'] != 1 or
            manifest.get('archive_id') != archive_id or manifest.get('project_identity') != PROJECT_ID):
        raise Refusal('invalid_manifest')
    members = manifest.get('members')
    if not isinstance(members, list) or not members:
        raise Refusal('invalid_manifest')
    if any(not isinstance(member, dict) or not isinstance(member.get('record'), str) or
           not NAME.fullmatch(member['record']) or not isinstance(member.get('sha256'), str)
           for member in members):
        raise Refusal('invalid_manifest')
    declared = {member['record'] for member in members}
    if len(declared) != len(members):
        raise Refusal('invalid_manifest')
    intent_digest = None
    if kind == 'restore':
        intent_path = path / 'intent.json'
        if not intent_path.exists() and not intent_path.is_symlink():
            # Cleanup may have unlinked intent before failing to remove the
            # directory. Only durable restored_at plus exact live members
            # below can classify this as a completed restore.
            if not manifest.get('restored_at'):
                raise Refusal('invalid_journal')
            intent_digest = 'removed_during_finalization'
        else:
            intent_raw = read_file(intent_path)
            intent_digest = sha(intent_raw)
            try:
                intent = json.loads(intent_raw)
            except (UnicodeError, ValueError):
                raise Refusal('invalid_journal') from None
            expected_members = sorted([member['record'], member['sha256']] for member in members)
            if (not isinstance(intent, dict) or intent.get('archive_id') != archive_id or
                    intent.get('members') != expected_members):
                raise Refusal('invalid_journal')
            baseline_manifest = {key: value for key, value in manifest.items() if key != 'restored_at'}
            baseline_raw = (json.dumps(baseline_manifest, indent=2) + '\n').encode()
            if intent.get('manifest_sha256') != sha(baseline_raw):
                raise Refusal('recovery_changed')
    else:
        def staged_files(directory):
            safe_dir(directory, private=True)
            names = set()
            for entry in directory.rglob('*'):
                if entry.is_symlink() or (not entry.is_dir() and not entry.is_file()):
                    raise Refusal('unsafe_storage')
                if entry.is_file():
                    names.add(str(entry.relative_to(directory)))
            return names
        if staged_files(path / 'records') != declared or not staged_files(path / 'moved') <= declared:
            raise Refusal('invalid_journal')
    entries = []
    for member in members:
        name = member.get('record')
        if not isinstance(name, str) or not NAME.fullmatch(name):
            raise Refusal('invalid_manifest')
        original = SESSIONS / name
        other = path / 'moved' / name if kind == 'archive' else ARCHIVE / archive_id / 'records' / name
        expected = member.get('sha256')
        original_raw = read_file(original) if original.exists() or original.is_symlink() else None
        other_raw = read_file(other) if other.exists() or other.is_symlink() else None
        if kind == 'archive':
            if original_raw is None and other_raw is None:
                raise Refusal('recovery_ambiguous')
            if original_raw is not None and other_raw is not None:
                original_info, other_info = os.stat(original), os.stat(other)
                if (sha(original_raw) != expected or sha(other_raw) != expected or
                        (original_info.st_dev, original_info.st_ino) != (other_info.st_dev, other_info.st_ino)):
                    raise Refusal('recovery_ambiguous')
            if sha(original_raw if original_raw is not None else other_raw) != expected:
                raise Refusal('recovery_changed')
        else:
            if other_raw is None or sha(other_raw) != expected:
                raise Refusal('backup_mismatch')
            if original_raw is not None and sha(original_raw) != expected:
                raise Refusal('recovery_changed')
        entries.append({'path': original, 'name': name, 'raw': original_raw,
                        'other': other, 'expected': expected})
    if kind == 'restore' and manifest.get('restored_at'):
        if any(entry['raw'] is None for entry in entries):
            raise Refusal('recovery_ambiguous')
        kind = 'restore_finalization'
    fingerprint = []
    for entry in entries:
        other_raw = read_file(entry['other']) if entry['other'].exists() else None
        fingerprint.append((entry['name'], sha(entry['raw']) if entry['raw'] is not None else 'missing',
                            sha(other_raw) if other_raw is not None else 'missing',
                            os.stat(entry['path']).st_ino if entry['raw'] is not None else None,
                            os.stat(entry['other']).st_ino if other_raw is not None else None))
    token = sha(json.dumps({'manifest': sha(raw_manifest), 'kind': kind,
                            'intent': intent_digest,
                            'pending_inode': pending_inode,
                            'fingerprint': fingerprint}, sort_keys=True).encode())[:20]
    return path, kind, entries, token, pending_inode


def recover(archive_id, confirm):
    path, kind, entries, token, pending_inode = recover_state(archive_id)
    if not confirm:
        action = 'finalize_restore' if kind == 'restore_finalization' else 'rollback_' + kind
        emit(True, 'recovery_preview', {'archive_id': archive_id, 'action': action,
                                       'confirmation_token': token, 'no_write': True})
    if confirm != token:
        raise Refusal('record_changed')
    if workflow_busy():
        raise Refusal('workflow_busy')
    lock_items = [{'path': entry['path']} for entry in entries]
    with locks(lock_items):
        if workflow_busy():
            raise Refusal('workflow_busy')
        current_path, current_kind, current_entries, current_token, current_inode = recover_state(archive_id)
        if current_token != token or current_kind != kind or current_inode != pending_inode:
            raise Refusal('record_changed')
        if kind == 'archive':
            existing = records()
            selected_names = {entry['name'] for entry in current_entries}
            active_bindings = {(item['data']['agent'], item['data']['native']['session_id'])
                               for item in existing if item['name'] not in selected_names}
            active_anchors = {item['data']['anchor'] for item in existing if item['name'] not in selected_names}
            for entry in current_entries:
                if entry['raw'] is None:
                    source = json.loads(read_file(entry['other']))
                    if ((source['agent'], source['native']['session_id']) in active_bindings or
                            source['anchor'] in active_anchors):
                        raise Refusal('native_rebound')
            try:
                for entry in current_entries:
                    if entry['raw'] is None:
                        move_file(entry['other'], entry['path'])
                    elif entry['other'].exists():
                        safe_unlink(entry['other'], entry['expected'])
            except (OSError, Refusal):
                raise Refusal('archive_recovery_required', {'no_write': False}) from None
        elif kind == 'restore':
            existing = records()
            selected_names = {entry['name'] for entry in current_entries}
            transaction_anchors = set()
            for entry in current_entries:
                if entry['raw'] is not None:
                    transaction_anchors.add(json.loads(entry['raw'])['anchor'])
            for item in existing:
                if item['name'] not in selected_names and (item['data'].get('lineage') or {}).get('parent_anchor') in transaction_anchors:
                    raise Refusal('recovery_lineage_conflict')
            try:
                for entry in current_entries:
                    if entry['raw'] is not None:
                        safe_unlink(entry['path'], entry['expected'])
            except (OSError, Refusal):
                raise Refusal('archive_recovery_required', {'no_write': False}) from None
        # A fully written restore with durable restored_at only needs the
        # lingering journal removed after an interrupted final cleanup.
        try:
            safe_remove_tree(current_path, expected_inode=current_inode)
        except (OSError, Refusal):
            raise Refusal('archive_recovery_required', {'no_write': False}) from None
    result = 'recovery_finalized' if kind == 'restore_finalization' else 'recovery_rolled_back'
    emit(True, result, {'archive_id': archive_id, 'action': kind,
                        'verification': verify_graph()})


def verify_graph():
    graph = subprocess.run([sys.executable, str(pathlib.Path(__file__).with_name('rig-session-resolve.py')),
                            '--graph-check'], capture_output=True, env=os.environ, check=False)
    return {'ok': graph.returncode == 0}


def apply_archive(anchors, days, acknowledge, token):
    if workflow_busy():
        raise Refusal('workflow_busy')
    chosen, _, reasons, observed = selected(anchors, days, acknowledge)
    if token != observed:
        raise Refusal('record_changed')
    if reasons:
        raise Refusal('archive_refused', {'refusal_reasons': reasons})
    with locks(chosen):
        if workflow_busy():
            raise Refusal('workflow_busy')
        current, reports, reasons, observed = selected(anchors, days, acknowledge)
        if observed != token or [item['name'] for item in current] != [item['name'] for item in chosen]:
            raise Refusal('record_changed')
        if reasons:
            raise Refusal('archive_refused', {'refusal_reasons': reasons})
        audit_preflight()
        if not ARCHIVE.exists() and not ARCHIVE.is_symlink():
            secure_mkdir(ARCHIVE)
        safe_dir(ARCHIVE, private=True)
        recovery_required()
        archive_id = secrets.token_hex(10)
        dest = ARCHIVE / ('.pending-' + archive_id)
        final = ARCHIVE / archive_id
        if final.exists() or final.is_symlink():
            raise Refusal('destination_exists')
        if dest.exists() or dest.is_symlink():
            raise Refusal('archive_recovery_required')
        secure_mkdir(dest)
        pending_inode = dest.stat().st_ino
        try:
            saved, moved = dest / 'records', dest / 'moved'
            secure_mkdir(saved)
            secure_mkdir(moved)
            for item in current:
                for base in (saved, moved):
                    if item['name'].startswith('done/'):
                        secure_mkdir(base / 'done')
                private_write(saved / item['name'], item['raw'])
            members = [{'record': item['name'], 'sha256': sha(item['raw']), 'size': len(item['raw']),
                        'mode': stat.S_IMODE(item['path'].stat().st_mode),
                        'anchor': item['data']['anchor'], 'agent': item['data']['agent'],
                        'state': item['data']['lifecycle']['state'],
                        'lineage_kind': (item['data'].get('lineage') or {}).get('kind', 'root')} for item in current]
            version_path = RIG / 'VERSION'
            rig_version = read_file(version_path).decode(errors='replace').strip() if version_path.exists() else 'unknown'
            manifest = {'schema_version': 1, 'archive_id': archive_id,
                        'archived_at': dt.datetime.now(dt.timezone.utc).isoformat(),
                        'project_identity': PROJECT_ID, 'older_than': days,
                        'acknowledge_active': acknowledge, 'rig_version': rig_version,
                        'reason': 'operator_confirmed_stale', 'members': members, 'evidence': reports}
            private_write(dest / 'manifest.json', (json.dumps(manifest, indent=2) + '\n').encode())
            for item in current:
                if read_file(saved / item['name']) != item['raw']:
                    raise Refusal('backup_mismatch')
        except Exception:
            safe_remove_tree(dest, expected_inode=pending_inode)
            raise
        try:
            for item in current:
                move_file(item['path'], moved / item['name'])
            rename_directory(dest, final)
        except (OSError, Refusal):
            raise Refusal('archive_recovery_required', {'no_write': False,
                                                         'next_step': 'bin/rig session archive --recover ' + archive_id + ' --json'}) from None
    return {'archive_id': archive_id, 'members': members,
            'audit_ok': audit_event('archive', archive_id, members)}


def restore_state(archive_id):
    safe_dir(ARCHIVE, private=True)
    dest = ARCHIVE / archive_id
    safe_dir(dest, private=True)
    safe_dir(dest / 'records', private=True)
    manifest_raw = read_file(dest / 'manifest.json')
    try:
        manifest = json.loads(manifest_raw)
    except (UnicodeError, ValueError):
        raise Refusal('invalid_manifest') from None
    if (not isinstance(manifest, dict) or type(manifest.get('schema_version')) is not int or
            manifest['schema_version'] != 1 or
            manifest.get('archive_id') != archive_id or manifest.get('project_identity') != PROJECT_ID or
            not isinstance(manifest.get('members'), list) or not manifest['members']):
        raise Refusal('invalid_manifest')
    current = records()
    anchors = {item['data']['anchor'] for item in current}
    natives = {(item['data']['agent'], item['data']['native']['session_id']) for item in current}
    restored = []
    seen_paths = set()
    seen_anchors = set()
    for member in manifest['members']:
        if not isinstance(member, dict):
            raise Refusal('invalid_manifest')
        name = member.get('record')
        if not isinstance(name, str) or not NAME.fullmatch(name):
            raise Refusal('invalid_manifest')
        member_anchor = member.get('anchor')
        if not isinstance(member_anchor, str) or not ANCHOR.fullmatch(member_anchor):
            raise Refusal('invalid_manifest')
        if name in seen_paths or member_anchor in seen_anchors:
            raise Refusal('invalid_manifest')
        seen_paths.add(name)
        seen_anchors.add(member_anchor)
        path = SESSIONS / name
        if path.exists() or path.is_symlink():
            raise Refusal('destination_exists')
        raw = read_file(dest / 'records' / name)
        if sha(raw) != member.get('sha256') or len(raw) != member.get('size'):
            raise Refusal('backup_mismatch')
        try:
            data = json.loads(raw)
        except (UnicodeError, ValueError):
            raise Refusal('backup_mismatch') from None
        if data.get('anchor') != member.get('anchor') or data.get('agent') != member.get('agent'):
            raise Refusal('backup_mismatch')
        if data['anchor'] in anchors:
            raise Refusal('anchor_in_use')
        if (data['agent'], (data.get('native') or {}).get('session_id')) in natives:
            raise Refusal('native_rebound')
        restored.append({'path': path, 'name': name, 'raw': raw, 'data': data})
    graph = components(current + restored)
    native_components = {}
    for item in current + restored:
        binding = (item['data']['agent'], item['data']['native']['session_id'])
        component = frozenset(graph[item['data']['anchor']])
        if binding in native_components and native_components[binding] != component:
            raise Refusal('invalid_manifest')
        native_components[binding] = component
    baseline = {'manifest': sha(manifest_raw),
                'destinations': [(item['name'], 'missing') for item in restored],
                'current': [(item['name'], sha(item['raw'])) for item in current]}
    token = sha(json.dumps(baseline, sort_keys=True).encode())[:20]
    return manifest, restored, token


def parse():
    values = {'--anchor': []}
    flags = set()
    args = sys.argv[1:]
    i = 0
    while i < len(args):
        key = args[i]
        if key in ('--json', '--list', '--acknowledge-active'):
            if key in flags:
                raise Refusal('invalid_input')
            flags.add(key)
            i += 1
        elif key in ('--anchor', '--older-than', '--confirm', '--restore', '--recover') and i + 1 < len(args):
            if key != '--anchor' and key in values:
                raise Refusal('invalid_input')
            value = args[i + 1]
            if not value or value.startswith('--'):
                raise Refusal('invalid_input')
            values.setdefault(key, []).append(value)
            i += 2
        else:
            raise Refusal('invalid_input')
    if any(not ANCHOR.fullmatch(anchor) for anchor in values['--anchor']):
        raise Refusal('invalid_input')
    try:
        days = int(values.get('--older-than', ['30'])[0])
    except ValueError:
        raise Refusal('invalid_input') from None
    if not 7 <= days <= 36500:
        raise Refusal('invalid_input')
    confirm, restore, recover_id = (values.get(key, [None])[0] for key in ('--confirm', '--restore', '--recover'))
    if any(value and not HEX.fullmatch(value) for value in (confirm, restore, recover_id)):
        raise Refusal('invalid_input')
    if '--list' in flags and (values['--anchor'] or confirm or restore or recover_id or '--older-than' in values):
        raise Refusal('invalid_input')
    if (restore or recover_id) and (values['--anchor'] or '--older-than' in values or '--acknowledge-active' in flags):
        raise Refusal('invalid_input')
    if restore and recover_id:
        raise Refusal('invalid_input')
    if not restore and not recover_id and '--list' not in flags and not values['--anchor']:
        raise Refusal('invalid_input')
    return values['--anchor'], days, confirm, restore, recover_id, '--acknowledge-active' in flags, '--list' in flags


def main():
    anchors, days, confirm, restore, recover_id, acknowledge, listing = parse()
    if recover_id:
        recover(recover_id, confirm)
    if listing:
        if not ARCHIVE.exists():
            emit(True, 'archive_list', {'archives': [], 'no_write': True})
        safe_dir(ARCHIVE, private=True)
        recovery_required()
        entries = []
        for path in sorted(ARCHIVE.iterdir()):
            if path.name.startswith('.'):
                continue
            if not HEX.fullmatch(path.name):
                raise Refusal('unsafe_storage')
            safe_dir(path, private=True)
            manifest = json.loads(read_file(path / 'manifest.json'))
            entries.append({'archive_id': path.name, 'archived_at': manifest.get('archived_at'),
                            'members': manifest.get('members'), 'restored_at': manifest.get('restored_at')})
        emit(True, 'archive_list', {'archives': entries, 'no_write': True})
    if restore:
        recovery_required()
        manifest, chosen, token = restore_state(restore)
        if not confirm:
            emit(True, 'restore_preview', {'archive_id': restore, 'members': manifest['members'],
                                          'confirmation_token': token, 'no_write': True})
        if confirm != token or workflow_busy():
            raise Refusal('record_changed' if confirm != token else 'workflow_busy')
        with locks(chosen):
            if workflow_busy():
                raise Refusal('workflow_busy')
            new_manifest, current, observed = restore_state(restore)
            if observed != token:
                raise Refusal('record_changed')
            audit_preflight()
            journal = ARCHIVE / ('.pending-restore-' + restore)
            if journal.exists() or journal.is_symlink():
                raise Refusal('archive_recovery_required')
            secure_mkdir(journal)
            journal_inode = journal.stat().st_ino
            manifest_raw = read_file(ARCHIVE / restore / 'manifest.json')
            intent = {'archive_id': restore, 'manifest_sha256': sha(manifest_raw),
                      'members': sorted((member['record'], member['sha256'])
                                        for member in new_manifest['members'])}
            private_write(journal / 'intent.json', (json.dumps(intent, sort_keys=True) + '\n').encode())
            written = []
            try:
                for item in current:
                    private_write(item['path'], item['raw'], staging_dir=journal)
                    written.append(item)
                resolver = pathlib.Path(__file__).with_name('rig-session-resolve.py')
                check = subprocess.run([sys.executable, str(resolver), '--graph-check'],
                                       capture_output=True, env=os.environ, check=False)
                if check.returncode != 0:
                    raise Refusal('invalid_restored_lineage')
            except (OSError, Refusal):
                raise Refusal('archive_recovery_required', {'no_write': False,
                                                             'next_step': 'bin/rig session archive --recover ' + restore + ' --json'}) from None
            new_manifest['restored_at'] = dt.datetime.now(dt.timezone.utc).isoformat()
            path = ARCHIVE / restore / 'manifest.json'
            try:
                private_replace(path, (json.dumps(new_manifest, indent=2) + '\n').encode())
            except (OSError, Refusal):
                raise Refusal('archive_recovery_required', {'no_write': False,
                                                             'next_step': 'bin/rig session archive --recover ' + restore + ' --json'}) from None
            try:
                safe_remove_tree(journal, expected_inode=journal_inode)
            except (OSError, Refusal):
                raise Refusal('archive_recovery_required', {'no_write': False,
                                                             'next_step': 'bin/rig session archive --recover ' + restore + ' --json'}) from None
        emit(True, 'archive_restored', {'archive_id': restore, 'members': new_manifest['members'],
                                      'audit_ok': audit_event('restore', restore, new_manifest['members']),
                                      'verification': verify(restore, new_manifest['members'], restored=True)})
    recovery_required()
    chosen, reports, reasons, token = selected(anchors, days, acknowledge)
    if not confirm:
        emit(True, 'archive_preview', {'records': reports, 'refusal_reasons': reasons,
                                       'confirmation_token': token, 'no_write': True,
                                       'warning': 'Resuming an archived active conversation creates a new Rig record; restore then refuses the old binding.'})
    result = apply_archive(anchors, days, acknowledge, confirm)
    emit(True, 'archived', {**result, 'verification': verify(result['archive_id'], result['members'], restored=False)})


def verify(archive_id, members, restored):
    rig_command = pathlib.Path(__file__).with_name('rig')
    doctor = subprocess.run([str(rig_command), 'session', 'doctor', '--json'],
                            capture_output=True, text=True, env=os.environ, check=False)
    checks = {'doctor_ok': doctor.returncode == 0, 'resolves': []}
    resolver = pathlib.Path(__file__).with_name('rig-session-resolve.py')
    for member in members:
        # The archive manifest deliberately omits native IDs. Read the private
        # saved record only for exact local verification; never print its ID.
        data = json.loads(read_file(ARCHIVE / archive_id / 'records' / member['record']))
        result = subprocess.run([sys.executable, str(resolver), '--agent', data['agent'],
                                 '--native-session-id', data['native']['session_id'], '--json'],
                                capture_output=True, text=True, env=os.environ, check=False)
        try:
            parsed = json.loads(result.stdout)
        except ValueError:
            parsed = {}
        expected = ('exact' if data['lifecycle']['state'] == 'active' else 'ended_record') if restored else 'not_found'
        observed = parsed.get('confidence') if restored and expected == 'exact' else parsed.get('reason')
        checks['resolves'].append({'anchor': member['anchor'], 'ok': observed == expected,
                                   'observed': observed})
    checks['ok'] = checks['doctor_ok'] and all(item['ok'] for item in checks['resolves'])
    return checks


if __name__ == '__main__':
    try:
        main()
    except Refusal as exc:
        emit(False, exc.reason, {'no_write': True, **exc.detail}, 3)
    except (OSError, UnicodeError, ValueError, TypeError):
        emit(False, 'storage_or_record_error', {'no_write': True}, 4)
