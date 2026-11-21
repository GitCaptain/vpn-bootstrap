# Selective Xray / sing-box clients

Use `vpn-show-user DEVICE` on the Xray server to obtain a **private** VLESS
REALITY URI. Do not commit this link, generated JSON, UUIDs, shortIds or keys.

This generator targets sing-box 1.14+ config format and the sing-box graphical
clients for Android, iOS, macOS, Windows and Linux. Client/kernel versions
must be tested against the pinned Xray version before upgrading.

## Routing policy

**Direct is the default for all websites and apps**, including Russian and
Chinese destinations. Only explicitly listed `--proxy-domain`,
`--proxy-app` (Android package) and `--proxy-process` (Windows/Linux/macOS)
use Xray. Add domains according to what *you* want to proxy, not a large
predefined country blocklist.

DNS defaults to the platform's local resolver; selected proxy domains use
Cloudflare DoH over Xray. Websites with shared CDNs, embedded third-party
requests, browser DoH, or encrypted ClientHello can require more rules.
DNS and per-app behavior must be verified on actual devices.

## Example

Generate a separate profile per device and avoid using one credential for
multiple devices:

```sh
mkdir -p "$HOME/.config/vpn-bootstrap"
chmod 700 "$HOME/.config/vpn-bootstrap"
# Save the private VLESS link as a 0600 file OUTSIDE the git checkout.
python3 clients/generate_singbox.py \
  --link-file "$HOME/.config/vpn-bootstrap/phone.vless" \
  --platform android \
  --proxy-domain openai.com \
  --proxy-domain chatgpt.com \
  --proxy-app org.telegram.messenger \
  --output "$HOME/.config/vpn-bootstrap/phone.json"
```

For Linux, replace `--platform android` and `--proxy-app` with
`--platform linux --proxy-process telegram-desktop`, if your client
supports process detection. Windows and macOS also support process-name
rules in the sing-box core; verify your chosen graphical client supports
them. iOS should use domain rules, not process-name rules. Android package rules require the app's correct package name.

Domain-suffix rules are written **without a leading dot**, so both the base
domain and its subdomains are matched by sing-box 1.9+.

Use `--direct-domain example.ru` for an explicit exception and
`--block-domain ads.example` to block a domain.

A local syntax check with a compatible sing-box binary is recommended:

```sh
sing-box check -c "$HOME/.config/vpn-bootstrap/phone.json"
```

Runtime connectivity, REALITY/uTLS handshake and Apple/Android VPN permissions
need a real-device test; syntax checks alone do not establish compatibility.

## Compatibility and rollout

Keep the existing server REALITY keys and users. Xray is intentionally pinned
and should not be silently upgraded; some Xray versions have REALITY ClientHello
compatibility changes. Create a fresh named device profile for each device,
test IP/DNS and selected/direct domains, and only then roll out to other devices.

AmneziaWG remains **independent backup VPN** (different protocol, client and
credentials). Its setup belongs to the `amnezia` branch, not to this generator.

## Install

Official app list: https://sing-box.sagernet.org/clients/

- Android: sing-box for Android
- iOS / macOS: sing-box for Apple platforms
- Windows / Linux: sing-box for Desktop

The exact local-profile import interface depends on the specific app release.
Do not put VPN links or generated JSON into GitHub issues.
