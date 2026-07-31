#!/usr/bin/env bash
# Deterministic, local-only feature discovery catalog.
#
# Adapters set REPO, RIG_DIR, and RIG_TIP_SOURCE, then call collect_contextual_tip.
# Catalog rows are: priority|id|evidence function|suppression function|copy.
# Evidence and suppression names are static; project content is never evaluated.

tip_command_available() {
  [[ -f "$REPO/.claude/commands/$1.md" ]]
}

tip_command_already_used() {
  local command="$1"
  grep -Fq -- "/$command" "$RIG_DIR/memory/PROGRESS.md" \
    "$RIG_DIR/memory/CONTEXT_SNAPSHOT.md" 2>/dev/null
}

evidence_errors_logged() {
  [[ -f "$RIG_DIR/memory/ERRORS.md" ]] &&
    grep -Eq '^## \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] — ' "$RIG_DIR/memory/ERRORS.md" 2>/dev/null
}
suppress_debug() { ! tip_command_available debug || tip_command_already_used debug; }

evidence_gaps_logged() {
  [[ -f "$RIG_DIR/memory/RIG_GAPS.md" ]] &&
    grep -Eq '^## \[[0-9]{4}-[0-9]{2}-[0-9]{2}\] — ' "$RIG_DIR/memory/RIG_GAPS.md" 2>/dev/null
}
suppress_rig_gaps() { ! tip_command_available rig-gaps || tip_command_already_used rig-gaps; }

evidence_reviewable_branch() {
  local branch base ahead
  branch=$(git -C "$REPO" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [[ -n "$branch" && "$branch" != "main" && "$branch" != "master" ]] || return 1
  if git -C "$REPO" show-ref --verify --quiet refs/heads/main; then
    base=main
  elif git -C "$REPO" show-ref --verify --quiet refs/heads/master; then
    base=master
  else
    return 1
  fi
  ahead=$(git -C "$REPO" rev-list --count "$base..HEAD" 2>/dev/null || printf '0')
  [[ "$ahead" =~ ^[0-9]+$ ]] && [[ "$ahead" -ge 2 ]]
}
suppress_code_review() { ! tip_command_available code-review || tip_command_already_used code-review; }

evidence_sprint() {
  [[ -f "$RIG_DIR/memory/PROGRESS.md" ]] || return 1
  local count
  count=$(grep -oE '\[#[0-9]+\]' "$RIG_DIR/memory/PROGRESS.md" 2>/dev/null | sort -u | wc -l | tr -d ' ')
  [[ "${count:-0}" -ge 3 ]]
}
suppress_sprint() { ! tip_command_available sprint || tip_command_already_used sprint; }

evidence_task_tracking() {
  local sessions active
  sessions=$(find "$RIG_DIR/memory/sessions" -type f -name 'session-*.json' 2>/dev/null | wc -l | tr -d ' ')
  active=$(find "$RIG_DIR/tasks/active" -maxdepth 1 -type f -name '*.md' ! -name 'TASK_example*' 2>/dev/null | wc -l | tr -d ' ')
  [[ "${sessions:-0}" -gt 1 && "${active:-0}" -eq 0 ]]
}
suppress_task_tracking() { ! tip_command_available task || tip_command_already_used task; }

evidence_session_name() {
  local count
  count=$(git -C "$REPO" rev-list --count HEAD 2>/dev/null || printf '0')
  [[ "$count" =~ ^[0-9]+$ ]] && [[ "$count" -ge 1 ]]
}
suppress_session_name() { ! tip_command_available session-name || tip_command_already_used session-name; }

evidence_fewer_prompts() { return 0; }
suppress_fewer_prompts() { [[ -f "$RIG_DIR/memory/.fewer-prompts-enabled" ]]; }

tip_catalog() {
  cat <<'CATALOG'
100|debug-errors|evidence_errors_logged|suppress_debug|Tip: ERRORS.md contains a recorded failure. Run /debug to investigate the observed error with a saved hypothesis trail.
90|rig-gaps|evidence_gaps_logged|suppress_rig_gaps|Tip: RIG_GAPS.md contains workflow friction. Run /rig-gaps to review and format the observed gaps for action.
80|code-review|evidence_reviewable_branch|suppress_code_review|Tip: this feature branch is at least two commits ahead of its base. Run /code-review for a focused review before shipping.
70|sprint|evidence_sprint|suppress_sprint|Tip: PROGRESS.md references at least three distinct issues. Run /sprint to plan and batch that multi-issue work.
60|task-tracking|evidence_task_tracking|suppress_task_tracking|Tip: multiple sessions exist with no active task. Run /task to give multi-file work a recovery anchor.
50|session-name|evidence_session_name|suppress_session_name|Tip: this repository has committed work. Run /session-name to anchor this session with a name that survives compaction.
40|fewer-prompts|evidence_fewer_prompts|suppress_fewer_prompts|Tip: permission-pattern scanning is off. Touch $RIG_DIR/memory/.fewer-prompts-enabled to scan for fewer safe prompts at every /wrap.
CATALOG
}

collect_contextual_tip() {
  [[ "$RIG_TIP_SOURCE" == "startup" || "$RIG_TIP_SOURCE" == "resume" ]] || return 0
  [[ -f "$RIG_DIR/memory/.rig-tips-disabled" ]] && return 0

  local priority id evidence suppression copy sentinel
  local best_priority=-1 best_id="" best_copy=""
  while IFS='|' read -r priority id evidence suppression copy; do
    [[ "$priority" =~ ^[0-9]+$ && -n "$id" && "$evidence" =~ ^[a-z_]+$ && "$suppression" =~ ^[a-z_]+$ ]] || continue
    sentinel="$RIG_DIR/memory/tips/.tip-${id}-shown"
    [[ -f "$sentinel" ]] && continue
    "$evidence" 2>/dev/null || continue
    "$suppression" 2>/dev/null && continue
    if [[ "$priority" -gt "$best_priority" ]]; then
      best_priority="$priority"
      best_id="$id"
      best_copy="$copy"
    fi
  done < <(tip_catalog)

  [[ -n "$best_id" ]] || return 0
  mkdir -p "$RIG_DIR/memory/tips" 2>/dev/null || return 0
  touch "$RIG_DIR/memory/tips/.tip-${best_id}-shown" 2>/dev/null || return 0
  printf '%s' "$best_copy"
}
