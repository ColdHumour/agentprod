#!/usr/bin/env python3
"""Offline tests for preserving existing public TCP listeners."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "xray_vps", Path(__file__).resolve().parents[1] / "xray_vps.py"
)
listeners = importlib.util.module_from_spec(spec)
spec.loader.exec_module(listeners)


class ListeningPortTests(unittest.TestCase):
    def test_public_and_wildcard_ports_are_kept(self):
        text = """LISTEN 0 511 0.0.0.0:80 0.0.0.0:*
LISTEN 0 511 [::]:443 [::]:*
LISTEN 0 128 203.0.113.9:8443 0.0.0.0:*
"""
        self.assertEqual(listeners.ports_from_ss(text), [80, 443, 8443])

    def test_loopback_ports_are_ignored(self):
        text = """LISTEN 0 128 127.0.0.1:8080 0.0.0.0:*
LISTEN 0 128 [::1]:9000 [::]:*
LISTEN 0 128 [::ffff:127.0.0.1]:9001 [::]:*
"""
        self.assertEqual(listeners.ports_from_ss(text), [])

    def test_duplicate_families_are_deduplicated(self):
        text = """LISTEN 0 511 0.0.0.0:80 0.0.0.0:*
LISTEN 0 511 [::]:80 [::]:*
"""
        self.assertEqual(listeners.ports_from_ss(text), [80])

    def test_public_docker_bindings_are_kept(self):
        metadata = [{"NetworkSettings": {"Ports": {
            "80/tcp": [{"HostIp": "0.0.0.0", "HostPort": "8080"},
                       {"HostIp": "::", "HostPort": "8080"}],
            "53/udp": [{"HostIp": "203.0.113.9", "HostPort": "5353"}],
        }}}]
        self.assertEqual(listeners.docker_ports(metadata, "tcp"), [8080])
        self.assertEqual(listeners.docker_ports(metadata, "udp"), [5353])

    def test_loopback_docker_bindings_are_ignored(self):
        metadata = [{"NetworkSettings": {"Ports": {
            "5432/tcp": [{"HostIp": "127.0.0.1", "HostPort": "5432"},
                         {"HostIp": "::1", "HostPort": "5432"}],
        }}}]
        self.assertEqual(listeners.docker_ports(metadata, "tcp"), [])
        self.assertEqual(listeners.docker_ports(metadata, "tcp", include_loopback=True), [5432])

    def test_docker_input_must_be_an_array(self):
        with self.assertRaises(ValueError):
            listeners.docker_ports({}, "tcp")


if __name__ == "__main__":
    unittest.main(verbosity=2)
