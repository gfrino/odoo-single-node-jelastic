#!/usr/bin/env bash
# Creates the Odoo database on first install and sets the administrator account.
# Usage: ADMIN_PASSWORD=... init-db.sh
# Does nothing if the database already exists.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state
: "${ADMIN_PASSWORD:?set ADMIN_PASSWORD}"
: "${ADMIN_EMAIL:?ADMIN_EMAIL missing from state}"
: "${ENV_DOMAIN:?ENV_DOMAIN missing from state}"

if [ "${DB_INITIALIZED:-}" = 1 ]; then
  log "Database $DB_NAME already initialised, nothing to do"
  exit 0
fi

systemctl stop odoo
"$JPS_DIR/write-odoo-conf.sh"

# A previous run that failed half-way left an empty or partial database: start over.
if db_exists; then
  log "Dropping incomplete database $DB_NAME from a previous attempt"
  psql_admin -d postgres -c "DROP DATABASE \"$DB_NAME\""
  rm -rf "${ODOO_DATA:?}/filestore/$DB_NAME"
fi

log "Creating database $DB_NAME"
# Same encoding and collation Odoo itself uses when it creates a database.
as_postgres createdb -O odoo -E UTF8 --lc-collate=C -T template0 "$DB_NAME"
psql_admin -d "$DB_NAME" -c "CREATE EXTENSION IF NOT EXISTS unaccent; CREATE EXTENSION IF NOT EXISTS pg_trgm;"

init_args=(-c "$ODOO_CONF" -d "$DB_NAME" -i base --stop-after-init --no-http)
(($(odoo_major) < 19)) && init_args+=(--without-demo=all)
[ -n "${ODOO_LANG:-}" ] && [ "$ODOO_LANG" != en_US ] && init_args+=("--load-language=$ODOO_LANG")
as_odoo odoo "${init_args[@]}" --logfile /var/log/odoo/init-db.log ||
  die "database initialisation failed, see /var/log/odoo/init-db.log"

# Credentials go through a private file, never on a command line.
secrets=$(mktemp)
chmod 600 "$secrets"
ADMIN_EMAIL=$ADMIN_EMAIL ADMIN_PASSWORD=$ADMIN_PASSWORD ODOO_LANG=${ODOO_LANG:-en_US} BASE_URL="https://$ENV_DOMAIN" \
  python3 -c 'import json, os, sys; json.dump({k: os.environ[k] for k in sys.argv[1:]}, sys.stdout)' \
  ADMIN_EMAIL ADMIN_PASSWORD ODOO_LANG BASE_URL > "$secrets"
chown odoo "$secrets"
as_odoo env SECRETS="$secrets" odoo shell -c "$ODOO_CONF" -d "$DB_NAME" --no-http \
  --logfile /var/log/odoo/init-db.log << 'PY'
import json, os
with open(os.environ["SECRETS"]) as f:
    s = json.load(f)
admin = env.ref("base.user_admin")
vals = {"login": s["ADMIN_EMAIL"], "email": s["ADMIN_EMAIL"], "password": s["ADMIN_PASSWORD"]}
if env["res.lang"].search([("code", "=", s["ODOO_LANG"]), ("active", "=", True)]):
    vals["lang"] = s["ODOO_LANG"]
admin.write(vals)
icp = env["ir.config_parameter"].sudo()
if hasattr(icp, "set_str"):  # Odoo 20+
    icp.set_str("web.base.url", s["BASE_URL"])
    icp.set_bool("web.base.url.freeze", True)
else:
    icp.set_param("web.base.url", s["BASE_URL"])
    icp.set_param("web.base.url.freeze", "True")
env.cr.commit()
PY
rm -f "$secrets"
set_state DB_INITIALIZED 1

systemctl start odoo
wait_odoo 240 || die "Odoo did not come up after creating the database"
log "Database $DB_NAME ready, administrator login $ADMIN_EMAIL"
