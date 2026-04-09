# Coding standards

> This file defines the conventions for every runtime in this project.
> Add a section for each language or framework you use.
> The agent reads this during every implementation task.

---

## How to use this file

Duplicate the template section below for each runtime in your stack.
Fill in the conventions that apply. Delete examples that don't fit.
The agent will follow whatever you write here — be specific.

---

## [Runtime 1 — e.g. Python / FastAPI]

### Naming
- Variables, functions, methods: `snake_case`
- Classes: `PascalCase`
- Constants and module-level config: `SCREAMING_SNAKE_CASE`
- Files and modules: `snake_case`
- [Model/schema fields]: `snake_case`

### Types
- Type hints required on all function signatures (parameters and return types)
- No untyped `dict` passed between functions — define a model or TypedDict
- [Add language-specific type rules here]

### Documentation
- [Docstring style — e.g. Google-style on all non-trivial functions]
- One-liner acceptable for simple functions
- No docstrings on private helpers that are self-explanatory

### General
- Max 40 lines per function. If longer, extract.
- Max 3 parameters per function. If more, use a data class or model.
- Pure functions preferred — no side effects unless necessary.
- Always handle the error case explicitly — never bare `except:` or equivalent.
- Group imports: stdlib → third-party → internal. Blank line between groups.
- No wildcard imports.

---

## [Runtime 2 — e.g. TypeScript / Next.js]

### Naming
- Variables and functions: `camelCase`
- Components and classes: `PascalCase`
- Constants: `SCREAMING_SNAKE_CASE`
- Files: `kebab-case` (except components: `PascalCase.[ext]`)
- Be descriptive — `getUserById` not `getUser`, `isLoading` not `loading`

### Types
- No `any` without a comment explaining why
- Prefer `interface` for object shapes, `type` for unions and primitives
- No untyped props — all component props must have a defined interface

### Comments
- JSDoc on all exported functions and components
- Comment the *why*, not the *what*

### General
- Max 40 lines per function. If longer, extract.
- Prefer `const` over `let`. Never `var`.
- No magic numbers — name your constants.
- No commented-out code in commits — delete it.
- Absolute imports preferred over relative (configure in `tsconfig.json` or equivalent).
- Group imports: external → internal → styles. Blank line between groups.
- No wildcard imports.

---

## Both runtimes

- Delete dead code. We have git history.
- No `console.log`, `print()`, or equivalent debug statements in committed code.
- Error handling: never swallow silently. Always log with enough context to debug.
- User-facing errors: human readable — never expose stack traces or internal details.
- No hardcoded credentials, tokens, or secrets — always use environment variables.
