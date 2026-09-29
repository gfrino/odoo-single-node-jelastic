#!/usr/bin/env bash
# Registers (or re-keys) an Odoo environment on this backup storage.
# Usage: add-client.sh <repository> '<ssh public key>'
# Creates the chrooted SFTP user, its repository directory and, for a new repository,
# a random restic password. Existing repositories keep their data and password: that is
# how a new Odoo environment takes over the backups of one that was lost.
# Prints JSON: {"user": ..., "host": <internal IP>, "host_keys": [...], "new": true|false}

. "$(dirname "$(readlink -f "$0")")/common.sh"

repo=${1:?usage: add-client.sh <repository> <ssh public key>}
pubkey=${2:?missing ssh public key}
user=$(user_for_repo "$repo")
[[ "$pubkey" =~ ^ssh-ed25519\ [A-Za-z0-9+/=]+(\ .*)?$ ]] || die "not an ed25519 public key"

new=false
if ! id "$user" > /dev/null 2>&1; then
  uid=$((20000 + $(ls "$REGISTRY" | grep -c '\.env$' || true)))
  while getent passwd "$uid" > /dev/null; do uid=$((uid + 1)); done
  useradd --uid "$uid" --gid "$GROUP" --home-dir / --no-create-home --shell /usr/sbin/nologin "$user"
fi
uid=$(id -u "$user")
printf 'CLIENT_USER=%q\nCLIENT_UID=%q\nCLIENT_REPO=%q\n' "$user" "$uid" "$repo" > "$REGISTRY/$user.env"

chroot=$CLIENTS/$user
mkdir -p "$chroot/repo"
chown root:root "$chroot"
chmod 755 "$chroot"
chown "$user:$GROUP" "$chroot/repo"
chmod 700 "$chroot/repo"
if [ ! -s "$chroot/password" ]; then
  new=true
  (umask 077 && openssl rand -base64 32 > "$chroot/password")
fi
# Readable by this client only (and root); each client is chrooted into its own directory.
chown "$user:root" "$chroot/password"
chmod 400 "$chroot/password"

# One key per client; a new Odoo environment taking over replaces the old key.
printf '%s\n' "$pubkey" > "$KEYS/$user"
chown root:root "$KEYS/$user"
chmod 644 "$KEYS/$user"

log "Client $user ready (repository $repo, new=$new)"
python3 - "$user" "$new" << 'PY'
import glob, json, socket, subprocess, sys
user, new = sys.argv[1], sys.argv[2] == "true"
ips = subprocess.run(["ip", "-4", "-o", "addr", "show", "scope", "global"], capture_output=True, text=True).stdout.split()
addrs = [w.split("/")[0] for w in ips if w.count(".") == 3 and "/" in w]
# Jelastic internal network first (10.x), otherwise the first address (e.g. local tests).
host = next((a for a in addrs if a.startswith("10.")), addrs[0] if addrs else None)
keys = [open(f).read().strip() for f in sorted(glob.glob("/etc/ssh/ssh_host_*_key.pub"))]
print(json.dumps({"user": user, "host": host, "host_keys": keys, "new": new}))
PY
