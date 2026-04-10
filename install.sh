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

# ── Locate the script's own directory (works with symlinks) ───────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_TEMPLATES="$SCRIPT_DIR/templates/global"
PROJECT_TEMPLATES="$SCRIPT_DIR/templates/project"

# ── Parse flags ───────────────────────────────────────────────────────────────
DO_GLOBAL=true
DO_PROJECT=true

for arg in "$@"; do
  case "$arg" in
    --global-only)  DO_PROJECT=false ;;
    --project-only) DO_GLOBAL=false ;;
    --help|-h)
      echo "Usage: ./install.sh [--global-only | --project-only | --help]"
      echo ""
      echo "  --global-only   Install ~/.claude/ layer only (CLAUDE.md + skills)"
      echo "  --project-only  Scaffold project layer only (processes, rules, memory, etc.)"
      echo "  (no flags)      Interactive — prompts for both"
      exit 0
      ;;
  esac
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
echo ""
read -r -p "$(echo -e "${BOLD}?${RESET} Choose a strategy [1/2/3/4] (default: 1): ")" strategy_input
strategy_input="${strategy_input:-1}"

case "$strategy_input" in
  1) COLLISION_STRATEGY="interactive" ;;
  2) COLLISION_STRATEGY="skip" ;;
  3) COLLISION_STRATEGY="overwrite" ;;
  4) COLLISION_STRATEGY="merge" ;;
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
# copy_file <src> <dest> [base_dir]
# base_dir is used for backup paths in overwrite mode.
copy_file() {
  local src="$1"
  local dest="$2"
  local base="${3:-}"
  local dir
  dir="$(dirname "$dest")"
  mkdir -p "$dir"

  if [[ ! -f "$dest" ]]; then
    # No collision — always copy
    cp "$src" "$dest"
    success "Created ${dest#${base}/}"
    return
  fi

  # File exists — apply strategy
  case "$COLLISION_STRATEGY" in
    interactive)
      if confirm "Overwrite existing: ${dest#${base}/}?"; then
        cp "$src" "$dest"
        success "Updated ${dest#${base}/}"
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
  esac
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
    echo ""
    confirm "Install CLAUDE.md (project brain template)?" "y"     && INSTALL_CLAUDE_MD=true    || INSTALL_CLAUDE_MD=false
    confirm "Install memory system (memory/, PROGRESS, ERRORS)?" "y" && INSTALL_MEMORY=true   || INSTALL_MEMORY=false
    confirm "Install task lifecycle (tasks/backlog, active, done)?" "y" && INSTALL_TASKS=true  || INSTALL_TASKS=false
    confirm "Install process workflows (processes/)?" "y"          && INSTALL_PROCESSES=true   || INSTALL_PROCESSES=false
    confirm "Install rules (rules/)?" "y"                          && INSTALL_RULES=true        || INSTALL_RULES=false
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
  echo ""

  # ── FILE → COMPONENT MAPPING ──────────────────────────────────────────────
  # Returns 0 (install) or 1 (skip) for a given relative path.
  should_install_file() {
    local rel="$1"
    case "$rel" in
      CLAUDE.md)                           [[ "$INSTALL_CLAUDE_MD" == true ]]      ;;
      PROJECT_BRIEF.md)                    [[ "$INSTALL_PROJECT_BRIEF" == true ]]  ;;
      memory/*)                            [[ "$INSTALL_MEMORY" == true ]]         ;;
      tasks/*)                             [[ "$INSTALL_TASKS" == true ]]          ;;
      processes/*)                         [[ "$INSTALL_PROCESSES" == true ]]      ;;
      rules/*)                             [[ "$INSTALL_RULES" == true ]]          ;;
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
    dest_file="$TARGET/$rel"
    copy_file "$src_file" "$dest_file" "$TARGET"
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
          (cd "$TARGET" && npx husky install)
          success "Husky initialized"
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
