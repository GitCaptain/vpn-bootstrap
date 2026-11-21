#!/usr/bin/env python3
"""Generate sing-box profiles for VLESS + REALITY from vpn-show-user output.

Default routing: DIRECT. Only explicitly selected domains or processes use Xray.
No credentials or generated profiles should be committed to git.
"""
import argparse
import json
import os
from pathlib import Path
import re
import tempfile
from urllib.parse import parse_qs, urlsplit
from uuid import UUID

PLATFORMS = ("android", "ios", "macos", "windows", "linux")

def parse_link(raw):
    match = re.search(r"vless://[^\s<>\"']+", raw)
    if not match:
        raise ValueError("No VLESS URI found in input")
    parsed = urlsplit(match.group(0).rstrip(";,"))
    if parsed.scheme != "vless" or not parsed.hostname:
        raise ValueError("Invalid VLESS URI")
    args = parse_qs(parsed.query)
    get = lambda key, default="": args.get(key, [default])[0]
    if get("security") != "reality" or get("type", "tcp") != "tcp":
        raise ValueError("Expected VLESS REALITY over TCP")
    if get("flow") != "xtls-rprx-vision":
        raise ValueError("Expected xtls-rprx-vision flow")
    if get("encryption", "none") != "none":
        raise ValueError("Expected encryption=none")
    sid = get("sid")
    if len(sid) > 16 or len(sid) % 2 or not re.fullmatch(r"[a-fA-F0-9]*", sid):
        raise ValueError("Invalid REALITY shortId")
    if not get("sni") or not get("pbk"):
        raise ValueError("Missing REALITY server name or public key")
    return dict(server=parsed.hostname, port=parsed.port or 443,
                uuid=str(UUID(parsed.username)), sni=get("sni"),
                public_key=get("pbk"), short_id=sid, fp=get("fp", "chrome"))

def domain_suffixes(domains):
    results = []
    for item in domains:
        value = item.strip().lower().lstrip("*.").rstrip(".")
        if "://" in value or "/" in value or not value:
            raise ValueError("Expected a domain, not a URL: " + item)
        value = value.encode("idna").decode("ascii")
        if not re.fullmatch(r"[a-z0-9.-]+", value) or ".." in value or "." not in value:
            raise ValueError("Invalid domain: " + item)
        suffix = value
        if suffix not in results:
            results.append(suffix)
    return results

def build(conn, platform, proxy_domains=(), direct_domains=(), block_domains=(),
          proxy_apps=(), proxy_processes=(), fingerprint=None):
    if platform not in PLATFORMS:
        raise ValueError("Unsupported platform")
    if proxy_apps and platform != "android":
        raise ValueError("Android package rules require platform=android")
    if proxy_processes and platform not in ("windows", "linux", "macos"):
        raise ValueError("Process rules are supported here only on Windows, Linux and macOS")

    tun = {"type": "tun", "tag": "tun-in",
           "address": ["172.19.0.1/30", "fdfe:dcba:9876::1/126"],
           "auto_route": True, "dns_mode": "hijack", "mtu": 1400}
    if platform in ("linux", "windows"):
        tun["strict_route"] = True
    if platform == "linux":
        tun["auto_redirect"] = True

    rules = [
        {"action": "sniff"},
        {"protocol": "dns", "action": "hijack-dns"},
        {"ip_is_private": True, "action": "route", "outbound": "direct"},
    ]
    dns_rules = [
        {"domain_suffix": [".lan", ".local", ".home.arpa"],
         "action": "route", "server": "local-dns"},
    ]
    for value, outbound in ((block_domains, "reject"),
                            (proxy_domains, "proxy"),
                            (direct_domains, "direct")):
        suffixes = domain_suffixes(value)
        if not suffixes:
            continue
        if outbound == "reject":
            rules.append({"domain_suffix": suffixes, "action": "reject"})
            dns_rules.append({"domain_suffix": suffixes, "action": "reject"})
        else:
            rules.append({"domain_suffix": suffixes, "action": "route", "outbound": outbound})
            dns_rules.append({"domain_suffix": suffixes, "action": "route",
                              "server": "remote-dns" if outbound == "proxy" else "local-dns"})
    if proxy_apps:
        rules.insert(3, {"package_name": list(proxy_apps), "action": "route", "outbound": "proxy"})
    if proxy_processes:
        rules.insert(3, {"process_name": list(proxy_processes), "action": "route", "outbound": "proxy"})
    # All unspecified traffic (including RU/CN sites) remains DIRECT.
    config = {
        "$schema": "https://sing-box.sagernet.org/schema.json",
        "log": {"level": "warn", "timestamp": True},
        "dns": {
            "servers": [
                {"type": "local", "tag": "local-dns"},
                {"type": "https", "tag": "remote-dns", "server": "1.1.1.1",
                 "server_port": 443, "detour": "proxy"}
            ],
            "rules": dns_rules, "final": "local-dns", "strategy": "prefer_ipv4"
        },
        "inbounds": [tun],
        "outbounds": [
            {"type": "vless", "tag": "proxy", "server": conn["server"],
             "server_port": conn["port"], "uuid": conn["uuid"],
             "flow": "xtls-rprx-vision",
             "tls": {"enabled": True, "server_name": conn["sni"],
                     "utls": {"enabled": True, "fingerprint": fingerprint or conn["fp"]},
                     "reality": {"enabled": True, "public_key": conn["public_key"],
                                 "short_id": conn["short_id"]}}},
            {"type": "direct", "tag": "direct"}
        ],
        "route": {"rules": rules, "final": "direct",
                  "default_domain_resolver": "local-dns"}
    }
    if platform in ("windows", "linux", "macos"):
        config["route"]["auto_detect_interface"] = True
    return config

def secure_write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    if path.exists():
        raise FileExistsError(f"Refusing to overwrite {path}")
    fd, temp = tempfile.mkstemp(prefix=".singbox-", dir=path.parent, text=True)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            stream.write(content)
        os.replace(temp, path)
    finally:
        Path(temp).unlink(missing_ok=True)

def main():
    parser = argparse.ArgumentParser(description="VLESS REALITY to selective sing-box config")
    parser.add_argument("--link-file", required=True, help="File containing vpn-show-user output")
    parser.add_argument("--platform", required=True, choices=PLATFORMS)
    parser.add_argument("--output", required=True)
    parser.add_argument("--proxy-domain", action="append", default=[])
    parser.add_argument("--direct-domain", action="append", default=[])
    parser.add_argument("--block-domain", action="append", default=[])
    parser.add_argument("--proxy-app", action="append", default=[], help="Android package")
    parser.add_argument("--proxy-process", action="append", default=[], help="Windows/Linux process")
    parser.add_argument("--fingerprint", default=None)
    args = parser.parse_args()
    config = build(
        parse_link(Path(args.link_file).read_text(encoding="utf-8")),
        args.platform, args.proxy_domain, args.direct_domain,
        args.block_domain, args.proxy_app, args.proxy_process,
        args.fingerprint)
    secure_write(Path(args.output), json.dumps(config, ensure_ascii=False, indent=2) + "\n")

if __name__ == "__main__":
    main()
