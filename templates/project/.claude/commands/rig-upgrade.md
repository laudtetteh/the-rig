# Command: /rig-upgrade

Upgrades The Rig in this project to the latest version available in the installer source.

Handles all known upgrade scenarios: repo, external, and stealth tracking; user-modified
files; global layer; VERSION staleness; and settings.json deduplication. Each phase is
gated — survey before touching anything, confirm before committing.

> **RIG_DIR resolution (stealth/external mode):** Resolve `.rig/` before every step.
>
> ```bash
> REPO=$(git rev-parse --show-toplevel)
> if [[ -f "$REPO/.rigpath" ]]; then
>   RIG_DIR=$(tr -d '[:space:]' < "$REPO/.rigpath")
> else
>   RIG_DIR="$REPO/.rig"
> fi
> ```

---

## Flags

```
/rig-upgrade                  # default: upgrade project layer, then offer global layer
/rig-upgrade --version        # print versions only — no upgrade triggered
/rig-upgrade --scope=project  # upgrade project layer only (skip Phase 4 global)
/rig-upgrade --scope=global   # upgrade global layer only (skip Phases 1–3 project)
/rig-upgrade --scope=both     # upgrade both layers without prompting (same as default but explicit)
/rig-upgrade --mode=agent     # skip the Phase 2 mode prompt: force guarded convergence (install.sh --strategy agent-upgrade)
/rig-upgrade --mode=classic   # skip the Phase 2 mode prompt: force the conservative installer (install.sh --strategy upgrade)
```

Before invoking the installer, resolve and confirm agent targets independently
for every selected layer. Accepted values are `claude`, `codex`, `both`, and
`none`; pass them as `--global-agent VALUE` and `--project-agent VALUE`.
When the user does not request a change, omit the selector so the installer can
reuse its versioned install-target metadata. Never delete integration files when
an agent is deselected. For agent-driven/noninteractive execution, ask the user
for any unresolved choice before invoking the installer, then run the same
command through `--preflight --json` and stop on a nonzero result.

### `--version` flag (early exit)

If the user passes `--version`, skip all phases and print version info only:

```bash
# Project installed version
PROJECT_VERSION=$(cat "$RIG_DIR/VERSION" 2>/dev/null || echo "not installed")
PROJECT_TS=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$RIG_DIR/VERSION" 2>/dev/null \
  || stat -c "%y" "$RIG_DIR/VERSION" 2>/dev/null | cut -d' ' -f1-2 | cut -c1-16 \
  || echo "unknown")

# Global installer version
GLOBAL_INSTALLER=~/tools/the-rig
GLOBAL_VERSION=$(cat "$GLOBAL_INSTALLER/VERSION" 2>/dev/null || echo "not found")
GLOBAL_TS=$(stat -f "%Sm" -t "%Y-%m-%d %H:%M" "$GLOBAL_INSTALLER/VERSION" 2>/dev/null \
  || stat -c "%y" "$GLOBAL_INSTALLER/VERSION" 2>/dev/null | cut -d' ' -f1-2 | cut -c1-16 \
  || echo "unknown")

# Latest GitHub release (requires gh CLI; graceful fallback if unavailable)
GITHUB_VERSION=""
GITHUB_DATE=""
if command -v gh >/dev/null 2>&1; then
  _gh_json=$(gh release view --repo laudtetteh/the-rig --json tagName,publishedAt 2>/dev/null || true)
  if [[ -n "$_gh_json" ]]; then
    GITHUB_VERSION=$(echo "$_gh_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['tagName'])" 2>/dev/null || true)
    GITHUB_DATE=$(echo "$_gh_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['publishedAt'][:10])" 2>/dev/null || true)
  fi
fi

# Installed agent target metadata (agent support, not just VERSION files)
PROJECT_TARGETS_FILE="$RIG_DIR/install-targets.json"
PROJECT_AGENTS=$(python3 - "$PROJECT_TARGETS_FILE" <<'PY' 2>/dev/null || echo "unknown"
import json, sys
with open(sys.argv[1]) as fh:
    print(",".join(json.load(fh).get("agents", [])) or "none")
PY
)
GLOBAL_TARGETS_FILE="$HOME/.rig/install-targets.json"
GLOBAL_AGENTS=$(python3 - "$GLOBAL_TARGETS_FILE" <<'PY' 2>/dev/null || echo "unknown"
import json, sys
with open(sys.argv[1]) as fh:
    print(",".join(json.load(fh).get("agents", [])) or "none")
PY
)

CODEX_INFRA_STATUS="not selected"
if [[ ",$PROJECT_AGENTS," == *",codex,"* ]]; then
  missing_codex=()
  [[ -f "$REPO/.codex/hooks.json" ]] || missing_codex+=(".codex/hooks.json")
  [[ -x "$REPO/.codex/hooks/rig-adapter.sh" ]] || missing_codex+=(".codex/hooks/rig-adapter.sh executable")
  [[ -f "$REPO/.codex/config.toml" ]] || missing_codex+=(".codex/config.toml")
  [[ -d "$REPO/.agents/skills" ]] || missing_codex+=(".agents/skills")
  if [[ "${#missing_codex[@]}" -eq 0 ]]; then
    CODEX_INFRA_STATUS="complete"
  else
    CODEX_INFRA_STATUS="missing: ${missing_codex[*]}"
  fi
fi
```

Output:

> ```
> Rig version info
> ─────────────────────────────────────────
> Project (.rig/VERSION):         1.16.0   (last modified: 2026-05-18 11:41)
> Global installer (~/tools/):    1.16.0   (last modified: 2026-05-18 10:52)
> Latest GitHub release:          v1.16.0  (published: 2026-05-18)
> Project agent targets:          claude,codex
> Global agent targets:           claude
> Codex project infrastructure:   complete
> ```

If `GITHUB_VERSION` is empty (gh not available or network failed), print instead:
> ```
> Latest GitHub release:          (unavailable — gh not found or no network)
> ```

After printing the version and target lines, apply these checks in order:

1. If project and global versions differ:
   > "⚠️ Project is at `$PROJECT_VERSION` but global installer is at `$GLOBAL_VERSION`. Run `/rig-upgrade` to sync."

2. If a GitHub version was retrieved and it differs from `$GLOBAL_VERSION`
   (compare after stripping a leading `v` from `$GITHUB_VERSION`):
   > "⚠️ Stable installer source is at `$GLOBAL_VERSION` but latest release is `$GITHUB_VERSION`.
   > Update it with: `git -C ~/tools/the-rig checkout main && git -C ~/tools/the-rig pull --ff-only origin main`
   > Then re-run `/rig-upgrade --version`."

3. If a GitHub version was retrieved and it differs from `$PROJECT_VERSION`
   (compare after stripping a leading `v` from `$GITHUB_VERSION`):
   > "⚠️ A newer release is available: `$GITHUB_VERSION`. Pull `~/tools/the-rig` and run `/rig-upgrade`."

4. If `CODEX_THREAD_ID` is set and `$PROJECT_AGENTS` does not include `codex`:
   > "⚠️ This is a Codex session, but the project target metadata is `$PROJECT_AGENTS`.
   > Run `/rig-upgrade --scope=project --mode=agent` or install with `--project-agent both` to retrofit Codex project support."

5. If `CODEX_THREAD_ID` is set and `$CODEX_INFRA_STATUS` is not `complete`:
   > "⚠️ Codex project support is incomplete: `$CODEX_INFRA_STATUS`.
   > Run `/rig-upgrade --scope=project --mode=agent`, then verify with `bin/rig doctor --json`."

6. If `CODEX_THREAD_ID` is set and `bin/rig session resolve --json` reports `reason: not_found`:
   > "⚠️ Current Codex thread is not bound to Rig session memory.
   > After the project target is converged, run: `bin/rig session retrofit --agent codex --from-env --source resume --json`."

7. If all versions and target surfaces are in sync: say nothing extra.

Then stop — do not proceed to Phase 0.

### `--scope` flag

Read the scope flag before Phase 0. Default is `both` (current behavior).

- `--scope=project`: set `SKIP_GLOBAL=true`. Phase 4 is skipped entirely.
- `--scope=global`: set `SKIP_PROJECT=true`. Phases 1, 2, and 3 are skipped entirely. Jump directly to Phase 4.
- `--scope=both`: normal flow (no skip).

These flags do not suppress the Phase 0 session state check — always run 0a first.

### `--mode` flag

Read the mode flag before Phase 0. It selects how Phase 2 (2-mode below) applies
the project-layer upgrade, and short-circuits the interactive mode prompt in
2-mode when present.

- `--mode=agent`: set `UPGRADE_MODE=agent` — Phase 2 runs `install.sh --strategy
  agent-upgrade` (guarded convergence).
- `--mode=classic`: set `UPGRADE_MODE=classic` — Phase 2 runs `install.sh
  --strategy upgrade` (the original per-file interactive review flow), unchanged
  from before agent-driven convergence existed.
- Neither flag passed: `UPGRADE_MODE` is unset here; 2-mode asks the user (or
  applies the non-interactive default) once Phase 2 is reached.

`--mode` has no effect when `--scope=global` skips Phase 2 entirely.

---

## Phase 0 — Pre-flight

### 0a — Session state

Check for housekeeping flags before touching anything:

```bash
[[ -f "$RIG_DIR/memory/.wrap-needed" ]] && echo "WRAP NEEDED"
[[ -f "$RIG_DIR/memory/.post-merge-pending" ]] && echo "POST-MERGE NEEDED"
```

- If `.wrap-needed` exists: say "⚠️ A previous session ended without `/wrap`. Run `/wrap`
  first to avoid losing state — or say 'skip wrap' to proceed anyway." Wait for the user.
- If `.post-merge-pending` exists: say "⚠️ A merge landed since last `/post-merge`. Run
  `/post-merge` first — or say 'skip post-merge' to proceed anyway." Wait for the user.
- If neither flag exists: proceed silently.

### 0b — Record current version

```bash
CURRENT_VERSION=$(cat "$RIG_DIR/VERSION" 2>/dev/null || echo "unknown")
echo "Current Rig version: $CURRENT_VERSION"
```

### 0c — Locate installer source

Check in order:

```bash
# 1. Standard stable installer location
if [[ -f ~/tools/the-rig/install.sh ]]; then
  INSTALLER_SRC=~/tools/the-rig

# 2. Explicit env var override
elif [[ -n "$RIG_INSTALLER_SRC" && -f "$RIG_INSTALLER_SRC/install.sh" ]]; then
  INSTALLER_SRC="$RIG_INSTALLER_SRC"

# 3. Dev-repo self-install: the repo itself contains install.sh + templates/
elif [[ -f "$REPO/install.sh" && -d "$REPO/templates/project" ]]; then
  INSTALLER_SRC="$REPO"
  echo "ℹ️  Installer source is this repo itself (dev mode)."

else
  echo "❌ Cannot locate installer source."
  echo "   Expected: ~/tools/the-rig/install.sh"
  echo "   Or set: export RIG_INSTALLER_SRC=/path/to/the-rig"
  # Stop and ask the user to provide the path
fi
```

If no installer is found, stop and tell the user. Do not guess or invent a path.

### 0d — Branch check (non-dev mode only)

If `$INSTALLER_SRC` is NOT `$REPO` (i.e. using an external installer source):

```bash
INSTALLER_BRANCH=$(git -C "$INSTALLER_SRC" branch --show-current 2>/dev/null || echo "")
INSTALLER_VERSION=$(cat "$INSTALLER_SRC/VERSION" 2>/dev/null || echo "unknown")
```

- If `$INSTALLER_BRANCH` is empty (detached HEAD or not a git repo): warn and ask whether
  to continue.
- If `$INSTALLER_BRANCH` is not `main`: say exactly —
  > "⚠️ Installer source is on branch '`$INSTALLER_BRANCH`', not `main`.
  > Upgrading from a non-stable branch may install unreviewed changes.
  > Switch with: `git -C $INSTALLER_SRC checkout main && git pull origin main`
  > Proceed anyway?" 
  Wait for the user's response.
- If `$INSTALLER_BRANCH == main`: proceed.

Report what version will be installed:
> "Upgrading: **$CURRENT_VERSION → $INSTALLER_VERSION**"

### 0e — CLAUDE.md path sanity check

Detect whether `CLAUDE.md` contains paths that belong to a different tracking mode.
This can happen when an upgrade was run with the wrong tracking flag, writing stealth
absolute paths into a repo-tracked project's `CLAUDE.md`.

This check needs to know the tracking mode, but Phase 1c (the phase that
normally computes `$TRACKING`) hasn't run yet at Phase 0e — detect it locally
here instead of assuming a variable set by a later phase:

```bash
CLAUDE_MD="$REPO/CLAUDE.md"
if [[ -f "$CLAUDE_MD" ]]; then
  # Local, self-contained tracking-mode detection (Phase 1c computes the
  # same value later for the rest of the command; duplicated here rather
  # than referenced forward, since Phase 0e always runs first).
  if [[ -f "$REPO/.rigpath" ]]; then
    if [[ -d "$REPO/.husky" ]]; then TRACKING="external"; else TRACKING="stealth"; fi
  else
    TRACKING="repo"
  fi

  # Check for stealth-style absolute paths (e.g. /Users/name/.rig/projects/)
  STEALTH_PATHS=$(grep -E '/\.rig/projects/' "$CLAUDE_MD" 2>/dev/null || true)

  if [[ -n "$STEALTH_PATHS" && "$TRACKING" == "repo" ]]; then
    echo "⚠️  Path mismatch in CLAUDE.md:"
    echo "   CLAUDE.md contains absolute stealth paths but this is a repo-tracked install."
    echo "   These paths point to a directory that likely does not exist:"
    echo "$STEALTH_PATHS" | head -5
    echo ""
    echo "   This causes the agent to fail silently when Bash is unavailable."
    echo "   Options:"
    echo "   [f] Fix — rewrite context-loading and @import paths to use relative .rig/ paths"
    echo "   [s] Skip — leave CLAUDE.md unchanged (mismatch persists)"
  fi
fi
```

If user chooses **[f]**: make the following substitutions in `$CLAUDE_MD`:

1. Replace the numbered context-loading list (lines starting with `1.`, `2.`, etc. that
   reference an absolute `.rig/projects/*/memory/` path) with relative equivalents:
   - `/Users/*/memory/CONTEXT_SNAPSHOT.md` → `.rig/memory/CONTEXT_SNAPSHOT.md`
   - `/Users/*/memory/PROGRESS.md` → `.rig/memory/PROGRESS.md`
   - `/Users/*/memory/ERRORS.md` → `.rig/memory/ERRORS.md`
   - `/Users/*/memory/DECISIONS.md` → `.rig/memory/DECISIONS.md`
   - `/Users/*/tasks/active/` → `.rig/tasks/active/`
2. Replace `@/Users/*/rules/*.md` imports with `@.rig/rules/*.md`
3. Replace the "External .rig/ note" block with the hook-enforced context note from the
   current template.

Then confirm: "CLAUDE.md paths corrected to relative `.rig/` references."

If user chooses **[s]**: note the skip and continue.

If CLAUDE.md does not exist, or tracking is not `repo`, or no stealth paths found: skip silently.

---

## Phase 1 — Pull + Survey (read-only)

> **Scope gate:** If `SKIP_PROJECT=true` (from `--scope=global`), skip Phases 1, 2,
> and 3 entirely. Jump to Phase 4.

### 1a — Pull installer source to latest

If `$INSTALLER_SRC` is NOT `$REPO`:

```bash
git -C "$INSTALLER_SRC" pull origin main 2>&1
INSTALLER_VERSION=$(cat "$INSTALLER_SRC/VERSION" 2>/dev/null || echo "unknown")
echo "Installer now at: $INSTALLER_VERSION"
```

If `$INSTALLER_SRC` IS `$REPO`: skip — dev repo is already on the correct state.

### 1b — Breaking-change gate

Read `$INSTALLER_SRC/CHANGELOG.md` and extract all `### Changed — BREAKING` bullets
from sections newer than `$CURRENT_VERSION` (i.e., above the `## [$CURRENT_VERSION]`
header in the file). Sections are in descending order; stop collecting at
`## [$CURRENT_VERSION]`.

```bash
CHANGELOG="$INSTALLER_SRC/CHANGELOG.md"
```

If `$CHANGELOG` does not exist or `$CURRENT_VERSION` is `"unknown"`: skip silently and
continue to 1c.

Otherwise, collect the breaking-change bullets. If **no breaking changes** exist in
the range: say briefly —
> "No breaking changes since v$CURRENT_VERSION. Proceeding."

If **breaking changes exist**: display them in full, then say —
> "⚠️ Breaking changes since v$CURRENT_VERSION:
>
> [list of bullets, verbatim from CHANGELOG]
>
> Review the above before proceeding. Type **go** to continue the upgrade, or
> **cancel** to abort. No files will be modified until you confirm."

Wait for the user's response. If they say **cancel** (or anything other than
**go** / **yes** / **proceed** / **continue**): say "Upgrade cancelled. No files
were modified." and stop. Do not proceed to 1c.

### 1c — Detect tracking mode and key paths

```bash
# Tracking mode
if [[ -f "$REPO/.rigpath" ]]; then
  if [[ -d "$REPO/.husky" ]]; then
    TRACKING="external"
    HOOKS_DIR="$REPO/.husky"
  else
    TRACKING="stealth"
    HOOKS_DIR="$REPO/.git/hooks"
  fi
else
  TRACKING="repo"
  HOOKS_DIR="$REPO/.husky"
fi

TEMPLATES="$INSTALLER_SRC/templates/project"
BASE_BRANCH=$(grep "^base-branch:" "$REPO/CLAUDE.md" 2>/dev/null | awk '{print $2}' | tr -d '[:space:]')
BASE_BRANCH="${BASE_BRANCH:-main}"
```

### 1c-bis — Structured plan via `install.sh --strategy agent-plan`

As of #444 lane 444-A, `install.sh` accepts `--strategy agent-plan`: a
read-only, non-interactive invocation that runs the exact same artifact
discovery/classification as `--strategy upgrade`, performs zero writes to the
target, and emits one JSON document on stdout describing every discovered
artifact and its classification/action/reason. This is available as a
structured, machine-readable alternative (or supplement) to the manual
per-file `_diff_tpl` survey in 1d/1e below — it can shortcut or cross-check
that survey for the file families install.sh itself tracks (everything
counted in the installer's `UPGRADE_*_COUNT` bookkeeping).

```bash
AGENT_PLAN_JSON=$(bash "$INSTALLER_SRC/install.sh" --project-only \
  --target "$REPO" --tracking "$TRACKING" --strategy agent-plan)
AGENT_PLAN_STATUS=$?
```

`$AGENT_PLAN_STATUS` is `0` when `status` is `"success"` (no file needs manual
review) and `3` when `status` is `"refused"` (at least one customized or
conflicting file needs manual review — see the `conflicts` array in the JSON
for `path`/`reason`/`repair_guidance` per file). A dedicated exit code other
than `0`/`3` means a genuine fatal error unrelated to conflicts (e.g. a
missing target). Full schema and example documents are in
`$RIG_DIR/processes/UPGRADE_WORKFLOW.md`.

**Scope note — what this command actually wires today.** This survey step
(1c-bis) always runs `agent-plan` as a read-only preview, regardless of which
mode Phase 2 ends up using. What Phase 2 does with that preview depends on
`UPGRADE_MODE` (see 2-mode below):

- `UPGRADE_MODE=agent` (the recommended, and non-interactive default, mode):
  Phase 2 invokes `install.sh --strategy agent-upgrade` — the real guarded
  convergence engine, including issue #444 lane 444-C's structure-aware/
  three-way merge for customized files with a known format. Phase 2b presents
  the JSON `status`/`conflicts[]` result directly; it does not re-ask the
  user to decide anything the engine already resolved. Phase 3 invokes
  `bin/rig doctor --json` and surfaces any gate failure before the command
  declares completion.
- `UPGRADE_MODE=classic`: Phase 2 invokes `install.sh --strategy upgrade` —
  the original conservative, choice-driven installer run, with the original
  manual `[a]ccept template` / `[k]eep yours` / `[s]how full file` decision
  per customized file in Phase 2b. This path is unchanged from before agent
  mode existed and remains available on request.

Both modes still route through the exact same artifact discovery/
classification code path in `install.sh` — `agent-upgrade` differs from
`upgrade` only in how it reports and gates on the result (single JSON
document, dedicated exit code `3` for "needs manual review"), not in what it
is willing to touch automatically. See `UPGRADE_WORKFLOW.md` → "Agent-driven
upgrade contract" for the full JSON schema and exit-code table.

### 1d — Survey changed files

For each key Rig-owned file, compare the installed version to the template.
Where the template uses `[BASE_BRANCH]`, substitute `$BASE_BRANCH` before diffing.

```bash
_diff_tpl() {
  local rel="$1" tpl_path="$2" installed_path="$3"
  if [[ ! -f "$tpl_path" ]]; then echo "NO_TEMPLATE: $rel"; return; fi
  if [[ ! -f "$installed_path" ]]; then echo "MISSING:     $rel"; return; fi
  local tmp; tmp=$(mktemp)
  sed "s/\[BASE_BRANCH\]/${BASE_BRANCH}/g; s|\[REPO_ROOT\]|${REPO}|g" "$tpl_path" > "$tmp"
  if diff -q "$installed_path" "$tmp" >/dev/null 2>&1; then
    echo "up-to-date:  $rel"
  else
    echo "CHANGED:     $rel"
  fi
  rm -f "$tmp"
}
```

Survey these files (adjust paths based on `$TRACKING`):

**Claude hooks** — iterate the template directory so new hooks are never missed.
`subagent-start.sh` is opt-in (`--subagents`, or automatic when Codex is a
selected agent) — it is never installed by default, so treat a missing copy
of it as expected, not a real gap. Detect whether it was actually opted into
by checking whether it's already wired into `.claude/settings.json`'s
`SubagentStart` hook or referenced in `CLAUDE.md`, matching how install.sh's
own `agent-plan`/`agent-upgrade` classify it (see install.sh's
`INSTALL_SUBAGENTS` gate). This reconciles Phase 1d's own survey with Phase
1c-bis's `agent-plan` output, which already omits this file correctly when
not opted into — without this check, Phase 1d's raw survey would report a
false `MISSING` that agent-plan doesn't:
```bash
echo "=== Surveying Claude hooks ==="
for tpl in "$TEMPLATES/.claude/hooks/"*.sh; do
  [[ -f "$tpl" ]] || continue
  f=$(basename "$tpl")
  if [[ "$f" == "subagent-start.sh" && ! -f "$REPO/.claude/hooks/$f" ]]; then
    if grep -Fq '"SubagentStart"' "$REPO/.claude/settings.json" 2>/dev/null || \
       grep -Fq 'subagent-start.sh' "$REPO/CLAUDE.md" 2>/dev/null; then
      : # was opted into but the hook file itself is missing -- a real gap, fall through
    else
      echo "skip (opt-in, not installed): .claude/hooks/$f"
      continue
    fi
  fi
  _diff_tpl ".claude/hooks/$f" "$tpl" "$REPO/.claude/hooks/$f"
done
```

**Claude commands** — iterate the template directory:
```bash
echo "=== Surveying Claude commands ==="
for tpl in "$TEMPLATES/.claude/commands/"*.md; do
  [[ -f "$tpl" ]] || continue
  f=$(basename "$tpl")
  _diff_tpl ".claude/commands/$f" "$tpl" "$REPO/.claude/commands/$f"
done
```

**Git hooks** (location depends on tracking mode):
```bash
echo "=== Surveying git hooks (${TRACKING} mode) ==="
for f in pre-commit commit-msg post-commit post-merge filter-commit-message-inplace.sh; do
  if [[ "$TRACKING" == "stealth" ]]; then
    _diff_tpl ".husky/$f" "$TEMPLATES/.husky/$f" "$REPO/.git/hooks/$f"
  else
    _diff_tpl ".husky/$f" "$TEMPLATES/.husky/$f" "$REPO/.husky/$f"
  fi
done
```

**Process files** (location: `$RIG_DIR/processes/`):
```bash
echo "=== Surveying process files ==="
for tpl in "$TEMPLATES/.rig/processes/"*.md; do
  [[ -f "$tpl" ]] || continue
  f=$(basename "$tpl")
  _diff_tpl ".rig/processes/$f" "$tpl" "$RIG_DIR/processes/$f"
done
```

**Note on `[BASE_BRANCH]` diffs (applies to every survey above, both upgrade
modes):** `_diff_tpl` already substitutes `[BASE_BRANCH]` before comparing, but
this is a plain-text simulation of install.sh's own manifest/hash-based
classification (Phase 1c-bis's `agent-plan` output) — the two can disagree in
edge cases (confirmed live on `UPGRADE_WORKFLOW.md`: Phase 1d's own `_diff_tpl`
reported `CHANGED` purely from a `[BASE_BRANCH]` mismatch that `agent-plan`
correctly classified as `up-to-date`). If Phase 1d's survey and Phase 1c-bis's
`agent-plan` disagree on a file, **`agent-plan`'s classification is
authoritative** — it's install.sh's own real hash comparison, not a
reconstruction of it. Phase 1d's survey exists for quick human-readable
visibility only; don't block or re-litigate a decision based on it alone.
This was previously documented only in Phase 2b-classic's own "Note on
`[BASE_BRANCH]` diffs" (still accurate for that specific interactive-diff
context) — restated here so agent-mode users get the same guidance without
needing to fall back to classic mode to find it.

**Other tracked files**:
```bash
_diff_tpl ".rig/VERSION" "$TEMPLATES/.rig/VERSION" "$RIG_DIR/VERSION"
_diff_tpl ".gitleaks.toml" "$TEMPLATES/.gitleaks.toml" "$REPO/.gitleaks.toml"
```

### 1e — Check for user-modified Rig-owned files

Read the manifest to find files where the installed hash differs from the manifest hash.
These are files the user has edited since install — the installer will skip them.

```bash
MANIFEST="$RIG_DIR/memory/.rig-manifest"
if [[ -f "$MANIFEST" ]]; then
  while IFS= read -r line; do
    [[ "$line" =~ ^# ]] && continue; [[ -z "$line" ]] && continue
    manifest_hash=$(echo "$line" | awk '{print $1}')
    rel_path=$(echo "$line" | awk '{print $2}')
    # .rig/-prefixed entries live at the external $RIG_DIR in stealth/external
    # tracking, not $REPO/.rig/ -- resolving them as $REPO/$rel_path silently
    # skips every one of them (the -f check finds nothing there and the loop
    # just continues), undercounting real customizations. For repo/local
    # tracking $RIG_DIR already equals $REPO/.rig, so this resolves to the
    # same path either way.
    if [[ "$rel_path" == .rig/* ]]; then
      installed_path="$RIG_DIR/${rel_path#.rig/}"
    else
      installed_path="$REPO/$rel_path"
    fi
    [[ -f "$installed_path" ]] || continue
    current_hash=$(shasum -a 256 "$installed_path" 2>/dev/null | awk '{print $1}' || sha256sum "$installed_path" 2>/dev/null | awk '{print $1}')
    [[ "$current_hash" != "$manifest_hash" ]] && echo "USER-MODIFIED: $rel_path"
  done < "$MANIFEST"
fi
```

### 1f — Present the plan and wait

Display a summary table before touching anything:

```
=== Rig Upgrade Plan: $CURRENT_VERSION → $INSTALLER_VERSION ===

Files to auto-update (Rig-owned, unmodified):
  [list from survey]

Files that need review (Rig-owned, user-modified — installer will ask):
  [list from manifest check]

Files already up to date:
  [count]

Missing files to create:
  [list]
```

Then say:
> "Ready to upgrade. Proceed?"

**Wait for confirmation before Phase 2**, in an interactive session with a
user available to respond.

For an agent-driven/noninteractive execution context with no user available
to respond, proceed to Phase 2 directly without waiting — matching Phase
2-mode's own non-interactive fallback a few steps later (default to
`UPGRADE_MODE=agent`, which never silently overwrites a customized file; see
"Refusal semantics and exit code 3" in `UPGRADE_WORKFLOW.md`). Treating this
prompt and Phase 2-mode's prompt inconsistently — blocking here but not
there — would leave a fully noninteractive run hung on this step alone.

### 1g — Initialise result accumulators

Declare these arrays before Phase 2 begins. Every sub-phase appends to them;
Phase 5 reads them to produce an accurate summary.

```bash
UPGRADE_MODE=""          # "agent" or "classic" — set in Phase 2, 2-mode
UPGRADED=()              # files applied: classic mode's auto-updates, or agent
                         # mode's update/merge/remove actions
CONVERGED=()             # agent mode only: customized files merged via
                         # structure-aware/three-way convergence (issue #444 lane 444-C)
AGENT_CONFLICTS=()       # agent mode only: paths still needing manual review
                         # (classification "customized" or "conflict")
CUSTOMIZED_ACCEPTED=()   # classic mode only: user-modified files where user chose [a]ccept
CUSTOMIZED_KEPT=()       # classic mode only: user-modified files where user chose [k]eep
SKIPPED_BASE_BRANCH=()   # classic mode only: files skipped due to [BASE_BRANCH] false-positive
FIXED=()                 # manual corrections (VERSION, settings.json, commands)
DOCTOR_FAILURES=()       # bin/rig doctor gate names that failed post-upgrade
GLOBAL_UPDATED=()        # global layer sections/skills updated
GLOBAL_SKIPPED=()        # global layer sections/skills kept by user
```

---

## Phase 2 — Project layer upgrade

### 2-mode — Choose the upgrade mode

If `--mode=agent` or `--mode=classic` was passed (see Flags → `--mode`), set
`UPGRADE_MODE` to that value directly and skip the prompt below.

Otherwise, in an interactive session, ask the user:

> "Two ways to apply this upgrade:
> - **[g] Guarded convergence (recommended)** — runs `install.sh --strategy
>   agent-upgrade`. Applies every safe/convergeable change automatically —
>   including conflict-free structure-aware merges of customized files — never
>   prompts per file, and reports any file that still needs manual review with
>   concrete repair guidance instead of asking you to decide file-by-file.
> - **[c] Classic upgrade** — runs `install.sh --strategy upgrade`, the
>   original interactive `[a]ccept template` / `[k]eep yours` / `[s]how full
>   file` flow for every customized file.
>
> Which do you want? [g/c]"

Wait for the response. Map `g` / `guarded` / `agent` → `UPGRADE_MODE=agent`;
`c` / `classic` → `UPGRADE_MODE=classic`. On any other input, re-ask once;
if still unclear, default to `agent`.

For an agent-driven/noninteractive execution context with no `--mode` flag and
no user available to prompt, default to `UPGRADE_MODE=agent` directly without
asking — guarded convergence never silently overwrites a customized file (a
customized or conflicting file is always left untouched and reported in
`conflicts[]`, per "Refusal semantics and exit code 3" in
`UPGRADE_WORKFLOW.md`), and it produces the structured JSON result Phase 3's
`bin/rig doctor` check expects to reason about.

Then continue to **2a-agent** if `UPGRADE_MODE=agent`, or **2a-classic** if
`UPGRADE_MODE=classic`. Both paths converge again at **2c**.

---

### 2a-agent — Run the guarded convergence engine

```bash
AGENT_UPGRADE_JSON=$(bash "$INSTALLER_SRC/install.sh" --project-only \
  --target "$REPO" --tracking "$TRACKING" --strategy agent-upgrade)
AGENT_UPGRADE_STATUS=$?
echo "$AGENT_UPGRADE_JSON" | python3 -m json.tool  # pretty-print for the user
```

Interpret `$AGENT_UPGRADE_STATUS`:

- **`0`** — `status` is `"success"`. Every discovered artifact converged; no
  file needs manual review. Continue to 2b-agent (it reports nothing to
  review and moves straight on).
- **`3`** — `status` is `"refused"`. Every safe/convergeable action was still
  applied (see `summary.updated`, `summary.merged`, and `summary.converged`
  in the JSON) — this is not a failed run. At least one artifact is left
  untouched and listed in `conflicts[]`. Continue to 2b-agent to present it.
- **Any other exit code** — a genuine fatal error unrelated to conflicts (for
  example a missing target directory). Show `$AGENT_UPGRADE_JSON` verbatim
  (or, if it is empty, say the command produced no output), stop, and do not
  proceed to 2c or Phase 3.

Parse the JSON to populate the result accumulators:

```bash
echo "$AGENT_UPGRADE_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for a in d['artifacts']:
    if a['classification'] == 'converged':
        print('CONVERGED\t' + a['path'])
    elif a['action'] in ('update', 'merge', 'remove'):
        print('UPGRADED\t' + a['path'] + ' (' + a['action'] + ')')
for c in d['conflicts']:
    print('CONFLICT\t' + c['path'])
"
```

Read each tab-separated output line and append to the matching accumulator:
lines starting `CONVERGED` → `CONVERGED+=("$path")`; lines starting `UPGRADED`
→ `UPGRADED+=("$path")`; lines starting `CONFLICT` → `AGENT_CONFLICTS+=("$path")`.

### 2b-agent — Present unresolved conflicts

If `AGENT_CONFLICTS` is empty (i.e. `$AGENT_UPGRADE_STATUS` was `0`): say
"No files need manual review — every artifact converged automatically." and
continue to 2c.

Otherwise, for each entry in `$AGENT_UPGRADE_JSON`'s `conflicts[]` array,
present it exactly as the engine reported it — read `path`, `reason`, and
`repair_guidance` straight from the JSON. Do not invent guidance text and do
not offer an `[a]ccept`/`[k]eep` choice here: the engine already applied every
action it was willing to take automatically, so what remains is genuinely
unresolved and requires the manual step named in `repair_guidance`.

```
⚠️ N file(s) need manual review (guarded convergence left these untouched):

  path:            <conflicts[i].path>
  reason:          <conflicts[i].reason>
  repair guidance: <conflicts[i].repair_guidance>

  [... one block per conflicts[] entry ...]
```

Then say:
> "These files were left exactly as they were — nothing above was silently
> overwritten or silently accepted. Resolve them using the repair guidance
> above on your own schedule, then re-run `/rig-upgrade` to re-check. The
> rest of this upgrade already applied; continuing to verification."

Continue to 2c regardless of whether conflicts were found — a refused result
still applied every safe action, so post-upgrade verification is still
meaningful.

---

### 2a-classic — Run the installer

```bash
installer_output=$("$INSTALLER_SRC/install.sh" \
  --project-only \
  --strategy upgrade \
  --target "$REPO" 2>&1)
echo "$installer_output"  # show full output to user
```

Parse the captured output to populate result accumulators. The installer's
`success()` function prefixes every line with ANSI color codes and a status
symbol (`✓ `), so match on substring rather than prefix:

```bash
while IFS= read -r line; do
  case "$line" in
    *"Updated: "*)
      UPGRADED+=("${line#*Updated: }") ;;
  esac
done <<< "$installer_output"
```

Watch for:
- `"Updated: ..."` — file was auto-updated ✓ → added to `UPGRADED[]`
- `"Up to date: ..."` — file already current ✓
- `"Merged .claude/settings.json"` — settings merged ✓
- `"Customized file detected: ..."` — user-modified file was skipped; handle in 2b-classic
- `"Skipped (user-owned...): ..."` — expected; ignore
- Any `ERROR` or non-zero exit — stop and report

### 2b-classic — Handle skipped "Customized" files

For each file the installer reported as `"Customized file detected:"`:

1. Show what changed in the template. `$rel` is the same manifest-relative path
   format install.sh's own "Customized file detected:" output uses — for a
   `.rig/`-prefixed path in stealth/external tracking, that file lives under
   the external `$RIG_DIR`, not `$REPO/.rig/` (identical reasoning to Phase 1e
   above; see issue #494):
   ```bash
   tmp=$(mktemp)
   sed "s/\[BASE_BRANCH\]/${BASE_BRANCH}/g; s|\[REPO_ROOT\]|${REPO}|g" \
     "$TEMPLATES/$rel" > "$tmp"
   if [[ "$rel" == .rig/* ]]; then
     installed_path="$RIG_DIR/${rel#.rig/}"
   else
     installed_path="$REPO/$rel"
   fi
   diff "$installed_path" "$tmp"
   rm -f "$tmp"
   ```

2. Tell the user exactly what the diff shows.

3. Offer these options:
   > - **[a] Accept template** — overwrite with the new version (backup saved to `.rig-backup/`)
   > - **[k] Keep yours** — skip this file (your edits stay; you may miss upstream fixes)
   > - **[s] Show full file** — read both versions in full before deciding

4. If user chooses **[a]**: copy the template (with substitutions) over the installed file
   at `$installed_path` (resolved in step 1 above — the external `$RIG_DIR` path for
   `.rig/`-prefixed files in stealth/external tracking, `$REPO/$rel` otherwise).
   Then update the manifest entry and record the result:
   ```bash
   NEW_HASH=$(shasum -a 256 "$installed_path" 2>/dev/null | awk '{print $1}')
   # Replace the old hash line in .rig-manifest
   sed -i '' "/$rel$/s/^[a-f0-9]* /$NEW_HASH /" "$MANIFEST" 2>/dev/null || \
   sed -i "/$rel$/s/^[a-f0-9]* /$NEW_HASH /" "$MANIFEST"
   CUSTOMIZED_ACCEPTED+=("$rel")
   ```

5. If user chooses **[k]**: log a note and move on:
   ```bash
   CUSTOMIZED_KEPT+=("$rel")
   ```

**Note on `[BASE_BRANCH]` diffs:** If the only differences are `[BASE_BRANCH]` vs the
actual branch name (e.g. `main`), that is a known false positive — the file content is
effectively identical. Skip it automatically and say: "Skipped `$rel` — only `[BASE_BRANCH]`
substitution differs (expected)."
   ```bash
   SKIPPED_BASE_BRANCH+=("$rel")
   ```

### 2c — Stealth: update `.git/hooks/`

If `$TRACKING == stealth`, the installer does not update `.git/hooks/` directly (it writes
to `.husky/` which doesn't exist in stealth projects). Apply hook updates manually:

```bash
for f in pre-commit commit-msg post-commit post-merge filter-commit-message-inplace.sh; do
  tpl="$TEMPLATES/.husky/$f"
  dest="$REPO/.git/hooks/$f"
  [[ -f "$tpl" ]] || continue
  if ! diff -q "$tpl" "$dest" >/dev/null 2>&1; then
    cp "$tpl" "$dest"
    chmod +x "$dest"
    echo "Updated .git/hooks/$f"
  fi
done
```

---

## Phase 3 — Post-upgrade verification

### 3a — VERSION check

```bash
INSTALLED_VERSION=$(cat "$RIG_DIR/VERSION" 2>/dev/null || echo "missing")
EXPECTED_VERSION=$(cat "$INSTALLER_SRC/VERSION")
```

- If `$INSTALLED_VERSION == $EXPECTED_VERSION`: ✓ say so.
- If they differ: fix it:
  ```bash
  echo "$EXPECTED_VERSION" > "$RIG_DIR/VERSION"
  NEW_HASH=$(shasum -a 256 "$RIG_DIR/VERSION" | awk '{print $1}')
  sed -i '' "/\.rig\/VERSION$/s/^[a-f0-9]* /$NEW_HASH /" "$MANIFEST" 2>/dev/null || \
  sed -i "/\.rig\/VERSION$/s/^[a-f0-9]* /$NEW_HASH /" "$MANIFEST"
  echo "Fixed .rig/VERSION: $INSTALLED_VERSION → $EXPECTED_VERSION"
  FIXED+=(".rig/VERSION: $INSTALLED_VERSION → $EXPECTED_VERSION")
  ```

### 3b — settings.json deduplication check

```bash
python3 -c "
import json
with open('$REPO/.claude/settings.json') as f:
    s = json.load(f)
issues = []
for event, entries in s.get('hooks', {}).items():
    if len(entries) > 1:
        issues.append(f'{event}: {len(entries)} entries (expected 1)')
if issues:
    for i in issues: print('DUPLICATE:', i)
else:
    print('settings.json: OK (1 entry per event)')
"
```

If duplicates are found, remove them: each hook event (`PreToolUse`, `PostToolUse`, `Stop`)
should have **exactly one** entry. Keep the first occurrence; delete the rest. Write the
cleaned file back with `json.dump(..., indent=2)`. Record the fix:
```bash
FIXED+=("settings.json: removed duplicate hook entries")
```

### 3c — Commands inventory check

```bash
ls "$REPO/.claude/commands/"
```

Every command in `$TEMPLATES/.claude/commands/` should be present. List any that are missing
and offer to install them. For each one installed:
```bash
FIXED+=("commands: installed $name")
```

### 3d — `bin/rig doctor` postflight gates

Run the installed project's own `bin/rig doctor` to verify the five gates it
checks (`manifest_provenance`, `stealth_status`, `manifest_mode_hash`,
`stale_manifest_entries`, `idempotence` — see `UPGRADE_WORKFLOW.md` →
"Post-upgrade verification: `bin/rig doctor` gates" for what each one
verifies) actually pass on the state the upgrade just produced:

```bash
if [[ -x "$REPO/bin/rig" ]]; then
  DOCTOR_JSON=$("$REPO/bin/rig" doctor --json)
  DOCTOR_STATUS=$?
else
  DOCTOR_JSON=""
  DOCTOR_STATUS=127
fi
```

If `$REPO/bin/rig` does not exist or is not executable (a project upgrading
from a version older than issue #444 lane 444-H, before this command shipped):
say "bin/rig doctor is not available in this project yet (pre-444-H install) —
skipping postflight gates." and continue to Phase 4. Do not treat this as a
failure.

Otherwise, parse `$DOCTOR_JSON`:

```bash
echo "$DOCTOR_JSON" | python3 -c "
import json, sys
d = json.load(sys.stdin)
for c in d['checks']:
    if not c['ok']:
        print('FAIL\t' + c['name'] + '\t' + c['detail'])
print('OVERALL\t' + str(d['ok']))
"
```

Append the gate name from each `FAIL` line to `DOCTOR_FAILURES`.

- If the parsed `OVERALL` value is `True` (equivalently, `$DOCTOR_STATUS` was
  `0`): say "bin/rig doctor: all gates passed." and continue to Phase 4.
- If `False` (`$DOCTOR_STATUS` was `1`): present each failing gate's name and
  `detail` string exactly as `bin/rig doctor --json` reported it, then say:
  > "⚠️ bin/rig doctor found `${#DOCTOR_FAILURES[@]}` gate failure(s) after
  > this upgrade (listed above). These are separate from the "skipped" gates
  > that are expected steady state on an ordinary install (see
  > `UPGRADE_WORKFLOW.md`) — a failure here means a check actually ran and
  > found a real mismatch. Review each one before treating the upgrade as
  > complete; this does not block continuing to Phase 4/5, but it must appear
  > in the Phase 5 summary."
  Continue to Phase 4 — do not stop the command, but carry `DOCTOR_FAILURES`
  into the Phase 5 summary so it is never silently dropped.

---

## Phase 4 — Global layer upgrade (optional)

> **Scope gate:** If `SKIP_GLOBAL=true` (from `--scope=project`), skip Phase 4
> entirely. Jump to Phase 5.

If `--scope=both` or no scope flag: ask the user:
> "Do you also want to upgrade the global layer (`~/.claude/CLAUDE.md` + skills)?"

If **no**: skip to Phase 5.

If **yes**: proceed.

### 4a — Diff global CLAUDE.md

```bash
diff ~/.claude/CLAUDE.md "$INSTALLER_SRC/templates/global/CLAUDE.md"
```

Show the diff to the user. Identify which **sections** changed (look for `## Section Name`
headings in the diff). Do NOT overwrite the file wholesale — that would destroy:
- The real `PROFILE_PATH` or `PROFILE` import path
- Any personal hard rules or stack defaults the user has added
- Any project-specific global customizations

For each changed section, present:
> "Section `## [Section Name]` changed in the template. Apply this update?"
> [show the template version of the section]

If the user says yes: replace only that section in `~/.claude/CLAUDE.md` and record it:
```bash
GLOBAL_UPDATED+=("CLAUDE.md: ## $section_name")
```
If the user says no or skip:
```bash
GLOBAL_SKIPPED+=("CLAUDE.md: ## $section_name")
```

### 4b — Skills

```bash
for f in "$INSTALLER_SRC/templates/global/skills/"*.md; do
  name=$(basename "$f")
  target=~/.claude/skills/"$name"
  if [[ ! -f "$target" ]]; then
    echo "NEW skill: $name"
    # offer to install
  elif ! diff -q "$f" "$target" >/dev/null 2>&1; then
    echo "CHANGED: $name"
    # show diff, offer to update
  else
    echo "up-to-date: $name"
  fi
done
```

For each changed skill, show the diff and ask: update or keep?
```bash
# On update:
GLOBAL_UPDATED+=("skill: $name")
# On keep:
GLOBAL_SKIPPED+=("skill: $name")
```

---

## Phase 5 — Wrap-up

Print a summary using the result accumulators populated in Phases 2–4:

```bash
echo "=== Upgrade complete: $CURRENT_VERSION → $EXPECTED_VERSION (mode: $UPGRADE_MODE) ==="
echo ""

if [[ ${#UPGRADED[@]} -gt 0 ]]; then
  echo "Auto-updated (${#UPGRADED[@]}):"
  printf '  %s\n' "${UPGRADED[@]}"
else
  echo "Auto-updated: (none — all files already current)"
fi
echo ""

if [[ "$UPGRADE_MODE" == "agent" ]]; then
  if [[ ${#CONVERGED[@]} -gt 0 ]]; then
    echo "Converged (structure-aware/three-way merge, customization preserved):"
    printf '  %s\n' "${CONVERGED[@]}"
  else
    echo "Converged: (none)"
  fi
  echo ""
  if [[ ${#AGENT_CONFLICTS[@]} -gt 0 ]]; then
    echo "Needs manual review (${#AGENT_CONFLICTS[@]} — see repair guidance presented in 2b-agent):"
    printf '  %s\n' "${AGENT_CONFLICTS[@]}"
  else
    echo "Needs manual review: (none — status was success)"
  fi
else
  if [[ ${#CUSTOMIZED_ACCEPTED[@]} -gt 0 || ${#CUSTOMIZED_KEPT[@]} -gt 0 || ${#SKIPPED_BASE_BRANCH[@]} -gt 0 ]]; then
    echo "Reviewed (customized files):"
    for f in "${CUSTOMIZED_ACCEPTED[@]}"; do printf '  accepted: %s\n' "$f"; done
    for f in "${CUSTOMIZED_KEPT[@]}";    do printf '  kept:     %s\n' "$f"; done
    for f in "${SKIPPED_BASE_BRANCH[@]}"; do printf '  skipped (BASE_BRANCH only): %s\n' "$f"; done
  else
    echo "Reviewed: (no customized files)"
  fi
fi
echo ""

if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo "Fixed (${#FIXED[@]}):"
  printf '  %s\n' "${FIXED[@]}"
fi
echo ""

if [[ ${#DOCTOR_FAILURES[@]} -gt 0 ]]; then
  echo "bin/rig doctor: ${#DOCTOR_FAILURES[@]} gate failure(s):"
  printf '  %s\n' "${DOCTOR_FAILURES[@]}"
else
  echo "bin/rig doctor: all gates passed (or unavailable — see Phase 3d)"
fi
echo ""

if [[ ${#GLOBAL_UPDATED[@]} -gt 0 || ${#GLOBAL_SKIPPED[@]} -gt 0 ]]; then
  echo "Global layer:"
  for f in "${GLOBAL_UPDATED[@]}"; do printf '  updated: %s\n' "$f"; done
  for f in "${GLOBAL_SKIPPED[@]}"; do printf '  kept:    %s\n' "$f"; done
else
  echo "Global layer: skipped"
fi
```

If this project has a bats test suite (`tests/*.bats`), remind the user:
> "Run `bats tests/` to verify the installer is still working correctly."

If `DOCTOR_FAILURES` is non-empty, repeat the warning before moving on:
> "⚠️ `bin/rig doctor` reported gate failures above — resolve them before
> considering this upgrade fully verified."

If the project target includes Codex and any `.claude/commands/*.md` file was
updated, verify the generated skill mirror before considering the upgrade
complete:

```bash
test -d "$REPO/.agents/skills"
test -f "$REPO/.agents/skills/wrap/SKILL.md"
test -f "$REPO/.agents/skills/wrap/references/command.md"
test -f "$REPO/.agents/skills/post-merge/SKILL.md"
test -f "$REPO/.agents/skills/post-merge/references/command.md"
```

If any check fails, regenerate the mirrors from the canonical Claude command
sources with the installer generator, then re-run the checks:

```bash
mapfile -d '' CODEX_COMMAND_SOURCES < <(find "$INSTALLER_SRC/templates/project/.claude/commands" \
  -maxdepth 1 -type f -name '*.md' -print0)
python3 "$INSTALLER_SRC/installer/generate-codex-skills.py" \
  --output "$REPO/.agents/skills" \
  --base-branch "$BASE_BRANCH" \
  --skills-source "$INSTALLER_SRC/templates/project/.claude/skills" \
  "${CODEX_COMMAND_SOURCES[@]}"
```

Do not patch generated `.agents/skills/*/references/command.md` files by hand
without making the matching canonical `.claude/commands/*.md` change first.

### 5a — Commit strategy recommendation

Count the total modified files:

```bash
TOTAL_CHANGED=$((${#UPGRADED[@]} + ${#CONVERGED[@]} + ${#CUSTOMIZED_ACCEPTED[@]} + ${#FIXED[@]}))
```

If `$TRACKING == stealth` (or `external`), the branch/commit/PR recommendation
below does not apply: `.claude/` and `.rig/` are wholesale excluded from git
via `.git/info/exclude` in stealth/external tracking, so there is nothing to
branch, stage, or commit for those paths, regardless of `$TOTAL_CHANGED`. Say
instead:
> "**Commit strategy:** N/A — this is a `$TRACKING`-tracked project.
> `.claude/`/`.rig/` changes made by this upgrade are excluded from git
> entirely; there is nothing to commit for them."
and skip the rest of this phase.

If `$TRACKING == repo` and `$TOTAL_CHANGED` > 3:

> "**Commit strategy:** `$TOTAL_CHANGED` files were modified — use a branch and PR,
> even if `housekeeping: direct-push` is set:
>
> ```bash
> git checkout -b chore/rig-upgrade-$EXPECTED_VERSION
> git add -f .claude/ .husky/ .rig/processes/ .rig/rules/ .rig/VERSION
> git commit -m "chore(rig): upgrade to The Rig $EXPECTED_VERSION [#N]"
> gh pr create --title "chore(rig): upgrade to $EXPECTED_VERSION" ...
> ```
>
> `housekeeping: direct-push` applies to memory commits (PROGRESS.md, task file moves)
> — not to upgrades that modify hooks, commands, and process files."

If `$TRACKING == repo` and `$TOTAL_CHANGED` <= 3:

> "**Commit strategy:** Only `$TOTAL_CHANGED` file(s) changed — a direct
> `chore(rig): upgrade to $EXPECTED_VERSION [#N]` commit to `$BASE_BRANCH`
> is acceptable if `housekeeping: direct-push` is set."

Then say:
> "Upgrade complete. What's next?"

---

## Troubleshooting reference

| Symptom | Fix |
|---|---|
| Installer not found | Set `RIG_INSTALLER_SRC` or check `~/tools/the-rig/` |
| Installer on wrong branch | `git -C ~/tools/the-rig checkout main && git pull origin main` |
| `settings.json` still has duplicates after upgrade | Run Phase 3b manually; edit file directly |
| `.rig/VERSION` shows old version | Run Phase 3a fix block manually |
| A Rig-owned file wasn't updated (no prompt either) | Copy from template manually: `cp $TEMPLATES/$rel $REPO/$rel` — or, for a `.rig/`-prefixed `$rel` in stealth/external tracking, `cp $TEMPLATES/$rel $RIG_DIR/${rel#.rig/}` |
| Global CLAUDE.md was overwritten with placeholders | Restore from `.rig-backup/` + re-apply surgical edits |
| `git add` in hook fails with `index.lock` | Use `git update-index --add <file>` inside hooks instead of `git add` |
| `agent-upgrade` exits `3` (`status: "refused"`) | Not a failure — every safe action was still applied. Resolve each `conflicts[]` entry using its own `repair_guidance`, then re-run `/rig-upgrade` |
| `bin/rig doctor` reports a gate failure after upgrade | Review the failing gate's `detail` string (Phase 3d); it names the exact mismatch (e.g. hash drift, stale manifest entry) |
| `bin/rig doctor` not found | The project was installed before issue #444 lane 444-H shipped `bin/rig` — Phase 3d skips cleanly; re-run `/rig-upgrade` after this upgrade completes to pick it up |

Full upgrade docs: `$RIG_DIR/processes/UPGRADE_WORKFLOW.md`
