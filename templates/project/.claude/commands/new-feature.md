# Command: /new-feature

Trigger this command to kick off a new feature task end-to-end.

## What this does

Follows `.rig/processes/NEW_TASK_WORKFLOW.md` from the beginning:

1. Asks you for the feature name and one-sentence goal
2. Creates a task file in `.rig/tasks/backlog/` using the task template
3. Confirms the goal and files to touch
4. Writes the implementation plan into the task file under `## Approach`
5. Waits for your approval before writing any code

## Usage

```
/new-feature
```

Claude will ask:
- What's the feature name?
- What's the one-sentence goal?
- Any files that are off-limits or out of scope for this task?

Then it creates the task file and follows `.rig/processes/NEW_TASK_WORKFLOW.md` from Step 0.

## Notes

- A GitHub issue must be created before any code is written (Step 0 of NEW_TASK_WORKFLOW)
- The task file is not staged until it has been moved to `.rig/tasks/done/`
- If a task file already exists in `.rig/tasks/active/`, ask whether to resume it instead
