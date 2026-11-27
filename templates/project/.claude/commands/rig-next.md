# Command: /rig-next

Read-only status and next-action report for the exact current Rig session.

## What this does

Answer “what is still open in this session, what is next in the repository, and what should I do next?” Gather the evidence below and render it in the stated order. Do not edit files, create issues, update PRs, change labels, or run a workflow that writes state.

## Step 1 — Resolve the exact session

1. Resolve `REPO=$(git rev-parse --show-toplevel)` and `$RIG_DIR` with `python3 "$REPO/bin/rig-path.py" "$REPO"`.
2. Run `"$REPO/bin/rig" session resolve --json`. Treat the session as current only when the result is `state: active`, `confidence: exact`, and includes an anchor. If it is missing or ambiguous, state that session-scoped details cannot be verified; do not infer them from another record.
3. Read `.wrap-needed` and `.post-merge-pending` under `$RIG_DIR/memory/` if present.

## Step 2 — Report work open from this session

Use the current conversation for decisions and work discussed but not yet ticketed. Cross-check the exact session's open-decision ledger with:

```bash
"$REPO/bin/rig" session decision list --json
```

The ledger is private to `$RIG_DIR/memory/session-decisions/<anchor>.json`; list does not modify it. Include each unresolved question, proposed change, or approval request the agent raised while continuing without waiting. When an agent asks such a non-blocking question, it must immediately append it with `rig session decision append --question "..."`; when the user answers, close that entry with its ID and answer. Do not record blocking questions that are waiting for an answer.

Report:

- Uncommitted or unpushed work, including changed paths and branch ahead/behind state.
- Open PRs and draft PRs; include their head SHA and CI state only when checks are for that exact SHA. State when GitHub data cannot be fetched.
- Pending approvals and unanswered ledger entries.
- Work the user discussed that has not been ticketed.
- `.wrap-needed` and `.post-merge-pending` flags.

Use read-only Git and GitHub queries. If `gh` is unavailable, say which facts could not be checked.

## Step 3 — Report repository next actions

Read `CONTEXT_SNAPSHOT.md` under `$RIG_DIR/memory/` and the `Next action` checkpoints in active task cards under `$RIG_DIR/tasks/active/`. List blocked work with its precise unblock condition. Do not treat a backlog title or an old snapshot as newer than live GitHub state.

## Step 4 — Recommend one next action

End with one concrete action and one short reason, taking dependencies, approvals, current branch state, and pending housekeeping into account. Keep the report concise. If nothing can safely start, identify the exact missing approval or prerequisite.
