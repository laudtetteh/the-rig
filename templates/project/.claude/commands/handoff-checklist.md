# Command: /handoff-checklist

Prepare a consent-gated wrap-and-handoff checklist for a large or costly session.

## Consent gate

Before doing any checklist work, ask the user to confirm both:

1. They want to wrap and hand off now.
2. The exact next unit of work the next session should pursue.

If the user has not explicitly agreed, stop. Do not run `/post-merge`, `/wrap`, or any checklist step. Silence, hesitation, or an ambiguous answer is not consent.

## Checklist

After explicit agreement:

1. Check local task files, GitHub issues, README, `docs/`, Rig commands, hooks, processes, rules, and Codex skills for stale or inaccurate handoff context.
2. If there is no remaining in-session work, run `/post-merge` when a merge is pending, then run `/wrap`.
3. Generate a handoff prompt for the next session using the user's stated next unit of work. Do not invent the scope.
4. Include the expected operating process in the prompt: re-validate tickets against current main, use isolated worktrees, reproduce before fixing, add Bats coverage with proof-by-revert, run independent review, use one consolidated parent PR, run full surface review and hosted CI, and wait for explicit go-ahead before merge.
5. If the prompt asks the next session to delegate review or validation, state
   that delegated agents must not run a local full `bats tests/` suite unless
   the coordinator grants an explicit exception. Tell them to run long
   validation commands as foreground tool calls, report the exact command and
   tool/session identifier while waiting, and avoid duplicate validation while a
   prior run remains active.

## Output

Report exactly what was checked, whether `/post-merge` or `/wrap` ran, and the final handoff prompt.
