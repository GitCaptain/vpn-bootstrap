#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only preflight for existing VPN servers. Run from your workstation.
# Usage: bash bin/audit-vps.sh VPS_HOST [SSH_USER] [SSH_KEY|-] [SSH_PORT]
if [[ "${1:-}" == "--help" || "${1:-}" == "-h" ]]; then
    echo "Usage: bash bin/audit-vps.sh VPS_HOST [SSH_USER=root] [SSH_PRIVATE_KEY=-] [SSH_PORT=22]"
    echo "Read-only diagnostic of Docker, AmneziaWG, SSH and firewall state."
    echo "SSH_PRIVATE_KEY=- uses the SSH agent or password prompt; no VPN secrets are printed."
    exit 0
fi
if (( $# < 1 || $# > 4 )); then
    echo "Usage: bash bin/audit-vps.sh VPS_HOST [SSH_USER=root] [SSH_KEY=-] [SSH_PORT=22]" >&2
    exit 2
fi
server="$1"
admin="${2:-root}"
key="${3:--}"
port="${4:-22}"
[[ "$server" =~ ^[A-Za-z0-9.:-]+$ && "$server" != -* ]] ||
    { echo "ERROR: invalid host" >&2; exit 2; }
[[ "$admin" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] ||
    { echo "ERROR: invalid SSH user" >&2; exit 2; }
[[ "$port" =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$port <= 65535 )) ||
    { echo "ERROR: invalid SSH port" >&2; exit 2; }
args=(-T -p "$port" -o ClearAllForwardings=yes -o StrictHostKeyChecking=ask
      -o ControlMaster=no -o ControlPath=none -o ConnectTimeout=10)
if [[ "$key" != - ]]; then
    [[ -r "$key" ]] || { echo "ERROR: SSH key file unreadable" >&2; exit 2; }
    args+=(-i "$key" -o IdentitiesOnly=yes)
fi
# No credentials or secrets are echoed in the remote report.
ssh "${args[@]}" "$admin@$server" \
  'if [ "$(id -u)" -eq 0 ]; then exec bash -s; else exec sudo -n bash -s; fi' <<'REMOTE'
set -Eeuo pipefail
printf '=== VPS VPN AUDIT (read-only) ===\n'
printf 'Timestamp: '; date -u +%FT%TZ
printf 'OS: '; . /etc/os-release; printf '%s %s\n' "$ID" "$VERSION_ID"
printf 'Kernel: '; uname -r
printf 'SSH current user: '; id -un
printf 'Known operator accounts:\n'
for u in vpnadmin xray amnezia; do
    if id "$u" >/dev/null 2>&1; then
        echo "  $u: present"
    else
        echo "  $u: absent"
    fi
done
printf '\nDocker availability:\n'
if command -v docker >/dev/null; then
    docker --version
    if docker compose version >/dev/null 2>&1; then
        docker compose version
    else
        echo "WARNING: Docker Compose v2 is not installed; Xray setup will refuse to continue."
    fi
    if docker info >/dev/null 2>&1; then
        echo "Docker daemon: healthy"
        echo "Containers (names, image, published ports, Compose project):"
        docker ps -a --format '  {{.Names}} | {{.Image}} | {{.Ports}} | {{.Label "com.docker.compose.project"}}'
        echo "Docker daemon firewall backend (if configured):"
        if [[ -f /etc/docker/daemon.json ]]; then
            python3 - <<'PY' 2>/dev/null || true
import json
with open("/etc/docker/daemon.json") as f: d=json.load(f)
for k in ("iptables","ip6tables","firewall-backend","ip-forward","ipv6"):
    if k in d: print(f"  {k}: {d[k]}")
PY
        fi
    else
        echo "WARNING: Docker CLI exists but daemon is not healthy"
    fi
else
    echo "Docker not installed"
fi
printf '\nFirewall policy:\n'
if command -v ufw >/dev/null; then
    ufw status verbose || true
else
    echo "UFW absent"
fi
printf '\nListening TCP/UDP ports:\n'
ss -H -lntup 2>/dev/null | awk '{print "  "$1" "$5" "$7}' | head -80 || true
printf '\nSSH effective root policy (informational; Match clauses may differ):\n'
if command -v sshd >/dev/null; then
    sshd -T -C user=root,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22 |
        grep -E '^(permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication) ' || true
fi
printf '\nGlobal sudoers preflight (read-only):\n'
if command -v visudo >/dev/null 2>&1; then
    if visudo -c; then
        echo "Sudoers validation: OK"
    else
        echo "WARNING: Existing sudoers configuration is invalid; vpnadmin setup will abort."
        echo "Inspect /etc/sudoers.d/* permissions and fix separately before installing Xray."
    fi
else
    echo "WARNING: visudo not available"
fi

printf '\nExisting Amnezia SSH management (read-only):\n'
if id amnezia >/dev/null 2>&1; then
    if command -v sudo >/dev/null 2>&1 &&
       runuser -u amnezia -- sudo -n true >/dev/null 2>&1; then
        echo "  amnezia passwordless sudo: OK"
    else
        echo "  amnezia passwordless sudo: NOT WORKING (verify before root lockout)"
    fi
    if command -v sshd >/dev/null 2>&1; then
        sshd -T -C user=amnezia,host=localhost,addr=127.0.0.1,laddr=127.0.0.1,lport=22 |
            grep -E '^(pubkeyauthentication|passwordauthentication|authenticationmethods|kbdinteractiveauthentication) ' |
            sed 's/^/  /' || true
    fi
    if command -v passwd >/dev/null 2>&1; then
        passwd -S amnezia | awk '{print "  amnezia password state: "$2" (L=locked; P=set; NP=no password)"}'
    fi
fi
printf '\nExisting Amnezia Docker service (public metadata only):\n'
if docker info >/dev/null 2>&1; then
    for container in $(docker ps -a --format '{{.Names}}' | grep '^amnezia-' || true); do
        docker inspect -f \
            '  {{.Name}} | ID={{.Id}} | running={{.State.Running}} | restarted={{.RestartCount}} | started={{.State.StartedAt}} | ports={{json .HostConfig.PortBindings}}' \
            "$container" || true
    done
fi
printf '\nResources available:\n'
df -h / | tail -n 1 || true
free -h | head -n 2 || true

printf '\nXray state, if any:\n'
if [[ -d /opt/vpn-stack ]]; then
    for path in /opt/vpn-stack/state.json /opt/vpn-stack/users.json /opt/vpn-stack/compose.yml; do
        if [[ -f "$path" ]]; then echo "  exists: $path"; fi
    done
else
    echo "  No /opt/vpn-stack directory"
fi
echo '=== END VPS VPN AUDIT ==='
REMOTE
