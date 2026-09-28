#!/usr/bin/env bash
# Let's Encrypt certificate for the custom domains, issued with certbot on this node.
# Usage:
#   ssl.sh add <domain> [<domain>...] [--email you@example.com] [--skip-dns-check]
#   ssl.sh remove <domain> [<domain>...]
#   ssl.sh renew        force a renewal now
#   ssl.sh status
# One certificate ("odoo") covers all the custom domains. Renewal is automatic
# (certbot.timer, twice a day); the deploy hook reloads nginx only if its config is valid.
# The DNS A record of every domain must point to the node's public IP.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

cmd=${1:-status}
shift || true
domains=()
email=${LE_EMAIL:-${ADMIN_EMAIL:-}}
check_dns=1
while [ $# -gt 0 ]; do
  case $1 in
    --email) email=$2; shift 2 ;;
    --skip-dns-check) check_dns=0; shift ;;
    *)
      for d in ${1//,/ }; do
        d=${d,,}
        [[ "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || die "invalid domain: $d"
        domains+=("$d")
      done
      shift
      ;;
  esac
done

public_ips() {
  ip -o addr show scope global | awk '{print $4}' | cut -d/ -f1
}

check_domain_dns() {
  local d=$1 resolved ours
  resolved=$(getent ahostsv4 "$d" | awk '{print $1}' | sort -u)
  [ -n "$resolved" ] || die "$d does not resolve"
  ours=$(public_ips)
  for ip in $resolved; do
    grep -qx "$ip" <<< "$ours" || die "$d resolves to $ip, which is not an IP of this node ($(echo $ours))"
  done
}

issue() {
  local list=("$@") args=()
  [ ${#list[@]} -gt 0 ] || die "no domains"
  [ -n "$email" ] || die "no e-mail for Let's Encrypt (use --email)"
  ((check_dns)) && for d in "${list[@]}"; do check_domain_dns "$d"; done
  for d in "${list[@]}"; do args+=(-d "$d"); done
  mkdir -p "$ACME_ROOT"
  certbot certonly --non-interactive --agree-tos --email "$email" --no-eff-email \
    --webroot -w "$ACME_ROOT" --cert-name odoo --key-type ecdsa "${args[@]}"
  set_state LE_EMAIL "$email"
  set_state DOMAINS "${list[*]}"
  "$JPS_DIR/write-nginx.sh"
  # Prefer the first custom domain; the environment domain only if there is no other.
  local main=${list[0]}
  for d in "${list[@]}"; do
    if [ "$d" != "${ENV_DOMAIN:-}" ]; then main=$d; break; fi
  done
  set_base_url "$main"
}

# Links in e-mails and reports use web.base.url: point it at the main custom domain.
set_base_url() {
  db_exists || return 0
  psql_admin -d "$DB_NAME" -c "UPDATE ir_config_parameter SET value = 'https://$1' WHERE key = 'web.base.url'"
  log "web.base.url set to https://$1"
}

case $cmd in
  add)
    current=(${DOMAINS:-})
    merged=$(printf '%s\n' "${current[@]}" "${domains[@]}" | awk 'NF && !seen[$0]++')
    issue $merged
    ;;
  remove)
    current=(${DOMAINS:-})
    kept=$(printf '%s\n' "${current[@]}" | grep -vxF -f <(printf '%s\n' "${domains[@]}") || true)
    if [ -z "$kept" ]; then
      certbot delete --non-interactive --cert-name odoo || true
      set_state DOMAINS ""
      "$JPS_DIR/write-nginx.sh"
      set_base_url "$ENV_DOMAIN"
    else
      check_dns=0
      issue $kept
    fi
    ;;
  renew)
    certbot renew --force-renewal --cert-name odoo
    ;;
  status)
    echo "Domains: ${DOMAINS:-none}"
    certbot certificates --cert-name odoo 2> /dev/null | grep -E 'Domains|Expiry' || echo "No Let's Encrypt certificate"
    systemctl list-timers certbot.timer --no-pager | sed -n 2p
    ;;
  *) die "unknown command: $cmd" ;;
esac
