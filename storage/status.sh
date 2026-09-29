#!/usr/bin/env bash
# One-screen summary of the backup storage: disk, and per client the snapshots.

. "$(dirname "$(readlink -f "$0")")/common.sh"

echo "Disk: $(df -h --output=used,size,pcent "$BASE" | tail -1 | awk '{print $1 " used of " $2 " (" $3 ")"}')"
echo
printf '%-28s %-10s %-18s %s\n' "Environment" "Snapshots" "Last backup (UTC)" "Size"
for f in "$REGISTRY"/*.env; do
  [ -e "$f" ] || { echo "(no clients yet)"; break; }
  # shellcheck disable=SC1090
  . "$f"
  dir=$CLIENTS/$CLIENT_USER
  size=$(du -sh "$dir/repo" 2> /dev/null | cut -f1)
  count=0 last=-
  if [ -f "$dir/repo/config" ]; then
    read -r count last < <(RESTIC_PASSWORD_FILE=$dir/password restic -r "$dir/repo" snapshots --json --no-lock 2> /dev/null |
      python3 -c 'import json,sys; s=json.load(sys.stdin) or []; print(len(s), max((x["time"][:16].replace("T","_") for x in s), default="-"))' ||
      echo "? ?")
  fi
  printf '%-28s %-10s %-18s %s\n' "$CLIENT_REPO" "$count" "${last/_/ }" "$size"
done
