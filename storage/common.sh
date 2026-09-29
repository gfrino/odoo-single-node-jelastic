#!/usr/bin/env bash
# Shared paths and helpers for the backup storage node (backup-storage.jps).
#
# Layout on the /srv/odoo-backups volume:
#   clients/<user>/          root-owned chroot of one Odoo environment (SFTP only)
#   clients/<user>/repo/     its restic repository (owned by the client user)
#   clients/<user>/password  restic password, readable only by the client user (it
#                            downloads it when connecting) and root (status, recovery)
#   keys/<user>              the client's SSH public key (AuthorizedKeysFile)
#   registry/<user>.env      UID and repository name: users are re-created from it after
#                            a redeploy, which gives a fresh /etc/passwd
#   .ssh-host-keys/          this node's SSH host keys, restored after a redeploy (the
#                            Odoo environments pin them)

set -Eeuo pipefail

BASE=/srv/odoo-backups
CLIENTS=$BASE/clients
KEYS=$BASE/keys
REGISTRY=$BASE/registry
SCRIPTS=/opt/odoo-backup
GROUP=odoobk
GROUP_GID=9500
LOG_FILE=/var/log/odoo-backup.log
SSHD_MARK_BEGIN="# BEGIN odoo-backup (managed by /opt/odoo-backup/setup.sh)"
SSHD_MARK_END="# END odoo-backup"

export DEBIAN_FRONTEND=noninteractive

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "$LOG_FILE" >&2; }
die() { log "ERROR: $*"; exit 1; }
trap 'log "ERROR: ${BASH_SOURCE[0]##*/}:${LINENO}: \"${BASH_COMMAND}\" exited with $?"' ERR

[ "$(id -u)" -eq 0 ] || { echo "must run as root" >&2; exit 1; }

# Repository name (normally the Odoo environment name) -> system user name.
user_for_repo() {
  local repo=$1
  [[ "$repo" =~ ^[a-z0-9][a-z0-9-]{0,40}$ ]] || die "invalid repository name: $repo"
  echo "odoobk-${repo}"
}
