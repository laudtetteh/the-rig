# Customizing The Rig

> Coexistence: customize shared `.rig` contracts once, then regenerate provider adapters. Claude command sources and Codex generated skills may use different invocation syntax, but they must preserve the same behavior.

How to adapt The Rig for your stack, team size, and workflow preferences.

---

## Project settings (quick reference)

The fastest way to configure The Rig for a project is the `## Project settings` block
in the project `CLAUDE.md`. Set these once and every session inherits them:

```
base-branch: main          # integration branch all PRs target
housekeeping: direct-push  # direct-push | pr-required (how /post-merge commits)
issue-tracking: github     # github | linear | trello | gus | none
issue-creator: user        # user (default) | agent — GitHub only: agent auto-creates issues
secret-scanner: gitleaks   # gitleaks | none
commit-cleanup: yes        # yes | no (strip auto-injected tool footers from commits)
rig-gaps-push-target:      # optional: absolute path to RIG_GAPS.md in the local Rig repo
```

**`issue-tracking:`** shapes the entire task intake and commit workflow. The ref format enforced in the `commit-msg` hook (`[#N]`, `[TEAM-123]`, `[trello:ID]`, `[W-N]`) and the intake question in Claude `/task` or Codex `$task` both follow the configured tracker. Set to `none` for personal projects, prototypes, or repos without an issue tracker.

**`rig-gaps-push-target:`** enables `/rig-gaps --push` — a same-machine shortcut that appends unsubmitted gap entries directly to The Rig's own `RIG_GAPS.md` without copy-paste. Only useful if you maintain The Rig (or a fork) on this machine. Example:

```
rig-gaps-push-target: /Users/you/.rig/projects/the-rig/memory/RIG_GAPS.md
```

Leave blank (or omit the line) if The Rig repo isn't on this machine.

**Contribute mode — opt-in GitHub issue submission via `/rig-gaps --submit`:**

`/rig-gaps --submit` creates public GitHub issues in `laudtetteh/the-rig` directly via the `gh` CLI. It requires explicit opt-in:

```bash
touch .rig/memory/.rig-contribute-enabled
```

This file is gitignored — opt-in is per-machine, not per-repo. When the sentinel exists, each gap entry is reviewed and confirmed individually before submission. Requires `gh auth login` with public repo access. Strip any project-specific details (client names, internal paths) before submitting — entries become publicly visible.

For deeper customization of individual components, see the sections below.

---

## What to customize vs. what to leave alone

| Component | Customize | Leave alone |
|---|---|---|
| `CLAUDE.md` (global) | Stack defaults, personal sections | Hard rules, memory discipline, working style |
| `CLAUDE.md` (project) | Everything — it's project-specific | — |
| `PROJECT_BRIEF.md` | All of it — fill in your project | — |
| `.rig/rules/coding-standards.md` | All of it — fill in your stack's conventions | Structure (sections by runtime) |
| `.rig/rules/security.md` | Project-specific additions section | Non-negotiables (top of file) |
| `.claude/hooks/pre-tool.sh` | `BLOCKED_PATHS` array | Shared enforcement logic and provider payload normalization |
| `.claude/commands/task.md` | Autonomy/check-in/risk default levels | Canonical workflow structure mirrored into the generated Codex `$task` skill |
| `.husky/filter-commit-message-inplace.sh` | Add patterns for other AI tools | Existing patterns |
| `.gitleaks.toml` | Allowlist entries | `useDefault = true` |
| Processes | Scope and step details | Core sequence and gate logic |

---

## Adapting for your language stack

### Python-only project
In `.rig/rules/coding-standards.md`: delete the TypeScript section, fill in Python
conventions fully. Adjust imports section for your actual toolchain (Black, isort,
mypy, etc.).

### Node/TypeScript-only project
Delete the Python section. Expand the TypeScript section with your framework
conventions (React, Express, etc.).

### Go, Rust, Ruby, or any other language
The `coding-standards.md` template uses `[Runtime 1]` / `[Runtime 2]` as placeholder
headings — rename them to your languages and fill in the conventions. The structure
(naming, types, docs, general rules) applies to any typed language.

---

## Configuring protected paths

Edit the canonical `.claude/hooks/pre-tool.sh` handler and update the
`BLOCKED_PATHS` array. Codex reaches this same enforcement through
`.codex/hooks/rig-adapter.sh`; do not duplicate policy in that adapter:

```bash
BLOCKED_PATHS=(
  ".env.production"       # almost always want this
  "migrations/"           # uncomment if you run migrations manually
  "data/approved/"        # project-specific curated data
  "secrets/"              # any directory with sensitive files
)
```

The matching is substring-based — any file path containing the string will be blocked.
Keep entries specific enough to not accidentally block legitimate paths.

The `RIG_PROTECTED` block above `BLOCKED_PATHS` protects The Rig's own governance files
(`.rig/processes/`, `.rig/rules/`, `.husky/`, `CLAUDE.md`, `.claude/hooks/`).
Don't modify it directly — use `/rig-propose` instead.

---

## Configuring the base branch

The installer prompts for the base branch name and substitutes it throughout
all workflow files. If you need to change it after install, update the
`## Base branch` section in your project `CLAUDE.md`:

```markdown
## Base branch

base-branch: integration
```

Then manually update `git checkout [BASE_BRANCH]` references in:
- `.rig/processes/POST_MERGE_WORKFLOW.md`
- `.rig/processes/SHIP_WORKFLOW.md`
- `.claude/commands/ship.md`
- `.claude/commands/post-merge.md`

To auto-detect, the installer reads `git symbolic-ref refs/remotes/origin/HEAD`
and offers it as the default.

---

## Configuring the housekeeping commit convention

By default, `/post-merge` commits memory updates directly to the base branch — no branch,
no PR. For repos that require a PR for every change, set `pr-required` in the
project `CLAUDE.md`:

```markdown
## Git workflow convention

housekeeping: pr-required
```

| Value | Behaviour |
|---|---|
| `direct-push` | Commits and pushes directly to the base branch. Default. |
| `pr-required` | Creates `chore/post-merge-[N]` branch and opens a small PR. |

Change this once per project and `/post-merge` respects it every time.

---

## Adjusting the intake wizard defaults

`/task` defaults to **Medium autonomy / Normal check-ins / Balanced risk**. If your
workflow consistently runs at a different spice level, update the defaults in
`templates/project/.claude/commands/task.md`:

```markdown
Default: **3 — High (Autonomous)**
```

You can also update `.rig/tasks/backlog/TASK_example.md` — the `## Operating mode` table
is pre-filled with defaults. Change those values and every new task starts with your
preferred settings.

---

## Configuring protected paths for /rig-propose

The governance gate in `/rig-propose` mirrors the `RIG_PROTECTED` list in `pre-tool.sh`.
If you add new governance files that should require a proposal before modification,
add them to both places:

1. `pre-tool.sh` → `RIG_PROTECTED` array
2. `commands/rig-propose.md` → "When to use it" section

---

## Adding command and skill workflows

Create a new `.md` file in `.claude/commands/`. The filename becomes the Claude
slash-command name. For Codex-enabled installs, the installer generates the
corresponding `$name` skill under `.agents/skills/name/` from this canonical
source. Do not hand-edit generated skills; change the command source or a shared
`.rig/processes/` contract and regenerate through the installer.
Structure follows the existing commands: what it does, usage, steps, notes.

Example — `/review-pr`:

```markdown
# Command: /review-pr

Runs the code-review skill against the current diff.

## What this does
1. Gets the diff for the current branch vs main
2. Invokes the code-review skill
3. Reports blockers first, then warnings, then suggestions

## Usage
/review-pr
```

---

## Adjusting the pre-ship checklist

Edit `.rig/processes/SHIP_WORKFLOW.md` Step 1. Add or remove checklist items to match your
project's requirements. Common additions:

- Accessibility check for UI changes
- Migration review gate for database changes
- Performance regression check for hot paths
- Dependency license check for new packages

---

## Keeping .rig/ invisible to teammates

If you're using The Rig on a shared repo where teammates don't use it, you have
two options to avoid `.rig/` showing up in their `git status`.

### Option A — Local gitignore (simplest)

The installer offers this as a tracking choice. It adds `.rig/` to
`.git/info/exclude`, which is per-clone and never committed. Teammates don't see
it; no `.gitignore` change is needed.

To do it manually after install:

```bash
echo ".rig/" >> .git/info/exclude
```

### Option B — External directory

Install `.rig/` to a path outside the repo entirely. Use `--tracking external` with an optional `--rig-dir` to specify the path:

```bash
~/tools/the-rig/install.sh --project-only --tracking external --rig-dir ~/.rig/projects/my-project
```

Or choose option 3 in the interactive tracking prompt. The installer will:

1. Install all `.rig/` files to the external path
2. Write a `.rigpath` file in the project root containing the external path
3. Add `.rigpath` to `.git/info/exclude` automatically
4. Update `CLAUDE.md`'s `@` imports and context-loading paths to use the
   absolute external location
5. Update the hooks (`pre-tool.sh`, `post-tool.sh`) to resolve `RIG_DIR` via
   `.rigpath` at runtime — no hardcoded paths

The project root stays clean. The agent finds its memory and rules via
`.rigpath`. Teammates never see any of it.

> ⚠️ **Re-clone warning:** when you clone the project on a new machine, the
> external `.rig/` directory doesn't travel with it. You must manually restore
> the external directory on the new machine — either by re-running the installer
> with `--tracking external --rig-dir <same-path>`, or by copying it from a backup.
> See `docs/troubleshooting.md` → "CONTEXT_SNAPSHOT.md is missing after a re-clone"
> for the full recovery steps.

### Option C — Stealth mode (zero traces in git)

For multi-contributor repos where teammates must never see any Rig files — not
even in `git status` — choose **option 4 (Stealth)** in the installer's tracking
prompt.

What stealth mode does in a single pass:

1. Installs `.rig/` to an external path (default: `~/.rig/projects/<project-name>/`)
2. Writes `.rigpath` and adds it to `.git/info/exclude`
3. Adds all other Rig artifacts to `.git/info/exclude`:
   `CLAUDE.md`, `PROJECT_BRIEF.md`, `.claude/`, `.github/`, `.gitleaks.toml`, `docs/features/README.md`
4. Copies git hooks directly to `.git/hooks/` (no Husky required — `.git/hooks/`
   is never committed and invisible to teammates)

Claude Code still reads `.claude/settings.json` from disk at session start — it
just isn't tracked by git.

**Important:** stealth files live on disk only. When you clone the project on a new
machine, re-run the installer with option 4 to restore them. The `.git/info/exclude`
entries and `.git/hooks/` scripts are per-clone and must be set up on each machine.

---

## Scaling to a team

> **Concurrent-session boundary:** Implementation sessions should use isolated
> worktrees and distinct task/status files. Shared snapshot writes remain serialized:
> `/wrap` and `/post-merge` use `.snapshot-write-in-progress` and fail closed while
> another live writer owns it. Session naming also fails closed for write-capable
> workflows when the current launch cannot be resolved unambiguously.

The Rig was designed for solo or small-team use. For larger teams:

**Global layer**: Each engineer installs their own global layer. The personal profile
is individual — don't share it. Codex uses its own supported global instruction
and personal-skill locations; the `CLAUDE.md` global template should be the same
across the team (standardized hard rules and working style).

**Project layer**: Commit the project layer to the repo. Every team member gets the
same rules and workflows. If some engineers don't use The Rig, use the local
gitignore approach above.

**Memory files**: `PROGRESS.md` and `ERRORS.md` are committed and shared — everyone
sees the same build history and pitfall log. `CONTEXT_SNAPSHOT.md` is gitignored and
machine-local — each engineer has their own.

**Task files**: One task per `.rig/tasks/active/` file per engineer. Use naming conventions
to avoid collisions: `TASK_[engineer-initials]-[feature].md`.

---

## Using without Husky (non-Node projects)

The Husky hooks are POSIX shell scripts that work independently of Husky. You can
wire them directly:

```bash
# Copy hooks to .git/hooks/
cp .husky/pre-commit .git/hooks/pre-commit
cp .husky/commit-msg .git/hooks/commit-msg
cp .husky/post-commit .git/hooks/post-commit
cp .husky/filter-commit-message-inplace.sh .husky/

# Set executable bits
chmod +x .git/hooks/pre-commit .git/hooks/commit-msg .git/hooks/post-commit
```

The `.git/hooks/` approach works for any project regardless of language. The downside:
hooks in `.git/hooks/` are not committed to the repo, so teammates must set them up
manually. Husky solves this by checking in hooks to `.husky/` and auto-installing them
via `prepare` script in `package.json`.

---

## Keeping tool attribution footers in commits

By default, The Rig strips auto-injected footers (`Co-Authored-By: Claude`,
`Made-with-Claude`, etc.) from commit messages. These lines are inserted automatically
by AI coding tools — The Rig removes them so commit messages stay clean and reflect
what the human author wrote.

If you want these footers to remain (e.g. your team has a policy of crediting AI tools
in commit history), comment out or remove the `commit-msg` and `post-commit` hooks
from `.husky/`.

The `pre-commit` (gitleaks) is independent and unaffected.

---

## Replacing gitleaks with another secret scanner

Edit `.husky/pre-commit`. Replace the gitleaks block with your scanner of choice.
The hook structure (check for binary → run scanner → block on non-zero exit) works
for any scanner that exits non-zero on detection.

Common alternatives: `trufflehog`, `git-secrets`, `detect-secrets`.

---

## The decisions log

`.rig/memory/DECISIONS.md` is included in the default scaffold. The agent logs to it
when a significant architectural, product, or process decision is made — especially
one that closes off alternatives or would surprise a future reader.

Format per entry:

```markdown
## [YYYY-MM-DD] — [Short title]

**Context**: Why this decision needed to be made
**Decision**: What was chosen
**Rejected**: What was considered and not chosen
**Rationale**: Why
**Consequences**: What this decision implies going forward
```

Unlike `CONTEXT_SNAPSHOT.md`, this file is committed — decisions are project history.
The project `CLAUDE.md` context-loading sequence already references it.

---

## Upgrading The Rig

When a new version of The Rig is released, pull the latest from the repo and re-run
the installer against your project:

```bash
# 1. Pull the latest Rig source
cd ~/tools/the-rig && git pull

# 2. Run the installer from inside your project
cd ~/code/my-project
~/tools/the-rig/install.sh --project-only
```

Choose **Upgrade (option 3)** from the intent menu. This is the recommended
path for all upgrades. It:

- **Auto-updates** Rig-owned files (hooks, commands, process workflows, husky hooks)
  that you haven't modified since install — no prompts, no friction
- **Prompts with a diff** for any Rig-owned file you've customized — you see exactly
  what changed before deciding to overwrite or keep your version
- **Skips** user-owned files entirely (`CLAUDE.md`, `.rig/rules/`, `.rig/memory/`,
  `.rig/tasks/`, `.github/`) — your customizations are always preserved
- **Smart-merges** `.claude/settings.json` — new hooks are added without duplicating
  anything already present

### How it works: the manifest

The installer records the SHA256 hash of each Rig-owned file in
`.rig/memory/.rig-manifest` on every install. This is committed to the repo.

On upgrade, for each Rig-owned file:

| Condition | What happens |
|---|---|
| Dest hash == new template hash | Already up to date — skipped |
| Dest hash == manifest hash | Unmodified since install — overwritten silently (backup kept) |
| Dest hash != manifest hash | You've customized it — diff shown, you choose: overwrite / skip |
| No manifest entry | First upgrade (manifest didn't exist yet) — overwritten silently |

Backups are written to `.rig-backup/<timestamp>/` in the project root before any
overwrite. In stealth or external tracking mode, backups go to
`$EXTERNAL_RIG_DIR/backups/<timestamp>/` instead — so they never surface in the
project's git status. Nothing is ever lost.

### Manifest-aware customization

Files in the **Rig-owned** category that you commonly want to customize:

| File | Customizable section |
|---|---|
| `.claude/hooks/pre-tool.sh` | `BLOCKED_PATHS` array (project-specific protected paths) |
| `.claude/commands/ship.md` | Steps can be extended with project-specific checks |
| `.rig/processes/*.md` | Steps can be extended; core gate logic should be preserved |
| `.husky/filter-commit-message-inplace.sh` | Add patterns for other AI tools |

The Upgrade strategy will detect changes to these files and prompt before overwriting.

Upgrade writes are journaled under `.rig-backup/.in-progress/` while they run.
If the process is interrupted, the next upgrade restores the recorded backups
before continuing. To perform recovery without applying a new version, run:

```bash
./install.sh --project-only --target /path/to/project --tracking repo --recover
```

Recovery records contain operation types and relative paths only; they do not
contain file contents or command output. A successful upgrade moves the journal
into its timestamped backup directory for audit and rollback reference.
Your customizations are safe.

### Choosing the right intent

The installer asks "What are you doing?" and derives the right strategy from your
answer. You don't need to think about strategy names:

| Intent | Use when | Underlying strategy |
|---|---|---|
| **1) First install** | Setting up The Rig on a new machine | merge (global + project) |
| **2) New project** | Scaffolding into a new or existing project | merge (project only) |
| **3) Upgrade** | Updating an existing Rig install — recommended | upgrade (project only) |
| **4) Repair** | Resetting Rig-owned files to a clean state | overwrite (project only) |
| **5) Custom** | Full control over strategy and components | you choose |

For scripting and CI, the `--strategy` flag accepts the internal strategy name
directly (merge / skip / overwrite / upgrade / interactive), bypassing the intent
menu entirely.

After upgrading, review the CHANGELOG for any manual steps — some releases may add
new fields to `.rig/rules/` files or project `CLAUDE.md` that the Upgrade intent
skips (since those are user-owned).
