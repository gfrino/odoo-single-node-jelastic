#!/usr/bin/env bash
# Provisions the backup storage node. Idempotent: first install and after every
# redeploy (fresh OS image, same /srv/odoo-backups volume).

. "$(dirname "$(readlink -f "$0")")/common.sh"

. /etc/os-release
[ "$ID" = ubuntu ] || die "this installer needs Ubuntu, found $PRETTY_NAME"
log "Provisioning backup storage on $PRETTY_NAME"

apt-get update -q
apt-get install -y -q --no-install-recommends restic openssh-server openssh-sftp-server iproute2 openssl python3 unattended-upgrades ca-certificates

mkdir -p "$CLIENTS" "$KEYS" "$REGISTRY"
chown root:root "$BASE" "$CLIENTS" "$KEYS"
chmod 755 "$BASE" "$CLIENTS" "$KEYS"
chmod 700 "$REGISTRY"

getent group "$GROUP" > /dev/null || groupadd --gid "$GROUP_GID" "$GROUP"

# Re-create the client users from the registry (after a redeploy /etc/passwd is new).
for f in "$REGISTRY"/*.env; do
  [ -e "$f" ] || continue
  # shellcheck disable=SC1090
  . "$f"
  if ! id "$CLIENT_USER" > /dev/null 2>&1; then
    useradd --uid "$CLIENT_UID" --gid "$GROUP" --home-dir / --no-create-home \
      --shell /usr/sbin/nologin "$CLIENT_USER"
    log "Re-created user $CLIENT_USER"
  fi
done

# The Odoo environments pin this node's SSH host keys. A redeploy brings a fresh image
# with new keys, so keep them on the volume and put them back.
HOSTKEYS=$BASE/.ssh-host-keys
mkdir -p "$HOSTKEYS"
chmod 700 "$HOSTKEYS"
if compgen -G "$HOSTKEYS/ssh_host_*_key" > /dev/null; then
  cp -a "$HOSTKEYS"/ssh_host_* /etc/ssh/
else
  cp -a /etc/ssh/ssh_host_* "$HOSTKEYS"/
fi

# SFTP-only access for the clients: chrooted, key only, no forwarding, no TTY.
# The block goes at the end of sshd_config so it cannot capture global settings.
cfg=/etc/ssh/sshd_config
tmp=$(mktemp)
sed "/^${SSHD_MARK_BEGIN//\//\\/}\$/,/^${SSHD_MARK_END}\$/d" "$cfg" > "$tmp"
cat >> "$tmp" << EOF
$SSHD_MARK_BEGIN
Match Group $GROUP
    ChrootDirectory $CLIENTS/%u
    ForceCommand internal-sftp -d /repo
    AuthorizedKeysFile $KEYS/%u
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    AllowTcpForwarding no
    AllowAgentForwarding no
    X11Forwarding no
    PermitTunnel no
    PermitTTY no
$SSHD_MARK_END
EOF
if ! cmp -s "$tmp" "$cfg"; then
  cp -a "$cfg" "$cfg.bak.$(date +%s)"
  cat "$tmp" > "$cfg"
fi
rm -f "$tmp"
# Ubuntu 24.04 starts sshd on demand (ssh.socket): its runtime directory may not exist yet.
mkdir -p /run/sshd
sshd -t || die "sshd configuration test failed"
systemctl enable --quiet ssh 2> /dev/null || true
systemctl reload-or-restart ssh

cat > /etc/apt/apt.conf.d/20auto-upgrades << 'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

log "Backup storage ready ($(ls "$REGISTRY" | grep -c '\.env$' || true) clients)"
