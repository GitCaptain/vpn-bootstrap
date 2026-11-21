#!/usr/bin/env bash
set -Eeuo pipefail
# Run vpn-bootstrap.sh on a VPS from a local checkout using SSH.
# Usage: ./bin/setup-xray-remote.sh SERVER ADMIN PRIVATE_KEY XRAY_PUBLIC_KEY [PORT] [-- EXTRA_FLAGS...]
# PRIVATE_KEY may be "-" to use regular SSH agent/interactive authentication.
if (( $# < 4 )); then
    echo "Usage: $0 SERVER ADMIN PRIVATE_KEY XRAY_PUBLIC_KEY [PORT] [-- BOOTSTRAP_FLAGS...]" >&2
    exit 2
fi
SERVER="$1"; ADMIN="$2"; ADMIN_KEY="$3"; XRAY_PUB="$4"; shift 4
PORT=22
if (( $# > 0 )) && [[ "$1" =~ ^[0-9]+$ ]]; then PORT="$1"; shift; fi
if (( $# > 0 )); then
    [[ "$1" == "--" ]] || { echo "Extra bootstrap flags must follow --" >&2; exit 2; }
    shift
fi
[[ "$SERVER" =~ ^[a-zA-Z0-9.:-]+$ && "$SERVER" != -* ]] || { echo "Invalid server address" >&2; exit 2; }
[[ "$ADMIN" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Invalid SSH admin user" >&2; exit 2; }
[[ "$PORT" =~ ^[0-9]+$ ]] && (( 10#$PORT >= 1 && 10#$PORT <= 65535 )) ||
    { echo "Invalid SSH port" >&2; exit 2; }
[[ -r "$XRAY_PUB" ]] || { echo "Missing Xray public key file" >&2; exit 2; }
ssh-keygen -lf "$XRAY_PUB" >/dev/null || { echo "Invalid public SSH key" >&2; exit 2; }
PUB="$(awk 'NF {n++; line=$0} END {if (n==1) print line; else exit 1}' "$XRAY_PUB")" ||
    { echo "Expected exactly one public SSH key" >&2; exit 2; }

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
BOOTSTRAP="$SCRIPT_DIR/vpn-bootstrap.sh"
[[ -r "$BOOTSTRAP" ]] || { echo "Missing $BOOTSTRAP" >&2; exit 2; }
SSH_ARGS=(-T -p "$PORT" -o StrictHostKeyChecking=ask -o ClearAllForwardings=yes)
if [[ "$ADMIN_KEY" != "-" ]]; then
    [[ -r "$ADMIN_KEY" ]] || { echo "Missing admin private key file" >&2; exit 2; }
    SSH_ARGS+=(-i "$ADMIN_KEY" -o IdentitiesOnly=yes)
fi

options=(--user xray --pubkey "$PUB" --endpoint "$SERVER")
for arg in "$@"; do
    case "$arg" in
        --user|--pubkey|--pubkey-file|--harden-ssh|--endpoint)
            echo "Option $arg not allowed in remote wrapper" >&2
            exit 2 ;;
    esac
done
options+=("$@")
printf -v quoted_args '%q ' "${options[@]}"
remote_cmd="if [ \"\$(id -u)\" -eq 0 ]; then exec bash -s -- $quoted_args; else exec sudo -n bash -s -- $quoted_args; fi"

echo "Running Xray bootstrap on $SERVER via SSH as $ADMIN; creating xray management user."
ssh "${SSH_ARGS[@]}" "$ADMIN@$SERVER" "$remote_cmd" < "$BOOTSTRAP"
