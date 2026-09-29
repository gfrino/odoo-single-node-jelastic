#!/usr/bin/env bash
# Prints, as JSON, the installed PostgreSQL major and the newer ones available in PGDG.
# Used by the "Upgrade PostgreSQL" form of the add-on to fill its drop-down.
# Output: {"installed": "18", "available": ["19"]}

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

# Refresh only the PGDG list: quicker than a full apt-get update.
apt-get update -qq -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/pgdg.list \
  -o Dir::Etc::sourceparts=- -o APT::Get::List-Cleanup=0 > /dev/null 2>&1 || true

available=$(apt-cache search --names-only '^postgresql-[0-9]+$' | awk '{print $1}' | sed 's/postgresql-//' |
  awk -v cur="${PG_MAJOR:-0}" '$1 > cur' | sort -n | tr '\n' ' ')

python3 - "${PG_MAJOR:-}" "$available" << 'PY'
import json, sys
print(json.dumps({"installed": sys.argv[1], "available": sys.argv[2].split()}))
PY
