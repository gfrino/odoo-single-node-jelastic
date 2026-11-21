#!/usr/bin/env bash
# Let's Encrypt certificate for the environment domain (<env>.<jelastic-domain>).
# With a public IP the environment domain resolves to the node itself, not to the
# Jelastic resolver and its wildcard certificate: until the node has its own
# certificate, browsers get the self-signed one and show "Not secure".
# Usage:
#   cert-env.sh install   at environment creation: waits for DNS, tries a few times,
#                         then leaves the retries to the timer. Prints a note for the
#                         success message (empty when the certificate is there).
#   cert-env.sh retry     run by odoo-cert-env.timer every 15 minutes
#   cert-env.sh check     run by post-update.sh: starts the timer on environments that
#                         need a certificate and have none (older installs)
#   cert-env.sh status    one line, only while retrying

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

TIMER=odoo-cert-env.timer
CERT=/etc/letsencrypt/live/odoo/fullchain.pem
ISSUE_LOG=/tmp/cert-env-domain.log
# Let's Encrypt allows 5 failed validations per hostname per hour: 15 minutes stays
# below it. After two days without success the timer stops (Add domain still works).
GIVE_UP_SECONDS=$((48 * 3600))

env_domain=${ENV_DOMAIN:-}

# The environment domain is in the certificate the node serves.
covered() {
  [ -s "$CERT" ] &&
    openssl x509 -noout -ext subjectAltName -in "$CERT" 2> /dev/null | grep -qiE "DNS:${env_domain//./\\.}(,|$)"
}

# Every IPv4 address of the environment domain belongs to this node.
points_here() {
  local resolved ours ip
  resolved=$(getent ahostsv4 "$env_domain" 2> /dev/null | awk '{print $1}' | sort -u)
  [ -n "$resolved" ] || return 1
  ours=$(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)
  for ip in $resolved; do
    grep -qxF "$ip" <<< "$ours" || return 1
  done
}

issue() {
  if "$JPS_DIR/ssl.sh" add "$env_domain" > "$ISSUE_LOG" 2>&1; then
    log "Let's Encrypt certificate issued for $env_domain"
    return 0
  fi
  log "Let's Encrypt for $env_domain failed: $(tail -1 "$ISSUE_LOG")"
  return 1
}

write_timer() {
  cat > /etc/systemd/system/odoo-cert-env.service << EOF
[Unit]
Description=Let's Encrypt certificate for the environment domain (retry)
After=network-online.target nginx.service

[Service]
Type=oneshot
ExecStart=$JPS_DIR/cert-env.sh retry
EOF
  cat > /etc/systemd/system/$TIMER << 'EOF'
[Unit]
Description=Retry the Let's Encrypt certificate for the environment domain

[Timer]
OnActiveSec=2min
OnUnitActiveSec=15min

[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
}

start_retries() {
  systemctl is-active --quiet "$TIMER" && return 0
  set_state CERT_ENV_SINCE "$(date +%s)"
  write_timer
  systemctl enable --now --quiet "$TIMER"
  log "Retrying the certificate for $env_domain every 15 minutes"
}

stop_retries() {
  systemctl disable --now --quiet "$TIMER" 2> /dev/null || true
  set_state CERT_ENV_SINCE ""
}

[ -n "$env_domain" ] || { [ "${1:-}" = status ] || log "No environment domain in the state"; exit 0; }

cmd=${1:-status}
case $cmd in
  install)
    # The environment domain moves to the public IP a few seconds to minutes after
    # AttachExtIp; the node's resolver may also still have the old answer cached.
    for _ in $(seq 30); do
      points_here && break
      sleep 10
    done
    for attempt in 1 2 3; do
      if covered || issue; then
        stop_retries
        echo ""
        exit 0
      fi
      if [ "$attempt" -lt 3 ]; then sleep 60; fi
    done
    start_retries
    echo "**Certificate:** Let's Encrypt for ${env_domain} is not issued yet ($(tail -1 "$ISSUE_LOG")). Until it is, the browser shows \"Not secure\". The node retries every 15 minutes for two days; to retry now use **Odoo Manager → Add domain** with ${env_domain}."
    ;;

  retry)
    if covered; then
      stop_retries
      exit 0
    fi
    since=${CERT_ENV_SINCE:-}
    if [[ "$since" =~ ^[0-9]+$ ]] && (($(date +%s) - since > GIVE_UP_SECONDS)); then
      log "No certificate for $env_domain after two days: retries stopped (use Add domain)"
      stop_retries
      exit 0
    fi
    if ! points_here; then
      log "$env_domain does not resolve to this node yet: certificate not requested"
      exit 0
    fi
    issue && stop_retries
    exit 0
    ;;

  check)
    # Only when the environment domain reaches this node directly (public IP):
    # through the Jelastic resolver it already has a valid certificate.
    if ! covered && points_here; then
      start_retries
    fi
    ;;

  status)
    if systemctl is-active --quiet "$TIMER"; then
      echo "$env_domain has no Let's Encrypt certificate yet: retrying every 15 minutes"
    fi
    ;;

  *) die "unknown command: $cmd" ;;
esac
