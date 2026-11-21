#!/usr/bin/env bash
# Applies to an existing installation what newer scripts need, without the full
# installer and without restarting anything. Idempotent and quick.
# Runs after "Update scripts", before every nightly backup (so installations with an
# older add-on catch up on their own), and at the end of install.sh.
# Changes that need an Odoo restart (e.g. memory limits) apply at the next restart.

. "$(dirname "$(readlink -f "$0")")/common.sh"

# An empty, commented odoo.local.conf, so the place for local settings is visible.
# Never overwritten once it exists.
if [ ! -e "$ODOO_LOCAL_CONF" ]; then
  cat > "$ODOO_LOCAL_CONF" << 'EOF'
; Local Odoo settings for this node.
;
; /etc/odoo/odoo.conf is generated again on every Odoo start by
; /opt/odoo/jps/write-odoo-conf.sh (workers and limits follow the node's size), so
; changes made there are lost. Every option written below under [options] replaces
; the generated value instead. Apply with: systemctl restart odoo
; addons_path set here replaces the automatic one entirely.

[options]
; Examples (remove the leading ";" to use one):
;workers = 3
;max_cron_threads = 1
;limit_time_real = 1200
;log_level = warn
;smtp_server = mail.example.com
;smtp_port = 587
;smtp_ssl = starttls
EOF
  chown odoo:odoo "$ODOO_LOCAL_CONF" 2> /dev/null || true
  chmod 640 "$ODOO_LOCAL_CONF"
fi

"$JPS_DIR/remote-backup.sh" install-timer
"$JPS_DIR/optimize-node.sh" > /dev/null
# Environment domain on the public IP without a certificate ("Not secure"): retry it.
"$JPS_DIR/cert-env.sh" check || true
systemctl daemon-reload
md5sum "$JPS_DIR"/*.sh 2> /dev/null | md5sum | cut -c1-12 > /etc/odoo/scripts-applied
log "Post-update applied (scripts $(cat /etc/odoo/scripts-applied))"
