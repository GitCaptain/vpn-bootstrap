#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
# ./amnezia-setup.sh SERVER_IP ADMIN_USER PUBLIC_KEY [SSH_PORT] [NEW_USER]
# The Amnezia SSH account is always key-only, with its password locked.
# Set AMNEZIA_ADMIN_SSH_KEY=~/.ssh/admin if the provisioning admin uses a key.

if [[ $# -lt 3 || $# -gt 5 ]]; then
    echo "Usage: $0 SERVER_IP ADMIN_USER PUBLIC_KEY [SSH_PORT] [NEW_USER]"
    exit 1
fi

SERVER_HOST="$1"
ADMIN_USER="$2"
PUBKEY_FILE="$3"
SSH_PORT="${4:-22}"
TARGET_USER="${5:-amnezia}"

for cmd in ssh ssh-keygen base64 awk; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: $cmd"
        exit 1
    }
done

if [[ ! "$ADMIN_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    echo "ERROR: Invalid administrator username."
    exit 1
fi

if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: Invalid SSH port."
    exit 1
fi

SSH_PORT=$((10#$SSH_PORT))

if (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    echo "ERROR: Invalid SSH port."
    exit 1
fi

if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "ERROR: Invalid Linux username."
    exit 1
fi

if [[ ! -f "$PUBKEY_FILE" ]]; then
    echo "ERROR: Public key file not found."
    exit 1
fi

PUBKEY_LINE=$(awk '
    NF {
        count++
        key=$0
    }
    END {
        if (count != 1) exit 1
        print key
    }
' "$PUBKEY_FILE") || {
    echo "ERROR: Public key file must contain exactly one key."
    exit 1
}

if ! ssh-keygen -lf "$PUBKEY_FILE" >/dev/null 2>&1; then
    echo "ERROR: Invalid public SSH key."
    exit 1
fi

encode() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
}

TARGET_USER_B64=$(encode "$TARGET_USER")
PUBKEY_B64=$(encode "$PUBKEY_LINE")

# --------------------------------------------------
# Remote privilege escalation
# --------------------------------------------------

# The provisioning SSH account must be root or already have passwordless sudo.
# Do not transfer its sudo password through a base64-encoded SSH pipeline.
REMOTE_COMMAND='if [ "$(id -u)" -eq 0 ]; then exec bash -s; else exec sudo -n bash -s; fi'

# Optional private key for the *existing admin* SSH login. The public key
# argument is for the newly prepared amnezia account, not the admin account.
SSH_IDENTITY_ARGS=()
if [[ -n "${AMNEZIA_ADMIN_SSH_KEY:-}" ]]; then
    [[ -r "$AMNEZIA_ADMIN_SSH_KEY" ]] || {
        echo "ERROR: AMNEZIA_ADMIN_SSH_KEY is not readable." >&2
        exit 1
    }
    SSH_IDENTITY_ARGS=(-i "$AMNEZIA_ADMIN_SSH_KEY" -o IdentitiesOnly=yes)
fi

echo "===================================="
echo "Server:      $SERVER_HOST"
echo "Admin:       $ADMIN_USER"
echo "New user:    $TARGET_USER"
echo "SSH port:    $SSH_PORT"
echo "===================================="

echo "Target account password will be locked. Use its SSH private key in AmneziaVPN."

echo
echo "Connecting using SSH (public key preferred; password for bootstrap admin if necessary)..."
echo

{
    printf 'TARGET_USER_B64=%s\n' "$TARGET_USER_B64"
    printf 'PUBKEY_B64=%s\n' "$PUBKEY_B64"
    printf 'SSH_PORT=%s\n' "$SSH_PORT"

    cat <<'REMOTE_SCRIPT'

set -Eeuo pipefail

TARGET_USER=$(printf '%s' "$TARGET_USER_B64" | base64 -d)
PUBKEY=$(printf '%s' "$PUBKEY_B64" | base64 -d)

SSH_CONFIG="/etc/ssh/sshd_config"
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS_FILE="$SUDOERS_DIR/90-${TARGET_USER}-nopasswd"

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Root privileges required."
    exit 1
fi

for cmd in useradd usermod getent sshd \
           ssh-keygen systemctl base64 visudo runuser; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Required server command not found: $cmd"
        exit 1
    }
done

if [[ ! -f "$SSH_CONFIG" || ! -d "$SUDOERS_DIR" ]]; then
    echo "ERROR: SSH or sudo configuration not found."
    exit 1
fi

if ! getent group sudo >/dev/null 2>&1; then
    echo "ERROR: Group sudo not found. Ubuntu/Debian expected."
    exit 1
fi

# --------------------------------------------------
# Create or update user
# --------------------------------------------------

if id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User already exists: $TARGET_USER"
    usermod -s /bin/bash "$TARGET_USER"
else
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "Created user: $TARGET_USER"
fi

usermod -aG sudo "$TARGET_USER"

echo "Sudo group configured."

# --------------------------------------------------
# Configure passwordless sudo
# --------------------------------------------------

SUDOERS_BACKUP=""

if [[ -e "$SUDOERS_FILE" ]]; then
    SUDOERS_BACKUP="${SUDOERS_FILE}.backup-$(date +%Y%m%d-%H%M%S)-$$"
    cp -a "$SUDOERS_FILE" "$SUDOERS_BACKUP"
fi

SUDOERS_TMP=$(mktemp "$SUDOERS_DIR/.${TARGET_USER}.XXXXXX")

printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$TARGET_USER" \
    > "$SUDOERS_TMP"

chmod 0440 "$SUDOERS_TMP"

if ! visudo -cf "$SUDOERS_TMP"; then
    rm -f "$SUDOERS_TMP"
    echo "ERROR: Invalid sudoers configuration."
    exit 1
fi

mv -f "$SUDOERS_TMP" "$SUDOERS_FILE"

if ! visudo -c; then
    echo "ERROR: Full sudoers validation failed."

    if [[ -n "$SUDOERS_BACKUP" ]]; then
        cp -a "$SUDOERS_BACKUP" "$SUDOERS_FILE"
    else
        rm -f "$SUDOERS_FILE"
    fi

    exit 1
fi

# Test that passwordless sudo actually works
if ! runuser -u "$TARGET_USER" -- sudo -n true; then
    echo "ERROR: Passwordless sudo test failed."

    if [[ -n "$SUDOERS_BACKUP" ]]; then
        cp -a "$SUDOERS_BACKUP" "$SUDOERS_FILE"
    else
        rm -f "$SUDOERS_FILE"
    fi

    exit 1
fi

echo "Passwordless sudo configured and tested."

# --------------------------------------------------
# Configure SSH public key
# --------------------------------------------------

USER_HOME=$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')
USER_GROUP=$(id -gn "$TARGET_USER")

if [[ -z "$USER_HOME" || "$USER_HOME" == "/" ]]; then
    echo "ERROR: Invalid home directory."
    exit 1
fi

chown "$TARGET_USER:$USER_GROUP" "$USER_HOME"
chmod go-w "$USER_HOME"

install -d \
    -m 700 \
    -o "$TARGET_USER" \
    -g "$USER_GROUP" \
    "$USER_HOME/.ssh"

touch "$USER_HOME/.ssh/authorized_keys"

if ! grep -qxF -- "$PUBKEY" "$USER_HOME/.ssh/authorized_keys"; then
    printf '%s\n' "$PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"
fi

chown "$TARGET_USER:$USER_GROUP" "$USER_HOME/.ssh/authorized_keys"
chmod 600 "$USER_HOME/.ssh/authorized_keys"

echo "SSH public key installed."

# --------------------------------------------------
# Backup SSH configuration
# --------------------------------------------------

BACKUP="${SSH_CONFIG}.backup-amnezia-$(date +%Y%m%d-%H%M%S)-$$"

cp -a "$SSH_CONFIG" "$BACKUP"

echo "SSH backup: $BACKUP"

# --------------------------------------------------
# Remove previous managed block
# --------------------------------------------------

BEGIN_MARKER="# BEGIN AMNEZIA-SSH-KEY-ONLY"
END_MARKER="# END AMNEZIA-SSH-KEY-ONLY"

if grep -qF "$BEGIN_MARKER" "$SSH_CONFIG"; then
    if ! grep -qF "$END_MARKER" "$SSH_CONFIG"; then
        echo "ERROR: Previous SSH block is incomplete."
        exit 1
    fi

    sed -i \
        '/^# BEGIN AMNEZIA-SSH-KEY-ONLY$/,/^# END AMNEZIA-SSH-KEY-ONLY$/d' \
        "$SSH_CONFIG"
fi

# --------------------------------------------------
# Restrict SSH for this user only
# --------------------------------------------------

cat >> "$SSH_CONFIG" <<SSH_BLOCK

$BEGIN_MARKER
Match User $TARGET_USER
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
$END_MARKER
SSH_BLOCK

SSHD_BIN=$(command -v sshd)

if ! "$SSHD_BIN" -t -f "$SSH_CONFIG"; then
    echo "ERROR: Invalid SSH configuration. Restoring backup."
    cp -a "$BACKUP" "$SSH_CONFIG"
    exit 1
fi

EFFECTIVE=$("$SSHD_BIN" -T \
    -f "$SSH_CONFIG" \
    -C "user=$TARGET_USER,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=$SSH_PORT")

EXPECTED_SETTINGS=(
    "pubkeyauthentication yes"
    "authenticationmethods publickey"
    "passwordauthentication no"
    "kbdinteractiveauthentication no"
)

for setting in "${EXPECTED_SETTINGS[@]}"; do
    if ! grep -Fxq "$setting" <<< "$EFFECTIVE"; then
        echo "ERROR: SSH setting not applied: $setting"
        echo "Restoring backup."
        cp -a "$BACKUP" "$SSH_CONFIG"
        exit 1
    fi
done

echo "SSH configuration validated."

# --------------------------------------------------
# Reload SSH
# --------------------------------------------------

if systemctl reload ssh.service 2>/dev/null ||
   systemctl reload sshd.service 2>/dev/null; then
    :
else
    echo "ERROR: SSH reload failed. Restoring backup."
    cp -a "$BACKUP" "$SSH_CONFIG"

    systemctl reload ssh.service 2>/dev/null ||
        systemctl reload sshd.service 2>/dev/null ||
        true

    exit 1
fi

# Only lock an existing account password after the public key has been
# installed and the new SSH configuration has been validated and reloaded.
# Never risk locking the previous login during a failed setup step.
usermod -L "$TARGET_USER"

echo
echo "======================================"
echo "SUCCESS!"
echo "======================================"
echo "User:                  $TARGET_USER"
echo "Sudo:                  enabled"
echo "Sudo password:         NOT REQUIRED"
echo "SSH public key:        installed"
echo "SSH password login:   disabled"
echo "SSH key login:         enabled"
echo "Other users:           unchanged"
echo "SSH backup:            $BACKUP"
echo "Sudoers file:          $SUDOERS_FILE"
echo "======================================"

REMOTE_SCRIPT

} | ssh -T \
    -p "$SSH_PORT" \
    -o PubkeyAuthentication=yes \
    -o PreferredAuthentications=publickey,password,keyboard-interactive \
    -o NumberOfPasswordPrompts=3 \
    -o BatchMode=no \
    -o GSSAPIAuthentication=no \
    -o HostbasedAuthentication=no \
    -o StrictHostKeyChecking=ask \
    "${SSH_IDENTITY_ARGS[@]}" \
    "$ADMIN_USER@$SERVER_HOST" \
    "$REMOTE_COMMAND"

echo
echo "Setup completed."
echo
echo "Connect using:"
echo "ssh -p $SSH_PORT -i PRIVATE_KEY $TARGET_USER@$SERVER_HOST"
