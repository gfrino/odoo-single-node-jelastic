#!/usr/bin/env bash
# Shared paths and helpers for the Odoo single-node scripts.
# Every script sources this file; nothing here has side effects beyond defining things.

set -Eeuo pipefail

# --- Paths -------------------------------------------------------------------
# Everything that must survive a Jelastic redeploy lives on one of the node volumes
# declared in manifest.jps: /etc/odoo, /opt/odoo, /var/lib/odoo, /var/lib/postgresql,
# /etc/postgresql, /etc/letsencrypt, /var/backups/odoo.
JPS_DIR=/opt/odoo/jps
DEB_DIR=/opt/odoo/debs
ADDONS_DIR=/mnt/extra-addons
# Where custom modules lived before 1.1 (still read if it holds modules).
LEGACY_ADDONS_DIR=/opt/odoo/addons
STATE_FILE=/etc/odoo/jps.env
ODOO_CONF=/etc/odoo/odoo.conf
ODOO_LOCAL_CONF=/etc/odoo/odoo.local.conf
# Extra Ubuntu packages needed by custom modules (one per line, # for comments),
# reinstalled on every redeploy.
EXTRA_PACKAGES_FILE=/etc/odoo/apt-packages
ODOO_DATA=/var/lib/odoo
BACKUP_DIR=/var/backups/odoo
ACME_ROOT=/var/www/letsencrypt
LOG_FILE=/var/log/odoo-jps.log
ODOO_CORE_ADDONS=/usr/lib/python3/dist-packages/odoo/addons

# Fixed UIDs so files on the volumes keep the right owner after a redeploy
# re-creates the users on a fresh OS image.
ODOO_UID=969
PG_UID=970

# Same wkhtmltopdf build the official Odoo Docker images install on Ubuntu 24.04.
WKHTMLTOX_VERSION=0.12.6.1-3
declare -A WKHTMLTOX_SHA1=(
  [amd64]=967390a759707337b46d1c02452e2bb6b2dc6d59
  [arm64]=90f6e69896d51ef77339d3f3a20f8582bdf496cc
)

SUPPORTED_ODOO_VERSIONS="17.0 18.0 19.0 20.0"

export DEBIAN_FRONTEND=noninteractive
APT_INSTALL=(apt-get install -y -q --no-install-recommends
  -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# --- Logging -----------------------------------------------------------------
log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "ERROR: ${BASH_SOURCE[0]##*/}:${LINENO}: \"${BASH_COMMAND}\" exited with $?"' ERR

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# --- State (/etc/odoo/jps.env) -----------------------------------------------
load_state() {
  # shellcheck disable=SC1090
  if [ -f "$STATE_FILE" ]; then . "$STATE_FILE"; fi
  DB_NAME=${DB_NAME:-odoo}
}

set_state() {
  local key=$1 val=$2 tmp
  mkdir -p "$(dirname "$STATE_FILE")"
  touch "$STATE_FILE"
  chmod 600 "$STATE_FILE"
  tmp=$(mktemp)
  grep -v "^${key}=" "$STATE_FILE" > "$tmp" || true
  printf '%s=%q\n' "$key" "$val" >> "$tmp"
  cat "$tmp" > "$STATE_FILE"
  rm -f "$tmp"
  printf -v "$key" '%s' "$val"
}

# --- Helpers -----------------------------------------------------------------
odoo_major() { echo "${ODOO_VERSION%%.*}"; }

as_postgres() { runuser -u postgres -- "$@"; }
as_odoo() { runuser -u odoo -- "$@"; }
psql_admin() { as_postgres psql -X -q -At -v ON_ERROR_STOP=1 "$@"; }

db_exists() {
  [ "$(psql_admin -d postgres -c "SELECT 1 FROM pg_database WHERE datname = '$DB_NAME'")" = 1 ]
}

# Waits until Odoo answers on its local HTTP port. Returns non-zero on timeout.
wait_odoo() {
  local timeout=${1:-180} i code
  for ((i = 0; i < timeout; i += 3)); do
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1:8069/web/login || true)
    [ "$code" = 200 ] && return 0
    sleep 3
  done
  log "Odoo did not answer 200 on /web/login within ${timeout}s (last code: ${code:-none})"
  return 1
}

# Downloads an Odoo .deb into $DEB_DIR and prints its path.
# $1 = series (e.g. 20.0), $2 = build date (YYYYMMDD) or "latest".
download_odoo_deb() {
  local series=$1 build=${2:-latest} url tmp version dest
  url="https://nightly.odoo.com/${series}/nightly/deb/odoo_${series}.${build}_all.deb"
  mkdir -p "$DEB_DIR"
  tmp=$(mktemp -p "$DEB_DIR" .download.XXXXXX)
  log "Downloading $url"
  curl -fsSL --retry 3 -o "$tmp" "$url" || { rm -f "$tmp"; die "download failed: $url"; }
  version=$(dpkg-deb -f "$tmp" Version) || { rm -f "$tmp"; die "not a valid .deb: $url"; }
  dest="$DEB_DIR/odoo_${version}_all.deb"
  mv -f "$tmp" "$dest"
  echo "$dest"
}

# Resources visible to the container (Virtuozzo shows the cloudlet limit in /proc/meminfo).
mem_mb() { awk '/^MemTotal:/ {print int($2 / 1024)}' /proc/meminfo; }
cpu_count() { nproc; }

clamp() { local v=$1 lo=$2 hi=$3; ((v < lo)) && v=$lo; ((v > hi)) && v=$hi; echo "$v"; }
