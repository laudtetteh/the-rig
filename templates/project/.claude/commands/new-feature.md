# Command: /new-feature

> **Deprecated.** Use `/task` instead.
>
> `/task` is the primary entry point for all new work. It runs the same
> `NEW_TASK_WORKFLOW` as this command but adds the intake wizard — autonomy
> level, check-in frequency, and risk tolerance — so your operating mode is
> configured and persisted in the task file from the start.
>
> `/new-feature` is kept for backward compatibility. If you run it, the agent
> will redirect you to `/task` automatically.

---

When this command is triggered, say:

> "This command is deprecated. `/task` does everything `/new-feature` does, plus
> it captures your autonomy level, check-in preference, and risk tolerance so
> every session on this task behaves consistently.
>
> Run `/task` to start the intake wizard."

Do not proceed with the old workflow. Redirect only.

---

## Notes

Deprecated in favour of `/task`, which adds an intake wizard for autonomy level,
check-in frequency, and risk tolerance on top of the same `NEW_TASK_WORKFLOW`.
