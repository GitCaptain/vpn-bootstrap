import sys
from pathlib import Path
import unittest
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from generate_singbox import parse_link, build, domain_suffixes

LINK = ('vless://5f3877a8-19a2-4e7d-a90f-fc4af125c70b@203.0.113.10:443'
        '?encryption=none&flow=xtls-rprx-vision&security=reality&sni=www.example.com'
        '&fp=chrome&pbk=ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmno&sid=abcd1234&type=tcp#test')

class ClientConfigTests(unittest.TestCase):
    def test_direct_by_default_on_every_platform(self):
        for platform in ("android", "ios", "macos", "windows", "linux"):
            with self.subTest(platform=platform):
                conf = build(parse_link(LINK), platform)
                self.assertEqual(conf["route"]["final"], "direct")
                self.assertEqual(conf["dns"]["final"], "local-dns")

    def test_selected_domains_use_proxy(self):
        conf = build(parse_link(LINK), "ios", proxy_domains=["openai.com"])
        self.assertIn({"domain_suffix": ["openai.com"], "action": "route",
                       "outbound": "proxy"}, conf["route"]["rules"])
        self.assertIn({"domain_suffix": ["openai.com"], "action": "route",
                       "server": "remote-dns"}, conf["dns"]["rules"])

    def test_process_rule_on_macos(self):
        conf = build(parse_link(LINK), "macos", proxy_processes=["Telegram"])
        self.assertIn({"process_name": ["Telegram"], "action": "route",
                       "outbound": "proxy"}, conf["route"]["rules"])

    def test_suffixes_include_apex(self):
        # sing-box 1.9+: a suffix WITHOUT leading dot matches apex and subdomains.
        self.assertEqual(domain_suffixes(["openai.com", "*.openai.com"]), ["openai.com"])

    def test_no_app_rule_on_ios(self):
        with self.assertRaises(ValueError):
            build(parse_link(LINK), "ios", proxy_apps=["org.telegram.messenger"])

    def test_idna(self):
        self.assertEqual(domain_suffixes(["пример.рф"]), ["xn--e1afmkfd.xn--p1ai"])

if __name__ == "__main__":
    unittest.main()
