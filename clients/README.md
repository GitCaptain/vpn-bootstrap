# Selective Xray / sing-box clients

Use `vpn-show-user DEVICE` on the Xray server to obtain a **private** VLESS
REALITY URI. Do not commit this link, generated JSON, UUIDs, shortIds or keys.

This generator targets sing-box 1.14+ config format and the sing-box graphical
clients for Android, iOS, macOS, Windows and Linux. Client/kernel versions
must be tested against the pinned Xray version before upgrading.

## Routing policy

**Direct is the default for all websites and apps**, including Russian and
Chinese destinations. Only explicitly listed `--proxy-domain`,
`--proxy-app` (Android package) and `--proxy-process` (Windows/Linux)
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
python3 clients/generate_singbox.py \
  --link-file phone.vless \
  --platform android \
  --proxy-domain openai.com \
  --proxy-domain chatgpt.com \
  --proxy-app org.telegram.messenger \
  --output phone.json
```

For Linux, replace `--platform android` and `--proxy-app` with
`--platform linux --proxy-process telegram-desktop`, if your client
supports process detection. Windows has the same option. macOS and iOS
should use domain rules; per-app process selection is **not** promised on
those platforms. Android package rules require the app's correct package name.

Use `--direct-domain example.ru` for an explicit exception and
`--block-domain ads.example` to block a domain.

A local syntax check with a compatible sing-box binary is recommended:

```sh
sing-box check -c phone.json
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
