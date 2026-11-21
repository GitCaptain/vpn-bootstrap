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

IPLIST_FIELDS = ("domain", "domain_suffix", "domain_keyword", "domain_regex", "ip_cidr")
IPLIST_DOMAIN_FIELDS = ("domain", "domain_suffix", "domain_keyword", "domain_regex")


def load_iplist_rule_set(path):
    """Read the 'Sing-box rule-set (json)' selected/exported on iplist.opencck.org.

    The website exports rule-set sources, not a complete VPN client profile.
    Copy only supported routing matchers, never remote actions or outbounds.
    """
    data = json.loads(Path(path).read_text(encoding="utf-8"))
    if not isinstance(data, dict) or not isinstance(data.get("version"), int) or not isinstance(data.get("rules"), list):
        raise ValueError("Expected an iplist sing-box rule-set JSON with version and rules")
    if data["version"] not in range(1, 6):
        raise ValueError("Unsupported iplist rule-set version")
    if len(data["rules"]) > 1000:
        raise ValueError("Too many iplist rules")
    result = []
    for rule in data["rules"]:
        if not isinstance(rule, dict) or not rule:
            raise ValueError("Invalid iplist rule")
        unsupported = set(rule) - set(IPLIST_FIELDS)
        if unsupported:
            raise ValueError("Unsupported iplist matcher(s): " + ", ".join(sorted(unsupported)))
        values = {}
        for key, entries in rule.items():
            if not isinstance(entries, list) or len(entries) > 50000 or any(
                not isinstance(v, str) or not v or len(v) > 1024 for v in entries
            ):
                raise ValueError("Invalid iplist values in " + key)
            if entries:
                values[key] = entries
        if values:
            result.append(values)
    if not result:
        raise ValueError("The iplist rule-set is empty; select some portals/groups on the website")
    return result


def append_iplist_rules(config, iplist_rules):
    """Apply imported site categories to the Xray outbound, preserving DIRECT as fallback.

    Different rule fields are made separate OR alternatives, so a website's
    domain + '.domain' suffix combination matches BOTH apex and subdomains.
    No extra fetches, dependencies, or files are needed once JSON is generated.
    """
    for source_rule in iplist_rules:
        parts = [{field: entries} for field, entries in source_rule.items() if entries]
        if not parts:
            continue
        match = parts[0] if len(parts) == 1 else {
            "type": "logical", "mode": "or", "rules": parts
        }
        config["route"]["rules"].append({
            **match, "action": "route", "outbound": "proxy"
        })
        dns_parts = [{field: source_rule[field]} for field in IPLIST_DOMAIN_FIELDS
                     if source_rule.get(field)]
        if dns_parts:
            dns_match = dns_parts[0] if len(dns_parts) == 1 else {
                "type": "logical", "mode": "or", "rules": dns_parts
            }
            config["dns"]["rules"].append({
                **dns_match, "action": "route", "server": "remote-dns"
            })


def build(conn, platform, proxy_domains=(), direct_domains=(), block_domains=(),
          proxy_apps=(), proxy_processes=(), fingerprint=None, iplist_rules=()):
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
    append_iplist_rules(config, iplist_rules)
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
    parser.add_argument("--iplist-rule-set", action="append", default=[],
                        metavar="FILE", help="Downloaded JSON from iplist.opencck.org: Sing-box rule-set (json), one or more files")
    parser.add_argument("--direct-domain", action="append", default=[])
    parser.add_argument("--block-domain", action="append", default=[])
    parser.add_argument("--proxy-app", action="append", default=[], help="Android package")
    parser.add_argument("--proxy-process", action="append", default=[], help="Windows/Linux process")
    parser.add_argument("--fingerprint", default=None)
    args = parser.parse_args()
    iplist_rules = []
    for path in args.iplist_rule_set:
        iplist_rules.extend(load_iplist_rule_set(path))
    config = build(
        parse_link(Path(args.link_file).read_text(encoding="utf-8")),
        args.platform, args.proxy_domain, args.direct_domain,
        args.block_domain, args.proxy_app, args.proxy_process,
        args.fingerprint, iplist_rules)
    secure_write(Path(args.output), json.dumps(config, ensure_ascii=False, indent=2) + "\n")

if __name__ == "__main__":
    main()
