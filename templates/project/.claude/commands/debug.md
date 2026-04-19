# Command: /debug

Trigger this command when something is broken and you need structured diagnosis.

## What this does

Follows `.rig/processes/DEBUG_WORKFLOW.md`:

1. Asks you to describe the symptom and what you expected instead
2. Asks where you've already looked
3. States a hypothesis before touching any code
4. Works through: reproduce → isolate → inspect → fix → verify
5. Logs the bug and root cause in `.rig/memory/ERRORS.md`

## Usage

```
/debug
```

Claude will ask:
- What are you seeing?
- What did you expect to happen?
- Can you reproduce it consistently?
- Where have you already looked?

Then it follows DEBUG_WORKFLOW systematically — hypothesis first, smallest fix, mandatory log entry.

## Notes

- No code is touched until the bug can be reproduced (Step 1 of DEBUG_WORKFLOW)
- If the fix requires a larger refactor, a minimal patch is applied first and a separate task is opened for the refactor
- Every `/debug` session ends with a `.rig/memory/ERRORS.md` entry — even if the bug turns out to be trivial
