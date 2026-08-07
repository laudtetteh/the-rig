#!/usr/bin/env bats
#
# tests/test_branch_drift_agent_guard.bats — issue #476
#
# The "Installer branch drift check" runs unconditionally near the top of
# install.sh, gated only on _EARLY_PREFLIGHT -- before AGENT_MODE is ever
# assigned (that happens later, inside the --strategy case statement, once
# TARGET/COLLISION_STRATEGY resolution machinery is set up). Every warn()
# call inside the block evaluates AGENT_MODE while it's still unset
# regardless of --strategy, so warn()'s own self-gating never actually
# suppressed anything here, and the "Options:" menu's raw echo lines were
# unguarded too. Worse: if the installer's own checkout is behind its
# remote AND stdin is a TTY, it fell into a blocking `read` -- an
# agent-plan/agent-upgrade invocation with a TTY attached (common for CI
# runners or interactive agent sessions) would hang indefinitely.
#
# Fixed by an early, standalone lookahead over $@ (mirroring the existing
# --preflight/--json scan already at the top of the script) that detects
# --strategy agent-plan/agent-upgrade before the drift check runs, and
# skips the entire block for those strategies regardless of stdin or the
# real AGENT_MODE variable's assignment order.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
INSTALLER="$REPO_ROOT/install.sh"

setup() {
  TEMP_DIR="$(mktemp -d)"
  TEST_PROJECT="$TEMP_DIR/project"
  mkdir -p "$TEST_PROJECT"
  git -C "$TEST_PROJECT" init -q
  git -C "$TEST_PROJECT" config user.email test@test.com
  git -C "$TEST_PROJECT" config user.name Test

  # agent-plan/agent-upgrade classify against an existing installation --
  # establish a real baseline first, same as every other agent-contract
  # test in this suite (test_upgrade_agent_contract.bats). Deliberately run
  # without a drift-dir override so the baseline install itself isn't
  # affected by the mock-drift setup below.
  bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade >/dev/null 2>&1

  # A mock installer checkout that's genuinely behind its remote tracking
  # branch, per the existing _RIG_DRIFT_DIR test-override convention
  # documented in install.sh's own comment above the drift check.
  REMOTE="$TEMP_DIR/remote.git"
  DRIFT_REPO="$TEMP_DIR/drift-repo"
  AHEAD_REPO="$TEMP_DIR/ahead-repo"
  git init -q --bare "$REMOTE"

  git clone -q "$REMOTE" "$AHEAD_REPO"
  git -C "$AHEAD_REPO" config user.email test@test.com
  git -C "$AHEAD_REPO" config user.name Test
  git -C "$AHEAD_REPO" checkout -q -b main
  git -C "$AHEAD_REPO" commit -q --allow-empty -m "c1"
  git -C "$AHEAD_REPO" push -q -u origin main

  git clone -q "$REMOTE" "$DRIFT_REPO"
  git -C "$DRIFT_REPO" config user.email test@test.com
  git -C "$DRIFT_REPO" config user.name Test

  # Now push a second commit that DRIFT_REPO hasn't fetched yet -- its own
  # `git fetch` inside the drift check will discover it and see itself as
  # behind by exactly 1 commit.
  git -C "$AHEAD_REPO" commit -q --allow-empty -m "c2"
  git -C "$AHEAD_REPO" push -q origin main
}

teardown() { rm -rf "$TEMP_DIR"; }

@test "agent-plan against a behind-remote installer checkout emits exactly one JSON document, with zero drift-check narration leaked" {
  run env _RIG_DRIFT_DIR="$DRIFT_REPO" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy agent-plan
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"commit(s) behind"* ]]
  [[ "$output" != *"Options:"* ]]
  [[ "$output" != *"Update now and re-run"* ]]
  [[ "$output" == \{* ]]
}

@test "agent-upgrade against a behind-remote installer checkout emits exactly one JSON document, with zero drift-check narration leaked" {
  run env _RIG_DRIFT_DIR="$DRIFT_REPO" \
    bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy agent-upgrade
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]

  local nonblank_lines
  nonblank_lines="$(printf '%s\n' "$output" | /usr/bin/grep -c .)"
  [ "$nonblank_lines" -eq 1 ]
  [[ "$output" != *"commit(s) behind"* ]]
  [[ "$output" != *"Options:"* ]]
  [[ "$output" == \{* ]]
}

@test "agent-plan against a behind-remote installer checkout never blocks on stdin, even when stdin is a real TTY" {
  # A plain `run` in bats never attaches a real TTY to stdin, so it can
  # only prove the non-interactive leak above, not the far more severe
  # blocking-read hang -- that path is only reachable when `[ -t 0 ]` is
  # true. Attach a real pseudo-terminal via Python's pty module (portable
  # across macOS/Linux, unlike the `script` command's divergent flag
  # syntax between BSD and util-linux) purely to make stdin satisfy
  # `[ -t 0 ]`, and assert the process still exits well within a bounded
  # timeout instead of hanging forever. stdout/stderr go through a regular
  # pipe (not the pty) and MUST be drained concurrently while the process
  # runs, not after it exits -- install.sh's real JSON output routinely
  # exceeds the OS pipe buffer size, and a first version of this test
  # that only read after the wait loop deadlocked on that full pipe buffer
  # for every strategy, including plain "merge", which was a bug in the
  # test harness itself, not a real product hang (confirmed by comparing
  # against `expect`, which drains as it goes and never showed the false
  # hang for anything other than the two real, since-fixed bugs).
  run python3 - "$INSTALLER" "$TEST_PROJECT" "$DRIFT_REPO" <<'PY'
import os, pty, select, subprocess, sys, time

installer, target, drift_repo = sys.argv[1:4]
env = dict(os.environ)
env["_RIG_DRIFT_DIR"] = drift_repo

master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(
    ["bash", installer, "--project-only", "--target", target,
     "--project-name", "Test", "--tracking", "repo", "--strategy", "agent-plan"],
    stdin=slave_fd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=env,
)
os.close(slave_fd)

stdout_fd = proc.stdout.fileno()
out_chunks = []
deadline = time.time() + 25
while True:
    if proc.poll() is not None:
        break
    if time.time() > deadline:
        proc.kill()
        proc.wait()
        os.close(master_fd)
        sys.stderr.write("HUNG: process did not exit within timeout\n")
        sys.exit(1)
    ready, _, _ = select.select([stdout_fd], [], [], 0.1)
    if stdout_fd in ready:
        chunk = os.read(stdout_fd, 65536)
        if chunk:
            out_chunks.append(chunk)

while True:
    chunk = os.read(stdout_fd, 65536)
    if not chunk:
        break
    out_chunks.append(chunk)
os.close(master_fd)

sys.stdout.buffer.write(b"".join(out_chunks))
sys.exit(proc.returncode)
PY

  [[ "$output" != *"HUNG"* ]]
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}

@test "agent-plan with --target, --project-name, and --tracking all omitted never blocks on stdin, even when stdin is a real TTY" {
  # Independent-review finding: the fix above only closed the drift-check
  # and base-branch prompts. Three more `-t 0`-guarded (or entirely
  # unguarded) interactive prompts exist further down the project-layer
  # flow -- the --target path prompt (install.sh, had NO `-t 0` guard at
  # all), the --project-name prompt, and the .rig/ tracking-mode menu
  # (also had no `-t 0` guard). None checked AGENT_MODE, so omitting these
  # three flags under a real TTY reproduced the identical hang this issue
  # is about, just at a different line. Fixed by adding `-t 0 && -z
  # "$AGENT_MODE"` guards (matching the base-branch fix) to the first two,
  # and an explicit `elif -n "$AGENT_MODE"` branch defaulting to the
  # menu's own documented default (stealth) for the third, since that
  # branch had no `-t 0` structure to extend.
  run bash "$INSTALLER" --project-only --target "$TEST_PROJECT" \
    --project-name Test --tracking repo --strategy upgrade
  [ "$status" -eq 0 ]

  run python3 - "$INSTALLER" "$TEST_PROJECT" <<'PY'
import os, pty, select, subprocess, sys, time

installer, target = sys.argv[1:3]

master_fd, slave_fd = pty.openpty()
proc = subprocess.Popen(
    ["bash", installer, "--project-only", "--strategy", "agent-plan"],
    stdin=slave_fd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=target,
)
os.close(slave_fd)

stdout_fd = proc.stdout.fileno()
out_chunks = []
deadline = time.time() + 25
while True:
    if proc.poll() is not None:
        break
    if time.time() > deadline:
        proc.kill()
        proc.wait()
        os.close(master_fd)
        sys.stderr.write("HUNG: process did not exit within timeout\n")
        sys.exit(1)
    ready, _, _ = select.select([stdout_fd], [], [], 0.1)
    if stdout_fd in ready:
        chunk = os.read(stdout_fd, 65536)
        if chunk:
            out_chunks.append(chunk)

while True:
    chunk = os.read(stdout_fd, 65536)
    if not chunk:
        break
    out_chunks.append(chunk)
os.close(master_fd)

sys.stdout.buffer.write(b"".join(out_chunks))
sys.exit(proc.returncode)
PY

  [[ "$output" != *"HUNG"* ]]
  [ "$status" -eq 0 ] || [ "$status" -eq 3 ]
}
