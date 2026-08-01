# Public session identity and repair

The Rig identifies a conversation by its exact public native hook ID, agent,
and project identity. Branch, PID, cwd, title, prompts, transcripts, and the
number of active records are never normal identity selectors.

Public diagnostics:

- `rig session current [--json] [--verbose]` reports the exact current record.
- `rig session list [--json] [--verbose]` lists safe record summaries.
- `rig session doctor [--json]` checks syntax, schema support, uniqueness, and
  repair-audit privacy. Native IDs are redacted unless `--verbose` is explicit.

`rig session repair --anchor ANCHOR --agent AGENT --native-session-id ID
--reason REASON --json` produces a no-write preview. Apply that exact repair by
adding `--confirm TOKEN` with the preview's token. Confirmation rechecks
conflicts and the record hash while holding the
binding lock, updates the record atomically, and writes a mode-0600 audit entry
containing hashes and revisions but no native ID, prompt, or transcript text.

Prompt or transcript matching is not implemented against provider files. A
last-resort request must be explicitly authorized for that invocation, and it
still fails without writing unless a documented exported/plain-text provider
surface is integrated. The Rig never reads or edits provider SQLite databases,
indexes, rollout JSONL, private metadata, or transcript formats.

Lifecycle and migration:

- A provider SessionEnd conservatively leaves a resumable record `inactive`, or
  `ended_no_wrap` when that exact anchor owns a wrap obligation. Exact native-ID
  resume reactivates the same record.
- `rig session repair` is the only orphan reopen path. It previews and confirms
  an exact native binding, then transitions `orphaned` or `repair_pending` to
  `active`; it never guesses from branch, PID, title, prompts, or transcripts.
- Legacy records migrate only from an explicit launcher file/anchor during an
  exact native hook bind. A migrated legacy source may be retained as
  `superseded`; it is never selected for future writes. Ambiguous legacy records
  remain visible for explicit repair and are not normalized automatically.
- `rig session obligation mark|clear --kind wrap|post-merge` updates the exact
  record and shared reminder under one coordination lock. Wrap markers retain
  every pending `anchor=` entry. Post-merge clearing requires the exact pending
  merge SHA and records the acknowledging anchor; a mismatch performs no write.
  `--adopt-legacy` is required to clear an older unscoped wrap marker.
