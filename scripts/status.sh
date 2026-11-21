#!/usr/bin/env bash
# One-screen summary of the node.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

state() { systemctl is-active "$1" 2> /dev/null || true; }
. /etc/os-release

echo "OS:          $PRETTY_NAME"
echo "Odoo:        $(dpkg-query -W -f '${Version}' odoo 2> /dev/null) [$(state odoo)]"
echo "PostgreSQL:  ${PG_MAJOR:-?} [$(state "postgresql@${PG_MAJOR:-0}-main")] - $(as_postgres psql -X -At -c 'SHOW server_version' 2> /dev/null)"
echo "nginx:       $(nginx -v 2>&1 | sed 's|.*/||') [$(state nginx)]"
echo "Database:    $DB_NAME ($(psql_admin -d postgres -c "SELECT pg_size_pretty(pg_database_size('$DB_NAME'))" 2> /dev/null || echo '?'))"
echo "Filestore:   $(du -sh "$ODOO_DATA/filestore/$DB_NAME" 2> /dev/null | cut -f1 || echo '?')"
sized_on=""
[ "$(sizing_mem_mb)" != "$(mem_mb)" ] && sized_on=", sized on $(sizing_mem_mb) MB reserved"
echo "Workers:     $(awk -F' = ' '$1 == "workers" {print $2}' "$ODOO_CONF") (RAM $(mem_mb) MB${sized_on}, $(cpu_count) CPU)"
# The environment domain usually is in DOMAINS too (it gets a certificate): list it once.
# shellcheck disable=SC2086
domains=$(printf '%s\n' ${ENV_DOMAIN:-} ${DOMAINS:-} | awk 'NF && !seen[$0]++' | paste -sd ' ' -)
echo "Domains:     ${domains:-?}"
cert=/etc/letsencrypt/live/odoo/fullchain.pem
if [ -s "$cert" ]; then
  echo "Certificate: expires $(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)"
fi
pending=$("$JPS_DIR/cert-env.sh" status 2> /dev/null || true)
[ -z "$pending" ] || echo "Certificate: $pending"
last=$(ls -1t "$BACKUP_DIR"/*.dump 2> /dev/null | head -1 || true)
echo "Last backup: ${last:-none}"
"$JPS_DIR/remote-backup.sh" status 2> /dev/null | sed 's/^/             /; 1s/^ */Remote:      /' || true
echo "Disk:        $(df -h --output=used,size,pcent / | tail -1 | awk '{print $1 " used of " $2 " (" $3 ")"}')"
