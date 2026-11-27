#!/usr/bin/env bats

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"

@test "lessons-learned stated count matches numbered incidents" {
  python3 - "$REPO_ROOT/docs/lessons-learned.md" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text()
count = len(re.findall(r"(?m)^## \d+\. ", text))
words = {
    20: "Twenty",
    21: "Twenty-one",
    22: "Twenty-two",
    23: "Twenty-three",
    24: "Twenty-four",
    25: "Twenty-five",
}
expected = words.get(count, str(count))
first_line = text.splitlines()[2]
if expected not in first_line:
    raise SystemExit(f"expected {expected!r} in count line, got: {first_line!r}")
PY
}

@test "customizing doctor gate table documents current bin/rig doctor check IDs" {
  python3 - "$REPO_ROOT/templates/project/bin/rig" "$REPO_ROOT/docs/customizing.md" <<'PY'
import pathlib
import re
import sys

rig = pathlib.Path(sys.argv[1]).read_text()
docs = pathlib.Path(sys.argv[2]).read_text()

try:
    body = rig.split("doctor() {", 1)[1].split("\nsession_resolve()", 1)[0]
except IndexError:
    raise SystemExit("doctor() function not found")

actual = set(re.findall(r'check\("([^"]+)"', body))
try:
    after_heading = docs.split("### Verifying an upgrade: `bin/rig doctor` gates", 1)[1]
except IndexError:
    raise SystemExit("doctor gate docs table not found")
next_heading = re.search(r"\n### ", after_heading)
table = after_heading[: next_heading.start()] if next_heading else after_heading
documented = set(re.findall(r"(?m)^\| `([^`]+)` \|", table))

missing = sorted(actual - documented)
extra = sorted(documented - actual)
if missing or extra:
    raise SystemExit(
        "doctor gate drift:"
        + (f" missing={missing}" if missing else "")
        + (f" extra={extra}" if extra else "")
    )
PY
}

@test "upgrade docs distinguish agent convergence from raw installer upgrade" {
  grep -Fq 'semantic or intelligent convergence' "$REPO_ROOT/docs/customizing.md"
  grep -Fq 'install.sh --strategy agent-upgrade' "$REPO_ROOT/docs/customizing.md"
  grep -Fq 'Do not use raw `install.sh --strategy' "$REPO_ROOT/docs/customizing.md"
  grep -Fq 'Use the agent upgrade path when you want semantic convergence' "$REPO_ROOT/README.md"
}

@test "post-merge descriptions require exact SHA verification and conditional base update" {
  python3 - "$REPO_ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for relative in (
    "README.md",
    "docs/how-it-works.md",
    "templates/project/.claude/commands/rig-help.md",
):
    content = (root / relative).read_text().lower()
    for stale in ("pull main", "pulls main", "pull base branch", "step 1: pull latest main"):
        if stale in content:
            raise SystemExit(f"stale unconditional post-merge pull in {relative}: {stale}")
    if "exact merge sha" not in content:
        raise SystemExit(f"missing exact merge verification in {relative}")
PY
}

@test "provider brain spike records Claude and Codex load order" {
  local doc="$REPO_ROOT/docs/provider-neutral-project-brain.md"
  grep -Fq '## Provider Load Order Findings' "$doc"
  grep -Fq '~/.claude/CLAUDE.md' "$doc"
  grep -Fq '~/.codex/AGENTS.override.md' "$doc"
  grep -Fq 'project config cannot override' "$doc"
  grep -Fq 'For stealth/external installs, docs should say `$RIG_DIR`' "$doc"
}

@test "troubleshooting quotes the real commit-msg branch guard messages" {
  python3 - "$REPO_ROOT/templates/project/.husky/commit-msg" "$REPO_ROOT/docs/troubleshooting.md" \
    "$REPO_ROOT/templates/project/.claude/hooks/pre-tool.sh" <<'PY'
import pathlib
import re
import sys

hook = pathlib.Path(sys.argv[1]).read_text()
docs = pathlib.Path(sys.argv[2]).read_text()

messages = re.findall(r'echo "(ERROR: [^"]*\$BRANCH[^"]*)"', hook)
if len(messages) != 4:
    raise SystemExit(f"expected four branch guard messages in commit-msg, found {messages!r}")
for message in messages:
    if "$BRANCH_PREFIX" in message:
        rendered = message.replace("$BRANCH_PREFIX", "feature//")
    elif "does not use a configured branch prefix" in message:
        rendered = message.replace("$BRANCH", "wip/no-prefix")
    else:
        rendered = message.replace("$BRANCH", "main")
    if rendered not in docs:
        raise SystemExit(f"troubleshooting does not quote guard message: {rendered!r}")
pretool = pathlib.Path(sys.argv[3]).read_text()
prefix = re.search(r'fail_closed\(\) \{\n  echo "([^"$]*)\$1"', pretool)
if not prefix:
    raise SystemExit("fail_closed prefix not found in pre-tool.sh")
if f"prefixed with `{prefix.group(1).strip()}`" not in docs:
    raise SystemExit(f"troubleshooting does not name the PreToolUse prefix {prefix.group(1)!r}")
pretool_messages = re.findall(r'fail_closed "([^"]*\$CURRENT_BRANCH[^"]*)"', pretool)
if len(pretool_messages) != 2:
    raise SystemExit(f"expected two PreToolUse branch guard messages, found {pretool_messages!r}")
core_hook_messages = [m for m in messages if "Commit to " in m or "Direct-to-" in m]
hook_rendered = sorted(m.replace("ERROR: ", "", 1).replace("$BRANCH", "main") for m in core_hook_messages)
pretool_rendered = sorted(m.replace("$CURRENT_BRANCH", "main") for m in pretool_messages)
if hook_rendered != pretool_rendered:
    raise SystemExit(f"PreToolUse wording differs from commit-msg: {pretool_rendered!r} vs {hook_rendered!r}")
if "Committing directly to 'main' is not allowed." in docs:
    raise SystemExit("troubleshooting still quotes a guard message the hook never prints")
if "direct commits are intentional for this project" in docs:
    raise SystemExit("troubleshooting still claims direct-push allows every direct commit")
if "only for `chore` and `docs`" not in docs:
    raise SystemExit("troubleshooting does not state the chore/docs direct-push limit")
PY
}

@test "troubleshooting numbered sections are unique and sequential" {
  python3 - "$REPO_ROOT/docs/troubleshooting.md" <<'PY'
import pathlib
import re
import sys

numbers = [int(n) for n in re.findall(r"(?m)^## (\d+)\. ", pathlib.Path(sys.argv[1]).read_text())]
if numbers != list(range(len(numbers))):
    raise SystemExit(f"section numbers are not 0..N in order: {numbers}")
PY
}

@test "troubleshooting executable-bit fix covers every shipped Claude hook script" {
  python3 - "$REPO_ROOT/templates/project/.claude/hooks" "$REPO_ROOT/docs/troubleshooting.md" <<'PY'
import pathlib
import sys

hooks = sorted(p.name for p in pathlib.Path(sys.argv[1]).glob("*.sh"))
docs = pathlib.Path(sys.argv[2]).read_text()
try:
    section = docs.split("### Hooks not executable", 1)[1].split("\n### ", 1)[0]
except IndexError:
    raise SystemExit("Hooks not executable section not found")
if "chmod +x .claude/hooks/*.sh" not in section:
    raise SystemExit("executable-bit fix does not cover all .claude/hooks/*.sh scripts")
missing = [name for name in hooks if f"`{name}`" not in section]
if missing:
    raise SystemExit(f"executable-bit section does not name shipped hooks: {missing}")
for git_hook in ("pre-commit", "commit-msg", "post-commit", "post-merge"):
    if f".git/hooks/{git_hook}" not in section or f".husky/{git_hook}" not in section:
        raise SystemExit(f"executable-bit fix misses {git_hook} for husky or stealth installs")
PY
}

@test "public doc shell examples resolve Rig state paths instead of bare .rig/memory" {
  python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
bad = []
for rel in ("README.md", "docs/troubleshooting.md", "docs/customizing.md", "docs/agent-install.md"):
    text = (root / rel).read_text()
    for block in re.findall(r"```(?:bash|sh)\n(.*?)```", text, re.S):
        for line in block.splitlines():
            if re.search(r"(?<![\w$/{.-])\.rig/(memory|install-targets)", line):
                bad.append(f"{rel}: {line.strip()}")
readme = (root / "README.md").read_text()
for stale in ("`.rig/memory/tips/`", "`.rig/memory/.rig-tips-disabled`"):
    if stale in readme:
        bad.append(f"README.md: {stale}")
if bad:
    raise SystemExit("bare .rig state paths fail in stealth installs:\n" + "\n".join(bad))
PY
}

@test "install docs do not reference the never-created PROFILE.md" {
  run grep -n "your-ai-contexts" "$REPO_ROOT/README.md" "$REPO_ROOT/docs/agent-install.md" \
    "$REPO_ROOT/docs/troubleshooting.md" "$REPO_ROOT/docs/customizing.md"
  [ "$status" -eq 1 ]
  run grep -rn "PROFILE_PATH" "$REPO_ROOT/install.sh" "$REPO_ROOT/templates/global"
  [ "$status" -eq 1 ]
  grep -q "^\*\*Correction (2026-11-18):\*\* This decision no longer describes shipped behaviour" \
    "$REPO_ROOT/docs/decisions.md"
}

@test "agent-install new-machine setup does not hardcode repo tracking or rely on a cloned .rigpath" {
  python3 - "$REPO_ROOT/docs/agent-install.md" <<'PY'
import pathlib
import sys

docs = pathlib.Path(sys.argv[1]).read_text()
try:
    section = docs.split("### 7 — New machine setup", 1)[1].split("\n### ", 1)[0]
except IndexError:
    raise SystemExit("new machine setup section not found")
if "--tracking repo" in section:
    raise SystemExit("new machine example hardcodes --tracking repo")
if "read it to know where" in section:
    raise SystemExit("new machine setup tells users to read .rigpath from a fresh clone")
if ".git/info/exclude" not in section:
    raise SystemExit("new machine setup does not explain why .rigpath is absent")
PY
}

@test "agent-install post-install checklist checks stealth git hooks and avoids repo-only Bats" {
  python3 - "$REPO_ROOT/docs/agent-install.md" <<'PY'
import pathlib
import sys

docs = pathlib.Path(sys.argv[1]).read_text()
section = docs.split("## Post-install checklist", 1)[1]
if "bats tests/" in section:
    raise SystemExit("post-install checklist tells end users to run repo-only Bats")
for hook in ("commit-msg", "filter-commit-message-inplace.sh"):
    if f".git/hooks/{hook}" not in section:
        raise SystemExit(f"post-install checklist does not check stealth .git/hooks/{hook}")
PY
}

@test "README documents RIG_INSTALLER_SRC used by the upgrade commands" {
  grep -q 'RIG_INSTALLER_SRC' "$REPO_ROOT/templates/global/commands/rig-upgrade.md"
  grep -q 'export RIG_INSTALLER_SRC=/path/to/the-rig' "$REPO_ROOT/README.md"
  grep -q 'not by `install.sh` itself' "$REPO_ROOT/README.md"
  run grep -n 'RIG_INSTALLER_SRC' "$REPO_ROOT/install.sh"
  [ "$status" -eq 1 ]
}

@test "public memory inventories list every scaffolded memory document" {
  python3 - "$REPO_ROOT" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
names = {path.name for path in (root / "templates/project/.rig/memory").glob("*.md")}
readme = next(line for line in (root / "README.md").read_text().splitlines()
              if line.startswith("| Memory system |"))
brief = next(line for line in (root / "PROJECT_BRIEF.md").read_text().splitlines()
             if line.startswith("- **Memory system**:"))
for document, row in (("README.md", readme), ("PROJECT_BRIEF.md", brief)):
    missing = sorted(name for name in names if name not in row)
    if missing:
        raise SystemExit(f"{document} memory inventory omits: {', '.join(missing)}")
PY
}

@test "release verification lists every hosted CI job" {
  python3 - "$REPO_ROOT" <<'PY'
import pathlib
import re
import sys

root = pathlib.Path(sys.argv[1])
workflow = (root / ".github/workflows/ci.yml").read_text()
checks = (root / "docs/release-verification.md").read_text().split(
    "## Required hosted checks", 1)[1].split("\n## ", 1)[0]
job_names = re.findall(r"(?m)^    name:\s*(.+)$", workflow)
if not job_names:
    raise SystemExit("CI workflow has no named jobs")
for name in job_names:
    documented = name.split(" (", 1)[0] if "${{" in name else name
    if documented not in checks:
        raise SystemExit(f"release verification omits CI job: {name}")
PY
}
