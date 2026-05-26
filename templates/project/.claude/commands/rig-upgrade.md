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
```

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
```

Output:

> ```
> Rig version info
> ─────────────────────────────────────────
> Project (.rig/VERSION):         1.16.0   (last modified: 2026-05-18 11:41)
> Global installer (~/tools/):    1.16.0   (last modified: 2026-05-18 10:52)
> Latest GitHub release:          v1.16.0  (published: 2026-05-18)
> ```

If `GITHUB_VERSION` is empty (gh not available or network failed), print instead:
> ```
> Latest GitHub release:          (unavailable — gh not found or no network)
> ```

After printing all three lines, apply these checks in order:

1. If project and global versions differ:
   > "⚠️ Project is at `$PROJECT_VERSION` but global installer is at `$GLOBAL_VERSION`. Run `/rig-upgrade` to sync."

2. If a GitHub version was retrieved and it differs from `$PROJECT_VERSION`
   (compare after stripping a leading `v` from `$GITHUB_VERSION`):
   > "⚠️ A newer release is available: `$GITHUB_VERSION`. Pull `~/tools/the-rig` and run `/rig-upgrade`."

3. If all three are in sync: say nothing extra.

Then stop — do not proceed to Phase 0.

### `--scope` flag

Read the scope flag before Phase 0. Default is `both` (current behavior).

- `--scope=project`: set `SKIP_GLOBAL=true`. Phase 4 is skipped entirely.
- `--scope=global`: set `SKIP_PROJECT=true`. Phases 1, 2, and 3 are skipped entirely. Jump directly to Phase 4.
- `--scope=both`: normal flow (no skip).

These flags do not suppress the Phase 0 session state check — always run 0a first.

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

**Claude hooks** (always at `$REPO/.claude/hooks/`):
```bash
for f in pre-tool.sh post-tool.sh stop.sh; do
  _diff_tpl ".claude/hooks/$f" "$TEMPLATES/.claude/hooks/$f" "$REPO/.claude/hooks/$f"
done
```

**Claude commands** (always at `$REPO/.claude/commands/`):
```bash
for f in debug.md doc-feature.md kickoff.md new-feature.md post-merge.md propose.md \
          recon.md refresh-feature-doc.md rig-gaps.md run.md session-name.md ship.md \
          task.md upgrade.md wrap.md; do
  _diff_tpl ".claude/commands/$f" "$TEMPLATES/.claude/commands/$f" "$REPO/.claude/commands/$f"
done
```

**Git hooks** (location depends on tracking mode):
```bash
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
for f in SHIP_WORKFLOW.md NEW_TASK_WORKFLOW.md POST_MERGE_WORKFLOW.md \
          DEBUG_WORKFLOW.md UPGRADE_WORKFLOW.md; do
  _diff_tpl ".rig/processes/$f" "$TEMPLATES/.rig/processes/$f" "$RIG_DIR/processes/$f"
done
```

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
    installed_path="$REPO/$rel_path"
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

**Wait for confirmation before Phase 2.**

### 1g — Initialise result accumulators

Declare these arrays before Phase 2 begins. Every sub-phase appends to them;
Phase 5 reads them to produce an accurate summary.

```bash
UPGRADED=()             # files the installer auto-updated
CUSTOMIZED_ACCEPTED=()  # user-modified files where user chose [a]ccept
CUSTOMIZED_KEPT=()      # user-modified files where user chose [k]eep
SKIPPED_BASE_BRANCH=()  # files skipped due to [BASE_BRANCH] false-positive
FIXED=()                # manual corrections (VERSION, settings.json, commands)
GLOBAL_UPDATED=()       # global layer sections/skills updated
GLOBAL_SKIPPED=()       # global layer sections/skills kept by user
```

---

## Phase 2 — Project layer upgrade

### 2a — Run the installer

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
- `"Customized file detected: ..."` — user-modified file was skipped; handle in 2b
- `"Skipped (user-owned...): ..."` — expected; ignore
- Any `ERROR` or non-zero exit — stop and report

### 2b — Handle skipped "Customized" files

For each file the installer reported as `"Customized file detected:"`:

1. Show what changed in the template:
   ```bash
   tmp=$(mktemp)
   sed "s/\[BASE_BRANCH\]/${BASE_BRANCH}/g; s|\[REPO_ROOT\]|${REPO}|g" \
     "$TEMPLATES/$rel" > "$tmp"
   diff "$REPO/$rel" "$tmp"
   rm -f "$tmp"
   ```

2. Tell the user exactly what the diff shows.

3. Offer these options:
   > - **[a] Accept template** — overwrite with the new version (backup saved to `.rig-backup/`)
   > - **[k] Keep yours** — skip this file (your edits stay; you may miss upstream fixes)
   > - **[s] Show full file** — read both versions in full before deciding

4. If user chooses **[a]**: copy the template (with substitutions) over the installed file.
   Then update the manifest entry and record the result:
   ```bash
   NEW_HASH=$(shasum -a 256 "$REPO/$rel" 2>/dev/null | awk '{print $1}')
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
echo "=== Upgrade complete: $CURRENT_VERSION → $EXPECTED_VERSION ==="
echo ""

if [[ ${#UPGRADED[@]} -gt 0 ]]; then
  echo "Auto-updated (${#UPGRADED[@]}):"
  printf '  %s\n' "${UPGRADED[@]}"
else
  echo "Auto-updated: (none — all files already current)"
fi
echo ""

if [[ ${#CUSTOMIZED_ACCEPTED[@]} -gt 0 || ${#CUSTOMIZED_KEPT[@]} -gt 0 || ${#SKIPPED_BASE_BRANCH[@]} -gt 0 ]]; then
  echo "Reviewed (customized files):"
  for f in "${CUSTOMIZED_ACCEPTED[@]}"; do printf '  accepted: %s\n' "$f"; done
  for f in "${CUSTOMIZED_KEPT[@]}";    do printf '  kept:     %s\n' "$f"; done
  for f in "${SKIPPED_BASE_BRANCH[@]}"; do printf '  skipped (BASE_BRANCH only): %s\n' "$f"; done
else
  echo "Reviewed: (no customized files)"
fi
echo ""

if [[ ${#FIXED[@]} -gt 0 ]]; then
  echo "Fixed (${#FIXED[@]}):"
  printf '  %s\n' "${FIXED[@]}"
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
| A Rig-owned file wasn't updated (no prompt either) | Copy from template manually: `cp $TEMPLATES/$rel $REPO/$rel` |
| Global CLAUDE.md was overwritten with placeholders | Restore from `.rig-backup/` + re-apply surgical edits |
| `git add` in hook fails with `index.lock` | Use `git update-index --add <file>` inside hooks instead of `git add` |

Full upgrade docs: `$RIG_DIR/processes/UPGRADE_WORKFLOW.md`
