#!/usr/bin/env bash
set -Eeuo pipefail
# Read-only preflight for existing VPN servers. Run from your workstation.
# Usage: bash bin/audit-vps.sh VPS_HOST [SSH_USER] [SSH_KEY|-] [SSH_PORT]
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
