#!/usr/bin/env bash
# Full install + checks on a throw-away test node.
# Usage: [PLATFORM=linux/amd64] tests/smoke.sh <odoo-version> [name]
set -uo pipefail
v=$1
name=${2:-smoke-${v%%.*}}
here=$(cd "$(dirname "$0")" && pwd)
"$here/run-node.sh" "$name" > /dev/null
docker exec "$name" /opt/odoo/jps/install.sh --version "$v" --email admin@example.com --domain "$name.example.com" &&
  docker exec -e ADMIN_PASSWORD=Test-Pass-123 "$name" /opt/odoo/jps/init-db.sh
rc=$?
login=$(docker exec "$name" curl -s -o /dev/null -w '%{http_code}' -H 'X-Forwarded-Proto: https' http://127.0.0.1/web/login)
docker cp "$here/ws.py" "$name:/tmp/ws.py"
ws=$(docker exec "$name" python3 /tmp/ws.py 2>&1 | head -1)
pdf=$(docker exec "$name" bash -c 'echo "<h1>ok</h1>" > /tmp/t.html && wkhtmltopdf -q /tmp/t.html /tmp/t.pdf && head -c4 /tmp/t.pdf')
errors=$(docker exec "$name" bash -c 'cat /var/log/odoo/*.log | grep -cE " (ERROR|CRITICAL) "')
echo "RESULT $v $(docker exec "$name" dpkg --print-architecture): install=$rc login=$login websocket=[$ws] wkhtmltopdf=[$pdf] odoo-errors=$errors"
