# How The Rig works

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

```
┌─────────────────────────────────────────────────────────────────┐
│  GLOBAL LAYER  (~/.claude/)                                     │
│  Installed once per machine. Cross-project.                     │
│                                                                 │
│  ~/.claude/CLAUDE.md                                            │
│    └─ Hard rules (12), working style, memory discipline,        │
│       planning discipline, session workflow, git conventions,   │
│       code quality defaults, skill trigger table                │
│                                                                 │
│  ~/.claude/skills/                                              │
│    ├─ debug.md          ← "why is this broken"                  │
│    ├─ code-review.md    ← "review this"                         │
│    ├─ refactor.md       ← "refactor this to…"                   │
│    ├─ write-tests.md    ← "write tests for…"                    │
│    └─ explain.md        ← "explain this to me"                  │
│                                                                 │
│  ~/.your-ai-contexts/PROFILE.md                                 │
│    └─ Personal/professional context — role, stack, projects,    │
│       working style preferences                                 │
└────────────────────────────┬────────────────────────────────────┘
                             │ auto-loaded by Claude Code
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  PROJECT LAYER  (per-repo, version-controlled)                  │
│                                                                 │
│  CLAUDE.md              ← project identity + @.rig/rules/ imports│
│  .rig/                  ← The Rig system files                   │
│  .rig/processes/        ← step-by-step workflows                │
│  .rig/rules/            ← coding/git/security/verification      │
│  .rig/memory/           ← PROGRESS + ERRORS + SNAPSHOT          │
│  .rig/tasks/            ← backlog → active → done lifecycle     │
│  .claude/               ← hooks + slash commands                │
│  .husky/                ← git hooks                             │
│  .github/               ← PR + issue templates                  │
└─────────────────────────────────────────────────────────────────┘
```

The global layer is loaded first, automatically, by Claude Code. It provides
universal context. The project layer is read during orientation and provides
project-specific context.

---

## Session lifecycle

```
Session starts
     │
     ▼
Claude Code auto-loads ~/.claude/CLAUDE.md
     │  Hard rules, working style, memory discipline
     │
     ▼
CLAUDE.md instructs: read PROFILE.md
     │  Personal/professional context
     │
     ▼
CLAUDE.md instructs: read ./CLAUDE.md
     │  Project identity, stack, conventions
     │
     ▼
CLAUDE.md instructs: check .rig/memory/CONTEXT_SNAPSHOT.md
     │  If it exists → sufficient for orientation. Load it and stop.
     │  If absent or stale → load .rig/memory/PROGRESS.md (last 20 entries only)
     │
     ▼
CLAUDE.md instructs: read ./.rig/memory/ERRORS.md
     │  Known pitfalls to avoid
     │
     ▼
CLAUDE.md instructs: read ./.rig/tasks/active/
     │  What task is currently in flight
     │
     ▼
Agent is oriented. Hooks are live. Ready to work.
     │
     │  During the session (repeats every turn):
     │  ├─ pre-tool.sh  runs before every tool call
     │  ├─ post-tool.sh runs after every tool call
     │  └─ stop.sh      runs after the agent's final message each turn
     │       Updates "Last updated:" date in CONTEXT_SNAPSHOT.md
     │       Appends <!-- session-end YYYY-MM-DD HH:MM --> to PROGRESS.md
     │       (lightweight; idempotent — safe to run after every response)
     │
     ▼
/wrap — run manually before closing Claude Code
     │  Writes .rig/memory/CONTEXT_SNAPSHOT.md (full current state)
     │  Expands PROGRESS.md stubs; trims if > 20 entries
     │  Logs ERRORS.md and RIG_GAPS.md entries
     │  Trims ERRORS.md if > 30 entries
     │  Suggests session name (derives /rename from session-end markers)
     └─ Surfaces next priority
```

---

## The memory system

Three files, three purposes:

### .rig/memory/CONTEXT_SNAPSHOT.md
- **The primary orientation file** — written at session end via `/wrap`
- **Gitignored** — lives on disk only, never committed
- Contains: project state, open PRs, backlog priority, key decisions, known footguns, environment notes
- When it exists, the agent reads *only this* at session start. PROGRESS.md is skipped.
- What allows a new session to orient in seconds rather than minutes

### .rig/memory/PROGRESS.md
- Append-only build log, one entry per meaningful unit of work
- Auto-stubbed by `post-tool.sh` after every git commit — stub exists even if the agent forgets
- `stop.sh` appends `<!-- session-end YYYY-MM-DD HH:MM -->` boundary markers automatically; `/wrap` and `/post-merge` use these to identify which entries belong to the current session when suggesting a session name
- Most recent entry at the top
- **Trim convention:** capped at 20 entries. `/wrap` moves older entries to `.rig/memory/PROGRESS_archive.md` (gitignored, disk-only) when the cap is exceeded. Keeps session startup cost low indefinitely.

### .rig/memory/ERRORS.md
- Pitfall log — every non-obvious bug logged with structured format
- Format: Symptom → Root cause → Fix → Watch for
- The most valuable file in the system — it's institutional memory
- **Trim convention:** capped at 30 entries. `/wrap` moves older entries to `.rig/memory/ERRORS_archive.md` (gitignored, disk-only) when the cap is exceeded. Same pattern as PROGRESS.md.

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
Step 2.5: Pause — ask user for trigger phrase ("commit approved" / "ship it" / "lgtm" / "go")
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
Step 7: Suggest session name (derives /rename from session work)
Step 8: Surface next priority — ask "What's next?"
```

---

## The hook system

### Claude Code hooks (`.claude/`)

Wired via `.claude/settings.json`. Run on every tool call (`"matcher": ".*"`).

```
Every tool call
     │
     ├─► pre-tool.sh (PreToolUse)
     │     Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
     │     Logs call to /tmp/the-rig-session.log
     │     Checks RIG_PROTECTED: blocks writes to governance files
     │     (RIG_DIR/processes/, RIG_DIR/rules/, .husky/, CLAUDE.md, .claude/hooks/)
     │     Checks BLOCKED_PATHS: blocks project-specific protected paths
     │     Gates git commit on $RIG_DIR/memory/.rig-commit-ok sentinel:
     │       Blocked → agent shows commit message, asks for trigger phrase
     │       ("commit approved" / "ship it" / "lgtm" / "go")
     │       Agent creates sentinel → commit succeeds → post-tool.sh deletes it
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

Agent finishes response
     │
     └─► stop.sh (Stop event)
           Resolves RIG_DIR (.rigpath if present, else $REPO/.rig)
           If CONTEXT_SNAPSHOT.md exists and has "Last updated:" line:
             Update the date (preserve description text)
           If PROGRESS.md exists:
             Append <!-- session-end YYYY-MM-DD HH:MM --> boundary marker
             (idempotent: skips if last non-blank line is already a marker)
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

## The command set

Nine slash commands covering the full development lifecycle:

### Project bootstrap
| Command | Triggers | Key behaviour |
|---|---|---|
| `/kickoff` | `NEW_TASK_WORKFLOW` | Reads `PROJECT_BRIEF.md`, confirms understanding, scaffolds `CLAUDE.md` + task backlog + GitHub issues in one pass |

### Daily work
| Command | Triggers | Key behaviour |
|---|---|---|
| `/task` | `NEW_TASK_WORKFLOW` | Three-part intake wizard: goal → autonomy/check-ins/risk configuration → confirmation. Persists operating mode in task file. |
| `/run` | Task execution loop | Surveys backlog, builds dependency-aware priority queue, executes tasks respecting per-task operating mode. Chains automatically at High autonomy. |

### Ship and debug
| Command | Triggers | Key behaviour |
|---|---|---|
| `/ship` | `SHIP_WORKFLOW` | Sequential 9-step hard gate: task confirm → issue → labels → checklist → local test pause → commit approval → commit → housekeeping → PR |
| `/debug` | `DEBUG_WORKFLOW` | Hypothesis before code, mandatory ERRORS.md entry |

### Governance and housekeeping
| Command | Triggers | Key behaviour |
|---|---|---|
| `/propose` | Governance gate | Writes change proposal to `/tmp/`, shows before/after diff, waits for approval before touching any governance file |
| `/wrap` | Session-end sequence | Writes CONTEXT_SNAPSHOT, updates PROGRESS, runs self-improvement check (logs Rig gaps), trims PROGRESS/ERRORS, suggests session name via `/rename`, surfaces next priority |
| `/rig-gaps` | Self-improvement | Compiles unsubmitted `RIG_GAPS.md` entries + cross-checks `ERRORS.md`; formats a report with submission instructions for The Rig dev session |
| `/new-feature` | `NEW_TASK_WORKFLOW` | Original task entry point — creates task file, plans before coding, waits for approval |

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

Governance (protected paths, `/propose` gate, pre-ship checklist) applies at all
autonomy levels. "High Autonomous" means fewer interruptions, not fewer safeguards.
