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
# Branch drift: when the exact session named by the payload's session_id was
# bound on a different branch than the checkout's current HEAD, warn once per
# change and suggest a dedicated worktree.
#
# Must be fast: UserPromptSubmit has a 30-second timeout.
# When no flags are set and the nudge has already been offered, exits immediately.
#
# Output: JSON {"additionalContext": "..."} when there is something to surface.
# Claude Code receives this as context alongside the user's message.

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

WRAP_NEEDED="$RIG_DIR/memory/.wrap-needed"
POST_MERGE_PENDING="$RIG_DIR/memory/.post-merge-pending"
NUDGE_FLAG="$RIG_DIR/memory/.permission-nudge-offered"
HANDOFF_SUGGESTED="$RIG_DIR/memory/.handoff-suggested"
WARNINGS=""

# ── Branch change under the exact active session ─────────────────────────────
# Another terminal or session can switch a shared checkout's branch. Compare the
# exactly resolved session's recorded branch with HEAD and warn once per change.
# The acknowledged branch lives in a per-session marker beside the session
# records (sessions/ is gitignored and only session-*.json is ever scanned), so
# this hook never rewrites the schema-v1 record or contends for its revision.

# Print how to start a session in the active provider's syntax.
rig_session_launcher() {
  case "${RIG_AGENT:-claude}" in
    claude) printf '`bin/rig claude`' ;;
    codex) printf '`bin/rig codex`' ;;
    *) printf 'a new agent session' ;;
  esac
}

# Print a branch name for people, naming a detached HEAD explicitly.
rig_branch_label() {
  local short
  if [[ "$1" != HEAD ]]; then
    printf '%s' "$1"
  elif [[ "$2" == current ]] && short=$(git -C "$REPO" rev-parse --short HEAD 2>/dev/null); then
    printf 'detached HEAD at %s' "$short"
  else
    printf 'a detached HEAD'
  fi
}

# Print the branch-change warning for a resolver JSON result, at most once per
# change, and record the acknowledged branch. Prints nothing otherwise.
rig_branch_change_warning() {
  local fields anchor recorded current marker acknowledged tmp target bootstrap=""
  fields=$(printf '%s' "$1" | python3 -c '
import json, sys
try:
    d = json.load(sys.stdin)
    anchor, branch = d.get("anchor"), d.get("branch")
    if (d.get("confidence") == "exact" and isinstance(anchor, str) and isinstance(branch, str)
            and anchor and branch and not any(c in anchor + branch for c in "\t\n\r")):
        print(anchor + "\t" + branch)
except (ValueError, TypeError, AttributeError):
    pass
' 2>/dev/null) || return 0
  [[ -n "$fields" ]] || return 0
  anchor="${fields%%$'\t'*}"
  recorded="${fields#*$'\t'}"
  [[ "$anchor" =~ ^[A-Za-z0-9._-]+$ && "$recorded" != unknown ]] || return 0
  current=$(git -C "$REPO" rev-parse --abbrev-ref HEAD 2>/dev/null) || return 0
  [[ -n "$current" ]] || return 0
  marker="$RIG_DIR/memory/sessions/.branch-ack-$anchor"
  if [[ "$current" == "$recorded" ]]; then
    # Back on the recorded branch: re-arm the warning for a later change.
    [[ -e "$marker" ]] && rm -f "$marker" 2>/dev/null
    return 0
  fi
  if [[ -f "$marker" ]]; then
    IFS= read -r acknowledged < "$marker" 2>/dev/null || true
    [[ "$acknowledged" == "$current" ]] && return 0
  fi
  tmp=$(mktemp "$RIG_DIR/memory/sessions/.branch-ack.tmp.XXXXXX" 2>/dev/null) || return 0
  if ! { printf '%s\n' "$current" > "$tmp" && mv -f "$tmp" "$marker"; } 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 0
  fi
  target="<branch>"
  [[ "$recorded" != HEAD ]] && target="$(printf '%q' "$recorded")"
  [[ -f "$REPO/.rigpath" ]] && bootstrap='run `bin/rig worktree bootstrap` there, then '
  printf '⚠️ Branch changed under this session: it was bound on %s, but this checkout is now on %s. Another session or terminal may have switched the shared checkout. Confirm which branch this work belongs on before editing or committing. For parallel work, give each session its own worktree: `git worktree add <path> %s`, then %sstart the session there with %s.' \
    "$(rig_branch_label "$recorded" recorded)" "$(rig_branch_label "$current" current)" "$target" "$bootstrap" "$(rig_session_launcher)"
}
# ── End branch change under the exact active session ─────────────────────────

# Some clients resume an already-loaded thread without another SessionStart.
# UserPromptSubmit still carries the exact native session ID. Attach it once,
# or start a continuation after a completed wrap, before the flag fast path.
PROMPT_PAYLOAD=$(cat)
PROMPT_AGENT="${RIG_AGENT:-claude}"
if [[ "$PROMPT_AGENT" == codex || "$PROMPT_AGENT" == claude ]]; then
  PROMPT_NATIVE_ID=$(printf '%s' "$PROMPT_PAYLOAD" | python3 -c '
import json,sys
try:
    event=json.load(sys.stdin)
    if event.get("hook_event_name",event.get("hookEventName"))!="UserPromptSubmit": raise ValueError()
    value=event.get("session_id")
    if not isinstance(value,str) or not value: raise ValueError()
    print(value)
except (ValueError,TypeError,AttributeError):
    pass
' 2>/dev/null || true)
  if [[ -n "$PROMPT_NATIVE_ID" && -x "$REPO/bin/rig" ]]; then
    RESOLVE_STATUS=0
    RESOLVED=$("$REPO/bin/rig" session resolve --agent "$PROMPT_AGENT" --native-session-id "$PROMPT_NATIVE_ID" --json) || RESOLVE_STATUS=$?
    if [[ "$RESOLVE_STATUS" -ne 0 ]]; then
      RESOLVE_REASON=$(printf '%s' "$RESOLVED" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("reason") or "resolver_failed")' 2>/dev/null || printf resolver_failed)
      if [[ "$RESOLVE_REASON" == not_found || "$RESOLVE_REASON" == ended_record ]]; then
        BIND_ARGS=(session bind --agent "$PROMPT_AGENT" --native-session-id "$PROMPT_NATIVE_ID" --source prompt_resume --json)
        [[ "$RESOLVE_REASON" == ended_record ]] && BIND_ARGS+=(--allow-continuation)
        BIND_STATUS=0
        BOUND=$("$REPO/bin/rig" "${BIND_ARGS[@]}") || BIND_STATUS=$?
        if [[ "$BIND_STATUS" -ne 0 ]]; then
          WARNINGS="Rig could not attach this $PROMPT_AGENT session ($RESOLVE_REASON); run session doctor before naming or wrapping it."
        fi
      else
        WARNINGS="Rig session identity is unresolved ($RESOLVE_REASON); stop before naming or completing a session record."
      fi
    else
      BRANCH_WARNING=$(rig_branch_change_warning "$RESOLVED")
      [[ -n "$BRANCH_WARNING" ]] && WARNINGS="$BRANCH_WARNING"
    fi
  fi
fi

# Fast path: no flags AND nudge already evaluated — exit immediately
# The permission nudge names a Claude Code built-in; other providers never
# evaluate it, and must not consume the project-wide once-only flag.
NUDGE_PENDING=false
[[ "${RIG_AGENT:-claude}" == claude && ! -f "$NUDGE_FLAG" ]] && NUDGE_PENDING=true
if [[ -z "$WARNINGS" && ! -f "$WRAP_NEEDED" && ! -f "$POST_MERGE_PENDING" && "$NUDGE_PENDING" == false && -f "$HANDOFF_SUGGESTED" ]]; then
  exit 0
fi

# Build warning text for housekeeping flags
if [[ -f "$WRAP_NEEDED" ]]; then
  [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
  WARNINGS+="$(rig_wrap_warning)"
fi
if [[ -f "$POST_MERGE_PENDING" ]]; then
  [[ -n "$WARNINGS" ]] && WARNINGS+=$'\n\n'
  WARNINGS+="$(rig_post_merge_warning "$POST_MERGE_PENDING")"
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
    WARNINGS+="Rig handoff suggestion: this session has been active for about $((handoff_age / 60)) minutes. Want to wrap and hand off to a new session? Reply explicitly before I run $(rig_workflow_invocation handoff-checklist); silence or an ambiguous reply is not consent."
  fi
fi

# Permission nudge — once per project when allowlist is sparse
if [[ "$NUDGE_PENDING" == true ]] && command -v python3 >/dev/null 2>&1; then
  SETTINGS="$REPO/.claude/settings.json"
  if [[ -f "$SETTINGS" ]]; then
    allowed_count=$(python3 -c "
import json, sys
try:
    d = json.load(open(sys.argv[1]))
    print(len(d.get('permissions', {}).get('allow', [])))
except Exception:
    print(99)
" "$SETTINGS" 2>/dev/null || echo 99)
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
