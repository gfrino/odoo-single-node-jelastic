#!/usr/bin/env bash
# Starts a test "node" with the same volumes the manifest declares.
# Usage: [PLATFORM=linux/amd64] tests/run-node.sh <name> [volume-prefix]
# Re-running with the same volume prefix after removing the container simulates a
# Jelastic redeploy: fresh OS image, same volumes.
set -euo pipefail
name=$1
prefix=${2:-$1}
repo=$(cd "$(dirname "$0")/.." && pwd)
platform=${PLATFORM:-}
tag=odoo-jps-test${platform:+-${platform//\//-}}
docker build -q ${platform:+--platform "$platform"} -t "$tag" "$repo/tests" > /dev/null
vols=()
for p in etc-odoo:/etc/odoo opt-odoo:/opt/odoo var-lib-odoo:/var/lib/odoo \
         pg-data:/var/lib/postgresql pg-conf:/etc/postgresql \
         letsencrypt:/etc/letsencrypt backups:/var/backups/odoo; do
  vols+=(-v "${prefix}-${p%%:*}:${p#*:}")
done
docker run -d --name "$name" --privileged --cgroupns=host --tmpfs /run --tmpfs /run/lock \
  -v /sys/fs/cgroup:/sys/fs/cgroup:rw "${vols[@]}" -p 0:80 ${platform:+--platform "$platform"} "$tag" > /dev/null
# Scripts are copied (as the manifest's onInstall does), not bind-mounted.
docker exec "$name" mkdir -p /opt/odoo/jps
docker cp "$repo/scripts/." "$name:/opt/odoo/jps/"
echo "$name up"
