# Command: /ship

Trigger this command when you're ready to commit and close out a task.

## What this does

Follows `processes/SHIP_WORKFLOW.md`:

1. Identifies the active task file and confirms which task is being shipped
2. Runs through the pre-ship checklist (acceptance criteria, no debug code, no secrets, verification)
3. Shows you the proposed commit message and waits for approval
4. Commits, moves the task file to `tasks/done/`, updates `memory/PROGRESS.md`
5. Opens the PR using the project's PR template

## Usage

```
/ship
```

Claude will confirm:
- Which task is being shipped
- The commit message it will use (conventional format, references the issue)
- Any checklist items that look incomplete or ambiguous

It then waits for your explicit **"go ahead"** before committing.

## Notes

- The GitHub issue must already exist before `/ship` is run (see SHIP_WORKFLOW Step 0)
- Labels are applied at PR creation time — Claude will prompt if none are specified
- The task file is staged only from `tasks/done/`, never from `tasks/active/`
