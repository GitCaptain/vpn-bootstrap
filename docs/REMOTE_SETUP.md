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
