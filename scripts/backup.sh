#!/usr/bin/env bash
# Backs up the database (pg_dump custom format) and the filestore.
# Usage: backup.sh [--tag daily|manual|pre-update|...] [--keep-days 7]
# Prints the path of the database dump on stdout.
# Backups are on the /var/backups/odoo volume of the same node: copy them off the
# node as well (see README) - a single node is also a single point of failure.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

tag=manual
keep_days=${BACKUP_KEEP_DAYS:-7}
while [ $# -gt 0 ]; do
  case $1 in
    --tag) tag=$2; shift 2 ;;
    --keep-days) keep_days=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

db_exists || { log "No database $DB_NAME, nothing to back up"; exit 0; }

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
stamp=$(date +%Y%m%d-%H%M%S)
base="$BACKUP_DIR/${DB_NAME}-${stamp}-${tag}"

# Refuse to start if the dump would not fit: a full disk would stop Postgres.
db_bytes=$(psql_admin -d postgres -c "SELECT pg_database_size('$DB_NAME')")
fs_bytes=$(du -sb "$ODOO_DATA/filestore/$DB_NAME" 2> /dev/null | cut -f1 || echo 0)
free_bytes=$(($(df --output=avail -B1 "$BACKUP_DIR" | tail -1)))
((free_bytes > (db_bytes / 2 + fs_bytes) * 11 / 10)) ||
  die "not enough free space in $BACKUP_DIR for a backup"

log "Backing up $DB_NAME to ${base}.*"
as_postgres pg_dump -Fc -Z 6 -d "$DB_NAME" > "${base}.dump.tmp"
mv "${base}.dump.tmp" "${base}.dump"
if [ -d "$ODOO_DATA/filestore/$DB_NAME" ]; then
  tar -C "$ODOO_DATA/filestore" -cf "${base}.filestore.tar" "$DB_NAME"
fi
cp -a "$STATE_FILE" "${base}.jps.env"

# Daily backups are kept $keep_days days, automatic pre-* ones 30 days, manual ones
# until someone removes them.
find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}-*-daily.*" -mtime +"$keep_days" -delete
find "$BACKUP_DIR" -maxdepth 1 -name "${DB_NAME}-*-pre-*" -mtime +30 -delete
log "Backup done: $(du -ch "${base}".* | tail -1 | cut -f1)"
echo "${base}.dump"
