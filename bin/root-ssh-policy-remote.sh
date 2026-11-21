#!/usr/bin/env bash
set -Eeuo pipefail
# Usage (remote as root): bash -s -- apply|confirm|status [TOKEN]
# A temporary systemd timer restores SSH on failed post-change verification.
[[ "$(id -u)" == 0 ]] || { echo "ERROR: root required" >&2; exit 1; }
[[ $# -ge 1 && $# -le 2 ]] || exit 2
action="$1"
config=/etc/ssh/sshd_config
state_root=/var/lib/vpn-bootstrap/root-ssh
sshd="$(command -v sshd)"
root_effective() {
    local peer port
    peer="$(printf '%s' "${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}" | awk '{print $1}')"
    port="$(printf '%s' "${SSH_CONNECTION:-127.0.0.1 0 127.0.0.1 22}" | awk '{print $4}')"
    [[ "$port" =~ ^[0-9]+$ ]] || port=22
    "$sshd" -T -f "$config" \
        -C "user=root,host=localhost,addr=$peer,laddr=127.0.0.1,lport=$port" |
        awk '$1=="permitrootlogin" {print $2; exit}'
}
reload_ssh() {
    systemctl reload ssh.service 2>/dev/null ||
        systemctl reload sshd.service 2>/dev/null
}
case "$action" in
    status)
        root_effective
        ;;
    apply)
        "$sshd" -t -f "$config"
        if [[ "$(root_effective)" == no ]]; then
            echo "ALREADY"
            exit 0
        fi
        command -v systemd-run >/dev/null ||
            { echo "ERROR: systemd-run missing; cannot ensure timed rollback" >&2; exit 1; }
        mkdir -p -m 0700 "$state_root"
        chmod 0700 "$state_root"
        dir="$(mktemp -d "$state_root/pending.XXXXXXXX")"
        chmod 0700 "$dir"
        cp -a "$config" "$dir/sshd_config"
        cat > "$dir/revert.sh" <<'REVERT'
#!/usr/bin/env bash
set -Eeuo pipefail
dir="$1"
if [[ ! -e "$dir/confirmed" ]]; then
    cp -a "$dir/sshd_config" /etc/ssh/sshd_config
    /usr/sbin/sshd -t -f /etc/ssh/sshd_config
    systemctl reload ssh.service 2>/dev/null ||
        systemctl reload sshd.service 2>/dev/null
fi
REVERT
        chmod 0700 "$dir/revert.sh"
        token="$(basename "$dir")"
        unit="vpnrootrollback${token//[^a-zA-Z0-9]/}"
        # Arm recovery BEFORE changing the SSH daemon configuration.
        systemd-run --quiet --on-active=240s --unit="$unit" \
            /bin/bash "$dir/revert.sh" "$dir" ||
            { echo "ERROR: could not schedule SSH rollback" >&2; exit 1; }
        tmp="$(mktemp /etc/ssh/.vpn-root-policy.XXXXXXXX)"
        {
            echo '# VPN bootstrap: globally disable root SSH, including public-key auth'
            echo 'PermitRootLogin no'
            cat "$config"
        } > "$tmp"
        chmod --reference="$config" "$tmp"
        chown --reference="$config" "$tmp"
        mv -f "$tmp" "$config"
        if ! "$sshd" -t -f "$config" ||
           [[ "$(root_effective)" != no ]] ||
           ! reload_ssh; then
            echo "ERROR: new root SSH policy failed; restoring immediately" >&2
            cp -a "$dir/sshd_config" "$config"
            reload_ssh || true
            exit 1
        fi
        echo "$token"
        ;;
    confirm)
        [[ $# == 2 ]] || exit 2
        token="$2"
        [[ "$token" =~ ^pending\.[A-Za-z0-9]+$ ]] ||
            { echo "ERROR: invalid rollback token" >&2; exit 2; }
        dir="$state_root/$token"
        [[ -f "$dir/revert.sh" && -f "$dir/sshd_config" ]] ||
            { echo "ERROR: rollback state not found" >&2; exit 1; }
        "$sshd" -t -f "$config"
        [[ "$(root_effective)" == no ]] ||
            { echo "ERROR: root is still permitted by effective SSH settings" >&2; exit 1; }
        touch "$dir/confirmed"
        unit="vpnrootrollback${token//[^a-zA-Z0-9]/}"
        systemctl stop "$unit.timer" >/dev/null 2>&1 || true
        echo "Confirmed root SSH prohibited; timer disarmed."
        ;;
    *)
        echo "ERROR: expected apply, confirm, or status" >&2
        exit 2 ;;
esac
