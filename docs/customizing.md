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
   `CLAUDE.md`, `PROJECT_BRIEF.md`, `.claude/`, `.agents/`, `.codex/`, `.mcp.json`,
   `.playwright-mcp/`, `.github/`, `.gitleaks.toml`, `docs/features/README.md`,
   `.rig-backup/`, `.rig/`, and every generated launcher under `bin/` (not just
   `bin/rig` — `bin/rig-connector-preflight`, `bin/rig-sprint`, and any future
   launcher `install.sh` ships are enumerated from its own `templates/project/bin/`
   source, so this list can never drift the way it did before issue #444 lane 444-D)
4. Copies git hooks directly to `.git/hooks/` (no Husky required — `.git/hooks/`
   is never committed and invisible to teammates). Each installed hook is now
   manifest-tracked and backed up before an ordinary-mode overwrite (issue #444
   lane 444-G) — see "Verifying an upgrade" below for what happens when
   `agent-upgrade` finds a customized hook here instead.

> **Auditing an existing stealth install:** `bin/rig doctor` (see "Verifying an
> upgrade" below) runs a read-only stealth audit and reports any tracked or
> visible-unignored Rig artifact it finds — useful for confirming an older
> install (from before lane 444-D) doesn't have a leftover launcher leak.

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
git -C ~/tools/the-rig checkout main
git -C ~/tools/the-rig pull --ff-only origin main
cat ~/tools/the-rig/VERSION

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

### Manifest metadata and provenance fields

Alongside the plain-text `.rig/memory/.rig-manifest` (hash + path, one line per
file), the installer also writes a JSON companion at
`.rig/memory/.rig-manifest.json`. If you open it directly, each entry looks
like this:

```json
".claude/hooks/pre-tool.sh": {
  "sha256": "…",
  "owner": "rig",
  "source": "claude-native",
  "type": "file",
  "mode": "755",
  "installer_version": "1.24.0",
  "base_revision": "1.24.0",
  "generator": "install.sh",
  "provider": "claude"
}
```

What each field means:

- **`owner`** — `"rig"` (a Rig-owned infrastructure file — see `is_rig_owned()`
  in `install.sh`) or `"user"` (a file you're expected to edit).
- **`source`** — where the artifact family comes from:
  `generated-codex` (mirrored into `.agents/skills/`), `codex-native`
  (`.codex/*`), `claude-native` (`.claude/*`), `shared-rig` (`.rig/*`),
  `project-tooling` (`.husky/*`, `.gitleaks.toml`, stealth `.git/hooks/*`), or
  `project-user` (everything else).
- **`generator`** — the tool that actually produced the artifact's content:
  `install.sh` for a hand-authored template copied verbatim, or
  `codex-mirror` for a file `installer/generate-codex-skills.py` derived from
  a canonical Claude command.
- **`provider`** — which agent context the artifact belongs to: `claude`,
  `codex`, `both`, or `none`, using the install-target vocabulary described
  above.
- **`base_revision`** — a hint used only to order the historical template scan.
  It is never trusted as the lookup key for a three-way merge. The resolver
  proves the base by comparing the manifest's recorded SHA256 hash against
  rendered template content from reachable release tags and, first, the current
  worktree candidate. There is no separate per-file template version yet, so
  this is set to the installer's own `VERSION` at write time (the same value as
  `installer_version`) even though the fields answer different questions.

An entry written before this metadata existed (pre-issue-#444) simply omits
these fields, or carries explicit `null` — that is normal "legacy/unknown
provenance," not an error. A value present but outside its known vocabulary
(for example an unrecognized `owner`) is what the `manifest_provenance` doctor
gate below actually flags.

A `base_revision` that is a parseable version strictly newer than the
installer version currently running (issue #463) is a separate case: it is
reported as its own `future_revision` finding, distinct from `malformed`.
`agent-plan`/`agent-upgrade` refuse (exit `3`, `status: "refused"`) with
repair guidance; plain `--strategy upgrade` still completes (exit `0`) but
prints the finding and sets `RIG_UPGRADE_REVIEW_REQUIRED=1` for manual
review, exactly as it already does for a customized or
conflicting file.

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
into its timestamped backup directory for local recovery evidence.

Completed upgrades have a separate undo path: upgrade and agent-upgrade runs
write a durable report under `upgrade-reports/`, and `bin/rig upgrade rollback`
uses that report to undo one completed upgrade after a dry-run review. It is
not a replacement for `install.sh --recover`, which only handles interrupted
transactions. Your customizations are safe.

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

### Agent-driven upgrade mode (`agent-plan` / `agent-upgrade`)

Everything above describes the **ordinary** Upgrade intent — interactive by
default, and choice-driven in non-interactive/CI use (a customized file is
always skipped and reported, never silently changed). That behavior has not
changed.

If you want semantic or intelligent convergence during a Rig upgrade, use the
agent path (`/rig-upgrade --mode=agent`, `$rig-upgrade --mode=agent`, or
`install.sh --strategy agent-upgrade`). Do not use raw `install.sh --strategy
upgrade` for that expectation: the raw installer is deliberately conservative
and treats customized Rig-owned files as manual-review surfaces unless the
ordinary upgrade path already knows they are safe to update.

Separately, `install.sh` also accepts two more `--strategy` values that exist
specifically for a calling agent or script: `agent-plan` is read-only and emits
a JSON plan of what an upgrade would do with zero writes; `agent-upgrade`
applies the same convergeable actions non-interactive `upgrade` already
applies, plus a structure-aware/three-way merge step for customized files when
the incoming and local changes don't conflict. `settings.json` has a dedicated
JSON merge path; JSON, TOML, frontmatter Markdown, and other text artifacts use
the convergence helper appropriate to their file type. Both print one
machine-readable JSON document
and exit `3` (`status: "refused"`) rather than `0` if anything still needs a
human — see `.rig/processes/UPGRADE_WORKFLOW.md` → "Agent-driven upgrade
contract" for the full schema, exit codes, and worked examples.

**`/rig-upgrade` now wires both modes explicitly.** Its survey phase (1c-bis)
always uses `agent-plan` as a read-only preview. Phase 2 (2-mode) then chooses
between them: `--mode=agent` (also the non-interactive default, since guarded
convergence never silently overwrites a customization) runs `install.sh
--strategy agent-upgrade`, presents each `conflicts[]` entry with its repair
guidance verbatim, and — once the upgrade succeeds — Phase 3d runs `bin/rig
doctor --json` and surfaces any failing gate before the command finishes.
`--mode=classic` runs plain `install.sh --strategy upgrade`, the original
per-file interactive review flow, unchanged from before agent-driven
convergence existed. See `templates/project/.claude/commands/rig-upgrade.md`
for the full Phase 2/2a-agent/2b-agent/3d flow.

Tradeoff summary:

- `--strategy upgrade`: easiest to reason about; never attempts semantic merges
  for customized surfaces; leaves more manual review when you have local Rig
  customizations.
- `--strategy agent-upgrade`: preserves compatible local customizations while
  applying incoming Rig changes; refuses instead of guessing when convergence is
  unsafe; requires the caller to inspect JSON conflicts and validate the result.
- `/rig-upgrade` / `$rig-upgrade`: preferred user-facing flow because it runs
  the preview, applies the selected mode, and follows with doctor checks.

### Verifying an upgrade: `bin/rig doctor` gates

After any upgrade, `bin/rig doctor` (or `bin/rig doctor --json` for scripting)
runs these current postflight checks:

| Gate | What it verifies | Degrades to "skipped" (not "failed") when |
|---|---|---|
| `worktree_bootstrap` | A linked worktree has the expected stealth artifacts copied from the primary checkout | Not a linked worktree with a primary `.rigpath` |
| `rig_directory` | The resolved Rig directory exists and has a readable `memory/` directory | Never; missing Rig state is a failure |
| `rigpath` | `.rigpath` is a single non-empty line resolving to a usable Rig directory, or local `.rig/` is selected | Never; malformed path state is a failure |
| `stealth_exclusions` | Stealth/external artifacts are excluded from git visibility | Project is not a stealth/external install |
| `settings_json` | Claude settings and Codex hooks JSON files parse correctly | Never; invalid JSON is a failure |
| `claude_commands` | Installed Claude command files match the manifest or at least exist when no manifest baseline is present | Never; missing commands are a failure |
| `codex_skill_parity` | Generated Codex skills mirror Claude commands when Codex skills are installed | Codex mirroring is not enabled |
| `codex_project_instructions` | Codex has an effective `AGENTS*` file or configured `CLAUDE.md` fallback when Codex is an installed target | Codex is not an installed project target |
| `codex_project_target_runtime` | A live Codex runtime has the project target infrastructure it needs | Codex runtime is not detected |
| `codex_session_runtime` | A live Codex thread is bound to an active Rig session record | Codex runtime is not detected |
| `issue_tracking` | `CLAUDE.md` has at most one supported `issue-tracking:` value | Never; unsupported tracker configuration is a failure |
| `github_auth` | GitHub authentication is available when `issue-tracking: github` | A non-GitHub tracker is configured |
| `tracker_command_guidance` | `/task` and `/ship` guidance covers the configured tracker | Never; stale command guidance is a failure |
| `recent_commit_references` | Recent commits follow the configured tracker reference convention | Tracker is `none` or there are no commits to inspect |
| `recent_pr_references` | Recent GitHub PRs contain issue references or close keywords | Non-GitHub tracker, non-GitHub remote, or unavailable GitHub auth |
| `connector_declarations` | Optional connector dependency declarations have the expected public envelope | No connector declaration file exists |
| `template_placeholder_content` | Core project docs are not still showing raw scaffold placeholder content | Never; placeholder content is an advisory failure |
| `manifest_provenance` | Every `.rig-manifest.json` entry's `owner`/`source`/`generator`/`provider`/`type` value is within its known vocabulary | No manifest metadata file exists, or `installer/validate-manifest-provenance.py` isn't colocated (only true for a Rig-dogfooding checkout, not an ordinary downstream install) |
| `stealth_status` | No Rig-generated artifact is tracked by git or visible-and-unignored in a stealth/external install | The project isn't a stealth/external install, or `installer/audit-stealth.py` isn't colocated |
| `manifest_mode_hash` | Every Rig-owned artifact's file mode and content hash still match what the manifest recorded (catches hand-edits outside the installer) | No manifest metadata file exists |
| `stale_manifest_entries` | No manifest entry points at a path that no longer exists on disk | No manifest metadata file exists |
| `idempotence` | Not verified live by `doctor` itself (a read-only command has no safe way to mutate and roll back a real project tree) — always reports the documented procedure: run `bats tests/test_install_idempotence.bats` | Never fails on its own; it's a pointer to the real check, not a live result |
| `upgrade_pattern_blanked_file` | `CLAUDE.md`/`PROJECT_BRIEF.md` didn't revert to raw, unsubstituted template content (i.e. reintroduce the `[Project Name]` placeholder) since the last pre-flight snapshot — the signature of lessons-learned #14 | No pre-flight snapshot exists yet (issue #472 hasn't taken one — e.g. no upgrade-family run has happened on this project since the check shipped) |
| `upgrade_pattern_symlink_replaced` | No path that was a symlink in the last pre-flight snapshot now exists as a regular file — the signature of a symlink-refusal guard being bypassed (lessons-learned #15) | No pre-flight snapshot exists yet |

Both new gates diff the most recent pre-flight snapshot (issue #472,
`.rig-backup/preflight-snapshots/` for tracked installs or the external
`.rig/`'s own `preflight-snapshots/` for stealth/external) against current
state. They cover exactly 2 of the incidents in `docs/lessons-learned.md` —
deliberately: the rest are process/environment lessons (worktree confusion,
hook mistiming, Docker volume shadowing) with no file-content signature an
automated diff can check.

`installer/validate-manifest-provenance.py` and `installer/audit-stealth.py`
are release-engineering tools that live in The Rig's own source repo — they
are never installed into a downstream target project. In an ordinary
downstream install, `manifest_provenance` and `stealth_status` will therefore
permanently report "skipped" with an explanatory detail string; that is
expected steady state, not a gap you need to fix.

### Repairing common post-upgrade findings

**`rig doctor` reports a stealth `tracked_leak` or `untracked_leak`.**
Run `python3 installer/audit-stealth.py <target>` for the read-only
classification, then `python3 installer/repair-stealth.py <target>` to append
any missing pattern to `.git/info/exclude` for artifacts it classified as a
leak. `repair-stealth.py` is **additive only**: it never rewrites or removes
an existing exclude line, never touches the git index, and never untracks a
file. A `tracked_leak` — a Rig-generated file that was actually `git add`-ed
and committed — is reported by the repair tool's `still_tracked` list but is
**not** fixed automatically; adding an exclude pattern has no effect on a
path git already tracks. Untrack it explicitly and deliberately
(`git rm --cached <path>`, review the diff, then commit) rather than expecting
any Rig tooling to do that for you.

**`rig doctor` reports a stale manifest entry as `wrong-type`,
`dangling-symlink`, or `unexpected-symlink`.** These three categories are
never auto-repaired, including by `--repair-stale` — only a genuinely
`missing` entry (the tracked path no longer exists at all) is safe to drop
from the manifest automatically, because removing that entry doesn't touch
the filesystem. The other three mean something unexpected is sitting at a
path the manifest expected to be a plain file or directory — for example a
tracked path that became a symlink, or a symlink whose target vanished.
Inspect the path by hand, decide whether it's a real customization or
accidental drift, and either restore the expected artifact type or update the
manifest entry to match reality before re-running the upgrade.

**`agent-upgrade` (or `agent-plan`) exits `3` with `status: "refused"`.**
This means the run applied every safe/convergeable action it could (file
creation, unmodified-file updates, `settings.json` smart-merge, and any
conflict-free structure-aware merge) but left at least one artifact
untouched — check the `conflicts[]` array in the JSON output for the exact
`path`, `reason`, and `repair_guidance` per file. You have two ways forward:
resolve the conflict manually (edit the file to reconcile your customization
with the incoming change, or restore it from `.rig-backup/` and re-run to
accept the incoming template), or explicitly re-run with a strategy that
accepts the incoming version for that file (interactive `--strategy upgrade`,
which will prompt you per file). Never treat a `refused` result as a
transient failure to retry unchanged — re-running `agent-upgrade` against the
same unresolved conflict will refuse again, by design.
