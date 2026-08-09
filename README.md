# The Rig

> The Rig supports both Claude Code and Codex. Shared workflows and contracts are provider-neutral; Claude slash commands, Codex skills, and provider hook details are labeled where they differ.

**An opinionated agentic coding system for Claude Code and Codex.**

The Rig wraps Claude Code and Codex with shared structured memory, enforced workflows, automated safety hooks, and commit-history discipline — so AI-assisted development stays consistent across sessions, agents, projects, and months.

Built and refined across 100+ pull requests on a real production project.

---

## The problem it solves

Coding agents are powerful but session-local. Without structure, every session:

- Starts cold — repeats decisions already made, re-asks questions already answered
- Drifts — different conventions each session, silently violated rules
- Causes invisible damage — writes to protected files, commits without scanning for secrets, amends history in hidden worktrees
- Leaves no trail — no record of why things were built the way they were

The Rig solves all of this. Not through better prompts — through enforced structure.

---

## Architecture

The Rig has two layers that load in sequence at every session start:

```
┌─────────────────────────────────────────────────────────────────┐
│  GLOBAL LAYER  (~/.claude/ plus selected Codex integrations)    │
│  Installed once. Applies to every project on the machine.       │
│                                                                 │
│  CLAUDE.md          ← identity, hard rules, working style,      │
│                       personal context (fill in once)           │
│  skills/            ← reusable skill scripts (5 included)       │
└────────────────────────────┬────────────────────────────────────┘
                             │ loaded first at every session
                             ▼
┌─────────────────────────────────────────────────────────────────┐
│  PROJECT LAYER  (per-repo, version-controlled)                  │
│  Scaffolded per project. Defines project-specific behaviour.    │
│                                                                 │
│  CLAUDE.md          ← project identity, stack, conventions      │
│  .rig/              ← The Rig system files                       │
│  .rig/processes/    ← new-task, ship, debug, post-merge flows   │
│  .rig/rules/        ← coding standards, git, security, verify   │
│  .rig/memory/       ← PROGRESS, ERRORS, DECISIONS, SNAPSHOT      │
│  .rig/tasks/        ← active / backlog / done lifecycle         │
│  .claude/           ← Claude hook wiring + slash commands       │
│  .agents/skills/    ← generated Codex skills from commands      │
│  .codex/            ← Codex hook manifest + adapter             │
│  .husky/            ← secret scanning + tool footer cleanup     │
│  .github/           ← PR template + issue templates             │
└─────────────────────────────────────────────────────────────────┘
```

---

## What's included

| Component | Location | What it does |
|---|---|---|
| Global identity | `templates/global/CLAUDE.md` | Hard rules, working style, memory discipline, and a `## Personal context` section to fill in once — loads at every session |
| Skills (5) | `templates/global/skills/` | Reusable prompt scripts for debug, review, refactor, tests, explain |
| Project brain | `templates/project/CLAUDE.md` | Project-specific identity, stack, conventions, off-limits paths |
| Processes (8) | `templates/project/.rig/processes/` | Step-by-step workflows, including work modes, new-task, ship, debug, post-merge, sprint, connector preflight, and upgrade |
| Rules (7) | `templates/project/.rig/rules/` | Coding, git, security, verification, session identity, session naming, and protected-path contracts |
| Memory system | `templates/project/.rig/memory/` | PROGRESS log, ERRORS log, DECISIONS log, CONTEXT_SNAPSHOT (session state), RIG_GAPS (self-improvement feedback) |
| Task lifecycle | `templates/project/.rig/tasks/` | Structured task files through backlog → active → done |
| Claude/Codex adapters | `templates/project/.claude/`, `.codex/`, generated `.agents/skills/` | Shared command behavior and protected-path enforcement across both agents |
| Feature docs | `templates/project/docs/features/` | README index + `/doc-feature` and `/refresh-feature-doc` commands for capturing and maintaining business-critical feature knowledge |
| Git hooks | `templates/project/.husky/` | Secret scanning (gitleaks) + auto-injected tool footer removal |
| GitHub templates | `templates/project/.github/` | PR template + 3 issue templates |
| Installer | `install.sh` | Interactive setup script — handles both layers |
| CI | `.github/workflows/ci.yml` | Runs bats test suite on every push and PR |

---

## Quickstart

### Step 1 — Install The Rig once (per machine)

```bash
# Clone to a permanent tools location — do this once, not per project
# HTTPS:
git clone https://github.com/laudtetteh/the-rig.git ~/tools/the-rig
# SSH:
git clone git@github.com:laudtetteh/the-rig.git ~/tools/the-rig

cd ~/tools/the-rig
./install.sh --global-only

# Fill in your personal context (name, role, expertise, working style)
$EDITOR ~/.claude/CLAUDE.md   # look for the ## Personal context section
```

This installs the global layer (`~/.claude/CLAUDE.md` + skills) once. Every project
on your machine shares it.

---

### Step 2 — Scaffold a new project

```bash
# Create your project directory (name it whatever you want)
mkdir ~/code/my-project && cd ~/code/my-project
git init

# Run the installer from your permanent Rig location
~/tools/the-rig/install.sh --project-only
# Default: stealth mode — all Rig files stored outside the repo (no .rig/ committed)
# Choose option 1 at the tracking prompt to store .rig/ in the repo instead.

# Then open Claude Code and run /kickoff, or open Codex and run $kickoff
# The kickoff adapter reads PROJECT_BRIEF.md, confirms the project shape,
# and scaffolds CLAUDE.md + task backlog + GitHub issues in one pass.
```

The Rig stays in `~/tools/the-rig/`. Your project is clean. By default, Rig memory
and task files are stored in `~/.rig/projects/<project-name>/` — not committed to your repo.

---

### Dropping The Rig into an existing project

```bash
cd ~/code/my-project
~/tools/the-rig/install.sh --project-only
# Choose: 2) New project — preserves all existing files, smart-merges settings.json
```

---

### Reducing permission prompts

Claude Code asks for confirmation on many tool calls. The Rig seeds a baseline
allowlist for common read-only git operations in `.claude/settings.json` automatically.

To expand it based on your actual session activity, run:

```
/fewer-permission-prompts
```

This scans recent tool use, identifies safe patterns, and adds them to your
`.claude/settings.json`. Run it once after a few sessions to cut the friction
significantly — it adds patterns, never removes them.

---

### Upgrading

```bash
# 1. Pull the latest Rig source
cd ~/tools/the-rig && git pull

# 2. Run the installer from inside your project
cd ~/code/my-project
~/tools/the-rig/install.sh --project-only
# Choose: 3) Upgrade — updates Rig-owned files, detects your customizations,
# skips user-owned files (CLAUDE.md, rules/, memory/, github/)
#
# If hooks or commands are broken: 4) Repair resets Rig-owned files to factory
# state while always preserving CLAUDE.md, rules, and memory files.
```

**Non-interactive / scripted form** (skips all menus — use this from automation or Claude Code):

```bash
~/tools/the-rig/install.sh \
  --project-only \
  --target ~/code/my-project \
  --tracking stealth \
  --strategy upgrade
```

`--project-only` is a scope flag (skip the global layer). It does not imply non-interactive
mode on its own — provide `--strategy` and `--tracking` to skip all prompts.

> **Forgot to pull first?** If you run the installer before pulling, it detects
> the stale source and offers to pull and re-run automatically — just choose option 1
> at the prompt. The installer passes all your flags through to the re-run.

> **Agent-driven mode.** `install.sh` also accepts `--strategy agent-plan`
> (read-only JSON preview) and `--strategy agent-upgrade` (applies, then emits
> a JSON result and exits `3` if anything needs manual review) for scripted or
> agent-driven callers. `/rig-upgrade --mode=agent` (the default) calls this
> same `agent-upgrade` strategy internally — only `/rig-upgrade --mode=classic`
> still uses plain `--strategy upgrade` shown above. See `docs/customizing.md`
> and `.rig/processes/UPGRADE_WORKFLOW.md` for the full contract.

**After the installer runs:** check how many files changed before committing.

```bash
git diff --stat
```

- **4+ files changed** (hooks, commands, process files): use a branch + PR —
  `git checkout -b chore/rig-upgrade-vX.Y.Z` — even if `housekeeping: direct-push` is set.
  Rig upgrades that rewrite hook scripts warrant review.
- **1–3 files changed** (VERSION, settings.json only): a direct `chore(rig):` commit is fine
  if `housekeeping: direct-push` is set.

> `housekeeping: direct-push` applies to memory commits (PROGRESS.md, task file moves) — not
> to upgrades that modify hooks and commands.

---

### Setting up on a new machine

When you move to a new machine or re-clone a project that already has The Rig installed:

```bash
# 1. Clone The Rig itself (to a permanent location)
git clone https://github.com/laudtetteh/the-rig.git ~/tools/the-rig

# 2. Install the global layer on the new machine
cd ~/tools/the-rig
./install.sh --global-only

# 3. Fill in your personal context (machine-local — ## Personal context section)
$EDITOR ~/.claude/CLAUDE.md

# 4. Clone your project
git clone <your-project-url> ~/code/my-project
cd ~/code/my-project

# 5. Re-run the project installer to wire hooks and restore the local layer
~/tools/the-rig/install.sh --project-only
# Choose: 1) First install
```

**Why step 5 is required:** several Rig files are gitignored and don't travel with
the repo (`CONTEXT_SNAPSHOT.md`, `PROGRESS_archive.md`, `ERRORS_archive.md`, flag
files). The hooks also need their executable bits set. Step 5 restores all of this.

> **External `.rig/` note:** if you use an external `.rig/` directory (`.rigpath`
> points outside the repo), the external directory doesn't clone with the project.
> You'll need to manually restore or re-create it on the new machine. See
> `docs/customizing.md` → "Keeping .rig/ invisible to teammates" for the full
> external directory setup.

Run Claude `/rig-status` or Codex `$rig-status` any time to verify hooks, memory
files, provider wiring, and pending flags in one pass. See
`docs/troubleshooting.md` for common issues after a re-clone.

---

## How it works at session start

When you open Claude Code or Codex in a project using The Rig, the selected
provider's hooks establish the same shared lifecycle:

1. **`session-start.sh`** injects `CONTEXT_SNAPSHOT.md`, pending flag warnings, and at most one applicable feature tip as hook context — before the first user turn
2. Claude loads its global `~/.claude/CLAUDE.md`; Codex loads its supported global instructions and generated personal skills
3. The agent reads `./CLAUDE.md` through Claude's native loading or Codex's configured fallback (unless a native `AGENTS.md` takes precedence)
4. The agent reads `./.rig/memory/CONTEXT_SNAPSHOT.md` — **if present, this is sufficient; the agent stops here**
5. `./.rig/memory/PROGRESS.md` — only loaded if snapshot is absent or stale
6. `./.rig/memory/ERRORS.md` — what to avoid
7. `./.rig/tasks/active/` — what's currently in flight

On every user prompt, `prompt-submit.sh` re-checks for pending flag warnings and re-injects them if still present. No re-briefing. No repeating context. Every session picks up exactly where the last one left off.

Feature tips use only local project signals (such as recorded errors, workflow
gaps, branch history, sessions, and issue references). A shared deterministic
catalog selects the highest-priority applicable tip, suppresses commands that
are unavailable or already used, and records a one-time sentinel under
`.rig/memory/tips/`. To opt out, create `.rig/memory/.rig-tips-disabled`. To
reset one tip, remove its `.rig/memory/tips/.tip-<id>-shown` file; remove the
`tips/` directory to reset all tips.

**At session end**, provider hook adapters bind lifecycle work to the exact native
session record. `stop.sh` maintains the checkpoint and wrap obligation for the
exact root session. Run Claude `/wrap` or Codex `$wrap` before closing for a full
snapshot — hooks are a safety net, not a replacement.

---

## The command set

**Start a project**
```
/kickoff      →  reads PROJECT_BRIEF.md, scaffolds CLAUDE.md + task backlog + GitHub issues (run once at project creation)
```

**Daily work**
```
/task              →  intake wizard: goal + autonomy/check-ins/risk/testing configuration
/run               →  execute active task; surfaces operating mode wizard if absent; chains at High autonomy
/run [slug]        →  run a single specific task
/sprint            →  current conflict-aware wave planner for already-qualified task files
/sprint [slug …]   →  sprint over a specific set of tasks only
```

**Ship and debug**
```
/ship         →  pre-commit cleanup + checklist + commit + open or update PR
/debug        →  hypothesis-first diagnosis, mandatory ERRORS.md entry
```

**Release**
```
/pre-release-review  →  full stability review before cutting a release: regressions, tests, security,
                         docs accuracy, maintainability, edge cases, version bump readiness;
                         outputs a scored report with a SHIP / HOLD recommendation
```

**Feature knowledge**
```
/recon [topic]               →  check internal docs first, then sweep PR history + codebase; synthesize timeline
/feature-context [name]      →  load an existing feature doc into context before starting work on that feature
/doc-feature [name]          →  check for existing doc, then research end-to-end; produce doc in docs/features/
/refresh-feature-doc [name]  →  re-verify an existing feature doc against current code; correct stale claims
```

**Orientation and docs**
```
/status       →  project dashboard: branch, active tasks, backlog count, recent progress, pending flags
/doc-list     →  show docs/INDEX.md without loading full doc files
/rig-help     →  print all Rig commands with descriptions and key flags
```

**Governance and housekeeping**
```
/post-merge        →  post-merge hygiene: pull main, update memory, move task file, housekeeping commit
/rig-propose       →  submit a change to governance files for human approval before anything is touched
/session-name      →  derive a name strictly from the current conversation/session and present it as a suggestion
/wrap              →  write CONTEXT_SNAPSHOT, capture in-flight task state, ensure memory is current
/rig-gaps          →  compile workflow friction from RIG_GAPS.md + ERRORS.md; format for submission
/rig-gaps --push   →  append unsubmitted entries to local Rig repo (requires rig-gaps-push-target: in CLAUDE.md)
/rig-gaps --submit →  create public GitHub issues in laudtetteh/the-rig (opt-in; requires .rig-contribute-enabled + gh auth)
/rig-upgrade                →  pull latest Rig source and re-run installer with --strategy upgrade
/rig-upgrade --version      →  print installed version, global installer version, and latest GitHub release; warns if behind
/rig-upgrade --scope=global →  upgrade global layer only; --scope=project for project layer only
```

---

## What the hooks enforce

### Claude Code hooks

| Hook | Event | What it does |
|---|---|---|
| `session-start.sh` | `SessionStart` | Injects `CONTEXT_SNAPSHOT.md` and pending flag warnings before the first user turn |
| `prompt-submit.sh` | `UserPromptSubmit` | Re-checks `.wrap-needed`/`.post-merge-pending` on every prompt; re-injects warnings when present |
| `permission-request.sh` | `PermissionRequest` | Auto-approves safe read-only tool patterns to reduce permission-prompt noise |
| `pre-tool.sh` | `PreToolUse` (every tool call) | Blocks writes to protected paths; gates `git commit` on user go-ahead sentinel; blocks direct commits to `main`/`master` unless `housekeeping: direct-push`; redirects worktree writes to main-repo path |
| `post-tool.sh` | `PostToolUse` (every tool call) | Auto-stubs `PROGRESS.md` after every commit; clears commit sentinel |
| `pre-compact.sh` | `PreCompact` | Writes compact checkpoint + `compactionSummary` before context compaction |
| `post-compact.sh` | `PostCompact` | Injects checkpoint content as `additionalContext` after compaction |
| `subagent-start.sh` | `SubagentStart` | Injects project name, branch, active task, and key conventions into spawned subagents |
| `stop.sh` | `Stop` (every agent turn) | Updates `Last updated:` in `CONTEXT_SNAPSHOT.md`; appends session-end boundary to `PROGRESS.md` |

### Codex hooks

`.codex/hooks.json` and `.codex/hooks/rig-adapter.sh` translate documented Codex
events and payload fields into the same canonical hook contracts. Provider-native
session IDs remain authoritative; Codex does not infer identity from branches,
titles, transcripts, or singleton state.

### Git hooks

| Hook | Trigger | What it prevents |
|---|---|---|
| `pre-commit` | Before every git commit | Secrets reaching the repository |
| `commit-msg` | On every git commit | (1) Strips auto-injected tool footers (`Co-Authored-By: Claude`, `Made-with-Claude`, etc.); (2) validates Conventional Commits subject-line format; (3) requires a tracker-specific issue reference (`[#N]` for GitHub, `[TEAM-123]` for Linear, etc.) when `issue-tracking:` is set in `CLAUDE.md` |
| `post-commit` | After every git commit | Re-applies footer stripping in case the git client re-injected footers after `commit-msg` ran |

---

## Requirements

| Requirement | Notes |
|---|---|
| [Claude Code](https://docs.anthropic.com/claude-code) or [Codex](https://developers.openai.com/codex/) | At least one supported coding-agent CLI; both may be installed |
| bash 3.2+ | For `install.sh` and hook scripts |
| git | For hooks and version control |
| python3 | Required by `pre-tool.sh` for JSON parsing. Standard on macOS 12+ and most Linux distros. |
| [gitleaks](https://github.com/gitleaks/gitleaks) | Secret scanning (`brew install gitleaks`) |
| npm / npx | For Husky initialization (optional if not using Node projects) |

---

## Documentation

See [docs/INDEX.md](docs/INDEX.md) for the canonical documentation index.

---

## Origin

The Rig grew organically out of real project work, starting with [LaudBot](https://github.com/laudtetteh/laudbot) — an AI-powered interactive resume where each session revealed a new failure mode and prompted a new layer of scaffolding. Every component exists because something went wrong without it.

It was subsequently piloted on [4Culture.org](https://4culture.org), a shared-repo WordPress platform with multiple contributors. That engagement surface stealth mode, the housekeeping commit convention, and several robustness improvements to the hook system.

The LaudBot repo history — 100+ PRs, clean conventional commits, linked issues, documented architecture — is the original proof of concept.

---

## License

MIT — see [LICENSE](LICENSE).
