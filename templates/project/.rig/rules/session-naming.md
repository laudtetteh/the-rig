# Session-local naming contract

Session names describe only work performed in the current conversation/session.
Apply this contract whenever `/session-name`, `/wrap`, `/post-merge`, or the
generated Codex `$session-name` skill proposes or updates a name.

## Authoritative evidence

1. Current conversation context is authoritative.
2. A `tentative_name` in the session file resolved for this launch may recover
   current-session intent after compaction.
3. PROGRESS entries tagged with the resolved current session UUID may
   cross-check the conversation.

Every unit in a proposed name must be attributable to at least one source above.
When sources conflict, use the current conversation and discard the conflicting
file evidence.

## Evidence that must never contribute name units

- `CONTEXT_SNAPSHOT.md`, including any legacy `Session name` field
- unscoped or legacy `<!-- session-end -->` marker ranges
- session files not selected by the resolver, including files under
  `sessions/done/`
- PROGRESS entries tagged with another session UUID
- branch history, commits, PRs, issues, task records, or project state not known
  from the current conversation/session

These sources may inform project housekeeping, but they must not be appended to,
merged into, or used as fallback for the current session name.

## Raw or unresolved launches

If `bin/rig session resolve --json` cannot identify this launch unambiguously,
an explicit naming request may continue with current conversation context only.
A workflow that must write or complete session state fails closed instead. In
either case, do not inspect unrelated session files, legacy markers, or snapshots
to recover a name. If the current conversation contains too little evidence, say
that no reliable name can be suggested yet; never inherit a prior-session name.

## Final contamination check

Before presenting a suggestion, compare every unit against the allowed evidence.
Remove any unit sourced only from project history or another session. If removal
leaves no units, do not propose a name.
