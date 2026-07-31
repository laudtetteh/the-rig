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
#   clear             — inject minimal orientation (project name + run /status)
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

if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

INPUT=$(cat)

# Parse source from stdin JSON
SOURCE=""
if command -v python3 >/dev/null 2>&1; then
  SOURCE=$(printf '%s' "$INPUT" | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('source', ''))
except Exception:
    pass
" 2>/dev/null || true)
fi

SNAPSHOT="$RIG_DIR/memory/CONTEXT_SNAPSHOT.md"
WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
POST_MERGE_PENDING="$RIG_DIR/memory/.post-merge-pending"
SESSION_DIR="$RIG_DIR/memory/sessions"
SESSION_PID="${RIG_SESSION_PID:-$PPID}"
SESSION_FILE="${RIG_SESSION_FILE:-$SESSION_DIR/session-${SESSION_PID}.json}"

# ── Helpers ───────────────────────────────────────────────────────────────────

flag_warnings() {
  local w=""
  if [[ -f "$WRAP_NEEDED" ]]; then
    w+="⚠️ The last session ended without running /wrap. CONTEXT_SNAPSHOT.md may be stale and PROGRESS.md has unexpanded entries. Run /wrap now to capture session state before starting new work — or say 'skip wrap' to proceed anyway."
  fi
  if [[ -f "$POST_MERGE_PENDING" ]]; then
    [[ -n "$w" ]] && w+=$'\n\n'
    w+="⚠️ A merge landed since /post-merge was last run. Memory may not reflect the merged state. Run /post-merge now — or say 'skip post-merge' to proceed anyway."
  fi
  printf '%s' "$w"
}

emit_context() {
  local ctx="$1"
  if command -v python3 >/dev/null 2>&1; then
    printf '%s' "$ctx" | python3 -c "
import json, sys
ctx = sys.stdin.read()
out = {
    'hookSpecificOutput': {
        'hookEventName': 'SessionStart',
        'additionalContext': ctx
    }
}
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

# Returns tip text if the named tip should fire (and hasn't fired before).
# Creates the per-tip sentinel on first call to prevent repeats.
# Never called when .rig-tips-disabled exists — that check lives in collect_tips.
show_tip() {
  local name="$1"
  local text="$2"
  local sentinel="$RIG_DIR/memory/tips/.tip-${name}-shown"
  [[ -f "$sentinel" ]] && return 0
  mkdir -p "$RIG_DIR/memory/tips" 2>/dev/null || true
  touch "$sentinel" 2>/dev/null || true
  printf '%s' "$text"
}

# Evaluates all tip conditions and returns any tips that should fire, newline-separated.
# Returns empty string if opt-out is set or no tip conditions are met.
collect_tips() {
  [[ -f "$RIG_DIR/memory/.rig-tips-disabled" ]] && return 0

  local tips="" t=""

  # Tip: session-name — fires after the first commit
  local commit_count
  commit_count=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || echo 0)
  commit_count=$((commit_count + 0))
  if [[ "$commit_count" -ge 1 ]]; then
    t=$(show_tip "session-name" \
      "Tip: run /session-name any time to anchor this session — names survive compaction." \
      2>/dev/null || true)
    [[ -n "$t" ]] && tips+="${t}"$'\n\n'
  fi

  # Tip: fewer-prompts — fires once a snapshot exists and the feature isn't already on
  if [[ ! -f "$RIG_DIR/memory/.fewer-prompts-enabled" ]]; then
    t=$(show_tip "fewer-prompts" \
      "Tip: touch \$RIG_DIR/memory/.fewer-prompts-enabled to auto-scan permission patterns at every /wrap." \
      2>/dev/null || true)
    [[ -n "$t" ]] && tips+="${t}"$'\n\n'
  fi

  # Tip: task-tracking — fires after second session with no active task
  local session_count active_tasks
  session_count=$(ls "$RIG_DIR/memory/sessions"/session-*.json 2>/dev/null | wc -l || echo 0)
  session_count=$((session_count + 0))
  active_tasks=$(ls "$RIG_DIR/tasks/active"/*.md 2>/dev/null \
    | grep -v "TASK_example" | wc -l || echo 0)
  active_tasks=$((active_tasks + 0))
  if [[ "$session_count" -gt 1 ]] && [[ "$active_tasks" -eq 0 ]]; then
    t=$(show_tip "task-tracking" \
      "Tip: Use /task to track multi-file work. Issues gate commits; tasks give the agent a recovery anchor." \
      2>/dev/null || true)
    [[ -n "$t" ]] && tips+="${t}"$'\n\n'
  fi

  # Tip: sprint — fires when 3+ distinct issue refs appear in PROGRESS.md
  if [[ -f "$RIG_DIR/memory/PROGRESS.md" ]]; then
    local issue_count
    issue_count=$(grep -oE '\[#[0-9]+\]' "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null \
      | sort -u | wc -l || echo 0)
    issue_count=$((issue_count + 0))
    if [[ "$issue_count" -ge 3 ]]; then
      t=$(show_tip "sprint" \
        "Tip: Use /sprint to plan and batch parallel issues." \
        2>/dev/null || true)
      [[ -n "$t" ]] && tips+="${t}"$'\n\n'
    fi
  fi

  tips="${tips%$'\n\n'}"
  printf '%s' "$tips"
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
  startup|resume)
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
    [[ -n "$TIPS" ]]    && FULL_CTX="${FULL_CTX}"$'\n\n---\n\n'"${TIPS}"
    emit_context "$FULL_CTX"
    ;;

  compact)
    # ── Re-establish session identity after compaction ────────────────────────
    # Two scenarios:
    #   A) Same process (in-session compaction): PPID unchanged, session file exists.
    #   B) New process (new tab from compacted context): different PPID, no session
    #      file for this PPID. Fall back to reading anchor from the most recent
    #      compact checkpoint written by pre-compact.sh.
    SESSION_UUID=""
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

    COMPACT_CHECKPOINT="$RIG_DIR/memory/.compact-checkpoint-${SESSION_PID}.md"
    if [[ ! -f "$COMPACT_CHECKPOINT" ]]; then
      # In Scenario B, reuse the checkpoint already found during identity resolution
      # to avoid a second ls scan that could pick a different (possibly wrong) file.
      COMPACT_CHECKPOINT="${PRIOR_CKPT:-}"
      if [[ -z "$COMPACT_CHECKPOINT" ]]; then
        COMPACT_CHECKPOINT=$(ls -t "$RIG_DIR/memory"/.compact-checkpoint-*.md 2>/dev/null | head -1 || true)
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
    emit_context "Project: ${PROJECT_NAME}. Session cleared — run /status for current state."
    ;;

  *)
    # Unknown source or unparseable input — fail silently
    exit 0
    ;;
esac

exit 0
