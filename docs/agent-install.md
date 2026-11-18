# Agent install guide

> The Rig installs compatibility layers for both Claude Code and Codex. Paths named `CLAUDE.md` or `.claude` are Claude-native surfaces; Codex receives the corresponding configured/generated adapter.

How to install The Rig non-interactively — exact flag combinations for every scenario.

Use this when Claude Code or Codex is helping a user install or upgrade The Rig.
The installer is interactive by default; the flags below bypass all prompts.

---

## Installer flags reference

| Flag | Values | What it does |
|---|---|---|
| `--global-only` | — | Install only the global layer (`~/.claude/`) |
| `--project-only` | — | Install only the project layer (target repo) |
| `--global-agent` | `claude` \| `codex` \| `both` \| `none` | Select global integrations independently |
| `--project-agent` | `claude` \| `codex` \| `both` \| `none` | Select project integrations independently |
| `--preflight` | — | Validate the resolved matrix and prerequisites without writing |
| `--json` | — | With `--preflight`, emit schema-versioned JSON only |
| `--target <path>` | absolute path | Project directory to install into |
| `--base-branch <name>` | branch name | Substitute the project's base branch into templates |
| `--tracking` | `repo` \| `local` \| `external` \| `stealth` | How `.rig/` is tracked in git |
| `--strategy` | `merge` \| `upgrade` \| `overwrite` \| `skip` \| `interactive` \| `agent-plan` \| `agent-upgrade` | How to handle existing files |
| `--rig-dir <path>` | absolute path | Where to put `.rig/` when using external or stealth tracking |
| `--project-name <name>` | string | Project name substituted into templates |
| `--skip-git-hooks` | — | Skip writing to `.git/hooks/` (stealth + existing Husky setup); without an active Rig `commit-msg` hook, visible guarded agent commits use the limited PreToolUse approval gate |
| `--recover` | — | Restore an interrupted transaction without applying a new version |
| `--repair-stale` | — | Repair stale Rig-owned manifest entries when the on-disk file still matches the running template |
| `--feature-docs` | — | Install optional feature documentation helpers |
| `--subagents` | — | Install optional subagent hook support |
| `--contribute` | — | Enable opt-in contribution helpers |
| `--notifications` | — | Install optional notification support |

**Tracking modes:**

| Mode | `.rig/` location | git visibility |
|---|---|---|
| `repo` | Inside the project repo, committed | Visible to all contributors |
| `local` | Inside the project repo, gitignored | Local only |
| `external` | Outside the repo (explicit `--rig-dir`) | Invisible; `.rigpath` file points to it |
| `stealth` | Outside the repo (`~/.rig/projects/<name>/` default) | Zero traces in git |

**Strategy modes:**

| Strategy | Existing files | When to use |
|---|---|---|
| `merge` | Creates missing files, skips existing | Fresh install on a new project |
| `upgrade` | Updates Rig-owned files if unchanged; detects customizations | Upgrading an existing install |
| `overwrite` | Replaces all Rig-owned files unconditionally | Repair/reset |
| `skip` | Never overwrites anything | Safe read-only test |
| `interactive` | Asks per file (Custom path only) | Human-supervised, file-by-file review |
| `agent-plan` | Zero writes; emits a JSON preview of upgrade classification and guarded convergence; exits `3` if any file needs manual review | Agent/script preflight before applying an upgrade |
| `agent-upgrade` | Applies safe updates plus guarded convergence for customized Rig-owned files; emits a JSON result; exits `3` if any file was left for manual review | Agent/script-driven guarded upgrade with a machine-readable result |

`agent-plan` and `agent-upgrade` are non-interactive-only: they are accepted by
`--strategy` but never offered in the interactive "What are you doing?" menu, so
a human user can never land in agent mode by accident.

If agent selectors are omitted, fresh installs retain the historical Claude-only
default. Upgrades reuse the last successful selection from
`~/.rig/install-targets.json` and the resolved project `.rig/install-targets.json`.
Explicit selectors take precedence. Selecting `none` or deselecting an agent never
removes files from an earlier install.
When every enabled layer explicitly resolves to `none`, the command is a verified
no-op: it reports the matrix and writes neither destination files nor target metadata.

When the project target includes Codex, the installer preserves `CLAUDE.md` as the
single project-brain source and adds it to Codex's
`project_doc_fallback_filenames` in `.codex/config.toml`. Existing fallback names
and unrelated Codex settings are preserved. Codex's native `AGENTS.override.md`
and `AGENTS.md` files take precedence over configured fallback names; the installer
does not replace, rename, or remove either file.

Run a read-only machine check before automation:

```bash
./install.sh --project-only --project-agent both --target /path/to/project \
  --strategy upgrade --preflight --json
```

Exit 0 means required checks passed (optional features may still be degraded),
exit 1 means a prerequisite failed, and exit 2 means the invocation or metadata
schema is invalid. The installer never installs external dependencies itself.
The same preflight evaluation runs automatically before every normal install and
aborts before the first destination write when a required prerequisite is missing.

---

## Scenario commands

### 1 — First-time global install (once per machine)

```bash
cd ~/tools/the-rig
./install.sh --global-only --strategy merge
# Then fill in the "## Personal context" section of the global brain:
$EDITOR ~/.claude/CLAUDE.md
```

The Claude global layer installs `~/.claude/CLAUDE.md`,
`~/.claude/skills/`, and the global bootstrap command at
`~/.claude/commands/rig-upgrade.md`. Codex personal skills are generated under
`~/.agents/skills/`, including the matching `$rig-upgrade` bootstrap skill;
selecting both agents installs both delivery surfaces while project workflows
remain shared across all projects on the machine. Run this once per machine,
not per project.

---

### 2 — New project (committed `.rig/`)

For solo projects where The Rig files are committed to the repo:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking repo \
  --strategy merge \
  --project-name "MyProject"
```

---

### 3 — New project (local `.rig/`, gitignored)

For shared repos where you want `.rig/` on disk but invisible to git:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking local \
  --strategy merge \
  --project-name "MyProject"
```

---

### 4 — New project (stealth — zero git traces)

For shared repos where teammates must never see any Rig files:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking stealth \
  --strategy merge \
  --project-name "MyProject"
```

`.rig/` goes to `~/.rig/projects/MyProject/` by default. Use `--rig-dir` to override:

```bash
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking stealth \
  --rig-dir ~/.rig/projects/custom-name \
  --strategy merge \
  --project-name "MyProject"
```

---

### 5 — New project (external directory)

For repos where `.rig/` lives outside but isn't fully hidden:

```bash
cd ~/tools/the-rig
./install.sh \
  --project-only \
  --target /path/to/project \
  --tracking external \
  --rig-dir ~/.rig/projects/my-project \
  --strategy merge \
  --project-name "MyProject"
```

---

### 6 — Upgrade existing install

Pull the latest Rig source, then upgrade the project layer:

```bash
cd ~/tools/the-rig
git pull

./install.sh \
  --project-only \
  --target /path/to/project \
  --strategy upgrade
```

The upgrade strategy auto-updates Rig-owned files (hooks, commands, processes) when
unchanged, detects customizations and prompts, and always skips user-owned files
(`CLAUDE.md`, `rules/`, `memory/`, `.github/`).

---

### 7 — New machine setup

When re-cloning a project that already has The Rig installed:

```bash
# 1. Clone The Rig to a permanent location
git clone https://github.com/laudtetteh/the-rig.git ~/tools/the-rig

# 2. Install the global layer
cd ~/tools/the-rig
./install.sh --global-only --strategy merge

# 3. Fill in the "## Personal context" section of the global brain
$EDITOR ~/.claude/CLAUDE.md

# 4. Clone your project
git clone <project-url> ~/code/my-project

# 5. Re-run the project installer (wires hooks, restores local files).
#    Use the tracking mode the project was originally installed with.
./install.sh \
  --project-only \
  --target ~/code/my-project \
  --tracking <repo|local|external|stealth> \
  --strategy merge
```

Pick `--tracking` to match the original install — a fresh clone cannot tell you:

- **repo** — `.rig/` is committed, so it arrives with the clone.
- **local** — `.rig/` was excluded from git and does not arrive with the clone;
  restore it from a backup or re-create it with this command.
- **stealth** or **external** — the Rig directory lives outside the repo, and
  `.rigpath` is excluded through `.git/info/exclude`, so neither the directory
  nor `.rigpath` exists in a fresh clone. Restore the Rig directory from a
  backup, sync, or the old machine (stealth defaults to
  `~/.rig/projects/<project-name>/`), then pass `--rig-dir <that path>` (and the
  original `--project-name` for stealth) so the installer writes a new
  `.rigpath` pointing at it. External tracking always needs `--rig-dir`. On the
  old machine, `cat <project>/.rigpath` shows the path that was in use.

---

### 8 — Both layers at once (fresh machine, fresh project)

```bash
cd ~/tools/the-rig
./install.sh \
  --target /path/to/project \
  --tracking repo \
  --strategy merge \
  --project-name "MyProject"
# (omitting --global-only and --project-only runs both layers)
```

---

### 9 — Agent-driven guarded upgrade

For a calling agent or script that needs a machine-readable preview before
applying an upgrade, run `agent-plan` first, inspect the JSON, then run
`agent-upgrade`:

```bash
cd ~/tools/the-rig
git pull

# 1. Read-only preview — zero writes and no upgrade report, prints one JSON
#    document, exits 3 if anything would need manual review.
./install.sh --project-only --target /path/to/project --strategy agent-plan

# 2. If the plan's "status" is "success", apply safe updates plus guarded
#    convergence and get a JSON result back. When a durable report is written,
#    the result includes report_path and rollback_id.
./install.sh --project-only --target /path/to/project --strategy agent-upgrade
```

Both commands exit `0` with `"status": "success"` when nothing needs manual
review, and exit `3` with `"status": "refused"` when at least one artifact is
customized or conflicting. On exit `3`, read the JSON's `conflicts[]` array —
each entry has `path`, `reason`, and `repair_guidance` — and present those
fields verbatim to the user rather than inventing guidance text. Full JSON
schema, exit-code table, and classification semantics:
`.rig/processes/UPGRADE_WORKFLOW.md`'s "Agent-driven upgrade contract" section.

When `agent-upgrade` writes a durable report, scripted callers should read
`report_path` and `rollback_id` from the JSON result. The rollback id is the
confirmation token for `bin/rig upgrade rollback --id <id> --dry-run` followed
by `bin/rig upgrade rollback --id <id> --confirm <id>`.

A manifest entry whose `base_revision` claims an installer version newer
than the one currently running is treated the same way as any other
unresolved finding: both commands refuse (exit `3`) with repair guidance,
rather than silently trusting a future or bogus revision claim.

---

## Agent-guided install selection

The downstream `/rig-install` and `$rig-install` command adapters were retired.
Use this document directly when an agent needs guided install selection: collect
the target project path, tracking mode, agent target, and strategy, then emit the
exact `install.sh` command for review before running it.

---

## Post-install checklist

After any install, verify:

```bash
# Claude hooks are executable
ls -la /path/to/project/.claude/hooks/

# Git hooks are executable — repo, local, or external tracking
ls -la /path/to/project/.husky/
# Git hooks are executable — stealth tracking (no .husky/ is written)
ls -la /path/to/project/.git/hooks/pre-commit /path/to/project/.git/hooks/commit-msg \
  /path/to/project/.git/hooks/post-commit /path/to/project/.git/hooks/post-merge

# settings.json wired
cat /path/to/project/.claude/settings.json | grep pre-tool

# Provider-neutral health check from inside the project
cd /path/to/project && bin/rig doctor --json
```

Skip the Git hook checks when the install used `--skip-git-hooks` or declined
Git hooks. Claude `/rig-status` or Codex `$rig-status` gives the same check as a
readable report.

For stealth/external installs, also confirm:
```bash
# .rigpath exists and points to the right place
cat /path/to/project/.rigpath

# No Rig traces in git status
git -C /path/to/project status
```
