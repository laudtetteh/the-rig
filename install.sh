#!/usr/bin/env bash
# install.sh — The Rig installer
#
# Deploys The Rig's templates to your machine and/or a target project.
#
# Usage:
#   ./install.sh                  # Interactive mode — prompts for everything
#   ./install.sh --global-only    # Install global layer only (~/.claude/)
#   ./install.sh --project-only   # Scaffold project layer only
#   ./install.sh --help           # Show usage
#   ./install.sh --version        # Print version and exit
#
# Requirements: bash 3.2+, coreutils (cp, mkdir, chmod, sed)
# Optional: gitleaks (for secret scanning), npm/npx (for Husky)

set -euo pipefail

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────
info()    { echo -e "${BLUE}→${RESET} $*"; }
success() { echo -e "${GREEN}✓${RESET} $*"; }
warn()    { echo -e "${YELLOW}!${RESET} $*"; }
error()   { echo -e "${RED}✗${RESET} $*" >&2; }
bold()    { echo -e "${BOLD}$*${RESET}"; }
ask()     { echo -e "${BOLD}?${RESET} $*"; }

confirm() {
  local msg="$1"
  local default="${2:-n}"
  local prompt
  if [[ "$default" == "y" ]]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
  # Non-interactive (CI / piped stdin): accept the default without prompting.
  if [[ ! -t 0 ]]; then
    [[ "$default" =~ ^[Yy]$ ]]
    return
  fi
  read -r -p "$(echo -e "${BOLD}?${RESET} ${msg} ${prompt} ")" answer
  answer="${answer:-$default}"
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ── SHA256 helper ─────────────────────────────────────────────────────────────
# Portable: prefers sha256sum (Linux/GNU), falls back to shasum -a 256 (macOS).
# Returns empty string if neither is available.
sha256_file() {
  local file="$1"
  [[ -f "$file" ]] || { echo ""; return; }
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$file" | awk '{print $1}'
  else
    echo ""
  fi
}

# ── Rig-owned file classification ─────────────────────────────────────────────
# Returns 0 (true) if the file is infrastructure owned by The Rig (hooks, commands,
# processes). Used in overwrite mode to gate the user-modification warning — Rig-owned
# files are always overwritten silently; user-owned files prompt if customized.
# Returns 1 (false) for user-owned files (CLAUDE.md, rules, memory, tasks, github).
#
# NOTE: The manifest now tracks ALL files (not just Rig-owned), so the Upgrade
# strategy applies manifest-aware logic uniformly. is_rig_owned() is used for
# messaging/warning decisions only, not as a skip gate.
#
# Rig-owned:   .claude/hooks/, .claude/commands/, .rig/processes/, .husky/, .gitleaks.toml
# User-owned:  CLAUDE.md, PROJECT_BRIEF.md, .rig/rules/, .rig/memory/*.md,
#              .rig/tasks/, .github/
# Special:     .claude/settings.json (always smart-merged, not manifest-tracked)
is_rig_owned() {
  local rel="$1"
  case "$rel" in
    .claude/hooks/*|\
    .claude/commands/*|\
    .rig/processes/*|\
    .rig/VERSION|\
    .husky/*|\
    .gitleaks.toml)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# ── Manifest helpers ──────────────────────────────────────────────────────────
# The manifest lives at $MANIFEST_FILE and records the SHA256 of each Rig-owned
# file at the time it was last installed by the installer. Format per line:
#   sha256hash  relative/path
#
# This allows the Upgrade strategy to distinguish:
#   dest hash == manifest hash  → file unmodified since install → safe to overwrite
#   dest hash != manifest hash  → user has customized the file  → prompt before overwriting
#
# The manifest is committed to the repo (not gitignored) so the baseline travels
# with the project and any team member can run an Upgrade.

MANIFEST_FILE=""        # set during project-layer install (after RIG_DIR is resolved)
GLOBAL_MANIFEST_FILE="$HOME/.claude/.rig-global-manifest"  # global layer manifest

read_manifest_hash() {
  # Returns the recorded hash for a given rel path, or empty string if not found.
  local rel="$1"
  [[ -f "$MANIFEST_FILE" ]] || { echo ""; return 0; }
  # grep exits 1 when no match; suppress it so set -eo pipefail doesn't kill the installer.
  grep "  ${rel}$" "$MANIFEST_FILE" 2>/dev/null | awk '{print $1}' | head -1 || true
}

write_manifest_entry() {
  # Upsert: remove any existing entry for $rel, then append the new hash.
  local hash="$1"
  local rel="$2"
  [[ -z "$hash" || -z "$MANIFEST_FILE" ]] && return
  mkdir -p "$(dirname "$MANIFEST_FILE")"
  if [[ ! -f "$MANIFEST_FILE" ]]; then
    {
      echo "# The Rig manifest"
      echo "# Records the SHA256 of each Rig-owned file at last install."
      echo "# Used by the Upgrade strategy to detect user customizations."
      echo "# Committed to the repo. Do not edit manually."
    } > "$MANIFEST_FILE"
  fi
  local tmp; tmp="$(mktemp)"
  grep -v "  ${rel}$" "$MANIFEST_FILE" > "$tmp" 2>/dev/null || true
  echo "${hash}  ${rel}" >> "$tmp"
  mv "$tmp" "$MANIFEST_FILE"
}

# ── Locate the script's own directory (works with symlinks) ───────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_TEMPLATES="$SCRIPT_DIR/templates/global"
PROJECT_TEMPLATES="$SCRIPT_DIR/templates/project"
INSTALLER_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"

# ── Installer branch drift check ─────────────────────────────────────────────
# If the installer lives inside a git repo, check whether it's behind its
# remote tracking branch. A stale installer installs stale templates.
# Runs silently if there's no remote, no network, or no git.
# Tests can override _RIG_DRIFT_DIR to point to a mock repo.
_DRIFT_DIR="${_RIG_DRIFT_DIR:-$SCRIPT_DIR}"
if git -C "$_DRIFT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$_DRIFT_DIR" fetch --quiet 2>/dev/null || true
  _TRACKING=$(git -C "$_DRIFT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [[ -n "$_TRACKING" ]]; then
    _BEHIND=$(git -C "$_DRIFT_DIR" rev-list "HEAD..${_TRACKING}" --count 2>/dev/null || echo 0)
    if [[ "$_BEHIND" -gt 0 ]]; then
      warn "The installer is ${_BEHIND} commit(s) behind ${_TRACKING}."
      warn "Run: git -C \"$_DRIFT_DIR\" pull   to get the latest version first."
      warn "Proceeding with the current version..."
      echo ""
    fi
  fi
fi

# ── Parse flags ───────────────────────────────────────────────────────────────
DO_GLOBAL=true
DO_PROJECT=true
EXTERNAL_RIG_DIR=""   # set via --rig-dir <path>
RIG_TRACKING=""       # set during project-layer tracking detection; empty for global-only runs
_FLAG_STRATEGY=""     # set via --strategy <name>   (skips interactive prompt)
_FLAG_TARGET=""       # set via --target <path>     (skips interactive prompt)
_FLAG_PROJECT_NAME="" # set via --project-name <n>  (skips interactive prompt)
_FLAG_BASE_BRANCH=""  # set via --base-branch <n>   (skips interactive prompt)
_FLAG_TRACKING=""     # set via --tracking <mode>   (skips tracking prompt; orthogonal to --target)
SKIP_GIT_HOOKS=false  # set via --skip-git-hooks    (stealth: skip .git/hooks/ writes)

for arg in "$@"; do
  case "$arg" in
    --global-only)      DO_PROJECT=false ;;
    --project-only)     DO_GLOBAL=false ;;
    --skip-git-hooks)   SKIP_GIT_HOOKS=true ;;
    --rig-dir|--strategy|--target|--project-name|--base-branch|--tracking)
      # two-arg flags; value captured in the loop below
      ;;
    --version|-v)
      VERSION_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/VERSION"
      if [[ -f "$VERSION_FILE" ]]; then
        echo "The Rig v$(cat "$VERSION_FILE")"
      else
        echo "The Rig (VERSION file not found)"
      fi
      exit 0
      ;;
    --help|-h)
      echo "Usage: ./install.sh [options]"
      echo ""
      echo "Interactive (no flags): prompts 'What are you doing?' and guides from there."
      echo ""
      echo "Layer flags (override the intent menu):"
      echo "  --global-only         Install ~/.claude/ layer only (CLAUDE.md + skills)"
      echo "  --project-only        Scaffold project layer only"
      echo ""
      echo "Non-interactive flags (bypass all prompts — useful for scripting and CI):"
      echo "  --strategy <name>     Set strategy directly."
      echo "                        Values: merge | skip | overwrite | upgrade | interactive"
      echo "                        merge    — new/drop-in install (safe default; smart-merges settings.json)"
      echo "                        skip     — only install files that don't exist yet"
      echo "                        upgrade  — auto-update unmodified Rig files; prompt on customized; skip user-owned"
      echo "                        overwrite — replace everything; back up originals"
      echo "  --target <path>       Set target project directory."
      echo "  --project-name <name> Set project name (used in CLAUDE.md substitution)."
      echo "  --base-branch <name>  Set base branch name (default: main). Substituted into"
      echo "                        workflow examples and CLAUDE.md base-branch field."
      echo "  --tracking <mode>     Set .rig/ tracking mode without a prompt."
      echo "                        Values: repo | local | external | stealth"
      echo "                        repo     — .rig/ committed with the project (default)"
      echo "                        local    — .rig/ in .git/info/exclude; invisible to teammates"
      echo "                        external — .rig/ outside the repo (requires --rig-dir)"
      echo "                        stealth  — zero Rig traces; hooks go to .git/hooks/"
      echo "                        Orthogonal to --target: both can be used together."
      echo ""
      echo "Other:"
      echo "  --rig-dir <path>      Install .rig/ to an external path outside the repo."
      echo "                        Writes a .rigpath pointer file at the project root."
      echo "                        Useful for shared repos where teammates don't use The Rig."
      echo "  --skip-git-hooks      Stealth mode only: skip writing hooks to .git/hooks/."
      echo "                        Use when the project already manages git hooks via Husky"
      echo "                        or another tool and you want to avoid the conflict."
      echo "  --version, -v         Print The Rig version and exit."
      exit 0
      ;;
  esac
done

# Capture two-argument flag values
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  if [[ "${args[$i]}" == "--rig-dir" && $((i+1)) -lt ${#args[@]} ]]; then
    EXTERNAL_RIG_DIR="${args[$((i+1))]}"
  fi
  if [[ "${args[$i]}" == "--strategy" && $((i+1)) -lt ${#args[@]} ]]; then
    _FLAG_STRATEGY="${args[$((i+1))]}"
  fi
  if [[ "${args[$i]}" == "--target" && $((i+1)) -lt ${#args[@]} ]]; then
    _FLAG_TARGET="${args[$((i+1))]}"
  fi
  if [[ "${args[$i]}" == "--project-name" && $((i+1)) -lt ${#args[@]} ]]; then
    _FLAG_PROJECT_NAME="${args[$((i+1))]}"
  fi
  if [[ "${args[$i]}" == "--base-branch" && $((i+1)) -lt ${#args[@]} ]]; then
    _FLAG_BASE_BRANCH="${args[$((i+1))]}"
  fi
  if [[ "${args[$i]}" == "--tracking" && $((i+1)) -lt ${#args[@]} ]]; then
    _FLAG_TRACKING="${args[$((i+1))]}"
  fi
done

# ── Portable in-place sed ─────────────────────────────────────────────────────
# GNU sed uses -i ""; macOS BSD sed uses -i ''
sed_inplace() {
  local pattern="$1"
  local file="$2"
  if sed --version 2>/dev/null | grep -q GNU; then
    sed -i "$pattern" "$file"
  else
    sed -i '' "$pattern" "$file"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
echo ""
bold "╔══════════════════════════════════════╗"
bold "║         The Rig — Installer          ║"
bold "╚══════════════════════════════════════╝"
echo ""

# ── INSTALL INTENT ────────────────────────────────────────────────────────────
# Ask what the user is trying to do, then derive strategy and layer flags from
# that intent. Users shouldn't need to know what "merge" vs "upgrade" means.
#
# Internal COLLISION_STRATEGY values (not user-visible in the main flow):
#   merge        — smart-merge settings.json; skip everything else
#                  used for: fresh install and drop-in (safe default)
#   upgrade      — update Rig-owned files; preserve user-owned files
#                  used for: upgrading an existing install
#   overwrite    — replace all Rig-owned files; back up originals
#                  used for: repair/reset
#   interactive  — ask per file (Custom path only)
#   skip         — skip all existing files (Custom path, or --strategy flag)
#
# The "merge" strategy name is kept internally for backward compat with
# --strategy merge. It is not shown in the intent menu.
#
# _SKIP_COMPONENT_SELECTION: set to true for intents 1–4 (install all components).
# Component selection is only shown for intent 5 (Custom).
_SKIP_COMPONENT_SELECTION=false

if [[ -n "$_FLAG_STRATEGY" ]]; then
  # Non-interactive: --strategy flag bypasses the intent menu entirely.
  case "$_FLAG_STRATEGY" in
    interactive|skip|overwrite|merge|upgrade)
      COLLISION_STRATEGY="$_FLAG_STRATEGY"
      ;;
    *)
      warn "Unknown --strategy value '${_FLAG_STRATEGY}' — defaulting to interactive."
      COLLISION_STRATEGY="interactive"
      ;;
  esac
  _SKIP_COMPONENT_SELECTION=true
else
  echo "What are you doing?"
  echo ""
  echo "  1) First install  — set up The Rig on this machine for the first time"
  echo "                      (installs global layer + scaffolds a project)"
  echo "  2) New project    — scaffold The Rig into a project"
  echo "                      (global layer already installed)"
  echo "  3) Upgrade        — update The Rig in a project that already has it"
  echo "                      (updates hooks, commands, and processes; preserves your files)"
  echo "  4) Repair         — overwrite all Rig-owned files and start fresh"
  echo "                      (backs up originals to .rig-backup/)"
  echo "  5) Custom         — full control over layers, strategy, and components"
  echo ""
  read -r -p "$(echo -e "${BOLD}?${RESET} Choose [1/2/3/4/5] (default: 2): ")" intent_input
  intent_input="${intent_input:-2}"

  case "$intent_input" in
    1)
      # First install: global layer + project scaffold, skip existing files.
      # --global-only / --project-only flags still override if provided.
      [[ "$DO_PROJECT" == true ]] && DO_GLOBAL=true
      COLLISION_STRATEGY="merge"
      _SKIP_COMPONENT_SELECTION=true
      ;;
    2)
      # New project or drop-in: project layer only, preserve anything existing,
      # smart-merge settings.json so existing Claude Code commands aren't lost.
      DO_GLOBAL=false
      COLLISION_STRATEGY="merge"
      _SKIP_COMPONENT_SELECTION=true
      ;;
    3)
      # Upgrade: project + global layers, update Rig-owned files, preserve yours.
      DO_GLOBAL=true
      COLLISION_STRATEGY="upgrade"
      _SKIP_COMPONENT_SELECTION=true
      ;;
    4)
      # Repair: project layer only, overwrite all Rig-owned files.
      DO_GLOBAL=false
      COLLISION_STRATEGY="overwrite"
      _SKIP_COMPONENT_SELECTION=true
      ;;
    5)
      # Custom: full interactive flow — strategy and component selection both shown.
      echo ""
      echo "Collision strategy:"
      echo "  1) Interactive  — ask me for each file"
      echo "  2) Skip         — keep all existing files, only install new ones"
      echo "  3) Overwrite    — replace everything (backs up originals to .rig-backup/)"
      echo "  4) Merge        — smart-merge .claude/settings.json; skip everything else"
      echo "  5) Upgrade      — update Rig-owned files; skip user-owned; diff on custom"
      echo ""
      read -r -p "$(echo -e "${BOLD}?${RESET} Choose strategy [1/2/3/4/5] (default: 2): ")" strategy_input
      strategy_input="${strategy_input:-2}"
      case "$strategy_input" in
        1) COLLISION_STRATEGY="interactive" ;;
        2) COLLISION_STRATEGY="skip" ;;
        3) COLLISION_STRATEGY="overwrite" ;;
        4) COLLISION_STRATEGY="merge" ;;
        5) COLLISION_STRATEGY="upgrade" ;;
        *)
          warn "Invalid choice — defaulting to Skip."
          COLLISION_STRATEGY="skip"
          ;;
      esac
      _SKIP_COMPONENT_SELECTION=false
      ;;
    *)
      warn "Invalid choice — defaulting to New project (2)."
      DO_GLOBAL=false
      COLLISION_STRATEGY="merge"
      _SKIP_COMPONENT_SELECTION=true
      ;;
  esac
fi

echo ""
info "Strategy: ${COLLISION_STRATEGY}"
echo ""

# ── BACKUP HELPER ─────────────────────────────────────────────────────────────
# Used by overwrite strategy. In stealth/external mode, backs up to
# $EXTERNAL_RIG_DIR/backups/<timestamp>/ so no traces land in the project repo.
# Otherwise backs up to <target>/.rig-backup/<timestamp>/
BACKUP_DIR=""
BACKUP_TS="$(date +%Y%m%d_%H%M%S)"

init_backup_dir() {
  local base="$1"
  if [[ ( "$RIG_TRACKING" == "stealth" || "$RIG_TRACKING" == "external" ) && -n "$EXTERNAL_RIG_DIR" ]]; then
    BACKUP_DIR="${EXTERNAL_RIG_DIR}/backups/${BACKUP_TS}"
  else
    BACKUP_DIR="${base}/.rig-backup/${BACKUP_TS}"
  fi
  mkdir -p "$BACKUP_DIR"
}

backup_file() {
  local src="$1"
  local base="$2"
  if [[ -z "$BACKUP_DIR" ]]; then init_backup_dir "$base"; fi
  local rel="${src#$base/}"
  local dest="${BACKUP_DIR}/${rel}"
  mkdir -p "$(dirname "$dest")"
  cp "$src" "$dest"
}

# ── SMART MERGE: .claude/settings.json ───────────────────────────────────────
# Merges The Rig's hooks into an existing settings.json without duplicating
# any hook that already has the same command string.
# Requires Python 3 (guaranteed on macOS/Linux).
merge_settings_json() {
  local existing="$1"   # path to the existing settings.json
  local incoming="$2"   # path to The Rig's settings.json (with [REPO_ROOT] already substituted)
  local output="$3"     # where to write the merged result

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found — cannot merge settings.json. Skipping."
    return 1
  fi

  python3 - "$existing" "$incoming" "$output" << 'PYEOF'
import json, sys

existing_path, incoming_path, output_path = sys.argv[1], sys.argv[2], sys.argv[3]

with open(existing_path) as f:
    existing = json.load(f)
with open(incoming_path) as f:
    incoming = json.load(f)

existing.setdefault("hooks", {})

for event, incoming_hooks in incoming.get("hooks", {}).items():
    existing.setdefault("hooks", {}).setdefault(event, [])
    # Collect the command strings already registered for this event
    existing_commands = set()
    for entry in existing["hooks"][event]:
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if cmd:
                existing_commands.add(cmd)  # rig-debug-ok
    # Append incoming hooks whose command isn't already present
    for entry in incoming_hooks:
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if cmd not in existing_commands:
                existing["hooks"][event].append(entry)
                existing_commands.add(cmd)  # rig-debug-ok
                break  # each entry is a unit; add it once

with open(output_path, "w") as f:
    json.dump(existing, f, indent=2)
    f.write("\n")
PYEOF
}

# ── COPY FILE (respects collision strategy) ───────────────────────────────────
# copy_file <src> <dest> [base_dir] [rel]
#
# base_dir  used for backup paths in overwrite/upgrade mode
# rel       relative path of this file (e.g. ".claude/hooks/pre-tool.sh")
#           used for manifest tracking and is_rig_owned() classification
copy_file() {
  local src="$1"
  local dest="$2"
  local base="${3:-}"
  local rel="${4:-}"
  local dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir"

  if [[ ! -f "$dest" ]]; then
    # No collision — always install
    cp "$src" "$dest"
    success "Created ${dest#${base}/}"
    # Record ALL files in the manifest (not just Rig-owned) so the Upgrade
    # strategy can later detect whether any file has been customized.
    # settings.json is excluded — it's always smart-merged, not hash-tracked.
    if [[ -n "$rel" && "$(basename "$rel")" != "settings.json" ]]; then
      write_manifest_entry "$(sha256_file "$dest")" "$rel"
    fi
    return
  fi

  # File exists — apply strategy
  case "$COLLISION_STRATEGY" in
    interactive)
      if confirm "Overwrite existing: ${dest#${base}/}?"; then
        cp "$src" "$dest"
        success "Updated ${dest#${base}/}"
        if [[ -n "$rel" && "$(basename "$rel")" != "settings.json" ]]; then
          write_manifest_entry "$(sha256_file "$dest")" "$rel"
        fi
      else
        info "Skipped ${dest#${base}/}"
      fi
      ;;
    skip)
      info "Skipped (exists): ${dest#${base}/}"
      ;;
    overwrite)
      # For user-owned files that have been customized since install:
      # warn and require confirmation before overwriting.
      if [[ -n "$rel" ]] && ! is_rig_owned "$rel" && [[ "$(basename "$rel")" != "settings.json" ]]; then
        local _dest_hash _manifest_hash _src_hash
        _dest_hash="$(sha256_file "$dest")"
        _src_hash="$(sha256_file "$src")"
        _manifest_hash="$(read_manifest_hash "$rel")"
        if [[ -n "$_manifest_hash" && "$_dest_hash" != "$_manifest_hash" && "$_dest_hash" != "$_src_hash" ]]; then
          echo ""
          warn "User-modified file: ${rel}"
          echo "  Your version differs from what The Rig originally installed."
          echo "  A backup will be saved to .rig-backup/ before overwriting."
          echo ""
          if ! confirm "Overwrite ${rel} with the new template?" "n"; then
            info "Skipped (kept your version): ${rel}"
            return
          fi
        fi
      fi
      if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
      cp "$src" "$dest"
      success "Overwrote ${dest#${base}/}"
      if [[ -n "$rel" && "$(basename "$rel")" != "settings.json" ]]; then
        write_manifest_entry "$(sha256_file "$dest")" "$rel"
      fi
      ;;
    merge)
      # settings.json gets special treatment; everything else is skipped
      if [[ "$(basename "$dest")" == "settings.json" && "$dest" == *".claude/settings.json" ]]; then
        local tmp_merged tmp_src_subst abs_target escaped_target
        tmp_merged="$(mktemp /tmp/rig-settings-merged-XXXXXX.json)"
        # Substitute [REPO_ROOT] in a temp copy of the incoming template before
        # merging, so dedup can compare identical command strings (not template
        # placeholders vs real paths).
        tmp_src_subst="$(mktemp /tmp/rig-settings-src-XXXXXX.json)"
        abs_target="$(cd "$TARGET" && pwd)"
        escaped_target="${abs_target//\//\\/}"
        sed "s/\\[REPO_ROOT\\]/${escaped_target}/g" "$src" > "$tmp_src_subst"
        if merge_settings_json "$dest" "$tmp_src_subst" "$tmp_merged"; then
          cp "$tmp_merged" "$dest"
          success "Merged .claude/settings.json"
        else
          info "Skipped settings.json (merge failed — see warning above)"
        fi
        rm -f "$tmp_merged" "$tmp_src_subst"
      else
        info "Skipped (exists): ${dest#${base}/}"
      fi
      ;;
    upgrade)
      _copy_file_upgrade "$src" "$dest" "$base" "$rel"
      ;;
  esac
}

# ── UPGRADE STRATEGY HANDLER ──────────────────────────────────────────────────
# Separated for readability. Called by copy_file() when COLLISION_STRATEGY=upgrade.
#
# Decision tree for a file that already exists at $dest:
#
#   settings.json       → always smart-merge (same as "merge" strategy)
#   All other files (both Rig-owned and user-owned):
#     dest == src       → already up to date, skip
#     dest == manifest  → unmodified since install → overwrite silently (with backup)
#     dest != manifest  → user has customized it  → show diff, prompt o/s/d
#     no manifest entry → first upgrade run → overwrite silently (with backup)
#
# The manifest now tracks all files (not just Rig-owned), so a user-owned file
# like CLAUDE.md that was never customized will be updated automatically, while
# one the user has edited will prompt for review — the same logic for both.
#
# SHA256 unavailable: falls back to byte-level cmp(1). If files differ and
# sha256 is absent, prompts without a diff (can't reliably detect customization).
_copy_file_upgrade() {
  local src="$1"
  local dest="$2"
  local base="${3:-}"
  local rel="${4:-}"

  # ── settings.json: always smart-merge ──────────────────────────────────────
  if [[ "$(basename "$dest")" == "settings.json" && "$dest" == *".claude/settings.json" ]]; then
    local tmp_merged tmp_src_subst abs_target escaped_target
    tmp_merged="$(mktemp /tmp/rig-settings-merged-XXXXXX.json)"
    # Substitute [REPO_ROOT] before merging so dedup compares real paths,
    # not template placeholders vs already-substituted existing commands.
    tmp_src_subst="$(mktemp /tmp/rig-settings-src-XXXXXX.json)"
    abs_target="$(cd "$TARGET" && pwd)"
    escaped_target="${abs_target//\//\\/}"
    sed "s/\\[REPO_ROOT\\]/${escaped_target}/g" "$src" > "$tmp_src_subst"
    if merge_settings_json "$dest" "$tmp_src_subst" "$tmp_merged"; then
      cp "$tmp_merged" "$dest"
      success "Merged .claude/settings.json"
    else
      info "Skipped settings.json (merge failed — see warning above)"
    fi
    rm -f "$tmp_merged" "$tmp_src_subst"
    return
  fi

  # ── Manifest-aware handling (applies to all files) ─────────────────────────
  local new_hash dest_hash manifest_hash
  new_hash="$(sha256_file "$src")"
  dest_hash="$(sha256_file "$dest")"

  # Handle SHA256 unavailable: fall back to byte-level comparison
  if [[ -z "$new_hash" ]]; then
    if cmp -s "$src" "$dest"; then
      info "Up to date: ${rel}"
    else
      warn "sha256 unavailable — cannot detect customizations in: ${rel}"
      if confirm "Overwrite ${rel} with new version?" "y"; then
        if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
        cp "$src" "$dest"
        success "Updated: ${rel}"
      else
        info "Skipped: ${rel}"
      fi
    fi
    return
  fi

  # Already at the new version — nothing to do
  if [[ "$dest_hash" == "$new_hash" ]]; then
    info "Up to date: ${rel}"
    return
  fi

  manifest_hash="$(read_manifest_hash "$rel")"

  if [[ -z "$manifest_hash" ]]; then
    # No manifest entry. Two cases:
    #   Rig-owned:  first upgrade before manifest tracking existed → safe to overwrite.
    #   User-owned: never tracked (e.g. CLAUDE.md, PROJECT_BRIEF.md, memory files).
    #               We can't tell if the user customized it, so skip safely.
    if is_rig_owned "$rel"; then
      if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
      cp "$src" "$dest"
      success "Updated: ${rel}"
      write_manifest_entry "$new_hash" "$rel"
    else
      info "Skipped (user-owned, no prior manifest entry): ${rel}"
      # Record the current hash so future upgrades can detect customizations.
      write_manifest_entry "$dest_hash" "$rel"
    fi
  elif [[ "$dest_hash" == "$manifest_hash" ]]; then
    # Matches manifest → unmodified since install. Safe to overwrite.
    if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
    cp "$src" "$dest"
    success "Updated: ${rel}"
    write_manifest_entry "$new_hash" "$rel"
  else
    # dest_hash differs from manifest_hash — user has customized this file.
    # Show what changed and ask before overwriting.
    echo ""
    warn "Customized file detected: ${rel}"
    echo "  Your version differs from what The Rig originally installed."
    echo "  The new Rig version also modifies this file."
    echo ""
    # Non-interactive (CI / piped stdin): skip without prompting.
    if [[ ! -t 0 ]]; then
      info "Non-interactive mode — skipping customized file: ${rel}"
      info "Run the installer interactively to review and update this file."
      return
    fi
    local choice
    while true; do
      read -r -p "$(echo -e "  ${BOLD}?${RESET} (o)verwrite  (s)kip  (d)iff  [o/s/d]: ")" choice
      case "${choice:-}" in
        o|O)
          if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
          cp "$src" "$dest"
          success "Updated (overwritten): ${rel}"
          write_manifest_entry "$new_hash" "$rel"
          break
          ;;
        s|S)
          info "Skipped (kept your version): ${rel}"
          break
          ;;
        d|D)
          echo ""
          echo "  ── diff: your version (a) → new Rig version (b) ──"
          diff -u "$dest" "$src" | head -100 || true
          echo "  ── end diff ──"
          echo ""
          ;;
        *)
          echo "  Please enter o, s, or d."
          ;;
      esac
    done
  fi
}

# ── GLOBAL UPGRADE HANDLER ───────────────────────────────────────────────────
# Like _copy_file_upgrade() but for global-layer files (~/.claude/).
# All files passed here are treated as Rig-owned — the caller never passes
# PROFILE.md (personal data that must never be auto-overwritten).
# Caller sets MANIFEST_FILE="$GLOBAL_MANIFEST_FILE" before calling.
_copy_global_file_upgrade() {
  local src="$1"
  local dest="$2"
  local base="${3:-}"
  local rel="${4:-}"

  if [[ ! -f "$dest" ]]; then
    mkdir -p "$(dirname "$dest")"
    cp "$src" "$dest"
    success "Created: ${rel}"
    write_manifest_entry "$(sha256_file "$dest")" "$rel"
    return
  fi

  local new_hash dest_hash manifest_hash
  new_hash="$(sha256_file "$src")"
  dest_hash="$(sha256_file "$dest")"

  if [[ -z "$new_hash" ]]; then
    if cmp -s "$src" "$dest"; then
      info "Up to date: ${rel}"
    else
      warn "sha256 unavailable — cannot detect customizations in: ${rel}"
    fi
    return
  fi

  if [[ "$dest_hash" == "$new_hash" ]]; then
    info "Up to date: ${rel}"
    return
  fi

  manifest_hash="$(read_manifest_hash "$rel")"

  if [[ -z "$manifest_hash" || "$dest_hash" == "$manifest_hash" ]]; then
    # No prior manifest entry (first upgrade — treat as unmodified) OR
    # hash matches manifest (unmodified since install) → safe to auto-update.
    if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
    cp "$src" "$dest"
    success "Updated: ${rel}"
    write_manifest_entry "$new_hash" "$rel"
  else
    # dest_hash differs from manifest_hash — user has customized this file.
    echo ""
    warn "Customized file detected: ${rel}"
    echo "  Your version differs from what The Rig originally installed."
    echo "  The new Rig version also modifies this file."
    echo ""
    if [[ ! -t 0 ]]; then
      info "Non-interactive mode — skipping customized file: ${rel}"
      info "Run the installer interactively to review and update this file."
      return
    fi
    local choice
    while true; do
      read -r -p "$(echo -e "  ${BOLD}?${RESET} (o)verwrite  (s)kip  (d)iff  [o/s/d]: ")" choice
      case "${choice:-}" in
        o|O)
          if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
          cp "$src" "$dest"
          success "Updated (overwritten): ${rel}"
          write_manifest_entry "$new_hash" "$rel"
          break ;;
        s|S)
          info "Skipped (kept your version): ${rel}"
          break ;;
        d|D)
          echo ""
          echo "  ── diff: your version (a) → new Rig version (b) ──"
          diff -u "$dest" "$src" | head -100 || true
          echo "  ── end diff ──"
          echo "" ;;
        *) echo "  Please enter o, s, or d." ;;
      esac
    done
  fi
}

# ── GLOBAL LAYER ─────────────────────────────────────────────────────────────
if [[ "$DO_GLOBAL" == true ]]; then
  bold "── Global layer (~/.claude/) ──"
  echo ""

  CLAUDE_DIR="$HOME/.claude"
  SKILLS_DIR="$CLAUDE_DIR/skills"
  DEST_CLAUDE="$CLAUDE_DIR/CLAUDE.md"

  # Point manifest helpers at the global manifest for this section.
  _SAVED_MANIFEST_FILE="$MANIFEST_FILE"
  MANIFEST_FILE="$GLOBAL_MANIFEST_FILE"

  if [[ "$COLLISION_STRATEGY" == "upgrade" && -f "$DEST_CLAUDE" ]]; then
    # Upgrading an existing global install — extract profile path from the
    # installed CLAUDE.md instead of prompting (preserves their actual path).
    PROFILE_PATH=$(grep -oE '`[^`]+\.md`' "$DEST_CLAUDE" | head -1 | tr -d '`' 2>/dev/null || true)
    if [[ -z "$PROFILE_PATH" ]]; then
      PROFILE_PATH="$HOME/.your-ai-contexts/PROFILE.md"
      warn "Could not detect profile path from existing CLAUDE.md — using default: $PROFILE_PATH"
    else
      info "Detected profile path: $PROFILE_PATH"
    fi
    echo ""
  else
    # Fresh install — prompt for profile path
    DEFAULT_PROFILE_DIR="$HOME/.your-ai-contexts"
    ask "Where should your personal profile file live?"
    read -r -p "    Path [${DEFAULT_PROFILE_DIR}/PROFILE.md]: " PROFILE_PATH_INPUT
    PROFILE_PATH="${PROFILE_PATH_INPUT:-${DEFAULT_PROFILE_DIR}/PROFILE.md}"
    echo ""
    info "Installing to: $CLAUDE_DIR"
    info "Profile path:  $PROFILE_PATH"
    echo ""
  fi

  mkdir -p "$CLAUDE_DIR" "$SKILLS_DIR" "$(dirname "$PROFILE_PATH")"

  # ── CLAUDE.md ──────────────────────────────────────────────────────────────
  CLAUDE_TMP="$(mktemp)"
  sed "s|\\[PROFILE_PATH\\]|${PROFILE_PATH}|g" "$GLOBAL_TEMPLATES/CLAUDE.md" > "$CLAUDE_TMP"
  if [[ "$COLLISION_STRATEGY" == "upgrade" ]]; then
    _copy_global_file_upgrade "$CLAUDE_TMP" "$DEST_CLAUDE" "$CLAUDE_DIR" "CLAUDE.md"
  else
    copy_file "$CLAUDE_TMP" "$DEST_CLAUDE" "$CLAUDE_DIR" "CLAUDE.md"
  fi
  rm -f "$CLAUDE_TMP"

  # ── Skills ────────────────────────────────────────────────────────────────
  for skill_src in "$GLOBAL_TEMPLATES/skills/"*.md; do
    skill_name="$(basename "$skill_src")"
    skill_dest="$SKILLS_DIR/$skill_name"
    if [[ "$COLLISION_STRATEGY" == "upgrade" ]]; then
      _copy_global_file_upgrade "$skill_src" "$skill_dest" "$SKILLS_DIR" "skills/$skill_name"
    else
      copy_file "$skill_src" "$skill_dest" "$SKILLS_DIR" "skills/$skill_name"
    fi
  done

  # ── Profile ───────────────────────────────────────────────────────────────
  # Never touched on upgrade — personal data. Only created on fresh install.
  if [[ "$COLLISION_STRATEGY" != "upgrade" ]]; then
    if [[ -f "$PROFILE_PATH" ]]; then
      warn "$PROFILE_PATH already exists — skipping (personal data, never auto-overwritten)."
      info "To regenerate the template: cp $GLOBAL_TEMPLATES/PROFILE.md.example $PROFILE_PATH"
    else
      cp "$GLOBAL_TEMPLATES/PROFILE.md.example" "$PROFILE_PATH"
      success "Created $PROFILE_PATH"
      echo ""
      warn "ACTION REQUIRED: Fill in your personal profile at:"
      echo "      $PROFILE_PATH"
      echo "  The agent loads this file at every session start."
    fi
  fi

  # Restore manifest pointer
  MANIFEST_FILE="$_SAVED_MANIFEST_FILE"

  echo ""
fi

# Reset backup dir between layers so each layer uses its own base path.
BACKUP_DIR=""

# ── PROJECT LAYER ─────────────────────────────────────────────────────────────
if [[ "$DO_PROJECT" == true ]]; then
  bold "── Project layer ──"
  echo ""

  # Determine target directory
  if [[ -n "$_FLAG_TARGET" ]]; then
    TARGET="$_FLAG_TARGET"
  else
    DEFAULT_TARGET="$(pwd)"
    ask "Target project directory?"
    read -r -p "    Path [${DEFAULT_TARGET}]: " TARGET_INPUT
    TARGET="${TARGET_INPUT:-$DEFAULT_TARGET}"
  fi

  if [[ ! -d "$TARGET" ]]; then
    error "Directory does not exist: $TARGET"
    exit 1
  fi

  if [[ ! -d "$TARGET/.git" ]]; then
    warn "$TARGET does not appear to be a git repository."
    if [[ -n "$_FLAG_TARGET" ]]; then
      warn "Continuing non-interactively (--target provided)."
    elif ! confirm "Continue anyway?"; then
      exit 0
    fi
  fi

  if [[ -n "$_FLAG_PROJECT_NAME" ]]; then
    PROJECT_NAME="$_FLAG_PROJECT_NAME"
  else
    DEFAULT_PROJECT_NAME="$(basename "$TARGET")"
    if [[ -t 0 ]]; then
      ask "Project name (used in CLAUDE.md)?"
      read -r -p "    Name [${DEFAULT_PROJECT_NAME}]: " PROJECT_NAME_INPUT
      PROJECT_NAME="${PROJECT_NAME_INPUT:-$DEFAULT_PROJECT_NAME}"
    else
      PROJECT_NAME="$DEFAULT_PROJECT_NAME"
    fi
  fi

  # Sanitize project name for safe sed substitution.
  # Strip characters that are sed metacharacters or shell-special in this context.
  # Allow: letters, digits, spaces, hyphens, underscores, periods.
  PROJECT_NAME="$(echo "$PROJECT_NAME" | tr -dc 'A-Za-z0-9 ._-')"
  if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(basename "$TARGET")"
    warn "Project name contained only invalid characters — using directory name: $PROJECT_NAME"
  fi

  echo ""

  # ── BASE BRANCH ──────────────────────────────────────────────────────────────
  # The main integration branch for this repo (main, master, integration, etc.).
  # Substituted into workflow examples in CLAUDE.md, processes, and commands.
  if [[ -n "$_FLAG_BASE_BRANCH" ]]; then
    BASE_BRANCH="$_FLAG_BASE_BRANCH"
  else
    # Try to auto-detect from git
    _DETECTED_BASE=""
    if command -v git >/dev/null 2>&1 && git -C "$TARGET" rev-parse --git-dir >/dev/null 2>&1; then
      # git symbolic-ref exits 128 when there's no remote; pipefail would propagate that.
      _DETECTED_BASE="$(git -C "$TARGET" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's|refs/remotes/origin/||')" || true
    fi
    _DEFAULT_BASE="${_DETECTED_BASE:-main}"
    # Only prompt when stdin is a TTY (skip in non-interactive/CI contexts).
    if [[ -t 0 ]]; then
      ask "What is the base branch for this repo?"
      read -r -p "    Branch [${_DEFAULT_BASE}]: " _BASE_INPUT
      BASE_BRANCH="${_BASE_INPUT:-$_DEFAULT_BASE}"
    else
      BASE_BRANCH="$_DEFAULT_BASE"
    fi
  fi
  # Sanitize: letters, digits, hyphens, underscores, dots only
  BASE_BRANCH="$(echo "$BASE_BRANCH" | tr -dc 'A-Za-z0-9._-')"
  if [[ -z "$BASE_BRANCH" ]]; then
    BASE_BRANCH="main"
    warn "Invalid base branch name — defaulting to 'main'"
  fi
  info "Base branch: $BASE_BRANCH"
  echo ""

  # ── GIT TRACKING FOR .rig/ ────────────────────────────────────────────────
  # How should .rig/ appear (or not appear) in git?
  # --tracking flag takes precedence; --rig-dir alone implies external (backward-compat).
  # When neither is set, show the interactive prompt — including when --target is provided.
  RIG_TRACKING="repo"   # default: committed with the project
  RIGPATH_FILE=""       # absolute path to .rigpath (set if external or stealth mode)

  if [[ -n "$_FLAG_TRACKING" ]]; then
    # --tracking flag: validate and apply without prompting
    case "$_FLAG_TRACKING" in
      repo)
        RIG_TRACKING="repo"
        ;;
      local)
        RIG_TRACKING="exclude"
        ;;
      external)
        if [[ -z "$EXTERNAL_RIG_DIR" ]]; then
          error "--tracking external requires --rig-dir <path>"
          exit 1
        fi
        RIG_TRACKING="external"
        ;;
      stealth)
        RIG_TRACKING="stealth"
        if [[ -z "$EXTERNAL_RIG_DIR" ]]; then
          EXTERNAL_RIG_DIR="${HOME}/.rig/projects/${PROJECT_NAME}"
        fi
        ;;
      *)
        error "Invalid --tracking value '${_FLAG_TRACKING}'. Valid: repo, local, external, stealth"
        exit 1
        ;;
    esac
  elif [[ -n "$EXTERNAL_RIG_DIR" ]]; then
    # --rig-dir was provided (without --tracking): backward-compatible external mode.
    RIG_TRACKING="external"
  elif [[ -f "$TARGET/.rigpath" ]]; then
    # Existing .rigpath detected — auto-detect tracking mode without prompting.
    # Avoids writing .rig/ files to the wrong location when --tracking is omitted.
    EXTERNAL_RIG_DIR=$(tr -d '[:space:]' < "$TARGET/.rigpath")
    if [[ "$EXTERNAL_RIG_DIR" == "${HOME}/.rig/projects/"* ]]; then
      RIG_TRACKING="stealth"
    else
      RIG_TRACKING="external"
    fi
    info "Detected .rigpath — using ${RIG_TRACKING} mode: $EXTERNAL_RIG_DIR"
  else
    echo "How should .rig/ be tracked in git?"
    echo ""
    echo "  1) In the repo      — committed with the project (default, recommended for solo projects)"
    echo "  2) Local only       — added to .git/info/exclude; invisible to teammates, no .gitignore change"
    echo "  3) External         — install .rig/ to a path outside this repo entirely"
    echo "  4) Stealth          — zero Rig traces in git: all Rig files excluded or external;"
    echo "                        git hooks go to .git/hooks/ (no Husky required)"
    echo "                        Use for multi-contributor repos where teammates must not see Rig files."
    echo ""
    read -r -p "$(echo -e "${BOLD}?${RESET} Choose [1/2/3/4] (default: 1): ")" rig_tracking_input || true
    rig_tracking_input="${rig_tracking_input:-1}"

    case "$rig_tracking_input" in
      1) RIG_TRACKING="repo" ;;
      2) RIG_TRACKING="exclude" ;;
      3) RIG_TRACKING="external"
         ask "External path for .rig/ files?"
         read -r -p "    Path: " EXTERNAL_RIG_DIR || true
         if [[ -z "$EXTERNAL_RIG_DIR" ]]; then
           error "External path cannot be empty."
           exit 1
         fi
         ;;
      4) RIG_TRACKING="stealth"
         # Default the external .rig/ path — user can override
         _STEALTH_DEFAULT_RIG="${HOME}/.rig/projects/${PROJECT_NAME}"
         echo ""
         echo "  Stealth mode: all Rig artifacts will be excluded from git tracking."
         echo "  .rig/ files will be stored outside this repo."
         read -r -p "$(echo -e "  ${BOLD}?${RESET} External .rig/ path (default: ${_STEALTH_DEFAULT_RIG}): ")" EXTERNAL_RIG_DIR || true
         EXTERNAL_RIG_DIR="${EXTERNAL_RIG_DIR:-$_STEALTH_DEFAULT_RIG}"
         ;;
      *)
        warn "Invalid choice — defaulting to 'In the repo'."
        RIG_TRACKING="repo"
        ;;
    esac
  fi

  # Resolve and validate the external path (if applicable)
  if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
    # Expand ~ and resolve to absolute path
    EXTERNAL_RIG_DIR="${EXTERNAL_RIG_DIR/#\~/$HOME}"
    mkdir -p "$EXTERNAL_RIG_DIR" || { error "Cannot create directory: $EXTERNAL_RIG_DIR"; exit 1; }
    EXTERNAL_RIG_DIR="$(cd "$EXTERNAL_RIG_DIR" && pwd)"
    RIGPATH_FILE="$TARGET/.rigpath"
    info "External .rig/ location: $EXTERNAL_RIG_DIR"
  fi

  # ── Manifest path ─────────────────────────────────────────────────────────
  # Stored in .rig/memory/ so it lives alongside the other memory files.
  # For external .rig/ installs, it follows .rig/ to the external directory.
  # The manifest is committed to the repo (not gitignored) — see memory/.gitignore.
  if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
    MANIFEST_FILE="$EXTERNAL_RIG_DIR/memory/.rig-manifest"
  else
    MANIFEST_FILE="$TARGET/.rig/memory/.rig-manifest"
  fi

  echo ""

  # ── COMPONENT SELECTION ───────────────────────────────────────────────────
  # Skipped for intents 1–4 and when --target flag is provided.
  # Only shown for Custom (intent 5) when the user hasn't bypassed interactivity.
  if [[ "$_SKIP_COMPONENT_SELECTION" == true || -n "$_FLAG_TARGET" ]]; then
    component_choice="a"
  else
    echo "Which components do you want to install?"
    echo ""
    echo "  a) All (recommended)"
    echo "  b) Let me choose"
    echo ""
    read -r -p "$(echo -e "${BOLD}?${RESET} Choose [a/b] (default: a): ")" component_choice
    component_choice="${component_choice:-a}"
  fi

  # Component flags (all default to true)
  INSTALL_CLAUDE_MD=true
  INSTALL_MEMORY=true
  INSTALL_TASKS=true
  INSTALL_PROCESSES=true
  INSTALL_RULES=true
  INSTALL_CLAUDE_HOOKS=true
  INSTALL_COMMANDS=true
  INSTALL_GIT_HOOKS=true
  INSTALL_GITHUB=true
  INSTALL_PROJECT_BRIEF=true

  if [[ "$component_choice" == "b" ]]; then
    # Show context-aware paths for .rig/ components
    RIG_LABEL=".rig/"
    if [[ "$RIG_TRACKING" == "external" ]]; then
      RIG_LABEL="${EXTERNAL_RIG_DIR}/"
    fi
    echo ""
    confirm "Install CLAUDE.md (project brain template)?" "y"     && INSTALL_CLAUDE_MD=true    || INSTALL_CLAUDE_MD=false
    confirm "Install memory system (${RIG_LABEL}memory/, PROGRESS, ERRORS)?" "y" && INSTALL_MEMORY=true   || INSTALL_MEMORY=false
    confirm "Install task lifecycle (${RIG_LABEL}tasks/backlog, active, done)?" "y" && INSTALL_TASKS=true  || INSTALL_TASKS=false
    confirm "Install process workflows (${RIG_LABEL}processes/)?" "y"  && INSTALL_PROCESSES=true   || INSTALL_PROCESSES=false
    confirm "Install rules (${RIG_LABEL}rules/)?" "y"                  && INSTALL_RULES=true        || INSTALL_RULES=false
    confirm "Install Claude Code hooks (.claude/hooks/, settings.json)?" "y" && INSTALL_CLAUDE_HOOKS=true || INSTALL_CLAUDE_HOOKS=false
    confirm "Install slash commands (.claude/commands/)?" "y"      && INSTALL_COMMANDS=true    || INSTALL_COMMANDS=false
    confirm "Install git hooks (.husky/, .gitleaks.toml)?" "y"     && INSTALL_GIT_HOOKS=true   || INSTALL_GIT_HOOKS=false
    confirm "Install GitHub templates (.github/)?" "y"             && INSTALL_GITHUB=true       || INSTALL_GITHUB=false
    confirm "Install PROJECT_BRIEF.md template?" "y"               && INSTALL_PROJECT_BRIEF=true || INSTALL_PROJECT_BRIEF=false
    echo ""
  fi

  echo ""
  info "Scaffolding into: $TARGET"
  info "Project name:     $PROJECT_NAME"
  if [[ "$RIG_TRACKING" == "external" ]]; then
    info ".rig/ location:   $EXTERNAL_RIG_DIR (external)"
  elif [[ "$RIG_TRACKING" == "exclude" ]]; then
    info ".rig/ tracking:   local only (.git/info/exclude)"
  elif [[ "$RIG_TRACKING" == "stealth" ]]; then
    info ".rig/ location:   $EXTERNAL_RIG_DIR (stealth — all Rig files excluded from git)"
  fi
  echo ""

  # ── FILE → COMPONENT MAPPING ──────────────────────────────────────────────
  # Returns 0 (install) or 1 (skip) for a given relative path.
  should_install_file() {
    local rel="$1"
    case "$rel" in
      CLAUDE.md)                           [[ "$INSTALL_CLAUDE_MD" == true ]]      ;;
      PROJECT_BRIEF.md)                    [[ "$INSTALL_PROJECT_BRIEF" == true ]]  ;;
      .rig/memory/*)                       [[ "$INSTALL_MEMORY" == true ]]         ;;
      .rig/tasks/*)                        [[ "$INSTALL_TASKS" == true ]]          ;;
      .rig/processes/*)                    [[ "$INSTALL_PROCESSES" == true ]]      ;;
      .rig/rules/*)                        [[ "$INSTALL_RULES" == true ]]          ;;
      .claude/hooks/*|.claude/settings*)   [[ "$INSTALL_CLAUDE_HOOKS" == true ]]   ;;
      .claude/commands/*)                  [[ "$INSTALL_COMMANDS" == true ]]       ;;
      .husky/*|.gitleaks.toml)             [[ "$INSTALL_GIT_HOOKS" == true ]]      ;;
      .github/*)                           [[ "$INSTALL_GITHUB" == true ]]         ;;
      *)                                   return 0 ;;  # install unknown files by default
    esac
  }

  # ── COPY PROJECT FILES ────────────────────────────────────────────────────
  while IFS= read -r -d '' src_file; do
    rel="${src_file#$PROJECT_TEMPLATES/}"
    if ! should_install_file "$rel"; then
      info "Component not selected — skipped: $rel"
      continue
    fi

    # Route .rig/ files to the external directory when applicable.
    # In stealth mode: skip .husky/ entirely (hooks go to .git/hooks/ later).
    # Always pass $rel (the template-relative path) as the 4th arg so
    # copy_file() can classify the file and update the manifest.
    if [[ "$RIG_TRACKING" == "stealth" && "$rel" == .husky/* ]]; then
      info "Stealth mode — deferring to .git/hooks/: $rel"
      continue
    elif [[ ( "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ) && "$rel" == .rig/* ]]; then
      rig_rel="${rel#.rig/}"
      dest_file="$EXTERNAL_RIG_DIR/$rig_rel"
      copy_file "$src_file" "$dest_file" "$EXTERNAL_RIG_DIR" "$rel"
    else
      dest_file="$TARGET/$rel"
      copy_file "$src_file" "$dest_file" "$TARGET" "$rel"
    fi
  done < <(find "$PROJECT_TEMPLATES" -type f -print0)

  # ── WRITE INSTALLER VERSION INTO .rig/VERSION ─────────────────────────────
  # Always write the running installer's own version, overriding whatever the
  # static template file contains. This prevents drift when the template copy
  # lags behind the root VERSION bump. The manifest entry is upserted so the
  # upgrade strategy continues to detect user customizations correctly.
  _RIG_VER_DEST=""
  if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
    _RIG_VER_DEST="$EXTERNAL_RIG_DIR/VERSION"
  else
    _RIG_VER_DEST="$TARGET/.rig/VERSION"
  fi
  if [[ -n "$_RIG_VER_DEST" && -d "$(dirname "$_RIG_VER_DEST")" ]]; then
    echo "$INSTALLER_VERSION" > "$_RIG_VER_DEST"
    write_manifest_entry "$(sha256_file "$_RIG_VER_DEST")" ".rig/VERSION"
  fi

  # ── SUBSTITUTE PLACEHOLDERS ───────────────────────────────────────────────
  TARGET_ABS="$(cd "$TARGET" && pwd)"

  TARGET_CLAUDE="$TARGET/CLAUDE.md"
  if [[ -f "$TARGET_CLAUDE" ]]; then
    sed_inplace "s/\\[Project Name\\]/${PROJECT_NAME}/g" "$TARGET_CLAUDE"
    success "Substituted [Project Name] in CLAUDE.md"
  fi

  # Substitute [REPO_ROOT] in settings.json with the absolute project path.
  # This step runs after copy/merge to ensure the final file has the real path.
  TARGET_SETTINGS="$TARGET/.claude/settings.json"
  if [[ -f "$TARGET_SETTINGS" ]]; then
    ESCAPED_PATH="${TARGET_ABS//\//\\/}"
    sed_inplace "s/\\[REPO_ROOT\\]/${ESCAPED_PATH}/g" "$TARGET_SETTINGS"
    success "Substituted [REPO_ROOT] in .claude/settings.json → $TARGET_ABS"
  fi

  # Substitute [BASE_BRANCH] in CLAUDE.md, commands, and process files.
  # Covers both inline (.claude/commands/) and external (.rig/processes/) paths.
  _BASE_ESC="${BASE_BRANCH//\//\\/}"
  _subst_base_branch() {
    local f="$1"
    [[ -f "$f" ]] || return 0
    sed_inplace "s/\\[BASE_BRANCH\\]/${_BASE_ESC}/g" "$f"
  }
  _subst_base_branch "$TARGET/CLAUDE.md"
  _subst_base_branch "$TARGET/.claude/commands/ship.md"
  _subst_base_branch "$TARGET/.claude/commands/post-merge.md"
  # .rig/processes/ may be in-repo or external
  _TARGET_RIG_DIR="$TARGET/.rig"
  if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
    _TARGET_RIG_DIR="$EXTERNAL_RIG_DIR"
  fi
  _subst_base_branch "$_TARGET_RIG_DIR/processes/POST_MERGE_WORKFLOW.md"
  _subst_base_branch "$_TARGET_RIG_DIR/processes/SHIP_WORKFLOW.md"
  success "Substituted [BASE_BRANCH] → $BASE_BRANCH in workflow files"

  # ── EXTERNAL .rig/ — write .rigpath and update git excludes ──────────────
  if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
    # Write the pointer file so hooks can resolve RIG_DIR at runtime
    echo "$EXTERNAL_RIG_DIR" > "$RIGPATH_FILE"
    success "Created .rigpath → $EXTERNAL_RIG_DIR"

    # Exclude .rigpath from git tracking (per-clone, not shared via .gitignore)
    GIT_EXCLUDE="$TARGET/.git/info/exclude"
    if [[ -f "$GIT_EXCLUDE" ]]; then
      if ! grep -qF ".rigpath" "$GIT_EXCLUDE"; then
        echo ".rigpath" >> "$GIT_EXCLUDE"
        success "Added .rigpath to .git/info/exclude"
      else
        info ".rigpath already in .git/info/exclude"
      fi
    else
      warn ".git/info/exclude not found — add '.rigpath' to your .gitignore manually"
    fi

    # Update CLAUDE.md @imports to use absolute paths for the external .rig/ dir
    TARGET_CLAUDE="$TARGET/CLAUDE.md"
    if [[ -f "$TARGET_CLAUDE" ]]; then
      ESCAPED_EXT="${EXTERNAL_RIG_DIR//\//\\/}"
      sed_inplace "s|@\\.rig/|@${ESCAPED_EXT}/|g" "$TARGET_CLAUDE"
      # Also update the context-loading paths in the prose
      sed_inplace "s|\`.rig/memory/|\`${EXTERNAL_RIG_DIR}/memory/|g" "$TARGET_CLAUDE"
      sed_inplace "s|\`.rig/tasks/|\`${EXTERNAL_RIG_DIR}/tasks/|g" "$TARGET_CLAUDE"
      success "Updated CLAUDE.md to reference external .rig/ path"
    fi
  fi

  # ── LOCAL-ONLY: add .rig/ to .git/info/exclude ───────────────────────────
  if [[ "$RIG_TRACKING" == "exclude" ]]; then
    GIT_EXCLUDE="$TARGET/.git/info/exclude"
    if [[ -f "$GIT_EXCLUDE" ]]; then
      if ! grep -qF ".rig/" "$GIT_EXCLUDE"; then
        printf "\n# The Rig system files — local only, not shared with teammates\n.rig/\n" >> "$GIT_EXCLUDE"
        success "Added .rig/ to .git/info/exclude (local only — teammates won't see it)"
      else
        info ".rig/ already in .git/info/exclude"
      fi
    else
      warn ".git/info/exclude not found — add '.rig/' to your .gitignore manually"
    fi
  fi

  # ── STEALTH MODE: exclude all Rig artifacts + wire hooks to .git/hooks/ ──
  if [[ "$RIG_TRACKING" == "stealth" ]]; then
    GIT_EXCLUDE="$TARGET/.git/info/exclude"
    if [[ -f "$GIT_EXCLUDE" ]]; then
      # Helper: append entry only if not already present
      _stealth_exclude() {
        local entry="$1"
        if ! grep -qF "$entry" "$GIT_EXCLUDE"; then
          echo "$entry" >> "$GIT_EXCLUDE"
          success "Stealth: excluded $entry from git"
        else
          info "Stealth: $entry already in .git/info/exclude"
        fi
      }

      printf "\n# The Rig — stealth mode: all Rig artifacts excluded from git tracking\n" >> "$GIT_EXCLUDE"
      _stealth_exclude "CLAUDE.md"
      _stealth_exclude "PROJECT_BRIEF.md"
      _stealth_exclude ".claude/"
      _stealth_exclude ".github/"
      _stealth_exclude ".gitleaks.toml"
      _stealth_exclude "docs/features/README.md"
      _stealth_exclude ".rig-backup/"
      _stealth_exclude ".rig/"
      # .rigpath is already excluded by the external-mode block above
    else
      warn ".git/info/exclude not found — stealth exclusions could not be applied."
      warn "Add manually: CLAUDE.md, PROJECT_BRIEF.md, .claude/, .github/, .gitleaks.toml, docs/features/README.md, .rigpath"
    fi

    # Copy .husky/ hook scripts directly to .git/hooks/ (Husky-free, per-clone)
    GIT_HOOKS_DIR="$TARGET/.git/hooks"
    HUSKY_SRC="$PROJECT_TEMPLATES/.husky"
    if [[ "$SKIP_GIT_HOOKS" == true ]]; then
      info "Stealth: --skip-git-hooks set — skipping .git/hooks/ writes."
    else
      # Warn when the target project already manages hooks via Husky — the Rig
      # hooks written here may be overwritten silently by 'npm install'/'prepare'.
      if [[ -d "$TARGET/.husky" ]]; then
        warn "Stealth: .husky/ detected — project already manages git hooks."
        warn "  Rig hooks written to .git/hooks/ may be overwritten by 'npm install' or 'prepare'."
        warn "  Re-run with --skip-git-hooks to skip .git/hooks/ writes."
      fi
      if [[ -d "$HUSKY_SRC" && -d "$GIT_HOOKS_DIR" ]]; then
        for hook_src in "$HUSKY_SRC"/pre-commit "$HUSKY_SRC"/commit-msg \
                        "$HUSKY_SRC"/post-commit "$HUSKY_SRC"/post-merge \
                        "$HUSKY_SRC"/filter-commit-message-inplace.sh; do
          hook_name="$(basename "$hook_src")"
          hook_dest="$GIT_HOOKS_DIR/$hook_name"
          if [[ -f "$hook_src" ]]; then
            cp "$hook_src" "$hook_dest"
            chmod +x "$hook_dest"
            success "Stealth: installed $hook_name → .git/hooks/"
          fi
        done
      else
        warn "Stealth: .git/hooks/ not found — git hooks were not installed."
      fi
    fi
  fi

  # ── EXECUTABLE BITS ───────────────────────────────────────────────────────
  HUSKY_DIR="$TARGET/.husky"
  CLAUDE_HOOKS_DIR="$TARGET/.claude/hooks"

  if [[ -d "$HUSKY_DIR" ]]; then
    chmod +x "$HUSKY_DIR/"* 2>/dev/null || true
    success "Set executable bits on .husky/ hooks"
  fi

  if [[ -d "$CLAUDE_HOOKS_DIR" ]]; then
    chmod +x "$CLAUDE_HOOKS_DIR/"*.sh 2>/dev/null || true
    success "Set executable bits on .claude/hooks/ scripts"
  fi

  # ── HUSKY INITIALIZATION ──────────────────────────────────────────────────
  # Skipped in stealth mode — hooks are already wired to .git/hooks/ above.
  if [[ "$INSTALL_GIT_HOOKS" == true && "$RIG_TRACKING" != "stealth" ]]; then
    if [[ -f "$TARGET/package.json" ]]; then
      echo ""
      info "package.json detected."
      if confirm "Initialize Husky? (runs: npx husky install)"; then
        if command -v npx >/dev/null 2>&1; then
          if (cd "$TARGET" && npx husky install); then
            success "Husky initialized"
          else
            warn "Husky initialization failed — run it manually:"
            echo "    cd $TARGET && npx husky install"
            echo "  If you see a permission error on node_modules/.bin/husky:"
            echo "    chmod +x $TARGET/node_modules/.bin/husky"
          fi
        else
          warn "npx not found — run 'npx husky install' manually in $TARGET"
        fi
      fi
    else
      warn "No package.json found in $TARGET."
      echo "  Husky requires a package.json. To set it up later:"
      echo "    cd $TARGET && npm init -y && npm install --save-dev husky && npx husky install"
    fi
  fi

  # ── BACKUP REPORT ─────────────────────────────────────────────────────────
  if [[ -n "$BACKUP_DIR" && -d "$BACKUP_DIR" ]]; then
    echo ""
    info "Originals backed up to: $BACKUP_DIR"
  fi

  echo ""
fi

# ── GITLEAKS CHECK ────────────────────────────────────────────────────────────
echo ""
bold "── Checking dependencies ──"
echo ""

GITLEAKS_OK=false
if command -v gitleaks >/dev/null 2>&1; then
  GITLEAKS_OK=true
elif [[ -x "/usr/local/bin/gitleaks" || -x "/opt/homebrew/bin/gitleaks" ]]; then
  GITLEAKS_OK=true
fi

if [[ "$GITLEAKS_OK" == true ]]; then
  success "gitleaks is installed — secret scanning is active"
else
  warn "gitleaks is NOT installed — secret scanning will be skipped on commits"
  echo "  Install it: brew install gitleaks"
  echo "  Docs: https://github.com/gitleaks/gitleaks"
fi

# ── IN-PLACE CLEANUP ─────────────────────────────────────────────────────────
# If the installer was run from inside the target project directory (i.e. the user
# cloned The Rig directly into their project folder), offer to remove the Rig's
# own source files — they've been consumed by the installer and don't belong in
# the project.
#
# Files removed are Rig-specific repo files only. Scaffolded project files
# (CLAUDE.md, memory/, processes/, rules/, tasks/, .claude/, .husky/, etc.)
# are never touched.

if [[ "$DO_PROJECT" == true && -n "${TARGET_ABS:-}" ]]; then
  SCRIPT_ABS="$(cd "$SCRIPT_DIR" && pwd)"
  if [[ "$SCRIPT_ABS" == "$TARGET_ABS" ]]; then
    # Guard: if install.sh is committed in this repo, we're inside The Rig's own
    # source tree — skip cleanup to avoid deleting project source files.
    if ! git -C "$SCRIPT_ABS" ls-files --error-unmatch install.sh &>/dev/null 2>&1; then
      echo ""
      warn "The installer was run from inside the target project directory."
      echo "  The following The Rig source files are no longer needed in your project:"
      echo ""
      echo "    templates/     — scaffolding source (already consumed)"
      echo "    docs/          — The Rig's own architecture docs"
      echo "    CHANGELOG.md   — The Rig's changelog"
      echo "    install.sh     — this installer"
      echo "    LICENSE        — The Rig's MIT license"
      echo "    README.md      — The Rig's README (replace with your project's)"
      echo ""
      echo "  Your project files (CLAUDE.md, .rig/, .claude/, .husky/, PROJECT_BRIEF.md, etc.)"
      echo "  are NOT affected."
      echo ""
      if confirm "Remove these Rig source files from your project directory?" "y"; then
        for rig_file in templates docs CHANGELOG.md install.sh LICENSE README.md; do
          if [[ -e "$TARGET_ABS/$rig_file" ]]; then
            rm -rf "${TARGET_ABS:?}/$rig_file"
            success "Removed $rig_file"
          fi
        done
        echo ""
        warn "README.md was removed. Create a new one for your project:"
        echo "  Your project description, setup instructions, and usage go here."
      else
        info "Skipped cleanup. Remove them manually when you're ready:"
        echo "    cd $TARGET_ABS"
        echo "    rm -rf templates/ docs/ CHANGELOG.md install.sh LICENSE README.md"
      fi
    fi
  fi
fi

# ── DONE ──────────────────────────────────────────────────────────────────────
echo ""
bold "── Done ──"
echo ""
echo "The Rig is installed. Next steps:"
echo ""

if [[ "$DO_GLOBAL" == true ]]; then
  echo "  1. Fill in your personal profile (if you haven't already):"
  echo "       \$EDITOR ${PROFILE_PATH:-~/.your-ai-contexts/PROFILE.md}"
  echo ""
  echo "  2. Review and personalise ~/.claude/CLAUDE.md"
  echo "     (stack defaults, hard rules, working style)"
  echo ""
fi

if [[ "$DO_PROJECT" == true ]]; then
  echo "  3. Fill in ${TARGET:-your-project}/CLAUDE.md"
  echo "     (stack, conventions, off-limits paths)"
  echo ""
  echo "  4. Open a Claude Code session in your project and run /kickoff or /task"
  echo ""
fi

echo "Documentation: https://github.com/laudtetteh/the-rig"
echo ""
