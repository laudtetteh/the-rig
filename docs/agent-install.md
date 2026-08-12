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
| `--tracking` | `repo` \| `local` \| `external` \| `stealth` | How `.rig/` is tracked in git |
| `--strategy` | `merge` \| `upgrade` \| `overwrite` \| `skip` \| `interactive` \| `agent-plan` \| `agent-upgrade` | How to handle existing files |
| `--rig-dir <path>` | absolute path | Where to put `.rig/` when using external or stealth tracking |
| `--project-name <name>` | string | Project name substituted into templates |
| `--skip-git-hooks` | — | Skip writing to `.git/hooks/` (stealth + existing Husky setup) |

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
| `agent-plan` | Zero writes; emits a JSON preview of what `upgrade` would do; exits `3` if any file needs manual review | Agent/script preflight before applying an upgrade |
| `agent-upgrade` | Applies the same safe convergence as `upgrade`; emits a JSON result; exits `3` if any file was left for manual review | Agent/script-driven guarded upgrade with a machine-readable result |

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
# Then fill in the personal profile:
$EDITOR ~/.your-ai-contexts/PROFILE.md
```

The Claude global layer installs `~/.claude/CLAUDE.md` and `~/.claude/skills/`.
Codex personal skills are generated under `~/.agents/skills/`; selecting both
agents installs both delivery surfaces while project workflows remain shared
across all projects on the machine. Run this once per machine, not per project.

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

# 3. Fill in your personal profile
$EDITOR ~/.your-ai-contexts/PROFILE.md

# 4. Clone your project
git clone <project-url> ~/code/my-project

# 5. Re-run the project installer (wires hooks, restores local files)
./install.sh \
  --project-only \
  --target ~/code/my-project \
  --tracking repo \
  --strategy merge
```

If the project uses stealth or external tracking, use the same `--tracking` and
`--rig-dir` values as the original install. The `.rigpath` file in the project root
records the external `.rig/` path — read it to know where `.rig/` should be.

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

# 1. Read-only preview — zero writes, prints one JSON document, exits 3 if
#    anything would need manual review.
./install.sh --project-only --target /path/to/project --strategy agent-plan

# 2. If the plan's "status" is "success", apply the same convergence and get
#    a JSON result back.
./install.sh --project-only --target /path/to/project --strategy agent-upgrade
```

Both commands exit `0` with `"status": "success"` when nothing needs manual
review, and exit `3` with `"status": "refused"` when at least one artifact is
customized or conflicting. On exit `3`, read the JSON's `conflicts[]` array —
each entry has `path`, `reason`, and `repair_guidance` — and present those
fields verbatim to the user rather than inventing guidance text. Full JSON
schema, exit-code table, and classification semantics:
`.rig/processes/UPGRADE_WORKFLOW.md`'s "Agent-driven upgrade contract" section.

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
# Hooks are executable
ls -la /path/to/project/.claude/hooks/
ls -la /path/to/project/.husky/

# settings.json wired
cat /path/to/project/.claude/settings.json | grep pre-tool

# Focused installer smoke test from the Rig repo
bash -n install.sh
bats tests/test_install_a.bats
```

For stealth/external installs, also confirm:
```bash
# .rigpath exists and points to the right place
cat /path/to/project/.rigpath

# No Rig traces in git status
git -C /path/to/project status
```
