setup_suite() {
  RIG_TEST_RUNTIME_BIN="$(mktemp -d)"
  export RIG_TEST_RUNTIME_BIN
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RIG_TEST_RUNTIME_BIN/claude"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$RIG_TEST_RUNTIME_BIN/codex"
  chmod +x "$RIG_TEST_RUNTIME_BIN/claude" "$RIG_TEST_RUNTIME_BIN/codex"
  export PATH="$RIG_TEST_RUNTIME_BIN:$PATH"
}

teardown_suite() {
  rm -rf "$RIG_TEST_RUNTIME_BIN"
}
