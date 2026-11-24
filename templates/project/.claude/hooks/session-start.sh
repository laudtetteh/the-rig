#!/usr/bin/env bash
# session-start.sh
#
# Runs at Claude Code session start (SessionStart event).
# Injects context before the first turn so the agent is oriented without
# relying on instruction-dependent file reading — hook-enforced orientation.
#
# Source values and behaviour:
#   startup / resume  — inject CONTEXT_SNAPSHOT.md + housekeeping flag warnings
#   compact           — inject .compact-checkpoint.md (PreCompact output);
#                       falls back to CONTEXT_SNAPSHOT.md if checkpoint absent
#   clear             — inject minimal orientation (project name + run /rig-status)
#
# Session identity: creates $RIG_DIR/memory/sessions/session-{PPID}.json and
# /tmp/.rig-session-{PPID}.uuid on startup/resume/compact/clear. These anchor
# all PROGRESS entries and session-end markers to a specific session, enabling
# multi-session isolation and post-compaction name recovery.
#
# Output: JSON with hookSpecificOutput.additionalContext
# Falls through silently (exit 0, no output) on any error or missing files.

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO" ]] && exit 0

RIG_DIR=$(python3 "$REPO/bin/rig-path.py" "$REPO") || exit 2

# ── Provider-correct housekeeping reminders ──────────────────────────────────
# Keep this block identical in prompt-submit.sh and session-start.sh; a test
# compares the two copies. It reads only local files and Git objects, because
# UserPromptSubmit must never wait on the network.

# Print a Rig workflow invocation in the active provider's syntax, or a
# provider-neutral name when the provider is unknown.
rig_workflow_invocation() {
  case "${RIG_AGENT:-claude}" in
    claude) printf '/%s' "$1" ;;
    codex) printf '$%s' "$1" ;;
    *) printf 'the %s workflow' "$1" ;;
  esac
}

# Print how long ago an ISO-8601 timestamp with a UTC offset was, or nothing.
rig_merge_age() {
  command -v python3 >/dev/null 2>&1 || return 0
  python3 -c '
import datetime, sys
try:
    then = datetime.datetime.fromisoformat(sys.argv[1])
    if then.tzinfo is None:
        raise ValueError
    seconds = int((datetime.datetime.now(datetime.timezone.utc) - then).total_seconds())
    if seconds < 0:
        raise ValueError
    if seconds < 60:
        print("just now")
    else:
        count, unit = ((seconds // 60, "minute") if seconds < 3600 else
                       (seconds // 3600, "hour") if seconds < 86400 else
                       (seconds // 86400, "day"))
        print("%d %s%s ago" % (count, unit, "" if count == 1 else "s"))
except (ValueError, OverflowError):
    pass
' "$1" 2>/dev/null || true
}

# Print " Merge: <short SHA> (<subject or PR #N: title>) at <time>, <age>."
# from a .post-merge-pending marker. Marker values are untrusted data: only a
# hexadecimal SHA is ever passed to Git.
rig_merge_detail() {
  local marker="$1" sha merged_at label subject pr title age detail=""
  sha=$(sed -n 's/^merge_sha=//p' "$marker" 2>/dev/null | head -1)
  merged_at=$(sed -n 's/^merged_at=//p' "$marker" 2>/dev/null | head -1)
  [[ "$sha" == unknown ]] && sha=""
  [[ "$merged_at" == unknown ]] && merged_at=""
  if [[ -n "$sha" ]]; then
    label="$sha"
    if [[ "$sha" =~ ^[0-9a-fA-F]{7,64}$ ]] && git -C "$REPO" cat-file -e "${sha}^{commit}" 2>/dev/null; then
      label=$(git -C "$REPO" rev-parse --short "$sha" 2>/dev/null || printf '%s' "$sha")
      subject=$(git -C "$REPO" log -1 --format=%s "$sha" 2>/dev/null || true)
      pr=$(printf '%s' "$subject" | sed -n 's/^Merge pull request #\([0-9][0-9]*\) .*/\1/p')
      if [[ -n "$pr" ]]; then
        title=$(git -C "$REPO" log -1 --format=%b "$sha" 2>/dev/null | sed -n '/[^[:space:]]/{p;q;}')
        subject="PR #${pr}${title:+: $title}"
      fi
      [[ -n "$subject" ]] && label+=" ($subject)"
    fi
    detail=" Merge: $label"
  fi
  if [[ -n "$merged_at" ]]; then
    age=$(rig_merge_age "$merged_at")
    if [[ -n "$detail" ]]; then
      detail+=" at $merged_at"
    else
      detail=" Merged at $merged_at"
    fi
    [[ -n "$age" ]] && detail+=", $age"
  fi
  [[ -n "$detail" ]] && detail+="."
  printf '%s' "$detail"
}

# Print the pending-merge reminder in the active provider's syntax.
rig_post_merge_warning() {
  local invocation
  invocation=$(rig_workflow_invocation post-merge)
  printf '⚠️ A merge landed since %s was last run.%s Memory may not reflect the merged state. Run %s now — or say '"'"'skip for current task'"'"' to proceed without clearing the reminder.' \
    "$invocation" "$(rig_merge_detail "$1")" "$invocation"
}

# Print the missed-wrap reminder in the active provider's syntax.
rig_wrap_warning() {
  local invocation
  invocation=$(rig_workflow_invocation wrap)
  printf '⚠️ The last session ended without running %s. CONTEXT_SNAPSHOT.md may be stale and PROGRESS.md has unexpanded entries. Run %s now to capture session state before starting new work — or say '"'"'skip wrap'"'"' to proceed anyway.' \
    "$invocation" "$invocation"
}
# ── End provider-correct housekeeping reminders ──────────────────────────────

INPUT=$(cat)

# Parse source from stdin JSON
SOURCE=""
NATIVE_SESSION_ID=""
ROOT_SESSION_ID=""
PARENT_NATIVE_SESSION_ID=""
NATIVE_TITLE=""
AGENT_ID=""
if command -v python3 >/dev/null 2>&1; then
  _identity_input=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    d=json.load(sys.stdin)
    def text(value): return value if isinstance(value, str) else ''
    print(json.dumps([
        text(d.get('source')), text(d.get('session_id')),
        text(d.get('root_session_id', d.get('rootSessionId'))),
        text(d.get('forked_from_id', d.get('forkedFromId'))),
        text(d.get('session_title')), text(d.get('agent_id'))
    ]))
except Exception:
    pass
" 2>/dev/null || true)
  SOURCE=$(printf '%s' "$_identity_input" | python3 -c 'import json,sys; print(json.load(sys.stdin)[0])' 2>/dev/null || true)
  NATIVE_SESSION_ID=$(printf '%s' "$_identity_input" | python3 -c 'import json,sys; print(json.load(sys.stdin)[1])' 2>/dev/null || true)
  ROOT_SESSION_ID=$(printf '%s' "$_identity_input" | python3 -c 'import json,sys; print(json.load(sys.stdin)[2])' 2>/dev/null || true)
  PARENT_NATIVE_SESSION_ID=$(printf '%s' "$_identity_input" | python3 -c 'import json,sys; print(json.load(sys.stdin)[3])' 2>/dev/null || true)
  NATIVE_TITLE=$(printf '%s' "$_identity_input" | python3 -c 'import json,sys; print(json.load(sys.stdin)[4])' 2>/dev/null || true)
  AGENT_ID=$(printf '%s' "$_identity_input" | python3 -c 'import json,sys; print(json.load(sys.stdin)[5])' 2>/dev/null || true)
fi

SNAPSHOT="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
POST_MERGE_PENDING="$RIG_DIR/memory/.post-merge-pending"
SESSION_DIR="$RIG_DIR/memory/sessions"
SESSION_PID="${RIG_SESSION_PID:-$PPID}"
SESSION_FILE="${RIG_SESSION_FILE:-$SESSION_DIR/session-${SESSION_PID}.json}"

# A documented native hook ID is authoritative. Bind it before any lifecycle
# work; launcher/PID files are migration hints only and cannot override it.
if [[ -n "$NATIVE_SESSION_ID" && -n "$AGENT_ID" && -x "$REPO/bin/rig" ]]; then
  # Provider-documented subagent hooks retain the root session ID and add
  # agent_id. Resolve read-only: a child must never bootstrap or rename a root.
  BIND_RESULT=$("$REPO/bin/rig" session resolve --agent "${RIG_AGENT:-claude}" --native-session-id "$NATIVE_SESSION_ID" --json 2>/dev/null) || exit 0
  SESSION_FILE=$(printf '%s' "$BIND_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])' 2>/dev/null) || exit 0
  SESSION_UUID=$(printf '%s' "$BIND_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])' 2>/dev/null) || exit 0
  export RIG_SESSION_FILE="$SESSION_FILE" RIG_SESSION_ANCHOR="$SESSION_UUID"
elif [[ -n "$NATIVE_SESSION_ID" && -x "$REPO/bin/rig" ]]; then
  BIND_ARGS=(--agent "${RIG_AGENT:-claude}" --native-session-id "$NATIVE_SESSION_ID" --source "$SOURCE")
  [[ -n "$ROOT_SESSION_ID" ]] && BIND_ARGS+=(--root-session-id "$ROOT_SESSION_ID")
  [[ -n "$PARENT_NATIVE_SESSION_ID" ]] && BIND_ARGS+=(--parent-native-session-id "$PARENT_NATIVE_SESSION_ID")
  [[ -n "$NATIVE_TITLE" ]] && BIND_ARGS+=(--native-title "$NATIVE_TITLE")
  [[ "$SOURCE" == resume ]] && BIND_ARGS+=(--allow-continuation)
  BIND_RESULT=$(RIG_SESSION_PID="$SESSION_PID" "$REPO/bin/rig" session bind "${BIND_ARGS[@]}" 2>/dev/null) || exit 0
  SESSION_FILE=$(printf '%s' "$BIND_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["session_file"])' 2>/dev/null) || exit 0
  SESSION_UUID=$(printf '%s' "$BIND_RESULT" | python3 -c 'import json,sys; print(json.load(sys.stdin)["anchor"])' 2>/dev/null) || exit 0
  export RIG_SESSION_FILE="$SESSION_FILE" RIG_SESSION_ANCHOR="$SESSION_UUID"
fi

# ── Helpers ───────────────────────────────────────────────────────────────────

flag_warnings() {
  local w=""
  if [[ -f "$WRAP_NEEDED" ]]; then
    w+="$(rig_wrap_warning)"
  fi
  if [[ -f "$POST_MERGE_PENDING" ]]; then
    [[ -n "$w" ]] && w+=$'\n\n'
    w+="$(rig_post_merge_warning "$POST_MERGE_PENDING")"
  fi
  printf '%s' "$w"
}

emit_context() {
  local ctx="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$ctx" | python3 -c "
import json, os, sys
ctx = sys.stdin.read()
out = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': ctx
    }
}
title = os.environ.get('RIG_PUBLIC_SESSION_TITLE', '')
if title:
    out['hookSpecificOutput']['sessionTitle'] = title
print(json.dumps(out))
" 2>/dev/null || true
  fi
}

# Create a new session file and /tmp UUID sentinel for this process.
# Uses env vars for all dynamic values to avoid injection via branch names.
create_session_identity() {
  mkdir -p "$SESSION_DIR"
  local branch uuid started
  branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  uuid=$(python3 -c "import uuid; print(str(uuid.uuid4())[:8])" 2>/dev/null \
    || printf '%s' "$(date +%s)" | md5sum 2>/dev/null | cut -c1-8 \
    || date +%s)
  started=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
  [[ -n "${RIG_SESSION_ANCHOR:-}" ]] && uuid="$RIG_SESSION_ANCHOR"
  RIG_ANC="$uuid" RIG_PID="$SESSION_PID" RIG_STARTED="$started" RIG_BRANCH="$branch" \
  python3 -c "
import json, os
print(json.dumps({
    'anchor': os.environ['RIG_ANC'],
    'pid': int(os.environ['RIG_PID']),
    'started_at': os.environ['RIG_STARTED'],
    'branch': os.environ['RIG_BRANCH'],
    'tentative_name': None,
    'final_name': None,
    'status': 'active'
}, indent=2))
" 2>/dev/null > "$SESSION_FILE" || true
  printf '%s' "$uuid" > "/tmp/.rig-session-${SESSION_PID}.uuid" 2>/dev/null || true
}

# Evaluates the shared deterministic catalog and emits at most one tip.
# The catalog is project-local so future adapters can source the same lifecycle rules.
collect_tips() {
  local catalog="$RIG_DIR/contextual-tips.sh"
  [[ -r "$catalog" ]] || return 0
  # shellcheck source=/dev/null
  source "$catalog" 2>/dev/null || return 0
  RIG_TIP_SOURCE="$SOURCE" collect_contextual_tip 2>/dev/null || true
}

# Restore /tmp UUID from an existing session file (e.g. after tmp cleanse or restart).
restore_session_uuid() {
  local existing_uuid
  # Pass SESSION_FILE via env var — avoids python3 SyntaxError if path contains a quote.
  existing_uuid=$(SESSION_F="$SESSION_FILE" python3 -c "
import json, os
try:
    print(json.load(open(os.environ['SESSION_F'])).get('anchor',''))
except Exception:
    pass
" 2>/dev/null || true)
  [[ -n "$existing_uuid" ]] && printf '%s' "$existing_uuid" > "/tmp/.rig-session-${SESSION_PID}.uuid" 2>/dev/null || true
}

# ── Dispatch by source ────────────────────────────────────────────────────────

case "$SOURCE" in
  startup|resume|fork)
    [[ ! -f "$SNAPSHOT" ]] && exit 0

    # ── Create or restore session identity ───────────────────────────────────
    if [[ ! -f "$SESSION_FILE" ]]; then
      create_session_identity
    else
      # Always restore /tmp sentinel — may have been cleared by tmp cleanse or restart
      restore_session_uuid
    fi
    # ─────────────────────────────────────────────────────────────────────────

    # Passive cleanup: remove stale compact checkpoints older than 1 day.
    find "$RIG_DIR/memory" -name ".compact-checkpoint-*.md" -mtime +1 -delete 2>/dev/null || true

    CONTEXT=$(cat "$SNAPSHOT")
    WARNINGS=$(flag_warnings)
    TIPS=$(collect_tips 2>/dev/null || true)

    FULL_CTX="$CONTEXT"
    [[ -n "$WARNINGS" ]] && FULL_CTX="${WARNINGS}"$'\n\n---\n\n'"${FULL_CTX}"
    [[ -n "$TIPS" ]]    && FULL_CTX="${FULL_CTX}"$'\n\n---\n\n'"Rig tip relay: say exactly this to the user before other work: ${TIPS}"
    if [[ -z "$AGENT_ID" && "${RIG_AGENT:-claude}" == "claude" && -f "$SESSION_FILE" ]]; then
      RIG_PUBLIC_SESSION_TITLE=$(SESSION_F="$SESSION_FILE" python3 -c 'import json,os; d=json.load(open(os.environ["SESSION_F"])); n=d.get("names",{}); print(n.get("display_title") or n.get("final") or n.get("tentative") or "")' 2>/dev/null || true)
      export RIG_PUBLIC_SESSION_TITLE
    fi
    emit_context "$FULL_CTX"
    ;;

  compact)
    # ── Re-establish session identity after compaction ────────────────────────
    # Two scenarios:
    #   A) Same process (in-session compaction): PPID unchanged, session file exists.
    #   B) New process (new tab from compacted context): different PPID, no session
    #      file for this PPID. Fall back to reading anchor from the most recent
    #      compact checkpoint written by pre-compact.sh.
    SESSION_UUID="${RIG_SESSION_ANCHOR:-}"
    PRIOR_CKPT=""
    if [[ -f "$SESSION_FILE" ]]; then
      # Scenario A — same process
      # Pass SESSION_FILE via env var to avoid SyntaxError if path contains a quote.
      SESSION_UUID=$(SESSION_F="$SESSION_FILE" python3 -c "
import json, os
try:
    d = json.load(open(os.environ['SESSION_F']))
    print(d.get('anchor') or '')
except Exception:
    pass
" 2>/dev/null || true)
    else
      # Scenario B — new process; find anchor from most recent checkpoint.
      # Skip checkpoints that belong to a live concurrent session (their PPID
      # has an active session file) to avoid cross-session identity clobbering.
      mkdir -p "$SESSION_DIR"
      while IFS= read -r _ckpt; do
        [[ -f "$_ckpt" ]] || continue
        _ckpt_ppid=$(basename "$_ckpt" .md | sed 's/.*-//')
        _ckpt_sf="$SESSION_DIR/session-${_ckpt_ppid}.json"
        if [[ -f "$_ckpt_sf" ]] && grep -q '"status": "active"' "$_ckpt_sf" 2>/dev/null; then
          continue  # checkpoint belongs to a live session — skip
        fi
        PRIOR_CKPT="$_ckpt"
        break
      done < <(ls -t "$RIG_DIR/memory"/.compact-checkpoint-*.md 2>/dev/null || true)
      if [[ -n "$PRIOR_CKPT" ]] && [[ -f "$PRIOR_CKPT" ]]; then
        SESSION_UUID=$(grep "^\*\*Session anchor:\*\*" "$PRIOR_CKPT" 2>/dev/null \
          | sed 's/\*\*Session anchor:\*\* *//' | tr -d '[:space:]')
        [[ "$SESSION_UUID" == "none" ]] && SESSION_UUID=""
        PRIOR_TENTATIVE=$(grep "^\*\*Session tentative name:\*\*" "$PRIOR_CKPT" 2>/dev/null \
          | sed 's/\*\*Session tentative name:\*\* *//')
        [[ "$PRIOR_TENTATIVE" == "none" ]] && PRIOR_TENTATIVE=""
      fi
      if [[ -n "$SESSION_UUID" ]]; then
        # Create a new session file for this process, inheriting the prior anchor.
        # Uses env vars to avoid injection risk from branch names or tentative names.
        compact_branch=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
        compact_started=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S)
        RIG_ANC="$SESSION_UUID" RIG_PID="$SESSION_PID" RIG_STARTED="$compact_started" \
        RIG_BRANCH="$compact_branch" RIG_TENT="${PRIOR_TENTATIVE:-}" \
        python3 -c "
import json, os
t = os.environ.get('RIG_TENT') or None
print(json.dumps({
    'anchor': os.environ['RIG_ANC'],
    'pid': int(os.environ['RIG_PID']),
    'started_at': os.environ['RIG_STARTED'],
    'branch': os.environ['RIG_BRANCH'],
    'tentative_name': t,
    'final_name': None,
    'status': 'active',
    'continued_from_compaction': True
}, indent=2))
" 2>/dev/null > "$SESSION_FILE" || true
      fi
    fi
    [[ -n "$SESSION_UUID" ]] && printf '%s' "$SESSION_UUID" \
      > "/tmp/.rig-session-${SESSION_PID}.uuid" 2>/dev/null || true
    # ─────────────────────────────────────────────────────────────────────────

    COMPACT_CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint-${SESSION_UUID:-$SESSION_PID}.md"
    if [[ ! -f "$COMPACT_CHECKPOINT" ]]; then
      if [[ -n "$NATIVE_SESSION_ID" ]]; then
        # Exact native identity must never consume another session's checkpoint.
        COMPACT_CHECKPOINT=""
      else
      # In Scenario B, reuse the checkpoint already found during identity resolution
      # to avoid a second ls scan that could pick a different (possibly wrong) file.
      COMPACT_CHECKPOINT="${PRIOR_CKPT:-}"
      if [[ -z "$COMPACT_CHECKPOINT" ]]; then
        COMPACT_CHECKPOINT=$(ls -t "$RIG_DIR/memory"/.compact-checkpoint-*.md 2>/dev/null | head -1 || true)
      fi
      fi
    fi
    if [[ -n "$COMPACT_CHECKPOINT" ]] && [[ -f "$COMPACT_CHECKPOINT" ]]; then
      CONTEXT=$(cat "$COMPACT_CHECKPOINT")
    elif [[ -f "$SNAPSHOT" ]]; then
      CONTEXT=$(cat "$SNAPSHOT")
    else
      exit 0
    fi
    WARNINGS=$(flag_warnings)
    if [[ -n "$WARNINGS" ]]; then
      emit_context "${WARNINGS}"$'\n\n---\n\n'"${CONTEXT}"
    else
      emit_context "$CONTEXT"
    fi
    ;;

  clear)
    # /clear continues the same process (same PPID), so reuse the existing
    # session file and UUID if they exist. Create fresh only if absent.
    if [[ ! -f "$SESSION_FILE" ]]; then
      create_session_identity
    else
      restore_session_uuid
    fi

    PROJECT_NAME=$(basename "$REPO")
    emit_context "Project: ${PROJECT_NAME}. Session cleared — run $(rig_workflow_invocation status) for current state."
    ;;

  *)
    # Unknown source or unparseable input — fail silently
    exit 0
    ;;
esac

exit 0
