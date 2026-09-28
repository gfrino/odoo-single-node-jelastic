#!/usr/bin/env bash
# Updates Odoo to a newer build of the SAME major version (e.g. 20.0 of 26/09 -> 20.0 of 28/09).
# Usage: update-odoo.sh [--build latest|YYYYMMDD] [--update-modules]
#   --update-modules  also runs "-u all" (needed only when a fix changes data or views)
# A backup is taken first; if Odoo does not come back, the previous build (and, with
# --update-modules, the previous database) is restored automatically.
# Major upgrades (20 -> 21) need a data migration and are not done by this script.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

build=latest
update_modules=0
while [ $# -gt 0 ]; do
  case $1 in
    --build) build=$2; shift 2 ;;
    --update-modules) update_modules=1; shift ;;
    *) die "unknown option: $1" ;;
  esac
done

[[ "$build" =~ ^(latest|[0-9]{8})$ ]] || die "invalid build: $build (use latest or YYYYMMDD)"

prev_deb=$ODOO_DEB
prev_version=$(dpkg-query -W -f '${Version}' odoo)
new_deb=$(download_odoo_deb "$ODOO_VERSION" "$build")
new_version=$(dpkg-deb -f "$new_deb" Version)

if [ "$new_version" = "$prev_version" ]; then
  log "Odoo is already at $new_version"
  exit 0
fi
dpkg --compare-versions "$new_version" gt "$prev_version" ||
  log "Note: $new_version is older than the installed $prev_version (downgrade)"

dump=$("$JPS_DIR/backup.sh" --tag "pre-update-$new_version")

rollback() {
  log "Rolling back to Odoo $prev_version"
  systemctl stop odoo || true
  "${APT_INSTALL[@]}" --allow-downgrades --allow-change-held-packages "$prev_deb"
  apt-mark hold odoo > /dev/null
  if ((update_modules)); then
    "$JPS_DIR/restore.sh" "$dump"
  else
    systemctl start odoo
    wait_odoo 240 || true
  fi
  die "update to $new_version failed, Odoo $prev_version restored (backup: $dump)"
}

log "Updating Odoo $prev_version -> $new_version"
systemctl stop odoo
printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
chmod +x /usr/sbin/policy-rc.d
if ! "${APT_INSTALL[@]}" --allow-downgrades --allow-change-held-packages "$new_deb"; then
  rm -f /usr/sbin/policy-rc.d
  rollback
fi
rm -f /usr/sbin/policy-rc.d
apt-mark hold odoo > /dev/null

if ((update_modules)); then
  "$JPS_DIR/write-odoo-conf.sh"
  log "Updating all modules (-u all)"
  as_odoo odoo -c "$ODOO_CONF" -d "$DB_NAME" -u all --stop-after-init --no-http \
    --logfile /var/log/odoo/update-modules.log || rollback
fi

systemctl start odoo
wait_odoo 240 || rollback
set_state ODOO_DEB "$new_deb"

# Keep the current and the previous .deb for rollbacks, drop older ones.
for f in "$DEB_DIR"/odoo_*_all.deb; do
  [ "$f" = "$new_deb" ] || [ "$f" = "$prev_deb" ] || rm -f "$f"
done
log "Odoo updated to $new_version"
