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
    table = docs.split("### Verifying an upgrade: `bin/rig doctor` gates", 1)[1].split("\n\nBoth new gates", 1)[0]
except IndexError:
    raise SystemExit("doctor gate docs table not found")
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
