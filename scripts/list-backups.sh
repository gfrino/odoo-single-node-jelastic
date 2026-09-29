#!/usr/bin/env bash
# Prints, as JSON, the backups in /var/backups/odoo, newest first.
# Used by the "Restore backup" form of the add-on to fill its drop-down.
# Output: [{"file": "/var/backups/odoo/odoo-20260928-142149-pre-redeploy.dump",
#           "date": "2026-09-28 14:21", "tag": "pre-redeploy", "db_bytes": 2402772, "files_bytes": 8980480}, ...]

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

python3 - "$BACKUP_DIR" "$DB_NAME" << 'PY'
import json, os, re, sys
backup_dir, db = sys.argv[1], sys.argv[2]
pattern = re.compile(re.escape(db) + r"-(\d{8})-(\d{6})-(.+)\.dump$")
backups = []
for name in os.listdir(backup_dir) if os.path.isdir(backup_dir) else []:
    m = pattern.match(name)
    if not m:
        continue
    day, time, tag = m.groups()
    path = os.path.join(backup_dir, name)
    filestore = path[:-len(".dump")] + ".filestore.tar"
    backups.append({
        "file": path,
        "date": f"{day[:4]}-{day[4:6]}-{day[6:]} {time[:2]}:{time[2:4]}",
        "tag": tag,
        "db_bytes": os.path.getsize(path),
        "files_bytes": os.path.getsize(filestore) if os.path.exists(filestore) else 0,
    })
backups.sort(key=lambda b: b["file"], reverse=True)
print(json.dumps(backups))
PY
