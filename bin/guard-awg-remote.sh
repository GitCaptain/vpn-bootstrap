#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only snapshot of AmneziaWG container identity/health/ports.
# Caller compares output before and after changes to Xray.
[[ "$(id -u)" == 0 ]] || { echo "ERROR: root required" >&2; exit 1; }
if ! command -v docker >/dev/null || ! docker info >/dev/null 2>&1; then
    echo "NONE"
    exit 0
fi
mapfile -t containers < <(docker ps -a --format '{{.Names}}' |
    grep -E '^amnezia-awg([0-9-]*)?$' | LC_ALL=C sort || true)
if (( ${#containers[@]} == 0 )); then
    echo "NONE"
    exit 0
fi
for name in "${containers[@]}"; do
    # No credentials or container environment variables included.
    docker inspect -f \
        '{{.Name}} {{.Id}} {{.State.Running}} {{.State.StartedAt}} {{.RestartCount}} {{json .HostConfig.PortBindings}}' \
        "$name"
done
