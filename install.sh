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
# AGENT_MODE gates human-oriented stdout so agent-plan/agent-upgrade can emit a
# single machine-readable JSON document. Declared here (before first use) since
# these wrappers are defined at the very top of the script; the real value is
# set later during flag parsing. error() always writes to stderr, so it is
# never gated — fatal diagnostics must remain visible even in agent mode.
AGENT_MODE="${AGENT_MODE:-}"
info()    { [[ -n "$AGENT_MODE" ]] && return 0; echo -e "${BLUE}→${RESET} $*"; }
success() { [[ -n "$AGENT_MODE" ]] && return 0; echo -e "${GREEN}✓${RESET} $*"; }
warn()    { [[ -n "$AGENT_MODE" ]] && return 0; echo -e "${YELLOW}!${RESET} $*"; }
error()   { echo -e "${RED}✗${RESET} $*" >&2; }
bold()    { [[ -n "$AGENT_MODE" ]] && return 0; echo -e "${BOLD}$*${RESET}"; }
ask()     { [[ -n "$AGENT_MODE" ]] && return 0; echo -e "${BOLD}?${RESET} $*"; }
# Blank-line spacer for human-readable narrative sections. Retro-audit
# finding, PR #446: bare `echo ""` calls used purely for visual spacing were
# never routed through this file's own AGENT_MODE self-gating convention
# (every other narrative output helper above already is), so a real
# agent-plan/agent-upgrade run leaked several blank lines onto stdout ahead
# of its single documented JSON line -- a caller doing
# json.loads(stdout.strip().splitlines()[0]) still breaks on blank lines
# preceding the real content, and any strict "stdout is exactly one line"
# consumer breaks outright.
blank()   { [[ -n "$AGENT_MODE" ]] && return 0; echo ""; }

confirm() {
  local msg="$1"
  local default="${2:-n}"
  local prompt
  if [[ "$default" == "y" ]]; then prompt="[Y/n]"; else prompt="[y/N]"; fi
  # Non-interactive (CI / piped stdin) or agent mode: accept the default
  # without prompting. Agent modes must never block on a TTY prompt even if
  # stdin happens to be a terminal.
  if [[ ! -t 0 || -n "$AGENT_MODE" ]]; then
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
  local hash=""
  if command -v sha256sum >/dev/null 2>&1; then
    hash="$(sha256sum "$file" 2>/dev/null | awk '{print $1}' || true)"
  fi
  if [[ -z "$hash" ]] && command -v shasum >/dev/null 2>&1; then
    hash="$(shasum -a 256 "$file" 2>/dev/null | awk '{print $1}' || true)"
  fi
  printf '%s\n' "$hash"
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
# Rig-owned:   bin/rig, .claude/hooks/, .claude/commands/, .agents/skills/,
#              .codex/hooks.json, .codex/hooks/, .rig/processes/,
#              .rig/rules/protected-paths.txt, .husky/, .gitleaks.toml,
#              .git/hooks/ (stealth-mode installed hook scripts only)
# User-owned:  CLAUDE.md, PROJECT_BRIEF.md, other .rig/rules/, .rig/memory/*.md,
#              .rig/tasks/, .github/
# Special:     .claude/settings.json (always smart-merged, not manifest-tracked)
is_rig_owned() {
  local rel="$1"
  case "$rel" in
    bin/rig|\
    .claude/hooks/*|\
    .claude/commands/*|\
    .claude/agents/*|\
    .agents/skills/*|\
    .codex/hooks.json|\
    .codex/hooks/*|\
    .rig/processes/*|\
    .rig/rules/protected-paths.txt|\
    .husky/*|\
    .git/hooks/*|\
    .gitleaks.toml)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# ── Manifest helpers ──────────────────────────────────────────────────────────
# The manifest lives at $MANIFEST_FILE and records the SHA256 of each installed
# artifact at the time it was last installed by the installer. Format per line:
#   sha256hash  relative/path
# A versioned JSON companion records ownership/source/type/mode metadata while
# the text format remains readable by older installers.
#
# This allows the Upgrade strategy to distinguish:
#   dest hash == manifest hash  → file unmodified since install → safe to overwrite
#   dest hash != manifest hash  → user has customized the file  → prompt before overwriting
#
# The manifest is committed to the repo (not gitignored) so the baseline travels
# with the project and any team member can run an Upgrade.

MANIFEST_FILE=""        # set during project-layer install (after RIG_DIR is resolved)
GLOBAL_MANIFEST_FILE="$HOME/.claude/.rig-global-manifest"  # global layer manifest
CODEX_GLOBAL_MANIFEST_FILE="$HOME/.agents/.rig-global-manifest"

manifest_artifact_source() {
  case "$1" in
    .agents/skills/*) echo generated-codex ;;
    .codex/*) echo codex-native ;;
    .claude/*) echo claude-native ;;
    .rig/*) echo shared-rig ;;
    .husky/*|.git/hooks/*|.gitleaks.toml) echo project-tooling ;;
    *) echo project-user ;;
  esac
}

manifest_artifact_mode() {
  local path="$1"
  [[ -e "$path" || -L "$path" ]] || { echo ""; return; }
  if stat -c '%a' "$path" >/dev/null 2>&1; then
    stat -c '%a' "$path"
  else
    stat -f '%Lp' "$path"
  fi
}

write_manifest_metadata() {
  local hash="$1" rel="$2" manifest_file="$3" artifact_path="${4:-}" metadata_file
  [[ -z "$hash" || -z "$rel" || -z "$manifest_file" ]] && return
  metadata_file="${manifest_file}.json"
  local owner="user" kind="missing" mode="" source generator provider layer_agent
  if is_rig_owned "$rel"; then owner="rig"; fi
  source="$(manifest_artifact_source "$rel")"
  if [[ -L "$artifact_path" ]]; then kind="symlink"
  elif [[ -f "$artifact_path" ]]; then kind="file"
  elif [[ -d "$artifact_path" ]]; then kind="directory"
  elif [[ -e "$artifact_path" ]]; then kind="other"
  fi
  mode="$(manifest_artifact_mode "$artifact_path")"

  # generator: the tool that actually produced this artifact's content.
  # generated-codex artifacts are mirrored from the canonical Claude command
  # body by installer/generate-codex-skills.py; everything else is a
  # hand-authored template copied verbatim by install.sh itself. Keep this
  # mapping in sync with installer/validate-manifest-provenance.py.
  case "$source" in
    generated-codex) generator="codex-mirror" ;;
    *) generator="install.sh" ;;
  esac

  # provider: which agent context this artifact belongs to, using the same
  # claude/codex/both/none vocabulary as GLOBAL_AGENT/PROJECT_AGENT/has_agent().
  # Provider-specific paths are unambiguous from their source classification;
  # shared paths (.rig/*, project tooling, plain user files) take on the
  # active agent selection for whichever layer this manifest belongs to.
  case "$manifest_file" in
    "$GLOBAL_MANIFEST_FILE"|"$CODEX_GLOBAL_MANIFEST_FILE") layer_agent="${GLOBAL_AGENT:-}" ;;
    *) layer_agent="${PROJECT_AGENT:-}" ;;
  esac
  case "$source" in
    generated-codex|codex-native) provider="codex" ;;
    claude-native) provider="claude" ;;
    *)
      # Global-layer CLAUDE.md and personal skills fall through to the
      # generic "project-user" classification above -- manifest_artifact_
      # source() only recognizes a .claude/-prefixed rel as claude-native,
      # but the global layer records these un-prefixed ("CLAUDE.md",
      # "skills/$name.md"). Unlike the project layer's CLAUDE.md (which
      # really is Codex-shared, merged into .codex/config.toml as an
      # instruction fallback), the global CLAUDE.md/skills have no
      # Codex-side equivalent anywhere in this script -- Codex's global
      # artifacts are the entirely separate .agents/skills/* tree, already
      # correctly classified as generated-codex above. Treat these as
      # unambiguously Claude-only regardless of GLOBAL_AGENT, instead of
      # stamping them with the layer's agent selection (which could wrongly
      # record "both" or "codex" when --global-agent picks either).
      if [[ "$manifest_file" == "$GLOBAL_MANIFEST_FILE" && ( "$rel" == "CLAUDE.md" || "$rel" == skills/* ) ]]; then
        provider="claude"
      else
        provider="$layer_agent"
      fi
      ;;
  esac

  # base_revision: the trusted upstream template revision this artifact was
  # generated/copied from. There is no per-file template versioning today, so
  # the most trustworthy real signal available is the installer's own VERSION
  # at write time (the same value already recorded as installer_version).
  # The two fields are kept distinct on purpose: installer_version answers
  # "which installer executable performed this write" (housekeeping), while
  # base_revision answers "what upstream revision should a future three-way
  # merge diff against" (444-C provenance contract). They share a source
  # today only because no finer-grained per-template revision exists yet —
  # do not invent one.
  python3 - "$metadata_file" "$rel" "$hash" "$owner" "$source" "$kind" "$mode" "$INSTALLER_VERSION" "$generator" "$provider" <<'PYEOF'
import json, os, sys, tempfile

path, rel, digest, owner, source, kind, mode, installer_version, generator, provider = sys.argv[1:]
try:
    with open(path) as fh:
        data = json.load(fh)
except FileNotFoundError:
    data = {
        "schema": "https://the-rig.dev/schemas/manifest/v1",
        "schema_version": 1,
        "entries": {},
    }
if data.get("schema_version") != 1 or not isinstance(data.get("entries"), dict):
    raise SystemExit("invalid The Rig manifest metadata")
data["entries"][rel] = {
    "sha256": digest,
    "owner": owner,
    "source": source,
    "type": kind,
    "mode": mode or None,
    "installer_version": installer_version,
    "base_revision": installer_version or None,
    "generator": generator or None,
    "provider": provider or None,
}

directory = os.path.dirname(path) or "."
fd, temporary = tempfile.mkstemp(prefix=".rig-manifest.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(temporary, path)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
PYEOF
}

# ── Manifest provenance validation ────────────────────────────────────────────
# Thin wrapper around installer/validate-manifest-provenance.py. Reports (does
# not silently ignore) malformed provenance fields in a manifest metadata
# file, entries that simply predate this metadata (legacy/unknown
# provenance — not an error), and — since issue #463 — entries whose
# base_revision claims an installer VERSION newer than the one currently
# running ($INSTALLER_VERSION), the same "impossible future state" class of
# bug _GLOBAL_STATE_FUTURE/_PROJECT_STATE_FUTURE catch for install-target
# metadata. Consumed by report_future_manifest_revisions() below during
# --strategy upgrade/agent-plan/agent-upgrade, and by `rig doctor`'s
# manifest_provenance gate (templates/project/bin/rig), which calls the
# underlying script directly with the project's installed .rig/VERSION.
validate_manifest_provenance() {
  local metadata_file="$1"
  if [[ ! -f "$metadata_file" ]]; then
    printf '%s\n' '{"ok":true,"checked":0,"malformed":[],"legacy_provenance":[],"future_revision":[]}'
    return 0
  fi
  python3 "$SCRIPT_DIR/installer/validate-manifest-provenance.py" "$metadata_file" --running-version "$INSTALLER_VERSION"
}

# Detects and records (never auto-fixes) manifest entries whose base_revision
# is a bogus/future installer version relative to the one currently running
# (issue #463). Mirrors report_stale_manifest_entries()'s call shape and
# feeds the same UPGRADE_REVIEW_REQUIRED aggregation, so agent-plan/
# agent-upgrade refuse (status "refused", exit 3) exactly as they already do
# for skipped-customized/conflict/stale findings — the closest existing
# precedent available inside this same upgrade-decision flow. A plain
# --strategy upgrade run still completes (exit 0) but surfaces the finding
# for manual review via RIG_UPGRADE_REVIEW_REQUIRED, same as those findings.
# Ordinary manifests (base_revision absent, legacy, or <= INSTALLER_VERSION)
# make this a complete no-op: zero findings, zero effect on
# UPGRADE_REVIEW_REQUIRED.
report_future_manifest_revisions() {
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  local metadata_file="$1" label="$2"
  [[ -f "$metadata_file" ]] || return 0
  # validate_manifest_provenance() exits 1 (not just non-zero-and-ignorable)
  # whenever it finds anything to report, including the future_revision
  # case this function exists to detect — under `set -euo pipefail`, an
  # unguarded "var=$(cmd)" assignment where cmd exits 1 kills the whole
  # script. `|| true` is required here, exactly like the existing
  # read_agent_state() call sites above use "|| _state_status=$?" for the
  # same reason.
  local provenance_json
  provenance_json="$(validate_manifest_provenance "$metadata_file")" || true
  local rel base_rev
  while IFS=$'\t' read -r rel base_rev; do
    [[ -n "$rel" ]] || continue
    UPGRADE_FUTURE_REVISION_COUNT=$((UPGRADE_FUTURE_REVISION_COUNT + 1))
    UPGRADE_FUTURE_REVISION_FILES[${#UPGRADE_FUTURE_REVISION_FILES[@]}]="$label:$rel (base_revision $base_rev > running $INSTALLER_VERSION)"
  done < <(python3 -c '
import json, sys
d = json.load(sys.stdin)
for e in d.get("future_revision") or []:
    print(e.get("path", "") + "\t" + e.get("base_revision", ""))
' <<< "$provenance_json")
  return 0
}

# Audit a manifest's tracked entries against what's actually on disk.
#
#   metadata_file  the *.json metadata companion to a .rig-manifest file
#   artifact_root  root that non-".rig/*" tracked paths resolve against
#   label          "global" | "project" — only used to prefix report lines
#   rig_root       optional; when set (external/stealth layouts), any tracked
#                  rel beginning with ".rig/" resolves against this root
#                  instead, with the ".rig/" prefix stripped first. This is
#                  required because external/stealth manifests mix two
#                  families of rel paths in the same file: ordinary
#                  project-rooted paths (.claude/, CLAUDE.md, .git/hooks/…)
#                  that live under $TARGET, and ".rig/…" paths whose actual
#                  files were relocated to $EXTERNAL_RIG_DIR without the
#                  ".rig/" prefix. Resolving every entry against a single
#                  root previously made every ".rig/*" entry look either
#                  falsely stale (root=$TARGET) or made every non-".rig/*"
#                  entry unreachable (root=$EXTERNAL_RIG_DIR) — so this
#                  audit was skipped entirely for external/stealth (issue
#                  #444, lane 444-E). Repo/local layouts never pass rig_root
#                  and behave exactly as before.
#
# Reports (never silently fixes) four disjoint categories:
#   missing            tracked path no longer exists — the only category
#                      --repair-stale is permitted to remove from the
#                      manifest; removing the entry does not touch the
#                      filesystem, there is nothing there to touch.
#   wrong-type         tracked path exists but its type (file/directory)
#                      no longer matches what the manifest recorded.
#   dangling-symlink   tracked path is a symlink whose target does not exist.
#   unexpected-symlink tracked path is now a symlink where the manifest did
#                      not record one.
# The last three are never auto-repaired, even with --repair-stale — the
# manifest metadata for those paths is left untouched pending explicit
# operator review, per the "never silently overwrite or silently fix" policy
# in TASK_444.
report_stale_manifest_entries() {
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  local metadata_file="$1" artifact_root="$2" label="$3" rig_root="${4:-}"
  [[ -f "$metadata_file" ]] || return 0
  local stale_count=0 category stale_rel
  while IFS=$'\t' read -r category stale_rel; do
    [[ -n "$stale_rel" ]] || continue
    stale_count=$((stale_count + 1))
    UPGRADE_STALE_FILES[${#UPGRADE_STALE_FILES[@]}]="$label:$category:$stale_rel"
    if [[ "$category" == missing ]]; then
      if [[ "$REPAIR_STALE" == true ]]; then
        repair_stale_manifest_entry "$metadata_file" "${metadata_file%.json}" "$stale_rel"
        info "Repaired stale manifest entry: $label:$stale_rel"
      else
        UPGRADE_STALE_UNREPAIRED_COUNT=$((UPGRADE_STALE_UNREPAIRED_COUNT + 1))
      fi
    else
      # wrong-type / dangling-symlink / unexpected-symlink are never
      # auto-repaired, even with --repair-stale — always requires review.
      warn "Stale manifest entry requires manual repair ($category): $label:$stale_rel"
      UPGRADE_STALE_UNREPAIRED_COUNT=$((UPGRADE_STALE_UNREPAIRED_COUNT + 1))
    fi
  done < <(python3 - "$metadata_file" "$artifact_root" "$rig_root" <<'PYEOF'
import json, os, sys

metadata, root, rig_root = sys.argv[1:]

def resolve(rel):
    if rig_root and (rel == ".rig" or rel.startswith(".rig/")):
        stripped = rel[len(".rig/"):] if rel.startswith(".rig/") else ""
        return os.path.join(rig_root, stripped) if stripped else rig_root
    return os.path.join(root, rel)

try:
    with open(metadata) as fh:
        data = json.load(fh)
except (OSError, ValueError):
    raise SystemExit(0)
for rel in sorted(data.get("entries", {})):
    if not isinstance(rel, str) or rel.startswith("/") or ".." in rel.split("/"):
        continue
    entry = data["entries"].get(rel)
    recorded_type = entry.get("type") if isinstance(entry, dict) else None
    path = resolve(rel)

    if not os.path.lexists(path):
        print(f"missing\t{rel}")
        continue

    is_symlink = os.path.islink(path)
    if is_symlink:
        if not os.path.exists(path):  # follows the link — False means dangling
            print(f"dangling-symlink\t{rel}")
        elif recorded_type not in (None, "symlink"):
            print(f"unexpected-symlink\t{rel}")
        continue

    if recorded_type in (None, "missing"):
        continue
    actual_type = "directory" if os.path.isdir(path) else ("file" if os.path.isfile(path) else "other")
    if recorded_type != actual_type:
        print(f"wrong-type\t{rel}")
PYEOF
  )
  if [[ "$stale_count" -gt 0 ]]; then
    UPGRADE_STALE_COUNT=$((UPGRADE_STALE_COUNT + stale_count))
  fi
  return 0
}

repair_stale_manifest_entry() {
  local metadata_file="$1" manifest_file="$2" rel="$3"
  if ! upgrade_manifest_mutation_allowed "$manifest_file" "$rel"; then
    return 0
  fi
  python3 - "$metadata_file" "$manifest_file" "$rel" <<'PYEOF'
import json, os, sys, tempfile

metadata_file, manifest_file, rel = sys.argv[1:]
with open(metadata_file) as fh:
    data = json.load(fh)
entries = data.get("entries", {})
if rel not in entries:
    raise SystemExit(0)
del entries[rel]
directory = os.path.dirname(metadata_file) or "."
fd, temporary = tempfile.mkstemp(prefix=".rig-manifest.", dir=directory, text=True)
try:
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(temporary, metadata_file)
finally:
    if os.path.exists(temporary):
        os.unlink(temporary)
if os.path.isfile(manifest_file):
    with open(manifest_file) as fh:
        lines = fh.readlines()
    directory = os.path.dirname(manifest_file) or "."
    fd, temporary = tempfile.mkstemp(prefix=".rig-manifest.", dir=directory, text=True)
    try:
        with os.fdopen(fd, "w") as fh:
            for line in lines:
                fields = line.rstrip("\n").split(None, 1)
                if len(fields) == 2 and fields[1] == rel:
                    continue
                fh.write(line)
        os.replace(temporary, manifest_file)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)
PYEOF
}

read_manifest_hash() {
  # Returns the recorded hash for a given rel path, or empty string if not found.
  local rel="$1"
  local manifest_file="${2:-$MANIFEST_FILE}"
  [[ -f "$manifest_file" ]] || { echo ""; return 0; }
  # grep exits 1 when no match; suppress it so set -eo pipefail doesn't kill the installer.
  grep "  ${rel}$" "$manifest_file" 2>/dev/null | awk '{print $1}' | head -1 || true
}

write_manifest_entry() {
  # Upsert: remove any existing entry for $rel, then append the new hash.
  local hash="$1"
  local rel="$2"
  local manifest_file="${3:-$MANIFEST_FILE}"
  local artifact_path="${4:-}"
  [[ -z "$hash" || -z "$manifest_file" ]] && return
  # agent-plan: classification only, never write the manifest.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  if ! upgrade_manifest_mutation_allowed "$manifest_file" "$rel"; then
    return 0
  fi
  mkdir -p "$(dirname "$manifest_file")"
  if [[ ! -f "$manifest_file" ]]; then
    {
      echo "# The Rig manifest"
      echo "# Records the SHA256 of each Rig-owned file at last install."
      echo "# Used by the Upgrade strategy to detect user customizations."
      echo "# Committed to the repo. Do not edit manually."
    } > "$manifest_file"
  fi
  local tmp; tmp="$(mktemp)"
  grep -v "  ${rel}$" "$manifest_file" > "$tmp" 2>/dev/null || true
  echo "${hash}  ${rel}" >> "$tmp"
  mv "$tmp" "$manifest_file"
  write_manifest_metadata "$hash" "$rel" "$manifest_file" "$artifact_path"
}

# ── Locate the script's own directory (works with symlinks) ───────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GLOBAL_TEMPLATES="$SCRIPT_DIR/templates/global"
PROJECT_TEMPLATES="$SCRIPT_DIR/templates/project"
INSTALLER_VERSION="$(cat "$SCRIPT_DIR/VERSION" 2>/dev/null || echo "unknown")"
CAPABILITY_MANIFEST="${_RIG_CAPABILITY_MANIFEST:-$SCRIPT_DIR/installer/capabilities.v1.json}"
_EARLY_PREFLIGHT=false
_EARLY_PREFLIGHT_JSON=false
# issue #476: the real AGENT_MODE assignment happens much later, inside the
# --strategy case statement below (it needs TARGET/COLLISION_STRATEGY
# resolution machinery that isn't set up yet this early). The drift check
# right below this loop runs before that point, so it can't just read
# AGENT_MODE -- it needs its own early, standalone lookahead over $@,
# exactly like the --preflight/--json scan above, to know whether
# agent-plan/agent-upgrade was requested before deciding whether it's safe
# to print unguarded narration or block on an interactive prompt.
_EARLY_AGENT_MODE=false
_early_args=("$@")
for ((_early_i = 0; _early_i < ${#_early_args[@]}; _early_i++)); do
  case "${_early_args[$_early_i]}" in
    --preflight) _EARLY_PREFLIGHT=true ;;
    --json) _EARLY_PREFLIGHT_JSON=true ;;
    --strategy)
      # Last-wins, matching the real _FLAG_STRATEGY parser further down
      # (a plain forward-loop overwrite is naturally last-wins) -- every
      # occurrence must unconditionally reassign _EARLY_AGENT_MODE, not
      # just set it true and never reset it, or a duplicated --strategy
      # flag (e.g. "--strategy agent-plan --strategy merge") leaves this
      # true even though the run actually resolves to a human-capable
      # strategy (issue #483).
      if [[ $((_early_i + 1)) -lt ${#_early_args[@]} ]]; then
        case "${_early_args[$((_early_i + 1))]}" in
          agent-plan|agent-upgrade) _EARLY_AGENT_MODE=true ;;
          *) _EARLY_AGENT_MODE=false ;;
        esac
      fi
      ;;
  esac
done

# ── Installer branch drift check ─────────────────────────────────────────────
# If the installer lives inside a git repo, check whether it's behind its
# remote tracking branch. A stale installer installs stale templates.
# Runs silently if there's no remote, no network, or no git.
# Tests can override _RIG_DRIFT_DIR to point to a mock repo.
#
# Never for agent-plan/agent-upgrade (issue #476): this block used to be
# gated only on _EARLY_PREFLIGHT, and every warn()/echo call inside it is
# either unconditional or gated on the real AGENT_MODE variable, which
# isn't assigned yet at this point in the script regardless of --strategy.
# That meant an agent-plan/agent-upgrade run whose installer checkout was
# behind its remote always leaked this block's narration onto stdout ahead
# of the documented single JSON document -- and, far worse, if stdin was
# also a TTY (not uncommon for CI runners or interactive agent sessions),
# fell into the interactive `read` a few lines down and hung indefinitely
# waiting for input that would never come.
_DRIFT_DIR="${_RIG_DRIFT_DIR:-$SCRIPT_DIR}"
if [[ "$_EARLY_PREFLIGHT" != true && "$_EARLY_AGENT_MODE" != true ]] && git -C "$_DRIFT_DIR" rev-parse --git-dir >/dev/null 2>&1; then
  git -C "$_DRIFT_DIR" fetch --quiet 2>/dev/null || true
  _TRACKING=$(git -C "$_DRIFT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)
  if [[ -n "$_TRACKING" ]]; then
    _BEHIND=$(git -C "$_DRIFT_DIR" rev-list "HEAD..${_TRACKING}" --count 2>/dev/null || echo 0)
    if [[ "$_BEHIND" -gt 0 ]]; then
      warn "The installer is ${_BEHIND} commit(s) behind ${_TRACKING}."
      warn "Running from a stale version may install outdated hooks and commands."
      blank
      if [[ ! -t 0 ]]; then
        # Non-interactive (CI / piped stdin): warn and continue, don't block.
        warn "Run: git -C \"$_DRIFT_DIR\" pull   to get the latest version first."
        warn "Proceeding with the current version..."
        blank
      else
        echo "  Options:"
        echo "    1) Update now and re-run (recommended)"
        echo "    2) Continue with current version"
        echo "    3) Exit"
        blank
        read -r -p "  Choice [1/2/3]: " _STALE_CHOICE || true
        case "${_STALE_CHOICE:-}" in
          1)
            info "Pulling latest..."
            git -C "$_DRIFT_DIR" pull
            exec "$SCRIPT_DIR/install.sh" "$@"
            ;;
          2)
            warn "Proceeding with stale installer. Some installed files may be outdated."
            blank
            ;;
          *)
            echo "Exiting."
            exit 0
            ;;
        esac
      fi
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
RECOVER_ONLY=false
RECOVERY_ONLY_COMPLETE=false
REPAIR_STALE=false
SKIP_GIT_HOOKS=false       # set via --skip-git-hooks    (stealth: skip .git/hooks/ writes)
INSTALL_FEATURE_DOCS=false # set via --feature-docs      (gates doc-feature/feature-context/etc.)
INSTALL_SUBAGENTS=false    # set via --subagents          (gates subagent-start.sh + SubagentStart hook)
INSTALL_CONTRIBUTE=false   # set via --contribute         (gates rig-gaps.md + rig-propose.md)
INSTALL_NOTIFICATIONS=false
_FLAG_GLOBAL_AGENT=""
_FLAG_PROJECT_AGENT=""
PREFLIGHT_ONLY=false
JSON_OUTPUT=false
# AGENT_MODE: "" (default) | "plan" (--strategy agent-plan) | "apply" (--strategy agent-upgrade).
# AGENT_DRY_RUN: true only for AGENT_MODE=plan. Every mutation primitive in this
# script (write_manifest_entry, backup_file, ensure_upgrade_transaction,
# record_created, write_agent_state, rewrite_project_root_references, the
# copy_file/_copy_upgrade_existing/_copy_global_file_upgrade family, and a
# handful of directly-guarded cp/mkdir/sed/chmod/rm call sites) checks this
# flag and no-ops when true, so agent-plan can run the real classification
# logic used by --strategy upgrade with zero writes to the target.
AGENT_DRY_RUN=false

for arg in "$@"; do
  case "$arg" in
    --global-only)      DO_PROJECT=false ;;
    --project-only)     DO_GLOBAL=false ;;
    --skip-git-hooks)   SKIP_GIT_HOOKS=true ;;
    --feature-docs)     INSTALL_FEATURE_DOCS=true ;;
    --subagents)        INSTALL_SUBAGENTS=true ;;
    --contribute)       INSTALL_CONTRIBUTE=true ;;
    --notifications)    INSTALL_NOTIFICATIONS=true ;;
    --preflight)        PREFLIGHT_ONLY=true ;;
    --recover)          RECOVER_ONLY=true; _FLAG_STRATEGY="upgrade" ;;
    --repair-stale)     REPAIR_STALE=true; _FLAG_STRATEGY="upgrade" ;;
    --json)             JSON_OUTPUT=true ;;
    --global-agent|--project-agent)
      ;;
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
      blank
      echo "Interactive (no flags): prompts 'What are you doing?' and guides from there."
      blank
      echo "Layer flags (override the intent menu):"
      echo "  --global-only         Install ~/.claude/ layer only (CLAUDE.md + skills)"
      echo "  --project-only        Scaffold project layer only"
      echo "  --global-agent <name> Global agent target: claude | codex | both | none"
      echo "  --project-agent <name> Project agent target: claude | codex | both | none"
      echo "  --preflight           Validate targets and prerequisites without writing"
      echo "  --recover             Restore the last interrupted upgrade transaction"
      echo "  --repair-stale        Remove only confirmed-missing manifest entries"
      echo "  --json                Emit JSON (valid only with --preflight)"
      blank
      echo "Non-interactive flags (bypass all prompts — useful for scripting and CI):"
      echo "  --strategy <name>     Set strategy directly."
      echo "                        Values: merge | skip | overwrite | upgrade | interactive |"
      echo "                                agent-plan | agent-upgrade"
      echo "                        merge    — new/drop-in install (safe default; smart-merges settings.json)"
      echo "                        skip     — only install files that don't exist yet"
      echo "                        upgrade  — auto-update unmodified Rig files; prompt on customized; skip user-owned"
      echo "                        overwrite — replace everything; back up originals"
      echo "                        agent-plan    — read-only: emit a JSON plan of what upgrade"
      echo "                                        would do; zero writes; exit 3 if any file"
      echo "                                        needs manual review (see UPGRADE_WORKFLOW.md)"
      echo "                        agent-upgrade — apply the same convergence as 'upgrade' and"
      echo "                                        emit a JSON result; exit 3 if any file was"
      echo "                                        left for manual review"
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
      blank
      echo "Other:"
      echo "  --rig-dir <path>      Install .rig/ to an external path outside the repo."
      echo "                        Writes a .rigpath pointer file at the project root."
      echo "                        Useful for shared repos where teammates don't use The Rig."
      echo "  --feature-docs        Install feature-documentation commands (opt-in)."
      echo "                        Includes: /doc-feature, /doc-list, /feature-context,"
      echo "                        /refresh-feature-doc, and docs/features/README.md."
      echo "                        Skipped by default — add for projects that maintain"
      echo "                        end-to-end feature traces."
      echo "  --subagents           Install multi-agent hook (opt-in)."
      echo "                        Installs subagent-start.sh and wires the SubagentStart"
      echo "                        event in settings.json. Skipped by default — add for"
      echo "                        projects that use Claude Code multi-agent workflows."
      echo "  --contribute          Install Rig contributor commands (opt-in)."
      echo "  --notifications       Enable audible/visual agent notifications (opt-in)."
      echo "                        Installs /rig-gaps and /rig-propose. Useful for"
      echo "                        developers who maintain The Rig or a fork."
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
  case "${args[$i]}" in
    --global-agent|--project-agent)
      if [[ $((i+1)) -ge ${#args[@]} || "${args[$((i+1))]}" == --* ]]; then
        error "${args[$i]} requires a value"
        exit 2
      fi ;;
  esac
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
  if [[ "${args[$i]}" == "--global-agent" && $((i+1)) -lt ${#args[@]} ]]; then
    _FLAG_GLOBAL_AGENT="${args[$((i+1))]}"
  fi
  if [[ "${args[$i]}" == "--project-agent" && $((i+1)) -lt ${#args[@]} ]]; then
    _FLAG_PROJECT_AGENT="${args[$((i+1))]}"
  fi
done

# Set AGENT_MODE/AGENT_DRY_RUN as soon as --strategy is known (rather than
# down in the intent-menu bypass block below) so the info/success/warn/bold/
# ask/confirm wrappers defined at the top of this script — and every banner
# or prompt printed between here and the intent-menu block — are already
# gated before anything runs. The intent-menu block below still owns setting
# COLLISION_STRATEGY itself.
case "$_FLAG_STRATEGY" in
  agent-plan)
    AGENT_MODE="plan"
    AGENT_DRY_RUN=true
    ;;
  agent-upgrade)
    AGENT_MODE="apply"
    AGENT_DRY_RUN=false
    ;;
esac

# Agent-target contract. Selectors are intentionally separate from layer flags.
if [[ "$JSON_OUTPUT" == true && "$PREFLIGHT_ONLY" != true ]]; then
  error "--json is valid only with --preflight"
  exit 2
fi
if [[ "$DO_GLOBAL" != true && -n "$_FLAG_GLOBAL_AGENT" ]] ||
   [[ "$DO_PROJECT" != true && -n "$_FLAG_PROJECT_AGENT" ]]; then
  error "An agent selector was supplied for a disabled layer"
  exit 2
fi
for _agent_value in "${_FLAG_GLOBAL_AGENT:-claude}" "${_FLAG_PROJECT_AGENT:-claude}"; do
  case "$_agent_value" in claude|codex|both|none) ;; *)
    error "Invalid agent target '$_agent_value' (expected claude, codex, both, or none)"
    exit 2 ;;
  esac
done
GLOBAL_AGENT="${_FLAG_GLOBAL_AGENT:-claude}"
PROJECT_AGENT="${_FLAG_PROJECT_AGENT:-claude}"

if [[ -t 0 && "$PREFLIGHT_ONLY" != true && "$INSTALL_NOTIFICATIONS" != true ]]; then
  confirm "Enable audible/visual agent notifications?" "n" && INSTALL_NOTIFICATIONS=true || true
fi

agent_json() {
  case "$1" in
    claude) printf '["claude"]' ;;
    codex) printf '["codex"]' ;;
    both) printf '["claude","codex"]' ;;
    none) printf '[]' ;;
  esac
}
has_agent() { [[ "$1" == "$2" || "$1" == both ]]; }

read_agent_state() {
  local state_file="$1"
  [[ -f "$state_file" ]] || return 1
  python3 "$SCRIPT_DIR/installer/read-target-state.py" "$state_file"
}

write_agent_state() {
  local state_file="$1" layer="$2" selection="$3" project_root="${4:-}" tmp selection_json
  # agent-plan: classification only, never write target-state metadata.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  mkdir -p "$(dirname "$state_file")"
  tmp="$(mktemp "${state_file}.tmp.XXXXXX")"
  selection_json="$(agent_json "$selection")"
  python3 - "$tmp" "$layer" "$selection_json" "$INSTALLER_VERSION" "$project_root" <<'PYEOF'
import json, sys
path, layer, selection, version, project_root = sys.argv[1:]
data = {
    "schema": "https://the-rig.dev/schemas/install-targets/v1",
    "schema_version": 1,
    "layer": layer,
    "agents": json.loads(selection),
    "updated_by": {"installer_version": version},
}
if project_root:
    data["project_root"] = project_root
with open(path, "w") as f:
    json.dump(data, f, separators=(",", ":"))
    f.write("\n")
PYEOF
  mv "$tmp" "$state_file"
}

read_project_root() {
  local state_file="$1"
  python3 - "$state_file" <<'PYEOF'
import json, sys
try:
    with open(sys.argv[1]) as f:
        value = json.load(f).get("project_root", "")
except (OSError, ValueError, TypeError):
    value = ""
print(value if isinstance(value, str) else "")
PYEOF
}

rewrite_project_root_references() {
  local path="$1" old_root="$2" new_root="$3" tmp
  [[ -f "$path" && -n "$old_root" && "$old_root" != "$new_root" ]] || return 0
  # agent-plan: classification only, never rewrite moved-project paths.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  tmp="$(mktemp "${path}.tmp.XXXXXX")"
  if ! python3 - "$path" "$tmp" "$old_root" "$new_root" <<'PYEOF'
import json, sys
source, destination, old_root, new_root = sys.argv[1:]
with open(source) as f:
    data = json.load(f)
def rewrite(value):
    if isinstance(value, dict):
        return {key: rewrite(item) for key, item in value.items()}
    if isinstance(value, list):
        return [rewrite(item) for item in value]
    if isinstance(value, str):
        return value.replace(old_root, new_root)
    return value
with open(destination, "w") as f:
    json.dump(rewrite(data), f, indent=2)
    f.write("\n")
PYEOF
  then
    rm -f "$tmp"
    return 1
  fi
  mv "$tmp" "$path"
}

run_capability_smoke() {
  local layer="$1" selection="$2" root="$3" agents result status
  agents="$(agent_json "$selection" | tr -d '[]"' | tr -d ' ')"
  set +e
  result="$(python3 "$SCRIPT_DIR/installer/check-capabilities.py" "$CAPABILITY_MANIFEST" --layer "$layer" --agents "$agents" --root "$root")"; status=$?
  set -e
  printf '%s' "$result"
  return "$status"
}

# Upgrade-only run accounting. Keep this separate from per-file output so an
# automated caller can determine whether a successful run still needs review.
UPGRADE_UPDATED_COUNT=0
UPGRADE_MERGED_COUNT=0
# Distinct from UPGRADE_MERGED_COUNT (settings.json's existing additive-dedup
# smart-merge). This counts files resolved by the general-purpose
# structure-aware/three-way convergence engine added in issue #444 lane
# 444-C -- see attempt_convergence_merge() below.
UPGRADE_CONVERGED_COUNT=0
UPGRADE_SKIPPED_CUSTOMIZED_COUNT=0
UPGRADE_SKIPPED_UNTRACKED_COUNT=0
UPGRADE_SKIPPED_CUSTOMIZED_FILES=()
UPGRADE_SKIPPED_CONFLICT_COUNT=0
UPGRADE_SKIPPED_CONFLICT_FILES=()
UPGRADE_REMOVED_COUNT=0
UPGRADE_STALE_COUNT=0
# Subset of UPGRADE_STALE_COUNT that --repair-stale did not (and, for
# wrong-type/symlink categories, never will) resolve automatically. Drives
# UPGRADE_REVIEW_REQUIRED below without penalizing a run that just repaired
# every missing-entry finding it could.
UPGRADE_STALE_UNREPAIRED_COUNT=0
UPGRADE_STALE_FILES=()
# Manifest entries whose base_revision claims an installer VERSION newer
# than the one currently running (issue #463) — see
# report_future_manifest_revisions()/validate_manifest_provenance() below.
# Always zero for an ordinary manifest; drives UPGRADE_REVIEW_REQUIRED the
# same way UPGRADE_STALE_UNREPAIRED_COUNT does.
UPGRADE_FUTURE_REVISION_COUNT=0
UPGRADE_FUTURE_REVISION_FILES=()
# Full per-artifact log, one entry per record_upgrade_result() call, encoded as
# "<rel>\x1e<result>\x1e<detail>" (US = 0x1E, never legal in a path or in the
# JSON-encoded detail payload). Consumed only by the agent-plan/agent-upgrade
# JSON emitter at the end of the script to build the "artifacts"/"conflicts"
# arrays; unrelated to (and additive with) the *_COUNT bookkeeping above,
# which existing human-oriented output already relies on unchanged. `detail`
# is an optional JSON-encoded array of specific conflicting keys/lines (see
# attempt_convergence_merge()); empty for every result code that predates
# issue #444 lane 444-C.
UPGRADE_ARTIFACT_RECORDS=()

record_upgrade_result() {
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  local result="$1" rel="${2:-}" detail="${3:-}"
  UPGRADE_ARTIFACT_RECORDS[${#UPGRADE_ARTIFACT_RECORDS[@]}]="${rel}"$'\x1e'"${result}"$'\x1e'"${detail}"
  case "$result" in
    updated) UPGRADE_UPDATED_COUNT=$((UPGRADE_UPDATED_COUNT + 1)) ;;
    merged) UPGRADE_MERGED_COUNT=$((UPGRADE_MERGED_COUNT + 1)) ;;
    converged) UPGRADE_CONVERGED_COUNT=$((UPGRADE_CONVERGED_COUNT + 1)) ;;
    skipped-customized)
      UPGRADE_SKIPPED_CUSTOMIZED_COUNT=$((UPGRADE_SKIPPED_CUSTOMIZED_COUNT + 1))
      UPGRADE_SKIPPED_CUSTOMIZED_FILES[${#UPGRADE_SKIPPED_CUSTOMIZED_FILES[@]}]="$rel"
      ;;
    skipped-untracked)
      UPGRADE_SKIPPED_UNTRACKED_COUNT=$((UPGRADE_SKIPPED_UNTRACKED_COUNT + 1))
      ;;
    skipped-conflict)
      UPGRADE_SKIPPED_CONFLICT_COUNT=$((UPGRADE_SKIPPED_CONFLICT_COUNT + 1))
      UPGRADE_SKIPPED_CONFLICT_FILES[${#UPGRADE_SKIPPED_CONFLICT_FILES[@]}]="$rel"
      ;;
    removed) UPGRADE_REMOVED_COUNT=$((UPGRADE_REMOVED_COUNT + 1)) ;;
  esac
}

# Classify an upgrade destination without following its leaf or parent
# symlinks. The result is deliberately a small public vocabulary used by the
# upgrade summary and tests; no path content is emitted.
upgrade_destination_state() {
  python3 - "$1" "$2" <<'PYEOF'
import os
import sys

base, destination = (os.path.abspath(value) for value in sys.argv[1:])

try:
    if os.path.commonpath((base, destination)) != base:
        print("outside-root")
        raise SystemExit(0)
except ValueError:
    print("outside-root")
    raise SystemExit(0)

if os.path.islink(base):
    print("symlinked-root")
    raise SystemExit(0)

relative = os.path.relpath(destination, base)
parts = relative.split(os.sep)
current = base
for component in parts[:-1]:
    if component in ("", "."):
        continue
    current = os.path.join(current, component)
    if os.path.islink(current):
        print("symlinked-parent")
        raise SystemExit(0)
    if os.path.lexists(current) and not os.path.isdir(current):
        print("parent-wrong-type")
        raise SystemExit(0)

if not os.path.lexists(destination):
    print("missing")
elif os.path.islink(destination):
    print("symlink")
elif os.path.isfile(destination):
    print("regular-file")
elif os.path.isdir(destination):
    print("directory")
else:
    print("wrong-type")
PYEOF
}

record_upgrade_destination_conflict() {
  local rel="$1" state="$2"
  warn "Preserved conflicting upgrade destination: ${rel:-unknown} (${state})"
  record_upgrade_result skipped-conflict "$rel"
}

upgrade_set_executable_bits() {
  local directory="$1" pattern="$2" rel="$3" path
  if [[ -L "$directory" ]]; then
    record_upgrade_destination_conflict "$rel" symlinked-parent
    return 0
  fi
  # agent-plan: classification only, never change file modes.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  while IFS= read -r -d '' path; do
    chmod +x "$path"
  done < <(find -P "$directory" -maxdepth 1 -type f -name "$pattern" -print0)
}

# Shared no-follow safety check for any direct-writer mutation: only a
# missing destination or an existing regular file is writable; anything
# else (symlink, directory, other) is refused rather than silently
# destroyed. Strategy-agnostic on purpose -- see upgrade_prepare_mutation()
# below for the upgrade-only wrapper most callers actually want, and
# _stealth_install_git_hook() for the one caller that needs this check
# unconditionally, regardless of COLLISION_STRATEGY (retro-audit finding,
# found by /rig-surface-review's first real end-to-end run on
# chore/1.24.0-retro-audit itself: upgrade_prepare_mutation()'s own
# upgrade-only guard, below, silently no-ops under every strategy except
# "upgrade" -- including "merge", the default for every fresh install --
# so the #451 symlink-refusal fix it was meant to deliver never actually
# applied to a merge-strategy re-run with an existing customized/symlinked
# hook. Proven via direct repro: a merge-strategy install onto a project
# with .git/hooks/pre-commit symlinked outside the project silently
# overwrote the symlink's target in place, printing "A backup will be
# saved..." while creating zero backup.)
guard_destination_before_write() {
  local base="$1" destination="$2" rel="$3" state
  state="$(upgrade_destination_state "$base" "$destination")"
  case "$state" in
    missing)
      # Journal a first-ever creation the same way copy_file()/
      # _copy_global_file_upgrade()'s own missing-destination branches
      # already do, so an interrupted run rolls back to "absent" rather
      # than leaving a half-written file with no recovery record.
      ensure_upgrade_transaction "$base"
      record_created "$base" "$destination"
      return 0
      ;;
    regular-file)
      ensure_upgrade_transaction "$base"
      backup_file "$destination" "$base"
      return 0
      ;;
    *)
      record_upgrade_destination_conflict "$rel" "$state"
      return 1
      ;;
  esac
}

# Guard upgrade-only mutations that happen after the manifest-aware copy path.
# These operations must have the same no-follow semantics as copy_file(): only
# a missing destination or an existing regular file is writable. A conflict is
# reported once and preserved for explicit operator repair.
#
# Covers the "direct writer" mutation family that mutate a destination in
# place rather than copying a template file into it via copy_file(). Unlike
# copy_file()'s own upgrade path, these callers never called backup_file()
# themselves, so an interrupted run between two of these direct writes
# previously had nothing to roll back to (issue #444, lane 444-F). An
# existing regular-file destination is now journaled and backed up here,
# once, before the caller is allowed to mutate it — same transaction/journal
# machinery copy_file() already uses, so recover_upgrade_transaction()
# restores it identically.
#
# Upgrade-only by design: correct ONLY for callers whose write is itself
# semantically upgrade-only (comparing against a prior install's manifest
# baseline, or gated behind an enclosing `COLLISION_STRATEGY == upgrade`
# check the caller already has) -- for those, no-oping under every other
# strategy is the intended behavior. Settings merges, .rigpath, .rig/VERSION,
# target-state metadata, .codex/config.toml, and placeholder substitutions
# were originally routed through this wrapper on the mistaken assumption
# that they were all upgrade-only too, even though most of them write on
# every strategy (merge is the default for every fresh install) -- the
# wrapper silently skipped their symlink-refusal/backup protection outside
# an explicit --strategy upgrade run. Issue #482's audit swept every then-
# existing call site and migrated everything reached under a non-upgrade
# strategy to guard_destination_before_write() directly, matching the
# .git/hooks/*, notification-helper, global settings.json, and Codex-config
# precedent (issues #451/#470/#471, #477). Do NOT add a new caller here
# unless its write is provably upgrade-only by one of the two tests above --
# call guard_destination_before_write() directly instead, as every other
# direct-writer mutation in this file now does.
upgrade_prepare_mutation() {
  local base="$1" destination="$2" rel="$3"
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  guard_destination_before_write "$base" "$destination" "$rel"
}

# Same upgrade-only gate as upgrade_prepare_mutation() had before issue #482's
# audit -- its one call site (global .claude root creation) has no enclosing
# COLLISION_STRATEGY==upgrade check, so this silently no-ops under merge too.
# Out of #482's scope (that audit covered upgrade_prepare_mutation() call
# sites specifically); tracked separately as issue #489.
upgrade_prepare_directory() {
  local base="$1" destination="$2" rel="$3" state
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  state="$(upgrade_destination_state "$base" "$destination")"
  case "$state" in
    missing|directory) return 0 ;;
    *)
      record_upgrade_destination_conflict "$rel" "$state"
      return 1
      ;;
  esac
}

upgrade_manifest_base() {
  local manifest_file="$1"
  case "$manifest_file" in
    "$GLOBAL_MANIFEST_FILE"|"$CODEX_GLOBAL_MANIFEST_FILE") printf '%s\n' "$HOME" ;;
    *) dirname "$(dirname "$manifest_file")" ;;
  esac
}

# Strategy-agnostic on purpose, matching guard_destination_before_write() --
# called from write_manifest_entry() on nearly every write this script
# performs, under every strategy (merge is the default for every fresh
# install), not just upgrade. Previously gated on COLLISION_STRATEGY==upgrade
# like upgrade_prepare_mutation() was before issue #482's audit, so manifest-
# file symlink protection was effectively dead outside --strategy upgrade.
# Confirmed live: a symlinked .rig-manifest under --strategy merge was
# silently replaced with no refusal or warning (write_manifest_entry()'s
# rename-based write drops the symlink itself rather than following it, but
# still destroys it with zero protection). Issue #490; out of #482's scope,
# which covered upgrade_prepare_mutation() call sites specifically.
upgrade_manifest_mutation_allowed() {
  local manifest_file="$1" rel="$2" base state destination
  base="$(upgrade_manifest_base "$manifest_file")"
  for destination in "$manifest_file" "${manifest_file}.json"; do
    state="$(upgrade_destination_state "$base" "$destination")"
    case "$state" in
      missing|regular-file) ;;
      *)
        record_upgrade_destination_conflict "$rel" "$state"
        return 1
        ;;
    esac
  done
  return 0
}

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
if [[ "$JSON_OUTPUT" != true ]]; then
  blank
  bold "╔══════════════════════════════════════╗"
  bold "║         The Rig — Installer          ║"
  bold "╚══════════════════════════════════════╝"
  blank
fi

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
    agent-plan|agent-upgrade)
      # Agent-driven contract (issue #444, lane 444-A). Non-interactive-only —
      # deliberately absent from the interactive intent menu above so a human
      # can never land here by accident. Both modes reuse the exact same
      # discovery/classification code path as --strategy upgrade internally;
      # agent-plan additionally sets AGENT_DRY_RUN so every mutation primitive
      # it reaches becomes a no-op and the run is provably read-only.
      COLLISION_STRATEGY="upgrade"
      if [[ "$_FLAG_STRATEGY" == agent-plan ]]; then
        AGENT_MODE="plan"
        AGENT_DRY_RUN=true
      else
        AGENT_MODE="apply"
        AGENT_DRY_RUN=false
      fi
      ;;
    *)
      warn "Unknown --strategy value '${_FLAG_STRATEGY}' — defaulting to interactive."
      COLLISION_STRATEGY="interactive"
      ;;
  esac
  _SKIP_COMPONENT_SELECTION=true
elif [[ "$PREFLIGHT_ONLY" == true ]]; then
  # Read-only preflight must never enter the interactive intent flow.
  COLLISION_STRATEGY="merge"
  _SKIP_COMPONENT_SELECTION=true
else
  echo "What are you doing?"
  blank
  echo "  1) First install  — set up The Rig on this machine for the first time"
  echo "                      (installs global layer + scaffolds a project)"
  echo "  2) New project    — scaffold The Rig into a project"
  echo "                      (global layer already installed)"
  echo "  3) Upgrade        — update The Rig in a project that already has it"
  echo "                      (updates hooks, commands, and processes; preserves your files)"
  echo "  4) Repair         — overwrite all Rig-owned files and start fresh"
  echo "                      (backs up originals to .rig-backup/)"
  echo "  5) Custom         — full control over layers, strategy, and components"
  blank
  read -r -p "$(echo -e "${BOLD}?${RESET} Choose [1/2/3/4/5] (default: 2): ")" intent_input || true
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
      blank
      echo "Collision strategy:"
      echo "  1) Interactive  — ask me for each file"
      echo "  2) Skip         — keep all existing files, only install new ones"
      echo "  3) Overwrite    — replace everything (backs up originals to .rig-backup/)"
      echo "  4) Merge        — smart-merge .claude/settings.json; skip everything else"
      echo "  5) Upgrade      — update Rig-owned files; skip user-owned; diff on custom"
      blank
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

[[ "$JSON_OUTPUT" != true ]] && blank
if [[ "$JSON_OUTPUT" != true ]]; then info "Strategy: ${COLLISION_STRATEGY}"; blank; fi

choose_agent_target() {
  local layer="$1" choice
  echo "Agent target for the $layer layer:" >&2
  echo "  1) Claude  2) Codex  3) Both  4) None" >&2
  read -r -p "$(echo -e "${BOLD}?${RESET} Choose [1/2/3/4] (default: 1): ")" choice
  case "${choice:-1}" in 1) echo claude;; 2) echo codex;; 3) echo both;; 4) echo none;; *) error "Invalid target choice"; return 2;; esac
}
_INTERACTIVE_AGENT_CHOICE=false
if [[ -t 0 && "$PREFLIGHT_ONLY" != true && -z "$AGENT_MODE" ]]; then
  [[ "$DO_GLOBAL" == true && -z "$_FLAG_GLOBAL_AGENT" ]] && GLOBAL_AGENT="$(choose_agent_target global)"
  [[ "$DO_PROJECT" == true && -z "$_FLAG_PROJECT_AGENT" ]] && PROJECT_AGENT="$(choose_agent_target project)"
  _INTERACTIVE_AGENT_CHOICE=true
  echo "Target matrix: global=$GLOBAL_AGENT project=$PROJECT_AGENT"
  confirm "Continue with this target matrix?" "y" || exit 0
fi

GLOBAL_TARGET_STATE="$HOME/.rig/install-targets.json"
_GLOBAL_STATE_FUTURE=false
_GLOBAL_STATE_ERROR=""
PREVIOUS_GLOBAL_AGENT=""
if [[ "$COLLISION_STRATEGY" == upgrade && "$DO_GLOBAL" == true && -f "$GLOBAL_TARGET_STATE" ]]; then
  _saved_global="$(read_agent_state "$GLOBAL_TARGET_STATE")" || _state_status=$?
  PREVIOUS_GLOBAL_AGENT="${_saved_global:-}"
  if [[ "${_state_status:-0}" -eq 3 ]]; then
    _GLOBAL_STATE_FUTURE=true
    [[ -n "$_FLAG_GLOBAL_AGENT" ]] || _GLOBAL_STATE_ERROR="future global metadata requires explicit selector"
  elif [[ "${_state_status:-0}" -eq 2 ]]; then _GLOBAL_STATE_ERROR="malformed global target metadata"
  elif [[ -z "$_FLAG_GLOBAL_AGENT" && "$_INTERACTIVE_AGENT_CHOICE" != true ]]; then GLOBAL_AGENT="$_saved_global"
  fi
fi
[[ "$JSON_OUTPUT" != true ]] && info "Agent targets: global=${GLOBAL_AGENT} project=${PROJECT_AGENT}"

{
  _preflight_target="${_FLAG_TARGET:-$(pwd)}"
  _repo_state="$_preflight_target/.rig/install-targets.json"
  _stealth_state="$HOME/.rig/projects/${_FLAG_PROJECT_NAME:-$(basename "$_preflight_target")}/install-targets.json"
  _pointer_state=""
  [[ -f "$_preflight_target/.rigpath" ]] && _pointer_state="$(sed -n '1p' "$_preflight_target/.rigpath")/install-targets.json"
  _preflight_project_state="$_repo_state"
  _state_discovery_error=""
  if [[ "${_FLAG_TRACKING:-}" == repo || "${_FLAG_TRACKING:-}" == local ]]; then
    _preflight_project_state="$_repo_state"
  elif [[ "${_FLAG_TRACKING:-}" == external || "${_FLAG_TRACKING:-}" == stealth ]]; then
    _preflight_rig_dir="${EXTERNAL_RIG_DIR:-$HOME/.rig/projects/${_FLAG_PROJECT_NAME:-$(basename "$_preflight_target")}}"
    _preflight_project_state="$_preflight_rig_dir/install-targets.json"
  elif [[ -n "$EXTERNAL_RIG_DIR" ]]; then
    _preflight_project_state="$EXTERNAL_RIG_DIR/install-targets.json"
  elif [[ -n "$_pointer_state" ]]; then
    _preflight_project_state="$_pointer_state"
  elif [[ -d "$_preflight_target/.rig" && -n "$(git -C "$_preflight_target" ls-files -- ".rig/" 2>/dev/null)" ]]; then
    _preflight_project_state="$_repo_state"
  elif [[ -d "$_preflight_target/.rig" ]] &&
       { /usr/bin/grep -qF '.rig/' "$_preflight_target/.git/info/exclude" 2>/dev/null ||
         /usr/bin/grep -qF '.rig/' "$_preflight_target/.gitignore" 2>/dev/null; }; then
    _preflight_project_state="$_repo_state"
  else
    # With no conclusive tracking evidence, compare all surviving candidates.
    _discovered_state=""
    for _candidate in "$_pointer_state" "$_repo_state" "$_stealth_state"; do
      [[ -n "$_candidate" && -f "$_candidate" ]] || continue
      if [[ -z "$_discovered_state" ]]; then _discovered_state="$_candidate"
      elif ! cmp -s "$_discovered_state" "$_candidate"; then
        _state_discovery_error="conflicting project target metadata: $_discovered_state and $_candidate"
      fi
    done
    if [[ -n "$_discovered_state" ]]; then _preflight_project_state="$_discovered_state"
    else _preflight_project_state="${_pointer_state:-$_stealth_state}"
    fi
  fi
  _state_args=()
  [[ -n "$_GLOBAL_STATE_ERROR" ]] && _state_args+=(--state-error "$_GLOBAL_STATE_ERROR")
  [[ -n "$_state_discovery_error" ]] && _state_args+=(--state-error "$_state_discovery_error")
  if [[ "$COLLISION_STRATEGY" == upgrade && "$DO_PROJECT" == true && -f "$_preflight_project_state" ]]; then
    _saved_project="$(read_agent_state "$_preflight_project_state")" || _project_state_status=$?
    if [[ "${_project_state_status:-0}" -eq 3 ]]; then
      [[ -n "$_FLAG_PROJECT_AGENT" ]] || { [[ "$JSON_OUTPUT" == true ]] || error "Future project target metadata requires --project-agent"; _state_args+=(--state-error "future project metadata requires explicit selector"); }
    elif [[ "${_project_state_status:-0}" -eq 2 ]]; then _state_args+=(--state-error "malformed project target metadata")
    elif [[ -z "$_FLAG_PROJECT_AGENT" ]]; then PROJECT_AGENT="$_saved_project"
    fi
  fi
  _render_args=(--manifest "$CAPABILITY_MANIFEST" --version "$INSTALLER_VERSION" --operation "$COLLISION_STRATEGY" --global-agent "$GLOBAL_AGENT" --project-agent "$PROJECT_AGENT" --global-destination "$HOME/.claude" --project-destination "$_preflight_target")
  [[ "$DO_GLOBAL" == true ]] && _render_args+=(--global-enabled)
  [[ "$DO_PROJECT" == true ]] && _render_args+=(--project-enabled)
  [[ "$DO_PROJECT" == true && "$PROJECT_AGENT" != none && -f "$_preflight_target/package.json" ]] && _render_args+=(--project-husky)
  set +e
  _preflight_json="$(python3 "$SCRIPT_DIR/installer/render-preflight.py" "${_render_args[@]}" ${_state_args[@]+"${_state_args[@]}"})"; _preflight_status=$?
  set -e
  # agent-plan/agent-upgrade must print exactly one JSON document on
  # stdout, as their own contract (and templates/project/.rig/processes/
  # UPGRADE_WORKFLOW.md) explicitly documents. Retro-audit finding, PR
  # #446: this narrative summary was gated only on JSON_OUTPUT (true only
  # for the separate, explicit --preflight --json mode), so it always
  # printed ahead of the real result on every agent-mode run -- a caller
  # doing json.loads(stdout) on the first/only line would break. AGENT_MODE
  # is non-empty for both agent-plan and agent-upgrade; suppress this
  # intermediate preflight narration (and its own separate JSON blob,
  # which is not the final single document either) for both.
  if [[ "$JSON_OUTPUT" == true ]]; then printf '%s\n' "$_preflight_json"
  elif [[ -z "$AGENT_MODE" ]]; then
    echo "Target matrix: global=$GLOBAL_AGENT project=$PROJECT_AGENT"
    python3 -c 'import json,sys; d=json.load(sys.stdin); print("Missing prerequisites: " + (", ".join(x["id"] for x in d["dependencies"] if x["status"] != "ok" and x["classification"] != "optional") or "none")); print("Degraded features: " + (", ".join(d["degraded_features"]) or "none")); print("Next steps: " + (", ".join(d["next_steps"]) or "none"))' <<< "$_preflight_json"
  fi
  [[ "$PREFLIGHT_ONLY" == true ]] && exit "$_preflight_status"
  if [[ "$_preflight_status" -ne 0 ]]; then error "Required preflight checks failed before writes."; exit "$_preflight_status"; fi
}
if [[ -n "$_GLOBAL_STATE_ERROR" ]]; then error "$_GLOBAL_STATE_ERROR"; [[ "$_GLOBAL_STATE_FUTURE" == true ]] && exit 2 || exit 1; fi

_all_enabled_none=true
[[ "$DO_GLOBAL" == true && "$GLOBAL_AGENT" != none ]] && _all_enabled_none=false
[[ "$DO_PROJECT" == true && "$PROJECT_AGENT" != none ]] && _all_enabled_none=false
if [[ "$_all_enabled_none" == true ]]; then
  success "All enabled layers selected none; no files or metadata were written."
  exit 0
fi

# ── BACKUP HELPER ─────────────────────────────────────────────────────────────
# Used by overwrite strategy. In stealth/external mode, backs up to
# $EXTERNAL_RIG_DIR/backups/<timestamp>/ so no traces land in the project repo.
# Otherwise backs up to <target>/.rig-backup/<timestamp>/
BACKUP_DIR=""
BACKUP_TS="$(date +%Y%m%d_%H%M%S)"
UPGRADE_JOURNAL=""
UPGRADE_TRANSACTION_ACTIVE=false
UPGRADE_TRANSACTION_BASE=""

# Upgrade transactions deliberately contain only operation types and relative
# paths. They are local recovery metadata, never copied to reports or printed
# with file contents. A fixed in-progress directory makes an interrupted run
# discoverable on the next invocation; successful runs are renamed to the
# timestamped backup directory below.
journal_append() {
  local operation="$1" rel="$2" tmp
  [[ -n "$UPGRADE_JOURNAL" ]] || return 0
  tmp="$(mktemp "${UPGRADE_JOURNAL}.tmp.XXXXXX")"
  if [[ -f "$UPGRADE_JOURNAL" ]]; then cat "$UPGRADE_JOURNAL" > "$tmp"; fi
  printf '%s\t%s\n' "$operation" "$rel" >> "$tmp"
  mv "$tmp" "$UPGRADE_JOURNAL"
}

upgrade_relpath_safe() {
  # Journal entries are installer-generated relative paths. Reject anything
  # that could escape the selected base or cross a symlink during recovery.
  local base="$1" rel="$2" component path
  [[ -n "$rel" && "$rel" != /* ]] || return 1
  case "$rel" in
    .|..|./*|../*|*/./*|*/../*|*//*|*$'\t'*|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  path="$base"
  while IFS= read -r component; do
    [[ -n "$component" ]] || return 1
    path="$path/$component"
    [[ -L "$path" ]] && return 1
  done < <(printf '%s\n' "$rel" | tr '/' '\n')
  return 0
}

recover_upgrade_transaction() {
  local base="$1"
  local transaction="$base/.rig-backup/.in-progress"
  local journal="$transaction/.journal"
  [[ -f "$journal" ]] || return 0
  if [[ -L "$transaction" || ! -d "$transaction" ]]; then
    error "Unsafe interrupted upgrade transaction path: $transaction"
    return 2
  fi
  warn "Interrupted Rig upgrade detected; restoring its last transaction."
  local operation rel destination backup recovery_failed=false
  while IFS=$'\t' read -r operation rel; do
    [[ -n "$operation" && -n "$rel" ]] || continue
    if ! upgrade_relpath_safe "$base" "$rel" || ! upgrade_relpath_safe "$transaction" "$rel"; then
      error "Unsafe path in interrupted upgrade journal; recovery stopped: $rel"
      recovery_failed=true
      continue
    fi
    destination="$base/$rel"
    case "$operation" in
      backup)
        backup="$transaction/$rel"
        if [[ -f "$backup" && ! -L "$backup" ]]; then
          mkdir -p "$(dirname "$destination")"
          cp "$backup" "$destination"
        else
          error "Missing or unsafe backup in interrupted upgrade journal: $rel"
          recovery_failed=true
        fi
        ;;
      created)
        if [[ -f "$destination" || -L "$destination" ]]; then rm -f "$destination"; fi
        ;;
      *)
        error "Unknown operation in interrupted upgrade journal: $operation"
        recovery_failed=true
        ;;
    esac
  done < <(tac "$journal" 2>/dev/null || tail -r "$journal")
  if [[ "$recovery_failed" == true ]]; then
    error "Interrupted upgrade recovery stopped; review $journal and repair it before retrying."
    return 2
  fi
  rm -rf "$transaction"
  success "Interrupted upgrade restored; rerun Upgrade to converge safely."
}

init_backup_dir() {
  local base="$1"
  if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
    if [[ "$UPGRADE_TRANSACTION_ACTIVE" == true && "$UPGRADE_TRANSACTION_BASE" == "$base" ]]; then
      return
    fi
    if [[ "$UPGRADE_TRANSACTION_ACTIVE" == true ]]; then finish_upgrade_transaction; fi
    BACKUP_DIR="${base}/.rig-backup/.in-progress"
    if [[ -e "$BACKUP_DIR" ]]; then
      error "An interrupted upgrade transaction exists at $BACKUP_DIR; recovery is required."
      exit 1
    fi
    mkdir -p "$BACKUP_DIR"
    UPGRADE_JOURNAL="$BACKUP_DIR/.journal"
    : > "$UPGRADE_JOURNAL"
    UPGRADE_TRANSACTION_ACTIVE=true
    UPGRADE_TRANSACTION_BASE="$base"
    return
  fi
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
  # agent-plan: classification only, never write a backup.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  if [[ -z "$BACKUP_DIR" || "$UPGRADE_TRANSACTION_BASE" != "$base" ]]; then init_backup_dir "$base"; fi
  local rel="${src#"$base"/}"
  local dest="${BACKUP_DIR}/${rel}"
  # A single run can route the same destination through more than one
  # direct-writer mutation (e.g. CLAUDE.md: [Project Name] substitution,
  # then _subst_base_branch(), then the external/stealth @.rig/ rewrite).
  # BACKUP_TS is fixed for the whole run, so $dest is the same path across
  # every such call for a given destination -- if it already exists, an
  # earlier call this run already captured the file's true pre-run state;
  # a later call backing up again would silently overwrite that with this
  # run's own intermediate, already-mutated content instead (issue #482
  # review, filed as #491).
  [[ -e "$dest" ]] && return 0
  mkdir -p "$(dirname "$dest")"
  journal_append backup "$rel"
  cp "$src" "$dest"
}

# ── UNCONDITIONAL BACKUP-BEFORE-WRITE (issue #470) ────────────────────────────
# Every collision-path write that could overwrite an existing file MUST go
# through this function instead of calling `cp` directly. Backing up used to
# be a per-branch responsibility — each classification branch independently
# decided whether a backup was needed before its own `cp` call. That pattern
# is exactly what let a real historical bug (see docs/lessons-learned.md #14)
# silently destroy user-owned CLAUDE.md/PROJECT_BRIEF.md content with no
# recovery path: a classification branch wrongly concluded no backup was
# needed. This function makes "back up first" a structural invariant no
# classification branch can bypass, regardless of which strategy or code path
# led here — init_backup_dir() already branches correctly per
# $COLLISION_STRATEGY (transactional .in-progress dir for `upgrade`, a plain
# timestamped dir for every other strategy), so calling backup_file()
# unconditionally here is safe for all of them.
_upgrade_write() {
  local src="$1" dest="$2" base="$3"
  # agent-plan: classification only, never write or back up.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  if [[ ( -e "$dest" || -L "$dest" ) && -n "$base" ]]; then
    backup_file "$dest" "$base"
  fi
  cp "$src" "$dest"
}

record_created() {
  local base="$1" destination="$2"
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  # agent-plan: classification only, never write the transaction journal.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  journal_append created "${destination#"$base"/}"
}

ensure_upgrade_transaction() {
  local base="$1"
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  # agent-plan: classification only, never open a transaction/backup dir.
  [[ "$AGENT_DRY_RUN" == true ]] && return 0
  init_backup_dir "$base"
}

finish_upgrade_transaction() {
  [[ "$UPGRADE_TRANSACTION_ACTIVE" == true && -n "$BACKUP_DIR" ]] || return 0
  local final_dir final_parent suffix=0
  final_parent="$(dirname "$BACKUP_DIR")"
  final_dir="${final_parent}/${BACKUP_TS}_$$"
  # A single run can open and finalize more than one transaction against the
  # same base — init_backup_dir() above auto-finalizes and reopens whenever
  # ensure_upgrade_transaction()/backup_file() is called with a different
  # base than the currently active one (direct-writer mutations at several
  # points in the project layer legitimately alternate between $TARGET and
  # an external .rig/ root). BACKUP_TS and $$ are fixed for the whole run,
  # so a base revisited later would otherwise compute the exact same
  # final_dir as an earlier, already-finalized transaction; `mv` onto an
  # existing directory nests the new transaction's contents one level deep
  # (final_dir/.in-progress/…) instead of merging them at the top level,
  # silently scrambling the backup layout. Disambiguate with a counter
  # suffix so every finalized transaction directory is unique.
  while [[ -e "$final_dir" ]]; do
    suffix=$((suffix + 1))
    final_dir="${final_parent}/${BACKUP_TS}_${$}_${suffix}"
  done
  # A completed transaction remains as a recoverable backup, but no longer
  # looks interrupted to the next invocation.
  mv "$BACKUP_DIR" "$final_dir"
  BACKUP_DIR="$final_dir"
  UPGRADE_JOURNAL=""
  UPGRADE_TRANSACTION_ACTIVE=false
  UPGRADE_TRANSACTION_BASE=""
}

# ── PRE-FLIGHT SNAPSHOT (issue #472) ──────────────────────────────────────────
# Independent of and prior to the per-file backup_file()/_upgrade_write()
# mechanism above, which only ever backs up a file the copy loop actually
# decides to touch: takes one full recursive "before" snapshot of the target
# project's entire Rig/Claude/Codex footprint into its own timestamped
# location, so a full-tree diff is possible regardless of what the copy loop
# touches. Runs once per real (non-dry-run) upgrade-family invocation, before
# any project-layer write begins. agent-plan (AGENT_DRY_RUN=true) mutates
# nothing, so there is nothing to protect and no snapshot is taken.
PREFLIGHT_SNAPSHOT_DIR=""
preflight_snapshot_project() {
  local base="$1"
  [[ "$COLLISION_STRATEGY" == upgrade ]] || return 0
  [[ "$AGENT_DRY_RUN" == true ]] && return 0

  local snap_root
  if [[ ( "$RIG_TRACKING" == "stealth" || "$RIG_TRACKING" == "external" ) && -n "$EXTERNAL_RIG_DIR" ]]; then
    snap_root="${EXTERNAL_RIG_DIR}/preflight-snapshots"
  else
    snap_root="${base}/.rig-backup/preflight-snapshots"
  fi

  # Retention: keep the 5 most recent snapshots, pruning the oldest before
  # adding a new one. Scoped only to preflight-snapshots/ — independent of
  # the separately-accumulating per-file .rig-backup/<ts>_$$ dirs above,
  # which have no retention policy of their own (out of scope for #472).
  # Snapshot dirs are always our own "<timestamp>_<pid>" names (no spaces,
  # no newlines), so plain lexicographic `sort` on one-per-line output is
  # safe here without needing NUL-delimited find/sort (sort -z is GNU-only
  # and unavailable on macOS's BSD sort).
  if [[ -d "$snap_root" ]]; then
    local -a existing=()
    while IFS= read -r entry; do existing+=("$entry"); done < <(find "$snap_root" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | sort)
    local keep=4 count="${#existing[@]}" i
    if (( count > keep )); then
      for (( i = 0; i < count - keep; i++ )); do
        rm -rf "${existing[$i]}" || { error "Cannot prune old pre-flight snapshot: ${existing[$i]}"; exit 1; }
      done
    fi
  fi

  local snap_dir="${snap_root}/${BACKUP_TS}_$$"
  mkdir -p "$snap_dir" || { error "Cannot create pre-flight snapshot directory: $snap_dir"; exit 1; }

  local -a rel_paths=(
    "CLAUDE.md" "PROJECT_BRIEF.md" ".claude" ".agents" ".codex" ".mcp.json"
    ".playwright-mcp" ".github" ".gitleaks.toml" "docs/features/README.md"
    ".husky" ".rigpath" "bin/rig" ".git/hooks"
  )
  # Tracked .rig/ lives at $base/.rig for repo/exclude tracking, so it's just
  # another base-relative path. external/stealth tracking is handled below —
  # $EXTERNAL_RIG_DIR lives outside $base entirely.
  [[ "$RIG_TRACKING" == "repo" || "$RIG_TRACKING" == "exclude" ]] && rel_paths+=(".rig")

  local rel src dst
  for rel in "${rel_paths[@]}"; do
    src="${base}/${rel}"
    [[ -e "$src" || -L "$src" ]] || continue
    dst="${snap_dir}/${rel}"
    mkdir -p "$(dirname "$dst")" || { error "Cannot create pre-flight snapshot directory: $(dirname "$dst")"; exit 1; }
    cp -R "$src" "$dst" 2>/dev/null || { error "Pre-flight snapshot failed copying $src"; exit 1; }
  done

  # External/stealth .rig/ lives outside $base entirely, at $EXTERNAL_RIG_DIR
  # — which, in this mode, is also this snapshot's own ancestor directory
  # (preflight-snapshots/, backups/, and .rig-backup/ all live inside it;
  # tracked-mode .rig/ never includes .rig-backup/ in the first place, since
  # that lives as a sibling of $base/.rig, not inside it — excluding it here
  # too keeps both tracking modes' snapshot contents consistent). Copy real
  # contents in under snap_dir/.rig, skipping all three so the snapshot never
  # recurses into the snapshot/backup mechanism itself or balloons in size by
  # re-embedding the separately-accumulating, retention-less per-file
  # backup/transaction history on every run.
  if [[ ( "$RIG_TRACKING" == "stealth" || "$RIG_TRACKING" == "external" ) && -n "$EXTERNAL_RIG_DIR" && -d "$EXTERNAL_RIG_DIR" ]]; then
    mkdir -p "${snap_dir}/.rig" || { error "Cannot create pre-flight snapshot directory: ${snap_dir}/.rig"; exit 1; }
    local entry name
    while IFS= read -r -d '' entry; do
      name="$(basename "$entry")"
      case "$name" in
        backups|preflight-snapshots|.rig-backup) continue ;;
      esac
      cp -R "$entry" "${snap_dir}/.rig/${name}" 2>/dev/null || { error "Pre-flight snapshot failed copying $entry"; exit 1; }
    done < <(find "$EXTERNAL_RIG_DIR" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)
  fi

  # Deliberately left for a future consumer (issue #473's post-upgrade
  # doctor validation is expected to diff this snapshot against
  # post-upgrade state) -- not read anywhere else in this change.
  PREFLIGHT_SNAPSHOT_DIR="$snap_dir"
  info "Pre-flight snapshot: $snap_dir"
}

# ── BREAKING CHANGE CHECK ─────────────────────────────────────────────────────
# Print any "### Changed — BREAKING" bullets from CHANGELOG sections that are
# newer than $current_version, then prompt the user to confirm before continuing.
# Silent (returns 0) when: version is unknown, changelog missing, or no breaking
# changes exist in the upgrade range.
_show_breaking_changes() {
  local current_version="$1"
  local changelog="$2"

  [[ "$current_version" == "unknown" ]] && return 0
  [[ -f "$changelog" ]] || return 0

  local breaking_lines
  breaking_lines=$(awk -v ver="$current_version" '
    BEGIN { stop=0; in_breaking=0 }
    /^## \[/ {
      if (index($0, "[" ver "]") > 0) { stop=1 }
      in_breaking=0
    }
    stop { next }
    /^### .*BREAKING/ { in_breaking=1; next }
    /^### / { in_breaking=0 }
    in_breaking && /^- / { print; next }
    # A continuation line runs until the next "### " header, with no
    # blank-line boundary of its own (issue #481 fixed the common case:
    # a 2-space-indented wrapped bullet, matching every real entry in this
    # CHANGELOG.md as of this fix). An indented aside placed after a blank
    # line inside the same BREAKING section, before the next header, would
    # still be swept into the preceding bullet output -- not a known case
    # in this file today, but worth knowing if the format ever grows one.
    in_breaking && /^  / { print }
  ' "$changelog")

  [[ -n "$breaking_lines" ]] || return 0

  blank
  warn "Breaking changes since v${current_version} — review before upgrading:"
  blank
  # warn()/blank() above already self-gate on AGENT_MODE, but this raw echo
  # loop printing each CHANGELOG bullet did not (issue #475) -- reachable by
  # any agent-plan/agent-upgrade run against a project whose installed
  # version has a BREAKING changelog entry ahead of it, violating the
  # documented "exactly one JSON document on stdout" contract those modes
  # rely on. The Rig's own CHANGELOG.md has a real BREAKING section under
  # [1.18.0], so this was concretely reachable, not just theoretical.
  if [[ -z "$AGENT_MODE" ]]; then
    while IFS= read -r line; do
      echo "  $line"
    done <<< "$breaking_lines"
  fi
  blank
  if ! confirm "Continue upgrade with the above breaking changes?" "y"; then
    info "Upgrade cancelled. No files were modified."
    exit 0
  fi
  blank
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

# Remove hook entries for scripts that have been removed from the template.
# When a script is merged into another (e.g. session-end.sh → stop.sh), any
# existing installations still reference the old script. Strip those entries
# before adding the new ones so the installed settings.json stays clean.
_stale_scripts = ["session-end.sh"]
for event in list(existing.get("hooks", {}).keys()):
    existing["hooks"][event] = [
        entry for entry in existing["hooks"][event]
        if not any(
            any(sc in h.get("command", "") for sc in _stale_scripts)
            for h in entry.get("hooks", [])
        )
    ]
    if not existing["hooks"][event]:
        del existing["hooks"][event]

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

# Migrate the two legacy Rig-owned /tmp grants. Match exact strings so user
# permissions and similar-looking Write patterns remain untouched. If the Edit
# replacement is already present, remove only the obsolete Write entry.
legacy_allow_replacements = {
    "Write(/tmp/*.md)": "Edit(/tmp/*.md)",
    "Write(/tmp/*.txt)": "Edit(/tmp/*.txt)",
}
existing_permissions = existing.get("permissions", {})
existing_allow = existing_permissions.get("allow", []) or []
existing_allow_values = set(existing_allow)
migrated_allow = []
for pattern in existing_allow:
    replacement = legacy_allow_replacements.get(pattern)
    if replacement:
        if replacement not in existing_allow_values and replacement not in migrated_allow:
            migrated_allow.append(replacement)
    else:
        migrated_allow.append(pattern)
if migrated_allow != existing_allow:
    existing.setdefault("permissions", {})["allow"] = migrated_allow

# Merge permissions.allow (dedup by pattern string)
incoming_allow = incoming.get("permissions", {}).get("allow", [])
if incoming_allow:
    existing_allow = existing.get("permissions", {}).get("allow", []) or []
    existing_allow_set = set(existing_allow)
    new_patterns = [p for p in incoming_allow if p not in existing_allow_set]
    if new_patterns:
        existing.setdefault("permissions", {}).setdefault("allow", []).extend(new_patterns)

# Merge permissions.deny (dedup by pattern string)
incoming_deny = incoming.get("permissions", {}).get("deny", [])
if incoming_deny:
    existing_deny = existing.get("permissions", {}).get("deny", []) or []
    existing_deny_set = set(existing_deny)
    new_deny = [p for p in incoming_deny if p not in existing_deny_set]
    if new_deny:
        existing.setdefault("permissions", {}).setdefault("deny", []).extend(new_deny)

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
  local dir destination_state
  dir="$(dirname "$dest")"

  if [[ "$COLLISION_STRATEGY" == upgrade && -n "$base" ]]; then
    destination_state="$(upgrade_destination_state "$base" "$dest")"
    case "$destination_state" in
      symlinked-parent|symlinked-root|parent-wrong-type|outside-root|directory|wrong-type)
        record_upgrade_destination_conflict "$rel" "$destination_state"
        return 0
        ;;
    esac
  fi

  # agent-plan: classification only, never create the destination directory.
  [[ "$AGENT_DRY_RUN" == true ]] || mkdir -p "$dir"

  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    if [[ "$COLLISION_STRATEGY" == upgrade && -n "$base" ]]; then
      ensure_upgrade_transaction "$base"
      record_created "$base" "$dest"
    fi
    # No collision — always install (agent-plan: classification only, no write)
    [[ "$AGENT_DRY_RUN" == true ]] || cp "$src" "$dest"
    success "Created ${dest#${base}/}"
    record_upgrade_result updated "${rel:-${dest#${base}/}}"
    # Record ALL files in the manifest (not just Rig-owned) so the Upgrade
    # strategy can later detect whether any file has been customized.
    # settings.json is excluded — it's always smart-merged, not hash-tracked.
    if [[ -n "$rel" && "$(basename "$rel")" != "settings.json" ]]; then
      write_manifest_entry "$(sha256_file "$dest")" "$rel" "$MANIFEST_FILE" "$dest"
    fi
    return
  fi

  # File exists — apply strategy
  case "$COLLISION_STRATEGY" in
    interactive)
      if confirm "Overwrite existing: ${dest#${base}/}?"; then
        _upgrade_write "$src" "$dest" "$base"
        success "Updated ${dest#${base}/}"
        if [[ -n "$rel" && "$(basename "$rel")" != "settings.json" ]]; then
          write_manifest_entry "$(sha256_file "$dest")" "$rel" "$MANIFEST_FILE" "$dest"
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
      # warn and require confirmation before overwriting. The documented
      # contract for this strategy is "replace all Rig-owned files" — user-
      # owned files were never meant to be blindly replaced, customized or
      # not. A missing manifest entry must be treated exactly like a detected
      # customization (same as issue #140's fix for the `upgrade` strategy):
      # we cannot prove the file is untouched, so never silently overwrite it.
      if [[ -n "$rel" ]] && ! is_rig_owned "$rel" && [[ "$(basename "$rel")" != "settings.json" ]]; then
        local _dest_hash _manifest_hash _src_hash
        _dest_hash="$(sha256_file "$dest")"
        _src_hash="$(sha256_file "$src")"
        _manifest_hash="$(read_manifest_hash "$rel")"
        if [[ -z "$_manifest_hash" ]]; then
          blank
          warn "User-owned file with no recorded baseline: ${rel}"
          echo "  This file has never been tracked by an Upgrade run, so whether"
          echo "  it's been customized can't be determined. A backup will be"
          echo "  saved to .rig-backup/ before overwriting."
          blank
          if ! confirm "Overwrite ${rel} with the new template?" "n"; then
            info "Skipped (kept your version, recorded its current hash): ${rel}"
            write_manifest_entry "$_dest_hash" "$rel" "$MANIFEST_FILE" "$dest"
            return
          fi
        elif [[ "$_dest_hash" != "$_manifest_hash" && "$_dest_hash" != "$_src_hash" ]]; then
          blank
          warn "User-modified file: ${rel}"
          echo "  Your version differs from what The Rig originally installed."
          echo "  A backup will be saved to .rig-backup/ before overwriting."
          blank
          if ! confirm "Overwrite ${rel} with the new template?" "n"; then
            info "Skipped (kept your version): ${rel}"
            return
          fi
        fi
      fi
      _upgrade_write "$src" "$dest" "$base"
      success "Overwrote ${dest#${base}/}"
      if [[ -n "$rel" && "$(basename "$rel")" != "settings.json" ]]; then
        write_manifest_entry "$(sha256_file "$dest")" "$rel" "$MANIFEST_FILE" "$dest"
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
          _upgrade_write "$tmp_merged" "$dest" "$base"
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

# Codex artifacts historically preserved every existing destination outside an
# Upgrade. Keep that contract for merge/skip/overwrite while establishing a
# manifest baseline for future manifest-aware upgrades.
copy_codex_owned_initial() {
  local src="$1" dest="$2" base="$3" rel="$4" manifest_file="${5:-$MANIFEST_FILE}"
  mkdir -p "$(dirname "$dest")"
  if [[ -e "$dest" || -L "$dest" ]]; then
    info "Preserved existing: ${dest#${base}/}"
    if [[ -f "$dest" && ! -L "$dest" ]]; then
      write_manifest_entry "$(sha256_file "$dest")" "$rel" "$manifest_file" "$dest"
    fi
    return
  fi
  cp "$src" "$dest"
  success "Created ${dest#${base}/}"
  write_manifest_entry "$(sha256_file "$dest")" "$rel" "$manifest_file" "$dest"
}

# ── STRUCTURE-AWARE / THREE-WAY CONVERGENCE ENGINE (issue #444, lane 444-C) ──
# Only reachable from _copy_upgrade_existing()'s "customized" branch below,
# and only when AGENT_MODE is set (--strategy agent-plan/agent-upgrade).
# Interactive, skip, overwrite, merge, and plain --strategy upgrade never
# call this — their o/s/d prompt and non-interactive skip-with-review
# behavior are unchanged byte-for-byte.
#
# No trusted base/provenance is available yet: issue #444 lane 444-B (which
# adds base_revision/generator/provider manifest fields for exactly this
# purpose) had not merged as of this lane. Every merge helper below is
# called with only --current/--incoming and degrades to a conservative
# 2-way rule in that mode: a key/section/line that differs between the
# current (customized) file and the incoming template is always reported as
# a conflict rather than guessed — see installer/_convergence_common.py.
# Wiring a real --base once 444-B lands is a thin adapter at the call site
# below, not a redesign of the helpers themselves.
agent_convergence_merge_tool() {
  local rel="$1"
  case "$rel" in
    */settings.json|settings.json) echo "" ;;  # already smart-merged elsewhere, never here
    *.json) echo "merge-json.py" ;;
    *.toml) echo "merge-toml.py" ;;
    .claude/commands/*.md|.claude/agents/*.md|.rig/processes/*.md) echo "merge-frontmatter-markdown.py" ;;
    *) echo "merge-text3way.py" ;;
  esac
}

# Attempt a convergence merge for one customized file. The caller invokes
# this via command substitution ($(...)), which runs it in a subshell -- so,
# unlike most helpers in this script, it cannot hand data back through a
# global variable (any assignment would be lost when the subshell exits).
# Everything it returns must go through stdout instead:
#   exit 0 -> stdout is the path of a temp file holding the merged content;
#             the caller is responsible for applying and removing it.
#   exit 1 -> stdout is a JSON-encoded array of the specific conflicting
#             keys/lines (compact, single-line -- safe to capture as one
#             command-substitution value even though individual conflict
#             snippets may contain escaped newlines).
# Never writes to $dest itself.
attempt_convergence_merge() {
  local src="$1" dest="$2" rel="$3" tool out report status
  command -v python3 >/dev/null 2>&1 || { echo "[]"; return 1; }
  tool="$(agent_convergence_merge_tool "$rel")"
  [[ -n "$tool" ]] || { echo "[]"; return 1; }
  out="$(mktemp)"
  set +e
  report="$(python3 "$SCRIPT_DIR/installer/$tool" --current "$dest" --incoming "$src" --output "$out" 2>/dev/null)"
  status=$?
  set -e
  if [[ "$status" -eq 0 ]]; then
    printf '%s\n' "$out"
    return 0
  fi
  rm -f "$out"
  python3 -c '
import json, sys
try:
    doc = json.loads(sys.argv[1])
    conflicts = doc.get("conflicts", [])
    assert isinstance(conflicts, list)
except Exception:
    conflicts = []
print(json.dumps(conflicts, separators=(",", ":")))
' "$report" 2>/dev/null || echo "[]"
  return 1
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
_copy_upgrade_existing() {
  local src="$1"
  local dest="$2"
  local base="${3:-}"
  local rel="${4:-}"
  local manifest_file="$5"
  local settings_mode="$6"
  local rig_owned_default="$7"

  # Never follow a destination symlink while upgrading. In particular, a
  # dangling link must not turn a generated Rig artifact into an arbitrary
  # write outside the target. Require explicit removal before regeneration.
  if [[ -L "$dest" ]]; then
    warn "Customized symlink detected: ${rel}"
    info "Skipped symlink; remove it explicitly to install the generated file."
    record_upgrade_result skipped-conflict "$rel"
    return
  fi

  # ── settings.json: always smart-merge ──────────────────────────────────────
  if [[ "$settings_mode" == "smart-merge" && "$(basename "$dest")" == "settings.json" && "$dest" == *".claude/settings.json" ]]; then
    local tmp_merged tmp_src_subst abs_target escaped_target
    tmp_merged="$(mktemp /tmp/rig-settings-merged-XXXXXX.json)"
    # Substitute [REPO_ROOT] before merging so dedup compares real paths,
    # not template placeholders vs already-substituted existing commands.
    tmp_src_subst="$(mktemp /tmp/rig-settings-src-XXXXXX.json)"
    abs_target="$(cd "$TARGET" && pwd)"
    escaped_target="${abs_target//\//\\/}"
    sed "s/\\[REPO_ROOT\\]/${escaped_target}/g" "$src" > "$tmp_src_subst"
    if merge_settings_json "$dest" "$tmp_src_subst" "$tmp_merged"; then
      # agent-plan: classification only, never write the merged result.
      if [[ "$AGENT_DRY_RUN" != true ]]; then
        [[ -n "$base" ]] && ensure_upgrade_transaction "$base"
        _upgrade_write "$tmp_merged" "$dest" "$base"
      fi
      success "Merged .claude/settings.json"
      record_upgrade_result merged "$rel"
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
      record_upgrade_result up-to-date "$rel"
    else
      warn "sha256 unavailable — cannot detect customizations in: ${rel}"
      if confirm "Overwrite ${rel} with new version?" "y"; then
        _upgrade_write "$src" "$dest" "$base"
        success "Updated: ${rel}"
        record_upgrade_result updated "$rel"
      else
        info "Skipped: ${rel}"
        record_upgrade_result skipped-customized "$rel"
      fi
    fi
    return
  fi

  # Already at the new version — nothing to do
  if [[ "$dest_hash" == "$new_hash" ]]; then
    info "Up to date: ${rel}"
    record_upgrade_result up-to-date "$rel"
    return
  fi

  manifest_hash="$(read_manifest_hash "$rel" "$manifest_file")"

  if [[ -z "$manifest_hash" ]]; then
    # No manifest entry. Two cases:
    #   Rig-owned:  first upgrade before manifest tracking existed → safe to overwrite,
    #               except newly tracked Codex artifacts whose provenance is unknown.
    #   User-owned: never tracked (e.g. CLAUDE.md, PROJECT_BRIEF.md, memory files).
    #               We can't tell if the user customized it, so skip safely.
    if [[ "$rel" == .agents/skills/* || "$rel" == .codex/hooks.json || "$rel" == .codex/hooks/* ]]; then
      warn "Preserved untracked Codex artifact: ${rel}"
      info "Recorded its current hash; rerun Upgrade after reviewing it."
      record_upgrade_result skipped-customized "$rel"
      write_manifest_entry "$dest_hash" "$rel" "$manifest_file" "$dest"
    elif [[ "$rig_owned_default" == true ]] || is_rig_owned "$rel"; then
      _upgrade_write "$src" "$dest" "$base"
      success "Updated: ${rel}"
      record_upgrade_result updated "$rel"
      write_manifest_entry "$new_hash" "$rel" "$manifest_file" "$dest"
    else
      info "Skipped (user-owned, no prior manifest entry): ${rel}"
      record_upgrade_result skipped-untracked "$rel"
      # Record the current hash so future upgrades can detect customizations.
      write_manifest_entry "$dest_hash" "$rel" "$manifest_file" "$dest"
    fi
  elif [[ "$dest_hash" == "$manifest_hash" ]]; then
    # Matches manifest → unmodified since install. Safe to overwrite.
    _upgrade_write "$src" "$dest" "$base"
    success "Updated: ${rel}"
    record_upgrade_result updated "$rel"
    write_manifest_entry "$new_hash" "$rel" "$manifest_file" "$dest"
  else
    # dest_hash differs from manifest_hash — user has customized this file.
    # Show what changed and ask before overwriting (agent mode: this is
    # narrative-only chatter ahead of the JSON result, so suppress it).
    if [[ -z "$AGENT_MODE" ]]; then
      blank
      warn "Customized file detected: ${rel}"
      echo "  Your version differs from what The Rig originally installed."
      echo "  The new Rig version also modifies this file."
      blank
    fi
    # Agent mode (issue #444 lane 444-C): before falling back to the
    # non-interactive skip below, try the structure-aware/three-way
    # convergence engine. A clean merge is applied (or, in agent-plan's
    # AGENT_DRY_RUN, classified only) and the run is NOT refused for this
    # file. A merge conflict still falls through to the same
    # skipped-customized refusal as before, just with specific
    # keys/lines attached instead of a generic reason.
    if [[ -n "$AGENT_MODE" ]]; then
      # attempt_convergence_merge()'s stdout is a temp file path on success
      # (exit 0) or a JSON conflicts array on failure (exit 1) — see its own
      # comment for why it can't hand this back via a global variable.
      local _converged_output
      if _converged_output="$(attempt_convergence_merge "$src" "$dest" "$rel")"; then
        if [[ "$AGENT_DRY_RUN" != true ]]; then
          _upgrade_write "$_converged_output" "$dest" "$base"
          write_manifest_entry "$(sha256_file "$dest")" "$rel" "$manifest_file" "$dest"
        fi
        rm -f "$_converged_output"
        success "Converged: ${rel}"
        record_upgrade_result converged "$rel"
        return
      fi
      info "Non-interactive mode — merge conflict, skipping: ${rel}"
      info "Run the installer interactively to review and update this file."
      record_upgrade_result skipped-customized "$rel" "$_converged_output"
      return
    fi
    # Non-interactive (CI / piped stdin): skip without prompting.
    if [[ ! -t 0 ]]; then
      info "Non-interactive mode — skipping customized file: ${rel}"
      info "Run the installer interactively to review and update this file."
      record_upgrade_result skipped-customized "$rel"
      return
    fi
    local choice
    while true; do
      read -r -p "$(echo -e "  ${BOLD}?${RESET} (o)verwrite  (s)kip  (d)iff  [o/s/d]: ")" choice
      case "${choice:-}" in
        o|O)
          _upgrade_write "$src" "$dest" "$base"
          success "Updated (overwritten): ${rel}"
          record_upgrade_result updated "$rel"
          write_manifest_entry "$new_hash" "$rel" "$manifest_file" "$dest"
          break
          ;;
        s|S)
          info "Skipped (kept your version): ${rel}"
          record_upgrade_result skipped-customized "$rel"
          break
          ;;
        d|D)
          blank
          echo "  ── diff: your version (a) → new Rig version (b) ──"
          diff -u "$dest" "$src" | head -100 || true
          echo "  ── end diff ──"
          blank
          ;;
        *)
          echo "  Please enter o, s, or d."
          ;;
      esac
    done
  fi
}

_copy_file_upgrade() {
  _copy_upgrade_existing "$1" "$2" "${3:-}" "${4:-}" \
    "$MANIFEST_FILE" smart-merge false
}

# ── GLOBAL UPGRADE HANDLER ───────────────────────────────────────────────────
# Thin global-layer wrapper around the shared existing-file upgrade handler.
# Files passed here default to Rig-owned (global skills/hooks paths like
# "skills/$name" don't match is_rig_owned()'s patterns, so they need this
# forced default to stay auto-updatable) — the caller never passes PROFILE.md
# (personal data that must never be auto-overwritten). CLAUDE.md is the same
# class of exception: it's explicitly user-owned (is_rig_owned() already
# knows this), so its caller passes rig_owned_default=false explicitly rather
# than relying on this function's true-by-default (issue #470/#471 review —
# the global CLAUDE.md previously took the unconditional-overwrite branch on
# a missing manifest entry regardless of is_rig_owned(), the exact bug class
# this hardening pass exists to eliminate, just at the global layer).
_copy_global_file_upgrade() {
  local src="$1"
  local dest="$2"
  local base="${3:-}"
  local rel="${4:-}"
  local manifest_file="${5:-$GLOBAL_MANIFEST_FILE}"
  local rig_owned_default="${6:-true}"
  local destination_state

  destination_state="$(upgrade_destination_state "$base" "$dest")"
  case "$destination_state" in
    symlinked-parent|symlinked-root|parent-wrong-type|outside-root|directory|wrong-type)
      record_upgrade_destination_conflict "$rel" "$destination_state"
      return 0
      ;;
  esac

  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    # agent-plan: classification only, never create the directory or write.
    if [[ "$AGENT_DRY_RUN" != true ]]; then
      mkdir -p "$(dirname "$dest")"
    fi
    ensure_upgrade_transaction "$base"
    record_created "$base" "$dest"
    [[ "$AGENT_DRY_RUN" == true ]] || cp "$src" "$dest"
    success "Created: ${rel}"
    record_upgrade_result updated "$rel"
    write_manifest_entry "$(sha256_file "$dest")" "$rel" "$manifest_file" "$dest"
    return
  fi
  _copy_upgrade_existing "$src" "$dest" "$base" "$rel" \
    "$manifest_file" none "$rig_owned_default"
}

# Retire the hook merged into stop.sh in v1.21.0 only when the manifest proves
# that the installed regular file is an unchanged Rig artifact. Untracked,
# customized, symlinked, dangling, and wrong-type paths are user state until
# an operator explicitly repairs them. Never remove or follow those paths.
retire_legacy_session_end() {
  local rel=".claude/hooks/session-end.sh"
  local legacy="$TARGET/$rel"
  local manifest_hash current_hash

  [[ -e "$legacy" || -L "$legacy" ]] || return 0

  if [[ -L "$TARGET/.claude" || -L "$TARGET/.claude/hooks" ]]; then
    warn "Preserved legacy hook with symlinked parent: $rel"
    record_upgrade_result skipped-conflict "$rel"
    return 0
  fi

  if [[ -L "$legacy" ]]; then
    warn "Preserved legacy hook symlink: $rel"
    info "Remove it explicitly after reviewing its target."
    record_upgrade_result skipped-conflict "$rel"
    return 0
  fi

  if [[ ! -f "$legacy" ]]; then
    warn "Preserved legacy hook with unsupported file type: $rel"
    info "Repair the path explicitly before retrying the upgrade."
    record_upgrade_result skipped-conflict "$rel"
    return 0
  fi

  manifest_hash="$(read_manifest_hash "$rel" "$MANIFEST_FILE")"
  current_hash="$(sha256_file "$legacy")"
  if [[ -z "$manifest_hash" || -z "$current_hash" || "$current_hash" != "$manifest_hash" ]]; then
    warn "Preserved legacy hook requiring review: $rel"
    info "The file is customized or has no trusted manifest baseline; no deletion was performed."
    record_upgrade_result skipped-conflict "$rel"
    return 0
  fi

  ensure_upgrade_transaction "$TARGET"
  backup_file "$legacy" "$TARGET"
  # agent-plan: classification only, never delete the legacy hook.
  if [[ "$AGENT_DRY_RUN" != true ]]; then
    if ! rm -f "$legacy"; then
      error "Could not retire legacy hook: $rel"
      return 1
    fi
  fi
  success "Removed obsolete legacy hook: $rel"
  record_upgrade_result removed "$rel"
}

# Install a single Rig-owned hook script into .git/hooks/ during a stealth
# install/upgrade (issue #444, lane 444-G). .git/hooks/ sits outside git
# tracking and outside the manifest's normal template-copy path, so a plain
# `cp` here could silently destroy a hand-written or third-party hook with
# no manifest record and no backup. This routes the write through the same
# manifest + backup/journal machinery every other Rig-owned artifact uses:
#
#   - Destination missing              → first install, no backup needed.
#   - Destination is a symlink         → never followed/inspected; treated
#                                         as customized (same no-follow rule
#                                         copy_file() uses for other assets).
#   - No manifest entry for this hook  → never verified as Rig-installed;
#                                         treated as customized/foreign.
#   - Manifest entry, hash matches     → unmodified Rig-installed hook.
#   - Manifest entry, hash differs     → user has customized this hook.
#
# Interactive/noninteractive (non-agent) runs keep the existing overwrite
# behavior unchanged — the hook is always installed — but a customized hook
# is now backed up first via backup_file(), and every write updates the
# manifest so future runs can detect drift. Agent-upgrade mode
# (AGENT_MODE=apply) never overwrites a customized hook: it refuses and
# reports the path in conflicts[] via the existing skipped-customized
# classification, matching the refusal contract used elsewhere in #444.
_stealth_install_git_hook() {
  local hook_src="$1" hook_dest="$2" hook_name="$3"
  local rel=".git/hooks/${hook_name}"
  local customized=false

  if [[ -L "$hook_dest" ]]; then
    customized=true
  elif [[ -f "$hook_dest" ]]; then
    local dest_hash manifest_hash
    dest_hash="$(sha256_file "$hook_dest")"
    manifest_hash="$(read_manifest_hash "$rel" "$MANIFEST_FILE")"
    if [[ -z "$manifest_hash" ]]; then
      # No manifest baseline yet -- e.g. this hook was installed by a Rig
      # version before hook manifest tracking existed. Unlike a real hash
      # mismatch, this alone doesn't mean customized: fall back to comparing
      # against the INCOMING hook directly, matching _copy_file_upgrade()'s
      # own no-manifest-entry handling for every other Rig-owned file
      # (issue #495) -- an installed hook that already matches what would be
      # installed is not a customization, just a missing baseline, and
      # should never be permanently misreported as needing manual review.
      local src_hash
      src_hash="$(sha256_file "$hook_src")"
      if [[ "$dest_hash" == "$src_hash" ]]; then
        write_manifest_entry "$dest_hash" "$rel" "$MANIFEST_FILE" "$hook_dest"
        record_upgrade_result up-to-date "$rel"
        return 0
      fi
      customized=true
    elif [[ "$dest_hash" != "$manifest_hash" ]]; then
      customized=true
    fi
  elif [[ -e "$hook_dest" ]]; then
    # Exists but is neither a regular file nor a symlink (e.g. a directory) —
    # treat as customized/unsafe rather than guessing.
    customized=true
  fi

  if [[ "$customized" == true ]]; then
    # agent-plan (AGENT_MODE=plan) must detect and report this conflict via
    # the same skipped-customized classification agent-upgrade (AGENT_MODE=
    # apply) refuses on — otherwise agent-plan could report status:"success"
    # right before agent-upgrade refuses on the identical project (issue
    # #458). Detection above always runs; only the actual overwrite below is
    # gated on AGENT_DRY_RUN, so plan mode reports without ever writing.
    if [[ "$AGENT_MODE" == "apply" || "$AGENT_MODE" == "plan" ]]; then
      warn "Stealth: customized git hook preserved (agent-upgrade refuses to overwrite): $rel"
      record_upgrade_result skipped-customized "$rel"
      return 0
    fi
    warn "Stealth: customized or unrecognized git hook detected: $rel"
    echo "  A backup will be saved to .rig-backup/ (or the external backups/ dir) before installing the Rig hook."
  fi

  # Routes through the same no-follow, refuse-on-symlink choke point every
  # other direct-writer mutation uses (issue #470/#471's review found this
  # hand-rolled -f/-L/-e check had a gap: a symlinked .git/hooks/<name>
  # matched neither branch, so no backup/journal happened here, yet the cp
  # below still ran — cp follows an existing symlink and silently overwrites
  # whatever it points to, in place, with no recovery path, even if that
  # target lives outside the project entirely. A dangling symlink hit the
  # same gap and crashed the installer mid-transaction under set -e.
  #
  # Calls guard_destination_before_write() directly, NOT the
  # upgrade_prepare_mutation() wrapper -- that wrapper only runs under
  # COLLISION_STRATEGY==upgrade, but this function installs hooks under
  # every strategy (merge is the default for every fresh install). Retro-
  # audit finding, found by /rig-surface-review's first real end-to-end
  # run: calling the wrapper here made this whole check a silent no-op
  # under merge/skip/overwrite/interactive, so the #451 symlink-refusal
  # fix never actually applied outside an explicit --strategy upgrade run.
  guard_destination_before_write "$TARGET" "$hook_dest" "$rel" || return 0
  # agent-plan: classification only, never write the hook file.
  [[ "$AGENT_DRY_RUN" == true ]] || cp "$hook_src" "$hook_dest"
  [[ "$AGENT_DRY_RUN" == true ]] || chmod +x "$hook_dest"
  write_manifest_entry "$(sha256_file "$hook_dest")" "$rel" "$MANIFEST_FILE" "$hook_dest"
  success "Stealth: installed $hook_name → .git/hooks/"
  record_upgrade_result updated "$rel"
}

# ── GLOBAL LAYER ─────────────────────────────────────────────────────────────
if [[ "$DO_GLOBAL" == true && "$GLOBAL_AGENT" != none ]]; then
  bold "── Global layer ──"
  blank

  CLAUDE_DIR="$HOME/.claude"
  SKILLS_DIR="$CLAUDE_DIR/skills"
  DEST_CLAUDE="$CLAUDE_DIR/CLAUDE.md"

  if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
    # agent-plan: classification only, never recover an interrupted transaction.
    [[ "$AGENT_DRY_RUN" == true ]] || recover_upgrade_transaction "$CLAUDE_DIR"
    if [[ "$RECOVER_ONLY" == true ]]; then
      # Recovery-only must continue into the project layer when both layers
      # were selected.  A global-only invocation can finish here safely.
      DO_GLOBAL=false
      [[ "$DO_PROJECT" == true ]] || RECOVERY_ONLY_COMPLETE=true
    fi
  fi

  if [[ "$RECOVER_ONLY" != true ]]; then
  # Point manifest helpers at the global manifest for this section.
  _SAVED_MANIFEST_FILE="$MANIFEST_FILE"
  MANIFEST_FILE="$GLOBAL_MANIFEST_FILE"

  # issue #463: must run BEFORE any write below. A legitimate content update
  # to an entry this run would otherwise silently overwrite a tampered/future
  # base_revision with the real running INSTALLER_VERSION via the normal
  # write_manifest_metadata() path, erasing the evidence before a later
  # check could see it — checking here, against the manifest exactly as it
  # exists before this run's own writes, is what agent-plan already gets for
  # free (it never writes at all); this gives agent-upgrade the same view.
  report_future_manifest_revisions "${GLOBAL_MANIFEST_FILE}.json" global

  if has_agent "$GLOBAL_AGENT" claude; then
  if upgrade_prepare_directory "$HOME" "$CLAUDE_DIR" ".claude"; then
    # agent-plan: classification only, never create the global Claude root.
    [[ "$AGENT_DRY_RUN" == true ]] || mkdir -p "$CLAUDE_DIR" "$SKILLS_DIR"
  else
    info "Preserving conflicting global Claude root: .claude"
  fi

  if [[ "$INSTALL_NOTIFICATIONS" == true && "$AGENT_DRY_RUN" != true ]]; then
    # guard_destination_before_write() directly, NOT the upgrade_prepare_mutation()
    # wrapper -- that wrapper only runs under COLLISION_STRATEGY==upgrade, but
    # notifications can be installed under any strategy (--notifications works
    # alongside the default merge strategy too). Same gap and same fix as
    # _stealth_install_git_hook()'s guard_destination_before_write() call
    # (issue #451/#470/#471): under merge/skip/overwrite/interactive,
    # upgrade_prepare_mutation() silently no-ops and returns success without
    # ever checking for a symlinked or conflicting destination (issue #477).
    if guard_destination_before_write "$HOME" "$CLAUDE_DIR/bin/rig-notify" ".claude/bin/rig-notify"; then
      mkdir -p "$CLAUDE_DIR/bin"
      cp "$GLOBAL_TEMPLATES/bin/rig-notify" "$CLAUDE_DIR/bin/rig-notify"
      chmod +x "$CLAUDE_DIR/bin/rig-notify"
    else
      info "Skipped notification helper due to a conflicting destination."
    fi
    if guard_destination_before_write "$HOME" "$CLAUDE_DIR/settings.json" ".claude/settings.json"; then
      _notif_channel=terminal_bell
      [[ -n "${KITTY_WINDOW_ID:-}" ]] && _notif_channel=kitty
      [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]] && _notif_channel=ghostty
      [[ "${TERM_PROGRAM:-}" == iTerm.app ]] && _notif_channel=iterm2
      python3 - "$CLAUDE_DIR/settings.json" "$_notif_channel" <<'PYEOF'
import json, os, sys, tempfile
p, channel = sys.argv[1:]
try:
    data = json.load(open(p)) if os.path.exists(p) else {}
except Exception as e:
    print(f"Invalid Claude settings JSON: {e}", file=sys.stderr); raise SystemExit(1)
data["preferredNotifChannel"] = channel
hooks = data.setdefault("hooks", {})
cmd = 'bash ~/.claude/bin/rig-notify'
for event, arg in (("Notification","notification"),("Stop","stop"),("SubagentStop","subagent-stop"),("PermissionRequest","permission-request")):
    entry={"hooks":[{"type":"command","command":f"{cmd} {arg}"}]}
    if not any(entry == x for x in hooks.setdefault(event, [])): hooks[event].append(entry)
d=os.path.dirname(p); os.makedirs(d, exist_ok=True)
fd,tmp=tempfile.mkstemp(dir=d); os.close(fd)
with open(tmp,"w") as f: json.dump(data,f,indent=2); f.write("\n")
os.replace(tmp,p)
PYEOF
      command -v jq >/dev/null 2>&1 && jq -e . "$CLAUDE_DIR/settings.json" >/dev/null || { error "Notification settings validation failed."; exit 1; }
    else
      info "Skipped notification settings due to a conflicting destination."
    fi
  fi

  # ── CLAUDE.md ──────────────────────────────────────────────────────────────
  if [[ "$COLLISION_STRATEGY" == "upgrade" ]]; then
    # rig_owned_default=false: CLAUDE.md is user-owned (see is_rig_owned()'s
    # own classification comment), unlike the skills files below — a missing
    # manifest entry must default to skip-and-warn, not silent overwrite.
    _copy_global_file_upgrade "$GLOBAL_TEMPLATES/CLAUDE.md" "$DEST_CLAUDE" "$CLAUDE_DIR" "CLAUDE.md" "$GLOBAL_MANIFEST_FILE" false
  else
    copy_file "$GLOBAL_TEMPLATES/CLAUDE.md" "$DEST_CLAUDE" "$CLAUDE_DIR" "CLAUDE.md"
  fi

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
  fi

  if has_agent "$GLOBAL_AGENT" codex; then
    _CODEX_GLOBAL_STAGE="$(mktemp -d /tmp/rig-codex-global-skills-XXXXXX)"
    if ! python3 "$SCRIPT_DIR/installer/generate-codex-skills.py" \
      --output "$_CODEX_GLOBAL_STAGE" --base-branch main \
      --global-skills-source "$GLOBAL_TEMPLATES/skills"; then
      rm -rf "$_CODEX_GLOBAL_STAGE"
      error "Could not generate global Codex skills."
      exit 1
    fi
    while IFS= read -r -d '' _global_skill_src; do
      _global_skill_rel="${_global_skill_src#"$_CODEX_GLOBAL_STAGE"/}"
      _global_codex_rel=".agents/skills/$_global_skill_rel"
      if [[ "$COLLISION_STRATEGY" == "upgrade" ]]; then
        _copy_global_file_upgrade "$_global_skill_src" \
          "$HOME/$_global_codex_rel" "$HOME" "$_global_codex_rel" \
          "$CODEX_GLOBAL_MANIFEST_FILE"
      else
        copy_codex_owned_initial "$_global_skill_src" \
          "$HOME/$_global_codex_rel" "$HOME" "$_global_codex_rel" \
          "$CODEX_GLOBAL_MANIFEST_FILE"
      fi
    done < <(find "$_CODEX_GLOBAL_STAGE" -type f -print0)
    rm -rf "$_CODEX_GLOBAL_STAGE"
  fi

  # Restore manifest pointer
  MANIFEST_FILE="$_SAVED_MANIFEST_FILE"

  finish_upgrade_transaction

  blank
  fi
fi

if [[ "$RECOVERY_ONLY_COMPLETE" == true ]]; then
  echo "Recovery complete."
  exit 0
fi

if [[ "$DO_GLOBAL" == true ]]; then
  _global_smoke="$(run_capability_smoke global "$GLOBAL_AGENT" "$HOME/.claude")" || { error "Postflight smoke failed: $_global_smoke"; exit 1; }
  if [[ "$_GLOBAL_STATE_FUTURE" != true ]] && \
     guard_destination_before_write "$HOME" "$GLOBAL_TARGET_STATE" ".rig/install-targets.json"; then
    write_agent_state "$GLOBAL_TARGET_STATE" global "$GLOBAL_AGENT"
  fi
  success "Postflight targets: global=$GLOBAL_AGENT; smoke=$_global_smoke"
fi
if [[ "$COLLISION_STRATEGY" == upgrade && "$DO_GLOBAL" == true ]]; then
  # Global manifest entries are recorded relative to $CLAUDE_DIR ($HOME/.claude
  # — see the copy_file call installing CLAUDE.md with base="$CLAUDE_DIR",
  # rel="CLAUDE.md"), not $HOME directly. Passing $HOME here resolved every
  # entry one directory too shallow, so every global artifact was reported as
  # a false-positive "missing" stale entry. This went unnoticed before lane
  # 444-E started counting unrepaired stale entries toward
  # UPGRADE_REVIEW_REQUIRED; now it must resolve correctly.
  report_stale_manifest_entries "${GLOBAL_MANIFEST_FILE}.json" "$CLAUDE_DIR" global
  # report_future_manifest_revisions() for this layer already ran earlier,
  # before any global-layer write — see the call right after MANIFEST_FILE
  # is pointed at GLOBAL_MANIFEST_FILE, above. Running it here too would
  # double-count, and would miss entries a legitimate write this run already
  # silently corrected (issue #463).
fi

# Finalize any transaction still open before resetting BACKUP_DIR between
# layers -- retro-audit finding, root cause of the "interrupted upgrade
# transaction exists" regression the unconditional end-of-script
# finish_upgrade_transaction() call (below, near "── Done ──") didn't
# actually fix: this reset blindly clears BACKUP_DIR without finalizing
# first. UPGRADE_TRANSACTION_ACTIVE stays true, but with BACKUP_DIR now
# empty, finish_upgrade_transaction()'s own guard
# ([[ "$UPGRADE_TRANSACTION_ACTIVE" == true && -n "$BACKUP_DIR" ]]) can
# never be satisfied again -- the original .rig-backup/.in-progress from
# before this reset is silently orphaned no matter how many finalize calls
# run afterward, since none of them can rediscover its path. Confirmed live
# on a real, previously-installed machine: a stale .in-progress from an
# earlier global-layer run (predating this fix) sat unfinalized for days,
# invisibly, until the next such run hit it and refused with "recovery is
# required."
[[ "$UPGRADE_TRANSACTION_ACTIVE" == true ]] && finish_upgrade_transaction
BACKUP_DIR=""

# ── PROJECT LAYER ─────────────────────────────────────────────────────────────
if [[ "$DO_PROJECT" == true ]]; then
  bold "── Project layer ──"
  blank

  # Determine target directory
  if [[ -n "$_FLAG_TARGET" ]]; then
    TARGET="$_FLAG_TARGET"
  else
    DEFAULT_TARGET="$(pwd)"
    # Independent-review finding on issue #476: this prompt had no `-t 0`
    # guard at all (unlike every sibling prompt below it), so it read
    # unconditionally whenever --target was omitted -- reachable by an
    # agent-plan/agent-upgrade invocation with a real TTY attached and no
    # --target flag, hanging exactly like the drift check and base-branch
    # prompt did before their fixes.
    #
    # Regression found by tests/test_install.bats after the first attempt
    # at this fix added a `-t 0` check here (matching the sibling prompts'
    # pattern): unlike those siblings, this call site's original absence of
    # a `-t 0` guard was load-bearing -- several existing tests drive the
    # interactive installer non-interactively via a piped heredoc (e.g.
    # "stealth mode: warns when .husky/ exists in target project"), which
    # is not a TTY, relying on this prompt reading its answer from stdin
    # regardless. Adding `-t 0` silently skipped that read and defaulted to
    # $(pwd) instead, desynchronizing every subsequent piped answer (the
    # tracking-menu choice consumed the target path meant for this prompt).
    # `-z "$AGENT_MODE"` alone is both necessary and sufficient: it closes
    # the actual hang (agent-plan/agent-upgrade always skip this prompt,
    # regardless of stdin), and a plain `read` on non-agent, non-tty stdin
    # (closed, /dev/null, or a heredoc) never blocks -- it returns
    # immediately, empty on EOF or populated from the pipe, exactly
    # matching this call site's original safe behavior.
    if [[ -z "$AGENT_MODE" ]]; then
      ask "Target project directory?"
      read -r -p "    Path [${DEFAULT_TARGET}]: " TARGET_INPUT || true
      TARGET="${TARGET_INPUT:-$DEFAULT_TARGET}"
    else
      TARGET="$DEFAULT_TARGET"
    fi
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
    # Independent-review finding on issue #476: same class as the
    # base-branch prompt fix above -- this `-t 0` check had no AGENT_MODE
    # guard, so it blocked under a real TTY whenever --project-name was
    # omitted, regardless of --strategy.
    if [[ -t 0 && -z "$AGENT_MODE" ]]; then
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

  blank

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
    # Also never for agent-plan/agent-upgrade (found live while testing
    # issue #476's fix): a real TTY attached to an agent invocation reached
    # this exact same "-t 0" pattern and blocked on this read too, just
    # like the branch-drift check did before that fix -- AGENT_MODE is
    # already reliably assigned by this point in execution (the --strategy
    # case statement runs during flag parsing, well before this point), so
    # this fix is a straightforward extra guard rather than needing its own
    # early lookahead.
    if [[ -t 0 && -z "$AGENT_MODE" ]]; then
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
  blank

  # ── GIT TRACKING FOR .rig/ ────────────────────────────────────────────────
  # How should .rig/ appear (or not appear) in git?
  # --tracking flag takes precedence; --rig-dir alone implies external (backward-compat).
  # When neither is set, show the interactive prompt — including when --target is provided.
  RIG_TRACKING="stealth"   # default: zero Rig traces in git
  RIGPATH_FILE=""       # absolute path to .rigpath (set if external or stealth mode)

  # ── Upgrade: auto-detect existing tracking mode ───────────────────────────
  # When upgrading without --tracking and no .rigpath, infer the prior mode
  # from git state instead of defaulting to stealth via the interactive prompt.
  # Prevents silently migrating repo/local installs to stealth on upgrade.
  if [[ "$COLLISION_STRATEGY" == "upgrade" && -z "$_FLAG_TRACKING" \
        && -z "$EXTERNAL_RIG_DIR" && ! -f "$TARGET/.rigpath" \
        && -d "$TARGET/.rig" ]]; then
    if [[ -n "$(git -C "$TARGET" ls-files -- ".rig/" 2>/dev/null)" ]]; then
      _FLAG_TRACKING="repo"
      info "Auto-detected existing tracking mode: repo (.rig/ is git-committed)"
    elif grep -qF '.rig/' "$TARGET/.git/info/exclude" 2>/dev/null \
         || grep -qF '.rig/' "$TARGET/.gitignore" 2>/dev/null; then
      _FLAG_TRACKING="local"
      info "Auto-detected existing tracking mode: local (.rig/ is git-excluded)"
    fi
  fi

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
  elif [[ -n "$AGENT_MODE" ]]; then
    # Independent-review finding on issue #476: this whole interactive
    # tracking-mode menu had no `-t 0` guard at all -- it read
    # unconditionally whenever none of --tracking/--rig-dir/.rigpath were
    # present, reachable by an agent-plan/agent-upgrade invocation with a
    # real TTY attached. Fall back to the menu's own documented default
    # (stealth) instead of prompting, matching option 4 below exactly.
    RIG_TRACKING="stealth"
    EXTERNAL_RIG_DIR="${HOME}/.rig/projects/${PROJECT_NAME}"
  else
    echo "How should .rig/ be tracked in git?"
    blank
    echo "  1) In the repo      — committed with the project (not recommended for shared repos)"
    echo "  2) Local only       — added to .git/info/exclude; invisible to teammates, no .gitignore change"
    echo "  3) External         — install .rig/ to a path outside this repo entirely"
    echo "  4) Stealth          — zero Rig traces in git: all Rig files excluded or external; (default)"
    echo "                        git hooks go to .git/hooks/ (no Husky required)"
    echo "                        Use for multi-contributor repos where teammates must not see Rig files."
    blank
    read -r -p "$(echo -e "${BOLD}?${RESET} Choose [1/2/3/4] (default: 4): ")" rig_tracking_input || true
    rig_tracking_input="${rig_tracking_input:-4}"

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
         blank
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
    if [[ "$AGENT_DRY_RUN" == true ]]; then
      # agent-plan: classification only, never create the external .rig/ dir.
      # An existing install (the realistic agent-plan target) already has this
      # directory; canonicalize it read-only. A missing directory here means
      # the install is in an unusual state outside 444-A's scope — leave the
      # path unresolved rather than mutate the filesystem to find out.
      [[ -d "$EXTERNAL_RIG_DIR" ]] && EXTERNAL_RIG_DIR="$(cd "$EXTERNAL_RIG_DIR" && pwd)"
    else
      mkdir -p "$EXTERNAL_RIG_DIR" || { error "Cannot create directory: $EXTERNAL_RIG_DIR"; exit 1; }
      EXTERNAL_RIG_DIR="$(cd "$EXTERNAL_RIG_DIR" && pwd)"
    fi
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
  PROJECT_TARGET_STATE="$(dirname "$(dirname "$MANIFEST_FILE")")/install-targets.json"
  # issue #463: must run BEFORE any write below, against the manifest exactly
  # as it exists at the start of this run — see the matching global-layer
  # call and comment above for the full explanation of why this cannot run
  # in postflight instead.
  report_future_manifest_revisions "${MANIFEST_FILE}.json" project
  if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
    # agent-plan: classification only, never recover an interrupted transaction.
    if [[ "$AGENT_DRY_RUN" != true ]]; then
      recover_upgrade_transaction "$TARGET"
      if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
        recover_upgrade_transaction "$EXTERNAL_RIG_DIR"
      fi
    fi
    if [[ "$RECOVER_ONLY" == true ]]; then exit 0; fi
    # Take the whole-tree "known good before" snapshot only after any
    # interrupted prior transaction has been recovered, so it reflects
    # consistent state — never a mid-rollback one.
    preflight_snapshot_project "$TARGET"
  fi
  _PROJECT_STATE_FUTURE=false
  PREVIOUS_PROJECT_AGENT=""
  if [[ "$COLLISION_STRATEGY" == upgrade && -f "$PROJECT_TARGET_STATE" ]]; then
    _saved_project="$(read_agent_state "$PROJECT_TARGET_STATE")" || _project_state_status=$?
    PREVIOUS_PROJECT_AGENT="${_saved_project:-}"
    _PREVIOUS_PROJECT_ROOT=""
    if [[ "${_project_state_status:-0}" -ne 2 && "${_project_state_status:-0}" -ne 3 ]]; then
      _PREVIOUS_PROJECT_ROOT="$(read_project_root "$PROJECT_TARGET_STATE")"
    fi
    if [[ "${_project_state_status:-0}" -eq 3 ]]; then
      _PROJECT_STATE_FUTURE=true
      [[ -n "$_FLAG_PROJECT_AGENT" ]] || { error "Future project target metadata requires --project-agent"; exit 2; }
    elif [[ "${_project_state_status:-0}" -eq 2 ]]; then error "Malformed project target metadata: $PROJECT_TARGET_STATE"; exit 1
    elif [[ -z "$_FLAG_PROJECT_AGENT" && "$_INTERACTIVE_AGENT_CHOICE" != true ]]; then PROJECT_AGENT="$_saved_project"
    fi
  fi

  # ── BREAKING CHANGE GATE (upgrade only) ───────────────────────────────────
  # Read the project's installed Rig version and surface any breaking changes
  # between it and the incoming installer version before touching any files.
  # Tests can override _RIG_TEST_CHANGELOG to point to a controlled fixture.
  if [[ "$COLLISION_STRATEGY" == "upgrade" ]]; then
    if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
      _installed_version=$(cat "$EXTERNAL_RIG_DIR/VERSION" 2>/dev/null || echo "unknown")
    else
      _installed_version=$(cat "$TARGET/.rig/VERSION" 2>/dev/null || echo "unknown")
    fi
    _changelog_path="${_RIG_TEST_CHANGELOG:-$SCRIPT_DIR/CHANGELOG.md}"
    _show_breaking_changes "$_installed_version" "$_changelog_path"
  fi

  blank

  # ── COMPONENT SELECTION ───────────────────────────────────────────────────
  # Skipped for intents 1–4 and when --target flag is provided.
  # Only shown for Custom (intent 5) when the user hasn't bypassed interactivity.
  if [[ "$_SKIP_COMPONENT_SELECTION" == true || -n "$_FLAG_TARGET" ]]; then
    component_choice="a"
  else
    echo "Which components do you want to install?"
    blank
    echo "  a) All (recommended)"
    echo "  b) Let me choose"
    blank
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

  if ! has_agent "$PROJECT_AGENT" claude; then
    INSTALL_CLAUDE_HOOKS=false
    INSTALL_COMMANDS=false
    INSTALL_SUBAGENTS=false
  fi

  if [[ "$component_choice" == "b" ]]; then
    # Show context-aware paths for .rig/ components
    RIG_LABEL=".rig/"
    if [[ "$RIG_TRACKING" == "external" ]]; then
      RIG_LABEL="${EXTERNAL_RIG_DIR}/"
    fi
    blank
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
    blank
  fi

  blank
  info "Scaffolding into: $TARGET"
  info "Project name:     $PROJECT_NAME"
  if [[ "$RIG_TRACKING" == "external" ]]; then
    info ".rig/ location:   $EXTERNAL_RIG_DIR (external)"
  elif [[ "$RIG_TRACKING" == "exclude" ]]; then
    info ".rig/ tracking:   local only (.git/info/exclude)"
  elif [[ "$RIG_TRACKING" == "stealth" ]]; then
    info ".rig/ location:   $EXTERNAL_RIG_DIR (stealth — all Rig files excluded from git)"
  fi
  blank

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
      .rig/rules/protected-paths.txt)      [[ "$INSTALL_CLAUDE_HOOKS" == true ]] || has_agent "$PROJECT_AGENT" codex ;;
      .rig/rules/*)                        [[ "$INSTALL_RULES" == true ]]          ;;
      .claude/hooks/subagent-start.sh)     [[ "$INSTALL_SUBAGENTS" == true ]] || has_agent "$PROJECT_AGENT" codex ;;
      .claude/hooks/*)                     [[ "$INSTALL_CLAUDE_HOOKS" == true ]] || has_agent "$PROJECT_AGENT" codex ;;
      .claude/settings*)                   [[ "$INSTALL_CLAUDE_HOOKS" == true ]]   ;;
      .codex/*)                            has_agent "$PROJECT_AGENT" codex        ;;
      .claude/commands/doc-feature.md|\
      .claude/commands/doc-list.md|\
      .claude/commands/feature-context.md|\
      .claude/commands/refresh-feature-doc.md|\
      docs/features/*)                     [[ "$INSTALL_FEATURE_DOCS" == true ]]   ;;
      .claude/commands/rig-gaps.md|\
      .claude/commands/rig-propose.md)     [[ "$INSTALL_CONTRIBUTE" == true ]]     ;;
      .claude/commands/*|\
      .claude/agents/*)                    [[ "$INSTALL_COMMANDS" == true ]]       ;;
      .husky/*|.gitleaks.toml)             [[ "$INSTALL_GIT_HOOKS" == true ]]      ;;
      .github/*)                           [[ "$INSTALL_GITHUB" == true ]]         ;;
      *)                                   return 0 ;;  # install unknown files by default
    esac
  }

  # Codex skills use the same component choices as Claude commands, but do not
  # require the Claude command destination itself to be enabled.
  should_install_codex_command() {
    local rel="$1"
    case "$rel" in
      .claude/commands/doc-feature.md|\
      .claude/commands/doc-list.md|\
      .claude/commands/feature-context.md|\
      .claude/commands/refresh-feature-doc.md)
        [[ "$INSTALL_FEATURE_DOCS" == true ]] ;;
      .claude/commands/rig-gaps.md|\
      .claude/commands/rig-propose.md)
        [[ "$INSTALL_CONTRIBUTE" == true ]] ;;
      .claude/commands/*)
        return 0 ;;
      *)
        return 1 ;;
    esac
  }

  # ── UPGRADE AUTO-DETECT: enable feature-docs if already installed ─────────
  # If any feature-doc command exists in the target, preserve them on upgrade.
  if [[ "$INSTALL_FEATURE_DOCS" != true ]]; then
    for _fd_check in \
      "$TARGET/.claude/commands/doc-feature.md" \
      "$TARGET/.claude/commands/doc-list.md" \
      "$TARGET/.claude/commands/feature-context.md" \
      "$TARGET/.claude/commands/refresh-feature-doc.md"; do
      if [[ -f "$_fd_check" ]]; then
        INSTALL_FEATURE_DOCS=true
        break
      fi
    done
  fi

  # ── UPGRADE AUTO-DETECT: enable subagents if already installed ─────────────
  if [[ "$INSTALL_SUBAGENTS" != true && -f "$TARGET/.claude/hooks/subagent-start.sh" ]]; then
    INSTALL_SUBAGENTS=true
  fi

  # ── UPGRADE AUTO-DETECT: enable contribute if already installed ─────────────
  if [[ "$INSTALL_CONTRIBUTE" != true ]]; then
    for _cc_check in \
      "$TARGET/.claude/commands/rig-gaps.md" \
      "$TARGET/.claude/commands/rig-propose.md"; do
      if [[ -f "$_cc_check" ]]; then
        INSTALL_CONTRIBUTE=true
        break
      fi
    done
  fi

  # A non-interactive upgrade cannot ask which opt-in components to retain.
  # Warn when project instructions still reference a component that the unset
  # flag would skip, so the operator can rerun with the matching explicit flag.
  if [[ "$COLLISION_STRATEGY" == upgrade && -f "$TARGET/CLAUDE.md" ]]; then
    if [[ "$INSTALL_FEATURE_DOCS" != true ]] && \
       grep -Eq 'doc-feature|doc-list|feature-context|refresh-feature-doc|docs/features' "$TARGET/CLAUDE.md"; then
      warn "CLAUDE.md references feature-docs files that Upgrade will skip; rerun with --feature-docs."
    fi
    if [[ "$INSTALL_CONTRIBUTE" != true ]] && \
       grep -Eq 'rig-gaps|rig-propose' "$TARGET/CLAUDE.md"; then
      warn "CLAUDE.md references contribute files that Upgrade will skip; rerun with --contribute."
    fi
    if [[ "$INSTALL_SUBAGENTS" != true ]] && \
       grep -Fq 'subagent-start.sh' "$TARGET/CLAUDE.md"; then
      warn "CLAUDE.md references subagent files that Upgrade will skip; rerun with --subagents."
    fi
  fi

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
    elif [[ "$rel" == .codex/* && "$COLLISION_STRATEGY" != upgrade ]]; then
      copy_codex_owned_initial "$src_file" "$TARGET/$rel" "$TARGET" "$rel"
    else
      dest_file="$TARGET/$rel"
      copy_file "$src_file" "$dest_file" "$TARGET" "$rel"
    fi
  done < <(find "$PROJECT_TEMPLATES" -type f -print0)

  # Codex discovers repository skills under .agents/skills/. Generate one
  # skill per selected Rig command from the canonical Claude command body so
  # the two agent targets do not acquire independently maintained workflows.
  # Generation happens in a staging directory. Generated skills use the same
  # manifest-aware ownership and customization protection as template files.
  if has_agent "$PROJECT_AGENT" codex; then
    _CODEX_SKILL_STAGE="$(mktemp -d /tmp/rig-codex-skills-XXXXXX)"
    _CODEX_COMMAND_SOURCES=()
    while IFS= read -r -d '' _command_src; do
      _command_rel="${_command_src#$PROJECT_TEMPLATES/}"
      if should_install_codex_command "$_command_rel"; then
        _CODEX_COMMAND_SOURCES+=("$_command_src")
      fi
    done < <(find "$PROJECT_TEMPLATES/.claude/commands" -maxdepth 1 -type f -name '*.md' -print0)

    if ! python3 "$SCRIPT_DIR/installer/generate-codex-skills.py" \
      --output "$_CODEX_SKILL_STAGE" --base-branch "$BASE_BRANCH" \
      --skills-source "$PROJECT_TEMPLATES/.claude/skills" \
      "${_CODEX_COMMAND_SOURCES[@]}"; then
      rm -rf "$_CODEX_SKILL_STAGE"
      error "Could not generate Codex command skills."
      exit 1
    fi

    while IFS= read -r -d '' _skill_src; do
      _skill_rel=".agents/skills/${_skill_src#"$_CODEX_SKILL_STAGE"/}"
      if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
        copy_file "$_skill_src" "$TARGET/$_skill_rel" "$TARGET" "$_skill_rel"
      else
        copy_codex_owned_initial "$_skill_src" \
          "$TARGET/$_skill_rel" "$TARGET" "$_skill_rel"
      fi
    done < <(find "$_CODEX_SKILL_STAGE" -type f -print0)
    rm -rf "$_CODEX_SKILL_STAGE"
  fi

  # Codex supports CLAUDE.md as a project-instruction fallback. Merge the
  # supported setting without replacing existing user fallback names or other
  # project configuration. Existing AGENTS.md files remain untouched and take
  # precedence according to Codex's instruction discovery order.
  if has_agent "$PROJECT_AGENT" codex; then
    _CODEX_CONFIG="$TARGET/.codex/config.toml"
    # guard_destination_before_write() directly, NOT upgrade_prepare_mutation()
    # -- same gap and fix as the notification-helper call sites above and the
    # .git/hooks/* fix (issue #451/#470/#471): the wrapper silently no-ops
    # under every strategy except "upgrade", so a merge-strategy install with
    # --project-agent codex never actually refused a symlinked/conflicting
    # .codex/config.toml (issue #477).
    if guard_destination_before_write "$TARGET" "$_CODEX_CONFIG" ".codex/config.toml"; then
      # agent-plan: classification only, never invoke the merge script --
      # it performs a real write via merge-codex-config.py's atomic_write()
      # (including creating .codex/config.toml and its parent directory if
      # absent). Retro-audit finding, PR #446: this call had no
      # AGENT_DRY_RUN gate at all, unlike every other direct-writer
      # mutation in this file -- agent-plan (documented and relied upon
      # elsewhere as "zero writes, read-only") actually mutated
      # .codex/config.toml whenever --project-agent codex/both was passed.
      if [[ "$AGENT_DRY_RUN" != true ]]; then
        if ! _codex_merge_result="$(python3 "$SCRIPT_DIR/installer/merge-codex-config.py" "$_CODEX_CONFIG")"; then
          error "Codex project config was not changed. Fix $_CODEX_CONFIG and retry."
          exit 1
        fi
        success "Codex project instructions: CLAUDE.md fallback ${_codex_merge_result}"
      fi
    else
      info "Skipped Codex project config due to a conflicting destination."
    fi
  fi

  # ── REMOVE SCRIPTS MERGED INTO OTHER HOOKS (upgrade cleanup) ─────────────
  # session-end.sh was merged into stop.sh in v1.21.0. Retire it only when its
  # manifest proves it is unchanged Rig state; uncertain paths remain intact.
  if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
    retire_legacy_session_end || exit 1
  fi

  # ── WRITE INSTALLER VERSION INTO .rig/VERSION ─────────────────────────────
  # No static template file — write the running installer's version directly
  # so the installed project always reports the correct Rig version without
  # requiring a separate template file bump on every release.
  _RIG_VER_DEST=""
  if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
    _RIG_VER_DEST="$EXTERNAL_RIG_DIR/VERSION"
  else
    _RIG_VER_DEST="$TARGET/.rig/VERSION"
  fi
  if [[ -n "$_RIG_VER_DEST" ]]; then
    if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
      _rig_version_base="$EXTERNAL_RIG_DIR"
    else
      _rig_version_base="$TARGET"
    fi
    if guard_destination_before_write "$_rig_version_base" "$_RIG_VER_DEST" ".rig/VERSION"; then
      # agent-plan: classification only, never write .rig/VERSION.
      if [[ "$AGENT_DRY_RUN" != true ]]; then
        mkdir -p "$(dirname "$_RIG_VER_DEST")" 2>/dev/null || true
        echo "$INSTALLER_VERSION" > "$_RIG_VER_DEST"
        write_manifest_entry "$(sha256_file "$_RIG_VER_DEST")" ".rig/VERSION" "$MANIFEST_FILE" "$_RIG_VER_DEST"
      fi
    else
      info "Skipped .rig/VERSION due to a conflicting destination."
    fi
  fi

  # ── SUBSTITUTE PLACEHOLDERS ───────────────────────────────────────────────
  TARGET_ABS="$(cd "$TARGET" && pwd)"

  # A moved project keeps its installed target metadata, but generated
  # absolute paths in settings still point at the old root. Rewrite the JSON
  # atomically before the normal placeholder substitution so hooks remain
  # bound to the current project without touching unrelated files.
  # Audited under issue #482's upgrade_prepare_mutation() call-site sweep and
  # deliberately left on the upgrade-only wrapper, unlike the other call
  # sites this sweep migrated to guard_destination_before_write(): the
  # enclosing `COLLISION_STRATEGY == upgrade` check right below already
  # restricts this whole block to upgrade-only, so the wrapper's own gate
  # is correct here, not a silent no-op under merge/skip/overwrite --
  # moved-project detection (_PREVIOUS_PROJECT_ROOT) is inherently an
  # upgrade-only concept in the first place.
  if [[ "$COLLISION_STRATEGY" == upgrade && -n "${_PREVIOUS_PROJECT_ROOT:-}" &&
        "$_PREVIOUS_PROJECT_ROOT" != "$TARGET_ABS" ]]; then
    if upgrade_prepare_mutation "$TARGET" "$TARGET/.claude/settings.json" ".claude/settings.json"; then
      rewrite_project_root_references "$TARGET/.claude/settings.json" \
        "$_PREVIOUS_PROJECT_ROOT" "$TARGET_ABS" || {
        error "Could not update moved-project paths in .claude/settings.json."
        exit 1
      }
      success "Updated moved-project paths in .claude/settings.json"
      record_upgrade_result migrated ".claude/settings.json"
    fi
  fi

  TARGET_CLAUDE="$TARGET/CLAUDE.md"
  if [[ -f "$TARGET_CLAUDE" ]] && \
     guard_destination_before_write "$TARGET" "$TARGET_CLAUDE" "CLAUDE.md"; then
    # agent-plan: classification only, never substitute placeholders.
    if [[ "$AGENT_DRY_RUN" != true ]]; then
      sed_inplace "s/\\[Project Name\\]/${PROJECT_NAME}/g" "$TARGET_CLAUDE"
      success "Substituted [Project Name] in CLAUDE.md"
    fi
  fi

  # ── INJECT SubagentStart hook when --subagents is active ─────────────────
  # The settings.json template omits SubagentStart by default (it's opt-in).
  # When INSTALL_SUBAGENTS=true (via --subagents or auto-detect), inject the
  # SubagentStart entry with [REPO_ROOT] placeholder; it is substituted below.
  #
  # Reverted from guard_destination_before_write() back to
  # upgrade_prepare_mutation() (issue #482 follow-up): this step and the
  # [REPO_ROOT] substitution step right below it both run immediately after
  # the SAME settings.json was just created or smart-merged earlier in this
  # SAME run (see the "settings.json: always smart-merge" branch in
  # copy_file(), whose own _upgrade_write() call already correctly backs up
  # a genuinely pre-existing settings.json before overwriting it).
  # guard_destination_before_write()'s regular-file classification cannot
  # distinguish "this file existed before this run started" from "this file
  # was written moments ago by an earlier step in this same run" -- so
  # migrating this call site took a second, spurious backup of the
  # just-created/just-merged file, silently clobbering the smart-merge's
  # own correct backup with this run's own intermediate content. Broke a
  # previously-passing regression test (issue #470) on a fresh CI run.
  # Filed as a follow-up (#493) to fix properly with same-run-creation
  # tracking; reverted here to unblock, matching the precedent already set
  # for the moved-project settings.json rewrite a few hundred lines up.
  if [[ "$INSTALL_SUBAGENTS" == true && "$AGENT_DRY_RUN" != true && -f "$TARGET/.claude/settings.json" ]] && \
     upgrade_prepare_mutation "$TARGET" "$TARGET/.claude/settings.json" ".claude/settings.json"; then
    if command -v python3 >/dev/null 2>&1; then
      python3 - "$TARGET/.claude/settings.json" <<'PYEOF' 2>/dev/null || true
import json, sys
path = sys.argv[1]
with open(path) as f:
    s = json.load(f)
hooks = s.setdefault('hooks', {})
if 'SubagentStart' not in hooks:
    hooks['SubagentStart'] = [{'hooks': [{'type': 'command',
        'command': 'bash [REPO_ROOT]/.claude/hooks/subagent-start.sh'}]}]
    with open(path, 'w') as f:
        json.dump(s, f, indent=2)
        f.write('\n')
PYEOF
      success "Wired SubagentStart hook in .claude/settings.json"
    fi
  fi

  # Substitute [REPO_ROOT] in settings.json with the absolute project path.
  # This step runs after copy/merge to ensure the final file has the real
  # path. Reverted from guard_destination_before_write() back to
  # upgrade_prepare_mutation() -- see the SubagentStart injection comment
  # immediately above for why (issue #482 follow-up, #493).
  TARGET_SETTINGS="$TARGET/.claude/settings.json"
  if [[ -f "$TARGET_SETTINGS" ]] && \
     upgrade_prepare_mutation "$TARGET" "$TARGET_SETTINGS" ".claude/settings.json"; then
    # agent-plan: classification only, never substitute placeholders.
    if [[ "$AGENT_DRY_RUN" != true ]]; then
      ESCAPED_PATH="${TARGET_ABS//\//\\/}"
      sed_inplace "s/\\[REPO_ROOT\\]/${ESCAPED_PATH}/g" "$TARGET_SETTINGS"
      success "Substituted [REPO_ROOT] in .claude/settings.json → $TARGET_ABS"
    fi
  fi

  # Substitute [BASE_BRANCH] in CLAUDE.md, commands, and process files.
  # Covers both inline (.claude/commands/) and external (.rig/processes/) paths.
  _BASE_ESC="${BASE_BRANCH//\//\\/}"
  _subst_base_branch() {
    local f="$1" base="$TARGET" rel target_rig_dir="${_TARGET_RIG_DIR:-}"
    [[ -f "$f" ]] || return 0
    rel="${f#"$TARGET"/}"
    if [[ -n "$target_rig_dir" && "$f" == "$target_rig_dir/"* ]]; then
      base="$target_rig_dir"
      rel=".rig/${f#"$target_rig_dir"/}"
    fi
    guard_destination_before_write "$base" "$f" "$rel" || return 0
    # agent-plan: classification only, never substitute placeholders.
    [[ "$AGENT_DRY_RUN" == true ]] && return 0
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

  # agent-plan: most of the tracking-mode bookkeeping below (.rigpath, git
  # excludes, stale in-repo .rig/ cleanup) never calls record_upgrade_result
  # and isn't part of the UPGRADE_*_COUNT bookkeeping the schema mirrors.
  # Skip it outright under AGENT_DRY_RUN rather than guarding each of its
  # ~15 individual writes, since it produces nothing agent-plan needs to
  # report and must not run in a read-only preflight.
  #
  # Stealth .git/hooks/ install (lane 444-G) is the one exception, and it is
  # deliberately NOT nested inside this guard (see the standalone stealth
  # hook-install block right after this block closes, issue #458). It DOES
  # call record_upgrade_result (updated/skipped-customized), so agent-plan
  # needs it to run its customization detection even under AGENT_DRY_RUN —
  # otherwise agent-plan could report status:"success" right before
  # agent-upgrade refuses (exit 3) on the exact same customized hook.
  # _stealth_install_git_hook() itself gates every actual filesystem mutation
  # behind AGENT_DRY_RUN, so running it here under agent-plan still writes
  # nothing; it only classifies and records.
  # .rigpath's conflict-detection must run unconditionally, same as
  # .rig/VERSION above and the git-hook fix below it -- only the actual
  # write stays gated on AGENT_DRY_RUN. Retro-audit finding, PR #460: this
  # upgrade_prepare_mutation() call used to live entirely inside the
  # AGENT_DRY_RUN guard, so agent-plan never evaluated .rigpath's
  # destination state at all -- a real conflict there (e.g. a symlinked
  # .rigpath) would surface for the first time as an agent-upgrade refusal
  # the plan never warned about, the exact failure mode issue #458 was
  # filed to eliminate for the git-hook install loop.
  _RIGPATH_MUTATION_OK=false
  if [[ ( "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ) && -n "$RIGPATH_FILE" ]] \
     && guard_destination_before_write "$TARGET" "$RIGPATH_FILE" ".rigpath"; then
    _RIGPATH_MUTATION_OK=true
  fi

  if [[ "$AGENT_DRY_RUN" != true ]]; then

  # ── EXTERNAL .rig/ — write .rigpath and update git excludes ──────────────
  if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
    # Write the pointer file so hooks can resolve RIG_DIR at runtime
    if [[ "$_RIGPATH_MUTATION_OK" == true ]]; then
      echo "$EXTERNAL_RIG_DIR" > "$RIGPATH_FILE"
      success "Created .rigpath → $EXTERNAL_RIG_DIR"
    else
      info "Skipped .rigpath due to a conflicting destination."
    fi

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
    if [[ -f "$TARGET_CLAUDE" ]] && \
       guard_destination_before_write "$TARGET" "$TARGET_CLAUDE" "CLAUDE.md"; then
      ESCAPED_EXT="${EXTERNAL_RIG_DIR//\//\\/}"
      sed_inplace "s|@\\.rig/|@${ESCAPED_EXT}/|g" "$TARGET_CLAUDE"
      # Also update the context-loading paths in the prose
      sed_inplace "s|\`.rig/memory/|\`${EXTERNAL_RIG_DIR}/memory/|g" "$TARGET_CLAUDE"
      sed_inplace "s|\`.rig/tasks/|\`${EXTERNAL_RIG_DIR}/tasks/|g" "$TARGET_CLAUDE"
      success "Updated CLAUDE.md to reference external .rig/ path"
    fi

    # Stale in-repo .rig/ cleanup: if the project has an old in-repo .rig/
    # (e.g. migrating from repo/local to stealth/external), offer to remove it.
    if [[ -d "$TARGET/.rig" ]]; then
      blank
      warn "In-repo .rig/ found at $TARGET/.rig/ — superseded by the external install at $EXTERNAL_RIG_DIR."
      if confirm "Remove the stale in-repo .rig/ now?" "y"; then
        rm -rf "$TARGET/.rig"
        success "Removed stale in-repo .rig/"
      else
        warn "Left in place. Remove it manually to clean git status:"
        warn "  rm -rf \"$TARGET/.rig\""
      fi
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
      # Helper: append entry only if not already present.
      # -x (whole-line) matters here: without it, a substring match on
      # "bin/rig" is satisfied by an already-written "bin/rig-sprint" line,
      # silently skipping the real "bin/rig" entry depending on find(1)'s
      # enumeration order. Exact-line matching removes that ordering hazard
      # for every entry, not just the bin/rig* ones.
      _stealth_exclude() {
        local entry="$1"
        if ! grep -qxF "$entry" "$GIT_EXCLUDE"; then
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
      _stealth_exclude ".agents/"
      _stealth_exclude ".codex/"
      _stealth_exclude ".mcp.json"
      _stealth_exclude ".playwright-mcp/"
      _stealth_exclude ".github/"
      _stealth_exclude ".gitleaks.toml"
      _stealth_exclude "docs/features/README.md"
      _stealth_exclude ".rig-backup/"
      _stealth_exclude ".rig/"
      # Exclude every generated launcher under bin/ — not just bin/rig.
      # Enumerated from the installer's own templates/project/bin/ source
      # rather than a hardcoded per-name list or a "bin/rig*" glob:
      #   - a hardcoded list drifts the moment a new launcher ships (this is
      #     exactly how bin/rig-connector-preflight, bin/rig-sprint, and
      #     bin/rig-tab-title-watch went unexcluded — they were added to
      #     templates/project/bin/ without a matching entry here);
      #   - a "bin/rig*" glob in .git/info/exclude is future-proof but would
      #     also silently swallow an unrelated file a project author later
      #     adds at bin/rig-<anything>, hiding it from git without their
      #     knowledge — not a call this installer should make on a user's
      #     behalf without asking.
      # Enumerating our own template source excludes exactly (and only)
      # what we install, with zero drift on future launcher additions and
      # zero risk of over-excluding a file we did not generate.
      if [[ -d "$PROJECT_TEMPLATES/bin" ]]; then
        while IFS= read -r -d '' _launcher_src; do
          _stealth_exclude "bin/$(basename "$_launcher_src")"
        done < <(find "$PROJECT_TEMPLATES/bin" -type f -print0)
      else
        _stealth_exclude "bin/rig"
      fi
      # .rigpath is already excluded by the external-mode block above
    else
      warn ".git/info/exclude not found — stealth exclusions could not be applied."
      warn "Add manually: CLAUDE.md, PROJECT_BRIEF.md, .claude/, .agents/, .codex/, .mcp.json, .playwright-mcp/, .github/, .gitleaks.toml, docs/features/README.md, bin/rig*, .rigpath"
    fi
  fi

  fi # AGENT_DRY_RUN tracking-mode bookkeeping guard

  # ── STEALTH MODE: wire hooks to .git/hooks/ (issue #458) ─────────────────
  # Deliberately outside the AGENT_DRY_RUN guard above: agent-plan needs
  # _stealth_install_git_hook()'s customization detection and
  # record_upgrade_result calls to run so a customized hook is reported via
  # conflicts[] during a read-only plan, not only during agent-upgrade.
  # _stealth_install_git_hook() itself gates every actual write (backup,
  # cp, chmod, manifest entry) behind AGENT_DRY_RUN, so this still performs
  # zero filesystem mutations under agent-plan — only classification.
  if [[ "$RIG_TRACKING" == "stealth" ]]; then
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
            _stealth_install_git_hook "$hook_src" "$hook_dest" "$hook_name"
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
  CODEX_HOOKS_DIR="$TARGET/.codex/hooks"
  RIG_DISPATCHER="$TARGET/bin/rig"

  if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
    if [[ -d "$HUSKY_DIR" || -L "$HUSKY_DIR" ]]; then
      upgrade_set_executable_bits "$HUSKY_DIR" '*' '.husky/'
      success "Set executable bits on .husky/ hooks"
    fi

    if [[ -d "$CLAUDE_HOOKS_DIR" || -L "$CLAUDE_HOOKS_DIR" ]]; then
      upgrade_set_executable_bits "$CLAUDE_HOOKS_DIR" '*.sh' '.claude/hooks/'
      success "Set executable bits on .claude/hooks/ scripts"
    fi

    if has_agent "$PROJECT_AGENT" codex && \
       [[ -d "$CODEX_HOOKS_DIR" || -L "$CODEX_HOOKS_DIR" ]]; then
      upgrade_set_executable_bits "$CODEX_HOOKS_DIR" '*.sh' '.codex/hooks/'
      success "Set executable bits on Codex hook adapters"
    fi

    if [[ -L "$RIG_DISPATCHER" ]]; then
      record_upgrade_destination_conflict 'bin/rig' symlink
    elif [[ -f "$RIG_DISPATCHER" ]]; then
      # agent-plan: classification only, never change file modes.
      [[ "$AGENT_DRY_RUN" == true ]] || chmod +x "$RIG_DISPATCHER"
      success "Set executable bit on bin/rig"
    fi
  else
    if [[ -d "$HUSKY_DIR" ]]; then
      chmod +x "$HUSKY_DIR/"* 2>/dev/null || true
      success "Set executable bits on .husky/ hooks"
    fi

    if [[ -d "$CLAUDE_HOOKS_DIR" ]]; then
      chmod +x "$CLAUDE_HOOKS_DIR/"*.sh 2>/dev/null || true
      success "Set executable bits on .claude/hooks/ scripts"
    fi

    if has_agent "$PROJECT_AGENT" codex && [[ -d "$CODEX_HOOKS_DIR" ]]; then
      chmod +x "$CODEX_HOOKS_DIR/"*.sh 2>/dev/null || true
      success "Set executable bits on Codex hook adapters"
    fi

    if [[ -f "$RIG_DISPATCHER" ]]; then
      chmod +x "$RIG_DISPATCHER"
      success "Set executable bit on bin/rig"
    fi
  fi

  # ── HUSKY INITIALIZATION ──────────────────────────────────────────────────
  # Skipped in stealth mode — hooks are already wired to .git/hooks/ above.
  # Also skipped entirely in agent mode: confirm() already defaults to "no"
  # non-interactively, but Husky init is an external side effect (npm/npx)
  # outside the file-convergence contract this lane implements — never run it
  # from agent-plan or agent-upgrade regardless of default behavior.
  if [[ "$INSTALL_GIT_HOOKS" == true && "$RIG_TRACKING" != "stealth" && -z "$AGENT_MODE" ]]; then
    if [[ -f "$TARGET/package.json" ]]; then
      blank
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
    blank
    info "Originals backed up to: $BACKUP_DIR"
  fi

  # ── HUSKY HOOK CHANGE NOTICE (non-stealth only) ────────────────────────────
  # In stealth mode hooks land in .git/hooks/ (not tracked by git). In repo/local
  # mode, .husky/ files are in the working tree — surface any modifications so the
  # user knows to stage and commit them. The next session would otherwise flag the
  # hooks as stale without any indication they need committing.
  if [[ "$RIG_TRACKING" != "stealth" ]]; then
    _husky_changed=$(git -C "$TARGET" status --porcelain -- ".husky/" 2>/dev/null \
      | grep -v "^??" || true)
    if [[ -n "$_husky_changed" ]]; then
      blank
      info "Hook files modified — stage and commit to apply them:"
      while IFS= read -r _line; do
        info "  $_line"
      done <<< "$_husky_changed"
      info "  git add .husky/ && git commit -m 'chore(hooks): update Rig git hooks'"
    fi
  fi

  # Persist only after the selected layer and its required smoke checks succeed.
  _project_smoke="$(run_capability_smoke project "$PROJECT_AGENT" "$TARGET")" || { error "Postflight smoke failed: $_project_smoke"; exit 1; }
  if [[ "$_PROJECT_STATE_FUTURE" != true ]]; then
    if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
      _project_state_base="$EXTERNAL_RIG_DIR"
      _project_state_rel="install-targets.json"
    else
      _project_state_base="$TARGET"
      _project_state_rel=".rig/install-targets.json"
    fi
    if guard_destination_before_write "$_project_state_base" "$PROJECT_TARGET_STATE" "$_project_state_rel"; then
      write_agent_state "$PROJECT_TARGET_STATE" project "$PROJECT_AGENT" "$TARGET_ABS"
    fi
  fi
  success "Postflight targets: project=$PROJECT_AGENT; smoke=$_project_smoke"

  finish_upgrade_transaction

  if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
    if [[ "$RIG_TRACKING" == "external" || "$RIG_TRACKING" == "stealth" ]]; then
      # See report_stale_manifest_entries()'s rig_root doc comment: external/
      # stealth manifests mix $TARGET-rooted and $EXTERNAL_RIG_DIR-rooted
      # rels in one file, so both roots must be passed (issue #444, lane
      # 444-E — this audit was previously skipped outright for these two
      # layouts).
      report_stale_manifest_entries "${MANIFEST_FILE}.json" "$TARGET" project "$EXTERNAL_RIG_DIR"
    else
      report_stale_manifest_entries "${MANIFEST_FILE}.json" "$TARGET" project
    fi
    # report_future_manifest_revisions() for this layer already ran earlier,
    # before any project-layer write — see the call right after
    # PROJECT_TARGET_STATE is set, above. Running it here too would
    # double-count, and would miss entries a legitimate write this run
    # already silently corrected (issue #463).
  fi

  blank
fi

# ── GITLEAKS CHECK ────────────────────────────────────────────────────────────
blank
bold "── Checking dependencies ──"
blank

GITLEAKS_OK=false
if [[ ",${_RIG_TEST_MISSING_COMMANDS:-}," != *",gitleaks,"* ]]; then
  if command -v gitleaks >/dev/null 2>&1; then
    GITLEAKS_OK=true
  elif [[ -x "/usr/local/bin/gitleaks" || -x "/opt/homebrew/bin/gitleaks" ]]; then
    GITLEAKS_OK=true
  fi
fi

if [[ "$GITLEAKS_OK" == true ]]; then
  success "gitleaks is installed — secret scanning is active"
else
  warn "gitleaks is NOT installed — secret scanning will be skipped on commits"
  # Retro-audit finding, PR #446 follow-up: these two lines were plain
  # echo, not routed through the warn()/blank() AGENT_MODE-gating
  # convention above -- the only leak of its kind still reachable when
  # gitleaks isn't on PATH, breaking agent-plan/agent-upgrade's "exactly
  # one JSON document on stdout" contract in exactly that environment.
  if [[ -z "$AGENT_MODE" ]]; then
    echo "  Install it: brew install gitleaks"
    echo "  Docs: https://github.com/gitleaks/gitleaks"
  fi
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
#
# Never run in agent mode: this is a destructive rm -rf outside the
# file-convergence contract, and agent-plan must be provably read-only.
if [[ "$DO_PROJECT" == true && -n "${TARGET_ABS:-}" && -z "$AGENT_MODE" ]]; then
  SCRIPT_ABS="$(cd "$SCRIPT_DIR" && pwd)"
  if [[ "$SCRIPT_ABS" == "$TARGET_ABS" ]]; then
    # Guard: if install.sh is committed in this repo, we're inside The Rig's own
    # source tree — skip cleanup to avoid deleting project source files.
    if ! git -C "$SCRIPT_ABS" ls-files --error-unmatch install.sh &>/dev/null 2>&1; then
      blank
      warn "The installer was run from inside the target project directory."
      echo "  The following The Rig source files are no longer needed in your project:"
      blank
      echo "    templates/     — scaffolding source (already consumed)"
      echo "    docs/          — The Rig's own architecture docs"
      echo "    CHANGELOG.md   — The Rig's changelog"
      echo "    install.sh     — this installer"
      echo "    LICENSE        — The Rig's MIT license"
      echo "    README.md      — The Rig's README (replace with your project's)"
      blank
      echo "  Your project files (CLAUDE.md, .rig/, .claude/, .husky/, PROJECT_BRIEF.md, etc.)"
      echo "  are NOT affected."
      blank
      if confirm "Remove these Rig source files from your project directory?" "y"; then
        for rig_file in templates docs CHANGELOG.md install.sh LICENSE README.md; do
          if [[ -e "$TARGET_ABS/$rig_file" ]]; then
            rm -rf "${TARGET_ABS:?}/$rig_file"
            success "Removed $rig_file"
          fi
        done
        blank
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
UPGRADE_REVIEW_REQUIRED=0
if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
  [[ "$UPGRADE_SKIPPED_CUSTOMIZED_COUNT" -gt 0 ]] && UPGRADE_REVIEW_REQUIRED=1
  [[ "$UPGRADE_SKIPPED_CONFLICT_COUNT" -gt 0 ]] && UPGRADE_REVIEW_REQUIRED=1
  [[ "$UPGRADE_STALE_UNREPAIRED_COUNT" -gt 0 ]] && UPGRADE_REVIEW_REQUIRED=1
  # issue #463: a manifest entry claiming a future/bogus base_revision is
  # never silently accepted — same fail-closed treatment as the findings
  # above, which is what drives agent-plan/agent-upgrade's "refused" exit 3
  # below for this condition too.
  [[ "$UPGRADE_FUTURE_REVISION_COUNT" -gt 0 ]] && UPGRADE_REVIEW_REQUIRED=1
fi

if [[ -n "$AGENT_MODE" ]]; then
  # ── Agent-driven contract result (issue #444, lane 444-A) ──────────────────
  # agent-plan/agent-upgrade emit exactly one JSON document on stdout instead
  # of the human-oriented summary below (info/success/warn/bold/ask are
  # no-ops in AGENT_MODE; this is the only stdout content they produce).
  #
  # Exit code 3 is new and dedicated to this contract. It is deliberately
  # distinct from the two exit codes already in use elsewhere in this script:
  # 1 is the general fatal-error code, and 2 is reserved for malformed or
  # missing project/global target metadata (see the --strategy/--global-agent/
  # --project-agent parsing earlier in this file). Neither of those means
  # "the run completed but left something for a human to review" — reusing
  # either would make that state indistinguishable from a crash or a bad
  # flag. status="refused" + exit 3 together mean: nothing was silently
  # overwritten or silently accepted as converged; a customized or
  # conflicting file needs manual review before this project is fully
  # upgraded. A run with zero customized/conflicting files exits 0 with
  # status="success", whether or not anything was actually updated.
  _agent_status="success"
  [[ "$UPGRADE_REVIEW_REQUIRED" -eq 1 ]] && _agent_status="refused"
  # The artifact log is passed via a temp file, not a pipe: python3 - <<'PYEOF'
  # already claims stdin to read its own script source, so piping data into
  # the same stdin would silently discard it (the heredoc redirect wins over
  # the pipe for that fd). A file argv sidesteps the conflict entirely.
  _agent_records_file="$(mktemp)"
  printf '%s\n' "${UPGRADE_ARTIFACT_RECORDS[@]:-}" > "$_agent_records_file"
  _agent_json="$(python3 - \
    "$AGENT_MODE" "$_agent_status" "$_agent_records_file" \
    "$UPGRADE_UPDATED_COUNT" "$UPGRADE_MERGED_COUNT" "$UPGRADE_REMOVED_COUNT" \
    "$UPGRADE_SKIPPED_CUSTOMIZED_COUNT" "$UPGRADE_SKIPPED_CONFLICT_COUNT" \
    "$UPGRADE_SKIPPED_UNTRACKED_COUNT" "$UPGRADE_STALE_COUNT" "$UPGRADE_CONVERGED_COUNT" <<'PYEOF'
import json, sys

mode, status, records_path = sys.argv[1], sys.argv[2], sys.argv[3]
(updated, merged, removed, skipped_customized, skipped_conflict,
 skipped_untracked, stale, converged) = (int(x) for x in sys.argv[4:12])

# result-code (as passed to record_upgrade_result in install.sh) -> fields.
CLASSIFICATION = {
    "updated": "unmodified-since-install",
    "merged": "settings-mergeable",
    # issue #444 lane 444-C: resolved by the structure-aware/three-way
    # convergence engine (installer/merge-*.py), not the existing
    # additive-dedup smart-merge for settings.json (that is "merged" above).
    # NOTE: this heredoc is nested inside a $(...) command substitution --
    # bash 3.2 (macOS default) mis-tracks quote balance if a heredoc body
    # here contains a literal apostrophe, so avoid them in this block.
    "converged": "converged",
    "removed": "obsolete",
    "migrated": "moved-project-reference",
    "up-to-date": "up-to-date",
    "skipped-untracked": "user-owned-untracked",
    "skipped-customized": "customized",
    "skipped-conflict": "conflict",
}
ACTION = {
    "updated": "update",
    "merged": "merge",
    "converged": "merge",
    "removed": "remove",
    "migrated": "rewrite",
    "up-to-date": "none",
    "skipped-untracked": "skip",
    "skipped-customized": "skip",
    "skipped-conflict": "skip",
}
REASON = {
    "updated": "template file updated to the incoming Rig version",
    "merged": "settings.json merged (smart-merge) with the incoming Rig version",
    "converged": (
        "local customization preserved while incorporating conflict-free "
        "incoming Rig changes via structure-aware or three-way merge"
    ),
    "removed": "obsolete Rig-owned artifact retired",
    "migrated": "path references rewritten for a moved project root",
    "up-to-date": "already matches the incoming Rig version; no action needed",
    "skipped-untracked": "user-owned file with no prior manifest baseline; preserved untouched",
    "skipped-customized": "local content differs from the recorded Rig baseline (customized)",
    "skipped-conflict": "destination path has an unsupported type/symlink/location conflict",
}
REPAIR_GUIDANCE = {
    "skipped-customized": (
        "Resolve manually and re-run, or restore the file from .rig-backup/ "
        "and accept the incoming template on the next upgrade."
    ),
    "skipped-conflict": (
        "Remove or repair the conflicting path explicitly (wrong type, "
        "symlink, or out-of-root location), then re-run the upgrade."
    ),
}

artifacts = []
conflicts = []
with open(records_path) as fh:
    records_text = fh.read()
for line in records_text.split("\n"):
    if not line:
        continue
    path, sep, rest = line.partition("\x1e")
    if not sep:
        continue
    result, _, detail_raw = rest.partition("\x1e")
    entry = {
        "path": path,
        "classification": CLASSIFICATION.get(result, result),
        "action": ACTION.get(result, "unknown"),
        "reason": REASON.get(result, result),
    }
    artifacts.append(entry)
    if result in REPAIR_GUIDANCE:
        # issue #444 lane 444-C: when the convergence engine attempted a
        # merge and hit a real conflict, detail_raw is a JSON-encoded array
        # of the specific keys/lines that conflicted (see
        # attempt_convergence_merge() in install.sh and installer/merge-*.py).
        # Empty for every path that never reached the convergence engine
        # (e.g. no python3, unsupported destination conflict).
        try:
            details = json.loads(detail_raw) if detail_raw else []
            if not isinstance(details, list):
                details = []
        except ValueError:
            details = []
        conflicts.append({
            "path": path,
            "reason": entry["reason"],
            "repair_guidance": REPAIR_GUIDANCE[result],
            "details": details,
        })

doc = {
    "schema_version": 1,
    "mode": mode,
    "status": status,
    "summary": {
        "updated": updated,
        "merged": merged,
        "converged": converged,
        "removed_obsolete": removed,
        "skipped_customized": skipped_customized,
        "skipped_conflict": skipped_conflict,
        "skipped_untracked": skipped_untracked,
        "stale": stale,
    },
    "artifacts": artifacts,
    "conflicts": conflicts,
}
print(json.dumps(doc, separators=(",", ":")))
PYEOF
)"
  rm -f "$_agent_records_file"
  printf '%s\n' "$_agent_json"
  if [[ "$_agent_status" == "refused" ]]; then
    exit 3
  fi
  exit 0
fi

blank
if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
  bold "── Upgrade summary ──"
  echo "Updated: $UPGRADE_UPDATED_COUNT"
  echo "Merged: $UPGRADE_MERGED_COUNT"
  echo "Removed obsolete: $UPGRADE_REMOVED_COUNT"
  echo "Skipped customized: $UPGRADE_SKIPPED_CUSTOMIZED_COUNT"
  echo "Skipped conflicts: $UPGRADE_SKIPPED_CONFLICT_COUNT"
  echo "Skipped untracked user-owned: $UPGRADE_SKIPPED_UNTRACKED_COUNT"
  echo "Stale/missing tracked artifacts: $UPGRADE_STALE_COUNT"
  echo "Future/bogus manifest base_revision: $UPGRADE_FUTURE_REVISION_COUNT"
  if [[ "$UPGRADE_STALE_COUNT" -gt 0 ]]; then
    echo "Stale artifacts requiring explicit repair or migration:"
    for _stale_file in "${UPGRADE_STALE_FILES[@]}"; do
      echo "  - $_stale_file"
    done
  fi
  if [[ "$UPGRADE_SKIPPED_CUSTOMIZED_COUNT" -gt 0 ]]; then
    UPGRADE_REVIEW_REQUIRED=1
    echo "Customized files requiring manual review:"
    for _skipped_file in "${UPGRADE_SKIPPED_CUSTOMIZED_FILES[@]}"; do
      echo "  - $_skipped_file"
    done
  fi
  if [[ "$UPGRADE_SKIPPED_CONFLICT_COUNT" -gt 0 ]]; then
    UPGRADE_REVIEW_REQUIRED=1
    echo "Conflicting legacy artifacts requiring explicit repair:"
    for _conflict_file in "${UPGRADE_SKIPPED_CONFLICT_FILES[@]}"; do
      echo "  - $_conflict_file"
    done
  fi
  if [[ "$UPGRADE_FUTURE_REVISION_COUNT" -gt 0 ]]; then
    UPGRADE_REVIEW_REQUIRED=1
    echo "Manifest entries claiming a future/bogus base_revision (issue #463 — requires review):"
    for _future_file in "${UPGRADE_FUTURE_REVISION_FILES[@]}"; do
      echo "  - $_future_file"
    done
  fi
  python3 -c 'import json,sys
d=json.load(sys.stdin)
missing=[x["id"] for x in d["dependencies"] if x["status"] != "ok" and x["classification"] != "optional"]
print("Selected agents: global=%s project=%s" % (sys.argv[1], sys.argv[2]))
print("Missing prerequisites: " + (", ".join(missing) or "none"))
print("Degraded/skipped capabilities: " + (", ".join(d["degraded_features"]) or "none"))
print("Exact next steps: " + ("; ".join(d["next_steps"]) or "none"))' "$GLOBAL_AGENT" "$PROJECT_AGENT" <<< "$_preflight_json"
  [[ "$DO_GLOBAL" == true ]] && echo "Global smoke tests (expected signal: passed): ${_global_smoke:-none}"
  [[ "$DO_PROJECT" == true ]] && echo "Project smoke tests (expected signal: passed): ${_project_smoke:-none}"
  blank
fi

# Unconditional safety net: finalize any transaction still open at this
# point, regardless of which specific write path last touched it. Retro-
# audit finding, found by re-running the full suite after fixing
# upgrade_prepare_mutation()'s missing-branch journal gap above: that fix
# made install-targets.json's first-ever write (after the global Codex
# skills loop's own explicit finish_upgrade_transaction call) open a *new*
# transaction with nothing left in the script to finalize it, leaving
# .rig-backup/.in-progress on disk and causing every subsequent upgrade run
# to fail closed with "interrupted upgrade transaction exists." Explicit
# per-call-site finalize calls are easy to miss when a fix adds a new
# transaction-opening write path partway through the script; one
# unconditional call at the very end, after all layers have finished,
# closes this class of gap structurally instead of per call site.
# finish_upgrade_transaction() already no-ops safely when nothing is open.
finish_upgrade_transaction

bold "── Done ──"
blank
if [[ "$COLLISION_STRATEGY" != upgrade ]]; then
  echo "Target matrix: global=$GLOBAL_AGENT project=$PROJECT_AGENT"
  echo "Missing required prerequisites: none"
  if [[ "$GITLEAKS_OK" == true ]]; then echo "Degraded features: none"; else echo "Degraded features: secret-scanning (gitleaks missing)"; fi
fi
[[ "$DO_GLOBAL" == true && "$GLOBAL_AGENT" == none ]] && echo "Preserved deselected global agent files (no cleanup performed)."
[[ "$DO_PROJECT" == true && "$PROJECT_AGENT" == none ]] && echo "Preserved deselected project agent files (no cleanup performed)."
[[ -n "${PREVIOUS_GLOBAL_AGENT:-}" && "$PREVIOUS_GLOBAL_AGENT" != "$GLOBAL_AGENT" ]] && echo "Preserved prior global target files: $PREVIOUS_GLOBAL_AGENT."
[[ -n "${PREVIOUS_PROJECT_AGENT:-}" && "$PREVIOUS_PROJECT_AGENT" != "$PROJECT_AGENT" ]] && echo "Preserved prior project target files: $PREVIOUS_PROJECT_AGENT."
[[ "$COLLISION_STRATEGY" != upgrade ]] && echo "Postflight smoke results: manifest-derived checks passed."
if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
  echo "The Rig upgrade is complete. Next steps:"
else
  echo "The Rig is installed. Next steps:"
fi
blank

if [[ "$DO_GLOBAL" == true ]] && has_agent "$GLOBAL_AGENT" claude; then
  echo "  1. Fill in ~/.claude/CLAUDE.md:"
  echo "     - '## Personal context' — your name, role, stack, and working style"
  echo "     - '## Stack defaults' — the languages and frameworks you use"
  blank
fi

if [[ "$DO_GLOBAL" == true ]] && has_agent "$GLOBAL_AGENT" codex; then
  echo "  Codex personal skills are installed under ~/.agents/skills/."
  blank
fi

if [[ "$DO_PROJECT" == true ]]; then
  echo "  3. Fill in ${TARGET:-your-project}/CLAUDE.md"
  echo "     (stack, conventions, off-limits paths)"
  blank
  if has_agent "$PROJECT_AGENT" claude; then
    echo "  4. Open a Claude Code session in your project and run /kickoff or /task"
    blank
  fi
  if has_agent "$PROJECT_AGENT" codex; then
    echo "  4. Open a Codex session in your project and run \$kickoff or \$task"
    blank
  fi
fi

if has_agent "$GLOBAL_AGENT" codex || has_agent "$PROJECT_AGENT" codex; then
  echo "  Codex: launch 'codex' and verify native project guidance."
  echo "  Codex hooks: open /hooks, review The Rig project hooks, and trust their current definitions."
fi

echo "Documentation: https://github.com/laudtetteh/the-rig"
blank
if [[ "$COLLISION_STRATEGY" == upgrade ]]; then
  echo "RIG_UPGRADE_REVIEW_REQUIRED=$UPGRADE_REVIEW_REQUIRED"
fi
