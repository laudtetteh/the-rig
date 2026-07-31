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
