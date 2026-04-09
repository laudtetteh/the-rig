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
  # confirm "message" [default: y/n]
  local msg="$1"
  local default="${2:-n}"
  local prompt
  if [[ "$default" == "y" ]]; then
    prompt="[Y/n]"
  else
    prompt="[y/N]"
  fi
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

# ─────────────────────────────────────────────────────────────────────────────
echo ""
bold "╔══════════════════════════════════════╗"
bold "║         The Rig — Installer          ║"
bold "╚══════════════════════════════════════╝"
echo ""
echo "This script deploys The Rig's templates to your machine."
echo "It will not overwrite existing files without asking."
echo ""

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

  # Create directories
  mkdir -p "$CLAUDE_DIR" "$SKILLS_DIR" "$(dirname "$PROFILE_PATH")"

  # ── CLAUDE.md ──────────────────────────────────────────────────────────────
  DEST_CLAUDE="$CLAUDE_DIR/CLAUDE.md"
  SHOULD_INSTALL_CLAUDE=true

  if [[ -f "$DEST_CLAUDE" ]]; then
    warn "$DEST_CLAUDE already exists."
    if ! confirm "Overwrite it?"; then
      SHOULD_INSTALL_CLAUDE=false
      info "Skipped CLAUDE.md"
    fi
  fi

  if [[ "$SHOULD_INSTALL_CLAUDE" == true ]]; then
    # Substitute [PROFILE_PATH] with the actual path
    sed "s|\\[PROFILE_PATH\\]|${PROFILE_PATH}|g" \
      "$GLOBAL_TEMPLATES/CLAUDE.md" > "$DEST_CLAUDE"
    success "Installed ~/.claude/CLAUDE.md"
  fi

  # ── Skills ────────────────────────────────────────────────────────────────
  for skill_src in "$GLOBAL_TEMPLATES/skills/"*.md; do
    skill_name="$(basename "$skill_src")"
    skill_dest="$SKILLS_DIR/$skill_name"
    if [[ -f "$skill_dest" ]]; then
      if confirm "Overwrite existing skill: $skill_name?"; then
        cp "$skill_src" "$skill_dest"
        success "Updated ~/.claude/skills/$skill_name"
      else
        info "Skipped $skill_name"
      fi
    else
      cp "$skill_src" "$skill_dest"
      success "Installed ~/.claude/skills/$skill_name"
    fi
  done

  # ── Profile ───────────────────────────────────────────────────────────────
  if [[ -f "$PROFILE_PATH" ]]; then
    warn "$PROFILE_PATH already exists — skipping (don't want to overwrite personal data)."
    info "To re-generate the template: cp $GLOBAL_TEMPLATES/PROFILE.md.example $PROFILE_PATH"
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

  # Check it looks like a project (has a git repo or is obviously a project dir)
  if [[ ! -d "$TARGET/.git" ]]; then
    warn "$TARGET does not appear to be a git repository."
    if ! confirm "Continue anyway?"; then
      exit 0
    fi
  fi

  # Project name for substitution
  DEFAULT_PROJECT_NAME="$(basename "$TARGET")"
  ask "Project name (used in CLAUDE.md)?"
  read -r -p "    Name [${DEFAULT_PROJECT_NAME}]: " PROJECT_NAME_INPUT
  PROJECT_NAME="${PROJECT_NAME_INPUT:-$DEFAULT_PROJECT_NAME}"

  echo ""
  info "Scaffolding into: $TARGET"
  info "Project name:     $PROJECT_NAME"
  echo ""

  # ── Copy project template files ───────────────────────────────────────────
  # We walk the template tree and copy each file, preserving directory structure.
  # dotfiles (like .claude/, .husky/, .gitleaks.toml) are included explicitly.

  copy_file() {
    local src="$1"
    local dest="$2"
    local dir
    dir="$(dirname "$dest")"
    mkdir -p "$dir"

    if [[ -f "$dest" ]]; then
      if confirm "Overwrite existing: ${dest#$TARGET/}?"; then
        cp "$src" "$dest"
        success "Updated ${dest#$TARGET/}"
      else
        info "Skipped ${dest#$TARGET/}"
      fi
    else
      cp "$src" "$dest"
      success "Created ${dest#$TARGET/}"
    fi
  }

  # Walk template tree (find handles dotfiles)
  while IFS= read -r -d '' src_file; do
    # Compute relative path within templates/project/
    rel="${src_file#$PROJECT_TEMPLATES/}"
    dest_file="$TARGET/$rel"
    copy_file "$src_file" "$dest_file"
  done < <(find "$PROJECT_TEMPLATES" -type f -print0)

  # ── Substitute project name in CLAUDE.md ─────────────────────────────────
  TARGET_CLAUDE="$TARGET/CLAUDE.md"
  if [[ -f "$TARGET_CLAUDE" ]]; then
    # In-place replacement — macOS sed needs a backup extension
    if sed --version 2>/dev/null | grep -q GNU; then
      sed -i "s/\\[Project Name\\]/${PROJECT_NAME}/g" "$TARGET_CLAUDE"
    else
      # macOS BSD sed
      sed -i '' "s/\\[Project Name\\]/${PROJECT_NAME}/g" "$TARGET_CLAUDE"
    fi
    success "Substituted project name in CLAUDE.md"
  fi

  # ── Set executable bits on hook scripts ───────────────────────────────────
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

  # ── Husky initialization ───────────────────────────────────────────────────
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

  echo ""
fi

# ── Gitleaks check ────────────────────────────────────────────────────────────
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

# ── Done ─────────────────────────────────────────────────────────────────────
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
  echo "  4. Open a Claude Code session in your project and run:"
  echo "       /new-feature"
  echo ""
fi

echo "Documentation: https://github.com/laudtetteh/the-rig"
echo ""
