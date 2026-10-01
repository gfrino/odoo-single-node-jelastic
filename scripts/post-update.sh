#!/usr/bin/env bash
# Applies to an existing installation what newer scripts need, without the full
# installer and without restarting anything. Idempotent and quick.
# Runs after "Update scripts", before every nightly backup (so installations with an
# older add-on catch up on their own), and at the end of install.sh.
# Changes that need an Odoo restart (e.g. memory limits) apply at the next restart.

. "$(dirname "$(readlink -f "$0")")/common.sh"

"$JPS_DIR/remote-backup.sh" install-timer
"$JPS_DIR/optimize-node.sh" > /dev/null
systemctl daemon-reload
md5sum "$JPS_DIR"/*.sh 2> /dev/null | md5sum | cut -c1-12 > /etc/odoo/scripts-applied
log "Post-update applied (scripts $(cat /etc/odoo/scripts-applied))"
