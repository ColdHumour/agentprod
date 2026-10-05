#!/usr/bin/env python3
"""Offline tests for KCP UDP port selection."""
import importlib.util
from pathlib import Path
import socket
import unittest
from unittest import mock

spec = importlib.util.spec_from_file_location(
    "xray_vps", Path(__file__).resolve().parents[1] / "xray_vps.py"
)
ports = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ports)


class PortSelectionTests(unittest.TestCase):
    def test_range_and_common_ports(self):
        self.assertTrue(ports.allowed(45678))
        for port in (1024, 19999, 25565, 27015, 33060, 60000, 65535):
            with self.subTest(port=port):
                self.assertFalse(ports.allowed(port))

    def test_excluded_port(self):
        self.assertFalse(ports.allowed(45678, {45678}))

    def test_choose_skips_excluded_and_busy(self):
        values = iter((123, 456, 789))
        with mock.patch.object(ports.secrets, "randbelow", side_effect=lambda _: next(values)), \
             mock.patch.object(ports, "available", side_effect=(False, True)) as available:
            expected = ports.MIN_PORT + 789
            self.assertEqual(ports.choose({ports.MIN_PORT + 123}), expected)
            self.assertEqual(available.call_args_list[-1].args[1], "udp")

    def test_chosen_port_can_be_bound(self):
        port = ports.choose()
        self.assertTrue(ports.allowed(port))
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            sock.bind(("0.0.0.0", port))

    def test_tcp_selection_uses_stream_socket_check(self):
        with mock.patch.object(ports.secrets, "randbelow", return_value=2345), \
             mock.patch.object(ports, "available", return_value=True) as available:
            selected = ports.choose(protocol="tcp")
            self.assertEqual(selected, ports.MIN_PORT + 2345)
            available.assert_called_once_with(selected, "tcp")


if __name__ == "__main__":
    unittest.main(verbosity=2)
