#!/usr/bin/env bash
set -Eeuo pipefail
# Runs on the VPS as root, streamed from the operator's workstation.
# Creates a stable non-root administrative entrypoint for repeat bootstraps.
[[ "$(id -u)" == 0 ]] || { echo "ERROR: root required" >&2; exit 1; }
[[ $# == 1 && "$1" == ssh-*' '* ]] || { echo "ERROR: expected one public SSH key" >&2; exit 2; }
pubkey="$1"
account="vpnadmin"
if ! id "$account" >/dev/null 2>&1; then
    useradd -m -s /bin/bash "$account"
    echo "Created administrative SSH account: $account"
else
    echo "Existing administrative SSH account: $account"
fi
home="$(getent passwd "$account" | cut -d: -f6)"
[[ -n "$home" && "$home" != "/" && -d "$home" ]] ||
    { echo "ERROR: unsafe admin home" >&2; exit 1; }
group="$(id -gn "$account")"
install -d -m 0700 -o "$account" -g "$group" "$home/.ssh"
keys="$home/.ssh/authorized_keys"
if [[ ! -f "$keys" ]]; then
    install -o "$account" -g "$group" -m 0600 /dev/null "$keys"
fi
if ! grep -Fxq -- "$pubkey" "$keys"; then
    printf '%s\n' "$pubkey" >> "$keys"
fi
chown "$account:$group" "$keys"
chmod 0600 "$keys"
chmod go-w "$home"
if ! id -nG "$account" | tr ' ' '\n' | grep -Fxq sudo; then
    usermod -aG sudo "$account"
fi
policy="/etc/sudoers.d/80-vpn-bootstrap-vpnadmin"
desired="$account ALL=(ALL:ALL) NOPASSWD: ALL"
if [[ ! -f "$policy" || "$(cat "$policy")" != "$desired" ||
      "$(stat -c %a "$policy")" != 440 ]]; then
    tmp="$(mktemp /etc/sudoers.d/.vpnadmin.XXXXXX)"
    trap 'rm -f "$tmp"' EXIT
    printf '%s\n' "$desired" > "$tmp"
    chmod 0440 "$tmp"
    visudo -cf "$tmp" >/dev/null
    # Validate entire configuration using a test file, then atomically move.
    mv -f "$tmp" "$policy"
    if ! visudo -c >/dev/null; then
        echo "ERROR: sudoers configuration invalid" >&2
        exit 1
    fi
    trap - EXIT
fi
runuser -u "$account" -- sudo -n true ||
    { echo "ERROR: vpnadmin passwordless sudo failed" >&2; exit 1; }
echo "vpnadmin key and sudo ready; verify an independent SSH login before root lockout."
