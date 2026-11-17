#!/usr/bin/env bats
# Final merge-boundary PR metadata review (#614): `rig pr review-metadata`
# compares title, body, labels and closing links with the final commits from
# caller-fetched JSON, never contacts GitHub, and proposes REST edits that run
# only after explicit approval.

setup() {
  CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory" "$BATS_TEST_TMPDIR/fakebin"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  # A gh on PATH that records any call proves the review never contacts GitHub.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/fakebin/gh"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/gh"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
  PR_JSON="$BATS_TEST_TMPDIR/pr.json"
  CLOSING_JSON="$BATS_TEST_TMPDIR/closing.json"
  PAYLOAD="$BATS_TEST_TMPDIR/payload.json"
}

# write_pr TITLE BODY LABELS_CSV COMMIT_HEADLINE[|COMMIT_BODY]... — gh pr view JSON.
# In a commit body, a literal backslash-n becomes a newline.
write_pr() {
  local title="$1" body="$2" labels="$3"
  shift 3
  python3 - "$PR_JSON" "$title" "$body" "$labels" "$@" <<'PY'
import json, sys
path, title, body, labels, *commits = sys.argv[1:]
data = {
    "number": 42, "state": "OPEN", "isDraft": False, "headRefOid": "abc1234def5678",
    "title": title, "body": body,
    "labels": [{"name": n} for n in labels.split(",") if n],
    "commits": [],
}
for spec in commits:
    headline, _, commit_body = spec.partition("|")
    data["commits"].append({"messageHeadline": headline, "messageBody": commit_body.replace("\\n", "\n")})
json.dump(data, open(path, "w"))
PY
}

# write_closing N... — closingIssuesReferences GraphQL response.
write_closing() {
  python3 - "$CLOSING_JSON" "$@" <<'PY'
import json, sys
nodes = [{"number": int(n)} for n in sys.argv[2:]]
json.dump({"data": {"repository": {"pullRequest": {"closingIssuesReferences": {"nodes": nodes}}}}}, open(sys.argv[1], "w"))
PY
}

review() {
  run bash -c 'cd "$1" && shift && bin/rig pr review-metadata "$@"' _ "$CASE_DIR" "$@"
}

@test "pr review-metadata: consistent metadata is clean and names the reviewed head" {
  write_pr 'fix(hooks): warn on branch change [#12]' $'## Summary\nWarns.\n\n## Closes\n\nCloses #12\n' 'type: fix' 'fix(hooks): warn on branch change [#12]'
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Result: CLEAN"* ]] || return 1
  [[ "$output" == *"gh pr merge 42 --match-head-commit abc1234def5678"* ]] || return 1
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ]
}

@test "pr review-metadata: a title type absent from final commits proposes a REST title edit" {
  write_pr 'docs(readme): early plan [#12]' $'Body\n\nCloses #12\n' 'type: docs' 'fix(hooks): warn on branch change [#12]'
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON" --payload-out "$PAYLOAD" --json
  [ "$status" -eq 3 ]
  JSON_OUTPUT="$output" python3 -c '
import json, os
d = json.loads(os.environ["JSON_OUTPUT"])
assert [f["code"] for f in d["findings"]] == ["stale_title", "missing_label"], d["findings"]
assert d["proposal"]["title"] == "fix(hooks): warn on branch change [#12]"
assert d["proposal"]["add_labels"] == ["type: fix"]
assert any(c.startswith("gh api repos/{owner}/{repo}/pulls/42 --method PATCH --input ") for c in d["commands"]), d["commands"]
assert any("issues/42/labels --method POST" in c for c in d["commands"]), d["commands"]
assert not any("gh pr edit" in c for c in d["commands"]), d["commands"]
'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d == {"title": "fix(hooks): warn on branch change [#12]"}, d' "$PAYLOAD"
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ]
}

@test "pr review-metadata: an issue named by a final commit but not closed gets a Closes line in the payload" {
  write_pr 'fix(hooks): warn on branch change [#12]' $'## Summary\nWarns.\n\n## Closes\n\nCloses #12\n\n## Notes\nNone.\n' 'type: fix' \
    'fix(hooks): warn on branch change [#12]' 'fix(hooks): quote the worktree path [#13]'
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON" --payload-out "$PAYLOAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *"[missing_closing_link] issue #13"* ]] || return 1
  python3 -c '
import json, sys
body = json.load(open(sys.argv[1]))["body"]
closes = body.split("## Closes", 1)[1].split("## Notes", 1)[0]
assert "Closes #13" in closes and "Closes #12" in closes, body
assert "Closes #12, #13" not in body
' "$PAYLOAD"
}

@test "pr review-metadata: a Refs line in the body marks a partially delivered issue as intentionally open" {
  write_pr 'fix(doctor): honest states [#12]' $'## Closes\n\nCloses #12\n\nRefs #13 (repair remains open)\n' 'type: fix' \
    'fix(doctor): honest states [#12]' 'fix(doctor): parity diagnosis [#13]'
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" != *"missing_closing_link"* ]] || return 1
}

@test "pr review-metadata: closing an issue marked --not-closing is reported" {
  write_pr 'fix(doctor): honest states [#12]' $'Closes #12\nCloses #13\n' 'type: fix' \
    'fix(doctor): honest states [#12]' 'fix(doctor): parity diagnosis [#13]'
  write_closing 12 13
  review --pr "$PR_JSON" --closing "$CLOSING_JSON" --not-closing 13
  [ "$status" -eq 3 ]
  [[ "$output" == *"[unexpected_closing_link] PR closes #13, which is marked as left open"* ]] || return 1
}

@test "pr review-metadata: a closing link that no commit or scope names is reported" {
  write_pr 'fix(hooks): warn [#12]' $'Closes #12\nCloses #99\n' 'type: fix' 'fix(hooks): warn [#12]'
  write_closing 12 99
  review --pr "$PR_JSON" --closing "$CLOSING_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"PR closes #99, which no final commit or task scope names"* ]] || return 1
}

@test "pr review-metadata: GitHub-truncated commit headlines keep their issue block" {
  write_pr 'fix(post-merge): verify exact merges [#606 #607]' $'Closes #606\nCloses #607\n' 'type: fix' \
    'fix(post-merge): verify exact merges and preserve pending reminders […|…#606]\n\nAlso fixes #607.'
  write_closing 606 607
  review --pr "$PR_JSON" --closing "$CLOSING_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preserve pending reminders [#606]"* ]] || return 1
}

@test "pr review-metadata: required area labels, drafts and placeholders are reported" {
  write_pr 'fix(hooks): warn [#12]' $'Closes #N\nCloses #12\n' 'type: fix' 'fix(hooks): warn [#12]'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["isDraft"]=True; json.dump(d,open(sys.argv[1],"w"))' "$PR_JSON"
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON" --require-label 'area: hooks'
  [ "$status" -eq 3 ]
  [[ "$output" == *"[draft]"* && "$output" == *"[body_placeholder]"* && "$output" == *"label 'area: hooks' is not applied"* ]] || return 1
  [[ "$output" == *"labels[]=area: hooks"* ]] || return 1
}

@test "pr review-metadata: without GitHub references it falls back to body keywords and says so" {
  write_pr 'fix(hooks): warn [#12]' $'Fixes #12\n' 'type: fix' 'fix(hooks): warn [#12]'
  review --pr "$PR_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Closing links: PR body closing keywords (GitHub references not supplied)"* ]] || return 1
}

@test "pr review-metadata: a non-GitHub tracker skips closing-link checks but still reviews the title" {
  write_pr 'docs: plan' $'Linear ENG-12\n' '' 'fix(hooks): warn [#12]'
  review --pr "$PR_JSON" --issue-tracking linear
  [ "$status" -eq 3 ]
  [[ "$output" == *"Closing links: not checked: issue-tracking is 'linear'"* ]] || return 1
  [[ "$output" == *"[stale_title]"* && "$output" != *"missing_closing_link"* ]] || return 1
}

@test "pr review-metadata: unusable input exits 64 without writing a payload" {
  printf 'not json' > "$PR_JSON"
  review --pr "$PR_JSON" --payload-out "$PAYLOAD"
  [ "$status" -eq 64 ]
  [ ! -e "$PAYLOAD" ]
  review --pr "$BATS_TEST_TMPDIR/missing.json"
  [ "$status" -eq 64 ]
  review --bogus
  [ "$status" -eq 64 ]
}

@test "pr review-metadata: help prints usage without reading input" {
  review --help
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == "Usage: rig pr review-metadata"* ]] || return 1
}

@test "ship command runs the read-only metadata review before merging the reviewed head" {
  local ship="$BATS_TEST_DIRNAME/../templates/project/.claude/commands/ship.md"
  python3 - "$ship" <<'PY'
import sys
text = open(sys.argv[1]).read()
review = text.index("## Step 9.5 — Final merge-boundary metadata review")
merge = text.index("## Step 10 — Merge verification and branch cleanup")
assert review < merge
section = text[review:merge]
for needle in ('bin/rig" pr review-metadata', "--match-head-commit", "--method PATCH",
               "closingIssuesReferences", "Do not run it on every"):
    assert needle in section, needle
assert "gh pr edit" not in section.split("Act on the exit code:")[1].replace("`gh pr edit` can fail", "")
step9 = text[text.index("## Step 9"):review]
assert "gh api repos/{owner}/{repo}/pulls/[N] --method PATCH" in step9
PY
}
