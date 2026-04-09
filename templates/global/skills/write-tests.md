# Skill: write-tests

> Triggered by: "write tests for…"
> Installed at: `~/.claude/skills/write-tests.md`

When asked to write tests, follow this process.

---

## Steps

1. **Read the code under test in full** before writing anything.
2. **Identify the unit boundaries** — what is the smallest meaningful thing to test?
3. **List the test cases** before writing code:
   - Happy path (expected inputs, expected outputs)
   - Edge cases (empty, zero, max, boundary values)
   - Error cases (invalid input, missing data, external failure)
4. **Confirm the list** with the user if there are more than 6 test cases.
5. **Write tests** using the project's existing test framework and style.

---

## Rules

- Tests must be **independent** — no shared mutable state between tests.
- Test **behaviour**, not implementation. Don't assert on private internals.
- Mock at the boundary (network, filesystem, time, external APIs) —
  not inside business logic.
- Every test must have a name that describes what it asserts in plain English.
- Don't write tests for code that doesn't exist yet unless explicitly asked for TDD.

---

## Output format

- Group tests logically (by feature, method, or scenario).
- Include a brief comment above each group explaining what's being tested.
- If coverage is incomplete, list what's missing at the end.
