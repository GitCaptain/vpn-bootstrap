# Existing AmneziaWG VPS → Xray without losing backup VPN

**Status: draft runbook. Do not apply full bootstrap to a production server
until a tested plan for SSH root lockout and Amnezia management migration exists.**

AmneziaWG is the existing backup connection. Do not reinstall it. Xray uses
TCP/443 in a separate Compose deployment. AmneziaWG uses UDP in its existing
container, as managed by the official AmneziaVPN app.

## Phase 0: inventory, backup and baseline

From the workstation, on the Xray feature branch:

```sh
bash bin/audit-vps.sh VPS_IP root - 22
```

Use `vpnadmin` and its private key instead of root credentials if already
provisioned. This command is **read-only**. Save the output locally; redact
IP addresses before public sharing, and never paste passwords or private keys.

Confirm **before any modification**:
- AmneziaWG connection works through the existing mobile/desktop client;
  write down the exact container name, published UDP port and Docker project.
- Export/backup the AmneziaVPN client configuration with its own
  Settings → Backup feature, and securely preserve any AWG client configs.
  Keep backups offline.
- Check `docker ps`, `docker info`, `ufw status verbose`, all published
  ports, provider-side firewall, and SSH user/port.
- Identify which SSH username AmneziaVPN uses to **manage** its self-hosted
  server. If this is `root`, disabling root SSH will not stop the already
  running UDP tunnel, but can break **future server management** in the app.
  Verify migration to `amnezia` SSH management with the official client
  **without** reinstalling the AWG container, or defer root-SSH lockout.
- Ensure VPS recovery console and another SSH connection are available.

## Phase 1: test changes off production

Use a disposable Ubuntu 22.04 or 24.04 VPS snapshot/test VM with Docker and a
separate UDP container. Run Xray bootstrap twice, compare the existing container
ID/image/port and Xray state/UUIDs. Test failed root SSH re-login to verify the
scheduled recovery timer restores sshd configuration. Github Actions syntax
checks are *not* sufficient for this.

## Phase 2: bring up Xray only

After code review and protecting the existing AWG Docker/iptables rules, use the
local `bootstrap.sh --server VPS_IP --protocol xray --confirm-disable-root-ssh` with **independent**
`vpnadmin` and `xray` keypairs. This entrypoint passes `--no-firewall`
and `--skip-package-upgrade` to Xray specifically to avoid resetting UFW or
unnecessary distribution upgrades. Docker must already be healthy; if the
installed daemon is unhealthy Xray aborts rather than attempting a Docker
replacement. Xray's Compose deployment no longer uses `--remove-orphans`.

The entrypoint requires `--confirm-disable-root-ssh`; this explicit flag
asserts you have checked AmneziaVPN can still be administered without a root
SSH login. Without the flag it aborts **before changing the VPS**.

The bootstrap will **disable root SSH** after success, including public key
and password authentication. Do not run this phase before you verify
AmneziaVPN's future administrative management can work without root.

Manually confirm TCP/443 is allowed at the VPS provider firewall and any
host firewall. Never add a generic default-deny UFW rule before examining the
existing AWG UDP port.

## Phase 3: issue independent Xray credentials

Each platform should have its own credential, never share the same UUID
between devices. From the workstation, using `vpnadmin` SSH:

```sh
ssh -i ~/.ssh/vpnadmin vpnadmin@VPS_IP 'sudo vpn-add-user android'
ssh -i ~/.ssh/vpnadmin vpnadmin@VPS_IP 'sudo vpn-add-user ios'
ssh -i ~/.ssh/vpnadmin vpnadmin@VPS_IP 'sudo vpn-add-user macos'
ssh -i ~/.ssh/vpnadmin vpnadmin@VPS_IP 'sudo vpn-add-user windows'
ssh -i ~/.ssh/vpnadmin vpnadmin@VPS_IP 'sudo vpn-add-user linux'
```

Copy personal VLESS link securely to the local sing-box generator. **Do not**
put credentials or generated profiles into GitHub. See `clients/README.md`.

The sing-box rule default is **DIRECT**: Russian, Chinese and other ordinary
sites bypass the VPN. Proxy routing is only for explicitly selected domains
and supported platform-specific apps/processes. Test routing for an included
domain and an ordinary excluded domain separately, including DNS.

Clients: https://sing-box.sagernet.org/clients/
- Android: sing-box for Android
- iOS / macOS: sing-box for Apple platforms
- Windows / Linux: sing-box for Desktop

Use `sing-box check` against the exact installed core version and test REALITY
handshake; JSON unit tests alone do not prove interoperability.

## Phase 4: acceptance and merge gates

1. Existing AmneziaWG works before, during and after Xray bootstrap.
2. AWG container ID and published UDP port unchanged, including after a
   second identical bootstrap run.
3. Xray container healthy, inbound TCP/443 externally reachable.
4. Existing Xray keys/UUIDs and container ID stay stable on no-op rerun.
5. Every selected site uses Xray; ordinary RU/CN sites go direct.
6. New vpnadmin/xray SSH logins succeed. Existing Amnezia server can still
   be managed via its official client after root-SSH policy change.
7. Root SSH with either password or public key is denied.
8. Simulate failed login and verify SSH rollback in a **test VM**.
9. Pass GitHub Actions and review the full diff.

### Git integration
- PR #2 was merged into the **experimental** `amnezia` branch.
- PR #3 (amnezia → master) stays Draft until acceptance tests.
- PR #1 (Xray/bootstrap → master) stays Draft until acceptance tests.
- Resolve overlap in `amnezia-setup.sh` before both PR #1/#3 are merged.


## CLI help (current)

Run `bash bootstrap.sh --help` for all arguments. First SSH login via password
is the default when `--initial-ssh-private-key` is omitted. The new flags
`--vpnadmin-ssh-private-key`, `--vpnadmin-ssh-public-key`,
`--xray-ssh-private-key`, and `--xray-ssh-public-key` name the keys' owner
and distinguish local private key files from public keys uploaded to the VPS.

## Existing AmneziaVPN sudoers permissions (Ubuntu 24.04)

A working AmneziaWG installation may have `/etc/sudoers.d/amnezia` with
permissions that are **too permissive for `visudo -c`**, even when
`sudo -n` happens to work. Example: `bad permissions, should be mode 0440`.

Before changing anything, inspect the existing sudoers file as root:

```sh
ssh root@VPS_IP 'stat -c "%U:%G %a %n" /etc/sudoers.d/amnezia; visudo -c'
```

If it is an ordinary, non-symlink, **root:root** file and `visudo` reports
only the mode error, fix the mode without changing content:

```sh
ssh root@VPS_IP 'test -f /etc/sudoers.d/amnezia &&
  test ! -L /etc/sudoers.d/amnezia &&
  test "$(stat -c %U:%G /etc/sudoers.d/amnezia)" = root:root &&
  chmod 0440 /etc/sudoers.d/amnezia &&
  visudo -c &&
  runuser -u amnezia -- sudo -n true'
```

No Docker restart or modification to AmneziaWG container is involved.
If other sudoers problems remain, **do not blindly change other files**;
inspect diagnostics first. On a failed first bootstrap the `vpnadmin`
account/public key may already exist, while its new sudoers drop-in
was rolled back; the next bootstrap is designed to finish configuring
that same account without changing its SSH key.

The remote `ensure-vpnadmin-remote.sh` now runs `visudo -c` **before**
creating any account or changing sudoers. Thus a pre-existing problem
results in an early stop instead of a partial installation.

