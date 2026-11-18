#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
# ./amnezia-setup.sh SERVER_IP ADMIN_USER PUBLIC_KEY [SSH_PORT] [NEW_USER] [NEW_PASSWORD]
#
# Defaults:
# SSH_PORT=22
# NEW_USER=amnezia
# NEW_PASSWORD=amnezia
#
# Use "-" as NEW_PASSWORD to enter it interactively.

if [[ $# -lt 3 || $# -gt 6 ]]; then
    echo "Usage: $0 SERVER_IP ADMIN_USER PUBLIC_KEY [SSH_PORT] [NEW_USER] [NEW_PASSWORD]"
    exit 1
fi

SERVER_HOST="$1"
ADMIN_USER="$2"
PUBKEY_FILE="$3"
SSH_PORT="${4:-22}"
TARGET_USER="${5:-amnezia}"
TARGET_PASSWORD="${6:-amnezia}"

# --------------------------------------------------
# Validation
# --------------------------------------------------

for cmd in ssh ssh-keygen base64 awk; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Required command not found: $cmd"
        exit 1
    }
done

if [[ "$SERVER_HOST" == -* ]]; then
    echo "ERROR: Invalid server address."
    exit 1
fi

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
    echo "ERROR: SSH port must be between 1 and 65535."
    exit 1
fi

if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "ERROR: Invalid Linux username: $TARGET_USER"
    exit 1
fi

if [[ "$TARGET_PASSWORD" == "-" ]]; then
    printf "New password for %s: " "$TARGET_USER" >&2
    IFS= read -r -s TARGET_PASSWORD </dev/tty
    printf "\n" >&2
fi

if [[ -z "$TARGET_PASSWORD" ||
      "$TARGET_PASSWORD" == *:* ||
      "$TARGET_PASSWORD" == *$'\n'* ||
      "$TARGET_PASSWORD" == *$'\r'* ]]; then
    echo "ERROR: Invalid password. Empty passwords, colons and newlines are not supported."
    exit 1
fi

if [[ ! -f "$PUBKEY_FILE" ]]; then
    echo "ERROR: Public key file not found: $PUBKEY_FILE"
    exit 1
fi

if ! PUBKEY_LINE=$(awk '
    NF {
        count++
        key=$0
    }
    END {
        if (count != 1) exit 1
        print key
    }
' "$PUBKEY_FILE"); then
    echo "ERROR: Public key file must contain exactly one key."
    exit 1
fi

if ! ssh-keygen -lf "$PUBKEY_FILE" >/dev/null 2>&1; then
    echo "ERROR: Invalid public SSH key."
    exit 1
fi

# --------------------------------------------------
# Encode values for secure transport via SSH stdin
# --------------------------------------------------

encode() {
    printf '%s' "$1" | base64 | tr -d '\r\n'
}

TARGET_USER_B64=$(encode "$TARGET_USER")
TARGET_PASSWORD_B64=$(encode "$TARGET_PASSWORD")
PUBKEY_B64=$(encode "$PUBKEY_LINE")

SUDO_PASSWORD_B64=""

# For non-root administrators, sudo may require a
# separate password. Press Enter if sudo is passwordless.
if [[ "$ADMIN_USER" != "root" ]]; then
    printf "Sudo password for %s (Enter if passwordless sudo): " \
        "$ADMIN_USER" >&2

    IFS= read -r -s SUDO_PASSWORD </dev/tty
    printf "\n" >&2

    SUDO_PASSWORD_B64=$(encode "$SUDO_PASSWORD")
    unset SUDO_PASSWORD
fi

unset TARGET_PASSWORD

# --------------------------------------------------
# Remote privilege escalation
# --------------------------------------------------

# The first line of stdin is reserved for the sudo
# password for non-root users. The remaining stdin
# contains the actual installation script.
#
# No remote PTY is allocated. SSH password prompts
# are handled locally by the SSH client.

REMOTE_COMMAND='
set -eu

if [ "$(id -u)" -eq 0 ]; then
    exec bash -s
fi

IFS= read -r SUDO_PASSWORD_B64 || {
    echo "ERROR: Cannot read sudo credentials." >&2
    exit 1
}

if ! sudo -n true >/dev/null 2>&1; then
    SUDO_PASSWORD=$(printf "%s" "$SUDO_PASSWORD_B64" | base64 -d)

    if ! printf "%s\n" "$SUDO_PASSWORD" | sudo -S -p "" -v; then
        echo "ERROR: Sudo authentication failed." >&2
        exit 1
    fi
fi

unset SUDO_PASSWORD SUDO_PASSWORD_B64

exec sudo -n bash -s
'

# --------------------------------------------------
# Remote installation script
# --------------------------------------------------

echo "===================================="
echo "Server:      $SERVER_HOST"
echo "Admin:       $ADMIN_USER"
echo "New user:    $TARGET_USER"
echo "SSH port:    $SSH_PORT"
echo "===================================="
echo
echo "Connecting using PASSWORD authentication only..."
echo

{
    # Non-root user: first line is reserved for sudo.
    if [[ "$ADMIN_USER" != "root" ]]; then
        printf '%s\n' "$SUDO_PASSWORD_B64"
    fi

    # Send parameters as base64 assignments.
    printf 'TARGET_USER_B64=%s\n' "$TARGET_USER_B64"
    printf 'TARGET_PASSWORD_B64=%s\n' "$TARGET_PASSWORD_B64"
    printf 'PUBKEY_B64=%s\n' "$PUBKEY_B64"
    printf 'SSH_PORT=%s\n' "$SSH_PORT"

    cat <<'REMOTE_SCRIPT'

set -Eeuo pipefail

# Decode parameters
TARGET_USER=$(printf '%s' "$TARGET_USER_B64" | base64 -d)
TARGET_PASSWORD=$(printf '%s' "$TARGET_PASSWORD_B64" | base64 -d)
PUBKEY=$(printf '%s' "$PUBKEY_B64" | base64 -d)

SSH_CONFIG="/etc/ssh/sshd_config"

# --------------------------------------------------
# Check environment
# --------------------------------------------------

if [[ "$(id -u)" -ne 0 ]]; then
    echo "ERROR: Root privileges required."
    exit 1
fi

for cmd in useradd usermod chpasswd getent sshd \
           ssh-keygen systemctl base64; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: Required server command not found: $cmd"
        exit 1
    }
done

if [[ ! -f "$SSH_CONFIG" ]]; then
    echo "ERROR: SSH configuration not found: $SSH_CONFIG"
    exit 1
fi

if ! getent group sudo >/dev/null 2>&1; then
    echo "ERROR: Group 'sudo' does not exist."
    echo "This script expects Ubuntu/Debian."
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

# Set password
printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | chpasswd

unset TARGET_PASSWORD

# Add user to sudo group
usermod -aG sudo "$TARGET_USER"

echo "Sudo privileges configured."

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

chown "$TARGET_USER:$USER_GROUP" \
    "$USER_HOME/.ssh/authorized_keys"

chmod 600 "$USER_HOME/.ssh/authorized_keys"

echo "SSH public key installed."

# --------------------------------------------------
# Backup SSH configuration
# --------------------------------------------------

BACKUP="${SSH_CONFIG}.backup-amnezia-$(date +%Y%m%d-%H%M%S)-$$"

cp -a "$SSH_CONFIG" "$BACKUP"

echo "SSH configuration backup: $BACKUP"

# --------------------------------------------------
# Remove previous managed configuration block
# --------------------------------------------------

BEGIN_MARKER="# BEGIN AMNEZIA-SSH-KEY-ONLY"
END_MARKER="# END AMNEZIA-SSH-KEY-ONLY"

if grep -qF "$BEGIN_MARKER" "$SSH_CONFIG"; then
    if ! grep -qF "$END_MARKER" "$SSH_CONFIG"; then
        echo "ERROR: Previous managed SSH block is incomplete."
        exit 1
    fi

    sed -i \
        '/^# BEGIN AMNEZIA-SSH-KEY-ONLY$/,/^# END AMNEZIA-SSH-KEY-ONLY$/d' \
        "$SSH_CONFIG"
fi

# --------------------------------------------------
# Restrict SSH for the requested user
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

# --------------------------------------------------
# Validate SSH configuration
# --------------------------------------------------

SSHD_BIN=$(command -v sshd)

if ! "$SSHD_BIN" -t -f "$SSH_CONFIG"; then
    echo "ERROR: Invalid SSH configuration."
    echo "Restoring backup..."

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
        echo "ERROR: Effective SSH setting not applied:"
        echo "  $setting"
        echo "Restoring backup..."

        cp -a "$BACKUP" "$SSH_CONFIG"
        exit 1
    fi
done

echo "SSH configuration validated."

# --------------------------------------------------
# Reload SSH without dropping existing connections
# --------------------------------------------------

reload_ssh() {
    if systemctl reload ssh.service 2>/dev/null; then
        return 0
    fi

    if systemctl reload sshd.service 2>/dev/null; then
        return 0
    fi

    return 1
}

if ! reload_ssh; then
    echo "ERROR: Failed to reload SSH."
    echo "Restoring previous configuration..."

    cp -a "$BACKUP" "$SSH_CONFIG"
    reload_ssh || true

    exit 1
fi

# --------------------------------------------------
# Success
# --------------------------------------------------

echo
echo "======================================"
echo "SUCCESS!"
echo "======================================"
echo "User:                  $TARGET_USER"
echo "Sudo:                  enabled"
echo "SSH public key:        installed"
echo "SSH password login:   disabled"
echo "SSH key login:         enabled"
echo "Other users:           unchanged"
echo "Backup:                $BACKUP"
echo "======================================"

REMOTE_SCRIPT

} | ssh -T \
    -p "$SSH_PORT" \
    -o PubkeyAuthentication=no \
    -o PreferredAuthentications=password,keyboard-interactive \
    -o NumberOfPasswordPrompts=3 \
    -o BatchMode=no \
    -o GSSAPIAuthentication=no \
    -o HostbasedAuthentication=no \
    -o StrictHostKeyChecking=ask \
    "$ADMIN_USER@$SERVER_HOST" \
    "$REMOTE_COMMAND"

echo
echo "Setup completed."
echo
echo "Connect to the new user using:"
echo "ssh -p $SSH_PORT -i PRIVATE_KEY $TARGET_USER@$SERVER_HOST"
