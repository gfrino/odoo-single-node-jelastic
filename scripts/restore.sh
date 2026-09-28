#!/usr/bin/env bash
# Restores a backup made by backup.sh (database and, if present, filestore).
# Usage: restore.sh /var/backups/odoo/odoo-YYYYmmdd-HHMMSS-tag.dump
# The current database is renamed, not dropped, until the restore has succeeded.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

dump=${1:?usage: restore.sh <file.dump>}
dump=$(readlink -f "$dump")
[[ "$dump" == "$BACKUP_DIR"/*.dump ]] || die "backup must be a .dump file in $BACKUP_DIR"
[ -s "$dump" ] || die "backup not found: $dump"
filestore_tar=${dump%.dump}.filestore.tar
aside="${DB_NAME}_before_restore_$(date +%Y%m%d%H%M%S)"

log "Restoring $dump"
systemctl stop odoo
if db_exists; then
  psql_admin -d postgres -c "ALTER DATABASE \"$DB_NAME\" RENAME TO \"$aside\""
fi
if ! {
  as_postgres createdb -O odoo -E UTF8 --lc-collate=C -T template0 "$DB_NAME" &&
    as_postgres pg_restore --no-owner --role=odoo -d "$DB_NAME" < "$dump"
}; then
  psql_admin -d postgres -c "DROP DATABASE IF EXISTS \"$DB_NAME\""
  [ "$(psql_admin -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$aside'")" = 1 ] &&
    psql_admin -d postgres -c "ALTER DATABASE \"$aside\" RENAME TO \"$DB_NAME\""
  systemctl start odoo
  die "restore failed, previous database put back"
fi

if [ -s "$filestore_tar" ]; then
  if [ -d "$ODOO_DATA/filestore/$DB_NAME" ]; then
    mv "$ODOO_DATA/filestore/$DB_NAME" "$ODOO_DATA/filestore/$aside"
  fi
  tar -C "$ODOO_DATA/filestore" -xf "$filestore_tar"
  chown -R odoo:odoo "$ODOO_DATA/filestore/$DB_NAME"
fi

systemctl start odoo
wait_odoo 240 || die "Odoo did not come up after the restore; previous data kept as $aside"
psql_admin -d postgres -c "DROP DATABASE \"$aside\"" 2> /dev/null || true
rm -rf "${ODOO_DATA:?}/filestore/$aside"
log "Restore of $dump completed"
