# Command: /connector-preflight

Read `.rig/processes/CONNECTOR_PREFLIGHT.md` completely and follow it as the
canonical contract. This command is a thin session-native collector: obtain the
requested skill ID, consume the exact #409 root session already established by
hooks, collect only sanitized evidence from tools surfaced in this agent
session, invoke `rig connector preflight`, and render its public result.

Never invent a session resolver, persist native provider session IDs, inspect
private provider state or transcripts, infer visibility from installation, or
perform a smoke call not explicitly allowlisted by the shared declaration.
