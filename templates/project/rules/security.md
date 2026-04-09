# Security rules

> These are non-negotiable. The agent must follow them regardless of context or time pressure.
> Document any project-specific additions in the section at the bottom.

---

## Non-negotiables — the agent must never do these

- **Never log secrets, tokens, passwords, or PII.** Not in application logs, not in debug output, not in commit messages.
- **Never hardcode credentials.** All secrets come from environment variables. No exceptions.
- **Never expose internal error details in API responses.** Return a human-readable message. Log the detail server-side.
- **Never trust client-supplied data without validation.** Validate and sanitise at every system boundary.
- **Never build raw SQL strings.** Always use parameterised queries or the ORM.
- **Never commit `.env` files.** Verify `.gitignore` covers them before every commit.

---

## Auth

- Always verify session tokens or JWTs server-side on protected routes. Never trust the client's claim.
- Never store sensitive data in `localStorage` — use `httpOnly` cookies or server-side session.
- Rate-limit all auth endpoints before any public-facing deployment.
- Store invite or one-time tokens as hashes — never plaintext.

---

## API

- Validate and sanitise all inputs at the boundary (request body, query params, headers).
- Return `404` (not `403`) when a resource exists but the requester cannot access it — do not leak resource existence.
- Always check ownership before allowing read or write on user-scoped resources.

---

## Dependencies

- Flag any new dependency before adding it — discuss the tradeoff first.
- No packages with known high or critical CVEs without explicit sign-off.
- Run `npm audit` or equivalent before any production deploy.

---

## Environment

- `.env` files must be in `.gitignore` — verify before every commit.
- Use separate secrets for dev, staging, and production. Never reuse across environments.
- Provide a `.env.example` with all required variable names and placeholder values — no real secrets.

---

## If a secret appears in context

If a key, token, or password appears in the conversation or a file during a session:

1. Flag it immediately.
2. Do not include it in any commit, log, or output.
3. Prompt the user to rotate it — even if it only appeared locally.

---

## Project-specific additions

> Add rules here that are specific to this project's data model, compliance requirements,
> or privacy policy. Examples:
>
> - "The `[path]` directory is read-only — never write to it."
> - "Never surface [data type] in API responses."
> - "All [entity] records must be soft-deleted, never hard-deleted."
