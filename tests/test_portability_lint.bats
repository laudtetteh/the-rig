#!/usr/bin/env bats

setup() {
  export CASE_DIR="$BATS_TEST_TMPDIR/case"
  mkdir -p "$CASE_DIR/docs"
  git -C "$CASE_DIR" init -q
  export LINT="$BATS_TEST_DIRNAME/lint-portability.py"
}

@test "portability lint permits the approved README pilot credit" {
  printf 'It was subsequently piloted on [%s%s.org](https://%sculture.org), a shared-repo platform.\n' '4' 'Culture' '4' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" add README.md
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 0 ]
}

@test "portability lint rejects a second README pilot mention" {
  printf 'The private pilot was %s%s.\n' '4' 'Culture' > "$CASE_DIR/README.md"
  git -C "$CASE_DIR" add README.md
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *pilot_name* ]]
}

@test "portability lint rejects private names and home paths in tracked docs" {
  printf 'Name: %s%s\nPath: /Users/%s/code\n' beacon avenue actual-person > "$CASE_DIR/docs/example.md"
  git -C "$CASE_DIR" add docs/example.md
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 1 ]
  [[ "$output" == *private_identifier* && "$output" == *personal_home* ]]
}

@test "portability lint ignores untracked local notes" {
  printf 'Name: %s%s\n' beacon avenue > "$CASE_DIR/docs/local.md"
  run python3 "$LINT" --root "$CASE_DIR"
  [ "$status" -eq 0 ]
}
