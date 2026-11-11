#!/usr/bin/env bash
# Install the version previously supplied by Ubuntu 24.04 without depending on
# the runner's apt mirror. Verify the source commit before running its installer.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

source_dir="$RUNNER_TEMP/bats-core-v1.10.0"
prefix="$RUNNER_TEMP/bats-core-install"
expected_commit=f7defb94362f2053a3e73d13086a167448ea9133

git clone --quiet --depth 1 --branch v1.10.0 \
  https://github.com/bats-core/bats-core.git "$source_dir"
actual_commit=$(git -C "$source_dir" rev-parse HEAD)
if [[ "$actual_commit" != "$expected_commit" ]]; then
  printf 'Unexpected bats-core v1.10.0 commit: %s\n' "$actual_commit" >&2
  exit 1
fi

bash "$source_dir/install.sh" "$prefix"
printf '%s\n' "$prefix/bin" >> "$GITHUB_PATH"
"$prefix/bin/bats" --version
