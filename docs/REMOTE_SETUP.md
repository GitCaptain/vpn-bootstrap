# Unified local bootstrap (experimental / draft PR)

Run from your **own machine**. The single entrypoint selects Xray, Amnezia
administrative preparation, or both. It never runs in GitHub Actions.

## Required local SSH keys

Create/bring private and matching public SSH keys for:
- vpnadmin (the persistent administrative SSH fallback; never reuse root key)
- xray (only when installing Xray)
- amnezia (only when preparing AmneziaWG)

Keep private keys **only on the workstation**, not in Git. If a key is protected
by a passphrase, add it to your local ssh-agent first, so the separate
non-interactive login verification can succeed.

## Commands

Initially, when existing root SSH is still enabled:

\`\`\`sh
bash bootstrap.sh --server VPS_IP --protocol xray \
    --ssh-user root --ssh-key ~/.ssh/vps_root \
    --admin-key ~/.ssh/vpnadmin --admin-pubkey ~/.ssh/vpnadmin.pub \
    --xray-pubkey ~/.ssh/xray.pub
\`\`\`

For a machine where root initially uses password authentication, use
\`--ssh-key -\`; SSH will prompt for the *initial root login*.

To provision the backup Amnezia account later (root SSH already prohibited):

\`\`\`sh
bash bootstrap.sh --server VPS_IP --protocol amnezia \
    --admin-key ~/.ssh/vpnadmin --admin-pubkey ~/.ssh/vpnadmin.pub \
    --amnezia-pubkey ~/.ssh/amnezia.pub
\`\`\`

For both stages on a fresh host choose \`--protocol both\`. Local defaults are
\`$HOME/.ssh/vpnadmin\`, \`$HOME/.ssh/vpnadmin.pub\`, \`$HOME/.ssh/xray.pub\`,
\`$HOME/.ssh/amnezia.pub\`, and SSH port 22.

## Exactly what is installed

- Xray: \`vpn-bootstrap.sh\` installs/reuses Docker and manages the
  dedicated non-root \`xray-reality\` container and separate SSH management
  account \`xray\`. The script verifies container readiness and TCP listener.
  Repeated runs with unchanged desired config should not recreate the container.
- Amnezia: \`amnezia-setup.sh\` creates/validates separate \`amnezia\` SSH
  account with key-only login and root-equivalent passwordless sudo. **It does
  not install the AWG container.** Official AmneziaVPN Self-hosted GUI must
  create/discover/manage the separate AmneziaWG container. The unified CLI
  reports this remaining manual step; do not mistake account preparation for
  an operating AWG server. We deliberately do not deploy a third-party AWG
  server that AmneziaVPN may not be able to manage.
- One VPS can have both (Xray TCP and AmneziaWG UDP). Do not let the Amnezia
  app install another Xray into the same server.

## Root SSH lockout

On a successful local run, bootstrap *automatically* sets
\`PermitRootLogin no\`, prohibiting root SSH login with either password or
public key. It first creates/verifies \`vpnadmin\` using a **fresh SSH session**
and \`sudo -n\`, then arms a 240-second systemd rollback timer before changing
SSH settings. After the change, it checks the effective \`sshd -T\` policy and
makes another independent \`vpnadmin\` login. Only then is the timer disarmed.

If confirmation fails, the timer restores the previous sshd_config, unless
the operator has repaired it first. Run the script from a trusted host and
maintain access to your VPS provider's recovery console.

The root account is **not deleted**, and local console/sudo access is not
disabled. Only SSH root login is forbidden. Other accounts' global SSH
password policies are not silently changed.

Both \`xray\` and \`amnezia\` have administrative sudo privileges (as required
by their management workflows). They are not isolation boundaries from the
host's root-managed Docker daemon.

## Before merging PRs

The GitHub Actions checks cover Bash syntax and Python unit tests. They do
**not** establish that the bootstrap is safe to run on an existing server.
Test two clean Ubuntu LTS VMs with both install orders, then rerun each mode
and compare Docker container IDs, keys, \`sshd -T\` output and UFW rules.
Test a simulated failed SSH reconnect and confirm timed rollback before
deploying to a production VPS.


---

## Legacy direct setup details

# Workstation-driven setup and separation

Run the scripts from **your own Linux/macOS workstation**, supplying the target
VPS address. They connect with SSH. Nothing is automatically deployed from GitHub.

## Design

| Component | Administrative SSH user on VPS | Docker runtime |
| --- | --- | --- |
| Primary Xray | `xray` | Existing `xray-reality` container (official non-root image) |
| Backup AmneziaWG | `amnezia` | Separate AWG container installed/managed by official AmneziaVPN app |

Both users receive broad sudo access for administration. These are independent
login identities, **not** mutually isolated security domains. Docker's daemon
is typically root-run; an AWG container may require NET_ADMIN and its own
kernel/TUN capabilities. Never assume AWG can run as an unprivileged process
simply because the SSH management user is named `amnezia`.

## First-stage Xray setup

From a clone of the repository, on the new Xray branch:

```bash
bash bin/setup-xray-remote.sh VPS_IP root ~/.ssh/vps_admin ~/.ssh/xray.pub 22
```

Pass `-` instead of the admin private-key path if the existing SSH admin
uses ssh-agent or interactive authentication. The remote administrative account
must be root or have passwordless sudo. The script reads the local
`vpn-bootstrap.sh` and streams it to the remote server; it never copies
private keys or user VPN credentials to GitHub. The public key is installed
for the dedicated `xray` management user.

Use additional upstream bootstrap flags only after `--`, e.g.
`-- --skip-package-upgrade`. SSH hardening is intentionally unavailable
from this initial wrapper; confirm a fresh working key login first.

## Amnezia preparation

On the `amnezia` branch use the local script:

```bash
AMNEZIA_ADMIN_SSH_KEY=~/.ssh/vps_admin bash amnezia-setup.sh VPS_IP root ~/.ssh/amnezia.pub 22 amnezia
```

This creates the `amnezia` SSH account with **key-only authentication**,
locks its password, configures passwordless sudo as required by the AmneziaVPN
installer, and checks SSH configuration before reloading. For the initial
bootstrap admin login, either an SSH private key or normal password-based SSH
may be used; the **new** `amnezia` account remains key-only.

In official AmneziaVPN choose Self-hosted, SSH user `amnezia`, use the
matching private key, then install **AmneziaWG only**. The local preparation
script does not install an AWG container itself. Do not let the AmneziaVPN
client install another Xray instance into this VPS.

## Safety

- Verify the SSH server fingerprint via a trusted out-of-band source.
- Back up the VPS and current Xray state and credentials.
- Do not change SSH root/password settings until both new SSH key logins work.
- Re-running scripts should preserve existing user credentials and state.
- Xray TCP/443 and AWG UDP port can coexist; ensure AWG does not overwrite
  Docker/firewall configuration used by Xray. Back up and verify firewall rules.
- Before upgrading the Xray server, test REALITY ClientHello compatibility on
  all devices and review current security advisories.
- Keep provider recovery console access.

Documentation:
- https://docs.amnezia.org/documentation/supported-linux-os-for-vps/
- https://docs.amnezia.org/troubleshooting/error-codes/

## 2026 Linux kernel security review

Before deploying/operating a publicly reachable VPS, verify the kernel's
status for **CVE-2026-98432** and the exposure of MPTCP listeners. Amnezia
warns that affected kernels require a distribution security fix **and reboot**;
Xray has also changed its MPTCP defaults in newer releases. Do not
blindly upgrade Xray to an incompatible REALITY version, and do not assume
that simply rebuilding the container patches the host kernel.

Official notice: https://docs.amnezia.org/documentation/instructions/update-server-cve-2026-98432/
