# Verification rules

> Defines when and how to verify code before committing.
> Applied in addition to the pre-ship checklist in `.rig/processes/SHIP_WORKFLOW.md`.

---

## When in-container verification is required

Run an in-container smoke test before committing whenever a PR touches **any** of:

- `docker-compose.yml` or any `Dockerfile`
- Dependency manifests: `requirements.txt`, `package.json`, `pyproject.toml`, `Gemfile`, etc.
- Any service-layer module (code that other modules import at startup)
- Any new module that runs at application boot

The reason: linting and diff review cannot catch import errors, missing packages, or
Docker layer issues. These only surface when the container actually starts.

---

## Minimum smoke test

```bash
# 1. Confirm the image builds cleanly
docker compose build [service-name]

# 2. Confirm the stack boots and the health endpoint responds
docker compose up -d
sleep 4
curl -sf http://localhost:[PORT]/health || (echo "Health check failed" && exit 1)
docker compose down

# 3. For logic changes — run an in-container assertion
docker compose run --rm [service] [runtime] -c "[assertion]"
# Examples:
#   docker compose run --rm backend python -c "from app.main import app; print('ok')"
#   docker compose run --rm backend python -m pytest tests/unit/ -q
```

Adapt the health endpoint path and port to your project.

---

## Document it in the commit message

The commit body must include a line describing what was verified:

```
- Verified in-container: image builds, /health 200, import check passes
```

---

## After Docker verification — check for untracked files

Docker volume mounts can generate new files inside the container that appear in
the host working directory. Always run:

```bash
git status --short
```

after any Docker verification step. Commit or `.gitignore` any untracked files
before opening the PR.

---

## When in-container verification is NOT required

- Changes to docs, task files, memory files, or rules only
- Frontend-only changes that don't touch `package.json` or any `Dockerfile`
- Pure type annotation or comment changes with no logic

In these cases, a diff review is sufficient.
