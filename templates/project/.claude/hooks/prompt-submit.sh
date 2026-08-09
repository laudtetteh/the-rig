#!/usr/bin/env bash
# prompt-submit.sh
#
# Runs on every user prompt (UserPromptSubmit event).
# Checks for .wrap-needed and .post-merge-pending flag files and injects
# a warning into context if either is set — so the agent sees the flag
# whether it was set at session start or mid-session (e.g. after a commit).
#
# Also fires a one-time nudge when the project's permission allowlist is
# sparse, suggesting /fewer-permission-prompts to reduce session friction.
#
# Session handoff suggestion: when a session has been active longer than the
# documented threshold, suggest /handoff-checklist once. This is a consent
# gate only; the hook never runs /wrap, /post-merge, or any checklist step.
#
# Must be fast: UserPromptSubmit has a 30-second timeout.
# When no flags are set and the nudge has already been offered, exits immediately.
#
# Output: JSON {"additionalContext": "..."} when there is something to surface.
# Claude Code receives this as context alongside the user's message.

REPO=$(git rev-parse --show-toplevel 2>/dev/null)
[[ -z "$REPO" ]] && exit 0

if [[ -f "$REPO/.rigpath" ]]; then
  RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
else
  RIG_DIR="$REPO/.rig"
fi

WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
POST_MERGE_PENDING="$RIG_DIR/memory/.post-merge-pending"
NUDGE_FLAG="$RIG_DIR/memory/.permission-nudge-offered"
HANDOFF_SUGGESTED="$RIG_DIR/memory/.handoff-suggested"

# Fast path: no flags AND nudge already evaluated — exit immediately
if [[ ! -f "$WRAP_NEEDED" && ! -f "$POST_MERGE_PENDING" && -f "$NUDGE_FLAG" && -f "$HANDOFF_SUGGESTED" ]]; then
  exit 0
fi

# Build warning text for housekeeping flags
WARNINGS=""
if [[ -f "$WRAP_NEEDED" ]]; then
  WARNINGS+="⚠️ The last session ended without running /wrap. CONTEXT_SNAPSHOT.md may be stale and PROGRESS.md has unexpanded entries. Run /wrap now to capture session state before starting new work — or say 'skip wrap' to proceed anyway."
fi
if [[ -f "$POST_MERGE_PENDING" ]]; then
  [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
  MERGE_SHA=$(sed -n 's/^merge_sha=//p' "$POST_MERGE_PENDING" 2>/dev/null | head -1)
  MERGED_AT=$(sed -n 's/^merged_at=//p' "$POST_MERGE_PENDING" 2>/dev/null | head -1)
  MERGE_DETAIL=""
  [[ -n "$MERGE_SHA" ]] && MERGE_DETAIL=" Merge: ${MERGE_SHA}"
  [[ -n "$MERGED_AT" ]] && MERGE_DETAIL+=" at ${MERGED_AT}."
  [[ -n "$MERGE_DETAIL" && "$MERGE_DETAIL" != *. ]] && MERGE_DETAIL+="."
  WARNINGS+="⚠️ A merge landed since /post-merge was last run.${MERGE_DETAIL} Memory may not reflect the merged state. Run /post-merge now — or say 'skip for current task' to proceed without clearing the reminder."
fi

# Session-size/cost benchmark — default 2 hours elapsed wall-clock for the
# active session. This intentionally suggests only; the user must explicitly
# agree before /handoff-checklist runs any checklist work.
if [[ ! -f "$HANDOFF_SUGGESTED" ]] && command -v python3 >/dev/null 2>&1; then
  HANDOFF_SECONDS="${RIG_HANDOFF_ELAPSED_SECONDS:-7200}"
  SESSION_DIR="$RIG_DIR/memory/sessions"
  handoff_age=$(SESSION_DIR="$SESSION_DIR" HANDOFF_SECONDS="$HANDOFF_SECONDS" python3 - <<'PYEOF' 2>/dev/null || true
import datetime as dt
import glob
import json
import os

threshold = int(os.environ.get("HANDOFF_SECONDS", "7200"))
now = dt.datetime.now(dt.timezone.utc)
best = 0
for path in glob.glob(os.path.join(os.environ["SESSION_DIR"], "session-*.json")):
    try:
        with open(path) as fh:
            doc = json.load(fh)
        if doc.get("status") != "active":
            continue
        raw = str(doc.get("started_at", "")).replace("Z", "+00:00")
        started = dt.datetime.fromisoformat(raw)
        if started.tzinfo is None:
            started = started.replace(tzinfo=dt.timezone.utc)
        age = int((now - started.astimezone(dt.timezone.utc)).total_seconds())
        best = max(best, age)
    except Exception:
        continue
print(best if best >= threshold else "")
PYEOF
)
  if [[ -n "$handoff_age" ]]; then
    touch "$HANDOFF_SUGGESTED" 2>/dev/null || true
    [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
    WARNINGS+="Rig handoff suggestion: this session has been active for about $((handoff_age / 60)) minutes. Want to wrap and hand off to a new session? Reply explicitly before I run /handoff-checklist; silence or an ambiguous reply is not consent."
  fi
fi

# Permission nudge — once per project when allowlist is sparse
if [[ ! -f "$NUDGE_FLAG" ]] && command -v python3 >/dev/null 2>&1; then
  SETTINGS="$REPO/.claude/settings.json"
  if [[ -f "$SETTINGS" ]]; then
    allowed_count=$(python3 -c "
import json, sys
try:
    d = json.load(open('$SETTINGS'))
    print(len(d.get('permissions', {}).get('allow', [])))
except Exception:
    print(99)
" 2>/dev/null || echo 99)
    touch "$NUDGE_FLAG"
    if [[ "$allowed_count" -lt 5 ]]; then
      [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
      WARNINGS+="Tip: run /fewer-permission-prompts to build a permission allowlist from your session history — reduces repetitive prompts without affecting oversight of write operations."
    fi
  fi
fi

# Exit cleanly if nothing to report
[[ -z "$WARNINGS" ]] && exit 0

# Output JSON additionalContext
if command -v python3 >/dev/null 2>&1; then
  printf '%s' "$WARNINGS" | python3 -c "
import json, sys
warnings = sys.stdin.read()
print(json.dumps({'additionalContext': warnings}))
" 2>/dev/null || true
fi

exit 0
