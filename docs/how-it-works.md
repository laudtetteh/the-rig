# How The Rig works

> Coexistence: The Rig’s shared `.rig` processes run across Claude Code and Codex. Provider adapters expose the same workflows through Claude commands/hooks and Codex skills/hooks; provider-specific mechanics below are labeled explicitly.

A technical deep-dive into the architecture, components, and session lifecycle. For short definitions of recurring terms, see the [glossary](glossary.md).

---

## The core insight

AI coding agents are powerful but stateless. Without explicit structure:

- Every session starts from zero
- Conventions drift because there's no enforcement
- Mistakes repeat because there's no log
- Irreversible actions happen because there's no gate

The Rig solves this at three levels:

1. **Memory** — persistent context that survives session resets
2. **Process** — structured workflows the agent follows step-by-step
3. **Enforcement** — provider and Git hooks that reject covered operations when installed and enabled

---

## Two-layer architecture

Three locations work together. The installer repo produces the other two:

```
┌─────────────────────────────────────────────────────────────────┐
│  THE INSTALLER  (~/tools/the-rig/)                              │
│  Cloned once. Run install.sh to produce the two layers below.   │
│                                                                 │
│  ~/tools/the-rig/install.sh    ← interactive setup script      │
│  ~/tools/the-rig/templates/    ← source files for both layers   │
│  ~/tools/the-rig/VERSION       ← current Rig version            │
│                                                                 │
│  Key flags (for non-interactive / agent-driven installs):       │
│    --global-only               install only global layer        │
│    --project-only              install only project layer       │
│    --target <path>             project directory to install to  │
│    --tracking repo|local|external|stealth  tracking mode        │
│    --strategy merge|upgrade|overwrite|skip  file handling       │
│      also: agent-plan (read-only JSON plan, zero writes)        │
│            agent-upgrade (applies + JSON result; exit 3 if      │
│            anything needs manual review — see UPGRADE_WORKFLOW) │
│                                                                 │
│  To upgrade: git -C ~/tools/the-rig pull --ff-only origin main  │
│  Then re-run install.sh with --strategy upgrade                 │
└───────────────┬─────────────────────────┬───────────────────────┘
                │ installs global layer    │ installs project layer
                ▼                         ▼
┌──────────────────────────┐  ┌───────────────────────────────────┐
│  GLOBAL LAYER            │  │  PROJECT LAYER                    │
│  (~/.claude/)            │  │  (tracking configurable)          │
│  Once per machine.       │  │  Once per project.                │
│                          │  │                                   │
│  ~/.claude/CLAUDE.md     │  │  CLAUDE.md       ← project brain  │
│    └─ Hard rules,        │  │  .rig/           ← Rig system     │
│       working style,     │  │  .rig/processes/ ← workflows      │
│       memory discipline, │  │  .rig/rules/     ← standards      │
│       planning, git,     │  │  .rig/memory/    ← PROGRESS +     │
│       code quality,      │  │                    ERRORS +        │
│       personal context,  │  │                    SNAPSHOT        │
│       skill trigger table│  │  .rig/tasks/     ← backlog/active/│
│                          │  │                    done            │
│  ~/.claude/skills/       │  │  .claude/        ← hooks +        │
│    ├─ rig-debug-basics/  │  │                    commands        │
│    ├─ rig-review-basics/ │  │  .husky/         ← git hooks      │
│    ├─ refactor.md        │  │  .github/        ← PR + issue     │
│    ├─ write-tests.md     │  │                    templates       │
│    └─ explain.md         │  └───────────────────────────────────┘
│  ~/.claude/commands/     │
│    └─ rig-upgrade.md     │
│  ~/.agents/skills/       │
│    └─ generated Codex    │
│       personal skills    │
│                          │
└──────────────────────────┘
```

Claude Code loads its global layer natively. Codex consumes generated personal
skills and supported instruction files. At project scope, both providers share
the same `.rig/` memory, rules, and processes: `.claude/` is the Claude adapter,
`.agents/skills/` contains generated Codex skills, and `.codex/` contains the
Codex hook adapter. The installer repo runs only during install or upgrade.

---

## Session lifecycle

```
Session starts
     │
     ▼
session-start.sh fires (SessionStart hook)
     │  Reads CONTEXT_SNAPSHOT.md + checks .wrap-needed / .post-merge-pending
     │  Injects snapshot content and any warnings as additionalContext
     │  (before the first user turn — no manual file read required)
     │
     ▼
Selected provider loads its supported global instructions
     │  Hard rules, working style, memory discipline, personal context
     │
     ▼
CLAUDE.md instructs: read ./CLAUDE.md
     │  Project identity, stack, conventions
     │
     ▼
CLAUDE.md instructs: check .rig/memory/CONTEXT_SNAPSHOT.md
     │  Already injected by hook above — agent confirms or loads from disk if absent
     │  If it exists → sufficient for orientation. Stop here.
     │  If absent or stale → load .rig/memory/PROGRESS.md (last 20 entries only)
     │
     ▼
CLAUDE.md instructs: read ./.rig/memory/ERRORS.md
     │  Known pitfalls to avoid (only if snapshot absent/stale)
     │
     ▼
CLAUDE.md instructs: skim ./.rig/memory/DECISIONS.md
     │  Significant architectural and process decisions (skim only)
     │
     ▼
CLAUDE.md instructs: read the installed task path
     │  What task is currently in flight in a standard install
     │
     ▼
Agent is oriented. Hooks are live. Ready to work.
     │
     │  On every user prompt:
     │  └─ prompt-submit.sh (UserPromptSubmit)
     │       Re-checks pending flags and re-injects warnings
     │       Warns on an exact session's branch change
     │
     │  On every permission request:
     │  └─ permission-request.sh (PermissionRequest)
     │       Auto-approves read-only patterns and Markdown notes in
     │       Rig memory/, tasks/, docs/
     │
     │  Before every tool call:
     │  └─ pre-tool.sh (PreToolUse)
     │       Protected-path check, commit gate, main-branch guard, worktree redirect
     │
     │  After every tool call:
     │  └─ post-tool.sh (PostToolUse)
     │       PROGRESS.md fallback stub for approved visible guarded commits
     │
     │  Before context compaction:
     │  └─ pre-compact.sh (PreCompact)
     │       Writes .compact-checkpoint.md; outputs compactionSummary JSON
     │
     │  After context compaction:
     │  └─ post-compact.sh (PostCompact)
     │       Injects checkpoint as additionalContext; restores working context
     │
     │  When a subagent spawns, if installed with --subagents:
     │  └─ subagent-start.sh (SubagentStart)
     │       Injects project name, branch, active task, key conventions
     │
     │  After the agent's final message each turn:
     │  └─ stop.sh (Stop)
     │       Appends a session-end marker to PROGRESS.md (UUID-tagged when the anchor is available)
     │       Leaves an existing shared snapshot unchanged
     │       (lightweight; idempotent — safe to run after every response)
     │
     ▼
Claude /wrap or Codex $wrap — run manually before closing
     │  Refreshes the shared snapshot header and this session's task handoffs
     │  while preserving other active sessions' handoffs
     │  Expands PROGRESS.md stubs; trims if > 20 entries
     │  Logs ERRORS.md and RIG_GAPS.md entries
     │  Trims ERRORS.md if > 30 entries
     │  Suggests a name from current conversation and resolved current-session evidence
     └─ Surfaces next priority
     │
     ▼
Session ends
     │
     └─ stop.sh (also handles SessionEnd — same script, dispatches on `source` field)
          On logout/prompt_input_exit: writes .wrap-needed; creates a minimal checkpoint only if no snapshot exists
          On clear: logs context-cleared; no .wrap-needed
          On resume: no action; Stop (per-turn): PROGRESS marker only
```

In a shared Rig directory, an exact native SessionEnd attributes an unexpanded
auto-logged commit only when its PROGRESS heading carries that session's
`<!-- sid:... -->` marker. A stub without a session anchor leaves a project-wide
`.wrap-needed` reminder for review; it does not assign another session a wrap
obligation. A later full wrap can clear that reminder with explicit legacy
adoption. Legacy sessions retain the unscoped reminder path.
Wrap records the reminder's content and file metadata token when it acquires
the workflow lock. At completion it adopts an older unscoped reminder only if
that token still matches and no unexpanded untagged progress stub remains.
An unexpanded stub tagged to the current session blocks finalization until
that new work is captured in the wrap.
Another session's pending work stays visible. Legacy SessionEnd refreshes
the unscoped marker's generation, so an existing empty marker cannot hide a
newer reminder.
An older hook that only touches an existing nonempty marker and writes no
PROGRESS stub leaves no origin to recover if a later scoped writer replaces
that marker. Upgrade that hook to the generation-writing version.

---

## The memory system

Seven files, seven purposes:

### .rig/memory/CONTEXT_SNAPSHOT.md
- **The primary orientation file** — written at session end via `/wrap`
- **Gitignored** — lives on disk only, never committed
- Contains: project state, open PRs, backlog priority, key decisions, known footguns, environment notes
- When it exists, the agent reads *only this* at session start. PROGRESS.md is skipped.
- What allows a new session to orient in seconds rather than minutes

### .rig/memory/PROGRESS.md
- Append-only build log, one entry per meaningful unit of work
- Auto-stubbed by Git's `post-commit` hook after a guarded agent commit; PostToolUse uses a matching Git result as a fallback when that hook does not log
- `stop.sh` appends session-end markers for housekeeping, UUID-tagged when the anchor is available. Naming never uses legacy marker ranges, snapshots, unrelated session files, or project history; current conversation context is authoritative and only the resolved current session's UUID-tagged entries may cross-check it.
- Most recent entry at the top
- **Trim convention:** capped at 20 entries. `/wrap` moves older entries to `.rig/memory/PROGRESS_archive.md` (gitignored, disk-only) when the cap is exceeded. Keeps session startup cost low indefinitely.

### .rig/memory/ERRORS.md
- Pitfall log — every non-obvious bug logged with structured format
- Format: Symptom → Root cause → Fix → Watch for
- The most valuable file in the system — it's institutional memory
- **Trim convention:** capped at 30 entries. `/wrap` moves older entries to `.rig/memory/ERRORS_archive.md` (gitignored, disk-only) when the cap is exceeded. Same pattern as PROGRESS.md.

### .rig/memory/DECISIONS.md
- Structured log of significant architectural, product, and process decisions
- Format per entry: Context → Decision → Rejected → Rationale → Consequences
- Committed (unlike CONTEXT_SNAPSHOT) — decisions are project history, not session state
- Skimmed at session start; the agent logs to it when a non-obvious choice is made

### .rig/memory/PROJECT_CONVENTIONS.md
- Current, durable project operating rules and preferences only
- Every addition, removal, or material change requires explicit user approval
- Agent-writable and committed so approved conventions follow the project across machines
- Always read at session start, even when `CONTEXT_SNAPSHOT.md` is current
- Excludes secrets, transient state, copied governance policy, historical rationale,
  and inferred or merely suggested preferences
- Consequential choices and their alternatives/rationale remain in `DECISIONS.md`

### .rig/memory/RIG_GAPS.md
- Self-improvement feedback log — committed to every project repo
- Captures workflow friction, bugs, missing features, and improvement ideas observed during real use
- Appended automatically by `/wrap` (step 5) when the agent notices Rig-related friction
- Submitted to The Rig dev session via `/rig-gaps` command; entries marked `[submitted]` after delivery
- Accumulates across sessions and machines — the mechanism by which real-world use improves The Rig

### .rig/memory/.rig-manifest
- Written by the installer on every install under the effective `$RIG_DIR`; Git visibility follows the chosen storage path and exclusions (`repo` mode leaves `.rig/` eligible for tracking)
- Records the SHA256 hash of each Rig-owned file at install time
- Used by the **Upgrade** strategy to detect user customizations:
  - Hash unchanged since install → safe to auto-update
  - Hash changed → you've customized it → diff shown before overwrite
- A JSON companion, `.rig-manifest.json`, carries richer per-artifact
  provenance for every tracked path (not just Rig-owned ones): `owner`,
  `source`, `type`, `mode`, `installer_version`, and (since issue #444 lane
  444-B) `base_revision`/`generator`/`provider` — provenance metadata used by
  the historical-base resolver and `bin/rig doctor`. `base_revision` only
  orders the scan; the merge base is proven by SHA256 equality against rendered
  release-tagged template content. An entry written before lane 444-B simply lacks these
  three fields (legacy/unknown provenance, not an error). A `base_revision`
  claiming an installer version newer than the one currently running (issue
  #463) is reported as its own `future_revision` finding, distinct from
  `malformed`, and causes the same refuse-with-guidance behavior (exit `3` in
  agent mode) as any other unresolved finding.
- See `docs/customizing.md` for the full Upgrade strategy workflow, the
  manifest metadata field reference, and the agent-driven `agent-plan`/
  `agent-upgrade` contract

---

## The process system

Nine process files define step-by-step behaviour across task intake, work
modes, sprint planning, shipping, debugging, connector preflight, upgrades,
post-merge housekeeping, and Rig gaps triage. Examples:

### NEW_TASK_WORKFLOW
```
Step 0: Configured tracker reference first (GitHub by default; skip for `none`) — /task enforces this at intake
Step 1: Confirm working directory (main repo root, never a worktree path)
Step 2: Orient (read SNAPSHOT → PROGRESS if needed → ERRORS → task file)
Step 3: Confirm understanding — restate goal, files, risks. Wait for approval.
Step 4: Plan — write numbered plan into task file. Wait for approval.
Step 5: Implement — one step at a time, surface surprises
Step 6: Verify — run tests, check acceptance criteria
Step 7: Wrap up — audit plan vs. reality; structured Done notes; move task; update PROGRESS;
        log ERRORS; log RIG_GAPS; commit
```

### SHIP_WORKFLOW
```
Step 0:   For GitHub tracking, create the issue before code; commit references [#N]. Skip for `none`.
Step 1:   Pre-ship checklist (AC, no debug code, no secrets, Docker verification)
Step 2:   Self-review — does this do ONLY what was asked?
Step 2.4: Derive and run 1–5 task-specific live checks; record results, skips, and risk
Step 2.5: Show the commit gate evidence block, then the optional copyable validation card;
          approval covers what the block lists, not a claim the user reviewed the diff
Step 3:   Commit (conventional format, issue reference; one-use sentinel via Git hook or visible-command fallback)
Step 4:   Update memory (verify task file accuracy; move task; PROGRESS; SNAPSHOT; ERRORS;
          RIG_GAPS; close GitHub Issue with actual-scope comment)
Step 5:   Open PR (body describes what was actually built; read template; labels at creation time)
```

### DEBUG_WORKFLOW
```
Step 1: Reproduce first — don't touch code until you can reproduce
Step 2: Isolate — which layer? which function? always/conditional?
Step 3: Inspect — state hypothesis before reading code
Step 4: Fix — smallest possible change
Step 5: Verify — no regressions
Step 6: Log — ERRORS.md entry, always
```

### POST_MERGE_WORKFLOW
```
Step 1: Fetch base and verify each exact merge SHA; fast-forward only for tracked housekeeping
Step 2: Update PROGRESS.md
Step 3: Move task file active/ → done/
Step 4: Refresh the shared CONTEXT_SNAPSHOT.md header while preserving task handoffs
Step 5: Check ERRORS.md and RIG_GAPS.md
Step 6: Housekeeping commit (if needed)
Step 7: Suggest session name (derives name from session work)
Step 8: Surface next priority — ask "What's next?"
```

---

## Snapshot handoff recovery

The snapshot writer saves a content-hashed backup when it retires or transfers
a task handoff or migrates a legacy snapshot. To recover a missing handoff,
list the backups:

```bash
bin/rig memory restore-snapshot --list --json
```

Pass a listed filename to `--from` to preview its missing sections. Add
`--section` with the task ID to select one handoff. Add `--confirm` only after
reviewing that preview.

The restore verifies the backup hash and runs under the snapshot writer lock.
It inserts only sections absent from the current snapshot; it keeps the current
shared header and every existing handoff. Before applying, it saves the current
view as a `restore-<digest>.md` backup. A section already present requires the
normal writer or a reviewed manual edit to change it.

---

## Session identity and continuation

| Moment | Record state | Naming and obligation rule |
|---|---|---|
| Active work | One active record for the exact project, provider and native thread | Names and obligations update only that record. |
| Memory checkpoint | The same active record | Saving context does not complete or rename the session. |
| Wrap completed | Record moves to `sessions/done/` with `lifecycle.state: complete` | Its final name stays with that work segment. |
| Later work in the same native thread | A new active record with `lineage.kind: continuation` and `parent_anchor` | The parent name is not copied. New work can be named and wrapped independently. |

Invoke Claude `/wrap --checkpoint` or Codex `$wrap --checkpoint` explicitly to
save a mid-session handoff. It requires an exact active Rig record, reports
dirty files and memory changes before writing, then updates project memory and
the session's owned snapshot sections under the workflow lock. It leaves the
record, name, lineage and wrap/post-merge obligations untouched. Repeated
checkpoints preserve other sessions' handoffs. A later plain `/wrap` runs the
normal finalization gates. A real provider SessionEnd can still end the record;
a subsequent native resume may create a continuation anchor.

### Cross-project Rig record index

`bin/rig session index --stale --project current --json` adds age, local PID
observation, obligation and handoff evidence to the read-only index. Provider
liveness remains unknown, even when a recorded PID is absent. The index gives
an archive preview command only for an unambiguous record in the current Rig
directory; records from other projects remain read-only. If the index's Rig
directory and the CLI's `.rigpath` resolution disagree, it suppresses the
archive suggestion until the path is corrected.

`bin/rig session archive --anchor ANCHOR --json` previews an exact v1 record.
The default minimum age is 30 days; `--older-than DAYS` accepts 7 or more.
An active record requires `--acknowledge-active` in both preview and apply.
Archive requires `--confirm TOKEN`, where the token binds the selected bytes,
obligation markers, snapshot, threshold and acknowledgement. A lineage component
must be selected in full with repeated `--anchor` flags. Live PID evidence,
pending obligations, checkpoint handoffs, malformed records and changed input
block the operation. `--list` shows archives, and `--restore ARCHIVE_ID` previews
a separate confirmation token before restoring the original bytes. An archived
conversation that resumes may create a new binding, in which case restore
refuses the old record. Provider transcripts are never changed.
If an interrupted archive or restore leaves a pending journal, the command
reports `archive_recovery_required`. Run `bin/rig session archive --recover ID
--json` to preview rollback or finalization, then repeat with its `--confirm
TOKEN`. Recovery checks saved hashes, current bindings, and lineage before any
write. A changed or rebound record requires manual investigation. The private
manifest preserves record hashes, original modes, and a reason; a redacted
`archive-audit.jsonl` records archive and restore actions.

`bin/rig session index --json` searches Rig session records in the current
project, immediate installed projects under the configured project roots, and
immediate external Rig directories under `~/.rig/projects/`. Set
`~/.rig/config.json` to `{"schema_version":1,"projects_roots":["/absolute/path"]}`
or use the `RIG_PROJECTS_ROOTS` environment variable (colon-separated on Unix).
The environment overrides config; an existing config, even with an empty list,
disables the legacy `~/code/` fallback. With neither setting, an existing
`~/code/` remains the default. Add one project with `--root /path/to/project`
(repeat for multiple projects). This is a bounded index of Rig records: it
does not search Claude or Codex transcript databases, and an unbound native
conversation will not appear. The JSON `coverage` field lists each Rig
directory examined and its record count.

Filter with `--project current` or `--project /path/to/project`,
`--provider claude|codex`, `--state STATE`, and a case-insensitive
`--search TEXT` over displayed names and branches. `--sort activity`
(the default) and `--sort created` show newest first. Each row includes its
recorded project, provider, name, branch, lifecycle state, file provenance,
and a provider resume-picker hint. Older PID-only Rig records appear as
`legacy_pid` with unknown provider and no resume hint; project attribution is
marked unverified when inferred only from a storage directory.
`provider_live_state` is always `unknown`: a Rig record does not prove its
native conversation is still available. Native IDs are omitted unless
`--verbose` is explicit.
Malformed, future-schema, unsafe, or cross-project records appear as errors
instead of silently becoming a selected session. Duplicate anchors are
marked ambiguous; the index never chooses one for resumption. The command
is read-only. A machine-wide query exits 2 when any scanned scope has errors.
With `--project`, only errors attributable to the selected project affect the
exit status; `coverage.omitted_unrelated_errors` counts diagnostics from other
projects, and each scope retains its error count. Plain-text rows quote
control characters so a recorded name cannot forge terminal output.

SessionStart binds the native ID when the provider fires it. On a resumed thread
that skips SessionStart, UserPromptSubmit can bind the exact ID in its event
payload. If that hook cannot attach, `rig session current --json` reports a
retrofit command when a native ID environment variable is available. Resolution
never picks a session from branch name or recent activity alone.

Attaching from a hook event does not export that ID to later tool-call shells.
When a client supplies neither a native ID environment variable nor a launcher
hint to those shells, a standalone `rig session current` remains unresolved.
The hook event can still create the exact record; a later caller must supply
exact identity before naming or completing it. A direct stdio app-server probe
with Codex CLI 0.169.0 and `CODEX_THREAD_ID` unset completed a turn and resumed
the same persisted thread in both the loaded server and a fresh server process.
The native thread ID stayed the same, but neither resume created a Rig session
record automatically. This direct stdio result does not establish how every
app-server client handles hooks or native ID environment variables. A client
that knows the thread ID can recover explicitly with
`bin/rig session retrofit --agent codex --native-session-id <thread-id> --source resume --json`.
Subsequent shell calls must pass the same exact hint, for example
`bin/rig session current --agent codex --native-session-id <thread-id> --json`.
For commands such as `session-name set` and the snapshot writer that do not
accept an explicit native ID, carry both `session_file` and `anchor` from that
same retrofit JSON result into the command environment:

```bash
RIG_SESSION_FILE='<session_file from retrofit JSON>' \
RIG_SESSION_ANCHOR='<anchor from retrofit JSON>' \
  bin/rig session-name set --final --complete 'Final session name'
```

Pass both values again in each separate tool-call shell. An explicit retrofit
succeeded in the probe, and `session current` resolved the same exact ID.
Retrofit refuses an ID that conflicts with a native provider ID already in the
shell. Automatic Rig binding on a direct stdio reattach was not observed;
behavior in other app-server clients remains unverified.

The name writer rechecks anchor, project identity, provider, native ID and
active state after locking the record. Legacy PID records remain readable; a
legacy name write requires an exact launcher file or anchor. `session doctor`
checks that repeated continuations form one unbroken chain with at most one
active leaf. Native IDs stay redacted unless `--verbose` is requested.

An older flat session record can declare schema v1 while lacking the native,
project, and lifecycle objects required by current v1 records. `session doctor --json`
names such a record as `historical_flat_record` and gives a read-only
next step. Run `bin/rig session legacy --file <reported-file> --json` to preview
quarantine and get a confirmation token. `--confirm <token>` backs up the
original bytes and moves only that record out of the resolver's scan. Its
result includes a `--restore <token>` command that restores the original only
if the destination is still absent and the backup matches. A current malformed
record cannot use this path. An old flat record still marked `active` needs the
older provenance fields and an explicit `--acknowledge-active` on confirmation;
preview reports this requirement before any write. Exact-session writes
continue to refuse malformed current records.

---

## The hook system

### Claude Code hooks (`.claude/`)

Wired via `.claude/settings.json`. A default install ships nine Claude hooks
covering the session lifecycle; `subagent-start.sh` is added when `--subagents`
is enabled.

These are intentionally Claude-specific handlers. Codex events are received by
`.codex/hooks.json` and normalized by `.codex/hooks/rig-adapter.sh` before they
enter the same canonical contracts.

```
Session starts
     │
     └─► session-start.sh (SessionStart)
           Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
           Reads CONTEXT_SNAPSHOT.md — injects as additionalContext
           Checks .wrap-needed — injects warning if present
           Checks .post-merge-pending — injects warning if present
           (fires before the first user turn — no manual file read required)

User submits a prompt
     │
     └─► prompt-submit.sh (UserPromptSubmit)
           Attaches an unbound resumed thread from its exact event session_id
           Re-checks .wrap-needed / .post-merge-pending on every prompt
           Re-injects warnings when flags are present
           Warns once per branch change for the exact active session
           (ensures flags surface even mid-session without repeating session-start)

Agent requests a permission
     │
     └─► permission-request.sh (PermissionRequest)
           Auto-approves a narrow set of patterns:
             Read; Bash read-only inspection (cat/head/tail/wc/grep/find,
               read-only git queries, bash -n syntax checks)
             Edit/Write of Markdown (.md) notes under RIG_DIR/memory/,
               RIG_DIR/tasks/, RIG_DIR/docs/ (resolved path; excludes
               PROJECT_CONVENTIONS.md; opt out with
               RIG_DIR/memory/.rig-strict-permissions)
           Never auto-approves commands that execute project code (test
             runners, build tools) or writes to scripts and data files
           Returns {"behavior": "allow"} for matched patterns — no prompt shown
           Falls through (no response) for everything else

Every tool call
     │
     ├─► pre-tool.sh (PreToolUse)
     │     Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
     │     Logs call to RIG_SESSION_LOG or /tmp/the-rig-session-<project>.log
     │     Worktree redirect: Write/Edit/MultiEdit/NotebookEdit targeting .claude/worktrees/
     │       → rewrites path to main-repo equivalent via hookSpecificOutput.updatedInput
     │     Checks RIG_PROTECTED: blocks writes to governance files
     │       (RIG_DIR/processes/, RIG_DIR/rules/, RIG_DIR/contextual-tips.sh,
     │        .husky/, CLAUDE.md, .claude/hooks/); hook-loaded Rig files stay
     │        protected even if an older policy file omits them. Paths are
     │        matched by filesystem identity (case variants, symlinks, hard
     │        links); not-yet-existing parts compare case-insensitively
     │     Checks BLOCKED_PATHS: blocks project-specific protected paths
     │     Rejects visible unmarked Bash commits; marked visible commits
     │       require approval. With no active Rig commit-msg hook, checks
     │       branch/type and consumes approval before the visible call runs
     │     Exit 2 (block) if any check fails
     │
     └─► post-tool.sh (PostToolUse)
           Logs completion to session log
           For approved visible guarded commits, auto-stubs PROGRESS.md
             when the Git result contains the matching commit hash
           For Bash, warn when a new branch name misses the expected prefix

Before context compaction
     │
     └─► pre-compact.sh (PreCompact)
           Resolves RIG_DIR
           Writes .compact-checkpoint.md: branch, last commit, active task, progress markers
           Outputs compactionSummary JSON field for Claude to receive immediately after compact
           (prevents disorientation when the context window is replaced)

After context compaction
     │
     └─► post-compact.sh (PostCompact)
           Reads .compact-checkpoint.md
           Injects its content as additionalContext
           (restores working context that would otherwise require manual re-orientation)

When a subagent spawns
     │
     └─► subagent-start.sh (SubagentStart, only when installed with --subagents)
           Resolves RIG_DIR
           Injects: project name, current branch, active task slug, key conventions
           (subagents share the same working context as the parent session)

Agent finishes response each turn
     │
     └─► stop.sh (Stop event)
           Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
           Preserves an existing CONTEXT_SNAPSHOT.md; SessionEnd writes a
           minimal checkpoint through the snapshot writer when wrap is needed
           and no snapshot exists
           If PROGRESS.md exists:
             Append <!-- session-end YYYY-MM-DD HH:MM sid:UUID --> when anchored,
             or <!-- session-end YYYY-MM-DD HH:MM --> without an anchor
             (idempotent: skips if last non-blank line is already a marker)
           Dispatches on `source` field from JSON stdin:
             Empty source (Stop event): appends a PROGRESS marker; preserves the shared snapshot

Session ends (logout / clear / quit)
     │
     └─► stop.sh (Stop is registered for SessionEnd too — same script, both events)
           Resolves RIG_DIR
           On logout/prompt_input_exit: writes an exact wrap obligation for tagged work;
                                        preserves untagged stubs as a project reminder
                                        writes a minimal auto-checkpoint only when CONTEXT_SNAPSHOT.md is absent
           On clear:                    logs context-cleared; does NOT write .wrap-needed
           On resume:                  no snapshot or PROGRESS change
           On Stop (no src):            per-turn PROGRESS marker; snapshot unchanged
```

**Critical implementation note:** Tool names in Claude Code are `PascalCase`
(`Write`, `Edit`, `Bash`). Using `snake_case` (`write_file`, `edit_file`) causes
the hooks to silently never fire. This was the most costly silent bug in the pilot —
it ran undetected for 30+ PRs.

### Git hooks (`.husky/`)

```
git commit
     │
     ├─► pre-commit
     │     Run gitleaks --staged → block if secrets detected
     │     (PATH-safe: checks command -v + /usr/local/bin + /opt/homebrew/bin)
     │     Run debug artifact scanner → block if leftover debug code detected
     │     (console.log, var_dump, pdb.set_trace, debugger, etc.)
     │     Extend with project patterns in .rig-debug-patterns
     │     Override per-line with # rig-debug-ok; bypass with --no-verify
     │
     ├─► commit-msg
     │     Apply filter-commit-message-inplace.sh to message file
     │     For RIG_COMMIT_POLICY=guarded: resolve actual worktree and .rigpath;
     │       consume fresh one-use $RIG_DIR/memory/.rig-commit-ok approval
     │     For guarded commits: block main/master except chore/docs when
     │       CLAUDE.md sets housekeeping: direct-push
     │     Exempt Git rebase/cherry-pick/revert replay from the
     │       one-use approval and branch checks
     │     Guard generated and manually completed merge commits
     │     Strips: known AI Co-authored-by and tool-generated footer lines
     │     Preserves: human Co-authored-by and Signed-off-by trailers
     │     Validates Conventional Commits subject-line format
     │       (type(scope): description — skips Merge/Revert/fixup/squash)
     │     Requires tracker-specific issue reference when issue-tracking: is set:
     │       github → [#N] or (#N)
     │       linear → [TEAM-123]
     │       trello → [trello:CARD-ID]
     │       gus    → [W-1234567]
     │       any other tracker → [REF], optionally checked by issue-ref-pattern:
     │       none   → no requirement
     │     `SKIP_COMMIT_VALIDATION=1` skips format/ticket checks only;
     │       `# no-issue` skips the tracker ref check only
     │
     └─► post-commit
           Re-read committed message
           Detect late AI footers (clients may inject after commit-msg)
           Warn without changing the SHA by default; optional amend for
             ordinary unsigned commits with RIG_POST_COMMIT_AUTO_AMEND=1
           During rebase/cherry-pick/revert, warn that the footer remains
             and must be removed after replay
           For guarded ordinary and merge commits, auto-stub the actual worktree's
             PROGRESS.md using final HEAD;
             existing SHA entries are not duplicated
           Hold .progress.lock through the SHA check and atomic replacement,
             including when worktrees share an external Rig directory
     └─► post-merge
           For a guarded commit created directly by git merge, claim its
             worktree-specific pending marker and reuse post-commit's final-SHA
             footer/progress handling before writing the merge reminder
```

`RIG_COMMIT_POLICY=guarded` is explicit on agent commit commands; human terminal
commits without it retain the existing format and ticket checks. Generated
scripts and compound commands must inherit the marker to be guarded. PreToolUse
rejects visible unmarked commits, but cannot parse every shell form. Automatic
tagging with `updatedInput` is unreliable: Claude Code may drop that rewrite
on an auto-mode retry, as described in its [hook reference](https://code.claude.com/docs/en/hooks#pretooluse-updatedinput-in-auto-mode).
For a visible guarded command, PreToolUse calls the active `commit-msg` hook
with a dedicated `--rig-policy-probe` argument and requires an exact capability
response from a temporary directory. Older hooks without the probe are blocked.
Customized wrappers should handle the probe before normal message-file handling.
This compatibility check does not prove that a custom or hostile hook enforces
approval during a real commit.
Git hooks run only when installed and enabled. `--skip-git-hooks` omits native
`.git/hooks` installation. If an active Rig Husky hook is present, it provides
the same commit-time guard. Otherwise, PreToolUse retains a visible-command
fallback: it checks approval age, target worktree, branch, and direct-push
subject type, then consumes approval before execution. PostToolUse logs a stub
for the matching successful Git result. Pending markers use the tool event ID
when supplied; overlapping events without IDs share a legacy marker. The
same pending marker backs up a compatible `commit-msg` hook when `post-commit`
is missing or custom; a final-SHA check avoids duplicate progress entries.
The fallback cannot inspect opaque generated scripts and may miss progress logging
for quiet output or a target it cannot resolve. Ordinary human terminal commits
remain unaffected. Visible commands that explicitly use `--no-verify`,
`core.hooksPath` overrides, or `HUSKY=0` are blocked early; dynamically
assembled bypasses remain possible.
The sentinel is a workflow guard, not a physical guarantee. Rebase, cherry-pick,
and revert replay commits are exempt from the Git approval gate and do not
consume approval. Guarded merge commits require fresh approval: this includes
commits made by `git merge --no-ff` and manual conflict completion. Git runs
`post-merge` rather than `post-commit` for generated merges, so the former
reuses the final-SHA logger after the successful guarded merge. If a late AI
footer appears on a generated merge, Git may refuse an opted-in amend while the
merge command is still running; the hook warns and logs the unchanged final SHA.

---

## The task lifecycle

`bin/rig task inventory --json` reads the install manifest and reports whether
task lifecycle was installed, intentionally omitted, or cannot be classified.
It also errors when an installed task component has a missing task directory.
The wrap, ship, and post-merge workflows resolve `$RIG_DIR` through `.rigpath`
for external and stealth installs before reading or moving task files. With tasks
omitted and shared memory installed, `/wrap` and `/post-merge` still update
shared memory; `/rig-ship` reports that
task lifecycle is unavailable.

```
$RIG_DIR/tasks/backlog/TASK_name.md    ← created by /task or /kickoff
        │
        │  (user starts work via /rig-run or /task)
        ▼
$RIG_DIR/tasks/active/TASK_name.md     ← Status: active
        │                             ## Operating mode set (autonomy/check-ins/risk)
        │  (implementation complete, tests pass)
        ▼
$RIG_DIR/tasks/done/TASK_name.md       ← Status: done, Done notes filled in
```

**Staging rule:** The task file is never staged in the implementation commit. It's
staged only from `.rig/tasks/done/` in a separate housekeeping commit for an
in-repo install whose `.rig/` is tracked. External or locally ignored Rig
memory and task files cannot be staged in the project repository; their
workflows report the update without a housekeeping commit.

---

## Context and token management

The Rig is designed to work within a bounded context budget across long sessions
and many tasks. This section documents what loads, when it loads, and what keeps
the budget in check.

### What loads at session start (always)

These files form the required orientation set. Claude loads them through native
instructions/imports; Codex uses its supported instruction fallback and generated
skills. Exact delivery differs by provider, but the shared `.rig` contract does not:

| Source | Typical size | Notes |
|---|---|---|
| `~/.claude/CLAUDE.md` (global) | ~14 KB | Hard rules, working style, conventions |
| Project `CLAUDE.md` | ~14 KB | Stack, structure, off-limits |
| `.rig/rules/` (4 files, via `@`) | ~10 KB | Coding standards, git, security, verification |
| `docs/features/README.md` (via `@`) | ~1.4 KB | Feature index |
| `PROJECT_CONVENTIONS.md` | ~1.5 KB initially | Explicitly approved current rules/preferences |
| `CONTEXT_SNAPSHOT.md` | ~2 KB | Session state — the most important gate |

**Session-start baseline: ~43 KB across these current template files.** Installed project content and provider load order can change the actual amount read.

### What loads on demand (not at startup)

These are read only when a command is invoked or a workflow is followed:

| File | Size | When |
|---|---|---|
| `rig-ship.md` | ~10 KB | `/rig-ship` command |
| `wrap.md` | ~11 KB | `/wrap` command |
| `SHIP_WORKFLOW.md` | ~10 KB | When `/rig-ship` directs agent to follow it |
| `NEW_TASK_WORKFLOW.md` | ~6 KB | When starting a new task |
| Active task file | ~1–3 KB | One per active task |
| `PROGRESS.md` | variable | Only if CONTEXT_SNAPSHOT is absent or stale |
| `ERRORS.md` | variable | Only if CONTEXT_SNAPSHOT is absent or stale |

### The CONTEXT_SNAPSHOT gate

The most important token-management mechanism. When `CONTEXT_SNAPSHOT.md` exists
and is current, the agent is instructed to stop reading context — it skips PROGRESS.md,
ERRORS.md, and deeper history entirely. This keeps repeat sessions cheap.

The Claude `/wrap` command or Codex `$wrap` skill writes the snapshot at session end. **Running the wrap adapter before
ending a session is the single most effective way to keep future sessions lean.**

### Trim limits

`PROGRESS.md` and `ERRORS.md` grow over time. The wrap workflow enforces limits:

- `PROGRESS.md` → trimmed to 20 entries; older entries moved to `PROGRESS_archive.md`
- `ERRORS.md` → trimmed to 30 entries; older entries moved to `ERRORS_archive.md`

Archive files are gitignored (history preserved locally, not loaded at session start).

A full `PROGRESS.md` at the 20-entry limit is ~4,000–6,000 tokens. A full `ERRORS.md`
at 30 entries is ~3,000–5,000 tokens. Both are well within budget even when stacked.

**Important:** the trim only runs when `/wrap` is invoked — it is not automatic.
Projects that skip `/wrap` regularly will see these files grow without bound.

### What actually drives context growth

The dominant cost is not Rig files — it's **tool call accumulation** mid-session.
Every `Read`, `Edit`, `Bash`, and `Grep` result stays in context for the rest of the
session. A task with 40 tool calls, averaging 1 KB of output each, adds ~40 KB
(~10,000 tokens) beyond the baseline. This is normal and expected — it is why
Each provider manages context and compaction differently; Rig checkpoints use
documented provider lifecycle events and exact session identity.

The Rig's design assumption is that a well-structured session (clear task file, current
CONTEXT_SNAPSHOT, invoked commands only as needed) will consume the context window in
proportion to the complexity of the work — not because of Rig overhead.

---

## The command set

Canonical workflows are delivered as Claude slash commands and generated Codex
skills covering the full development lifecycle:

### Project bootstrap
| Command | Triggers | Key behaviour |
|---|---|---|
| `/kickoff` | `NEW_TASK_WORKFLOW` | Reads `PROJECT_BRIEF.md`, confirms understanding, scaffolds `CLAUDE.md` and a task backlog, then links items for the configured `issue-tracking:` mode. GitHub issues are created only with `issue-creator: agent` and separate approval for each exact write; `none` needs no tracker items. Run once at project creation. |

### Daily work
| Command | Triggers | Key behaviour |
|---|---|---|
| `/task` | `NEW_TASK_WORKFLOW` | Three-part intake wizard: goal → autonomy/check-ins/risk/testing configuration → confirmation. Persists operating mode and test requirement in task file. |
| `/rig-run` | Task execution loop | Executes the active task respecting its stored operating mode. If `## Operating mode` is absent from the task file, surfaces an inline wizard to configure it before proceeding. Chains automatically at High autonomy. |
| `/sprint` | Conflict-aware planner | Audits tracker evidence when available, previews conflict/dependency waves through `rig sprint ... --json`, requires a Dependency Surface Audit before launch, and resumes only from an explicit sprint ID. |

### Ship and debug
| Command | Triggers | Key behaviour |
|---|---|---|
| `/rig-ship` | `SHIP_WORKFLOW` | Sequential hard gate: task confirm → issue → labels → branch/stale-main check → pre-commit cleanup (removes debug statements, runs linter, runs tests if required) → checklist → task-specific live validation and evidence → optional manual validation card → commit approval → commit → housekeeping → open or update PR → read-only final merge-boundary metadata review (`bin/rig pr review-metadata`; approved edits via REST) → merge of the reviewed head and verification |
| `/rig-debug` | `DEBUG_WORKFLOW` | Hypothesis before code, mandatory ERRORS.md entry |

### Release
| Command | Triggers | Key behaviour |
|---|---|---|
| `/pre-release-review` | Full review sweep | Covers regressions, test coverage, security, docs accuracy, maintainability, edge cases, and version bump readiness. Outputs a scored Markdown report with a SHIP / HOLD / SHIP WITH FIXES recommendation. |
| `/rig-review` | Rig review workflow | Reviews the current diff for bugs, regressions, risks, and missing tests before summary. |
| `/connector-preflight` | Connector verification | Checks MCP/app connector readiness before workflows rely on external tool access. |
| `/handoff-checklist` | Handoff gate | Produces a durable handoff checklist when work must transfer between sessions or agents. |

### Feature knowledge
| Command | Triggers | Key behaviour |
|---|---|---|
| `/feature-context` | Context loader | Loads an existing feature doc from `docs/features/` into context before starting work — avoids stale assumptions about a documented feature's internals |
| `/recon` | Keyword research | Checks internal docs first (`DECISIONS.md`, `ERRORS.md`, `PROGRESS.md`) before reading code. If nothing found internally, sweeps merged PR history, commit messages, and live codebase for a keyword. Synthesizes an evolution timeline + current state. |
| `/doc-feature` | Research + write | Checks for an existing doc first, then traces a named feature end-to-end and produces a structured doc in `docs/features/`. Guards against duplicates; updates the README index. |
| `/refresh-feature-doc` | Re-verify + update | Re-reads every claim in an existing feature doc against current code; corrects stale paths/line numbers; logs bugs found to `ERRORS.md`. Run after any PR that touches a documented feature. |

### Orientation and docs
| Command | Triggers | Key behaviour |
|---|---|---|
| `/rig-status` | State dashboard + health | Default: current branch, active tasks (with goals), backlog count, recent PROGRESS entries, pending housekeeping flags, and a one-line health verdict from `bin/rig doctor`. Fast alternative to loading full context files. `--health` runs the full check below. Replaces `/status`, which shadowed Claude Code's built-in `/status` panel (#714). |
| `/doc-list` | Docs index | Reads `docs/INDEX.md` and displays the table. Use before loading a full doc file to identify which one covers what you need. |
| `/rig-help` | Command reference | Prints all Rig commands with one-liner descriptions and key flags. Self-contained — no individual command files are loaded. |
| `/rig-status --health` | Rig health check | Runs provider-neutral status checks for hooks, memory, adapter wiring, and pending flags. |

### Governance and housekeeping
| Command | Triggers | Key behaviour |
|---|---|---|
| `/post-merge` | `POST_MERGE_WORKFLOW` | Fetch the base branch and verify each exact merge SHA; fast-forward a clean base checkout only when tracked housekeeping requires it, then update PROGRESS, move the task file, refresh the shared snapshot without removing other task handoffs, suggest a session name, and surface the next priority |
| `/rig-propose` | Governance gate | Writes change proposal to `/tmp/`, shows before/after diff, waits for approval before touching any governance file |
| `/session-name` | Session naming | Derives a name from current conversation/session evidence only; unrelated snapshots, markers, session records, and project history are rejected |
| `/wrap` | Session-end sequence | Refreshes the snapshot header and owned task handoffs, preserves other sessions' handoffs, updates PROGRESS, trims PROGRESS/ERRORS, suggests session name, and surfaces next priority. The owner-aware writer protects snapshot updates. |
| `/rig-gaps` | Self-improvement | _(Rig contributors)_ Compiles unsubmitted `RIG_GAPS.md` entries + cross-checks `ERRORS.md`; formats report for review and optional submission. `--push` appends directly to the local Rig repo (requires `rig-gaps-push-target:` in `CLAUDE.md`); `--submit` creates public GitHub issues in `laudtetteh/the-rig` (opt-in; requires `.rig-contribute-enabled` sentinel + `gh` auth) |
| `/rig-upgrade` | Upgrade workflow | Uses a global-first bootstrap when available: refresh the preferred installer checkout, then follow the latest upgrade command from that checkout. Survey phase always runs `--strategy agent-plan` as a read-only JSON preview. `--mode=agent` (also the non-interactive default) runs `install.sh --strategy agent-upgrade`, presents any `conflicts[]` with repair guidance, then runs `bin/rig doctor --json` as a post-upgrade gate. `--mode=classic` runs plain `install.sh --strategy upgrade`, the original per-file interactive review flow. `--version` prints project and global installed layers, preferred installer checkout state, and the latest tagged release from GitHub (via `gh`), warning if any are out of sync. `--scope=project\|global\|both` limits which layers are upgraded. |

---

## The autonomy system

`/task` and `/rig-run` support per-task operating mode configuration:

| Setting | Options |
|---|---|
| **Autonomy** | 🌶 Low (Guided) · 🌶🌶 Medium (Supervised) · 🌶🌶🌶 High (Autonomous) |
| **Check-ins** | Verbose · Normal · Quiet |
| **Risk tolerance** | Conservative · Balanced · Aggressive |

The configuration is written to `## Operating mode` in the task file and persists
across sessions. `/rig-run` reads the stored mode and executes accordingly — chaining
tasks without interruption at High autonomy, pausing between tasks at Medium and Low.

Governance (protected paths, `/rig-propose` gate, pre-ship checklist) applies at all
autonomy levels. "High Autonomous" means fewer interruptions, not fewer safeguards.

---

## Project settings

Several Rig behaviors are configurable per project via fields in the project `CLAUDE.md`.
These sit alongside the existing `base-branch:` and `housekeeping:` fields:

| Field | Default | Options | What it controls |
|---|---|---|---|
| `base-branch:` | `main` | Any branch name | The integration branch all PRs target |
| `housekeeping:` | `direct-push` | `direct-push` \| `pr-required` | How `/post-merge` handles memory-update commits |
| `issue-tracking:` | `github` | `github`, `none`, or any tracker name | Which issue tracker is required; shapes ref format in commit messages and intake wizard |
| `issue-creator:` | `user` | `user` \| `agent` | GitHub only: `agent` drafts the exact issue and files it after separate approval; `user` waits for the user to provide a number |
| `secret-scanner:` | `gitleaks` | `gitleaks` \| `none` | Secret scanning on commit; disabling requires editing `.husky/pre-commit` |
| `commit-cleanup:` | `yes` | `yes` \| `no` | Whether auto-injected tool footers are stripped from commit messages |
| `rig-gaps-push-target:` | *(unset)* | Absolute file path | Path to `RIG_GAPS.md` in the local Rig repo on this machine; enables `/rig-gaps --push` to append entries directly. Leave blank if The Rig repo isn't on this machine. |

The `issue-tracking:` setting shapes the entire task intake and commit workflow.
`github` uses `[#N]`; `none` skips references. Any other tracker name uses
a user-provided reference in brackets, optionally constrained by
`issue-ref-pattern:` and illustrated by `issue-ref-example:`.
`linear`, `trello`, and `gus` keep their existing preset formats.

Branch creation behavior is also parameterized by autonomy level:
- **Low/Medium**: always confirm the base branch before `git checkout -b`
- **High**: reads `base-branch:` from `CLAUDE.md`, states the base, and branches immediately

A stale-main check (`git fetch` + `rev-list` comparison) runs before any new branch is
created. If the base branch has advanced, Low/Medium autonomy prompts to rebase; High
autonomy rebases automatically.
