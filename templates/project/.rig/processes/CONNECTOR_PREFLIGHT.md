# Connector preflight workflow

The canonical dependency declaration is
`$RIG_DIR/connectors/skill-dependencies.v1.json`. The shell evaluator is
deterministic and cannot observe an agent's active tool schemas.

1. Run `rig session current --json`. Continue only for an exact root session.
2. Inspect only tools and schemas surfaced through the current agent's documented
   public tool inventory. Do not inspect private databases, indexes, credentials,
   rollout/transcript files, prompts, or messages.
3. Create `connector-preflight-evidence/v1` with the exact Rig anchor/revision,
   canonical visible tool names, normalized schema hashes, an inventory digest,
   and sanitized observations. Never persist native provider session IDs.
4. A smoke call is optional. Use only the declaration's fixed read-only metadata
   call, empty arguments, one attempt, and its timeout. Never search, enumerate,
   navigate to user content, mutate, or auto-approve a permission prompt. Discard
   response content and record only its normalized outcome and duration bucket.
5. Pass evidence by stdin or a private regular file to
   `rig connector preflight --skill ID --evidence FILE --json` and render the
   result. Configuration or CLI authentication never proves schema visibility or
   callability. If no safe call exists, `schema_visible` is the ceiling.

Evidence collection is read-only. Repair, login, authorization, and policy
changes require separate explicit user action.
