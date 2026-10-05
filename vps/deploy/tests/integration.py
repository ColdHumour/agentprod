#!/usr/bin/env python3
"""Optional real-core loopback test. No system proxy/firewall/service changes.

Uses an explicitly supplied Xray binary and a public REALITY target for its handshake.
All listeners are loopback-only; synthetic credentials are created per run.
"""
import argparse
import copy
import contextlib
import importlib.util
import json
from pathlib import Path
import socket
import struct
import subprocess
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

spec = importlib.util.spec_from_file_location("xray_vps", Path(__file__).resolve().parents[1] / "xray_vps.py")
cfg = importlib.util.module_from_spec(spec)
spec.loader.exec_module(cfg)


def free_port(udp=False):
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM if udp else socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def receive(sock, length):
    data = b""
    while len(data) < length:
        part = sock.recv(length - len(data))
        if not part:
            raise ConnectionError("Unexpected EOF")
        data += part
    return data


def fetch(socks_port, target_port):
    with socket.create_connection(("127.0.0.1", socks_port), timeout=8) as sock:
        sock.settimeout(8)
        sock.sendall(b"\x05\x01\x00")
        assert receive(sock, 2) == b"\x05\x00"
        sock.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + struct.pack("!H", target_port))
        reply = receive(sock, 4)
        if reply[1] != 0:
            raise ConnectionError("SOCKS rejected request")
        if reply[3] == 1:
            receive(sock, 6)
        elif reply[3] == 4:
            receive(sock, 18)
        else:
            receive(sock, receive(sock, 1)[0] + 2)
        sock.sendall(b"GET / HTTP/1.0\r\nHost: localhost\r\n\r\n")
        result = b""
        while True:
            part = sock.recv(65536)
            if not part:
                return result
            result += part


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        payload = b"xray-vps-integration-ok" * 1024
        self.send_response(200)
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--xray", required=True, type=Path)
    parser.add_argument("--target", default="www.cloudflare.com")
    args = parser.parse_args()
    binary = str(args.xray.resolve())
    processes, handles = [], []
    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    threading.Thread(target=server.serve_forever, daemon=True).start()
    def stop_processes():
        for process in processes:
            if process.poll() is None:
                process.terminate()
                process.wait(timeout=10)
        for handle in handles:
            handle.close()
    try:
        with contextlib.ExitStack() as stack:
            tmp = stack.enter_context(tempfile.TemporaryDirectory(prefix="xray-vps-test-"))
            stack.callback(stop_processes)
            folder = Path(tmp)
            s = dict(address="8.8.8.8", target=args.target, kcp_port=free_port(True),
                     reality_port=free_port(), version="v-test")
            s.update(cfg.credentials(binary))
            production = cfg.server_config(s)
            path = folder / "production.json"
            path.write_text(json.dumps(production), encoding="utf-8")
            subprocess.run([binary, "run", "-test", "-config", str(path)], check=True, capture_output=True)
            print("PASS: production configuration accepted by real core", flush=True)
            testserver = copy.deepcopy(production)
            for inbound in testserver["inbounds"]:
                inbound["listen"] = "127.0.0.1"
            # Fixture must reach a local HTTP server. Production retains its private-IP block.
            testserver["routing"]["rules"] = []

            def start(name, config, port, udp=False):
                path = folder / (name + ".json")
                path.write_text(json.dumps(config), encoding="utf-8")
                log = open(folder / (name + ".log"), "wb")
                handles.append(log)
                process = subprocess.Popen([binary, "run", "-config", str(path)], stdout=log, stderr=log)
                processes.append(process)
                for _ in range(60):
                    if process.poll() is not None:
                        raise RuntimeError(name + " exited unexpectedly")
                    try:
                        with socket.create_connection(("127.0.0.1", port), timeout=0.2):
                            break
                    except OSError:
                        time.sleep(0.1)
                else:
                    raise RuntimeError(name + " did not start")
                return process

            start("server", testserver, s["reality_port"])
            for mode in ("kcp", "reality"):
                for authorized in (True, False):
                    socks_port = free_port()
                    user = {"id": s["kcp_uuid" if mode == "kcp" else "reality_uuid"]}
                    if not authorized:
                        user["id"] = "ffffffff-ffff-4fff-bfff-ffffffffffff"
                    if mode == "kcp":
                        user.update(security="auto", alterId=0)
                        stream = cfg.kcp_stream(s, client=True)
                    else:
                        user.update(encryption="none", flow="xtls-rprx-vision")
                        stream = {"network": "raw", "security": "reality", "realitySettings": {
                            "serverName": s["target"], "fingerprint": "chrome",
                            "publicKey": s["public_key"], "shortId": s["short_id"]}}
                    client = {"log": {"loglevel": "warning"},
                              "inbounds": [{"listen": "127.0.0.1", "port": socks_port, "protocol": "socks", "settings": {"auth": "noauth"}}],
                              "outbounds": [{"protocol": "vmess" if mode == "kcp" else "vless",
                                             "settings": {"vnext": [{"address": "127.0.0.1", "port": s[mode + "_port"], "users": [user]}]},
                                             "streamSettings": stream}]}
                    proc = start(f"client-{mode}-{authorized}", client, socks_port)
                    try:
                        try:
                            result = fetch(socks_port, server.server_port)
                            succeeded = b"xray-vps-integration-ok" * 1024 in result
                        except (OSError, ConnectionError):
                            succeeded = False
                        assert succeeded == authorized, f"{mode}: authorized={authorized}, result={succeeded}"
                        print(f"PASS: {mode} {'authenticated transfer' if authorized else 'wrong UUID denied'}", flush=True)
                    finally:
                        proc.terminate()
                        proc.wait(timeout=10)
    finally:
        stop_processes()
        server.shutdown()
        server.server_close()


if __name__ == "__main__":
    main()
