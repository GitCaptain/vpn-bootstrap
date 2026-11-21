# AmneziaWG self-hosted preparation

This branch prepares an SSH administrative account for the **official**
AmneziaVPN desktop/mobile client's self-hosted server setup. It does **not**
install AmneziaWG itself. The AmneziaVPN client installs and manages its own
AWG Docker container, separate from Xray's `xray-reality`.

## Local workstation setup

```bash
AMNEZIA_ADMIN_SSH_KEY="$HOME/.ssh/vps_admin" \
  bash amnezia-setup.sh VPS_IP root "$HOME/.ssh/amnezia.pub" 22 amnezia
```

The existing server admin may authenticate over SSH by key or password.
If a non-root admin account is used, **its sudo must already be passwordless**;
the script deliberately does not ask for or transfer sudo passwords.

The *new* `amnezia` account is configured key-only; its password is locked.
Provide the corresponding *private* key to the **official AmneziaVPN app**
when creating the self-hosted connection. Use the AmneziaWG protocol only,
not the Xray protocol managed in master. Avoid port conflicts and preserve
firewall rules for both protocols.

By official design the app requires unrestricted passwordless sudo to
administer Docker and network services. This is equivalent to administrative
access even though the SSH account is not `root`. Do not treat it as
unprivileged process isolation. Prefer separate keys, restrict SSH exposure
where feasible and keep a safe recovery admin account/console.

If an older setup created `amnezia` with a password, this version locks it.
**First make sure that the matching SSH private key is present and works**.
The script checks `sshd -t`/`sshd -T` and reloads SSH, but no script can
fully prove a new network login from the VPS itself. Verify an actual fresh
login *before* you close your existing admin session.

Official references:
- https://docs.amnezia.org/documentation/instructions/install-vpn-on-server/
- https://docs.amnezia.org/documentation/supported-linux-os-for-vps/
- https://docs.amnezia.org/troubleshooting/error-codes/

## SSH key format compatibility

The AmneziaVPN FAQ explicitly lists RSA (2048/3072/4096) and ECDSA
(nistp256) SSH keys; its SSH error-code guide additionally mentions
OpenSSH ED25519 and PEM private-key formats. Because these pages are not
fully consistent, verify your **specific app version's** private-key parser.
For broadly documented compatibility, a dedicated ECDSA nistp256 private key
in PEM format is a reasonable starting point; never reuse the VPS admin key.

Sources:
- https://docs.amnezia.org/ru/faq/
- https://docs.amnezia.org/troubleshooting/error-codes/
