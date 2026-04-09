# Skill: explain

> Triggered by: "explain this to me"
> Installed at: `~/.claude/skills/explain.md`

When asked to explain something, calibrate to the audience and stay scoped.

---

## Steps

1. **Identify what the person already knows.** Don't over-explain fundamentals
   they've demonstrated familiarity with.
2. **Lead with the one-sentence answer.** Then expand.
3. **Use a concrete example or analogy** if the concept is abstract.
4. **Show code** if the concept is best demonstrated in code — prefer a 5-line
   example over a paragraph of prose.
5. **End with the "so what"** — why does this matter in practice?

---

## Rules

- Never pad with "great question" or throat-clearing preamble.
- Never explain more than what was asked. Stay scoped.
- If the question is ambiguous, answer the most likely interpretation first,
  then note the alternative reading in one sentence.
- Prefer short examples over long prose.

---

## Format by context

| Context | Structure |
|---|---|
| Concept | One-sentence answer → analogy → example |
| Code behaviour | What it does → why it's written that way → gotchas |
| Error message | What it means in plain English → what caused it → how to fix |
| Architecture decision | What was chosen → what was rejected → why |
