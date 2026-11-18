#!/usr/bin/env bash
# Make macOS system bash 3.2 (/bin/bash) the first `bash` on PATH for every
# later GitHub Actions step (issue #669).
#
# GitHub's macOS runner images ship Homebrew bash 5.x ahead of /bin/bash on
# PATH. bats, every Bats test file, install.sh and the Rig hooks all start via
# `#!/usr/bin/env bash` or a bare `bash ...` call, so without this shim the
# macOS job would silently exercise bash 5 and never catch bash 3.2 breakage.
# A shim directory holding only `bash -> /bin/bash` is prepended through
# GITHUB_PATH so the rest of the PATH (python3, jq, git) is left untouched.
#
# The script also asserts the userland really is BSD (no GNU sed or stat
# shadowing the system tools), because the BSD branches of sed_inplace and
# manifest_artifact_mode are part of what this job exists to exercise.
set -euo pipefail

: "${RUNNER_TEMP:?RUNNER_TEMP is required}"
: "${GITHUB_PATH:?GITHUB_PATH is required}"

system_bash=/bin/bash
# shellcheck disable=SC2016 # expanded by the child /bin/bash, not here
system_version="$("$system_bash" -c 'printf "%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}"')"
if [[ "$system_version" != "3.2" ]]; then
  printf 'Expected %s to be bash 3.2, found %s\n' "$system_bash" "$system_version" >&2
  exit 1
fi

if sed --version >/dev/null 2>&1; then
  printf 'GNU sed is first on PATH (%s); the BSD sed path would go untested\n' "$(command -v sed)" >&2
  exit 1
fi
if stat -c '%a' / >/dev/null 2>&1; then
  printf 'GNU stat is first on PATH (%s); the BSD stat path would go untested\n' "$(command -v stat)" >&2
  exit 1
fi

shim_dir="$RUNNER_TEMP/system-bash-shim"
mkdir -p "$shim_dir"
ln -sf "$system_bash" "$shim_dir/bash"
printf '%s\n' "$shim_dir" >> "$GITHUB_PATH"

printf 'Shadowed bash candidates on PATH:\n'
type -a bash || true
printf 'Prepended %s (bash -> %s, version %s)\n' "$shim_dir" "$system_bash" "$system_version"
