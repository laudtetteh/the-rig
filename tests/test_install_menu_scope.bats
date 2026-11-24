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
  [ -f "$skills/rig-review-basics/SKILL.md" ]
  grep -q '^name: rig-review-basics$' "$skills/rig-review-basics/SKILL.md"
  grep -q '~/.claude/skills/rig-review-basics/SKILL.md' "$skills/rig-review-basics/SKILL.md"
  grep -q '~/.agents/skills/rig-review-basics/SKILL.md' "$home/.agents/skills/rig-review-basics/SKILL.md"
  if grep -q '~/.claude/skills/rig-review-basics/SKILL.md' "$home/.agents/skills/rig-review-basics/SKILL.md"; then return 1; fi
  python3 - "$skills" "$manifest" <<'PY'
import json, pathlib, shutil, sys
skills, manifest = map(pathlib.Path, sys.argv[1:])
for name in ("rig-review-basics", "explain", "rig-debug-basics", "refactor"):
    shutil.move(str(skills / name / "SKILL.md"), str(skills / f"{name}.md"))
    (skills / name).rmdir()
manifest.write_text(manifest.read_text().replace(
    "skills/rig-review-basics/SKILL.md", "skills/rig-review-basics.md").replace(
    "skills/explain/SKILL.md", "skills/explain.md").replace(
    "skills/rig-debug-basics/SKILL.md", "skills/rig-debug-basics.md").replace(
    "skills/refactor/SKILL.md", "skills/refactor.md"))
metadata = manifest.with_name(manifest.name + ".json")
data = json.loads(metadata.read_text())
for name in ("rig-review-basics", "explain", "rig-debug-basics", "refactor"):
    data["entries"][f"skills/{name}.md"] = data["entries"].pop(f"skills/{name}/SKILL.md")
metadata.write_text(json.dumps(data) + "\n")
PY
  printf '\n# personal change\n' >> "$skills/explain.md"
  printf 'conflicting destination\n' > "$skills/rig-debug-basics"
  mkdir "$BATS_TEST_TMPDIR/external-refactor"
  cp "$skills/refactor.md" "$BATS_TEST_TMPDIR/external-refactor/SKILL.md"
  ln -s "$BATS_TEST_TMPDIR/external-refactor" "$skills/refactor"
  run env HOME="$home" bash "$REPO_ROOT/install.sh" --global-only --global-agent both --strategy agent-plan
  [ "$status" -eq 3 ]
  python3 - "$output" <<'PY' || return 1
import json, sys
plan = json.loads(sys.argv[1])
artifacts = {item["path"]: item for item in plan["artifacts"]}
assert plan["mode"] == "plan" and plan["status"] == "refused"
assert artifacts["skills/rig-review-basics.md"]["action"] == "remove"
assert artifacts["skills/explain.md"]["classification"] == "customized"
assert artifacts["skills/rig-debug-basics/SKILL.md"]["classification"] == "conflict"
PY
  [ -f "$skills/rig-review-basics.md" ]
  [ ! -e "$skills/rig-review-basics/SKILL.md" ]
  run env HOME="$home" bash "$REPO_ROOT/install.sh" --global-only --global-agent both --strategy upgrade
  [ "$status" -eq 0 ]
  [ ! -e "$skills/rig-review-basics.md" ]
  [ -f "$skills/rig-review-basics/SKILL.md" ]
  [ -f "$skills/explain.md" ]
  grep -q '# personal change' "$skills/explain.md"
  [ -f "$skills/explain/SKILL.md" ]
  [ -f "$skills/rig-debug-basics.md" ]
  [ -f "$skills/rig-debug-basics" ]
  [ ! -e "$skills/rig-debug-basics/SKILL.md" ]
  [ -f "$skills/refactor.md" ]
  [ -L "$skills/refactor" ]
  if grep -q 'skills/rig-review-basics.md' "$manifest"; then return 1; fi
  grep -q 'skills/rig-review-basics/SKILL.md' "$manifest"
  [[ "$output" == *'Preserved customized legacy Claude skill: skills/explain.md'* ]] || return 1
}
