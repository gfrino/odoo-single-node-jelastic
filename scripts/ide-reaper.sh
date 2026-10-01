#!/usr/bin/env bash
# Stops remote IDE servers (Antigravity, VS Code, Cursor, Windsurf, VSCodium) that keep
# running after the editor disconnected. Runs every 5 minutes (odoo-ide-reaper.timer):
#   - while they run, marks them as the first thing the kernel kills if memory runs out,
#     so Odoo and PostgreSQL are never the victims;
#   - stops them once no SSH session has been open for IDE_IDLE_MINUTES (default 20).
# Nothing happens while someone is connected over SSH.

. "$(dirname "$(readlink -f "$0")")/common.sh"
load_state

idle_minutes=${IDE_IDLE_MINUTES:-20}
# Only programs started from an IDE server directory (argv[0], possibly behind sh), not
# any command line that merely mentions it (e.g. someone's grep).
pattern='^((ba)?sh )?/[^ ]*/\.(antigravity-ide-server|vscode-server|cursor-server|windsurf-server|vscodium-server)/'
stamp=/run/odoo-ide-reaper.last-ssh

pids=$(pgrep -f -- "$pattern" || true)
[ -n "$pids" ] || { rm -f "$stamp"; exit 0; }

for p in $pids; do
  echo 1000 > "/proc/$p/oom_score_adj" 2> /dev/null || true
done

# Inbound SSH sessions (through the Jelastic SSH gate or direct).
if [ "$(ss -tnH state established '( sport = :22 )' | wc -l)" -gt 0 ]; then
  date +%s > "$stamp"
  exit 0
fi

[ -s "$stamp" ] || date +%s > "$stamp"
idle=$(($(date +%s) - $(cat "$stamp")))
if ((idle >= idle_minutes * 60)); then
  mem_before=$(free -m | awk '/^Mem:/ {print $3}')
  pkill -f -- "$pattern" || true
  sleep 2
  pkill -9 -f -- "$pattern" || true
  rm -f "$stamp"
  log "Stopped idle IDE servers (no SSH session for $((idle / 60)) min): RAM used ${mem_before} -> $(free -m | awk '/^Mem:/ {print $3}') MB"
fi
