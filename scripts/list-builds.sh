#!/usr/bin/env bash
# Prints, as JSON, the Odoo builds available for the installed major version.
# Used by the "Update Odoo" form of the add-on to fill its drop-down.
# Output: {"series": "20.0", "installed": "20260928", "builds": ["20260928", "20260927", ...]}

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

installed=$(dpkg-query -W -f '${Version}' odoo 2> /dev/null || true)
builds=$(curl -fsSL --max-time 20 "https://nightly.odoo.com/${ODOO_VERSION}/nightly/deb/" |
  grep -o "odoo_${ODOO_VERSION}\.[0-9]\{8\}_all\.deb" | sed "s/^odoo_${ODOO_VERSION}\.//; s/_all\.deb$//" |
  sort -ru | head -30 || true)

python3 - "$ODOO_VERSION" "${installed#"$ODOO_VERSION".}" "$builds" << 'PY'
import json, sys
series, installed, builds = sys.argv[1], sys.argv[2], sys.argv[3].split()
print(json.dumps({"series": series, "installed": installed, "builds": builds}))
PY
