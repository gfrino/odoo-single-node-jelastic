#!/usr/bin/env bash
# Upgrades PostgreSQL to a newer major version with pg_upgradecluster (pg_upgrade).
# Usage: upgrade-postgres.sh [--to 19] [--drop-old]
#   --to        target major version (default: newest in the PGDG repository)
#   --drop-old  remove the old cluster and packages once the new one works
# A dump is taken first. The old cluster is kept (stopped) unless --drop-old, so
# you can go back with: pg_dropcluster --stop NEW main && pg_ctlcluster OLD main start

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

target=""
drop_old=0
while [ $# -gt 0 ]; do
  case $1 in
    --to) target=$2; shift 2 ;;
    --drop-old) drop_old=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

old=$PG_MAJOR
apt-get update -q
if [ -z "$target" ]; then
  target=$(apt-cache search --names-only '^postgresql-[0-9]+$' | awk '{print $1}' | sed 's/postgresql-//' | sort -n | tail -1)
fi
[[ "$target" =~ ^[0-9]+$ ]] || die "invalid target version: $target"
drop_old_clusters() {
  local v
  for v in $(ls /etc/postgresql); do
    [ "$v" = "$PG_MAJOR" ] && continue
    [ -d "/etc/postgresql/$v/main" ] && pg_dropcluster --stop "$v" main
    rm -rf "/etc/postgresql/$v" "/var/lib/postgresql/$v"
    apt-get purge -y -q "postgresql-$v" "postgresql-client-$v" > /dev/null
    log "Old cluster $v removed"
  done
}

if ((target <= old)); then
  log "PostgreSQL is already at $old (target $target), nothing to upgrade"
  ((drop_old)) && drop_old_clusters
  exit 0
fi

# pg_upgrade copies the data files: we need room for a second copy.
data_bytes=$(du -sb "/var/lib/postgresql/$old/main" | cut -f1)
free_bytes=$(df --output=avail -B1 /var/lib/postgresql | tail -1)
((free_bytes > data_bytes * 12 / 10)) ||
  die "not enough free space: need ~$((data_bytes * 12 / 10 / 1048576)) MB in /var/lib/postgresql"

dump=$("$JPS_DIR/backup.sh" --tag "pre-pg$target")

log "Upgrading PostgreSQL $old -> $target"
"${APT_INSTALL[@]}" "postgresql-$target" "postgresql-client-$target"
# The package creates an empty "main" cluster for the new version: remove it first.
if [ -d "/etc/postgresql/$target/main" ]; then
  pg_dropcluster --stop "$target" main
fi

systemctl stop odoo
restore_old() {
  log "Upgrade failed, going back to PostgreSQL $old"
  pg_dropcluster --stop "$target" main 2> /dev/null || true
  set_state PG_MAJOR "$old"
  pg_ctlcluster "$old" main start || true
  systemctl start odoo
  die "PostgreSQL upgrade to $target failed; still on $old (backup: $dump)"
}
pg_upgradecluster -v "$target" -m upgrade "$old" main || restore_old

set_state PG_MAJOR "$target"
"$JPS_DIR/tune-postgres.sh" --restart || restore_old
systemctl enable --quiet "postgresql@${target}-main"
systemctl disable --quiet "postgresql@${old}-main" 2> /dev/null || true

systemctl start odoo
wait_odoo 240 || restore_old

# Fresh statistics: pg_upgrade does not carry them over.
as_postgres vacuumdb --all --analyze-in-stages --quiet

if ((drop_old)); then
  drop_old_clusters
else
  log "Old cluster $old kept (stopped). Remove it with: upgrade-postgres.sh --drop-old, or pg_dropcluster $old main"
fi
log "PostgreSQL upgraded to $target"
