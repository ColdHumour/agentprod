#!/usr/bin/env python3
"""Offline tests. No VPS access and no third-party Python packages."""
import base64
import copy
import importlib.util
import ipaddress
import json
import os
from pathlib import Path
import tempfile
import unittest
from urllib.parse import parse_qs, urlsplit

spec = importlib.util.spec_from_file_location("xray_vps", Path(__file__).resolve().parents[1] / "xray_vps.py")
cfg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfg)


def state():
    # Synthetic fixtures only; never use these values on a server.
    return dict(address="8.8.8.8", target="www.cloudflare.com", kcp_port=45678, reality_port=443,
                version="v-test", kcp_uuid="00112233-4455-4677-8899-aabbccddeeff",
                reality_uuid="11223344-5566-4788-99aa-bbccddeeff00", seed="test-seed-only",
                private_key="PRIVATE_TEST_KEY", public_key="PUBLIC_TEST_KEY", short_id="1234567890abcdef")


class ConfigTests(unittest.TestCase):
    def test_public_address_validation(self):
        for address in ("127.0.0.1", "10.0.0.1", "169.254.169.254", "::1", "224.0.0.1", "not-an-ip"):
            with self.subTest(address=address), self.assertRaises(ValueError):
                cfg.validate(dict(state(), address=address))
        cfg.validate(state())

    def test_port_validation(self):
        for port in (0, -1, 65536, "443", 22):
            with self.subTest(port=port), self.assertRaises(ValueError):
                cfg.validate(dict(state(), reality_port=port))

    def test_hostname_validation(self):
        for host in ("localhost", "1.2.3.4", "https://example.com", "x;id.com", "a\nb.com", "example.com:443"):
            with self.subTest(host=host), self.assertRaises(ValueError):
                cfg.validate(dict(state(), target=host))

    def test_kcp_is_authenticated_and_encrypted_vmess(self):
        inbound = cfg.server_config(state())["inbounds"][0]
        self.assertEqual(inbound["protocol"], "vmess")
        self.assertTrue(inbound["settings"]["disableInsecureEncryption"])
        self.assertEqual(inbound["settings"]["clients"][0]["alterId"], 0)

    def test_kcp_mask_order_and_seed(self):
        udp = cfg.kcp_stream(state())["finalmask"]["udp"]
        self.assertEqual(udp, [{"type": "header-dtls"},
                              {"type": "mkcp-aes128gcm", "settings": {"password": "test-seed-only"}}])

    def test_reality_has_no_empty_short_id(self):
        reality = cfg.server_config(state())["inbounds"][1]["streamSettings"]["realitySettings"]
        self.assertEqual(reality["shortIds"], [state()["short_id"]])
        self.assertEqual(reality["target"], "www.cloudflare.com:443")
        for key in ("limitFallbackUpload", "limitFallbackDownload"):
            self.assertGreater(reality[key]["bytesPerSec"], 0)
            self.assertEqual(reality[key]["afterBytes"], 0)

    def test_no_management_listener(self):
        c = cfg.server_config(state())
        self.assertEqual(len(c["inbounds"]), 2)
        self.assertNotIn("api", c)

    def test_private_and_metadata_routes_blocked(self):
        rule = cfg.server_config(state())["routing"]["rules"][0]
        self.assertEqual(rule["outboundTag"], "block")
        for address in ("127.0.0.1", "169.254.169.254", "10.0.0.1", "192.168.1.1", "::1", "fd00::1", "fe80::1"):
            ip = ipaddress.ip_address(address)
            self.assertTrue(any(ip in ipaddress.ip_network(n) for n in rule["ip"]))

    def test_vmess_import_link(self):
        uri = cfg.links(state()).splitlines()[0]
        s = json.loads(base64.b64decode(uri.removeprefix("vmess://")))
        self.assertEqual((s["id"], s["type"], s["path"], s["scy"], s["aid"]),
                         (state()["kcp_uuid"], "dtls", state()["seed"], "auto", "0"))

    def test_reality_import_link(self):
        uri = urlsplit(cfg.links(state()).splitlines()[1])
        q = parse_qs(uri.query)
        self.assertEqual(uri.username, state()["reality_uuid"])
        self.assertEqual(q["pbk"], [state()["public_key"]])
        self.assertEqual(q["flow"], ["xtls-rprx-vision"])

    def test_ipv6_link_brackets(self):
        s = dict(state(), address="2606:4700:4700::1111")
        cfg.validate(s)
        self.assertEqual(urlsplit(cfg.links(s).splitlines()[1]).hostname, s["address"])

    def test_client_exports_never_contain_private_key(self):
        for text in (cfg.links(state()), cfg.client_info(state())):
            self.assertNotIn(state()["private_key"], text)

    def test_bundle_permissions_and_no_overwrite(self):
        with tempfile.TemporaryDirectory() as folder:
            directory = Path(folder) / "bundle"
            cfg.write_bundle(directory, state())
            self.assertEqual(json.loads((directory / "state.json").read_text())["seed"], state()["seed"])
            if os.name != "nt":
                self.assertEqual((directory / "state.json").stat().st_mode & 0o777, 0o600)
            with self.assertRaises(FileExistsError):
                cfg.write_bundle(directory, state())


if __name__ == "__main__":
    unittest.main(verbosity=2)
