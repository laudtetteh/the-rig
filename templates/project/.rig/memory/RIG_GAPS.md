# Rig Gaps & Improvement Log

Observations, friction points, bugs, and improvement ideas captured during real use of The Rig.
Entries are added by the agent — at `/wrap`, task completion, or any time a workflow gap is noticed.

This file is committed to the repo so it persists across machines and accumulates over time.

---

## How to submit gaps for action

1. Run `/rig-gaps` in this project
2. Copy the formatted output
3. Open a Claude Code session in `~/tools/the-rig`
4. Paste and say: **"Here are gap reports from [project name]. Please analyze, triage, and create issues."**
5. The Rig agent will review, open issues, and implement fixes

---

## Entry format

```
## [YYYY-MM-DD] — [short title]

**Category**: bug | friction | missing-feature | improvement
**Severity**: blocking | annoying | nice-to-have
**Workflow**: [which command/process/hook triggered this]
**Observation**: [specific description — what happened or what was missing]
**Suggested fix**: [concrete suggestion, or "unclear"]
```

---

<!-- Add entries below — newest first -->
