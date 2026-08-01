# How The Rig works

> Coexistence: The Rig’s shared `.rig` processes run across Claude Code and Codex. Provider adapters expose the same workflows through Claude commands/hooks and Codex skills/hooks; provider-specific mechanics below are labeled explicitly.

A technical deep-dive into the architecture, components, and session lifecycle.

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
3. **Enforcement** — hooks that make certain failures physically impossible

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
│                                                                 │
│  To upgrade: cd ~/tools/the-rig && git pull                     │
│  Then re-run install.sh with --strategy upgrade                 │
└───────────────┬─────────────────────────┬───────────────────────┘
                │ installs global layer    │ installs project layer
                ▼                         ▼
┌──────────────────────────┐  ┌───────────────────────────────────┐
│  GLOBAL LAYER            │  │  PROJECT LAYER                    │
│  (~/.claude/)            │  │  (per-repo, version-controlled)   │
│  Once per machine.       │  │  Once per project.                │
│                          │  │                                   │
│  ~/.claude/CLAUDE.md     │  │  CLAUDE.md       ← project brain  │
│    └─ Hard rules (12),   │  │  .rig/           ← Rig system     │
│       working style,     │  │  .rig/processes/ ← workflows      │
│       memory discipline, │  │  .rig/rules/     ← standards      │
│       planning, git,     │  │  .rig/memory/    ← PROGRESS +     │
│       code quality,      │  │                    ERRORS +        │
│       personal context,  │  │                    SNAPSHOT        │
│       skill trigger table│  │  .rig/tasks/     ← backlog/active/│
│                          │  │                    done            │
│  ~/.claude/skills/       │  │  .claude/        ← hooks (10) +   │
│    ├─ debug.md           │  │                    commands        │
│    ├─ code-review.md     │  │  .husky/         ← git hooks      │
│    ├─ refactor.md        │  │  .github/        ← PR + issue     │
│    ├─ write-tests.md     │  │                    templates       │
│    └─ explain.md         │  └───────────────────────────────────┘
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
CLAUDE.md instructs: read ./.rig/tasks/active/
     │  What task is currently in flight
     │
     ▼
Agent is oriented. Hooks are live. Ready to work.
     │
     │  On every user prompt:
     │  └─ prompt-submit.sh (UserPromptSubmit)
     │       Re-checks .wrap-needed / .post-merge-pending; re-injects warnings
     │
     │  On every permission request:
     │  └─ permission-request.sh (PermissionRequest)
     │       Auto-approves safe read-only patterns
     │
     │  Before every tool call:
     │  └─ pre-tool.sh (PreToolUse)
     │       Protected-path check, commit gate, main-branch guard, worktree redirect
     │
     │  After every tool call:
     │  └─ post-tool.sh (PostToolUse)
     │       PROGRESS.md auto-stub on commit; sentinel cleanup
     │
     │  Before context compaction:
     │  └─ pre-compact.sh (PreCompact)
     │       Writes .compact-checkpoint.md; outputs compactionSummary JSON
     │
     │  After context compaction:
     │  └─ post-compact.sh (PostCompact)
     │       Injects checkpoint as additionalContext; restores working context
     │
     │  When a subagent spawns:
     │  └─ subagent-start.sh (SubagentStart)
     │       Injects project name, branch, active task, key conventions
     │
     │  After the agent's final message each turn:
     │  └─ stop.sh (Stop)
     │       Updates "Last updated:" date in CONTEXT_SNAPSHOT.md
     │       Appends a UUID-tagged session-end marker to PROGRESS.md
     │       (lightweight; idempotent — safe to run after every response)
     │
     ▼
Claude /wrap or Codex $wrap — run manually before closing
     │  Writes .rig/memory/CONTEXT_SNAPSHOT.md (full current state)
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
          On logout/prompt_input_exit: writes .wrap-needed + minimal auto-checkpoint
          On clear: logs context-cleared; no .wrap-needed
          On resume / Stop (per-turn): per-turn date update + PROGRESS marker
```

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
- Auto-stubbed by `post-tool.sh` after every git commit — stub exists even if the agent forgets
- `stop.sh` appends UUID-tagged session-end markers for housekeeping. Naming never uses legacy marker ranges, snapshots, unrelated session files, or project history; current conversation context is authoritative and only the resolved current session's UUID-tagged entries may cross-check it.
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
- Written by the installer on every install; committed to the repo
- Records the SHA256 hash of each Rig-owned file at install time
- Used by the **Upgrade** strategy to detect user customizations:
  - Hash unchanged since install → safe to auto-update
  - Hash changed → you've customized it → diff shown before overwrite
- See `docs/customizing.md` for the full Upgrade strategy workflow

---

## The process system

Four workflow files that define step-by-step behaviour at each phase:

### NEW_TASK_WORKFLOW
```
Step 0: GitHub issue first — /task wizard enforces this at intake time
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
Step 0:   Create GitHub issue FIRST — commit must reference [#N]
Step 1:   Pre-ship checklist (AC, no debug code, no secrets, Docker verification)
Step 2:   Self-review — does this do ONLY what was asked?
Step 2.4: Derive and run 1–5 task-specific live checks; record results, skips, and risk
Step 2.5: Show an optional copyable validation card; approval attests to evidence review
Step 3:   Commit (conventional format, issue reference; sentinel flow via pre-tool.sh)
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
Step 1: Pull latest main
Step 2: Update PROGRESS.md
Step 3: Move task file active/ → done/
Step 4: Overwrite CONTEXT_SNAPSHOT.md
Step 5: Check ERRORS.md and RIG_GAPS.md
Step 6: Housekeeping commit (if needed)
Step 7: Suggest session name (derives name from session work)
Step 8: Surface next priority — ask "What's next?"
```

---

## The hook system

### Claude Code hooks (`.claude/`)

Wired via `.claude/settings.json`. Ten hooks covering the full session lifecycle.

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
           Re-checks .wrap-needed / .post-merge-pending on every prompt
           Re-injects warnings when flags are present
           (ensures flags surface even mid-session without repeating session-start)

Agent requests a permission
     │
     └─► permission-request.sh (PermissionRequest)
           Auto-approves safe read-only patterns:
             Read, Bash (ls/cat/grep/find/git log/git diff/etc.), WebFetch, WebSearch
           Returns {"behavior": "allow"} for matched patterns — no prompt shown
           Falls through (no response) for write/destructive operations

Every tool call
     │
     ├─► pre-tool.sh (PreToolUse)
     │     Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
     │     Logs call to /tmp/the-rig-session.log
     │     Worktree redirect: Write/Edit/NotebookEdit targeting .claude/worktrees/
     │       → rewrites path to main-repo equivalent via updatedToolInput
     │     Checks RIG_PROTECTED: blocks writes to governance files
     │       (RIG_DIR/processes/, RIG_DIR/rules/, .husky/, CLAUDE.md, .claude/hooks/)
     │     Checks BLOCKED_PATHS: blocks project-specific protected paths
     │     Gates git commit on $RIG_DIR/memory/.rig-commit-ok sentinel:
     │       Blocked → agent shows commit message, asks for trigger phrase
     │       ("commit approved" / "ship it" / "lgtm" / "go")
     │       Agent creates sentinel → commit succeeds → post-tool.sh deletes it
     │     Guards git commit on main/master:
     │       Blocked unless CLAUDE.md sets housekeeping: direct-push
     │       Even with direct-push: blocks feat/fix/refactor/test/perf/devops/style types
     │       Only chore/docs may go directly to main
     │     Exit 1 (block) if any check fails
     │
     └─► post-tool.sh (PostToolUse)
           Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
           Logs completion to session log
           If tool is Bash:
             Scan output for git commit hash pattern
             If commit detected:
               Read commit message + hash from git log
               Append dated stub to RIG_DIR/memory/PROGRESS.md (idempotent)
               Delete $RIG_DIR/memory/.rig-commit-ok sentinel (one-shot auth)

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
     └─► subagent-start.sh (SubagentStart)
           Resolves RIG_DIR
           Injects: project name, current branch, active task slug, key conventions
           (subagents share the same working context as the parent session)

Agent finishes response each turn
     │
     └─► stop.sh (Stop event)
           Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
           If CONTEXT_SNAPSHOT.md exists and has "Last updated:" line:
             Update the date (preserve description text)
           If PROGRESS.md exists:
             Append <!-- session-end YYYY-MM-DD HH:MM --> boundary marker
             (idempotent: skips if last non-blank line is already a marker)
           Dispatches on `source` field from JSON stdin:
             Empty source (Stop event): updates CONTEXT_SNAPSHOT date + PROGRESS marker

Session ends (logout / clear / quit)
     │
     └─► stop.sh (Stop is registered for SessionEnd too — same script, both events)
           Resolves RIG_DIR
           On logout/prompt_input_exit: writes .wrap-needed sentinel
                                        writes a minimal auto-checkpoint to CONTEXT_SNAPSHOT.md
                                        (current branch + last commit; prevents cold-start next session)
           On clear:                    logs context-cleared; does NOT write .wrap-needed
           On resume / Stop (no src):   per-turn update (date + PROGRESS marker)
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
     │     Strips: Co-authored-by, Signed-off-by, Made-with trailers
     │     Strips: "Generated with Claude/Cursor/Copilot" footer lines
     │     Validates Conventional Commits subject-line format
     │       (type(scope): description — skips Merge/Revert/fixup/squash)
     │     Requires tracker-specific issue reference when issue-tracking: is set:
     │       github → [#N] or (#N)
     │       linear → [TEAM-123]
     │       trello → [trello:CARD-ID]
     │       gus    → [W-1234567]
     │       none   → no requirement
     │     Bypass: `SKIP_COMMIT_VALIDATION=1` env var, or add `# no-issue` trailer
     │     to the commit body (bypasses tracker ref check for any issue-tracking mode)
     │
     └─► post-commit
           Re-read committed message
           Re-apply filter (catches clients that re-inject after commit-msg)
           Amend in-place only if message changed (cmp -s check)
```

---

## The task lifecycle

```
.rig/tasks/backlog/TASK_name.md    ← created by /task or /kickoff
        │
        │  (user starts work via /run or /task)
        ▼
.rig/tasks/active/TASK_name.md     ← Status: active
        │                             ## Operating mode set (autonomy/check-ins/risk)
        │  (implementation complete, tests pass)
        ▼
.rig/tasks/done/TASK_name.md       ← Status: done, Done notes filled in
```

**Staging rule:** The task file is never staged in the implementation commit. It's
staged only from `.rig/tasks/done/` in a separate housekeeping commit.

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
| `~/.claude/CLAUDE.md` (global) | ~10 KB | Hard rules, working style, conventions |
| Project `CLAUDE.md` | ~6 KB | Stack, structure, off-limits |
| `.rig/rules/` (4 files, via `@`) | ~11 KB | Coding standards, git, security, verification |
| `docs/features/README.md` (via `@`) | ~1 KB | Feature index |
| `PROJECT_CONVENTIONS.md` | ~1.5 KB initially | Explicitly approved current rules/preferences |
| `CONTEXT_SNAPSHOT.md` | ~2 KB | Session state — the most important gate |

**Session-start baseline: ~30 KB (~7,000 tokens).** Well within supported agent context windows.

### What loads on demand (not at startup)

These are read only when a command is invoked or a workflow is followed:

| File | Size | When |
|---|---|---|
| `ship.md` | ~10 KB | `/ship` command |
| `wrap.md` | ~11 KB | `/wrap` command |
| `SHIP_WORKFLOW.md` | ~10 KB | When `/ship` directs agent to follow it |
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
| `/kickoff` | `NEW_TASK_WORKFLOW` | Reads `PROJECT_BRIEF.md`, confirms understanding, scaffolds `CLAUDE.md` + task backlog + GitHub issues in one pass. Run once at project creation — the command file can be deleted after use. |

### Daily work
| Command | Triggers | Key behaviour |
|---|---|---|
| `/task` | `NEW_TASK_WORKFLOW` | Three-part intake wizard: goal → autonomy/check-ins/risk/testing configuration → confirmation. Persists operating mode and test requirement in task file. |
| `/run` | Task execution loop | Executes the active task respecting its stored operating mode. If `## Operating mode` is absent from the task file, surfaces an inline wizard to configure it before proceeding. Chains automatically at High autonomy. |
| `/sprint` | Conflict-aware planner | Current implementation groups already-qualified tasks into conflict-free waves. Full tracker audit/repair, durable resumable planning, and `rig sprint ... --json` remain planned in issue #378. |

### Ship and debug
| Command | Triggers | Key behaviour |
|---|---|---|
| `/ship` | `SHIP_WORKFLOW` | Sequential hard gate: task confirm → issue → labels → branch/stale-main check → pre-commit cleanup (removes debug statements, runs linter, runs tests if required) → checklist → task-specific live validation and evidence → optional manual validation card → commit approval → commit → housekeeping → open or update PR |
| `/debug` | `DEBUG_WORKFLOW` | Hypothesis before code, mandatory ERRORS.md entry |

### Release
| Command | Triggers | Key behaviour |
|---|---|---|
| `/pre-release-review` | Full review sweep | Covers regressions, test coverage, security, docs accuracy, maintainability, edge cases, and version bump readiness. Outputs a scored Markdown report with a SHIP / HOLD / SHIP WITH FIXES recommendation. |

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
| `/status` | State dashboard | Shows current branch, active tasks (with goals), backlog count, recent PROGRESS entries, and any pending housekeeping flags. Fast alternative to loading full context files. |
| `/doc-list` | Docs index | Reads `docs/INDEX.md` and displays the table. Use before loading a full doc file to identify which one covers what you need. |
| `/rig-help` | Command reference | Prints all Rig commands with one-liner descriptions and key flags. Self-contained — no individual command files are loaded. |

### Governance and housekeeping
| Command | Triggers | Key behaviour |
|---|---|---|
| `/post-merge` | `POST_MERGE_WORKFLOW` | Post-merge hygiene: pull base branch, update PROGRESS, move task file, housekeeping commit, suggest session name, surface next priority |
| `/rig-propose` | Governance gate | Writes change proposal to `/tmp/`, shows before/after diff, waits for approval before touching any governance file |
| `/session-name` | Session naming | Derives a name from current conversation/session evidence only; unrelated snapshots, markers, session records, and project history are rejected |
| `/wrap` | Session-end sequence | Writes CONTEXT_SNAPSHOT, captures in-flight task state, updates PROGRESS, trims PROGRESS/ERRORS, suggests session name, surfaces next priority. Concurrent session guard prevents race conditions on PROGRESS.md. |
| `/rig-gaps` | Self-improvement | _(Rig contributors)_ Compiles unsubmitted `RIG_GAPS.md` entries + cross-checks `ERRORS.md`; formats report for review and optional submission. `--push` appends directly to the local Rig repo (requires `rig-gaps-push-target:` in `CLAUDE.md`); `--submit` creates public GitHub issues in `laudtetteh/the-rig` (opt-in; requires `.rig-contribute-enabled` sentinel + `gh` auth) |
| `/rig-upgrade` | Upgrade workflow | Pulls latest Rig source and re-runs `install.sh` with `--strategy upgrade`. `--version` prints the project version, global installer version, and the latest tagged release from GitHub (via `gh`), warning if any are out of sync. `--scope=project\|global\|both` limits which layers are upgraded. |

---

## The autonomy system

`/task` and `/run` support per-task operating mode configuration:

| Setting | Options |
|---|---|
| **Autonomy** | 🌶 Low (Guided) · 🌶🌶 Medium (Supervised) · 🌶🌶🌶 High (Autonomous) |
| **Check-ins** | Verbose · Normal · Quiet |
| **Risk tolerance** | Conservative · Balanced · Aggressive |

The configuration is written to `## Operating mode` in the task file and persists
across sessions. `/run` reads the stored mode and executes accordingly — chaining
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
| `issue-tracking:` | `github` | `github` \| `linear` \| `trello` \| `gus` \| `none` | Which issue tracker is required; shapes ref format in commit messages and intake wizard |
| `issue-creator:` | `user` | `user` \| `agent` | GitHub only: whether the agent creates issues itself (`agent`) or waits for the user to provide a number (`user`) |
| `secret-scanner:` | `gitleaks` | `gitleaks` \| `none` | Secret scanning on commit; disabling requires editing `.husky/pre-commit` |
| `commit-cleanup:` | `yes` | `yes` \| `no` | Whether auto-injected tool footers are stripped from commit messages |
| `rig-gaps-push-target:` | *(unset)* | Absolute file path | Path to `RIG_GAPS.md` in the local Rig repo on this machine; enables `/rig-gaps --push` to append entries directly. Leave blank if The Rig repo isn't on this machine. |

The `issue-tracking:` setting shapes the entire task intake and commit workflow: the ref format expected in commit messages (`[#N]`, `[TEAM-123]`, `[trello:ID]`, `[W-N]`) and the intake question in `/task` both follow the configured tracker. Set to `none` for personal projects, prototypes, or repos without an issue tracker.

Branch creation behavior is also parameterized by autonomy level:
- **Low/Medium**: always confirm the base branch before `git checkout -b`
- **High**: reads `base-branch:` from `CLAUDE.md`, states the base, and branches immediately

A stale-main check (`git fetch` + `rev-list` comparison) runs before any new branch is
created. If the base branch has advanced, Low/Medium autonomy prompts to rebase; High
autonomy rebases automatically.
