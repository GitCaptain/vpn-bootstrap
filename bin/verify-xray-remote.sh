#!/usr/bin/env bash
set -Eeuo pipefail
# Run as root on the VPS after vpn-bootstrap.sh completed successfully.
[[ "$(id -u)" == 0 ]] || { echo "ERROR: root required" >&2; exit 1; }
test -x /usr/local/sbin/vpn-status ||
    { echo "ERROR: vpn-status missing" >&2; exit 1; }
docker inspect xray-reality >/dev/null ||
    { echo "ERROR: Xray container missing" >&2; exit 1; }
[[ "$(docker inspect -f '{{.State.Running}}' xray-reality)" == true ]] ||
    { echo "ERROR: Xray container is not running" >&2; exit 1; }
port="$(jq -r '.xray_port' /opt/vpn-stack/state.json)"
[[ "$port" =~ ^[0-9]+$ ]] ||
    { echo "ERROR: missing configured port" >&2; exit 1; }
nc -4 -z -w 2 127.0.0.1 "$port" ||
    { echo "ERROR: Xray published TCP port is unavailable" >&2; exit 1; }
/usr/local/sbin/vpn-status
echo "Xray readiness verified (container and localhost TCP)."
echo "Note: full REALITY client handshake still requires an external client test."
