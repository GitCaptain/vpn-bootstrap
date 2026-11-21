# VPN setup — project handoff (21 November 2026)

This document records the decisions from the ChatGPT VPN setup discussion for
continued work in ChatGPT Work or other code-review sessions.

## Sources
- Repo: https://github.com/GitCaptain/vpn-bootstrap
- Primary script: master/vpn-bootstrap.sh
- Backup AmneziaWG: amnezia/amnezia-setup.sh
- Draft Xray/client PR: https://github.com/GitCaptain/vpn-bootstrap/pull/1

## Requirements (confirmed by user)
1. Primary VPN: Xray VLESS + REALITY + XTLS Vision.
2. **SELECTIVE client routing**: all traffic DIRECT by default. Only an
   explicit, editable list of websites and apps uses Xray. This includes
   Russian sites: direct. China can later get additional rules, but currently
   remains direct by default. User gave ChatGPT and Telegram as *examples* of
   selectable applications/services; not a fixed allowlist.
3. Target operating systems: Android, iOS, macOS, Windows, Linux. sing-box
   chosen as candidate unified core/client. Check current official graphical
   clients and real feature differences: package-name routing on Android,
   process matching on supported Windows/Linux builds, domain rules on iOS.
4. Backup connection: **AmneziaWG, separate AmneziaVPN client/server and
   config**, independent from Xray. Do not mix Amnezia VPN imports with the
   principal Xray client and do not disturb AWG.
5. GitHub commits and PRs preferred over pasting scripts or archives in chat.
6. Protect existing VPS SSH access, never deploy/disable password/root access
   without explicit review and verified second login. No server deployment
   was requested.
7. Preserve existing Xray keys/users and state. Upgrades must be explicit and
   reversible. Verify REALITY ClientHello/uTLS compatibility before upgrading.

## Review of amnezia/amnezia-setup.sh (not merged into Xray)
- Default created account password is literal `amnezia` unless overridden;
  this is unsafe. Prompt securely or generate a random password.
- The newly created user receives unrestricted passwordless sudo
  (`NOPASSWD: ALL`). Minimize privileges or explicitly document the risk.
- Initial SSH transport demands password/keyboard-interactive authentication
  (PubkeyAuthentication=no), so it cannot work against key-only SSH.
- User/password data are passed as base64, which is **not encryption**.
  Treat pipeline/process/environment exposure as a security concern.
- The SSH Match block is appended to sshd_config, with backup/validation, but
  interacts with other Match blocks and should be tested using sshd -T on
  supported Ubuntu releases. Prefer a dedicated drop-in and staged rollout.
- Script prepares a privileged SSH account **for using AmneziaVPN**; it does
  not deploy AmneziaWG itself. Do not conflate client preparation and server
  protocol setup.
- Work on this file separately, targeting the `amnezia` branch.

## Draft PR #1 coverage
- Xray bootstrap: RU server blocking opt-in for new installations; older
  state remains unchanged. Harden REALITY target validation.
- Conservative IPv4 resolution when Docker IPv6 egress not tested.
- Do not advertise outbound-detected IPv6 as inbound reachable automatically.
- Container capabilities dropped and PID limit set.
- `clients/generate_singbox.py` with `route.final=direct`, `dns.final=local-dns`,
  explicit proxy-domain and Android app / Windows Linux process rules,
  no credentials in Git.
- README and unit tests; not yet end-to-end integration verified.

## Outstanding tasks
- CI syntax checks on Bash and Python, integration tests with actual sing-box
  binaries and supported OS clients.
- Verify domain DNS/routing for selected websites and content/CDNs.
- Better Docker-namespace IPv6 diagnostics; avoid UFW/Docker bypass and
  stale rules on port changes.
- Review correct Xray REALITY target choice and default fingerprint against
  the pinned Xray 26.3.27 and specific sing-box client versions.
- Add stable, secure client configuration distribution/provisioning if needed,
  without committing user secrets.
- Keep Xray PR draft until review and tests; do not merge/deploy automatically.

## Updated local-first deployment architecture (21 Nov 2026)
- The user will invoke setup scripts on their **own workstation**, passing
  the destination VPS address. No automatic deployments or GitHub Actions
  deployments to the VPS.
- Xray setup: `bin/setup-xray-remote.sh` streams the existing
  `vpn-bootstrap.sh` over SSH, with an independent `xray` management account.
  Use an existing root or passwordless-sudo admin for the initial connection.
  Xray container remains the dedicated `xray-reality` Docker service.
- Amnezia setup: `amnezia-setup.sh` already runs from the workstation;
  a separate review PR is open:
  https://github.com/GitCaptain/vpn-bootstrap/pull/2 (base: amnezia).
  It creates/maintains independent SSH account `amnezia`, locked password
  and SSH key only. It deliberately retains unrestricted passwordless sudo
  per upstream AmneziaVPN installation requirements.
- AmneziaWG container is installed by official AmneziaVPN Self-hosted UI
  *after* account prep, and must be separate from Xray. Distinct SSH identities
  and containers do not equal isolation from root when admins have NOPASSWD
  sudo; AmneziaWG may need privileged NET_ADMIN in its container.
- Official AmneziaVPN supports either SSH password or private-key
  authentication and non-root sudo account with passwordless permissions:
  https://docs.amnezia.org/documentation/supported-linux-os-for-vps/
  https://docs.amnezia.org/troubleshooting/error-codes/
- A new chat does not automatically enable Work; current GitHub integration
  is usable in this chat. For context in any new chat, point it to this file
  and both PRs.
