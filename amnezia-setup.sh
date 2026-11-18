#!/usr/bin/env bash
set -Eeuo pipefail

# Usage:
# ./create-amnezia-user.sh SERVER_IP ADMIN_USER PUBLIC_KEY [SSH_PORT] [NEW_USER] [NEW_PASSWORD]

if [[ $# -lt 3 || $# -gt 6 ]]; then
    echo "Usage: $0 SERVER_IP ADMIN_USER PUBLIC_KEY [SSH_PORT] [NEW_USER] [NEW_PASSWORD]"
    exit 1
fi

SERVER_IP="$1"
ADMIN_USER="$2"
PUBKEY_FILE="$3"
SSH_PORT="${4:-22}"
TARGET_USER="${5:-amnezia}"
TARGET_PASSWORD="${6:-amnezia}"

# Dependencies
for cmd in ssh ssh-keygen base64; do
    command -v "$cmd" >/dev/null 2>&1 || {
        echo "ERROR: $cmd is not installed."
        exit 1
    }
done

# Validate arguments
if [[ ! "$SSH_PORT" =~ ^[0-9]+$ ]] ||
   (( SSH_PORT < 1 || SSH_PORT > 65535 )); then
    echo "ERROR: Invalid SSH port."
    exit 1
fi

if [[ ! "$TARGET_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    echo "ERROR: Invalid Linux username."
    exit 1
fi

if [[ -z "$TARGET_PASSWORD" ||
      "$TARGET_PASSWORD" == *:* ||
      "$TARGET_PASSWORD" == *$'\n'* ||
      "$TARGET_PASSWORD" == *$'\r'* ]]; then
    echo "ERROR: Invalid password."
    exit 1
fi

if [[ ! -f "$PUBKEY_FILE" ]]; then
    echo "ERROR: Public key file not found."
    exit 1
fi

PUBKEY=$(awk '
    NF { n++; key=$0 }
    END {
        if (n != 1) exit 1
        print key
    }
' "$PUBKEY_FILE") || {
    echo "ERROR: Public key file must contain exactly one key."
    exit 1
}

if ! ssh-keygen -lf "$PUBKEY_FILE" >/dev/null 2>&1; then
    echo "ERROR: Invalid public key."
    exit 1
fi

# Base64 prevents shell injection and keeps credentials out of
# the remote command in plain text.
USER_B64=$(printf '%s' "$TARGET_USER" | base64 | tr -d '\r\n')
PASS_B64=$(printf '%s' "$TARGET_PASSWORD" | base64 | tr -d '\r\n')
PUBKEY_B64=$(printf '%s' "$PUBKEY" | base64 | tr -d '\r\n')

# Remote setup script
REMOTE_SCRIPT=$(cat <<'REMOTE_SCRIPT'
set -Eeuo pipefail

TARGET_USER=$(printf '%s' "$1" | base64 -d)
TARGET_PASSWORD=$(printf '%s' "$2" | base64 -d)
PUBKEY=$(printf '%s' "$3" | base64 -d)

SSH_CONFIG="/etc/ssh/sshd_config"
SSHD_BIN=$(command -v sshd || true)

if [[ -z "$SSHD_BIN" || ! -f "$SSH_CONFIG" ]]; then
    echo "ERROR: OpenSSH server configuration not found."
    exit 1
fi

if ! getent group sudo >/dev/null; then
    echo "ERROR: sudo group not found. Ubuntu/Debian is expected."
    exit 1
fi

# Create user if necessary
if id "$TARGET_USER" >/dev/null 2>&1; then
    echo "User already exists: $TARGET_USER"
    usermod -s /bin/bash "$TARGET_USER"
else
    useradd -m -s /bin/bash "$TARGET_USER"
    echo "Created user: $TARGET_USER"
fi

# Set password and grant sudo
printf '%s:%s\n' "$TARGET_USER" "$TARGET_PASSWORD" | chpasswd
usermod -aG sudo "$TARGET_USER"

# Install SSH public key
USER_HOME=$(getent passwd "$TARGET_USER" | cut -d: -f6)
USER_GROUP=$(id -gn "$TARGET_USER")

install -d -m 700 \
    -o "$TARGET_USER" -g "$USER_GROUP" \
    "$USER_HOME/.ssh"

touch "$USER_HOME/.ssh/authorized_keys"

if ! grep -qxF -- "$PUBKEY" "$USER_HOME/.ssh/authorized_keys"; then
    printf '%s\n' "$PUBKEY" >> "$USER_HOME/.ssh/authorized_keys"
fi

chown "$TARGET_USER:$USER_GROUP" \
    "$USER_HOME/.ssh/authorized_keys"

chmod 600 "$USER_HOME/.ssh/authorized_keys"
chmod go-w "$USER_HOME"

# Backup SSH config
BACKUP="${SSH_CONFIG}.backup-amnezia-$(date +%Y%m%d-%H%M%S)-$$"
cp -a "$SSH_CONFIG" "$BACKUP"

# Remove previously installed block
sed -i \
    '/^# BEGIN AMNEZIA-SSH-KEY-ONLY$/,/^# END AMNEZIA-SSH-KEY-ONLY$/d' \
    "$SSH_CONFIG"

# Restrict SSH authentication for this user only
cat >> "$SSH_CONFIG" <<'SSH_BLOCK'

# BEGIN AMNEZIA-SSH-KEY-ONLY
Match User amnezia
    PubkeyAuthentication yes
    AuthenticationMethods publickey
    PasswordAuthentication no
    KbdInteractiveAuthentication no
# END AMNEZIA-SSH-KEY-ONLY
SSH_BLOCK

# Validate syntax and effective authentication settings
if ! "$SSHD_BIN" -t; then
    echo "ERROR: Invalid SSH configuration. Restoring backup."
    cp -a "$BACKUP" "$SSH_CONFIG"
    exit 1
fi

EFFECTIVE=$("$SSHD_BIN" -T \
    -C "user=$TARGET_USER,host=localhost,addr=127.0.0.1")

for expected in \
    "pubkeyauthentication yes" \
    "authenticationmethods publickey" \
    "passwordauthentication no" \
    "kbdinteractiveauthentication no"
do
    if ! grep -Fxq "$expected" <<< "$EFFECTIVE"; then
        echo "ERROR: SSH setting not applied: $expected"
        echo "Restoring backup."
        cp -a "$BACKUP" "$SSH_CONFIG"
        exit 1
    fi
done

# Reload SSH without dropping existing connections
if systemctl reload ssh.service 2>/dev/null; then
    :
elif systemctl reload sshd.service 2>/dev/null; then
    :
else
    echo "ERROR: SSH reload failed. Restoring backup."
    cp -a "$BACKUP" "$SSH_CONFIG"
    systemctl restart ssh.service 2>/dev/null ||
        systemctl restart sshd.service || true
    exit 1
fi

echo
echo "===================================="
echo "User successfully configured!"
echo "===================================="
echo "Username: $TARGET_USER"
echo "Sudo: enabled"
echo "SSH: public key only"
echo "Password authentication: disabled"
echo "Backup: $BACKUP"
REMOTE_SCRIPT
)

SCRIPT_B64=$(printf '%s' "$REMOTE_SCRIPT" | base64 | tr -d '\r\n')

# Root does not need sudo.
# For another administrator, sudo authenticates interactively.
REMOTE_CMD="if [ \"\$(id -u)\" -eq 0 ]; then
    printf '%s' '$SCRIPT_B64' | base64 -d | bash -s -- '$USER_B64' '$PASS_B64' '$PUBKEY_B64'
else
    sudo -v &&
    sudo -n bash -c 'printf \"%s\" \"\$1\" | base64 -d | bash -s -- \"\$2\" \"\$3\" \"\$4\"' _ '$SCRIPT_B64' '$USER_B64' '$PASS_B64' '$PUBKEY_B64'
fi"

echo "===================================="
echo "Server: $SERVER_IP"
echo "Admin: $ADMIN_USER"
echo "New user: $TARGET_USER"
echo "SSH port: $SSH_PORT"
echo "===================================="

if [[ "$TARGET_PASSWORD" == "amnezia" ]]; then
    echo "WARNING: Using default password 'amnezia'."
fi

echo
echo "Connecting to server..."

ssh -tt \
    -p "$SSH_PORT" \
    -o StrictHostKeyChecking=ask \
    "$ADMIN_USER@$SERVER_IP" \
    "$REMOTE_CMD"

echo
echo "Setup completed."
echo
echo "Connect using:"
echo "ssh -p $SSH_PORT -i \"${PUBKEY_FILE%.pub}\" $TARGET_USER@$SERVER_IP"
