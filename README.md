# The Rig

**An opinionated agentic coding system for Claude Code.**

The Rig wraps Claude Code with structured memory, enforced workflows, automated safety hooks, and a commit history discipline — so AI-assisted development stays consistent across sessions, projects, and months.

Built and refined across 100+ pull requests on a real production project.

---

## The problem it solves

Claude Code is powerful but stateless. Without structure, every session:

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
│  GLOBAL LAYER  (~/.claude/)                                     │
│  Installed once. Applies to every project on the machine.       │
│                                                                 │
│  CLAUDE.md          ← identity, hard rules, working style       │
│  skills/            ← reusable skill scripts (5 included)       │
│  ~/.your-ai-contexts/PROFILE.md  ← personal/professional context│
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
│  .claude/           ← hook wiring + slash commands              │
│  .husky/            ← secret scanning + tool footer cleanup     │
│  .github/           ← PR template + issue templates             │
└─────────────────────────────────────────────────────────────────┘
```

---

## What's included

| Component | Location | What it does |
|---|---|---|
| Global identity | `templates/global/CLAUDE.md` | Hard rules, working style, memory discipline — loads at every session |
| Personal profile | `templates/global/PROFILE.md.example` | Your professional context — the agent reads it so you never re-explain yourself |
| Skills (5) | `templates/global/skills/` | Reusable prompt scripts for debug, review, refactor, tests, explain |
| Project brain | `templates/project/CLAUDE.md` | Project-specific identity, stack, conventions, off-limits paths |
| Processes (4) | `templates/project/.rig/processes/` | Step-by-step workflows: new-task, ship, debug, post-merge |
| Rules (4) | `templates/project/.rig/rules/` | Coding standards, git conventions, security rules, verification protocol |
| Memory system | `templates/project/.rig/memory/` | PROGRESS log, ERRORS log, DECISIONS log, CONTEXT_SNAPSHOT (session state), RIG_GAPS (self-improvement feedback) |
| Task lifecycle | `templates/project/.rig/tasks/` | Structured task files through backlog → active → done |
| Claude Code hooks | `templates/project/.claude/` | Pre/post-tool enforcement + 13 slash commands |
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

# Fill in your personal profile
$EDITOR ~/.your-ai-contexts/PROFILE.md
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
# Choose: 2) New project

# Then open Claude Code in your project and run /kickoff
# /kickoff reads PROJECT_BRIEF.md, confirms the project shape,
# and scaffolds CLAUDE.md + task backlog + GitHub issues in one pass.
```

The Rig stays in `~/tools/the-rig/`. Your project is clean.

---

### Dropping The Rig into an existing project

```bash
cd ~/code/my-project
~/tools/the-rig/install.sh --project-only
# Choose: 2) New project — preserves all existing files, smart-merges settings.json
```

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

---

### Setting up on a new machine

When you move to a new machine or re-clone a project that already has The Rig installed:

```bash
# 1. Clone The Rig itself (to a permanent location)
git clone https://github.com/laudtetteh/the-rig.git ~/tools/the-rig

# 2. Install the global layer on the new machine
cd ~/tools/the-rig
./install.sh --global-only

# 3. Fill in your personal profile (machine-local — not committed)
$EDITOR ~/.your-ai-contexts/PROFILE.md

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

See `docs/troubleshooting.md` for common issues after a re-clone.

---

## How it works at session start

When you open Claude Code in a project using The Rig, the agent automatically reads (in order):

1. `~/.claude/CLAUDE.md` — who it is and how to behave
2. `~/.your-ai-contexts/PROFILE.md` — who you are
3. `./CLAUDE.md` — what this project is
4. `./.rig/memory/CONTEXT_SNAPSHOT.md` — full current state (written at session end by `/wrap`); **if present, this is sufficient — the agent stops here**
5. `./.rig/memory/PROGRESS.md` — build history; only loaded if snapshot is absent or stale
6. `./.rig/memory/ERRORS.md` — what to avoid
7. `./.rig/tasks/active/` — what's currently in flight

No re-briefing. No repeating context. Every session picks up exactly where the last one left off.

**At session end**, `stop.sh` fires automatically (Claude Code's Stop event): it updates the `Last updated:` timestamp in `CONTEXT_SNAPSHOT.md` and appends a `<!-- session-end -->` boundary marker to `PROGRESS.md`. Run `/wrap` before closing Claude Code for a full snapshot — `stop.sh` is a lightweight safety net, not a replacement.

---

## The command set

**Start a project**
```
/kickoff      →  reads PROJECT_BRIEF.md, scaffolds CLAUDE.md + task backlog + GitHub issues
```

**Daily work**
```
/task              →  intake wizard: define the task + configure autonomy, check-ins, and risk
/run               →  execute the backlog; respects per-task operating mode; chains at High autonomy
/run [slug]        →  run a single specific task
/sprint            →  conflict-aware sprint planner: groups tasks into waves, runs wave by wave
/sprint [slug …]   →  sprint over a specific set of tasks only
```

**Ship and debug**
```
/ship         →  pre-ship checklist, commit, open PR
/debug        →  hypothesis-first diagnosis, mandatory ERRORS.md entry
```

**Feature knowledge**
```
/recon [topic]               →  sweep PR history + commits + codebase for a keyword; synthesize an evolution timeline
/feature-context [name]      →  load an existing feature doc into context before starting work on that feature
/doc-feature [name]          →  research a feature end-to-end; produce a structured doc in docs/features/
/refresh-feature-doc [name]  →  re-verify an existing feature doc against current code; correct stale claims
```

**Governance and housekeeping**
```
/post-merge   →  post-merge hygiene: pull main, update memory, move task file, housekeeping commit
/rig-propose  →  submit a change to governance files for human approval before anything is touched
/session-name →  derive a session name from current work and present it as a suggestion
/wrap         →  write CONTEXT_SNAPSHOT, ensure memory is current, log any Rig gaps before closing
/rig-gaps     →  compile workflow friction from RIG_GAPS.md + ERRORS.md; format for submission to The Rig dev session
/rig-upgrade  →  pull latest Rig source and re-run the installer with --strategy upgrade
```

---

## What the hooks enforce

| Hook | Trigger | What it prevents |
|---|---|---|
| `pre-tool.sh` | Before every Claude Code tool call | Writes to protected paths; blocks `git commit` until user gives explicit go-ahead |
| `post-tool.sh` | After every Claude Code tool call | PROGRESS.md being skipped after a commit; clears commit sentinel after use |
| `stop.sh` | When the agent finishes its final response | CONTEXT_SNAPSHOT going stale — updates `Last updated:` and appends a session-end boundary to PROGRESS.md without requiring `/wrap` |
| `pre-commit` | Before every git commit | Secrets reaching the repository |
| `commit-msg` | On every git commit | (1) Strips auto-injected tool footers (`Co-Authored-By: Claude`, `Made-with-Claude`, etc.) from commit messages; (2) validates Conventional Commits subject-line format; (3) requires a tracker-specific issue reference (`[#N]` for GitHub, `[TEAM-123]` for Linear, etc.) when `issue-tracking:` is set in `CLAUDE.md` |
| `post-commit` | After every git commit | Re-applies footer stripping in case the git client re-injected footers after `commit-msg` ran |

---

## Requirements

| Requirement | Notes |
|---|---|
| [Claude Code](https://docs.anthropic.com/claude-code) | The AI coding CLI this system wraps |
| bash 3.2+ | For `install.sh` and hook scripts |
| git | For hooks and version control |
| [gitleaks](https://github.com/gitleaks/gitleaks) | Secret scanning (`brew install gitleaks`) |
| npm / npx | For Husky initialization (optional if not using Node projects) |

---

## Documentation

- [How it works](docs/how-it-works.md) — architecture deep-dive with diagrams
- [Key decisions](docs/decisions.md) — design rationale and tradeoffs
- [Lessons learned](docs/lessons-learned.md) — 13 documented pitfalls from the pilot
- [Customizing](docs/customizing.md) — adapting The Rig for your stack

---

## Origin

The Rig grew organically out of real project work, starting with [LaudBot](https://github.com/laudtetteh/laudbot) — an AI-powered interactive resume where each session revealed a new failure mode and prompted a new layer of scaffolding. Every component exists because something went wrong without it.

It was subsequently piloted on [4Culture.org](https://4culture.org), a shared-repo WordPress platform with multiple contributors. That engagement surface stealth mode, the housekeeping commit convention, and several robustness improvements to the hook system.

The LaudBot repo history — 100+ PRs, clean conventional commits, linked issues, documented architecture — is the original proof of concept.

---

## License

MIT — see [LICENSE](LICENSE).
