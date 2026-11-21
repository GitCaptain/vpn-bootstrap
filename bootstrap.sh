#!/usr/bin/env bash
set -Eeuo pipefail

# Local entrypoint: chooses Xray, AmneziaWG preparation, or both.
# Root SSH is disabled only after a verified new vpnadmin SSH login and sudo.
# AmneziaWG's Docker container is installed by the official AmneziaVPN app.
usage() {
    cat <<'EOF'
Usage:
  ./bootstrap.sh --server VPS_HOST --protocol xray|amnezia|both
                 [--ssh-user root] [--ssh-key /path/to/initial-admin-key|-]
                 [--ssh-port 22]
                 [--admin-key ~/.ssh/vpnadmin] [--admin-pubkey ~/.ssh/vpnadmin.pub]
                 [--xray-key ~/.ssh/xray] [--xray-pubkey ~/.ssh/xray.pub]
                 [--amnezia-key ~/.ssh/amnezia] [--amnezia-pubkey ~/.ssh/amnezia.pub]
                 --confirm-root-ssh-lockout

Behavior:
  - Invoke from the local checkout; no script or key is fetched from GitHub.
  - Always uses the 'vpnadmin' SSH administrator for subsequent provisioning.
  - Xray has its own 'xray' SSH user and non-root Docker service.
  - Amnezia uses its own 'amnezia' SSH user; its official GUI installs AWG.
  - On successful setup, disables root SSH even for SSH keys, with a
    timed rollback if the new administrator login cannot be verified.
  - Re-running prefers vpnadmin and skips already configured steps.
EOF
}
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
SERVER=""
PROTOCOL=""
INITIAL_USER="root"
INITIAL_KEY="-"
PORT="22"
ADMIN_KEY="$HOME/.ssh/vpnadmin"
ADMIN_PUB="$HOME/.ssh/vpnadmin.pub"
XRAY_KEY="$HOME/.ssh/xray"
XRAY_PUB="$HOME/.ssh/xray.pub"
AMNEZIA_KEY="$HOME/.ssh/amnezia"
AMNEZIA_PUB="$HOME/.ssh/amnezia.pub"
CONFIRM_ROOT_LOCKOUT=0
while (( $# > 0 )); do
    case "$1" in
        --server) SERVER="$2"; shift 2 ;;
        --protocol) PROTOCOL="$2"; shift 2 ;;
        --ssh-user) INITIAL_USER="$2"; shift 2 ;;
        --ssh-key) INITIAL_KEY="$2"; shift 2 ;;
        --ssh-port) PORT="$2"; shift 2 ;;
        --admin-key) ADMIN_KEY="$2"; shift 2 ;;
        --admin-pubkey) ADMIN_PUB="$2"; shift 2 ;;
        --xray-key) XRAY_KEY="$2"; shift 2 ;;
        --xray-pubkey) XRAY_PUB="$2"; shift 2 ;;
        --amnezia-key) AMNEZIA_KEY="$2"; shift 2 ;;
        --amnezia-pubkey) AMNEZIA_PUB="$2"; shift 2 ;;
        --confirm-root-ssh-lockout) CONFIRM_ROOT_LOCKOUT=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "Unknown option: $1" ;;
    esac
done
[[ -n "$SERVER" && "$SERVER" =~ ^[a-zA-Z0-9.:-]+$ && "$SERVER" != -* ]] ||
    die "Provide a safe --server address"
[[ "$PROTOCOL" == xray || "$PROTOCOL" == amnezia || "$PROTOCOL" == both ]] ||
    die "--protocol must be xray, amnezia, or both"
[[ "$INITIAL_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    die "Invalid --ssh-user"
# A previous AmneziaVPN self-hosted connection may still store root SSH
# credentials. Disabling root SSH does not stop AWG packets, but can break
# future Amnezia server management. Require explicit operator confirmation
# that access has been migrated and tested *before any server mutation*.
[[ "$CONFIRM_ROOT_LOCKOUT" -eq 1 ]] ||
    die "Missing --confirm-root-ssh-lockout. First verify that existing AmneziaVPN server management works via a non-root SSH user, back up its settings, and review docs/EXISTING_AMNEZIA_RUNBOOK.md"
[[ "$PORT" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$PORT <= 65535 )) ||
    die "Invalid SSH port"
for cmd in ssh ssh-keygen awk bash; do
    command -v "$cmd" >/dev/null || die "Missing $cmd"
done
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
for file in bin/ensure-vpnadmin-remote.sh bin/root-ssh-policy-remote.sh; do
    [[ -f "$SCRIPT_DIR/$file" ]] || die "Missing local script $file"
done
check_pubkey() {
    local f="$1" key
    [[ -r "$f" ]] || die "Missing SSH public key: $f"
    ssh-keygen -lf "$f" >/dev/null || die "Invalid SSH public key: $f"
    key="$(awk 'NF{n++;line=$0}END{if(n==1)print line;else exit 1}' "$f")" ||
        die "Expected exactly one public key in $f"
    printf '%s' "$key"
}
ADMIN_PUB_VALUE="$(check_pubkey "$ADMIN_PUB")"
if [[ "$PROTOCOL" == xray || "$PROTOCOL" == both ]]; then
    [[ -r "$XRAY_KEY" ]] || die "Missing Xray SSH private key: $XRAY_KEY"
    [[ -r "$XRAY_PUB" ]] || die "Missing Xray SSH key file: $XRAY_PUB"
    check_pubkey "$XRAY_PUB" >/dev/null
fi
if [[ "$PROTOCOL" == amnezia || "$PROTOCOL" == both ]]; then
    [[ -f "$SCRIPT_DIR/amnezia-setup.sh" ]] ||
        die "Missing amnezia-setup.sh in this checkout"
    [[ -r "$AMNEZIA_KEY" ]] || die "Missing Amnezia SSH private key: $AMNEZIA_KEY"
    check_pubkey "$AMNEZIA_PUB" >/dev/null
fi
[[ -r "$ADMIN_KEY" ]] || die "Missing vpnadmin private key: $ADMIN_KEY"
if [[ "$INITIAL_KEY" != "-" ]]; then
    [[ -r "$INITIAL_KEY" ]] || die "Missing initial admin SSH private key: $INITIAL_KEY"
fi

ssh_common=(-T -p "$PORT" -o StrictHostKeyChecking=ask
            -o ClearAllForwardings=yes -o ControlMaster=no -o ControlPath=none
            -o ConnectTimeout=10)
ssh_using_key() {
    local key="$1" user="$2" cmd="$3"
    shift 3
    if [[ "$key" == "-" ]]; then
        ssh "${ssh_common[@]}" "$user@$SERVER" "$cmd" "$@"
    else
        ssh "${ssh_common[@]}" -i "$key" -o IdentitiesOnly=yes \
            "$user@$SERVER" "$cmd" "$@"
    fi
}
# Always verify a fresh, non-multiplexed SSH connection before considering
# an account ready. BatchMode prevents accidental password fallback.
admin_ready() {
    ssh "${ssh_common[@]}" -o BatchMode=yes -i "$ADMIN_KEY" \
        -o IdentitiesOnly=yes "vpnadmin@$SERVER" \
        'test "$(id -un)" = vpnadmin && sudo -n true' </dev/null >/dev/null 2>&1
}
verify_service_login() {
    local user="$1" key="$2"
    ssh "${ssh_common[@]}" -o BatchMode=yes -i "$key" \
        -o IdentitiesOnly=yes "$user@$SERVER" \
        "test \"\$(id -un)\" = '$user' && sudo -n true" \
        </dev/null >/dev/null 2>&1 ||
        die "Fresh SSH login and sudo failed for $user; root SSH will remain unchanged"
    echo "Verified $user SSH and passwordless sudo."
}
run_remote_admin_script() {
    local script="$1"; shift
    local encoded=""
    printf -v encoded '%q ' "$@"
    ssh "${ssh_common[@]}" -o BatchMode=yes -i "$ADMIN_KEY" \
        -o IdentitiesOnly=yes "vpnadmin@$SERVER" \
        "exec sudo -n bash -s -- $encoded" < "$script"
}
if admin_ready; then
    echo "Existing vpnadmin SSH account confirmed; skipping initial admin creation."
else
    echo "Provisioning persistent vpnadmin from $INITIAL_USER SSH account."
    printf -v escaped_pub '%q' "$ADMIN_PUB_VALUE"
    remote_cmd="if [ \"\$(id -u)\" -eq 0 ]; then exec bash -s -- $escaped_pub; else exec sudo -n bash -s -- $escaped_pub; fi"
    ssh_using_key "$INITIAL_KEY" "$INITIAL_USER" "$remote_cmd" \
        < "$SCRIPT_DIR/bin/ensure-vpnadmin-remote.sh" ||
        die "Failed to provision vpnadmin; existing SSH access left unchanged"
fi
admin_ready || die "Cannot establish a NEW vpnadmin SSH session with sudo; root SSH not changed"
echo "Verified: vpnadmin key-only SSH and passwordless sudo."

if [[ "$PROTOCOL" == xray || "$PROTOCOL" == both ]]; then
    echo "Installing/checking Xray."
    bash "$SCRIPT_DIR/bin/setup-xray-remote.sh" \
        "$SERVER" vpnadmin "$ADMIN_KEY" "$XRAY_PUB" "$PORT" \
        -- --skip-package-upgrade --no-ssh-hardening --no-block-ru --no-firewall
    run_remote_admin_script "$SCRIPT_DIR/bin/verify-xray-remote.sh"
    verify_service_login xray "$XRAY_KEY"
fi
if [[ "$PROTOCOL" == amnezia || "$PROTOCOL" == both ]]; then
    echo "Installing/checking separate Amnezia SSH manager."
    AMNEZIA_ADMIN_SSH_KEY="$ADMIN_KEY" \
        bash "$SCRIPT_DIR/amnezia-setup.sh" \
        "$SERVER" vpnadmin "$AMNEZIA_PUB" "$PORT" amnezia
    verify_service_login amnezia "$AMNEZIA_KEY"
    # This checks the SSH preparation only. Official AmneziaVPN still installs
    # or discovers the actual AWG container via its Self-hosted connection.
fi

echo "Disabling root SSH (password AND public key), with scheduled recovery."
result="$(run_remote_admin_script "$SCRIPT_DIR/bin/root-ssh-policy-remote.sh" apply)"
case "$result" in
    ALREADY)
        echo "Root SSH already denied by effective sshd policy." ;;
    pending.*)
        # The previous SSH session might still be alive: force a NEW connection.
        admin_ready || die "vpnadmin re-login failed; timed SSH rollback remains armed"
        status="$(run_remote_admin_script "$SCRIPT_DIR/bin/root-ssh-policy-remote.sh" status)"
        [[ "$status" == no ]] ||
            die "root SSH is not disabled; timed SSH rollback remains armed"
        run_remote_admin_script "$SCRIPT_DIR/bin/root-ssh-policy-remote.sh" confirm "$result" ;;
    *) die "Unexpected SSH policy result; investigate pending rollback: $result" ;;
esac
admin_ready || die "Final vpnadmin SSH verification failed"
[[ "$(run_remote_admin_script "$SCRIPT_DIR/bin/root-ssh-policy-remote.sh" status)" == no ]] ||
    die "Final root SSH effective-policy check failed"
echo "Bootstrap complete: root SSH is prohibited; vpnadmin SSH is verified."
if [[ "$PROTOCOL" == amnezia || "$PROTOCOL" == both ]]; then
    echo "Amnezia SSH preparation complete. The official AmneziaVPN client"
    echo "must install/discover the separate AmneziaWG container to finish AWG."
fi
