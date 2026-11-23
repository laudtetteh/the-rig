#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

make_repo() {
  local root="$1"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" config user.email test@example.com
  git -C "$root" config user.name Test
  printf 'fixture\n' > "$root/README"
  git -C "$root" add README
  git -C "$root" commit -qm seed
}

setup() {
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME"
}

@test "linked stealth install and upgrade use Git common paths and rollback a hook" {
  local primary="$BATS_TEST_TMPDIR/primary" linked="$BATS_TEST_TMPDIR/linked" hooks exclude rid
  make_repo "$primary"
  git -C "$primary" worktree add -qb linked "$linked"

  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$linked" --project-name linked --tracking stealth --strategy merge
  [ "$status" -eq 0 ]
  hooks="$(git -C "$linked" rev-parse --git-path hooks)"
  exclude="$(git -C "$linked" rev-parse --git-path info/exclude)"
  [ -f "$hooks/pre-commit" ]
  grep -qxF 'bin/rig-path.py' "$exclude"
  [ -z "$(git -C "$linked" status --short)" ]
  run python3 "$REPO_ROOT/installer/audit-stealth.py" "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"leak_count": 0'* ]]
  run python3 "$REPO_ROOT/installer/repair-stealth.py" "$linked"
  [ "$status" -eq 0 ]
  [[ "$output" == *'"repaired": []'* ]]

  printf '\n# local customization\n' >> "$hooks/pre-commit"
  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$linked" --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *'Stale/missing tracked artifacts: 0'* ]]
  ! grep -qF '# local customization' "$hooks/pre-commit"
  run "$linked/bin/rig" upgrade rollback --last --dry-run --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"path":"hooks/pre-commit"'* ]]
  rid="$(printf '%s' "$output" | python3 -c 'import json,sys; print(json.load(sys.stdin)["rollback_id"])')"
  mkdir -p "$linked/custom-hooks"
  git -C "$linked" config core.hooksPath custom-hooks
  run "$linked/bin/rig" upgrade rollback --id "$rid" --confirm "$rid" --json
  [ "$status" -eq 0 ]
  grep -qF '# local customization' "$hooks/pre-commit"
  [ ! -e "$linked/custom-hooks/pre-commit" ]
  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$linked" --strategy upgrade
  [ "$status" -eq 0 ]
  [[ "$output" == *'Stale/missing tracked artifacts: 0'* ]]

  mkdir -p "$BATS_TEST_TMPDIR/outside-info"
  mv "$(dirname "$exclude")" "$BATS_TEST_TMPDIR/original-info"
  printf 'outside\n' > "$BATS_TEST_TMPDIR/outside-info/exclude"
  ln -s "$BATS_TEST_TMPDIR/outside-info" "$(dirname "$exclude")"
  run python3 "$REPO_ROOT/installer/repair-stealth.py" "$linked"
  [ "$status" -eq 2 ]
  [[ "$output" == *'not a regular contained Git exclude file'* ]]
  [ "$(cat "$BATS_TEST_TMPDIR/outside-info/exclude")" = outside ]
}

@test "same-name stealth project refuses another project's Rig directory and warns on hooksPath" {
  local first="$BATS_TEST_TMPDIR/one/app" second="$BATS_TEST_TMPDIR/two/app"
  make_repo "$first"
  make_repo "$second"
  mkdir -p "$first/custom-hooks"
  git -C "$first" config core.hooksPath custom-hooks
  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$first" --project-name app --tracking stealth --strategy merge
  [ "$status" -eq 0 ]
  [[ "$output" == *'core.hooksPath is configured'* ]]
  [ ! -e "$first/custom-hooks/pre-commit" ]

  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$second" --project-name app --tracking stealth --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Rig directory already belongs to another project'* ]]
  [ ! -e "$second/.rigpath" ]
  # A manually added pointer must not disguise an occupied directory while
  # the recorded owner still exists at a different project root.
  printf '%s\n' "$HOME/.rig/projects/app" > "$second/.rigpath"
  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$second" --project-name app --tracking stealth --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Rig directory already belongs to another project'* ]]
  mv "$first" "$BATS_TEST_TMPDIR/one/moved-app"
  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$second" --project-name app --tracking stealth --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Rig directory already belongs to another project'* ]]
  mv "$BATS_TEST_TMPDIR/one/moved-app" "$first"
  python3 - "$HOME/.rig/projects/app/install-targets.json" <<'PY'
import json, sys
path = sys.argv[1]
with open(path, encoding="utf-8") as handle:
    state = json.load(handle)
state.pop("project_root", None)
with open(path, "w", encoding="utf-8") as handle:
    json.dump(state, handle)
PY
  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$first" --project-name app --tracking stealth --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Rig directory already belongs to another project'* ]]
}

@test "nested target refuses parent Git exclude and hooks in install audit and repair" {
  local parent="$BATS_TEST_TMPDIR/parent" nested="$BATS_TEST_TMPDIR/parent/nested" exclude hooks before
  make_repo "$parent"
  mkdir -p "$nested"
  exclude="$(git -C "$parent" rev-parse --git-path info/exclude)"
  hooks="$(git -C "$parent" rev-parse --git-path hooks)"
  [[ "$exclude" == /* ]] || exclude="$parent/$exclude"
  [[ "$hooks" == /* ]] || hooks="$parent/$hooks"
  before="$(shasum -a 256 "$exclude")"
  run bash "$REPO_ROOT/install.sh" --project-only --project-agent claude \
    --target "$nested" --project-name nested --tracking stealth --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Target must be the Git worktree root'* ]]
  [ ! -e "$nested/.rigpath" ]
  [ "$(shasum -a 256 "$exclude")" = "$before" ]
  [ ! -e "$hooks/pre-commit" ]
  run python3 "$REPO_ROOT/installer/audit-stealth.py" "$nested"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code": "not-a-git-root"'* ]]
  run python3 "$REPO_ROOT/installer/repair-stealth.py" "$nested"
  [ "$status" -eq 2 ]
  [[ "$output" == *'"code": "not-a-git-root"'* ]]
  [ "$(shasum -a 256 "$exclude")" = "$before" ]
}

@test "existing owner symlink refuses before any project mutation" {
  local app="$BATS_TEST_TMPDIR/app" rig="$HOME/.rig/projects/app" outside="$BATS_TEST_TMPDIR/owner.json" before
  make_repo "$app"
  mkdir -p "$rig/memory"
  printf '%s\n' "$rig" > "$app/.rigpath"
  printf '{"schema_version":1,"layer":"project","agents":["claude"],"project_root":"%s"}\n' "$app" > "$outside"
  before="$(shasum -a 256 "$outside")"
  ln -s "$outside" "$rig/install-targets.json"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Rig directory already belongs to another project'* ]]
  [ ! -e "$app/bin/rig" ]
  [ ! -d "$rig/preflight-snapshots" ]
  [ "$(shasum -a 256 "$outside")" = "$before" ]
  rm "$outside"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Rig directory already belongs to another project'* ]]
  [ ! -e "$app/bin/rig" ]
  rm "$rig/install-targets.json"
  printf '{"schema_version":1,"layer":"project","agents":["claude"],"project_root":"%s"}\n' "$app" > "$rig/install-targets.json"
  mv "$app/.rigpath" "$BATS_TEST_TMPDIR/pointer"
  ln -s "$BATS_TEST_TMPDIR/pointer" "$app/.rigpath"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy merge
  [ "$status" -ne 0 ]
  [[ "$output" == *'Rig directory already belongs to another project'* ]]
  [ ! -e "$app/bin/rig" ]
}

@test "bootstrap and doctor derive all shipped bin paths from the manifest" {
  local primary="$BATS_TEST_TMPDIR/primary" linked="$BATS_TEST_TMPDIR/elsewhere/linked" rig="$BATS_TEST_TMPDIR/rig"
  make_repo "$primary"
  mkdir -p "$BATS_TEST_TMPDIR/elsewhere"
  git -C "$primary" worktree add -qb linked "$linked"
  mkdir -p "$primary/bin" "$rig/memory"
  printf '%s\n' "$rig" > "$primary/.rigpath"
  cp "$REPO_ROOT/templates/project/bin/rig" "$primary/bin/rig"
  cp "$REPO_ROOT/templates/project/bin/rig-path.py" "$primary/bin/rig-path.py"
  cp "$REPO_ROOT/templates/project/bin/rig-sprint" "$primary/bin/rig-sprint"
  cp "$REPO_ROOT/templates/project/bin/rig-connector-preflight" "$primary/bin/rig-connector-preflight"
  cp "$REPO_ROOT/templates/project/bin/rig-tab-title-watch" "$primary/bin/rig-tab-title-watch"
  chmod +x "$primary/bin/rig"
  for name in rig rig-path.py rig-sprint rig-connector-preflight rig-tab-title-watch; do
    printf 'hash  bin/%s\n' "$name" >> "$rig/memory/.rig-manifest"
  done
  printf 'sensitive\n' > "$BATS_TEST_TMPDIR/secret"
  printf 'hash  bin/../../secret\n' >> "$rig/memory/.rig-manifest"
  run bash -c 'cd "$1" && "$2" worktree bootstrap' bash "$linked" "$primary/bin/rig"
  [ "$status" -eq 0 ]
  for name in rig rig-path.py rig-sprint rig-connector-preflight rig-tab-title-watch; do
    [ -f "$linked/bin/$name" ]
  done
  [ ! -e "$BATS_TEST_TMPDIR/elsewhere/secret" ]
  run "$linked/bin/rig" doctor --json
  [[ "$output" == *'"name":"worktree_bootstrap"'* ]]
  [[ "$output" != *'"name":"worktree_bootstrap","ok":false'* ]]
  mv "$primary/bin" "$BATS_TEST_TMPDIR/outside-bin"
  ln -s "$BATS_TEST_TMPDIR/outside-bin" "$primary/bin"
  rm "$linked/bin/rig-tab-title-watch"
  run bash -c 'cd "$1" && "$2" worktree bootstrap' bash "$linked" "$linked/bin/rig"
  [ "$status" -eq 3 ]
  [[ "$output" == *'source path escapes primary worktree'* ]]
  [ ! -e "$linked/bin/rig-tab-title-watch" ]
}

@test "explicit adoption upgrades real v1.8.1 and v1.20.0 external installs without taking another checkout" {
  local version old app rig other tracking before
  for version in v1.8.1 v1.20.0; do
    old="$BATS_TEST_TMPDIR/$version/old"
    app="$BATS_TEST_TMPDIR/$version/one/app"
    other="$BATS_TEST_TMPDIR/$version/two/app"
    rig="$HOME/.rig/projects/$version-app"
    mkdir -p "$old"
    git -C "$REPO_ROOT" archive "$version" | tar -xf - -C "$old"
    make_repo "$app"
    make_repo "$other"
    if [ "$version" = v1.8.1 ]; then
      tracking=external
      run bash "$old/install.sh" --project-only --target "$app" --project-name app \
        --rig-dir "$rig" --strategy merge
    else
      tracking=stealth
      run bash "$old/install.sh" --project-only --target "$app" --project-name app \
        --rig-dir "$rig" --tracking stealth --strategy merge --project-agent claude
    fi
    [ "$status" -eq 0 ]
    [ -f "$rig/memory/.rig-manifest" ]
    [ ! -e "$rig/install-targets.json" ]
    before="$(shasum -a 256 "$rig/memory/.rig-manifest")"

    run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
      --tracking "$tracking" --strategy upgrade
    [ "$status" -ne 0 ]
    [[ "$output" == *'Rig directory already belongs to another project'* ]]
    [ ! -e "$rig/install-targets.json" ]

    run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
      --tracking "$tracking" --strategy agent-plan --adopt-legacy-rig-dir
    # Historical customized hooks can make an otherwise read-only plan
    # return review-required; adoption eligibility itself is still checked.
    [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
    [[ "$output" == *'"mode":"plan"'* ]]
    [ ! -e "$rig/install-targets.json" ]
    [ "$(shasum -a 256 "$rig/memory/.rig-manifest")" = "$before" ]
    [ ! -d "$rig/preflight-snapshots" ]

    run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
      --tracking "$tracking" --strategy upgrade --adopt-legacy-rig-dir
    [ "$status" -eq 0 ]
    [[ "$output" == *'Adopted legacy Rig directory for this project'* ]]
    [ -d "$rig/preflight-snapshots" ]
    [ "$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["project_root"])' "$rig/install-targets.json")" = "$app" ]
    run "$app/bin/rig" upgrade rollback --last --dry-run --json
    [ "$status" -eq 0 ]
    [[ "$output" == *'"path":"install-targets.json"'* ]]

    run bash "$REPO_ROOT/install.sh" --project-only --target "$other" --rig-dir "$rig" \
      --tracking "$tracking" --strategy upgrade --adopt-legacy-rig-dir
    [ "$status" -ne 0 ]
    [ ! -e "$other/.rigpath" ]
  done
}

@test "legacy adoption rejects a forged pointer and symlinked backup boundary before writes" {
  local app="$BATS_TEST_TMPDIR/app" rig="$HOME/.rig/projects/app" outside="$BATS_TEST_TMPDIR/outside"
  make_repo "$app"
  mkdir -p "$rig/memory" "$outside"
  printf 'version\n' > "$rig/VERSION"
  printf 'brain\n' > "$app/CLAUDE.md"
  printf 'wrong path\n' > "$app/.rigpath"
  printf '%s  CLAUDE.md\n%s  .rig/VERSION\n' \
    "$(shasum -a 256 "$app/CLAUDE.md" | awk '{print $1}')" \
    "$(shasum -a 256 "$rig/VERSION" | awk '{print $1}')" > "$rig/memory/.rig-manifest"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" \
    --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -eq 2 ]
  [[ "$output" == *'requires --project-only, --target, --rig-dir'* ]]
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *'Legacy Rig adoption refused'* ]]
  [ ! -e "$rig/install-targets.json" ]
  printf '%s\n' "$rig" > "$app/.rigpath"
  ln -s "$outside" "$rig/preflight-snapshots"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *'Legacy Rig adoption refused'* ]]
  [ ! -e "$rig/install-targets.json" ]
  [ -z "$(ls -A "$outside")" ]
  rm "$rig/preflight-snapshots"
  printf 'changed outside manifest\n' > "$app/CLAUDE.md"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *'Legacy Rig adoption refused'* ]]
  [ ! -e "$rig/install-targets.json" ]
  printf 'brain\n' > "$app/CLAUDE.md"
  mv "$rig" "${rig}-real"
  ln -s "${rig}-real" "$rig"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *'Legacy Rig adoption refused'* ]]
  [ ! -e "$rig/install-targets.json" ]
  rm "$rig"
  mv "${rig}-real" "$rig"
  mv "$HOME/.rig/projects" "$HOME/.rig/projects-real"
  ln -s "$HOME/.rig/projects-real" "$HOME/.rig/projects"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *'Legacy Rig adoption refused'* ]]
  [ ! -e "$rig/install-targets.json" ]
}

@test "failed legacy upgrade removes only its provisional owner record" {
  local app="$BATS_TEST_TMPDIR/app" rig="$HOME/.rig/projects/app" wrappers="$BATS_TEST_TMPDIR/wrappers" marker="$BATS_TEST_TMPDIR/copy-failed"
  make_repo "$app"
  mkdir -p "$rig/memory"
  printf '1.20.0\n' > "$rig/VERSION"
  printf 'brain\n' > "$app/CLAUDE.md"
  printf '%s\n' "$rig" > "$app/.rigpath"
  printf '%s  CLAUDE.md\n%s  .rig/VERSION\n' \
    "$(shasum -a 256 "$app/CLAUDE.md" | awk '{print $1}')" \
    "$(shasum -a 256 "$rig/VERSION" | awk '{print $1}')" > "$rig/memory/.rig-manifest"
  mkdir -p "$wrappers"
  cat > "$wrappers/cp" <<'SH'
#!/bin/bash
destination=''
for argument in "$@"; do destination="$argument"; done
if [[ -f "$RIG_TEST_OWNER_FILE" && "$destination" == "$RIG_TEST_PROJECT/"* ]]; then
  : > "$RIG_TEST_FAIL_MARKER"
  exit 87
fi
exec /bin/cp "$@"
SH
  chmod +x "$wrappers/cp"
  run env PATH="$wrappers:$PATH" RIG_TEST_OWNER_FILE="$rig/install-targets.json" \
    RIG_TEST_PROJECT="$app" RIG_TEST_FAIL_MARKER="$marker" \
    bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
      --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -ne 0 ]
  [ -f "$marker" ]
  [[ "$output" == *'Adopted legacy Rig directory for this project'* ]]
  [[ "$output" == *'Removed provisional legacy Rig owner record after failed upgrade'* ]]
  [ ! -e "$rig/install-targets.json" ]
}

@test "losing an atomic legacy owner race cannot journal deletion of the winner" {
  local app="$BATS_TEST_TMPDIR/app" rig="$HOME/.rig/projects/app" wrappers="$BATS_TEST_TMPDIR/wrappers" before
  make_repo "$app"
  mkdir -p "$rig/memory" "$wrappers"
  printf '1.20.0\n' > "$rig/VERSION"
  printf 'brain\n' > "$app/CLAUDE.md"
  printf '%s\n' "$rig" > "$app/.rigpath"
  printf '%s  CLAUDE.md\n%s  .rig/VERSION\n' \
    "$(shasum -a 256 "$app/CLAUDE.md" | awk '{print $1}')" \
    "$(shasum -a 256 "$rig/VERSION" | awk '{print $1}')" > "$rig/memory/.rig-manifest"
  cat > "$wrappers/ln" <<'SH'
#!/bin/bash
if [[ "$2" == "$RIG_TEST_OWNER_FILE" ]]; then
  /bin/cp "$1" "$2"
  exit 1
fi
exec /bin/ln "$@"
SH
  chmod +x "$wrappers/ln"
  run env PATH="$wrappers:$PATH" RIG_TEST_OWNER_FILE="$rig/install-targets.json" \
    bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
      --tracking external --strategy upgrade --adopt-legacy-rig-dir
  [ "$status" -ne 0 ]
  [[ "$output" == *'lost the owner-record race'* ]]
  [ -f "$rig/install-targets.json" ]
  before="$(python3 -c 'import os,sys; p=sys.argv[1]; s=os.stat(p); print(s.st_dev,s.st_ino)' "$rig/install-targets.json")"
  run bash "$REPO_ROOT/install.sh" --project-only --target "$app" --rig-dir "$rig" \
    --tracking external --strategy upgrade --recover
  [ "$status" -eq 0 ]
  [ "$before" = "$(python3 -c 'import os,sys; p=sys.argv[1]; s=os.stat(p); print(s.st_dev,s.st_ino)' "$rig/install-targets.json")" ]
}
