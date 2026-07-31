# Project conventions

Current operating rules and preferences that the user has explicitly approved
for this project. Read this file at the start of every session and follow each
active convention.

This file is agent-writable, but approval is the gate: do not add, remove, or
materially change a convention until the user explicitly approves that exact
rule or preference. Record the approval date with the convention.

## Content boundary

Include only durable, project-specific operating rules or preferences that are
currently in force.

Do not include:

- secrets, credentials, tokens, private keys, or sensitive personal data;
- transient state such as current branches, open work, environment status, or
  session notes;
- copied or paraphrased governance policy from `CLAUDE.md`, `.rig/processes/`,
  `.rig/rules/`, `.husky/`, or `.claude/hooks/`;
- historical rationale, alternatives, or consequences — record those in
  `DECISIONS.md` when the choice is consequential;
- completed-work history — record it in `PROGRESS.md`;
- failures or pitfalls — record them in `ERRORS.md`;
- feedback about The Rig — record it in `RIG_GAPS.md`;
- inferred, observed, or suggested preferences that the user has not explicitly
  approved.

## Format

```markdown
## [Short convention name]

**Convention**: [The current rule or preference, stated precisely]
**Approved**: [YYYY-MM-DD — explicit user approval]
```

---

<!-- Add explicitly approved conventions below this line. -->
