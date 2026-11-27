# Command: /rig-handoff

Review unfinished work, prepare a concise session close-out, and show a handoff prompt in chat.

## What this does

Run the close-out sequence only with the user's existing permission for each write. The command itself does not authorize tracker writes, post-merge housekeeping, or session finalization.

## Step 1 — Decide whether this is a stopping point

Use the current conversation and `/rig-next` to list unfinished work, open approvals, unresolved decision-ledger entries, and the next action. Say whether the session is at a logical stopping point. If it is not, identify what must finish first and stop before finalizing the session.

## Step 2 — Resolve every unfinished item

For each unfinished item, identify the owning active task or create a proposed task draft. Before creating or changing a tracker item, show the exact tracker, title, body, labels, and repository and wait for approval of that specific write. Do not file a GitHub issue from an unverified claim. Include every open item from the session decision ledger and close ledger entries only when the user has answered them.

## Step 3 — Run the full accuracy audit

Run `/rig-audit --full`. Reproduce technical claims and present its stale/valid/uncertain table. Apply verified local fixes under the normal test and review gates. Keep tracker writes, release actions, and changes outside the audited scope behind their existing approval requirements.

## Step 4 — Ask before housekeeping or finalization

If `.post-merge-pending` exists, explain what merge remains to process and ask whether to run `/post-merge`. Run it only after the user explicitly agrees. After post-merge is complete, ask separately before running `/wrap`; `/wrap` may update project memory and complete the exact session. If the user does not agree, leave the flag or session state untouched and report the next action.

## Step 5 — Show one handoff prompt in chat

Write a short prompt that points the next agent to the repository's resolved `$RIG_DIR/memory/CONTEXT_SNAPSHOT.md` and active task cards. Include only the scope the user actually stated and any exact pending approval. Do not restate the full snapshot, create a new issue, or write a prompt file by default.

If the user explicitly asks to save the prompt, overwrite only `$RIG_DIR/memory/NEXT_SESSION_PROMPT.md` after showing the exact content. Never create dated copies or save the prompt elsewhere.
