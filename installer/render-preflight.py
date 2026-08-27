#!/usr/bin/env python3
import argparse, json, os, shutil, subprocess, sys

p = argparse.ArgumentParser()
p.add_argument("--manifest", required=True); p.add_argument("--version", required=True)
p.add_argument("--operation", required=True); p.add_argument("--global-agent", required=True)
p.add_argument("--project-agent", required=True); p.add_argument("--global-enabled", action="store_true")
p.add_argument("--project-enabled", action="store_true"); p.add_argument("--global-destination", required=True)
p.add_argument("--project-husky", action="store_true")
p.add_argument("--project-destination", required=True); p.add_argument("--state-error", action="append", default=[])
a = p.parse_args()
forced_missing = set(os.environ.get("_RIG_TEST_MISSING_COMMANDS", "").split(","))
def available(name): return name not in forced_missing and bool(shutil.which(name))
def destination_status(path):
    if not os.path.isdir(path):
        return "missing", None
    if not os.access(path, os.W_OK):
        return "missing", "unwritable"
    return "ok", None

def agents(value): return [] if value == "none" else ["claude", "codex"] if value == "both" else [value]
deps = [{"id":"bash","classification":"required","scope":"both","agents":[],"status":"ok","required_for":["installer"],"remediation":"Install Bash 3.2 or newer"},
        {"id":"python3","classification":"required","scope":"both","agents":[],"status":"ok" if available("python3") else "missing","required_for":["capability-manifest"],"remediation":"Install Python 3"}]
selected = (agents(a.global_agent) if a.global_enabled else []) + (agents(a.project_agent) if a.project_enabled else [])
if a.global_enabled and agents(a.global_agent):
    parent = a.global_destination if os.path.isdir(a.global_destination) else os.path.dirname(a.global_destination)
    deps.append({"id":"global-destination","classification":"required","scope":"global","agents":agents(a.global_agent),"status":"ok" if os.path.isdir(parent) and os.access(parent, os.W_OK) else "missing","required_for":["global-install"],"remediation":"Choose a writable HOME/global destination"})
for agent in ("claude", "codex"):
    if agent in selected:
        deps.append({"id":agent,"classification":"required","scope":"both","agents":[agent],"status":"ok" if available(agent) else "missing","required_for":[f"{agent}-integration"],"remediation":f"Install and authenticate the {agent} CLI"})
if a.project_enabled and agents(a.project_agent):
    project_destination_status, project_destination_detail = destination_status(a.project_destination)
    project_destination_dep = {"id":"project-destination","classification":"project","scope":"project","agents":agents(a.project_agent),"status":project_destination_status,"required_for":["project-install"],"remediation":"Choose an existing writable project directory"}
    if project_destination_detail: project_destination_dep["detail"] = project_destination_detail
    deps.append(project_destination_dep)
    deps.append({"id":"git","classification":"project","scope":"project","agents":agents(a.project_agent),"status":"ok" if available("git") else "missing","required_for":["project-rig-core"],"remediation":"Install git"})
    deps.append({"id":"gitleaks","classification":"optional","scope":"project","agents":[],"status":"ok" if shutil.which("gitleaks") else "missing","required_for":["secret-scanning"],"remediation":"Install gitleaks to enable commit secret scanning"})
    deps.append({"id":"sha256","classification":"optional","scope":"project","agents":[],"status":"ok" if (shutil.which("sha256sum") or shutil.which("shasum")) else "missing","required_for":["customization-detection"],"remediation":"Install sha256sum or shasum for upgrade customization detection"})
    if a.project_husky:
        deps.append({"id":"npx","classification":"project","scope":"project","agents":agents(a.project_agent),"status":"ok" if available("npx") else "missing","required_for":["husky-initialization"],"remediation":"Install Node.js/npm to provide npx, or decline Husky initialization"})
errors = [{"code":"target-metadata-invalid","message":x} for x in a.state_error]
try:
    checker = os.path.join(os.path.dirname(__file__), "check-capabilities.py")
    checked = subprocess.run([sys.executable, checker, a.manifest], text=True, capture_output=True)
    manifest_result = json.loads(checked.stdout)
    if checked.returncode: errors.append(manifest_result["error"])
except Exception as exc: errors.append({"code":"capability-manifest-invalid","message":str(exc)})
for dep in deps:
    if dep["classification"] != "optional" and dep["status"] != "ok": errors.append({"code":f"missing-{dep['id']}","message":dep["remediation"]})
degraded = []
if any(d["id"] == "gitleaks" and d["status"] != "ok" for d in deps): degraded.append("secret-scanning")
if any(d["id"] == "sha256" and d["status"] != "ok" for d in deps): degraded.append("customization-detection")
warnings = []
if any(d["id"] == "project-destination" and d.get("detail") == "unwritable" for d in deps):
    warnings.append({"code":"unwritable-project-destination","message":"Project destination exists but is not writable by this process"})
operation = "upgrade" if a.operation == "upgrade" else "repair" if a.operation == "overwrite" else "install"
result={"schema":"https://the-rig.dev/schemas/install-preflight/v1","schema_version":1,"ok":not errors,"installer_version":a.version,"operation":operation,
"layers":{"global":{"enabled":a.global_enabled,"agents":agents(a.global_agent),"destination":a.global_destination},"project":{"enabled":a.project_enabled,"agents":agents(a.project_agent),"destination":a.project_destination}},
"dependencies":deps,"degraded_features":degraded,"errors":errors,"warnings":warnings,"next_steps":[f"Launch {x}" for x in sorted(set(selected))],"auto_install_dependencies":False}
print(json.dumps(result,separators=(",",":")))
sys.exit(0 if result["ok"] else 1)
