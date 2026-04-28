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
# Returns 0 (true) if the file is owned by The Rig and should be tracked in the
# manifest and overwritten by the Upgrade strategy.
# Returns 1 (false) if it is user-customized and must be skipped in Upgrade mode.
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

MANIFEST_FILE=""  # set during project-layer install (after RIG_DIR is resolved)

read_manifest_hash() {
  # Returns the recorded hash for a given rel path, or empty string if not found.
  local rel="$1"
  [[ -f "$MANIFEST_FILE" ]] || { echo ""; return; }
  grep "  ${rel}$" "$MANIFEST_FILE" 2>/dev/null | awk '{print $1}' | head -1
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

# ── Parse flags ───────────────────────────────────────────────────────────────
DO_GLOBAL=true
DO_PROJECT=true
EXTERNAL_RIG_DIR=""   # set via --rig-dir <path>

for arg in "$@"; do
  case "$arg" in
    --global-only)  DO_PROJECT=false ;;
    --project-only) DO_GLOBAL=false ;;
    --rig-dir)
      # --rig-dir is handled below as a two-arg flag; skip here
      ;;
    --help|-h)
      echo "Usage: ./install.sh [--global-only | --project-only] [--rig-dir <path>] [--help]"
      echo ""
      echo "  --global-only      Install ~/.claude/ layer only (CLAUDE.md + skills)"
      echo "  --project-only     Scaffold project layer only (processes, rules, memory, etc.)"
      echo "  --rig-dir <path>   Install .rig/ to an external directory outside the repo."
      echo "                     A .rigpath pointer file is written to the project root."
      echo "                     Useful for shared repos where teammates don't use The Rig."
      echo "  (no flags)         Interactive — prompts for both"
      exit 0
      ;;
  esac
done

# Capture --rig-dir value (two-argument flag)
args=("$@")
for (( i=0; i<${#args[@]}; i++ )); do
  if [[ "${args[$i]}" == "--rig-dir" && $((i+1)) -lt ${#args[@]} ]]; then
    EXTERNAL_RIG_DIR="${args[$((i+1))]}"
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

# ── COLLISION STRATEGY ───────────────────────────────────────────────────────
# Ask once upfront. Applied consistently to every file copy.
#
# STRATEGY values:
#   interactive  — ask per file (original behaviour)
#   skip         — keep existing, only create new files
#   overwrite    — replace all, back up originals to .rig-backup/
#   merge        — smart-merge .claude/settings.json; skip everything else

echo "How should I handle files that already exist at the destination?"
echo ""
echo "  1) Interactive  — ask me for each file"
echo "  2) Skip         — keep all existing files, only install new ones"
echo "  3) Overwrite    — replace everything (backs up originals to .rig-backup/)"
echo "  4) Merge        — smart-merge .claude/settings.json; skip everything else"
echo "  5) Upgrade      — update Rig-owned files (hooks, commands, processes, husky);"
echo "                    skip user-owned files (CLAUDE.md, rules/, memory/, github/);"
echo "                    prompt with diff if you've customized a Rig-owned file"
echo "                    ── recommended for upgrading an existing install ──"
echo ""
read -r -p "$(echo -e "${BOLD}?${RESET} Choose a strategy [1/2/3/4/5] (default: 1): ")" strategy_input
strategy_input="${strategy_input:-1}"

case "$strategy_input" in
  1) COLLISION_STRATEGY="interactive" ;;
  2) COLLISION_STRATEGY="skip" ;;
  3) COLLISION_STRATEGY="overwrite" ;;
  4) COLLISION_STRATEGY="merge" ;;
  5) COLLISION_STRATEGY="upgrade" ;;
  *)
    warn "Invalid choice — defaulting to Interactive."
    COLLISION_STRATEGY="interactive"
    ;;
esac

echo ""
info "Collision strategy: ${COLLISION_STRATEGY}"
echo ""

# ── BACKUP HELPER ─────────────────────────────────────────────────────────────
# Used by overwrite strategy. Backs up to <target>/.rig-backup/<timestamp>/
BACKUP_DIR=""
BACKUP_TS="$(date +%Y%m%d_%H%M%S)"

init_backup_dir() {
  local base="$1"
  BACKUP_DIR="${base}/.rig-backup/${BACKUP_TS}"
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
                existing_commands.add(cmd)
    # Append incoming hooks whose command isn't already present
    for entry in incoming_hooks:
        for h in entry.get("hooks", []):
            cmd = h.get("command", "")
            if cmd not in existing_commands:
                existing["hooks"][event].append(entry)
                existing_commands.add(cmd)
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
    # Record in manifest whenever a Rig-owned file is freshly installed
    if [[ -n "$rel" ]] && is_rig_owned "$rel"; then
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
        if [[ -n "$rel" ]] && is_rig_owned "$rel"; then
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
      if [[ -n "$base" ]]; then backup_file "$dest" "$base"; fi
      cp "$src" "$dest"
      success "Overwrote ${dest#${base}/}"
      if [[ -n "$rel" ]] && is_rig_owned "$rel"; then
        write_manifest_entry "$(sha256_file "$dest")" "$rel"
      fi
      ;;
    merge)
      # settings.json gets special treatment; everything else is skipped
      if [[ "$(basename "$dest")" == "settings.json" && "$dest" == *".claude/settings.json" ]]; then
        local tmp_merged
        tmp_merged="$(mktemp /tmp/rig-settings-merged-XXXXXX.json)"
        if merge_settings_json "$dest" "$src" "$tmp_merged"; then
          cp "$tmp_merged" "$dest"
          success "Merged .claude/settings.json"
        else
          info "Skipped settings.json (merge failed — see warning above)"
        fi
        rm -f "$tmp_merged"
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
#   user-owned file     → always skip (preserves customizations)
#   Rig-owned file:
#     dest == src       → already up to date, skip
#     dest == manifest  → unmodified since install → overwrite silently (with backup)
#     dest != manifest  → user has customized it  → show diff, prompt o/s/d
#     no manifest entry → first upgrade run → overwrite silently (with backup)
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
    local tmp_merged
    tmp_merged="$(mktemp /tmp/rig-settings-merged-XXXXXX.json)"
    if merge_settings_json "$dest" "$src" "$tmp_merged"; then
      cp "$tmp_merged" "$dest"
      success "Merged .claude/settings.json"
    else
      info "Skipped settings.json (merge failed — see warning above)"
    fi
    rm -f "$tmp_merged"
    return
  fi

  # ── User-owned files: always skip ──────────────────────────────────────────
  if [[ -n "$rel" ]] && ! is_rig_owned "$rel"; then
    info "Skipped (user-owned): ${rel}"
    return
  fi

  # ── Rig-owned: manifest-aware handling ─────────────────────────────────────
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

  if [[ -z "$manifest_hash" || "$dest_hash" == "$manifest_hash" ]]; then
    # No manifest entry (first upgrade) OR dest matches manifest (not customized).
    # Safe to overwrite without prompting.
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

# ── GLOBAL LAYER ─────────────────────────────────────────────────────────────
if [[ "$DO_GLOBAL" == true ]]; then
  bold "── Global layer (~/.claude/) ──"
  echo ""

  CLAUDE_DIR="$HOME/.claude"
  SKILLS_DIR="$CLAUDE_DIR/skills"

  # Profile path
  DEFAULT_PROFILE_DIR="$HOME/.your-ai-contexts"
  ask "Where should your personal profile file live?"
  read -r -p "    Path [${DEFAULT_PROFILE_DIR}/PROFILE.md]: " PROFILE_PATH_INPUT
  PROFILE_PATH="${PROFILE_PATH_INPUT:-${DEFAULT_PROFILE_DIR}/PROFILE.md}"

  echo ""
  info "Installing to: $CLAUDE_DIR"
  info "Profile path:  $PROFILE_PATH"
  echo ""

  mkdir -p "$CLAUDE_DIR" "$SKILLS_DIR" "$(dirname "$PROFILE_PATH")"

  # ── CLAUDE.md ──────────────────────────────────────────────────────────────
  DEST_CLAUDE="$CLAUDE_DIR/CLAUDE.md"
  CLAUDE_TMP="$(mktemp /tmp/rig-global-claude-XXXXXX.md)"
  sed "s|\\[PROFILE_PATH\\]|${PROFILE_PATH}|g" "$GLOBAL_TEMPLATES/CLAUDE.md" > "$CLAUDE_TMP"
  copy_file "$CLAUDE_TMP" "$DEST_CLAUDE" "$CLAUDE_DIR"
  rm -f "$CLAUDE_TMP"

  # ── Skills ────────────────────────────────────────────────────────────────
  for skill_src in "$GLOBAL_TEMPLATES/skills/"*.md; do
    skill_name="$(basename "$skill_src")"
    skill_dest="$SKILLS_DIR/$skill_name"
    copy_file "$skill_src" "$skill_dest" "$SKILLS_DIR"
  done

  # ── Profile ───────────────────────────────────────────────────────────────
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

  echo ""
fi

# ── PROJECT LAYER ─────────────────────────────────────────────────────────────
if [[ "$DO_PROJECT" == true ]]; then
  bold "── Project layer ──"
  echo ""

  # Determine target directory
  DEFAULT_TARGET="$(pwd)"
  ask "Target project directory?"
  read -r -p "    Path [${DEFAULT_TARGET}]: " TARGET_INPUT
  TARGET="${TARGET_INPUT:-$DEFAULT_TARGET}"

  if [[ ! -d "$TARGET" ]]; then
    error "Directory does not exist: $TARGET"
    exit 1
  fi

  if [[ ! -d "$TARGET/.git" ]]; then
    warn "$TARGET does not appear to be a git repository."
    if ! confirm "Continue anyway?"; then exit 0; fi
  fi

  DEFAULT_PROJECT_NAME="$(basename "$TARGET")"
  ask "Project name (used in CLAUDE.md)?"
  read -r -p "    Name [${DEFAULT_PROJECT_NAME}]: " PROJECT_NAME_INPUT
  PROJECT_NAME="${PROJECT_NAME_INPUT:-$DEFAULT_PROJECT_NAME}"

  # Sanitize project name for safe sed substitution.
  # Strip characters that are sed metacharacters or shell-special in this context.
  # Allow: letters, digits, spaces, hyphens, underscores, periods.
  PROJECT_NAME="$(echo "$PROJECT_NAME" | tr -dc 'A-Za-z0-9 ._-')"
  if [[ -z "$PROJECT_NAME" ]]; then
    PROJECT_NAME="$(basename "$TARGET")"
    warn "Project name contained only invalid characters — using directory name: $PROJECT_NAME"
  fi

  echo ""

  # ── GIT TRACKING FOR .rig/ ────────────────────────────────────────────────
  # How should .rig/ appear (or not appear) in git?
  # Only asked in interactive mode; --rig-dir flag bypasses this.
  RIG_TRACKING="repo"   # default: committed with the project
  RIGPATH_FILE=""       # absolute path to .rigpath (set if external or exclude mode)

  if [[ -z "$EXTERNAL_RIG_DIR" ]]; then
    echo "How should .rig/ be tracked in git?"
    echo ""
    echo "  1) In the repo      — committed with the project (default, recommended for solo projects)"
    echo "  2) Local only       — added to .git/info/exclude; invisible to teammates, no .gitignore change"
    echo "  3) External         — install .rig/ to a path outside this repo entirely"
    echo ""
    read -r -p "$(echo -e "${BOLD}?${RESET} Choose [1/2/3] (default: 1): ")" rig_tracking_input
    rig_tracking_input="${rig_tracking_input:-1}"

    case "$rig_tracking_input" in
      1) RIG_TRACKING="repo" ;;
      2) RIG_TRACKING="exclude" ;;
      3) RIG_TRACKING="external"
         ask "External path for .rig/ files?"
         read -r -p "    Path: " EXTERNAL_RIG_DIR
         if [[ -z "$EXTERNAL_RIG_DIR" ]]; then
           error "External path cannot be empty."
           exit 1
         fi
         ;;
      *)
        warn "Invalid choice — defaulting to 'In the repo'."
        RIG_TRACKING="repo"
        ;;
    esac
  else
    RIG_TRACKING="external"
  fi

  # Resolve and validate the external path (if applicable)
  if [[ "$RIG_TRACKING" == "external" ]]; then
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
  if [[ "$RIG_TRACKING" == "external" ]]; then
    MANIFEST_FILE="$EXTERNAL_RIG_DIR/memory/.rig-manifest"
  else
    MANIFEST_FILE="$TARGET/.rig/memory/.rig-manifest"
  fi

  echo ""

  # ── COMPONENT SELECTION ───────────────────────────────────────────────────
  echo "Which components do you want to install?"
  echo ""
  echo "  a) All (recommended)"
  echo "  b) Let me choose"
  echo ""
  read -r -p "$(echo -e "${BOLD}?${RESET} Choose [a/b] (default: a): ")" component_choice
  component_choice="${component_choice:-a}"

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
    # Always pass $rel (the template-relative path) as the 4th arg so
    # copy_file() can classify the file and update the manifest.
    if [[ "$RIG_TRACKING" == "external" && "$rel" == .rig/* ]]; then
      rig_rel="${rel#.rig/}"
      dest_file="$EXTERNAL_RIG_DIR/$rig_rel"
      copy_file "$src_file" "$dest_file" "$EXTERNAL_RIG_DIR" "$rel"
    else
      dest_file="$TARGET/$rel"
      copy_file "$src_file" "$dest_file" "$TARGET" "$rel"
    fi
  done < <(find "$PROJECT_TEMPLATES" -type f -print0)

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

  # ── EXTERNAL .rig/ — write .rigpath and update git excludes ──────────────
  if [[ "$RIG_TRACKING" == "external" ]]; then
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
  if [[ "$INSTALL_GIT_HOOKS" == true ]]; then
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
    info "Originals backed up to: ${BACKUP_DIR#$TARGET/}"
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
