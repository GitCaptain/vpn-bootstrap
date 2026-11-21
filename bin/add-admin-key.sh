#!/usr/bin/env bash
set -Eeuo pipefail
# Add another workstation's *public* SSH key to the existing vpnadmin account.
# Invoked on the workstation that already has a working vpnadmin private key.
usage() {
    echo "Usage: bash bin/add-admin-key.sh SERVER CURRENT_ADMIN_PRIVATE_KEY NEW_WORKSTATION_PUBLIC_KEY [SSH_PORT=22]" >&2
    exit 2
}
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: bash bin/add-admin-key.sh VPS_HOST CURRENT_VPNADMIN_PRIVATE_KEY NEW_DEVICE_PUBLIC_KEY [SSH_PORT=22]"
    echo "Add an additional workstation's public SSH key to vpnadmin, preserving existing keys."
    echo "No private key is copied to the VPS; caller must already be able to log in as vpnadmin."
    exit 0
fi
(( $# == 3 || $# == 4 )) || usage
SERVER="$1"
CURRENT_KEY="$2"
NEW_PUBKEY_FILE="$3"
PORT="${4:-22}"
[[ "$SERVER" =~ ^[A-Za-z0-9.:-]+$ && "$SERVER" != -* ]] || usage
[[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$PORT <= 65535 )) || usage
[[ -r "$CURRENT_KEY" && -r "$NEW_PUBKEY_FILE" ]] || usage
command -v ssh-keygen >/dev/null || { echo "ssh-keygen missing" >&2; exit 2; }
ssh-keygen -lf "$NEW_PUBKEY_FILE" >/dev/null ||
    { echo "Invalid public SSH key" >&2; exit 2; }
new_key="$(awk 'NF{n++;line=$0}END{if(n==1)print line;else exit 1}' "$NEW_PUBKEY_FILE")" ||
    { echo "Expected exactly one public SSH key" >&2; exit 2; }
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
REMOTE="$SCRIPT_DIR/bin/ensure-vpnadmin-remote.sh"
[[ -f "$REMOTE" ]] || { echo "Missing $REMOTE" >&2; exit 2; }
printf -v escaped_key '%q' "$new_key"
ssh -T -p "$PORT" -o BatchMode=yes -o IdentitiesOnly=yes \
    -o StrictHostKeyChecking=ask -o ClearAllForwardings=yes \
    -o ControlMaster=no -o ControlPath=none \
    -i "$CURRENT_KEY" "vpnadmin@$SERVER" \
    "exec sudo -n bash -s -- $escaped_key" < "$REMOTE"
echo "New public key was added (or was already present)."
echo "Test a fresh vpnadmin SSH login from the second workstation."
