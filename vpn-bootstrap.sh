#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# VPN Server Bootstrap
#
# Supported OS:
#   Ubuntu 22.04 LTS
#   Ubuntu 24.04 LTS
#   Ubuntu 26.04 LTS
#
# This script:
#   - Updates installed packages
#   - Installs minimal server administration dependencies
#   - Creates a dedicated VPN management user
#   - Installs an SSH public key
#   - Grants passwordless sudo to the VPN management user
#   - Disables SSH root login and SSH password authentication
#   - Optionally creates swap (default: same size as RAM)
#   - Enables unattended Ubuntu security updates
#   - Installs Docker Engine from Docker's official repository
#   - Enables Docker at boot
#   - Performs basic IPv4/IPv6 and service diagnostics
#
# This script does NOT:
#   - Upgrade Ubuntu to another release
#   - Reboot the server
#   - Change the SSH port
#   - Configure a firewall
#   - Install Xray or AmneziaWG
#
# Usage:
#
#   ./vpn-bootstrap.sh \
#       --user vpn \
#       --pubkey-file /root/id_ed25519.pub
#
#   ./vpn-bootstrap.sh \
#       --user vpn \
#       --pubkey 'ssh-ed25519 AAAA... workstation'
#
# Options:
#
#   --user USER
#       Required.
#       User account that will manage the VPN server.
#
#   --pubkey KEY
#       SSH public key as a quoted command-line argument.
#
#   --pubkey-file FILE
#       Read the SSH public key from FILE.
#
#   --swap auto
#       Create swap approximately equal to installed RAM.
#       This is the default.
#
#   --swap none
#       Do not create swap.
#
#   --swap SIZE
#       Explicit swap size, for example:
#           512M
#           1G
#           2G
#
#   --skip-package-upgrade
#       Install required packages but do not upgrade all currently
#       installed Ubuntu packages.
#
#   --help
#       Show this help.
#
# Notes:
#
#   - If any swap is already active, this script leaves it unchanged.
#   - The VPN management user is NOT added to the docker group.
#     Docker operations should be performed through sudo.
#   - SSH password authentication is disabled.
#   - The VPN management user has passwordless sudo because the account
#     is accessible exclusively through its SSH key.
# ==============================================================================


# ------------------------------------------------------------------------------
# General helpers
# ------------------------------------------------------------------------------

SCRIPT_NAME="$(basename "$0")"

VPN_USER=""
SSH_PUBKEY=""
SSH_PUBKEY_FILE=""
SWAP_SIZE="auto"
PACKAGE_UPGRADE=1


log() {
    printf '\n===== %s =====\n' "$*"
}


die() {
    echo "ERROR: $*" >&2
    exit 1
}


usage() {
    sed -n '2,/^# ==============================================================================/{s/^# \{0,1\}//;p}' "$0"
}


require_value() {
    local option="$1"
    local value="${2:-}"

    if [[ -z "$value" || "$value" == --* ]]; then
        die "$option requires a value."
    fi
}


trap '
    rc=$?
    echo >&2
    echo "ERROR: bootstrap failed at line $LINENO." >&2
    echo "Command: $BASH_COMMAND" >&2
    echo "Exit code: $rc" >&2
    exit "$rc"
' ERR


# ------------------------------------------------------------------------------
# Parse CLI arguments
# ------------------------------------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in

        --user)
            require_value "$1" "${2:-}"
            VPN_USER="$2"
            shift 2
            ;;

        --pubkey)
            require_value "$1" "${2:-}"
            SSH_PUBKEY="$2"
            shift 2
            ;;

        --pubkey-file)
            require_value "$1" "${2:-}"
            SSH_PUBKEY_FILE="$2"
            shift 2
            ;;

        --swap)
            require_value "$1" "${2:-}"
            SWAP_SIZE="$2"
            shift 2
            ;;

        --skip-package-upgrade)
            PACKAGE_UPGRADE=0
            shift
            ;;

        --help|-h)
            usage
            exit 0
            ;;

        *)
            die "Unknown option: $1. Run $SCRIPT_NAME --help."
            ;;
    esac
done


# ------------------------------------------------------------------------------
# Validate execution context
# ------------------------------------------------------------------------------

if [[ "$EUID" -ne 0 ]]; then
    die "Run this script as root or through sudo."
fi


if [[ -z "$VPN_USER" ]]; then
    die "--user is required."
fi


if [[ ! "$VPN_USER" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
    die "Invalid VPN management username: $VPN_USER"
fi


if [[ "$VPN_USER" == "root" ]]; then
    die "The VPN management user cannot be root."
fi


if [[ -n "$SSH_PUBKEY" && -n "$SSH_PUBKEY_FILE" ]]; then
    die "Use either --pubkey or --pubkey-file, not both."
fi


if [[ -z "$SSH_PUBKEY" && -z "$SSH_PUBKEY_FILE" ]]; then
    die "One of --pubkey or --pubkey-file is required."
fi


if [[ -n "$SSH_PUBKEY_FILE" ]]; then

    if [[ ! -r "$SSH_PUBKEY_FILE" ]]; then
        die "Cannot read public key file: $SSH_PUBKEY_FILE"
    fi

    KEY_LINE_COUNT="$(
        grep -cve '^[[:space:]]*$' "$SSH_PUBKEY_FILE" || true
    )"

    if [[ "$KEY_LINE_COUNT" -ne 1 ]]; then
        die "The public key file must contain exactly one public key."
    fi

    SSH_PUBKEY="$(
        grep -ve '^[[:space:]]*$' "$SSH_PUBKEY_FILE" |
        head -n 1 |
        sed 's/\r$//'
    )"
fi


case "$SSH_PUBKEY" in
    ssh-*|ecdsa-*|sk-*)
        ;;
    *)
        die "The supplied value does not look like an OpenSSH public key."
        ;;
esac


# ------------------------------------------------------------------------------
# Validate operating system
# ------------------------------------------------------------------------------

log "OPERATING SYSTEM"

if [[ ! -r /etc/os-release ]]; then
    die "/etc/os-release is missing."
fi

# shellcheck disable=SC1091
source /etc/os-release


if [[ "${ID:-}" != "ubuntu" ]]; then
    die "This bootstrap currently supports Ubuntu only."
fi


case "${VERSION_ID:-}" in
    22.04|24.04|26.04)
        ;;
    *)
        die \
            "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. \
Use Ubuntu 22.04, 24.04 or 26.04."
        ;;
esac


echo "Distribution : ${PRETTY_NAME:-Ubuntu}"
echo "Kernel       : $(uname -r)"
echo "Architecture : $(uname -m)"


# ------------------------------------------------------------------------------
# Configure non-interactive package management
# ------------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1

APT_OPTIONS=(
    -y
    -o Dpkg::Options::=--force-confold
)


# ------------------------------------------------------------------------------
# Update package indexes
# ------------------------------------------------------------------------------

log "APT UPDATE"

apt-get update


# ------------------------------------------------------------------------------
# Upgrade existing packages
# ------------------------------------------------------------------------------

if [[ "$PACKAGE_UPGRADE" -eq 1 ]]; then

    log "PACKAGE UPGRADE"

    apt-get "${APT_OPTIONS[@]}" upgrade

else

    log "PACKAGE UPGRADE SKIPPED"

fi


# ------------------------------------------------------------------------------
# Install base dependencies
# ------------------------------------------------------------------------------

log "BASE PACKAGES"

apt-get "${APT_OPTIONS[@]}" install \
    ca-certificates \
    curl \
    gnupg \
    jq \
    openssh-client \
    openssh-server \
    sudo \
    unattended-upgrades \
    iproute2 \
    iptables \
    ipset \
    e2fsprogs


# ------------------------------------------------------------------------------
# Validate SSH public key using OpenSSH
# ------------------------------------------------------------------------------

log "SSH PUBLIC KEY VALIDATION"

KEY_TMP="$(mktemp)"

printf '%s\n' "$SSH_PUBKEY" > "$KEY_TMP"

if ! ssh-keygen -l -f "$KEY_TMP"; then
    rm -f "$KEY_TMP"
    die "OpenSSH rejected the supplied public key."
fi

rm -f "$KEY_TMP"


# ------------------------------------------------------------------------------
# Create VPN management user
# ------------------------------------------------------------------------------

log "VPN MANAGEMENT USER"

if id "$VPN_USER" >/dev/null 2>&1; then

    echo "User already exists: $VPN_USER"

else

    useradd \
        --create-home \
        --shell /bin/bash \
        "$VPN_USER"

    echo "Created user: $VPN_USER"

fi


# Ensure the account has a normal shell.

usermod \
    --shell /bin/bash \
    "$VPN_USER"


# Disable Unix password login for the account.
# SSH public-key authentication will be used instead.

passwd -l "$VPN_USER" >/dev/null 2>&1 || true


# Add the management user to Ubuntu's sudo group.

usermod \
    -aG sudo \
    "$VPN_USER"


# ------------------------------------------------------------------------------
# Configure passwordless sudo
# ------------------------------------------------------------------------------

log "SUDO CONFIGURATION"

SUDOERS_FILE="/etc/sudoers.d/90-vpn-management-${VPN_USER}"
SUDOERS_TMP="$(mktemp)"

printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' \
    "$VPN_USER" \
    > "$SUDOERS_TMP"

chmod 440 "$SUDOERS_TMP"

if ! visudo -cf "$SUDOERS_TMP"; then
    rm -f "$SUDOERS_TMP"
    die "Generated sudoers configuration is invalid."
fi

install \
    -o root \
    -g root \
    -m 0440 \
    "$SUDOERS_TMP" \
    "$SUDOERS_FILE"

rm -f "$SUDOERS_TMP"

echo "Passwordless sudo configured for: $VPN_USER"


# ------------------------------------------------------------------------------
# Install SSH authorized key
# ------------------------------------------------------------------------------

log "SSH AUTHORIZED KEY"

USER_HOME="$(
    getent passwd "$VPN_USER" |
    cut -d: -f6
)"

if [[ -z "$USER_HOME" ]]; then
    die "Could not determine home directory for $VPN_USER."
fi


install \
    -d \
    -o "$VPN_USER" \
    -g "$VPN_USER" \
    -m 0700 \
    "$USER_HOME/.ssh"


AUTHORIZED_KEYS="$USER_HOME/.ssh/authorized_keys"

touch "$AUTHORIZED_KEYS"

chown \
    "$VPN_USER:$VPN_USER" \
    "$AUTHORIZED_KEYS"

chmod 0600 "$AUTHORIZED_KEYS"


if ! grep -qxF "$SSH_PUBKEY" "$AUTHORIZED_KEYS"; then
    printf '%s\n' "$SSH_PUBKEY" >> "$AUTHORIZED_KEYS"
fi


chown \
    "$VPN_USER:$VPN_USER" \
    "$AUTHORIZED_KEYS"

chmod 0600 "$AUTHORIZED_KEYS"

echo "SSH public key installed for: $VPN_USER"


# ------------------------------------------------------------------------------
# Configure swap
# ------------------------------------------------------------------------------

log "SWAP"

if swapon --show --noheadings | grep -q .; then

    echo "Active swap already exists."
    echo "Existing swap will not be modified."
    swapon --show

else

    case "${SWAP_SIZE,,}" in

        none|off|0)
            echo "Swap creation disabled."
            ;;

        auto)

            MEM_KIB="$(
                awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo
            )"

            if [[ ! "$MEM_KIB" =~ ^[0-9]+$ ]]; then
                die "Could not determine installed RAM."
            fi

            SWAP_BYTES=$(( MEM_KIB * 1024 ))
            ;;

        *)

            if ! SWAP_BYTES="$(
                numfmt \
                    --from=iec \
                    "$SWAP_SIZE" \
                    2>/dev/null
            )"; then
                die \
                    "Invalid --swap value '$SWAP_SIZE'. \
Use auto, none, 512M, 1G, 2G, etc."
            fi

            if (( SWAP_BYTES < 64 * 1024 * 1024 )); then
                die "Swap must be at least 64 MiB, or use --swap none."
            fi
            ;;
    esac


    if [[ "${SWAP_SIZE,,}" != "none" &&
          "${SWAP_SIZE,,}" != "off" &&
          "$SWAP_SIZE" != "0" ]]; then

        SWAP_MIB=$(
            (
                SWAP_BYTES + 1024 * 1024 - 1
            ) / (1024 * 1024)
        )

        SWAP_DISPLAY="$(
            numfmt \
                --to=iec-i \
                --suffix=B \
                "$(( SWAP_MIB * 1024 * 1024 ))"
        )"

        DISK_AVAILABLE="$(
            df \
                -B1 \
                --output=avail \
                / |
            tail -n 1 |
            tr -d ' '
        )"

        DISK_RESERVE=$(( 256 * 1024 * 1024 ))

        if (( SWAP_MIB * 1024 * 1024 + DISK_RESERVE > DISK_AVAILABLE )); then
            die \
                "Not enough free disk space for $SWAP_DISPLAY swap \
while keeping 256 MiB reserved."
        fi


        echo "Creating swap: $SWAP_DISPLAY"


        if [[ -e /swapfile ]]; then
            swapoff /swapfile >/dev/null 2>&1 || true
            rm -f /swapfile
        fi


        ROOT_FS="$(
            findmnt \
                -n \
                -o FSTYPE \
                /
        )"


        if [[ "$ROOT_FS" == "btrfs" ]]; then

            touch /swapfile

            if ! chattr +C /swapfile; then
                rm -f /swapfile
                die "Could not disable copy-on-write for Btrfs swapfile."
            fi

        fi


        dd \
            if=/dev/zero \
            of=/swapfile \
            bs=1M \
            count="$SWAP_MIB" \
            status=progress


        chmod 0600 /swapfile

        mkswap /swapfile >/dev/null

        swapon /swapfile


        if ! grep -qE \
            '^[[:space:]]*/swapfile[[:space:]]' \
            /etc/fstab; then

            echo '/swapfile none swap sw 0 0' \
                >> /etc/fstab
        fi


        echo
        swapon --show

    fi
fi


# ------------------------------------------------------------------------------
# Configure unattended Ubuntu security updates
# ------------------------------------------------------------------------------

log "AUTOMATIC SECURITY UPDATES"

cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF


cat > /etc/apt/apt.conf.d/52-vpn-bootstrap <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF


systemctl enable \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    >/dev/null 2>&1 || true


systemctl start \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    >/dev/null 2>&1 || true


echo "Automatic Ubuntu security updates enabled."
echo "Automatic reboots disabled."


# ------------------------------------------------------------------------------
# Install Docker Engine from Docker's official repository
# ------------------------------------------------------------------------------

log "DOCKER ENGINE"


if ! dpkg-query \
        -W \
        -f='${Status}' \
        docker-ce \
        2>/dev/null |
        grep -q 'ok installed'; then

    CONFLICTING_PACKAGES=()

    for package in \
        docker.io \
        docker-compose \
        docker-compose-v2 \
        docker-doc \
        docker-buildx \
        podman-docker \
        containerd \
        runc
    do

        if dpkg-query \
            -W \
            -f='${Status}' \
            "$package" \
            2>/dev/null |
            grep -q 'ok installed'; then

            CONFLICTING_PACKAGES+=("$package")
        fi

    done


    if (( ${#CONFLICTING_PACKAGES[@]} > 0 )); then

        echo "Removing conflicting container packages:"
        printf '  %s\n' "${CONFLICTING_PACKAGES[@]}"

        apt-get "${APT_OPTIONS[@]}" remove \
            "${CONFLICTING_PACKAGES[@]}"

    fi
fi


install \
    -m 0755 \
    -d \
    /etc/apt/keyrings


curl \
    -fsSL \
    https://download.docker.com/linux/ubuntu/gpg \
    -o /etc/apt/keyrings/docker.asc


chmod \
    a+r \
    /etc/apt/keyrings/docker.asc


DOCKER_CODENAME="${
    UBUNTU_CODENAME:-${VERSION_CODENAME:-}
}"

if [[ -z "$DOCKER_CODENAME" ]]; then
    die "Could not determine Ubuntu codename for Docker repository."
fi


DOCKER_ARCH="$(
    dpkg --print-architecture
)"


cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${DOCKER_CODENAME}
Components: stable
Architectures: ${DOCKER_ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF


apt-get update


apt-get "${APT_OPTIONS[@]}" install \
    docker-ce \
    docker-ce-cli \
    containerd.io \
    docker-buildx-plugin \
    docker-compose-plugin


systemctl enable \
    --now \
    docker


if ! systemctl is-active \
        --quiet \
        docker; then

    die "Docker service is not running."
fi


if ! docker info >/dev/null 2>&1; then
    die "Docker daemon is running but docker info failed."
fi


echo "Docker installed successfully."

docker --version
docker compose version
containerd --version | head -n 1


# ------------------------------------------------------------------------------
# Configure SSH hardening
# ------------------------------------------------------------------------------

log "SSH HARDENING"

SSH_MAIN="/etc/ssh/sshd_config"
SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
SSH_DROPIN="${SSH_DROPIN_DIR}/00-vpn-bootstrap.conf"


mkdir -p "$SSH_DROPIN_DIR"


# Ensure sshd_config loads drop-in configuration files.
# The Include directive is inserted at the beginning when missing because
# OpenSSH generally uses the first obtained value for a setting.

if ! grep -Eq \
    '^[[:space:]]*Include[[:space:]]+/etc/ssh/sshd_config.d/\*\.conf' \
    "$SSH_MAIN"; then

    SSH_BACKUP="${
        SSH_MAIN
    }.vpn-bootstrap-backup.$(
        date +%Y%m%d-%H%M%S
    )"

    cp \
        -a \
        "$SSH_MAIN" \
        "$SSH_BACKUP"

    SSH_TMP="$(mktemp)"

    {
        echo 'Include /etc/ssh/sshd_config.d/*.conf'
        cat "$SSH_MAIN"
    } > "$SSH_TMP"

    install \
        -o root \
        -g root \
        -m 0644 \
        "$SSH_TMP" \
        "$SSH_MAIN"

    rm -f "$SSH_TMP"

fi


cat > "$SSH_DROPIN" <<'EOF'
PermitRootLogin no

PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitEmptyPasswords no

MaxAuthTries 3

X11Forwarding no
EOF


chmod 0644 "$SSH_DROPIN"


# Validate complete SSH configuration before reloading sshd.

sshd -t


SSH_EFFECTIVE="$(
    sshd -T |
    grep -E \
        '^(permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|maxauthtries|x11forwarding) '
)"


verify_ssh_setting() {

    local expected="$1"

    if ! grep \
        -qx \
        "$expected" \
        <<< "$SSH_EFFECTIVE"; then

        echo
        echo "Effective sshd configuration:"
        echo "$SSH_EFFECTIVE"

        die "Expected SSH setting is not effective: $expected"
    fi
}


verify_ssh_setting \
    'permitrootlogin no'

verify_ssh_setting \
    'pubkeyauthentication yes'

verify_ssh_setting \
    'passwordauthentication no'

verify_ssh_setting \
    'kbdinteractiveauthentication no'

verify_ssh_setting \
    'permitemptypasswords no'

verify_ssh_setting \
    'maxauthtries 3'

verify_ssh_setting \
    'x11forwarding no'


systemctl reload ssh


if ! systemctl is-active \
        --quiet \
        ssh; then

    die "SSH service is not running after configuration reload."
fi


echo "$SSH_EFFECTIVE"


# ------------------------------------------------------------------------------
# Network diagnostics
# ------------------------------------------------------------------------------

log "NETWORK"


echo "--- IPv4 addresses ---"
ip -4 -br addr || true

echo
echo "--- IPv4 routes ---"
ip -4 route || true


echo
echo "--- IPv6 addresses ---"
ip -6 -br addr || true

echo
echo "--- IPv6 routes ---"
ip -6 route || true


SERVER_IPV4="$(
    ip \
        -4 \
        route get \
        1.1.1.1 \
        2>/dev/null |
    awk '
        {
            for (i = 1; i <= NF; i++) {
                if ($i == "src") {
                    print $(i + 1)
                    exit
                }
            }
        }
    '
)"


GLOBAL_IPV6="$(
    ip \
        -6 \
        -o \
        addr show \
        scope global \
        2>/dev/null |
    awk '
        {
            print $4
            exit
        }
    '
)"


echo
echo "--- IPv6 connectivity ---"

if [[ -n "$GLOBAL_IPV6" ]]; then

    echo "Global IPv6 address: $GLOBAL_IPV6"

    if ping \
        -6 \
        -c 2 \
        -W 2 \
        2606:4700:4700::1111 \
        >/dev/null 2>&1; then

        echo "IPv6 outbound connectivity: OK"

    else

        echo "IPv6 outbound connectivity: NOT WORKING"

    fi

else

    echo "No global IPv6 address configured."

fi


# ------------------------------------------------------------------------------
# Check ports needed by the future VPN services
# ------------------------------------------------------------------------------

log "VPN PORT PRE-CHECK"


if ss -ltnH |
    awk '{print $4}' |
    grep -Eq '(^|:|\])443$'; then

    echo "WARNING: TCP/443 is already occupied:"
    ss -ltnp | grep ':443 ' || true

else

    echo "TCP/443: FREE"

fi


# ------------------------------------------------------------------------------
# Final system information
# ------------------------------------------------------------------------------

log "RESOURCE SUMMARY"

free -h

echo
swapon --show || true

echo
df -h /


log "DOCKER SUMMARY"

docker info \
    --format \
    'Server Version: {{.ServerVersion}}
Storage Driver: {{.Driver}}
Cgroup Driver: {{.CgroupDriver}}
Containers: {{.Containers}}
Images: {{.Images}}'


log "SSH SUMMARY"

SSH_PORT="$(
    sshd -T |
    awk '
        $1 == "port" {
            print $2
            exit
        }
    '
)"

echo "VPN management user : $VPN_USER"
echo "SSH port            : ${SSH_PORT:-unknown}"
echo "IPv4                : ${SERVER_IPV4:-unknown}"
echo "IPv6                : ${GLOBAL_IPV6:-none}"
echo
echo "$SSH_EFFECTIVE"


# ------------------------------------------------------------------------------
# Reboot state
# ------------------------------------------------------------------------------

log "BOOTSTRAP RESULT"

echo "VPN server bootstrap completed successfully."
echo
echo "SSH root login         : disabled"
echo "SSH password login     : disabled"
echo "SSH public-key login   : enabled"
echo "VPN management user    : $VPN_USER"
echo "Passwordless sudo      : enabled"
echo "Docker Engine          : installed"
echo "Automatic sec. updates : enabled"
echo "Automatic reboot       : disabled"

if swapon --show --noheadings | grep -q .; then
    echo "Swap                  : enabled"
else
    echo "Swap                  : disabled"
fi


if [[ -f /var/run/reboot-required ]]; then

    echo
    echo "REBOOT REQUIRED:"
    echo "Ubuntu installed updates that require a reboot."
    echo "The script intentionally does not reboot the server automatically."

fi


echo
echo "IMPORTANT:"
echo "Before closing your current SSH session, verify a new login:"
echo

if [[ -n "$SERVER_IPV4" ]]; then

    if [[ "$SSH_PORT" == "22" ]]; then
        echo "    ssh ${VPN_USER}@${SERVER_IPV4}"
    else
        echo "    ssh -p ${SSH_PORT} ${VPN_USER}@${SERVER_IPV4}"
    fi

else

    echo "    ssh ${VPN_USER}@SERVER_IP"

fi

echo
echo "Then verify privileges with:"
echo
echo "    sudo id"
echo
echo "Expected result: uid=0(root)"
echo
