#!/usr/bin/env bash
# Provisions the node: packages, users, Postgres, Odoo, nginx, timers.
# Idempotent. Used for the first install and again after every Jelastic redeploy,
# when the OS image is fresh but the volumes still hold all the data.
#
# First install:  install.sh --version 20.0 --email admin@example.com --domain env.example.com [--lang it_IT] [--pg 18] [--build 20260926]
# After redeploy: install.sh            (everything is read from /etc/odoo/jps.env)

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

while [ $# -gt 0 ]; do
  case $1 in
    --version) set_state ODOO_VERSION "$2"; shift 2 ;;
    --email) set_state ADMIN_EMAIL "$2"; shift 2 ;;
    --domain) set_state ENV_DOMAIN "$2"; shift 2 ;;
    --lang) set_state ODOO_LANG "$2"; shift 2 ;;
    --pg) set_state PG_MAJOR "$2"; shift 2 ;;
    --build) ODOO_BUILD=$2; shift 2 ;;
    *) die "unknown option: $1" ;;
  esac
done

[ -n "${ODOO_VERSION:-}" ] || die "first install needs --version"
[[ "${ADMIN_EMAIL:-}" =~ ^[^@[:space:]\']+@[^@[:space:]\']+\.[a-zA-Z]{2,}$ ]] ||
  die "admin e-mail '${ADMIN_EMAIL:-}' is not an e-mail address"
[[ " $SUPPORTED_ODOO_VERSIONS " == *" $ODOO_VERSION "* ]] || die "unsupported Odoo version $ODOO_VERSION (supported: $SUPPORTED_ODOO_VERSIONS)"
set_state DB_NAME "$DB_NAME"

# --- OS ---------------------------------------------------------------------
. /etc/os-release
[ "$ID" = ubuntu ] || die "this installer needs Ubuntu, found $PRETTY_NAME"
dpkg --compare-versions "$VERSION_ID" ge 24.04 || die "this installer needs Ubuntu 24.04 or later, found $PRETTY_NAME"
arch=$(dpkg --print-architecture)
[ -n "${WKHTMLTOX_SHA1[$arch]:-}" ] || die "unsupported architecture $arch"
log "Provisioning Odoo $ODOO_VERSION on $PRETTY_NAME ($arch)"

# --- Users with fixed UIDs (files on the volumes keep their owner) ------------
ensure_user() {
  local name=$1 uid=$2 home=$3 shell=$4
  if ! getent group "$name" > /dev/null; then
    if getent group "$uid" > /dev/null; then groupadd --system "$name"; else groupadd --system --gid "$uid" "$name"; fi
  fi
  if ! id "$name" > /dev/null 2>&1; then
    if getent passwd "$uid" > /dev/null; then
      useradd --system --gid "$name" --home-dir "$home" --no-create-home --shell "$shell" "$name"
    else
      useradd --system --uid "$uid" --gid "$name" --home-dir "$home" --no-create-home --shell "$shell" "$name"
    fi
  fi
}
ensure_user odoo "$ODOO_UID" "$ODOO_DATA" /usr/sbin/nologin
ensure_user postgres "$PG_UID" /var/lib/postgresql /bin/bash

# --- Base packages -----------------------------------------------------------
apt-get update -q
"${APT_INSTALL[@]}" ca-certificates curl gnupg iproute2 locales openssl nginx certbot \
  unattended-upgrades python3 python3-pip xz-utils fonts-noto-cjk node-less \
  python3-magic python3-markdown2 python3-num2words python3-odf python3-pdfminer python3-phonenumbers \
  python3-pyldap python3-qrcode python3-renderpm python3-setuptools python3-slugify \
  python3-vobject python3-watchdog python3-xlrd python3-xlwt
locale-gen en_US.UTF-8 > /dev/null

# --- PostgreSQL from the official PGDG repository -----------------------------
install -d /usr/share/postgresql-common/pgdg
if [ ! -s /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc ]; then
  curl -fsSL -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc \
    https://www.postgresql.org/media/keys/ACCC4CF8.asc
fi
echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" \
  > /etc/apt/sources.list.d/pgdg.list
apt-get update -q
if [ -z "${PG_MAJOR:-}" ]; then
  PG_MAJOR=$(apt-cache search --names-only '^postgresql-[0-9]+$' | awk '{print $1}' | sed 's/postgresql-//' | sort -n | tail -1)
  [ -n "$PG_MAJOR" ] || die "cannot find any postgresql-N package in PGDG"
  set_state PG_MAJOR "$PG_MAJOR"
fi
log "Installing PostgreSQL $PG_MAJOR"
# An existing /etc/postgresql/N/main (volume) stops postgresql-common from creating a new cluster.
"${APT_INSTALL[@]}" "postgresql-$PG_MAJOR" "postgresql-client-$PG_MAJOR" postgresql-client
chown -R postgres:postgres /var/lib/postgresql "/etc/postgresql/$PG_MAJOR"
chmod 700 "/var/lib/postgresql/$PG_MAJOR/main"
# Odoo is stopped while Postgres restarts, so crons don't fail mid-transaction.
systemctl stop odoo 2> /dev/null || true
"$JPS_DIR/tune-postgres.sh" --restart
systemctl enable --quiet "postgresql@${PG_MAJOR}-main"

if [ "$(psql_admin -d postgres -c "SELECT 1 FROM pg_roles WHERE rolname = 'odoo'")" != 1 ]; then
  psql_admin -d postgres -c "CREATE ROLE odoo LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE"
fi
# Never superuser: that is what COPY ... PROGRAM attacks rely on.
psql_admin -d postgres -c "ALTER ROLE odoo NOSUPERUSER NOCREATEDB NOCREATEROLE"

# --- wkhtmltopdf (patched Qt build, same as the official images) ---------------
if ! dpkg -s wkhtmltox 2> /dev/null | grep -q "^Version: 1:${WKHTMLTOX_VERSION}"; then
  deb="$DEB_DIR/wkhtmltox_${WKHTMLTOX_VERSION}.jammy_${arch}.deb"
  mkdir -p "$DEB_DIR"
  if [ ! -s "$deb" ]; then
    curl -fsSL --retry 3 -o "$deb.tmp" \
      "https://github.com/wkhtmltopdf/packaging/releases/download/${WKHTMLTOX_VERSION}/wkhtmltox_${WKHTMLTOX_VERSION}.jammy_${arch}.deb"
    mv "$deb.tmp" "$deb"
  fi
  echo "${WKHTMLTOX_SHA1[$arch]}  $deb" | sha1sum -c --quiet - || { rm -f "$deb"; die "wkhtmltox checksum mismatch"; }
  "${APT_INSTALL[@]}" "$deb"
fi

# --- Odoo ---------------------------------------------------------------------
# The exact .deb in use is kept on the /opt/odoo volume: a redeploy reinstalls the
# same build, and update-odoo.sh can roll back to it.
if [ -z "${ODOO_DEB:-}" ] || [ ! -s "${ODOO_DEB:-}" ]; then
  ODOO_DEB=$(download_odoo_deb "$ODOO_VERSION" "${ODOO_BUILD:-latest}")
  set_state ODOO_DEB "$ODOO_DEB"
fi
installed=$(dpkg-query -W -f '${Version}' odoo 2> /dev/null || true)
wanted=$(dpkg-deb -f "$ODOO_DEB" Version)
if [ "$installed" != "$wanted" ]; then
  log "Installing Odoo $wanted"
  # Keep the package from starting Odoo with its default config during install.
  printf '#!/bin/sh\nexit 101\n' > /usr/sbin/policy-rc.d
  chmod +x /usr/sbin/policy-rc.d
  "${APT_INSTALL[@]}" --allow-downgrades "$ODOO_DEB" || { rm -f /usr/sbin/policy-rc.d; die "Odoo package install failed"; }
  rm -f /usr/sbin/policy-rc.d
fi
apt-mark hold odoo wkhtmltox > /dev/null

mkdir -p "$ADDONS_DIR" "$ODOO_DATA" /var/log/odoo "$BACKUP_DIR"
chown odoo:odoo "$ADDONS_DIR" /var/log/odoo
[ "$(stat -c %U "$ODOO_DATA")" = odoo ] || chown -R odoo:odoo "$ODOO_DATA"
chmod 700 "$BACKUP_DIR"

# Master password: random and never shown. The database manager is disabled anyway.
if [ -z "${ADMIN_PASSWD_HASH:-}" ]; then
  hash=$(python3 -c 'import secrets
from passlib.context import CryptContext
print(CryptContext(schemes=["pbkdf2_sha512"]).hash(secrets.token_urlsafe(32)))')
  set_state ADMIN_PASSWD_HASH "$hash"
fi

mkdir -p /etc/systemd/system/odoo.service.d
cat > /etc/systemd/system/odoo.service.d/10-jps.conf << EOF
# Generated by /opt/odoo/jps/install.sh
[Service]
ExecStartPre=+${JPS_DIR}/write-odoo-conf.sh
Restart=always
RestartSec=5
LimitNOFILE=65536
TimeoutStopSec=60
EOF

# --- Backups: daily at night, 7 days kept on the backup volume -----------------
cat > /etc/systemd/system/odoo-backup.service << EOF
[Unit]
Description=Odoo database and filestore backup
After=postgresql.service

[Service]
Type=oneshot
ExecStart=${JPS_DIR}/backup.sh --tag daily
EOF
cat > /etc/systemd/system/odoo-backup.timer << 'EOF'
[Unit]
Description=Daily Odoo backup

[Timer]
OnCalendar=*-*-* 02:30
RandomizedDelaySec=30m
Persistent=true

[Install]
WantedBy=timers.target
EOF

# --- Automatic security updates (OS, nginx, Postgres minor releases) -----------
# Odoo and wkhtmltopdf are held: they only change through update-odoo.sh.
cat > /etc/apt/apt.conf.d/52odoo-jps << 'EOF'
// Generated by /opt/odoo/jps/install.sh
Unattended-Upgrade::Origins-Pattern {
    "origin=${distro_id},archive=${distro_codename}-security";
    "origin=${distro_id},archive=${distro_codename}-updates";
    "origin=apt.postgresql.org,archive=${distro_codename}-pgdg";
};
Unattended-Upgrade::Package-Blacklist { "odoo"; "wkhtmltox"; };
Unattended-Upgrade::Automatic-Reboot "false";
EOF
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- Let's Encrypt renewal hook (the certificates themselves are on a volume) ---
mkdir -p /etc/letsencrypt/renewal-hooks/deploy
cat > /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh << 'EOF'
#!/bin/sh
nginx -t -q && systemctl reload nginx
EOF
chmod +x /etc/letsencrypt/renewal-hooks/deploy/reload-nginx.sh

systemctl daemon-reload
"$JPS_DIR/write-nginx.sh"
systemctl enable --quiet odoo nginx odoo-backup.timer certbot.timer unattended-upgrades
systemctl start odoo-backup.timer certbot.timer

if db_exists; then
  systemctl restart odoo
  wait_odoo 240 || die "Odoo did not come up; see /var/log/odoo/odoo-server.log"
  log "Odoo $wanted is up with database $DB_NAME"
else
  log "Odoo $wanted installed; database $DB_NAME not created yet (run init-db.sh)"
fi
