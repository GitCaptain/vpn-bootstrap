# Selective Xray / sing-box clients

Use `vpn-show-user DEVICE` on the Xray server to obtain a **private** VLESS
REALITY URI. Do not commit this link, generated JSON, UUIDs, shortIds or keys.

This generator targets sing-box 1.14+ config format and the sing-box graphical
clients for Android, iOS, macOS, Windows and Linux. Client/kernel versions
must be tested against the pinned Xray version before upgrading.

## Выбор сайтов мышкой на iplist.opencck.org (без ручных доменов)

Для SFM на macOS и sing-box на Android, iOS, Linux, Windows можно выбрать
готовые категории сайтов и скачать правила в формате sing-box.

1. Открой https://iplist.opencck.org/ru/ .
2. Выбери **Порталы** и/или **Группы** (например, YouTube, ChatGPT,
   Telegram). Не оставляй выбор пустым: сервис тогда может вернуть весь каталог.
3. В поле **Формат** выбери **Sing-box rule-set (json)**, а в
   **Тип данных** — **Домены**. Рекомендуется тип совпадения
   **Домен и поддомены (суффикс)** (по умолчанию).
4. Включи **Сохранить как файл** и нажми **Отправить**. Сайт отдаст
   `ip-list.json` — файл с правилами, но **без** серверных VLESS-ключей.
5. Скачанный файл передай в наш генератор **не вместо ссылки Xray**,
   а вместе с ней — через `--iplist-rule-set`.

Пример для уже установленного Xray и пользователя `macos`. Выполняется
**на Mac**, а не на VPS:

```bash
cd ~/Projects/vpn-bootstrap
mkdir -p "$HOME/.config/vpn-bootstrap"
chmod 700 "$HOME/.config/vpn-bootstrap"
umask 077
set -o pipefail

ssh -i ~/.ssh/vpnadmin vpnadmin@VPS_IP 'sudo vpn-show-user macos' |
  python3 clients/generate_singbox.py \
    --link-file /dev/stdin \
    --platform macos \
    --iplist-rule-set "$HOME/Downloads/ip-list.json" \
    --output "$HOME/.config/vpn-bootstrap/macos-iplist.json"

sing-box check -c "$HOME/.config/vpn-bootstrap/macos-iplist.json"
```

Заменить `VPS_IP` на адрес своего сервера. Проверить, что файл скачался,
можно через `ls -l ~/Downloads/ip-list.json`. Если имя отличается, укажи
правильный путь. Выводной файл с ключами — 0600, находится вне Git.

Чтобы добавить выбор по IP-сетям (например, приложение обращается напрямую
к IP-адресу без доменного имени), выгрузи **те же Порталы/Группы** второй
раз с **Тип данных: IP-зоны ipv4 (CIDR)**, сохрани файл под другим именем
(например, `ip-list-cidr.json`) и добавь второй аргумент:

```text
--iplist-rule-set "$HOME/Downloads/ip-list-cidr.json"
```

Экспортируй именно **Sing-box rule-set (json)**, не `JSON`, `Amnezia`
и не `Sing-box rule-set (srs)` — эти файлы имеют другой формат. Скрипт
проверит структуру данных и не выполнит потенциальные действия из чужого JSON:
он переносит только правила совпадения доменов и IP-сетей. Имена доменов
и IP-правила копируются в итоговый JSON, **без обращений к сайту при
последующем запуске VPN**. Чтобы обновить категории, повторно выгрузи
список и создай новый файл профиля.

После генерации импортируй `macos-iplist.json` в SFM как локальный
профиль. **DIRECT остаётся по умолчанию**, через Xray пойдут только
выбранные на сайте домены/IP и другие явно добавленные правила.
Если сайт был выбран по домену, но приложение использует отдельные IP
и другие домены, понадобятся дополнительные категории/экспорт CIDR.

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

## macOS: first connection (standalone SFM)

The official sing-box macOS client is **SFM standalone**, available from
https://sing-box.sagernet.org/clients/apple/ . Official Homebrew command:

```sh
brew install sfm
```

SFM needs macOS 13+. On first start, allow the macOS VPN/System Extension
permission when requested. The app supports local profiles as full sing-box
JSON. An imported bare `vless://` link is not a substitute for the selective
routing JSON below.

For a server already provisioned with an Xray user named `macos`, create
the config on your Mac directly from the VPS over SSH **without committing
credentials or writing a separate VLESS-link file**:

```sh
cd ~/Projects/vpn-bootstrap
mkdir -p "$HOME/.config/vpn-bootstrap"
chmod 700 "$HOME/.config/vpn-bootstrap"
umask 077
set -o pipefail
ssh -i "$HOME/.ssh/vpnadmin" vpnadmin@VPS_IP 'sudo vpn-show-user macos' |
  python3 clients/generate_singbox.py \
    --link-file /dev/stdin \
    --platform macos \
    --proxy-domain openai.com \
    --proxy-domain chatgpt.com \
    --proxy-domain oaistatic.com \
    --proxy-domain oaiusercontent.com \
    --proxy-domain api.ipify.org \
    --output "$HOME/.config/vpn-bootstrap/macos.json"
```

Replace `VPS_IP` with your server's address. `api.ipify.org` is an
**optional diagnostic** that echoes your Xray server egress IP when the
profile is enabled. Remove it from routing after testing if desired.

The generator writes `macos.json` with mode 0600; do not store the profile
inside the Git checkout. If the output file already exists, the generator
intentionally refuses to overwrite it. Back it up locally and choose a new
output name for another version.

Open SFM, go to Profiles, create a **Local** profile, open its JSON editor,
paste the contents of `macos.json`, save and select it; start the
sing-box service. The exact button labels vary by app version.
You can copy the local config into the macOS clipboard with:

```sh
pbcopy < "$HOME/.config/vpn-bootstrap/macos.json"
```

**Treat the clipboard as sensitive:** it contains your private Xray
credentials and may synchronize between Apple devices when Universal
Clipboard is enabled. Paste into the local profile, and clear the clipboard
when done. Prefer file import if your installed SFM build offers it.

Routing policy is **DIRECT by default**, including all Russian and Chinese
sites. Only the explicit `--proxy-domain` list uses Xray. When your Mac
supports it, add `--proxy-process Telegram` to direct the whole Telegram
process via Xray, but be aware that domain rules do not by themselves cover
all IP-only application connections. Process matching requires the macOS
standalone client. Do not expect iOS to support this same rule.

Verification **with SFM connected**:

```sh
curl -4 https://api.ipify.org
curl -4 https://ifconfig.me/ip
```

The first command should report the VPS egress IPv4 address if its explicit
route is applied. The second should report your normal ISP/public IP, ideally
matching a test while SFM is stopped. Test a ChatGPT page and an ordinary
Russian website too. If the reported IPs do not behave as expected, inspect
SFM's connection dashboard and service log; a successful `sing-box check`
alone does not establish a working VLESS/REALITY handshake.

On some Macs, a VPN app running concurrently can interfere with SFM's
NetworkExtension routing; test with the backup AmneziaVPN tunnel disconnected
on **the Mac**, without stopping its server container.

Official references:
- https://sing-box.sagernet.org/clients/apple/
- https://sing-box.sagernet.org/clients/apple/features/
- https://sing-box.sagernet.org/clients/general/

## Install

Official app list: https://sing-box.sagernet.org/clients/

- Android: sing-box for Android
- iOS / macOS: sing-box for Apple platforms
- Windows / Linux: sing-box for Desktop

The exact local-profile import interface depends on the specific app release.
Do not put VPN links or generated JSON into GitHub issues.
