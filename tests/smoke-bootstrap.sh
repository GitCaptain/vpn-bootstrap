#!/usr/bin/env bash
set -Eeuo pipefail
cd "$(dirname "$0")/.."
# Offline-only CLI tests. All tested commands must fail BEFORE any SSH attempt.
help="$(bash bootstrap.sh --help)"
grep -q -- '--protocol xray|amnezia|both' <<< "$help"
grep -q -- '--initial-ssh-private-key' <<< "$help"
grep -q -- '--vpnadmin-ssh-private-key' <<< "$help"
grep -q -- '--confirm-disable-root-ssh' <<< "$help"
grep -q -- 'Private key files NEVER get copied' <<< "$help"

check_failure() {
    local expected="$1"; shift
    local output
    if output="$(bash bootstrap.sh "$@" 2>&1)"; then
        printf 'ERROR: invalid invocation unexpectedly succeeded: %s\n' "$*" >&2
        exit 1
    fi
    if ! grep -Fq -- "$expected" <<< "$output"; then
        printf 'ERROR: expected diagnostic %q, got: %s\n' "$expected" "$output" >&2
        exit 1
    fi
}
check_failure 'Provide a safe --server address' --server '../bad' --protocol xray
check_failure '--protocol must be' --server 203.0.113.20 --protocol invalid
check_failure 'Missing value for --initial-ssh-user' --server 203.0.113.20 --protocol xray --initial-ssh-user
check_failure 'Missing --confirm-disable-root-ssh' --server 203.0.113.20 --protocol xray
check_failure 'Missing SSH public key' \
    --server 203.0.113.20 --protocol xray --confirm-disable-root-ssh \
    --vpnadmin-ssh-public-key /does/not/exist
# Ensure the sudoers preflight runs BEFORE the first account mutation,
# preventing a partial install when a pre-existing Amnezia sudoers file fails.
python3 - <<'PY'
from pathlib import Path
source = Path("bin/ensure-vpnadmin-remote.sh").read_text()
preflight = source.index('if ! visudo -c; then')
creation = source.index('    useradd -m -s /bin/bash "$account"')
sudoers_write = source.index('    mv -f "$tmp" "$policy"')
assert preflight < creation < sudoers_write
print("Pre-existing sudoers guard precedes account provisioning: OK")
PY

echo "Offline bootstrap argument guards and self-documentation checks passed."
