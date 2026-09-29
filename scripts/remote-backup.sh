#!/usr/bin/env bash
# Off-node backups to a separate backup environment (backup-storage.jps) with restic
# over SFTP on the Jelastic internal network. Everything is encrypted (AES-256) before
# it leaves this node; identical data is stored once (deduplication).
#
#   remote-backup.sh keygen                      print this node's SSH public key
#   remote-backup.sh connect --host IP --user U --repo R --env E --host-keys 'k1|k2'
#   remote-backup.sh run [--if-configured]       back up now, then apply retention
#   remote-backup.sh snapshots [--json]          list the remote backups
#   remote-backup.sh restore <snapshot-id>       restore database and filestore
#   remote-backup.sh status | disconnect
#
# Configuration and key live on the /etc/odoo volume, so they survive a redeploy.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

RB_DIR=/etc/odoo/remote-backup
RB_CONF=$RB_DIR/config.env
RB_KEY=$RB_DIR/id_ed25519
RB_KNOWN=$RB_DIR/known_hosts
RB_PASS=$RB_DIR/password
RB_LAST=$RB_DIR/last-success
STAGING=$BACKUP_DIR/.remote-staging
# The last 3 always (several manual backups on one day), then 7 daily, 4 weekly, 12 monthly.
KEEP=(--keep-last 3 --keep-daily 7 --keep-weekly 4 --keep-monthly 12)
export RESTIC_CACHE_DIR=/var/cache/restic

load_remote() {
  [ -s "$RB_CONF" ] || return 1
  # shellcheck disable=SC1090
  . "$RB_CONF"
  export RESTIC_REPOSITORY="sftp:${RB_USER}@${RB_HOST}:/repo"
  export RESTIC_PASSWORD_FILE=$RB_PASS
  SFTP_CMD="ssh -i $RB_KEY -o UserKnownHostsFile=$RB_KNOWN -o StrictHostKeyChecking=yes -o BatchMode=yes -o ConnectTimeout=20 -o ServerAliveInterval=30 ${RB_USER}@${RB_HOST} -s sftp"
}

restic_() { restic -o sftp.command="$SFTP_CMD" "$@"; }

# Environments installed before 1.2 have no restic yet.
ensure_restic() {
  command -v restic > /dev/null && command -v sftp > /dev/null && return 0
  log "Installing restic"
  apt-get update -q > /dev/null
  "${APT_INSTALL[@]}" restic openssh-client > /dev/null
}

cmd=${1:-status}
shift || true

case $cmd in
  keygen)
    mkdir -p "$RB_DIR"
    chmod 700 "$RB_DIR"
    [ -s "$RB_KEY" ] || ssh-keygen -q -t ed25519 -N "" -C "odoo-backup@${ENV_DOMAIN:-$(hostname)}" -f "$RB_KEY"
    cat "$RB_KEY.pub"
    ;;

  connect)
    ensure_restic
    host="" user="" repo="" env="" host_keys=""
    while [ $# -gt 0 ]; do
      case $1 in
        --host) host=$2; shift 2 ;;
        --user) user=$2; shift 2 ;;
        --repo) repo=$2; shift 2 ;;
        --env) env=$2; shift 2 ;;
        --host-keys) host_keys=$2; shift 2 ;;
        *) die "unknown option: $1" ;;
      esac
    done
    [[ "$host" =~ ^[0-9.]+$ ]] || die "invalid host: $host"
    [[ "$user" =~ ^odoobk-[a-z0-9-]+$ ]] || die "invalid user: $user"
    [ -n "$host_keys" ] || die "missing --host-keys"
    [ -s "$RB_KEY" ] || die "run keygen first"
    # Pin the storage node's host keys: no trust-on-first-use.
    : > "$RB_KNOWN"
    IFS='|' read -r -a keys <<< "$host_keys"
    for k in "${keys[@]}"; do
      [[ "$k" =~ ^(ssh-ed25519|ecdsa-sha2-nistp[0-9]+|ssh-rsa)\ [A-Za-z0-9+/=]+ ]] || continue
      printf '%s %s\n' "$host" "$(awk '{print $1, $2}' <<< "$k")" >> "$RB_KNOWN"
    done
    [ -s "$RB_KNOWN" ] || die "no valid host key"
    printf 'RB_HOST=%q\nRB_USER=%q\nRB_REPO=%q\nRB_ENV=%q\n' "$host" "$user" "$repo" "$env" > "$RB_CONF"
    chmod 600 "$RB_CONF" "$RB_KNOWN"
    load_remote
    # The restic password is kept on the storage node too (disaster recovery): fetch it.
    tmp=$(mktemp)
    printf 'get /password %s\n' "$tmp" | sftp -q -b - -i "$RB_KEY" -o UserKnownHostsFile="$RB_KNOWN" \
      -o StrictHostKeyChecking=yes -o BatchMode=yes "${RB_USER}@${RB_HOST}" > /dev/null ||
      { rm -f "$tmp"; die "cannot reach the backup environment over SFTP ($RB_USER@$RB_HOST)"; }
    install -m 600 "$tmp" "$RB_PASS"
    rm -f "$tmp"
    if restic_ cat config > /dev/null 2>&1; then
      log "Connected to existing repository $repo on $env ($(restic_ snapshots --json | python3 -c 'import json,sys; print(len(json.load(sys.stdin) or []))') snapshots)"
    else
      restic_ init --repository-version 2 > /dev/null
      log "Repository $repo created on $env"
    fi
    systemctl enable --now odoo-remote-backup.timer > /dev/null 2>&1 || true
    echo "Connected to $env (repository $repo)."
    echo "Encryption password (also kept on the backup environment): $(cat "$RB_PASS")"
    ;;

  run)
    ensure_restic
    if ! load_remote; then
      [ "${1:-}" = --if-configured ] && exit 0
      die "no backup environment connected"
    fi
    db_exists || { log "No database $DB_NAME, nothing to back up"; exit 0; }
    mkdir -p "$STAGING"
    chmod 700 "$STAGING"
    # Uncompressed dump: restic compresses and deduplicates it far better than a
    # compressed one, which changes completely every day.
    log "Remote backup of $DB_NAME to $RB_ENV ($RB_REPO)"
    as_postgres pg_dump -Fc -Z 0 -d "$DB_NAME" > "$STAGING/$DB_NAME.dump"
    paths=("$STAGING/$DB_NAME.dump" "$STATE_FILE")
    [ -d "$ODOO_DATA/filestore/$DB_NAME" ] && paths+=("$ODOO_DATA/filestore/$DB_NAME")
    restic_ backup --no-scan --tag "odoo-${ODOO_VERSION}" --tag "db-${DB_NAME}" --host "${ENV_DOMAIN:-$(hostname)}" \
      "${paths[@]}" > /tmp/restic-backup.log 2>&1 || { cat /tmp/restic-backup.log >&2; rm -f "$STAGING/$DB_NAME.dump"; die "restic backup failed"; }
    rm -f "$STAGING/$DB_NAME.dump"
    restic_ forget --prune "${KEEP[@]}" > /tmp/restic-forget.log 2>&1 || log "WARNING: retention failed (see /tmp/restic-forget.log)"
    # Weekly integrity check of the repository structure.
    if [ "$(date +%u)" = 7 ]; then
      restic_ check > /tmp/restic-check.log 2>&1 && log "Repository check OK" || log "WARNING: restic check failed (see /tmp/restic-check.log)"
    fi
    date '+%F %T' > "$RB_LAST"
    log "Remote backup done: $(grep -E '^Added to the repository' /tmp/restic-backup.log | sed 's/Added to the repository: //')"
    ;;

  snapshots)
    load_remote || die "no backup environment connected"
    if [ "${1:-}" = --json ]; then
      restic_ snapshots --json | python3 -c '
import json, sys
snaps = json.load(sys.stdin) or []
snaps.sort(key=lambda s: s["time"], reverse=True)  # full timestamp, newest first
print(json.dumps([{"id": s["short_id"], "time": s["time"][:19].replace("T", " "), "tags": s.get("tags") or [],
                   "host": s.get("hostname", "")} for s in snaps]))'
    else
      restic_ snapshots --compact
    fi
    ;;

  restore)
    id=${1:?usage: remote-backup.sh restore <snapshot-id>}
    [[ "$id" =~ ^[0-9a-f]{8,64}$ ]] || die "invalid snapshot id: $id"
    load_remote || die "no backup environment connected"
    target=$STAGING/restore-$id
    rm -rf "$target"
    mkdir -p "$target"
    log "Downloading snapshot $id from $RB_ENV"
    restic_ restore "$id" --target "$target" > /tmp/restic-restore.log 2>&1 ||
      { cat /tmp/restic-restore.log >&2; die "restic restore failed"; }
    dump=$(find "$target" -path "*/.remote-staging/*.dump" | head -1)
    [ -s "$dump" ] || die "no database dump in snapshot $id"
    src_db=$(basename "$dump" .dump)
    # Hand over to restore.sh in the format of a local backup.
    base="$BACKUP_DIR/${DB_NAME}-$(date +%Y%m%d-%H%M%S)-remote-$id"
    mv "$dump" "$base.dump"
    fs=$(find "$target" -type d -path "*/filestore/$src_db" | head -1)
    if [ -n "$fs" ]; then
      tar -C "$(dirname "$fs")" -cf "$base.filestore.tar" --transform "s|^$src_db|$DB_NAME|" "$src_db"
    fi
    rm -rf "$target"
    "$JPS_DIR/backup.sh" --tag pre-remote-restore > /dev/null
    "$JPS_DIR/restore.sh" "$base.dump"
    # The snapshot stays on the backup environment: no need to keep this copy.
    rm -f "$base.dump" "$base.filestore.tar"
    # A snapshot from another (lost) environment carries its address: links in e-mails
    # and reports must point to this one.
    main=${ENV_DOMAIN:-}
    for d in ${DOMAINS:-}; do
      if [ "$d" != "${ENV_DOMAIN:-}" ]; then main=$d; break; fi
    done
    if [ -n "$main" ]; then
      psql_admin -d "$DB_NAME" -c "UPDATE ir_config_parameter SET value = 'https://$main' WHERE key = 'web.base.url'"
      log "web.base.url set to https://$main"
    fi
    log "Snapshot $id restored"
    ;;

  status)
    if load_remote; then
      echo "Backup environment: $RB_ENV (repository $RB_REPO, $RB_USER@$RB_HOST)"
      echo "Last remote backup: $(cat "$RB_LAST" 2> /dev/null || echo never)"
    else
      echo "Backup environment: not connected"
    fi
    ;;

  disconnect)
    rm -f "$RB_CONF" "$RB_PASS" "$RB_KNOWN" "$RB_LAST"
    systemctl disable --now odoo-remote-backup.timer > /dev/null 2>&1 || true
    log "Backup environment disconnected (the backups stay on it)"
    ;;

  *) die "unknown command: $cmd" ;;
esac
