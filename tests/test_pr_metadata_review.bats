#!/usr/bin/env bats
# Final merge-boundary PR metadata review (#614): `rig pr review-metadata`
# compares title, body, labels and closing links with the final commits from
# caller-fetched JSON, never contacts GitHub, and proposes REST edits that run
# only after explicit approval.

setup() {
  CASE_DIR="$BATS_TEST_TMPDIR/project"
  mkdir -p "$CASE_DIR/bin" "$CASE_DIR/.rig/memory" "$BATS_TEST_TMPDIR/fakebin"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig" "$CASE_DIR/bin/rig"
  cp "$BATS_TEST_DIRNAME/../templates/project/bin/rig-path.py" "$CASE_DIR/bin/rig-path.py"
  chmod +x "$CASE_DIR/bin/rig"
  git -C "$CASE_DIR" init -q
  # A gh on PATH that records any call proves the review never contacts GitHub.
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/gh-calls"\nexit 1\n' "$BATS_TEST_TMPDIR" > "$BATS_TEST_TMPDIR/fakebin/gh"
  chmod +x "$BATS_TEST_TMPDIR/fakebin/gh"
  export PATH="$BATS_TEST_TMPDIR/fakebin:$PATH"
  PR_JSON="$BATS_TEST_TMPDIR/pr.json"
  CLOSING_JSON="$BATS_TEST_TMPDIR/closing.json"
  FILES_LIST="$BATS_TEST_TMPDIR/files.txt"
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
    data["commits"].append({"oid": "abc1234def5678", "messageHeadline": headline,
                            "messageBody": commit_body.replace("\\n", "\n")})
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
assert [f["code"] for f in d["findings"]] == ["stale_title", "missing_label", "stale_label"], d["findings"]
assert d["proposal"]["title"] == "fix(hooks): warn on branch change [#12]"
assert d["proposal"]["add_labels"] == ["type: fix"]
assert d["proposal"]["remove_labels"] == ["type: docs"]
assert any(c.startswith("gh api repos/{owner}/{repo}/pulls/42 --method PATCH --input ") for c in d["commands"]), d["commands"]
assert any("issues/42/labels --method POST" in c for c in d["commands"]), d["commands"]
assert not any("gh pr edit" in c for c in d["commands"]), d["commands"]
'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d == {"title": "fix(hooks): warn on branch change [#12]"}, d' "$PAYLOAD"
  [ ! -e "$BATS_TEST_TMPDIR/gh-calls" ]
}

@test "pr review-metadata: reports files claimed in Changes but absent from final diff" {
  write_pr 'feat(demo): add feature [#12]' $'## Summary\nAdds a demo feature.\n\n## Changes\n- Updated `src/never-touched.py` to handle the new path.\n\n## Test plan\n- Ran `tests/test_demo.bats`\n\nCloses #12\n' 'type: feat' 'feat(demo): add feature [#12]'
  printf 'src/actual.py\n' > "$FILES_LIST"
  review --pr "$PR_JSON" --files "$FILES_LIST" --issue-tracking none
  [ "$status" -eq 3 ]
  [[ "$output" == *"[body_claim_not_in_diff]"*"src/never-touched.py"* ]] || return 1
  [[ "$output" != *"tests/test_demo.bats"* ]] || return 1
}

@test "pr review-metadata: accepts changed paths and scopes body checks to change sections" {
  write_pr 'feat(demo): add feature [#12]' $'## Summary\nAdds a demo feature.\n\n## Changes\n- Updated `docs/release-20261126.md` in commit `abc1234`.\n\n## Test plan\n- Ran `tests/test_demo.bats`\n\nCloses #12\n' 'type: feat' 'feat(demo): add feature [#12]'
  printf 'docs/release-20261126.md\n' > "$FILES_LIST"
  review --pr "$PR_JSON" --files "$FILES_LIST" --issue-tracking none
  [ "$status" -eq 0 ]
  [[ "$output" == *'Result: CLEAN'* ]] || return 1
}

@test "pr review-metadata: reports a change-section commit ID absent from final commits" {
  write_pr 'feat(demo): add feature [#12]' $'## Summary\nAdds a demo feature.\n\n## Changes\n- Backported commit `deadbeef1234567`.\n\nCloses #12\n' 'type: feat' 'feat(demo): add feature [#12]'
  printf 'src/actual.py\n' > "$FILES_LIST"
  review --pr "$PR_JSON" --files "$FILES_LIST" --issue-tracking none
  [ "$status" -eq 3 ]
  [[ "$output" == *"[body_commit_not_in_pr]"*"deadbeef1234567"* ]] || return 1
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
  local ship="$BATS_TEST_DIRNAME/../templates/project/.claude/commands/rig-ship.md"
  python3 - "$ship" <<'PY'
import sys
text = open(sys.argv[1]).read()
review = text.index("## Step 9.5 — Final merge-boundary metadata review")
merge = text.index("## Step 10 — Merge verification and branch cleanup")
assert review < merge
section = text[review:merge]
for needle in ('bin/rig" pr review-metadata', "--match-head-commit", "--method PATCH",
               "closingIssuesReferences", "Do not run it on every", "gh pr diff",
               "--files \"$REVIEW_DIR/files.txt\"", "test-count accuracy still needs"):
    assert needle in section, needle
assert "gh pr edit" not in section.split("Act on the exit code:")[1].replace("`gh pr edit` can fail", "")
step9 = text[text.index("## Step 9"):review]
assert "gh api repos/{owner}/{repo}/pulls/[N] --method PATCH" in step9

workflow = open("templates/project/.rig/processes/SHIP_WORKFLOW.md").read()
workflow_section = workflow[workflow.index("## Step 8 — Review PR metadata at the merge boundary"):
                            workflow.index("### Merge gate evidence block")]
for needle in ("gh pr diff N --name-only", "--files FILE", "Summary, Changes, Files changed, and Scope",
               "test and verification claims", "focused", "CI run for the reviewed head",
               "gh api repos/{owner}/{repo}/pulls/N --method PATCH", "Do not use `gh pr edit`"):
    assert needle in workflow_section, needle
PY
}

@test "wrap and post-merge check PR body claims against final diffs and use REST for approved edits" {
  python3 - <<'PY'
from pathlib import Path
wrap = Path("templates/project/.claude/commands/wrap.md").read_text()
wrap_section = wrap[wrap.index("## PR description freshness step"):wrap.index("## Session naming step")]
for needle in ("gh pr diff", "pr review-metadata", "--files", "current PR head",
               "ask before", "gh api repos/{owner}/{repo}/pulls/"):
    assert needle in wrap_section, needle
assert "gh pr edit" not in wrap_section

post_merge = Path("templates/project/.rig/processes/POST_MERGE_WORKFLOW.md").read_text()
post_section = post_merge[post_merge.index("## Post-merge PR description accuracy"):
                          post_merge.index("## Step 2 — Update PROGRESS.md")]
for needle in ("gh pr diff", "exact-head", "ask for approval", "gh api",
               "append that note to the PR body", "preserving the original",
               "Do not use gh pr edit"):
    assert needle in post_section, needle
PY
}

@test "pr review-metadata: a Refs list leaves every listed issue open" {
  write_pr 'feat(x): add y [#12]' $'Closes #12\n\nRefs #13, #14 (partial)\nPartially addresses #15\n' 'type: feat' 'feat(x): add y [#12 #13 #14 #15]'
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Result: CLEAN"* ]] || return 1
}

@test "pr review-metadata: a closing keyword in commit prose is reported without proposing a Closes line" {
  write_pr 'fix(x): repair y [#12]' $'Closes #12\n' 'type: fix' 'fix(x): repair y [#12]|The approach that fixed #500 regressed this.'
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON" --payload-out "$PAYLOAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *"[commit_message_closes]"*"#500"* && "$output" != *"missing_closing_link"* ]] || return 1
  [ ! -e "$PAYLOAD" ]
}

@test "pr review-metadata: a body Closes line GitHub does not link is reported, not duplicated" {
  write_pr 'fix(x): repair y [#12]' $'## Closes\n\nCloses #12\n' 'type: fix' 'fix(x): repair y [#12]'
  write_closing
  review --pr "$PR_JSON" --closing "$CLOSING_JSON" --payload-out "$PAYLOAD"
  [ "$status" -eq 3 ]
  [[ "$output" == *"[closing_link_not_linked]"*"#12"* && "$output" != *"missing_closing_link"* ]] || return 1
  [ ! -e "$PAYLOAD" ]
}

@test "pr review-metadata: unreadable inputs and payload paths exit 64, as JSON when requested" {
  review --pr "$BATS_TEST_TMPDIR"
  [ "$status" -eq 64 ]
  [[ "$output" != *"Traceback"* ]] || return 1
  write_pr 'docs: plan' 'Body' 'type: docs' 'fix(x): repair y [#12]'
  review --pr "$PR_JSON" --payload-out "$BATS_TEST_TMPDIR/missing-dir/payload.json"
  [ "$status" -eq 64 ]
  [[ "$output" != *"Traceback"* ]] || return 1
  review --bogus --json
  [ "$status" -eq 64 ]
  JSON_OUTPUT="$output" python3 -c 'import json,os; d=json.loads(os.environ["JSON_OUTPUT"]); assert d["ok"] is False and d["error"] == "usage", d'
}

@test "pr review-metadata: non-conventional revert PRs are not given a mangled title or closing link" {
  write_pr 'Revert "feat(x): add y [#12]"' $'Reverts #9\n' '' 'Revert "feat(x): add y [#12]"'
  write_closing
  review --pr "$PR_JSON" --closing "$CLOSING_JSON"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Result: CLEAN"* ]] || return 1
}

@test "pr review-metadata: a stale type label gets a DELETE proposal and drafts get a ready command" {
  write_pr 'fix(x): repair y [#12]' $'Closes #12\n' 'type: fix,type: docs' 'fix(x): repair y [#12]'
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); d["isDraft"]=True; json.dump(d,open(sys.argv[1],"w"))' "$PR_JSON"
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON"
  [ "$status" -eq 3 ]
  [[ "$output" == *"[stale_label] label 'type: docs'"* ]] || return 1
  [[ "$output" == *"issues/42/labels/type%3A%20docs --method DELETE"* ]] || return 1
  [[ "$output" == *"gh pr ready 42"* ]] || return 1
  [[ "$output" == *"--match-head-commit abc1234def5678 (add the project's --merge, --squash or --rebase flag)"* ]] || return 1
}

@test "pr review-metadata: a clean review writes no payload file" {
  write_pr 'fix(x): repair y [#12]' $'Closes #12\n' 'type: fix' 'fix(x): repair y [#12]'
  write_closing 12
  review --pr "$PR_JSON" --closing "$CLOSING_JSON" --payload-out "$PAYLOAD"
  [ "$status" -eq 0 ]
  [ ! -e "$PAYLOAD" ]
}
