#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

make_repo() {
  mkdir -p "$1"
  git -C "$1" init -q
}

@test "project-only wins over First install and Upgrade menu choices" {
  local home="$BATS_TEST_TMPDIR/home" project="$BATS_TEST_TMPDIR/project"
  mkdir -p "$home"
  make_repo "$project"
  run bash -c 'printf "1\n" | HOME="$1" bash "$2/install.sh" --project-only --target "$3" --project-name project --tracking repo --project-agent claude' bash "$home" "$REPO_ROOT" "$project"
  [ "$status" -eq 0 ]
  [ -f "$project/bin/rig" ]
  [ ! -e "$home/.claude" ]
  run bash -c 'printf "3\n" | HOME="$1" bash "$2/install.sh" --project-only --target "$3" --project-name project --tracking repo --project-agent claude' bash "$home" "$REPO_ROOT" "$project"
  [ "$status" -eq 0 ]
  [ ! -e "$home/.claude" ]
}

@test "global upgrade migrates clean flat skills and preserves customized flat skills" {
  local home="$BATS_TEST_TMPDIR/home" skills manifest
  mkdir -p "$home"
  run env HOME="$home" bash "$REPO_ROOT/install.sh" --global-only --global-agent both --strategy merge
  [ "$status" -eq 0 ]
  skills="$home/.claude/skills"
  manifest="$home/.claude/.rig-global-manifest"
  [ -f "$skills/code-review/SKILL.md" ]
  grep -q '^name: code-review$' "$skills/code-review/SKILL.md"
  grep -q '~/.claude/skills/code-review/SKILL.md' "$skills/code-review/SKILL.md"
  grep -q '~/.agents/skills/code-review/SKILL.md' "$home/.agents/skills/code-review/SKILL.md"
  ! grep -q '~/.claude/skills/code-review/SKILL.md' "$home/.agents/skills/code-review/SKILL.md"
  python3 - "$skills" "$manifest" <<'PY'
import json, pathlib, shutil, sys
skills, manifest = map(pathlib.Path, sys.argv[1:])
for name in ("code-review", "explain", "debug", "refactor"):
    shutil.move(str(skills / name / "SKILL.md"), str(skills / f"{name}.md"))
    (skills / name).rmdir()
manifest.write_text(manifest.read_text().replace(
    "skills/code-review/SKILL.md", "skills/code-review.md").replace(
    "skills/explain/SKILL.md", "skills/explain.md").replace(
    "skills/debug/SKILL.md", "skills/debug.md").replace(
    "skills/refactor/SKILL.md", "skills/refactor.md"))
metadata = manifest.with_name(manifest.name + ".json")
data = json.loads(metadata.read_text())
for name in ("code-review", "explain", "debug", "refactor"):
    data["entries"][f"skills/{name}.md"] = data["entries"].pop(f"skills/{name}/SKILL.md")
metadata.write_text(json.dumps(data) + "\n")
PY
  printf '\n# personal change\n' >> "$skills/explain.md"
  printf 'conflicting destination\n' > "$skills/debug"
  mkdir "$BATS_TEST_TMPDIR/external-refactor"
  cp "$skills/refactor.md" "$BATS_TEST_TMPDIR/external-refactor/SKILL.md"
  ln -s "$BATS_TEST_TMPDIR/external-refactor" "$skills/refactor"
  run env HOME="$home" bash "$REPO_ROOT/install.sh" --global-only --global-agent both --strategy agent-plan
  [ "$status" -eq 3 ]
  [[ "$output" == *'Migrated legacy Claude skill: skills/code-review.md'* ]]
  [ -f "$skills/code-review.md" ]
  [ ! -e "$skills/code-review/SKILL.md" ]
  run env HOME="$home" bash "$REPO_ROOT/install.sh" --global-only --global-agent both --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$skills/code-review.md" ]
  [ -f "$skills/code-review/SKILL.md" ]
  [ -f "$skills/explain.md" ]
  grep -q '# personal change' "$skills/explain.md"
  [ -f "$skills/explain/SKILL.md" ]
  [ -f "$skills/debug.md" ]
  [ -f "$skills/debug" ]
  [ ! -e "$skills/debug/SKILL.md" ]
  [ -f "$skills/refactor.md" ]
  [ -L "$skills/refactor" ]
  ! grep -q 'skills/code-review.md' "$manifest"
  grep -q 'skills/code-review/SKILL.md' "$manifest"
  [[ "$output" == *'Preserved customized legacy Claude skill: skills/explain.md'* ]]
}
