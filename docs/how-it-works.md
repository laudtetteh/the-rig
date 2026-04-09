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
│    └─ Hard rules (11), working style, memory discipline,        │
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
│  CLAUDE.md              ← project identity + @rules/ imports    │
│  processes/             ← step-by-step workflows                │
│  rules/                 ← coding/git/security/verification      │
│  memory/                ← PROGRESS + ERRORS + SNAPSHOT          │
│  tasks/                 ← backlog → active → done lifecycle     │
│  .claude/               ← hooks + slash commands                │
│  .husky/                ← git hooks                             │
│  .github/               ← PR + issue templates                  │
└─────────────────────────────────────────────────────────────────┘
```

The global layer is loaded first, automatically, by Claude Code. It provides universal context. The project layer is read during orientation and provides project-specific context.

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
CLAUDE.md instructs: read ./memory/PROGRESS.md
     │  Where the project stands — full build history
     │
     ▼
CLAUDE.md instructs: read ./memory/ERRORS.md
     │  Known pitfalls to avoid
     │
     ▼
CLAUDE.md instructs: read ./tasks/active/
     │  What task is currently in flight
     │
     ▼
Agent is oriented. Hooks are live. Ready to work.
     │
     │  During the session:
     │  ├─ pre-tool.sh runs before every tool call
     │  └─ post-tool.sh runs after every tool call
     │
     ▼
/wrap — session end
     │  Writes CONTEXT_SNAPSHOT.md
     │  Ensures PROGRESS.md is current
     └─ Surfaces next priority
```

---

## The memory system

Three files, three purposes:

### PROGRESS.md
- Append-only build log
- One entry per PR merge (format: date, summary, bullets, PR number)
- Auto-stubbed by `post-tool.sh` after every git commit — the stub exists even if the agent forgets to write the narrative
- Most recent entry at the top

### ERRORS.md
- Pitfall log — every non-obvious bug logged with structured format
- Never deleted, only appended
- Format: Symptom → Root cause → Fix → Watch for
- The most valuable file in the system — it's institutional memory

### CONTEXT_SNAPSHOT.md
- Session state — overwritten (never deleted) at session end via `/wrap`
- **Gitignored** — lives on disk only, never committed
- Contains: project state paragraph, full PR list, open PRs, backlog priority order, key decisions, known footguns, environment notes
- What allows a new session to orient in seconds rather than minutes

---

## The process system

Four workflow files that define step-by-step behaviour at each phase:

### NEW_TASK_WORKFLOW
```
Step 0: Confirm working directory (main repo, not worktree)
Step 1: Orient (read SNAPSHOT → PROGRESS → ERRORS → task file)
Step 2: Confirm understanding — restate goal, files, risks. Wait for approval.
Step 3: Plan — write numbered plan into task file. Wait for approval.
Step 4: Implement — one step at a time, surface surprises
Step 5: Verify — run tests, check acceptance criteria
Step 6: Wrap up — move task, update PROGRESS, log ERRORS, commit
```

### SHIP_WORKFLOW
```
Step 0: Create GitHub issue FIRST — commit must reference [#N]
Step 1: Pre-ship checklist (AC, no debug code, no secrets, Docker verification)
Step 2: Self-review — does this do ONLY what was asked?
Step 3: Commit (conventional format, issue reference)
Step 4: Update memory (move task, PROGRESS, SNAPSHOT, ERRORS)
Step 5: Open PR (template exactly, labels at creation time)
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
Step 5: Check ERRORS.md
Step 6: Housekeeping commit (if needed)
Step 7: Surface next priority — ask "What's next?"
```

---

## The hook system

### Claude Code hooks (`.claude/`)

Wired via `.claude/settings.json`. Run on every tool call (`"matcher": ".*"`).

```
Every tool call
     │
     ├─► pre-tool.sh (PreToolUse)
     │     Logs call to /tmp/the-rig-session.log
     │     If tool is Write or Edit:
     │       Extract file_path from JSON input
     │       Check against BLOCKED_PATHS array
     │       Exit 1 (block) if match found
     │
     └─► post-tool.sh (PostToolUse)
           Logs completion to session log
           If tool is Bash:
             Scan output for git commit hash pattern
             If commit detected:
               Read commit message + hash from git log
               Append dated stub to PROGRESS.md (idempotent)
```

**Critical implementation note:** Tool names in Claude Code are `PascalCase` (`Write`, `Edit`, `Bash`). Using `snake_case` (`write_file`, `edit_file`) causes the hooks to silently never fire. This was the most costly silent bug in the pilot — it ran undetected for 30+ PRs.

### Git hooks (`.husky/`)

```
git commit
     │
     ├─► pre-commit
     │     Run gitleaks --staged
     │     Block commit if secrets detected
     │     (PATH-safe: checks command -v + /usr/local/bin + /opt/homebrew/bin)
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
tasks/backlog/TASK_name.md    ← created during planning
        │
        │  (user starts work)
        ▼
tasks/active/TASK_name.md     ← Status: active
        │
        │  (implementation complete, tests pass)
        ▼
tasks/done/TASK_name.md       ← Status: done, Done notes filled in
```

**Staging rule:** The task file is never staged in the implementation commit. It's staged only from `tasks/done/` in a separate housekeeping commit. Committing from `tasks/active/` creates a confusing history where in-progress and completed states appear in the same PR.

---

## The slash commands

Four commands that map to the process workflows:

| Command | Triggers | Key behaviour |
|---|---|---|
| `/new-feature` | `NEW_TASK_WORKFLOW` | Creates task file, plans before coding, waits for approval |
| `/ship` | `SHIP_WORKFLOW` | Pre-ship checklist, shows commit message, waits for "go ahead" |
| `/debug` | `DEBUG_WORKFLOW` | Hypothesis before code, mandatory ERRORS.md entry |
| `/wrap` | Session-end sequence | Writes CONTEXT_SNAPSHOT, updates PROGRESS, surfaces next priority |
