#!/usr/bin/env python3
"""Standard-library-only helpers for the Xray VPS deployment."""
import argparse
import base64
import ipaddress
import json
import os
from pathlib import Path
import re
import secrets
import socket
import subprocess
import sys
from urllib.parse import urlencode
import uuid

ASSET_NAMES = {
    "amd64": "Xray-linux-64.zip",
    "arm64": "Xray-linux-arm64-v8a.zip",
}
URL_PREFIX = "https://github.com/XTLS/Xray-core/releases/download/"
MIN_PORT = 20000
MAX_PORT = 59999
COMMON_PORTS = frozenset({
    25565, 27015, 27017, 28015, 30000, 32400,
    33060, 37777, 40000, 47808, 50000, 50001,
})

PRIVATE_NETS = [
    "0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8",
    "169.254.0.0/16", "172.16.0.0/12", "192.0.0.0/24", "192.0.2.0/24",
    "192.168.0.0/16", "198.18.0.0/15", "198.51.100.0/24", "203.0.113.0/24",
    "224.0.0.0/4", "240.0.0.0/4", "::/128", "::1/128",
    "64:ff9b::/96", "64:ff9b:1::/48", "100::/64", "2001:db8::/32",
    "2002::/16", "fc00::/7", "fe80::/10", "ff00::/8",
]


def validate(options, resolve=False):
    address = ipaddress.ip_address(options["address"])
    if not address.is_global or address.is_multicast:
        raise ValueError("Server address must be a public IPv4/IPv6 address")
    for field in ("kcp_port", "reality_port"):
        if not isinstance(options[field], int) or not 1024 <= options[field] <= 65535:
            if not (field == "reality_port" and options[field] == 443):
                raise ValueError("Ports must be 1024..65535 (REALITY may use 443)")
    domain = options["target"]
    if not re.fullmatch(r"(?=.{1,253}$)(?:[A-Za-z0-9](?:[A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z]{2,63}", domain):
        raise ValueError("REALITY target must be a plain DNS hostname, without port/path")
    if resolve:
        addresses = {row[4][0] for row in socket.getaddrinfo(domain, 443, type=socket.SOCK_STREAM)}
        if not addresses or any(not ipaddress.ip_address(a).is_global for a in addresses):
            raise ValueError("REALITY target must resolve exclusively to public addresses")
    return options


def select_asset(metadata, architecture):
    if metadata.get("draft") or metadata.get("prerelease"):
        raise ValueError("GitHub latest release is not a stable release")
    name = ASSET_NAMES.get(architecture)
    if not name:
        raise ValueError("Only amd64 and arm64 are supported")
    asset = next((item for item in metadata.get("assets", []) if item.get("name") == name), None)
    if not asset:
        raise ValueError("Required Xray asset not found in latest release")
    digest = asset.get("digest") or ""
    if not re.fullmatch(r"sha256:[0-9a-fA-F]{64}", digest):
        raise ValueError("Official GitHub asset SHA256 digest is missing or invalid")
    tag = metadata.get("tag_name") or ""
    url = asset.get("browser_download_url") or ""
    if not re.fullmatch(r"v[0-9][0-9A-Za-z._-]*", tag):
        raise ValueError("Invalid release tag")
    if not url.startswith(URL_PREFIX):
        raise ValueError("Invalid asset URL")
    return tag, name, url, digest


def allowed(port, excluded=()):
    return MIN_PORT <= port <= MAX_PORT and port not in COMMON_PORTS and port not in set(excluded)


def available(port, protocol="udp"):
    try:
        kind = socket.SOCK_DGRAM if protocol == "udp" else socket.SOCK_STREAM
        with socket.socket(socket.AF_INET, kind) as sock:
            sock.bind(("0.0.0.0", port))
        return True
    except OSError:
        return False


def choose(excluded=(), protocol="udp"):
    excluded = set(excluded)
    span = MAX_PORT - MIN_PORT + 1
    for _ in range(512):
        port = MIN_PORT + secrets.randbelow(span)
        if allowed(port, excluded) and available(port, protocol):
            return port
    raise RuntimeError(f"Could not find an available random {protocol.upper()} port")


def is_loopback_host(host):
    host = host.strip("[]")
    if host in {"*", "0.0.0.0", "::"}:
        return False
    try:
        address = ipaddress.ip_address(host.split("%", 1)[0])
    except ValueError:
        return False
    if address.is_loopback:
        return True
    return bool(getattr(address, "ipv4_mapped", None) and address.ipv4_mapped.is_loopback)


def ports_from_ss(text):
    ports = set()
    for line in text.splitlines():
        fields = line.split()
        if len(fields) < 5:
            continue
        match = re.fullmatch(r"(.+):(\d+)", fields[3])
        if not match:
            continue
        host, port_text = match.groups()
        port = int(port_text)
        if 1 <= port <= 65535 and not is_loopback_host(host):
            ports.add(port)
    return sorted(ports)


def docker_ports(metadata, protocol, include_loopback=False):
    """Return host ports published by `docker inspect`."""
    ports = set()
    if not isinstance(metadata, list):
        raise ValueError("Docker inspect output must be a JSON array")
    for container in metadata:
        mappings = container.get("NetworkSettings", {}).get("Ports", {})
        if not isinstance(mappings, dict):
            continue
        for container_port, bindings in mappings.items():
            if not container_port.endswith("/" + protocol) or not isinstance(bindings, list):
                continue
            for binding in bindings:
                host = str(binding.get("HostIp", ""))
                port_text = str(binding.get("HostPort", ""))
                if not include_loopback and host and is_loopback_host(host):
                    continue
                if port_text.isdigit() and 1 <= int(port_text) <= 65535:
                    ports.add(int(port_text))
    return sorted(ports)


def credentials(binary):
    result = subprocess.run([str(binary), "x25519"], check=True, capture_output=True, text=True)
    fields = dict(line.split(":", 1) for line in result.stdout.splitlines() if ":" in line)
    private = fields.get("PrivateKey", fields.get("Private key", "")).strip()
    public = next((v.strip() for k, v in fields.items()
                   if "PublicKey" in k or k in ("Password", "Public key")), "")
    for key in (private, public):
        if not re.fullmatch(r"[A-Za-z0-9_-]{43}", key) or len(base64.urlsafe_b64decode(key + "=")) != 32:
            raise ValueError("Unexpected xray x25519 output; no configuration was installed")
    return dict(kcp_uuid=str(uuid.uuid4()), reality_uuid=str(uuid.uuid4()),
                seed=secrets.token_hex(16), private_key=private,
                public_key=public, short_id=secrets.token_hex(8))


def kcp_stream(state, client=False):
    # This kit uses the Xray FinalMask types below and validates the generated
    # configuration with the downloaded core before installing anything.
    return {
        "network": "kcp",
        "kcpSettings": {"mtu": 1350, "tti": 50,
                        "uplinkCapacity": 12 if client else 100,
                        "downlinkCapacity": 100,
                        "congestion": True, "readBufferSize": 4, "writeBufferSize": 4},
        "finalmask": {"udp": [
            {"type": "header-dtls"},
            {"type": "mkcp-aes128gcm", "settings": {"password": state["seed"]}},
        ]},
    }


def server_config(state):
    limit = {"afterBytes": 0, "bytesPerSec": 8192, "burstBytesPerSec": 4096}
    return {
        "log": {"loglevel": "warning", "access": "none"},
        "inbounds": [
            {"tag": "kcp-in", "listen": "0.0.0.0" if ":" not in state["address"] else "::",
             "port": state["kcp_port"], "protocol": "vmess",
             "settings": {"clients": [{"id": state["kcp_uuid"], "alterId": 0}],
                          "disableInsecureEncryption": True},
             "streamSettings": kcp_stream(state)},
            {"tag": "reality-in", "listen": "0.0.0.0" if ":" not in state["address"] else "::",
             "port": state["reality_port"], "protocol": "vless",
             "settings": {"clients": [{"id": state["reality_uuid"], "flow": "xtls-rprx-vision"}],
                          "decryption": "none"},
             "streamSettings": {
                 "network": "raw", "security": "reality",
                 "realitySettings": {"show": False, "target": state["target"] + ":443",
                                     "xver": 0, "serverNames": [state["target"]],
                                     "privateKey": state["private_key"],
                                     "shortIds": [state["short_id"]],
                                     "limitFallbackUpload": limit.copy(),
                                     "limitFallbackDownload": limit.copy()},
             }},
        ],
        "outbounds": [
            {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "UseIP"}},
            {"tag": "block", "protocol": "blackhole", "settings": {}},
        ],
        "routing": {"domainStrategy": "IPOnDemand", "rules": [
            {"type": "field", "ip": PRIVATE_NETS, "outboundTag": "block"},
            {"type": "field", "port": "25,465,587", "network": "tcp", "outboundTag": "block"},
        ]},
    }


def links(state):
    vmess = {"v": "2", "ps": "VPS-KCP-DTLS", "add": state["address"],
             "port": str(state["kcp_port"]), "id": state["kcp_uuid"], "aid": "0",
             "scy": "auto", "net": "kcp", "type": "dtls", "host": "",
             "path": state["seed"], "tls": ""}
    first = "vmess://" + base64.b64encode(json.dumps(vmess, separators=(",", ":")).encode()).decode()
    address = "[" + state["address"] + "]" if ":" in state["address"] else state["address"]
    query = urlencode({"encryption": "none", "flow": "xtls-rprx-vision", "security": "reality",
                       "sni": state["target"], "fp": "chrome", "pbk": state["public_key"],
                       "sid": state["short_id"], "type": "tcp"})
    second = f"vless://{state['reality_uuid']}@{address}:{state['reality_port']}?{query}#VPS-REALITY"
    return first + "\n" + second + "\n"


def client_info(s):
    return f"""Xray VPS client settings / v2rayN 客户端参数（包含访问凭据，请勿公开）
Server / 地址: {s['address']}
Core / 服务端核心: {s['version']}

[1] VMess + KCP + DTLS
Protocol / 协议: VMess（不是原参考配置的 VLESS）
Port / 端口: {s['kcp_port']} / UDP
UUID: {s['kcp_uuid']}
AlterId: 0
Encryption / 加密: auto（禁止 none/zero）
Transport / 传输: kcp
Header / 伪装: dtls
Seed / KCP seed: {s['seed']}
TLS / 传输安全: 留空/none
Flow / 流控: 留空
Mux / 多路复用: 关闭
建议客户端 KCP: mtu=1350, tti=50, uplinkCapacity=12, downlinkCapacity=100
服务器 uplinkCapacity=100 MB/s 是上限，不是保证网速。

[2] VLESS + TCP/RAW + REALITY + Vision
Protocol / 协议: VLESS
Port / 端口: {s['reality_port']} / TCP
UUID: {s['reality_uuid']}
Encryption / 加密: none（此入口由 REALITY 提供传输加密）
Transport / 传输: tcp/raw
Flow / 流控: xtls-rprx-vision
TLS / 传输安全: reality
SNI / serverName: {s['target']}
Fingerprint / 指纹: chrome
PublicKey / Password / 公钥: {s['public_key']}
ShortId: {s['short_id']}
SpiderX: 留空
Mux / 多路复用: 关闭
服务器 privateKey 不应复制到客户端。

Import / 从剪贴板导入两条链接：
{links(s)}
两入口依赖不同的 TCP/UDP 端口；云厂商安全组也必须放行。
KCP 使用新版 v2rayN 时，请保留之前的数组顺序修复。
"""


def private_write(path, text):
    # Output directories must be fresh and private. Refuse to overwrite symlinks/files.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(text)


def write_bundle(directory, state):
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name, value in (("state.json", state), ("config.json", server_config(state))):
        private_write(directory / name, json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    private_write(directory / "client-info.txt", client_info(state))
    private_write(directory / "links.txt", links(state))


def configure_main(argv):
    parser = argparse.ArgumentParser()
    parser.add_argument("--xray", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--state", type=Path, help="Retain connection settings but rotate every credential")
    parser.add_argument("--version", help="Installed Xray release tag; required for a new deployment")
    parser.add_argument("--address")
    parser.add_argument("--target", default="www.cloudflare.com")
    parser.add_argument("--kcp-port", type=int,
                        help="KCP UDP port; required for a new deployment")
    parser.add_argument("--reality-port", type=int, default=443)
    args = parser.parse_args(argv)
    if args.state:
        state = json.loads(args.state.read_text(encoding="utf-8"))
    else:
        if not args.version or args.kcp_port is None:
            parser.error("--version and --kcp-port are required for a new deployment")
        state = dict(address=args.address, target=args.target, kcp_port=args.kcp_port,
                     reality_port=args.reality_port, version=args.version)
    validate(state, resolve=True)
    state.update(credentials(args.xray))
    write_bundle(args.output, state)


def release_main(argv):
    parser = argparse.ArgumentParser(prog="xray_vps.py release")
    parser.add_argument("metadata", type=Path)
    parser.add_argument("architecture", choices=sorted(ASSET_NAMES))
    args = parser.parse_args(argv)
    metadata = json.loads(args.metadata.read_text(encoding="utf-8"))
    print(*select_asset(metadata, args.architecture))


def port_main(argv):
    parser = argparse.ArgumentParser(prog="xray_vps.py port")
    parser.add_argument("--exclude", action="append", type=int, default=[])
    parser.add_argument("--protocol", choices=("tcp", "udp"), default="udp")
    parser.add_argument("--check", type=int)
    args = parser.parse_args(argv)
    if args.check is not None:
        if not allowed(args.check, args.exclude):
            parser.error(
                f"Port must be {MIN_PORT}..{MAX_PORT}, must not be a common port, "
                "and must not conflict with an excluded port"
            )
        return
    print(choose(args.exclude, args.protocol))


def listening_main(argv):
    parser = argparse.ArgumentParser(prog="xray_vps.py listening")
    parser.parse_args(argv)
    for port in ports_from_ss(sys.stdin.read()):
        print(port)


def docker_ports_main(argv):
    parser = argparse.ArgumentParser(prog="xray_vps.py docker-ports")
    parser.add_argument("--protocol", choices=("tcp", "udp"), required=True)
    parser.add_argument("--include-loopback", action="store_true")
    args = parser.parse_args(argv)
    metadata = json.load(sys.stdin)
    for port in docker_ports(metadata, args.protocol, args.include_loopback):
        print(port)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("command", choices=("configure", "release", "port", "listening", "docker-ports"))
    args, rest = parser.parse_known_args()
    {"configure": configure_main, "release": release_main,
     "port": port_main, "listening": listening_main,
     "docker-ports": docker_ports_main}[args.command](rest)


if __name__ == "__main__":
    main()
