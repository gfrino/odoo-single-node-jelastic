#!/usr/bin/env bash
# Prints, as JSON, the repositories on this backup storage with their last snapshot.
# Used by the Odoo add-on's "Connect backup environment" form.
# Output: [{"repo": "demo20", "snapshots": 12, "last": "2026-09-29 03:41"}, ...]

. "$(dirname "$(readlink -f "$0")")/common.sh"

python3 - "$REGISTRY" "$CLIENTS" << 'PY'
import glob, json, os, subprocess, sys
registry, clients = sys.argv[1], sys.argv[2]
out = []
for f in sorted(glob.glob(os.path.join(registry, "*.env"))):
    env = dict(line.strip().split("=", 1) for line in open(f) if "=" in line)
    user, repo = env.get("CLIENT_USER", "").strip("'"), env.get("CLIENT_REPO", "").strip("'")
    d = os.path.join(clients, user)
    snaps = []
    if os.path.exists(os.path.join(d, "repo", "config")):
        r = subprocess.run(["restic", "-r", os.path.join(d, "repo"), "snapshots", "--json", "--no-lock"],
                           env=dict(os.environ, RESTIC_PASSWORD_FILE=os.path.join(d, "password")),
                           capture_output=True, text=True)
        if r.returncode == 0:
            snaps = json.loads(r.stdout or "[]") or []
    last = max((s["time"][:16].replace("T", " ") for s in snaps), default="")
    out.append({"repo": repo, "snapshots": len(snaps), "last": last})
print(json.dumps(out))
PY
