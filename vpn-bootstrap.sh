#!/usr/bin/env bash
set -Eeuo pipefail

# ==============================================================================
# Incremental VPN server bootstrap for Ubuntu 22.04 / 24.04 LTS
#
# Installs and maintains:
#   - VPN management user with SSH public-key access and passwordless sudo
#   - Explicit second-step SSH hardening after testing the management login
#   - Optional swap (default: approximately equal to installed RAM)
#   - Unattended Ubuntu security updates (without automatic reboot)
#   - Docker Engine from Docker's official repository
#   - UFW firewall (SSH + Xray TCP port only)
#   - Xray-core: VLESS + XTLS Vision + REALITY
#   - Xray runs as the official image's non-root user on a Docker bridge network
#     (host VPN port is published to an unprivileged container port)
#   - Optional, explicit opt-in blocking of Russian destinations on Xray.
#     Selective site/app routing is done on sing-box clients (default: direct).
#   - Persistent per-device VPN user management commands
#
# The script is incremental/idempotent:
#   - Existing users, keys, VPN users and REALITY keys are preserved.
#   - Existing active swap is preserved.
#   - Existing Docker installation is reused if functional.
#   - Xray configuration is regenerated from persistent state without rotating keys.
#   - Re-running preserves credentials; configuration changes recreate Xray briefly.
#   - Package, user, swap and firewall changes are NOT a full system transaction.
#
# The script never reboots the server and never upgrades Ubuntu to another release.
#
# Required options:
#   --user USER
#   --pubkey KEY              OR --pubkey-file FILE
#
# Common options:
#   --swap auto|none|SIZE     Default: auto. Examples: 512M, 1G, 2G.
#   --endpoint HOST           Client endpoint. Default: auto-detected public IPv4.
#   --xray-port PORT          Default on first install: 443.
#   --reality-target HOST     Default on first install: www.microsoft.com.
#   --xray-image IMAGE        Default on first install: ghcr.io/xtls/xray-core:26.3.27.
#                             The exact stable version is pinned for reproducibility;
#                             every run checks GitHub's latest stable release and warns
#                             when the configured version is outdated.
#   --block-ru                Enable RU destination blocking (opt-in on first install).
#   --no-block-ru             Disable RU destination blocking.
#   --no-firewall             Do not configure/enable UFW.
#   --harden-ssh              Second step: run via sudo from the management user.
#   --no-ssh-hardening        Keep SSH authentication unchanged (the default).
#   --skip-package-upgrade    Skip apt-get upgrade.
#   --help
#
# Example:
#   sudo ./vpn-bootstrap.sh \
#     --user vpn \
#     --pubkey-file /root/id_ed25519.pub \
#     --swap auto
# ==============================================================================

SCRIPT_NAME="$(basename "$0")"
VPN_ROOT="/opt/vpn-stack"
XRAY_DIR="$VPN_ROOT/xray"
USERS_FILE="$VPN_ROOT/users.json"
STATE_FILE="$VPN_ROOT/state.json"
COMPOSE_FILE="$VPN_ROOT/compose.yml"
LOCK_FILE="$VPN_ROOT/.lock"
XRAY_CONTAINER="xray-reality"

VPN_USER=""
SSH_PUBKEY=""
SSH_PUBKEY_FILE=""
SWAP_SIZE="auto"
ENDPOINT_ARG=""
XRAY_PORT_ARG=""
REALITY_TARGET_ARG=""
XRAY_IMAGE_ARG=""
BLOCK_RU_ARG=""
CONFIGURE_FIREWALL=1
SSH_HARDENING=0
PACKAGE_UPGRADE=1

DEFAULT_XRAY_PORT=443
DEFAULT_REALITY_TARGET="www.microsoft.com"
DEFAULT_XRAY_IMAGE="ghcr.io/xtls/xray-core:26.3.27"
LEGACY_BOOTSTRAP_PRERELEASE_IMAGE="ghcr.io/xtls/xray-core:26.9.8"
XRAY_RELEASES_API="https://api.github.com/repos/XTLS/Xray-core/releases"

log() {
    printf '\n===== %s =====\n' "$*"
}

die() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARNING: $*" >&2
}

usage() {
    cat <<'EOF'
Usage:
  sudo ./vpn-bootstrap.sh --user USER (--pubkey KEY | --pubkey-file FILE) [OPTIONS]

Required:
  --user USER                 VPN management user to create or maintain.
  --pubkey KEY                OpenSSH public key as one quoted argument.
  --pubkey-file FILE          Read exactly one OpenSSH public key from FILE.
                              Use either --pubkey or --pubkey-file.

Options:
  --swap auto|none|SIZE       Swap policy. Default: auto (approximately RAM size).
                              Examples: none, 512M, 1G, 2G.
  --endpoint HOST             Client endpoint. Default: detected public IPv4.
  --xray-port PORT            Xray TCP port. Default on first install: 443.
  --reality-target HOST       REALITY target/SNI hostname.
                              Default on first install: www.microsoft.com.
  --xray-image IMAGE          Pin a specific Xray Docker image.
                              Default on first install: ghcr.io/xtls/xray-core:26.3.27.
  --block-ru                  Block Russian IP destinations and .ru/.su/.рф domains.
                              Disabled by default on first install.
  --no-block-ru               Disable RU destination blocking.
  --no-firewall               Do not configure or enable UFW.
  --harden-ssh                Second step, after testing a new management-user SSH login.
                              Must be run via sudo as that user; disables root/password login.
  --no-ssh-hardening          Leave SSH authentication unchanged (default).
  --skip-package-upgrade      Skip apt-get upgrade.
  --help, -h                  Show this help and exit.

Behavior:
  - Non-interactive: the script never asks questions while running.
  - Incremental: existing VPN users and REALITY keys are preserved.
  - Existing active swap is preserved.
  - Functional Docker is reused.
  - The pinned Xray version is checked against GitHub's latest stable release.
    A failed online version check does not abort installation.
  - The server is never rebooted automatically.

Example:
  sudo ./vpn-bootstrap.sh \
    --user vpn \
    --pubkey-file /root/id_ed25519.pub \
    --swap auto
EOF
}

require_value() {
    local option="$1"
    local value="${2:-}"
    if [[ -z "$value" || "$value" == --* ]]; then
        die "$option requires a value."
    fi
}

json_bool() {
    [[ "$1" == "1" ]] && printf 'true' || printf 'false'
}

is_valid_port() {
    [[ "$1" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 ))
}

is_valid_username() {
    [[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]
}

is_valid_hostname_or_ip() {
    local value="$1"
    # Hostnames, IPv4 and unbracketed IPv6 only; exclude URL/YAML metacharacters.
    [[ -n "$value" && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9.:-]*$ ]]
}

url_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

xray_image_tag() {
    local image="$1"

    # Only compare the official Xray image when it uses a simple version tag.
    [[ "$image" == ghcr.io/xtls/xray-core:* ]] || return 1
    [[ "$image" != *@* ]] || return 1

    local tag="${image##*:}"
    [[ "$tag" =~ ^v?[0-9]+([.][0-9]+)+$ ]] || return 1
    printf '%s\n' "${tag#v}"
}

version_is_older() {
    local current="$1"
    local latest="$2"
    [[ "$current" != "$latest" ]] || return 1
    [[ "$(printf '%s\n%s\n' "$current" "$latest" | sort -V | tail -n 1)" == "$latest" ]]
}

check_xray_version() {
    local image="$1"
    local current latest_json latest_tag latest current_release prerelease release_url

    current="$(xray_image_tag "$image" 2>/dev/null || true)"

    if [[ -z "$current" ]]; then
        warn "Xray stable-version comparison skipped for custom/unversioned image: $image"
        return 0
    fi

    latest_json="$(
        curl -fsSL \
            --connect-timeout 4 \
            --max-time 8 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: vpn-bootstrap-xray-version-check' \
            "${XRAY_RELEASES_API}/latest" \
            2>/dev/null || true
    )"

    latest_tag="$(jq -r '.tag_name // empty' <<< "$latest_json" 2>/dev/null || true)"
    latest="${latest_tag#v}"

    if [[ -z "$latest" || ! "$latest" =~ ^[0-9]+([.][0-9]+)+$ ]]; then
        warn "Could not determine the latest stable Xray release from GitHub; continuing with $image."
        return 0
    fi

    # Check whether the currently pinned release itself is marked as a prerelease.
    # Try the usual v-prefixed release tag first, then the plain version tag.
    current_release="$(
        curl -fsSL \
            --connect-timeout 4 \
            --max-time 8 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: vpn-bootstrap-xray-version-check' \
            "${XRAY_RELEASES_API}/tags/v${current}" \
            2>/dev/null || \
        curl -fsSL \
            --connect-timeout 4 \
            --max-time 8 \
            -H 'Accept: application/vnd.github+json' \
            -H 'User-Agent: vpn-bootstrap-xray-version-check' \
            "${XRAY_RELEASES_API}/tags/${current}" \
            2>/dev/null || true
    )"

    prerelease="$(jq -r '.prerelease // empty' <<< "$current_release" 2>/dev/null || true)"
    release_url="$(jq -r '.html_url // empty' <<< "$latest_json" 2>/dev/null || true)"

    echo "Pinned Xray version : $current"
    echo "Latest stable Xray : $latest"

    if [[ "$prerelease" == "true" ]]; then
        warn "Pinned Xray $current is marked as a PRE-RELEASE by GitHub."
    fi

    if version_is_older "$current" "$latest"; then
        warn "Pinned Xray $current is OUTDATED; latest stable is $latest."
        warn "To upgrade intentionally, rerun with: --xray-image ghcr.io/xtls/xray-core:${latest}"
        [[ -n "$release_url" ]] && warn "Release: $release_url"
    elif [[ "$current" == "$latest" ]]; then
        echo "Xray stable-version check: up to date."
    else
        # A newer numeric version than the latest stable is usually a prerelease.
        warn "Pinned Xray $current is newer than the latest stable $latest; verify that this is intentional."
    fi
}

STATE_BACKUP_DIR=""
STATE_TRANSACTION=0
SSH_BACKUP_DIR=""
SSH_TRANSACTION=0
IPV6_PROBE_FILE=""

rollback_pending() {
    if [[ "$SSH_TRANSACTION" -eq 1 && -n "$SSH_BACKUP_DIR" ]]; then
        warn "Restoring SSH configuration after a failed hardening step."
        cp -a "$SSH_BACKUP_DIR/main" /etc/ssh/sshd_config
        if [[ -f "$SSH_BACKUP_DIR/dropin" ]]; then
            cp -a "$SSH_BACKUP_DIR/dropin" /etc/ssh/sshd_config.d/00-vpn-bootstrap.conf
        else
            rm -f /etc/ssh/sshd_config.d/00-vpn-bootstrap.conf
        fi
        systemctl reload ssh || true
        SSH_TRANSACTION=0
    fi
    if [[ "$STATE_TRANSACTION" -eq 1 && -n "$STATE_BACKUP_DIR" ]]; then
        warn "Restoring previous Xray state after a failed deployment."
        if [[ -f "$STATE_BACKUP_DIR/state.json" ]]; then
            cp -a "$STATE_BACKUP_DIR/state.json" "$STATE_FILE"
        else
            rm -f "$STATE_FILE"
        fi
        STATE_TRANSACTION=0
    fi
}
cleanup_bootstrap() {
    local rc=$?
    trap - EXIT
    rollback_pending
    [[ -z "$STATE_BACKUP_DIR" ]] || rm -rf -- "$STATE_BACKUP_DIR"
    [[ -z "$SSH_BACKUP_DIR" ]] || rm -rf -- "$SSH_BACKUP_DIR"
    [[ -z "$IPV6_PROBE_FILE" ]] || rm -f -- "$IPV6_PROBE_FILE"
    exit "$rc"
}
trap cleanup_bootstrap EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap '
    rc=$?
    if (( BASH_SUBSHELL == 0 )); then
        echo "ERROR: bootstrap failed at line $LINENO (exit $rc)." >&2
    fi
    exit "$rc"
' ERR

# ------------------------------------------------------------------------------
# Parse command-line options
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
        --endpoint)
            require_value "$1" "${2:-}"
            ENDPOINT_ARG="$2"
            shift 2
            ;;
        --xray-port)
            require_value "$1" "${2:-}"
            XRAY_PORT_ARG="$2"
            shift 2
            ;;
        --reality-target)
            require_value "$1" "${2:-}"
            REALITY_TARGET_ARG="$2"
            shift 2
            ;;
        --xray-image)
            require_value "$1" "${2:-}"
            XRAY_IMAGE_ARG="$2"
            shift 2
            ;;
        --block-ru)
            BLOCK_RU_ARG="true"
            shift
            ;;
        --no-block-ru)
            BLOCK_RU_ARG="false"
            shift
            ;;
        --no-firewall)
            CONFIGURE_FIREWALL=0
            shift
            ;;
        --harden-ssh)
            SSH_HARDENING=1
            shift
            ;;
        --no-ssh-hardening)
            SSH_HARDENING=0
            shift
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
# Validate arguments and execution context
# ------------------------------------------------------------------------------

[[ "$EUID" -eq 0 ]] || die "Run this script as root or through sudo."
[[ -n "$VPN_USER" ]] || die "--user is required."
is_valid_username "$VPN_USER" || die "Invalid VPN management username: $VPN_USER"
[[ "$VPN_USER" != "root" ]] || die "The VPN management username cannot be root."
if [[ "$SSH_HARDENING" -eq 1 && "${SUDO_USER:-}" != "$VPN_USER" ]]; then
    die "First test a NEW SSH login as $VPN_USER, then rerun via sudo with --harden-ssh from that login."
fi
# Serialize the complete bootstrap before package/user/firewall changes.
command -v flock >/dev/null || die "flock (util-linux) is required."
exec 8>/run/lock/vpn-bootstrap.lock
flock -n -x 8 || die "Another bootstrap is already running."

if [[ -n "$SSH_PUBKEY" && -n "$SSH_PUBKEY_FILE" ]]; then
    die "Use either --pubkey or --pubkey-file, not both."
fi

if [[ -z "$SSH_PUBKEY" && -z "$SSH_PUBKEY_FILE" ]]; then
    die "One of --pubkey or --pubkey-file is required."
fi

if [[ -n "$XRAY_PORT_ARG" ]]; then
    is_valid_port "$XRAY_PORT_ARG" || die "Invalid --xray-port: $XRAY_PORT_ARG"
fi

if [[ -n "$ENDPOINT_ARG" ]]; then
    is_valid_hostname_or_ip "$ENDPOINT_ARG" || die "Invalid --endpoint: $ENDPOINT_ARG"
fi

if [[ -n "$REALITY_TARGET_ARG" ]]; then
    is_valid_hostname_or_ip "$REALITY_TARGET_ARG" || die "Invalid --reality-target: $REALITY_TARGET_ARG"
    [[ "$REALITY_TARGET_ARG" != *:* ]] || die "--reality-target must be a hostname without a port."
fi

if [[ -n "$SSH_PUBKEY_FILE" ]]; then
    [[ -r "$SSH_PUBKEY_FILE" ]] || die "Cannot read public key file: $SSH_PUBKEY_FILE"
    KEY_LINE_COUNT="$(grep -cve '^[[:space:]]*$' "$SSH_PUBKEY_FILE" || true)"
    [[ "$KEY_LINE_COUNT" -eq 1 ]] || die "The public key file must contain exactly one public key."
    SSH_PUBKEY="$(awk 'NF { sub(/\r$/, ""); print }' "$SSH_PUBKEY_FILE")"
fi

[[ "$SSH_PUBKEY" != *$'\n'* && "$SSH_PUBKEY" != *$'\r'* ]] || die "Supply exactly one public key line."
case "$SSH_PUBKEY" in
    ssh-*|ecdsa-*|sk-*) ;;
    *) die "The supplied value does not look like an OpenSSH public key." ;;
esac

# ------------------------------------------------------------------------------
# Validate operating system
# ------------------------------------------------------------------------------

log "OPERATING SYSTEM"
[[ -r /etc/os-release ]] || die "/etc/os-release is missing."
# shellcheck disable=SC1091
source /etc/os-release
[[ "${ID:-}" == "ubuntu" ]] || die "This bootstrap currently supports Ubuntu only."
case "${VERSION_ID:-}" in
    22.04|24.04) ;;
    *) die "Unsupported Ubuntu version: ${VERSION_ID:-unknown}. Use Ubuntu 22.04 or 24.04 LTS." ;;
esac

echo "Distribution : ${PRETTY_NAME:-Ubuntu}"
echo "Kernel       : $(uname -r)"
echo "Architecture : $(uname -m)"

# ------------------------------------------------------------------------------
# Wait for cloud-init/apt package locks
# ------------------------------------------------------------------------------

wait_for_apt() {
    local waited=0
    local max_wait=300
    while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/cache/apt/archives/lock >/dev/null 2>&1; do
        if (( waited >= max_wait )); then
            die "APT/dpkg remained locked for more than ${max_wait}s."
        fi
        sleep 2
        waited=$(( waited + 2 ))
    done
}

export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a
export UCF_FORCE_CONFFOLD=1
APT_OPTIONS=(
    -y
    -o DPkg::Lock::Timeout=300
    -o Dpkg::Options::=--force-confdef
    -o Dpkg::Options::=--force-confold
)

log "PACKAGE INDEX"
wait_for_apt
apt-get update

if [[ "$PACKAGE_UPGRADE" -eq 1 ]]; then
    log "PACKAGE UPGRADE"
    wait_for_apt
    apt-get "${APT_OPTIONS[@]}" upgrade
else
    log "PACKAGE UPGRADE SKIPPED"
fi

log "BASE PACKAGES"
wait_for_apt
apt-get "${APT_OPTIONS[@]}" install \
    ca-certificates \
    curl \
    gnupg \
    jq \
    openssh-client \
    openssh-server \
    openssl \
    sudo \
    unattended-upgrades \
    iproute2 \
    iptables \
    ufw \
    netcat-openbsd \
    qrencode \
    util-linux \
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
# Create/update VPN management user
# ------------------------------------------------------------------------------

log "VPN MANAGEMENT USER"
if id "$VPN_USER" >/dev/null 2>&1; then
    echo "User already exists: $VPN_USER"
else
    useradd --create-home --shell /bin/bash "$VPN_USER"
    echo "Created user: $VPN_USER"
fi

usermod --shell /bin/bash "$VPN_USER"
usermod -aG sudo "$VPN_USER"
passwd -l "$VPN_USER" >/dev/null 2>&1 || true

SUDOERS_FILE="/etc/sudoers.d/90-vpn-management-${VPN_USER}"
SUDOERS_TMP="$(mktemp)"
printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$VPN_USER" > "$SUDOERS_TMP"
chmod 0440 "$SUDOERS_TMP"
visudo -cf "$SUDOERS_TMP" >/dev/null
install -o root -g root -m 0440 "$SUDOERS_TMP" "$SUDOERS_FILE"
rm -f "$SUDOERS_TMP"

USER_HOME="$(getent passwd "$VPN_USER" | cut -d: -f6)"
[[ -n "$USER_HOME" && "$USER_HOME" != "/" ]] || die "Invalid home directory for $VPN_USER."
USER_GROUP="$(id -gn "$VPN_USER")"
[[ ! -L "$USER_HOME/.ssh" && ! -L "$USER_HOME/.ssh/authorized_keys" ]] || die "SSH paths must not be symlinks."
install -d -o "$VPN_USER" -g "$USER_GROUP" -m 0700 "$USER_HOME/.ssh"
AUTHORIZED_KEYS="$USER_HOME/.ssh/authorized_keys"
touch "$AUTHORIZED_KEYS"
chown "$VPN_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"
if ! grep -qxF "$SSH_PUBKEY" "$AUTHORIZED_KEYS"; then
    printf '%s\n' "$SSH_PUBKEY" >> "$AUTHORIZED_KEYS"
fi
chown "$VPN_USER:$USER_GROUP" "$AUTHORIZED_KEYS"
chmod 0600 "$AUTHORIZED_KEYS"

echo "VPN management user ready: $VPN_USER"

# ------------------------------------------------------------------------------
# Configure swap
# ------------------------------------------------------------------------------

log "SWAP"
if [[ -n "$(swapon --show --noheadings)" ]]; then
    echo "Active swap already exists; leaving it unchanged."
    swapon --show
else
    CREATE_SWAP=1
    case "${SWAP_SIZE,,}" in
        none|off|0)
            CREATE_SWAP=0
            ;;
        auto)
            MEM_KIB="$(awk '/^MemTotal:/ && !found {print $2; found=1}' /proc/meminfo)"
            [[ "$MEM_KIB" =~ ^[0-9]+$ ]] || die "Could not determine installed RAM."
            SWAP_BYTES=$(( MEM_KIB * 1024 ))
            ;;
        *)
            SWAP_BYTES="$(numfmt --from=iec "$SWAP_SIZE" 2>/dev/null)" || \
                die "Invalid --swap value '$SWAP_SIZE'. Use auto, none, 512M, 1G, 2G, etc."
            (( SWAP_BYTES >= 64 * 1024 * 1024 )) || die "Swap must be at least 64 MiB, or use --swap none."
            ;;
    esac

    if [[ "$CREATE_SWAP" -eq 0 ]]; then
        echo "Swap creation disabled."
    else
        SWAP_MIB=$(( (SWAP_BYTES + 1024 * 1024 - 1) / (1024 * 1024) ))
        SWAP_DISPLAY="$(numfmt --to=iec-i --suffix=B "$(( SWAP_MIB * 1024 * 1024 ))")"
        DISK_AVAILABLE="$(df -B1 --output=avail / | tail -n 1 | tr -d ' ')"
        DISK_RESERVE=$(( 512 * 1024 * 1024 ))
        (( SWAP_MIB * 1024 * 1024 + DISK_RESERVE <= DISK_AVAILABLE )) || \
            die "Not enough free disk space for $SWAP_DISPLAY swap while keeping 512 MiB reserved."

        echo "Creating swap: $SWAP_DISPLAY"
        if [[ -e /swapfile ]]; then
            swapoff /swapfile >/dev/null 2>&1 || true
            rm -f /swapfile
        fi

        ROOT_FS="$(findmnt -n -o FSTYPE /)"
        if [[ "$ROOT_FS" == "btrfs" ]]; then
            touch /swapfile
            chattr +C /swapfile || { rm -f /swapfile; die "Could not disable CoW for Btrfs swapfile."; }
        fi

        dd if=/dev/zero of=/swapfile bs=1M count="$SWAP_MIB" status=progress
        chmod 0600 /swapfile
        mkswap /swapfile >/dev/null
        swapon /swapfile
        grep -qE '^[[:space:]]*/swapfile[[:space:]]' /etc/fstab || \
            echo '/swapfile none swap sw 0 0' >> /etc/fstab
        swapon --show
    fi
fi

# ------------------------------------------------------------------------------
# Enable unattended security updates without automatic reboot
# ------------------------------------------------------------------------------

log "AUTOMATIC SECURITY UPDATES"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

cat > /etc/apt/apt.conf.d/52-vpn-bootstrap <<'EOF'
Unattended-Upgrade::Automatic-Reboot "false";
EOF

systemctl enable apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true
systemctl start apt-daily.timer apt-daily-upgrade.timer >/dev/null 2>&1 || true

# ------------------------------------------------------------------------------
# Install/reuse Docker Engine
# ------------------------------------------------------------------------------

log "DOCKER ENGINE"
if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    echo "Functional Docker installation already exists; reusing it."
else
    # Remove packages that conflict with Docker CE when a partial/non-working
    # container runtime is already present. Existing Docker data under
    # /var/lib/docker is not deleted by this package removal.
    CONFLICTING_DOCKER_PACKAGES=()
    for package in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
        PACKAGE_STATUS="$(dpkg-query -W -f='${Status}' "$package" 2>/dev/null || true)"
        if [[ "$PACKAGE_STATUS" == "install ok installed" ]]; then
            CONFLICTING_DOCKER_PACKAGES+=("$package")
        fi
    done
    if (( ${#CONFLICTING_DOCKER_PACKAGES[@]} > 0 )); then
        echo "Removing conflicting container packages:"
        printf '  %s\n' "${CONFLICTING_DOCKER_PACKAGES[@]}"
        wait_for_apt
        apt-get "${APT_OPTIONS[@]}" remove "${CONFLICTING_DOCKER_PACKAGES[@]}"
    fi

    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc

    DOCKER_CODENAME="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    [[ -n "$DOCKER_CODENAME" ]] || die "Could not determine Ubuntu codename for Docker repository."
    DOCKER_ARCH="$(dpkg --print-architecture)"

    cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: ${DOCKER_CODENAME}
Components: stable
Architectures: ${DOCKER_ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
EOF

    wait_for_apt
    apt-get update
    wait_for_apt
    apt-get "${APT_OPTIONS[@]}" install \
        docker-ce \
        docker-ce-cli \
        containerd.io \
        docker-buildx-plugin \
        docker-compose-plugin
fi

systemctl enable --now docker
systemctl is-active --quiet docker || die "Docker service is not running."
docker info >/dev/null

echo "Docker: $(docker --version)"
if ! docker compose version >/dev/null 2>&1; then
    die "Docker works, but Compose v2 is missing. Install its plugin before rerunning."
fi
echo "Compose: $(docker compose version)"

# Keep Docker logs bounded and keep containers alive across daemon upgrades when possible.
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_DAEMON_TMP="$(mktemp)"
if [[ -s "$DOCKER_DAEMON_JSON" ]]; then
    jq empty "$DOCKER_DAEMON_JSON" || die "$DOCKER_DAEMON_JSON contains invalid JSON."
    jq '. + {"live-restore": true, "log-driver": "json-file", "log-opts": ((.["log-opts"] // {}) + {"max-size":"10m","max-file":"3"})}' \
        "$DOCKER_DAEMON_JSON" > "$DOCKER_DAEMON_TMP"
else
    jq -n '{"live-restore": true, "log-driver":"json-file", "log-opts":{"max-size":"10m","max-file":"3"}}' \
        > "$DOCKER_DAEMON_TMP"
fi

if [[ ! -f "$DOCKER_DAEMON_JSON" ]] || ! cmp -s "$DOCKER_DAEMON_TMP" "$DOCKER_DAEMON_JSON"; then
    dockerd --validate --config-file "$DOCKER_DAEMON_TMP" >/dev/null
    DOCKER_CONFIG_BACKUP="$(mktemp)"
    DOCKER_CONFIG_EXISTED=0
    if [[ -f "$DOCKER_DAEMON_JSON" ]]; then
        cp -a "$DOCKER_DAEMON_JSON" "$DOCKER_CONFIG_BACKUP"
        DOCKER_CONFIG_EXISTED=1
    fi
    install -o root -g root -m 0644 "$DOCKER_DAEMON_TMP" "$DOCKER_DAEMON_JSON"
    if ! systemctl restart docker || ! systemctl is-active --quiet docker; then
        if [[ "$DOCKER_CONFIG_EXISTED" -eq 1 ]]; then
            cp -a "$DOCKER_CONFIG_BACKUP" "$DOCKER_DAEMON_JSON"
        else
            rm -f "$DOCKER_DAEMON_JSON"
        fi
        systemctl restart docker || warn "Docker recovery failed; inspect journalctl -u docker."
        rm -f "$DOCKER_CONFIG_BACKUP" "$DOCKER_DAEMON_TMP"
        die "Docker rejected the new daemon settings; previous configuration restored."
    fi
    rm -f "$DOCKER_CONFIG_BACKUP"
fi
rm -f "$DOCKER_DAEMON_TMP"

# ------------------------------------------------------------------------------
# Harden SSH
# ------------------------------------------------------------------------------

# Union of configured ports, actual sshd listeners, socket-activation ports,
# and the server port of the current SSH connection (when preserved by sudo).
SSH_CONFIGURATION="$(sshd -T)"
mapfile -t SSH_PORTS <<< "$(
    {
        printf '%s\n' "$SSH_CONFIGURATION" | awk '$1 == "port" {print $2}'
        ss -H -ltnp | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}'
        systemctl show ssh.socket -p Listen --value 2>/dev/null |
            tr ' ' '\n' | sed -nE 's/.*:([0-9]+)$/\1/p' || true
        if [[ -n "${SSH_CONNECTION:-}" ]]; then
            read -r _ _ _ current_ssh_port <<< "$SSH_CONNECTION"
            printf '%s\n' "$current_ssh_port"
        fi
    } | awk '/^[0-9]+$/ && $1 > 0 && $1 <= 65535 {print $1}' | sort -nu
)"
(( ${#SSH_PORTS[@]} > 0 )) && is_valid_port "${SSH_PORTS[0]}" || die "Could not determine any SSH ports."
SSH_PORT="${SSH_PORTS[0]}"
printf 'Preserving SSH ports: %s\n' "${SSH_PORTS[*]}"

if [[ "$SSH_HARDENING" -eq 1 ]]; then
    log "SSH HARDENING"
    SSH_MAIN="/etc/ssh/sshd_config"
    SSH_DROPIN_DIR="/etc/ssh/sshd_config.d"
    SSH_DROPIN="$SSH_DROPIN_DIR/00-vpn-bootstrap.conf"
    mkdir -p "$SSH_DROPIN_DIR"
    SSH_BACKUP_DIR="$(mktemp -d /etc/ssh/.vpn-hardening.XXXXXX)"
    cp -a "$SSH_MAIN" "$SSH_BACKUP_DIR/main"
    [[ ! -f "$SSH_DROPIN" ]] || cp -a "$SSH_DROPIN" "$SSH_BACKUP_DIR/dropin"
    SSH_TRANSACTION=1

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

    MANAGED_INCLUDE='Include /etc/ssh/sshd_config.d/00-vpn-bootstrap.conf'
    if ! sed -n '1,5p' "$SSH_MAIN" | grep -Fx "$MANAGED_INCLUDE" >/dev/null; then
        if [[ ! -e "${SSH_MAIN}.vpn-bootstrap-original" ]]; then
            cp -a "$SSH_MAIN" "${SSH_MAIN}.vpn-bootstrap-original"
        fi
        SSH_TMP="$(mktemp)"
        {
            echo "$MANAGED_INCLUDE"
            grep -vxF "$MANAGED_INCLUDE" "$SSH_MAIN"
        } > "$SSH_TMP"
        install -o root -g root -m 0644 "$SSH_TMP" "$SSH_MAIN"
        rm -f "$SSH_TMP"
    fi

    sshd -t
    SSH_CLIENT_ADDR="${SSH_CONNECTION:-}"
    SSH_CLIENT_ADDR="${SSH_CLIENT_ADDR%% *}"
    SSH_CLIENT_ADDR="${SSH_CLIENT_ADDR:-127.0.0.1}"
    # Evaluate Match rules for the management user, too.
    SSH_EFFECTIVE="$(sshd -T -C "user=$VPN_USER,host=localhost,addr=${SSH_CLIENT_ADDR:-127.0.0.1}" 2>/dev/null | grep -E '^(permitrootlogin|pubkeyauthentication|passwordauthentication|kbdinteractiveauthentication|permitemptypasswords|maxauthtries|x11forwarding) ')"

    for expected in \
        'permitrootlogin no' \
        'pubkeyauthentication yes' \
        'passwordauthentication no' \
        'kbdinteractiveauthentication no' \
        'permitemptypasswords no' \
        'maxauthtries 3' \
        'x11forwarding no'
    do
        grep -qxF "$expected" <<< "$SSH_EFFECTIVE" || {
            echo "$SSH_EFFECTIVE"
            die "Expected SSH setting is not effective: $expected"
        }
    done

    systemctl reload ssh
    systemctl is-active --quiet ssh || die "SSH service is not running after reload."
    SSH_TRANSACTION=0
    echo "$SSH_EFFECTIVE"
else
    log "SSH AUTHENTICATION LEFT UNCHANGED"
    echo "Test a new key-based SSH login as $VPN_USER; then rerun via sudo with --harden-ssh."
    echo "Root/password login settings have not been hardened by this run."
fi

# ------------------------------------------------------------------------------
# Detect server networking
# ------------------------------------------------------------------------------

log "NETWORK DETECTION"
SERVER_IPV4="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src" && !found){print $(i+1); found=1}}')"
[[ -n "$SERVER_IPV4" ]] || die "Could not detect the server IPv4 address."

IPV6_EGRESS_OK=0
SERVER_IPV6=""
IPV6_PROBE_FILE="$(mktemp)"
if curl -6 -fsS --max-time 6 https://api64.ipify.org >"$IPV6_PROBE_FILE" 2>/dev/null; then
    SERVER_IPV6="$(tr -d '\r\n' <"$IPV6_PROBE_FILE")"
    if [[ "$SERVER_IPV6" == *:* ]]; then
        IPV6_EGRESS_OK=1
    else
        SERVER_IPV6=""
    fi
fi
rm -f "$IPV6_PROBE_FILE"
IPV6_PROBE_FILE=""

if [[ "$IPV6_EGRESS_OK" -eq 1 ]]; then
    echo "IPv4: $SERVER_IPV4"
    echo "IPv6: $SERVER_IPV6 (outbound connectivity OK)"
else
    echo "IPv4: $SERVER_IPV4"
    echo "IPv6: unavailable or outbound connectivity is not working"
fi

# ------------------------------------------------------------------------------
# Initialize/preserve persistent Xray state
# ------------------------------------------------------------------------------

log "XRAY STATE"
install -d -o root -g root -m 0700 "$VPN_ROOT" "$XRAY_DIR"
touch "$LOCK_FILE"
chmod 0600 "$LOCK_FILE"
exec 9>"$LOCK_FILE"
flock -x 9
# Children inherit this descriptor; renderer must not acquire the same lock again.
export VPN_LOCK_HELD=1
STATE_BACKUP_DIR="$(mktemp -d "$VPN_ROOT/.state-backup.XXXXXX")"
[[ ! -f "$STATE_FILE" ]] || cp -a "$STATE_FILE" "$STATE_BACKUP_DIR/state.json"
STATE_TRANSACTION=1

if [[ ! -f "$USERS_FILE" ]]; then
    printf '{"users":[]}\n' > "$USERS_FILE"
    chmod 0600 "$USERS_FILE"
else
    jq -e '.users | type == "array"' "$USERS_FILE" >/dev/null || die "$USERS_FILE is invalid."
fi

if [[ -f "$STATE_FILE" ]]; then
    jq empty "$STATE_FILE" || die "$STATE_FILE contains invalid JSON."
    XRAY_IMAGE="$(jq -r '.xray_image' "$STATE_FILE")"
    XRAY_PORT="$(jq -r '.xray_port' "$STATE_FILE")"
    REALITY_TARGET="$(jq -r '.reality_target' "$STATE_FILE")"
    REALITY_PRIVATE_KEY="$(jq -r '.reality_private_key' "$STATE_FILE")"
    REALITY_PUBLIC_KEY="$(jq -r '.reality_public_key' "$STATE_FILE")"
    ENDPOINT_MODE="$(jq -r '.endpoint_mode // "auto"' "$STATE_FILE")"
    ENDPOINT_HOST="$(jq -r '.endpoint_host' "$STATE_FILE")"
    BLOCK_RU="$(jq -r '.block_ru' "$STATE_FILE")"

    [[ -n "$XRAY_IMAGE" && "$XRAY_IMAGE" != "null" ]] || die "Missing xray_image in state."
    is_valid_port "$XRAY_PORT" || die "Invalid xray_port in state."
    [[ -n "$REALITY_PRIVATE_KEY" && "$REALITY_PRIVATE_KEY" != "null" ]] || die "Missing REALITY private key in state."
    [[ -n "$REALITY_PUBLIC_KEY" && "$REALITY_PUBLIC_KEY" != "null" ]] || die "Missing REALITY public key in state."

    if [[ -n "$XRAY_IMAGE_ARG" ]]; then
        XRAY_IMAGE="$XRAY_IMAGE_ARG"
    elif [[ "$XRAY_IMAGE" == "$LEGACY_BOOTSTRAP_PRERELEASE_IMAGE" ]]; then
        # Migrate only the prerelease image that an older bootstrap version
        # selected by mistake. Never replace an actively running deployment
        # behind the operator's back.
        if [[ "$(docker inspect -f '{{.State.Running}}' "$XRAY_CONTAINER" 2>/dev/null || true)" != "true" ]]; then
            warn "Migrating legacy bootstrap prerelease pin to stable: $DEFAULT_XRAY_IMAGE"
            XRAY_IMAGE="$DEFAULT_XRAY_IMAGE"
        else
            warn "Running Xray still uses legacy prerelease $XRAY_IMAGE; preserving it. Use --xray-image explicitly to change it."
        fi
    fi
    if [[ -n "$XRAY_PORT_ARG" ]]; then XRAY_PORT="$XRAY_PORT_ARG"; fi
    if [[ -n "$REALITY_TARGET_ARG" ]]; then REALITY_TARGET="$REALITY_TARGET_ARG"; fi
    if [[ -n "$BLOCK_RU_ARG" ]]; then BLOCK_RU="$BLOCK_RU_ARG"; fi
    if [[ -n "$ENDPOINT_ARG" ]]; then
        ENDPOINT_MODE="manual"
        ENDPOINT_HOST="$ENDPOINT_ARG"
    elif [[ "$ENDPOINT_MODE" == "auto" ]]; then
        ENDPOINT_HOST="$SERVER_IPV4"
    fi

    echo "Existing REALITY keys and VPN users preserved."
else
    XRAY_IMAGE="${XRAY_IMAGE_ARG:-$DEFAULT_XRAY_IMAGE}"
    XRAY_PORT="${XRAY_PORT_ARG:-$DEFAULT_XRAY_PORT}"
    REALITY_TARGET="${REALITY_TARGET_ARG:-$DEFAULT_REALITY_TARGET}"
    BLOCK_RU="${BLOCK_RU_ARG:-false}"

    if [[ -n "$ENDPOINT_ARG" ]]; then
        ENDPOINT_MODE="manual"
        ENDPOINT_HOST="$ENDPOINT_ARG"
    else
        ENDPOINT_MODE="auto"
        ENDPOINT_HOST="$SERVER_IPV4"
    fi

    docker pull "$XRAY_IMAGE"
    KEY_OUTPUT="$(docker run --rm "$XRAY_IMAGE" x25519)"
    REALITY_PRIVATE_KEY="$(awk -F': ' '/^PrivateKey:/ {print $2; exit}' <<< "$KEY_OUTPUT")"
    REALITY_PUBLIC_KEY="$(awk -F': ' '/^Password \(PublicKey\):/ {print $2; exit} /^PublicKey:/ {print $2; exit}' <<< "$KEY_OUTPUT")"
    [[ -n "$REALITY_PRIVATE_KEY" ]] || die "Could not generate REALITY private key."
    [[ -n "$REALITY_PUBLIC_KEY" ]] || die "Could not generate REALITY public key."
    echo "Generated persistent REALITY keypair."
fi

is_valid_port "$XRAY_PORT" || die "Invalid Xray port: $XRAY_PORT"
for port in "${SSH_PORTS[@]}"; do
    [[ "$XRAY_PORT" != "$port" ]] || die "Xray port conflicts with SSH TCP/$port."
done
is_valid_hostname_or_ip "$ENDPOINT_HOST" || die "Invalid endpoint host: $ENDPOINT_HOST"
is_valid_hostname_or_ip "$REALITY_TARGET" || die "Invalid REALITY target: $REALITY_TARGET"
[[ "$REALITY_TARGET" != *:* ]] || die "REALITY target must be a hostname without a port."
[[ "$BLOCK_RU" == "true" || "$BLOCK_RU" == "false" ]] || die "Invalid block_ru state."

STATE_TMP="$(mktemp)"
jq -Rn \
    --arg image "$XRAY_IMAGE" \
    --argjson port "$XRAY_PORT" \
    --arg target "$REALITY_TARGET" \
    --arg public_key "$REALITY_PUBLIC_KEY" \
    --arg endpoint_mode "$ENDPOINT_MODE" \
    --arg endpoint_host "$ENDPOINT_HOST" \
    --argjson block_ru "$BLOCK_RU" \
    --arg server_ipv4 "$SERVER_IPV4" \
    --arg server_ipv6 "$SERVER_IPV6" \
    --argjson ipv6_ok "$(json_bool "$IPV6_EGRESS_OK")" \
    'input as $private_key | {
        xray_image:$image,
        xray_port:$port,
        reality_target:$target,
        reality_private_key:$private_key,
        reality_public_key:$public_key,
        endpoint_mode:$endpoint_mode,
        endpoint_host:$endpoint_host,
        block_ru:$block_ru,
        server_ipv4:$server_ipv4,
        server_ipv6:$server_ipv6,
        ipv6_egress_ok:$ipv6_ok
    }' > "$STATE_TMP" <<< "$REALITY_PRIVATE_KEY"
install -o root -g root -m 0600 "$STATE_TMP" "$STATE_FILE"
rm -f "$STATE_TMP"

# ------------------------------------------------------------------------------
# Check pinned Xray version against the latest stable GitHub release
# ------------------------------------------------------------------------------

log "XRAY VERSION CHECK"
check_xray_version "$XRAY_IMAGE"

# ------------------------------------------------------------------------------
# Validate REALITY camouflage target
# ------------------------------------------------------------------------------

log "REALITY TARGET CHECK"
# Validate both the certificate identity and HTTP/2 ALPN negotiation.  Merely
# seeing "TLSv1.3" in openssl output can accept a mismatched or broken target.
TLS_PROBE_OUTPUT=""
if TLS_PROBE_OUTPUT="$(timeout 12 openssl s_client \
    -connect "${REALITY_TARGET}:443" \
    -servername "$REALITY_TARGET" \
    -tls1_3 -alpn h2 \
    -verify_hostname "$REALITY_TARGET" \
    -verify_return_error </dev/null 2>&1)" && \
    grep -Fq 'ALPN protocol: h2' <<< "$TLS_PROBE_OUTPUT"; then
    echo "REALITY target TLS 1.3, certificate hostname and HTTP/2: OK"
else
    warn "REALITY target diagnostic:"
    printf '%s\n' "$TLS_PROBE_OUTPUT" | tail -n 12 >&2
    die "REALITY target TLS 1.3/certificate/HTTP2 check failed: $REALITY_TARGET"
fi
unset TLS_PROBE_OUTPUT

# ------------------------------------------------------------------------------
# Install renderer and management command
# ------------------------------------------------------------------------------

log "VPN MANAGEMENT COMMANDS"
install -d -o root -g root -m 0755 /usr/local/libexec

cat > /usr/local/libexec/vpn-render-xray <<'RENDER'
#!/usr/bin/env bash
set -Eeuo pipefail

VPN_ROOT="/opt/vpn-stack"
XRAY_DIR="$VPN_ROOT/xray"
STATE_FILE="$VPN_ROOT/state.json"
USERS_FILE="$VPN_ROOT/users.json"
COMPOSE_FILE="$VPN_ROOT/compose.yml"
XRAY_CONTAINER="xray-reality"
XRAY_CONTAINER_PORT=8443

[[ $EUID -eq 0 ]] || { echo "ERROR: run as root" >&2; exit 1; }
if [[ "${VPN_LOCK_HELD:-0}" != 1 ]]; then
    exec 9>"$VPN_ROOT/.lock"
    flock -x 9
fi
jq empty "$STATE_FILE"
jq -e '.users | type == "array"' "$USERS_FILE" >/dev/null

XRAY_IMAGE="$(jq -r '.xray_image' "$STATE_FILE")"
XRAY_PORT="$(jq -r '.xray_port' "$STATE_FILE")"
REALITY_TARGET="$(jq -r '.reality_target' "$STATE_FILE")"
BLOCK_RU="$(jq -r '.block_ru' "$STATE_FILE")"
IPV6_OK="$(jq -r '.ipv6_egress_ok' "$STATE_FILE")"

# Keep the Xray process on an unprivileged container port. Docker publishes
# the configured host port and performs the bridge-network forwarding. Enable
# IPv6 on the private bridge whenever the host kernel supports IPv6, even if
# the provider's current IPv6 route is unavailable. This keeps the deployment
# ready for IPv6 without changing the host networking model.
if [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] && \
   [[ "$(cat /proc/sys/net/ipv6/conf/all/disable_ipv6)" == "0" ]]; then
    LISTEN_ADDR="::"
    NETWORK_IPV6_LINE="    enable_ipv6: true"
else
    LISTEN_ADDR="0.0.0.0"
    NETWORK_IPV6_LINE=""
fi

# The host's IPv6 probe does not validate Docker bridge IPv6 egress.
# Until a network-namespace probe is available, prefer reliable IPv4 DNS
# resolution.  Existing IPv6 literals still use the kernel routing table.
FREEDOM_STRATEGY="UseIPv4"

# The official Xray image runs as a non-root user by default. Keep the
# temporary config inside the root-only VPN directory. The config file itself
# is readable because the normal runtime is non-root; the parent directory is
# mode 0700 on the host, so unprivileged host users still cannot access it.
CONFIG_TMP="$(mktemp "$XRAY_DIR/.config.json.tmp.XXXXXX")"
VALIDATION_LOG="$(mktemp)"
COMPOSE_TMP="$(mktemp "$VPN_ROOT/.compose.tmp.XXXXXX")"
DEPLOY_BACKUP="$(mktemp -d "$VPN_ROOT/.deploy-backup.XXXXXX")"
DEPLOY_PENDING=0
HAD_COMPOSE=0
HAD_CONFIG=0
[[ ! -f "$COMPOSE_FILE" ]] || { cp -a "$COMPOSE_FILE" "$DEPLOY_BACKUP/compose.yml"; HAD_COMPOSE=1; }
[[ ! -f "$XRAY_DIR/config.json" ]] || { cp -a "$XRAY_DIR/config.json" "$DEPLOY_BACKUP/config.json"; HAD_CONFIG=1; }
cleanup_deployment() {
    local rc=$?
    trap - EXIT
    if [[ "$DEPLOY_PENDING" -eq 1 ]]; then
        echo "ERROR: applying Xray failed; restoring previous deployment." >&2
        if [[ "$HAD_CONFIG" -eq 1 ]]; then
            cp -a "$DEPLOY_BACKUP/config.json" "$XRAY_DIR/config.json"
        else
            rm -f "$XRAY_DIR/config.json"
        fi
        if [[ "$HAD_COMPOSE" -eq 1 ]]; then
            cp -a "$DEPLOY_BACKUP/compose.yml" "$COMPOSE_FILE"
            # Recreate: a single-file bind mount may still reference the replaced inode.
            if ! docker compose --project-directory "$VPN_ROOT" -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans >&2; then
                echo "ERROR: automatic deployment recovery failed; check Docker logs." >&2
            fi
        else
            # Only remove the deployment if Compose actually created it for us.
            docker compose --project-directory "$VPN_ROOT" -f "$COMPOSE_FILE" down --remove-orphans >&2 || true
            rm -f "$COMPOSE_FILE"
        fi
    fi
    rm -f "$CONFIG_TMP" "$VALIDATION_LOG" "$COMPOSE_TMP"
    rm -rf -- "$DEPLOY_BACKUP"
    exit "$rc"
}
trap cleanup_deployment EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

jq -n \
    --arg listen "$LISTEN_ADDR" \
    --argjson port "$XRAY_CONTAINER_PORT" \
    --arg target "$REALITY_TARGET" \
    --slurpfile state "$STATE_FILE" \
    --arg freedom_strategy "$FREEDOM_STRATEGY" \
    --argjson block_ru "$BLOCK_RU" \
    --slurpfile db "$USERS_FILE" '
    ($db[0].users) as $u |
    ($u | map({id:.uuid, email:.name, flow:"xtls-rprx-vision"})) as $clients |
    (if ($u|length) == 0 then [""] else ($u | map(.sid)) end) as $short_ids |
    {
      log: {loglevel:"warning"},
      inbounds: [
        {
          tag:"vless-reality",
          listen:$listen,
          port:$port,
          protocol:"vless",
          settings:{
            clients:$clients,
            decryption:"none"
          },
          streamSettings:{
            network:"tcp",
            security:"reality",
            realitySettings:{
              show:false,
              target:($target + ":443"),
              xver:0,
              serverNames:[$target],
              privateKey:$state[0].reality_private_key,
              shortIds:$short_ids
            }
          },
          sniffing:{
            enabled:true,
            destOverride:["http","tls","quic"],
            routeOnly:true
          }
        }
      ],
      outbounds:[
        {
          tag:"direct",
          protocol:"freedom",
          settings:{domainStrategy:$freedom_strategy}
        },
        {
          tag:"block",
          protocol:"blackhole"
        }
      ],
      routing:{
        domainStrategy:"IPIfNonMatch",
        rules:(
          if $block_ru then
            [
              {
                type:"field",
                domain:["regexp:(?i)(^|\\.)(ru|su|xn--p1ai)$"],
                outboundTag:"block"
              },
              {
                type:"field",
                ip:["geoip:ru"],
                outboundTag:"block"
              }
            ]
          else [] end
        )
      }
    }
    ' > "$CONFIG_TMP"

# Xray's official distroless image runs without root privileges, so a 0600
# root-owned bind mount is unreadable inside the container. The host-side
# directory is mode 0700, therefore mode 0644 here does not expose the file to
# unprivileged host users while allowing the non-root container to read it.
chmod 0644 "$CONFIG_TMP"

# Validate the new configuration before replacing the live one.
# Keep Xray's diagnostic output so a configuration failure is actionable.
docker pull "$XRAY_IMAGE" >/dev/null

if docker run --rm \
    --network none \
    -v "$CONFIG_TMP:/etc/xray/config.json:ro" \
    "$XRAY_IMAGE" \
    run -test -config /etc/xray/config.json >"$VALIDATION_LOG" 2>&1; then
    :
else
    rc=$?
    echo "ERROR: Xray configuration validation failed (exit code $rc)." >&2
    echo "----- Xray validation output -----" >&2
    cat "$VALIDATION_LOG" >&2
    echo "----------------------------------" >&2
    exit "$rc"
fi

# Use the normal Docker bridge model. The official Xray image remains non-root
# and listens on an unprivileged container port. Docker publishes the requested
# host port (443 by default) to that internal port. No root user override and no
# NET_BIND_SERVICE capability are required.
cat > "$COMPOSE_TMP" <<EOF
services:
  xray:
    image: ${XRAY_IMAGE}
    container_name: ${XRAY_CONTAINER}
    restart: always
    read_only: true
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    pids_limit: 128
    ports:
      - "${XRAY_PORT}:${XRAY_CONTAINER_PORT}/tcp"
    networks:
      - xray-net
    volumes:
      - ./xray/config.json:/etc/xray/config.json:ro
    command: ["run", "-config", "/etc/xray/config.json"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

networks:
  xray-net:
    driver: bridge
${NETWORK_IPV6_LINE}
EOF
chmod 0600 "$COMPOSE_TMP"

cd "$VPN_ROOT"
# Relative volume paths are resolved against VPN_ROOT even for the candidate file.
docker compose --project-directory "$VPN_ROOT" -f "$COMPOSE_TMP" config -q
DEPLOY_PENDING=1
install -o root -g root -m 0644 "$CONFIG_TMP" "$XRAY_DIR/config.json"
install -o root -g root -m 0600 "$COMPOSE_TMP" "$COMPOSE_FILE"
docker compose --project-directory "$VPN_ROOT" -f "$COMPOSE_FILE" up -d --force-recreate --remove-orphans

for _ in $(seq 1 20); do
    if [[ "$(docker inspect -f '{{.State.Running}}' "$XRAY_CONTAINER" 2>/dev/null || true)" == "true" ]] && \
       nc -4 -z -w 1 127.0.0.1 "$XRAY_PORT" >/dev/null 2>&1; then
        # Catch immediate crash/restart loops instead of trusting the first TCP accept.
        sleep 2
        if [[ "$(docker inspect -f '{{.State.Running}} {{.RestartCount}}' "$XRAY_CONTAINER" 2>/dev/null || true)" == "true 0" ]]; then
            DEPLOY_PENDING=0
            exit 0
        fi
    fi
    sleep 1
done

echo "ERROR: Xray did not become ready through published host TCP/$XRAY_PORT." >&2
docker logs --tail 100 "$XRAY_CONTAINER" >&2 || true
exit 1
RENDER
chmod 0700 /usr/local/libexec/vpn-render-xray

cat > /usr/local/sbin/vpnctl <<'VPNCTL'
#!/usr/bin/env bash
set -Eeuo pipefail

VPN_ROOT="/opt/vpn-stack"
STATE_FILE="$VPN_ROOT/state.json"
USERS_FILE="$VPN_ROOT/users.json"
LOCK_FILE="$VPN_ROOT/.lock"
XRAY_CONTAINER="xray-reality"

[[ $EUID -eq 0 ]] || { echo "ERROR: use sudo" >&2; exit 1; }

url_host() {
    local host="$1"
    if [[ "$host" == *:* && "$host" != \[*\] ]]; then
        printf '[%s]' "$host"
    else
        printf '%s' "$host"
    fi
}

load_state() {
    XRAY_IMAGE="$(jq -r '.xray_image' "$STATE_FILE")"
    XRAY_PORT="$(jq -r '.xray_port' "$STATE_FILE")"
    ENDPOINT_HOST="$(jq -r '.endpoint_host' "$STATE_FILE")"
    REALITY_TARGET="$(jq -r '.reality_target' "$STATE_FILE")"
    REALITY_PUBLIC_KEY="$(jq -r '.reality_public_key' "$STATE_FILE")"
    SERVER_IPV6="$(jq -r '.server_ipv6 // ""' "$STATE_FILE")"
    IPV6_OK="$(jq -r '.ipv6_egress_ok // false' "$STATE_FILE")"
    BLOCK_RU="$(jq -r '.block_ru' "$STATE_FILE")"
}

validate_name() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || {
        echo "ERROR: name must match [A-Za-z0-9][A-Za-z0-9._-]{0,63}" >&2
        exit 1
    }
}

build_link() {
    local name="$1" uuid="$2" sid="$3" host="$4"
    host="$(url_host "$host")"
    printf 'vless://%s@%s:%s?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s\n' \
        "$uuid" "$host" "$XRAY_PORT" "$REALITY_TARGET" "$REALITY_PUBLIC_KEY" "$sid" "$name"
}

show_user() {
    local name="$1"
    load_state
    local row uuid sid
    row="$(jq -c --arg n "$name" 'first(.users[]? | select(.name==$n)) // empty' "$USERS_FILE")"
    [[ -n "$row" ]] || { echo "ERROR: user not found: $name" >&2; exit 1; }
    uuid="$(jq -r '.uuid' <<< "$row")"
    sid="$(jq -r '.sid' <<< "$row")"

    echo "Primary link:"
    build_link "$name" "$uuid" "$sid" "$ENDPOINT_HOST"

    # Do not advertise a direct IPv6 endpoint merely from host outbound
    # connectivity. The external Docker-published port may not be reachable.
}

add_user() {
    local name="$1"
    validate_name "$name"
    exec 9>"$LOCK_FILE"
    flock -x 9
    export VPN_LOCK_HELD=1
    load_state

    if jq -e --arg n "$name" '.users[]? | select(.name==$n)' "$USERS_FILE" >/dev/null; then
        echo "User already exists: $name"
        show_user "$name"
        return 0
    fi

    local uuid sid tmp backup
    uuid="$(docker run --rm "$XRAY_IMAGE" uuid | tail -n 1 | tr -d '\r\n')"
    [[ -n "$uuid" ]] || { echo "ERROR: UUID generation failed" >&2; exit 1; }
    sid="$(openssl rand -hex 8)"
    tmp="$(mktemp)"
    backup="${USERS_FILE}.bak"
    cp -a "$USERS_FILE" "$backup"

    jq -Rn --arg n "$name" --arg s "$sid" --slurpfile db "$USERS_FILE" \
        'input as $u | $db[0] | .users += [{name:$n,uuid:$u,sid:$s}]' > "$tmp" <<< "$uuid"
    install -o root -g root -m 0600 "$tmp" "$USERS_FILE"
    rm -f "$tmp"

    if ! /usr/local/libexec/vpn-render-xray; then
        cp -a "$backup" "$USERS_FILE"
        echo "ERROR: user creation rolled back" >&2
        exit 1
    fi
    rm -f "$backup"

    echo "Created VPN user/device: $name"
    echo "Note: applying user changes performs a short controlled Xray restart."
    echo
    show_user "$name"
    echo
    echo "QR code for the primary link:"
    build_link "$name" "$uuid" "$sid" "$ENDPOINT_HOST" | qrencode -t ANSIUTF8
    echo
    echo "Treat VLESS links and QR codes as credentials."
}

remove_user() {
    local name="$1"
    validate_name "$name"
    exec 9>"$LOCK_FILE"
    flock -x 9
    export VPN_LOCK_HELD=1

    if ! jq -e --arg n "$name" '.users[]? | select(.name==$n)' "$USERS_FILE" >/dev/null; then
        echo "User does not exist: $name"
        return 0
    fi

    local tmp backup
    tmp="$(mktemp)"
    backup="${USERS_FILE}.bak"
    cp -a "$USERS_FILE" "$backup"
    jq --arg n "$name" '.users |= map(select(.name != $n))' "$USERS_FILE" > "$tmp"
    install -o root -g root -m 0600 "$tmp" "$USERS_FILE"
    rm -f "$tmp"

    if ! /usr/local/libexec/vpn-render-xray; then
        cp -a "$backup" "$USERS_FILE"
        echo "ERROR: user removal rolled back" >&2
        exit 1
    fi
    rm -f "$backup"
    echo "Removed VPN user/device: $name"
}

list_users() {
    jq -r '.users[].name' "$USERS_FILE"
}

status() {
    load_state
    echo "Xray container:"
    docker ps --filter "name=^/${XRAY_CONTAINER}$" --format '  {{.Names}}  {{.Status}}  {{.Image}}'
    echo
    echo "Published port:"
    docker port "$XRAY_CONTAINER" 2>/dev/null || true
    echo
    echo "Configuration:"
    echo "  Endpoint:       $ENDPOINT_HOST:$XRAY_PORT"
    echo "  REALITY target: $REALITY_TARGET"
    echo "  RU blocking:    $BLOCK_RU"
    echo "  IPv6 egress:    $IPV6_OK"
    echo "  VPN users:      $(jq '.users | length' "$USERS_FILE")"
    echo
    echo "Memory:"
    free -h
}

COMMAND="${1:-}"
shift || true
# Serialize readers too: they must not observe a half-applied users database.
if [[ "${VPN_LOCK_HELD:-0}" != 1 && ( "$COMMAND" == show-user || "$COMMAND" == list-users || "$COMMAND" == status ) ]]; then
    exec 9>"$LOCK_FILE"
    flock -s 9
fi

case "$COMMAND" in
    add-user)
        [[ $# -eq 1 ]] || { echo "Usage: sudo vpn-add-user NAME" >&2; exit 2; }
        add_user "$1"
        ;;
    remove-user)
        [[ $# -eq 1 ]] || { echo "Usage: sudo vpn-remove-user NAME" >&2; exit 2; }
        remove_user "$1"
        ;;
    show-user)
        [[ $# -eq 1 ]] || { echo "Usage: sudo vpn-show-user NAME" >&2; exit 2; }
        show_user "$1"
        ;;
    list-users)
        [[ $# -eq 0 ]] || { echo "Usage: sudo vpn-list-users" >&2; exit 2; }
        list_users
        ;;
    status)
        [[ $# -eq 0 ]] || { echo "Usage: sudo vpn-status" >&2; exit 2; }
        status
        ;;
    *)
        echo "Usage: sudo vpnctl {add-user|remove-user|show-user|list-users|status} [NAME]" >&2
        exit 2
        ;;
esac
VPNCTL
chmod 0700 /usr/local/sbin/vpnctl

cat > /usr/local/sbin/vpn-add-user <<'EOF'
#!/usr/bin/env bash
exec /usr/local/sbin/vpnctl add-user "$@"
EOF
cat > /usr/local/sbin/vpn-remove-user <<'EOF'
#!/usr/bin/env bash
exec /usr/local/sbin/vpnctl remove-user "$@"
EOF
cat > /usr/local/sbin/vpn-show-user <<'EOF'
#!/usr/bin/env bash
exec /usr/local/sbin/vpnctl show-user "$@"
EOF
cat > /usr/local/sbin/vpn-list-users <<'EOF'
#!/usr/bin/env bash
exec /usr/local/sbin/vpnctl list-users "$@"
EOF
cat > /usr/local/sbin/vpn-status <<'EOF'
#!/usr/bin/env bash
exec /usr/local/sbin/vpnctl status "$@"
EOF
chmod 0700 /usr/local/sbin/vpn-add-user /usr/local/sbin/vpn-remove-user \
    /usr/local/sbin/vpn-show-user /usr/local/sbin/vpn-list-users /usr/local/sbin/vpn-status

# ------------------------------------------------------------------------------
# Check port ownership before starting/reconfiguring Xray
# ------------------------------------------------------------------------------

log "XRAY PORT CHECK"
if ss -H -ltn "sport = :${XRAY_PORT}" | awk 'NF {found=1} END {exit !found}'; then
    if docker inspect "$XRAY_CONTAINER" 2>/dev/null |
        jq -e --arg p "$XRAY_PORT" '.[0].NetworkSettings.Ports // {} | [.[]? // [] | .[]? | .HostPort] | index($p) != null' >/dev/null; then
        echo "TCP/$XRAY_PORT is already owned by the existing Xray deployment."
    else
        echo "TCP/$XRAY_PORT is already occupied:"
        ss -ltnp | grep -E ":${XRAY_PORT}[[:space:]]" || true
        die "Choose another --xray-port or free TCP/$XRAY_PORT."
    fi
else
    echo "TCP/$XRAY_PORT is free."
fi

# ------------------------------------------------------------------------------
# Render, validate and start Xray
# ------------------------------------------------------------------------------

log "XRAY DEPLOYMENT"
/usr/local/libexec/vpn-render-xray
STATE_TRANSACTION=0

[[ "$(docker inspect -f '{{.State.Running}}' "$XRAY_CONTAINER" 2>/dev/null || true)" == "true" ]] || \
    die "Xray container is not running."

# Verify the Docker-published host port over IPv4.
if ! nc -4 -z -w 2 127.0.0.1 "$XRAY_PORT"; then
    docker logs --tail 100 "$XRAY_CONTAINER" || true
    die "Xray container is running but Docker is not forwarding IPv4 TCP/$XRAY_PORT to Xray."
fi

echo "Xray is reachable through Docker on IPv4 TCP/$XRAY_PORT."
if nc -6 -z -w 2 ::1 "$XRAY_PORT" >/dev/null 2>&1; then
    echo "Xray Docker-published IPv6 host port: OK"
else
    echo "Xray Docker-published IPv6 host port: unavailable"
fi

# ------------------------------------------------------------------------------
# Configure UFW after SSH and Xray ports are known. Docker manages the
# published Xray port with its own firewall/NAT rules; the explicit UFW allow
# documents the intended host policy and protects ordinary host services.
# ------------------------------------------------------------------------------

if [[ "$CONFIGURE_FIREWALL" -eq 1 ]]; then
    log "FIREWALL"
    sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
    ufw default deny incoming >/dev/null
    ufw default allow outgoing >/dev/null
    for port in "${SSH_PORTS[@]}"; do
        ufw allow "${port}/tcp" comment 'SSH' >/dev/null
    done
    ufw allow "${XRAY_PORT}/tcp" comment 'Xray REALITY' >/dev/null
    ufw --force enable >/dev/null
    ufw status verbose
else
    log "FIREWALL SKIPPED"
fi

# ------------------------------------------------------------------------------
# Final checks and summary
# ------------------------------------------------------------------------------

log "FINAL CHECKS"
/usr/local/sbin/vpn-status

echo
if [[ -f /var/run/reboot-required ]]; then
    warn "Ubuntu reports that a reboot is required after package updates."
    warn "The script intentionally did not reboot the server."
fi

echo
echo "============================================================"
echo "VPN BOOTSTRAP COMPLETE"
echo "============================================================"
echo "VPN management user : $VPN_USER"
echo "SSH ports           : ${SSH_PORTS[*]}"
echo "Client endpoint      : $ENDPOINT_HOST:$XRAY_PORT"
echo "Protocol             : VLESS + XTLS Vision + REALITY"
echo "REALITY target       : $REALITY_TARGET"
echo "RU destinations      : $([[ "$BLOCK_RU" == "true" ]] && echo BLOCKED || echo ALLOWED)"
echo "IPv6 egress          : $([[ "$IPV6_EGRESS_OK" -eq 1 ]] && echo ENABLED || echo UNAVAILABLE)"
echo "VPN users            : $(jq '.users | length' "$USERS_FILE")"
echo
echo "Xray runs continuously in Docker."
echo "Docker starts at boot and the Xray container uses restart: always,"
echo "so it is restarted automatically after a crash or server reboot."
echo
echo "No VPN user was created automatically."
echo "Create one device/user with:"
echo "    sudo vpn-add-user phone"
echo
echo "Other commands:"
echo "    sudo vpn-add-user NAME"
echo "    sudo vpn-remove-user NAME"
echo "    sudo vpn-show-user NAME"
echo "    sudo vpn-list-users"
echo "    sudo vpn-status"
echo
echo "IMPORTANT:"
echo "Before closing this SSH session, verify a NEW key-based SSH login as $VPN_USER."
if [[ "$SSH_HARDENING" -eq 0 ]]; then
    echo "SSH hardening is pending: from that login rerun this script via sudo with --harden-ssh."
fi
echo "Treat every vless:// link and QR code as a credential."
echo "============================================================"
