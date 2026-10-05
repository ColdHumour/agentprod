#!/usr/bin/env bash
# Xray VPS installer and post-install manager for Ubuntu 22.04.
set -Eeuo pipefail
export LC_ALL=C
umask 077

SELF=$(readlink -f -- "${BASH_SOURCE[0]}")
HERE=$(dirname -- "$SELF")
BASE=/root/xray-vps
LIB=/usr/local/lib/xray-vps
CONF=/etc/xray-vps/config.json
HELPER_SOURCE="$HERE/xray_vps.py"
die() { echo "ERROR: $*" >&2; exit 1; }
ok() { echo "[ OK ] $*"; }
warn() { echo "[WARN] $*"; }
require_root() { [[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'; }
require_ssh() { [[ -n "${SSH_CONNECTION:-}" ]] || die 'Preserve SSH_CONNECTION when using sudo; see README.md.'; }

xray_account_valid() {
    local entry account home shell primary_group
    entry=$(getent passwd xray-vps) || return 1
    IFS=: read -r account _ _ _ _ home shell <<< "$entry"
    primary_group=$(id -gn xray-vps 2>/dev/null) || return 1
    [[ "$account" == xray-vps && "$home" == /nonexistent && "$primary_group" == xray-vps \
        && "$shell" =~ ^(/usr)?/sbin/nologin$ ]]
}

snapshot_docker_ports() {
    local helper=$1 prefix=$2 protocol container_output
    local -a container_ids
    command -v docker >/dev/null || die 'Docker service is active but the docker command is unavailable.'
    docker info >/dev/null 2>&1 || die 'Docker is active but its API is unavailable to root.'
    container_output=$(docker ps -q) || die 'Could not enumerate running Docker containers.'
    container_ids=()
    [[ -z "$container_output" ]] || mapfile -t container_ids <<< "$container_output"
    for protocol in tcp udp; do
        : > "${prefix}-all-${protocol}.txt"
        : > "${prefix}-public-${protocol}.txt"
        if ((${#container_ids[@]})); then
            docker inspect "${container_ids[@]}" | python3 "$helper" docker-ports --protocol "$protocol" --include-loopback > "${prefix}-all-${protocol}.txt"
            docker inspect "${container_ids[@]}" | python3 "$helper" docker-ports --protocol "$protocol" > "${prefix}-public-${protocol}.txt"
        fi
    done
}

preflight_main() {
    local KCP_PORT= REALITY_PORT= EXTRA_SSH_PORT= NGINX_ACTIVE=no DOCKER_ACTIVE=no
    local number current_ssh_port arch available_kb REALITY_PLAN REALITY_RANDOM reality_text kcp_text path service
    local DOCKER_REALITY_CONFLICT=no preflight_docker_output
    local -a preflight_docker_ids
    local -a existing_paths
    while (($#)); do
        case "$1" in
            --kcp-port|--reality-port|--ssh-port)
                (($# >= 2)) || die "Missing value for $1"
                case "$1" in
                    --kcp-port) KCP_PORT=$2 ;;
                    --reality-port) REALITY_PORT=$2 ;;
                    --ssh-port) EXTRA_SSH_PORT=$2 ;;
                esac
                shift 2 ;;
            -h|--help)
                echo 'Usage: bash deploy.sh preflight [--kcp-port PORT] [--reality-port PORT] [--ssh-port PORT]'
                return 0 ;;
            *) die "Unknown preflight option: $1" ;;
        esac
    done
    require_root
    require_ssh
    [[ -d /run/systemd/system ]] || die 'A normal systemd VPS is required; containers are unsupported.'
    # shellcheck disable=SC1091
    source /etc/os-release
    [[ "$ID" == ubuntu && "$VERSION_ID" == 22.04 ]] || die 'Ubuntu 22.04 is required.'
    ok 'Ubuntu 22.04, elevated SSH session and systemd detected.'

    if systemctl is-active --quiet nginx 2>/dev/null || pgrep -x nginx >/dev/null 2>&1; then
        NGINX_ACTIVE=yes
        ok 'Active Nginx detected; its current public TCP listener ports will be preserved.'
    fi
    if systemctl is-active --quiet docker 2>/dev/null; then
        DOCKER_ACTIVE=yes
        command -v docker >/dev/null || die 'Docker service is active but the docker command is unavailable.'
        docker info >/dev/null 2>&1 || die 'Docker is active but its API is unavailable to root.'
        ok 'Active Docker detected; running containers and published host ports will be preserved.'
        warn 'Docker-published ports can bypass UFW; keep container port publishing restricted to what you intend to expose.'
    fi
    arch=$(dpkg --print-architecture)
    [[ "$arch" == amd64 || "$arch" == arm64 ]] || die "Unsupported architecture: $arch"
    ok "Supported architecture: $arch"

    for number in ${REALITY_PORT:+"$REALITY_PORT"} ${EXTRA_SSH_PORT:+"$EXTRA_SSH_PORT"}; do
        [[ "$number" =~ ^[1-9][0-9]{0,4}$ ]] && (( number <= 65535 )) || die "Invalid port: $number"
    done
    [[ -z "$REALITY_PORT" || "$REALITY_PORT" == 443 || "$REALITY_PORT" -ge 1024 ]] || die 'REALITY port must be 443 or 1024..65535.'
    if [[ -n "$KCP_PORT" ]]; then
        [[ "$KCP_PORT" =~ ^[0-9]+$ ]] || die "Invalid KCP port: $KCP_PORT"
        (( KCP_PORT >= 20000 && KCP_PORT <= 59999 )) || die 'KCP port must be in 20000..59999.'
        case ",$KCP_PORT," in
            *,25565,*|*,27015,*|*,27017,*|*,28015,*|*,30000,*|*,32400,*|*,33060,*|*,37777,*|*,40000,*|*,47808,*|*,50000,*|*,50001,*)
                die 'That KCP port is commonly used; choose another.' ;;
        esac
    fi
    read -r _ _ _ current_ssh_port <<< "$SSH_CONNECTION"
    [[ "$current_ssh_port" =~ ^[1-9][0-9]{0,4}$ ]] || die 'Could not determine the current SSH port.'
    [[ -z "$REALITY_PORT" || "$REALITY_PORT" != "$current_ssh_port" ]] || die 'REALITY port conflicts with the current SSH port.'
    [[ -z "$REALITY_PORT" || -z "$EXTRA_SSH_PORT" || "$REALITY_PORT" != "$EXTRA_SSH_PORT" ]] || die 'REALITY port conflicts with the extra SSH port.'
    ok "Ports are valid; current SSH port is $current_ssh_port."

    existing_paths=()
    for path in "$BASE" "$LIB" /etc/xray-vps /etc/systemd/system/xray.service /usr/local/sbin/xray-vps; do
        [[ ! -e "$path" && ! -L "$path" ]] || existing_paths+=("$path")
    done
    if ((${#existing_paths[@]})); then
        echo '[FAIL] Existing Xray deployment paths:' >&2
        printf '  %s\n' "${existing_paths[@]}" >&2
        die 'To replace this managed deployment, first run: sudo bash /root/xray-vps-kit/deploy.sh replace-existing --confirm'
    fi
    if command -v xray >/dev/null || command -v v2ray >/dev/null; then
        die 'An unmanaged Xray/V2Ray command was detected; this installer will not replace it.'
    fi
    if getent passwd xray-vps >/dev/null; then
        xray_account_valid || die 'Existing xray-vps account does not match the expected restricted system account.'
        warn 'Existing restricted xray-vps system account will be reused.'
    fi
    for service in xray v2ray; do
        systemctl cat "$service.service" >/dev/null 2>&1 && die "Existing $service service detected; this installer does not migrate it."
    done
    ok 'No conflicting proxy deployment was detected.'

    REALITY_PLAN=${REALITY_PORT:-443}
    REALITY_RANDOM=no
    if [[ "$DOCKER_ACTIVE" == yes ]]; then
        preflight_docker_output=$(docker ps -q) || die 'Could not enumerate running Docker containers.'
        preflight_docker_ids=()
        [[ -z "$preflight_docker_output" ]] || mapfile -t preflight_docker_ids <<< "$preflight_docker_output"
        if ((${#preflight_docker_ids[@]})); then
            if docker inspect "${preflight_docker_ids[@]}" \
                | python3 "$HELPER_SOURCE" docker-ports --protocol tcp --include-loopback \
                | grep -qx "$REALITY_PLAN"; then
                DOCKER_REALITY_CONFLICT=yes
            fi
            if [[ -n "$KCP_PORT" ]] && docker inspect "${preflight_docker_ids[@]}" \
                | python3 "$HELPER_SOURCE" docker-ports --protocol udp --include-loopback \
                | grep -qx "$KCP_PORT"; then
                die "Requested KCP UDP port $KCP_PORT is published by Docker."
            fi
        fi
    fi
    if command -v ss >/dev/null; then
        if ss -H -lnt "sport = :$REALITY_PLAN" | grep -q . || [[ "$DOCKER_REALITY_CONFLICT" == yes ]]; then
            if [[ -z "$REALITY_PORT" ]]; then
                REALITY_RANDOM=yes
                warn 'TCP 443 is occupied; install will preserve it and select a random high TCP port for REALITY.'
            else
                die "Requested REALITY TCP port $REALITY_PORT is already occupied."
            fi
        fi
        if [[ -n "$KCP_PORT" ]]; then
            ss -H -lnu "sport = :$KCP_PORT" | grep -q . && die "UDP $KCP_PORT is already occupied."
            ok "Requested UDP $KCP_PORT is free."
        else
            ok 'Install will choose and recheck a random KCP UDP port.'
        fi
    else
        warn 'ss is not installed yet; install will install iproute2 and check ports again.'
    fi

    if command -v ufw >/dev/null; then
        if ufw status | grep -qx 'Status: active'; then
            ok 'UFW is active; defaults and existing rules will remain unchanged.'
        elif ufw show added | grep -q '^ufw '; then
            die 'UFW is inactive but has saved rules; refusing to activate an ambiguous ruleset.'
        else
            ok 'UFW is inactive and empty; current public TCP listeners will be preserved when it is enabled.'
        fi
    else
        ok 'UFW is not installed yet; install will configure it.'
    fi
    available_kb=$(df -Pk / | awk 'NR==2 {print $4}')
    (( available_kb >= 1048576 )) || die 'At least 1 GiB free space is required.'
    ok 'At least 1 GiB free disk space is available.'
    getent hosts api.github.com >/dev/null || die 'DNS resolution for api.github.com failed.'
    getent hosts github.com >/dev/null || die 'DNS resolution for github.com failed.'
    if command -v curl >/dev/null; then
        curl --fail --silent --show-error --head --proto '=https' --tlsv1.2 --connect-timeout 10 --max-time 20 \
            https://api.github.com/repos/XTLS/Xray-core/releases/latest >/dev/null \
            || die 'HTTPS access to the official GitHub release API failed.'
    fi
    ok 'GitHub connectivity checks passed.'
    if [[ -n "$REALITY_PORT" ]]; then reality_text="TCP $REALITY_PORT"
    elif [[ "$REALITY_RANDOM" == yes ]]; then reality_text='a random high TCP port because 443 is occupied'
    else reality_text='TCP 443'; fi
    if [[ -n "$KCP_PORT" ]]; then kcp_text="UDP $KCP_PORT"; else kcp_text='a random high UDP port'; fi
    echo
    echo 'PREFLIGHT PASSED'
    echo "Planned proxy ports: REALITY $reality_text; KCP $kcp_text."
}

install_main() {
    local KCP_PORT= REALITY_PORT= TARGET=www.cloudflare.com ADDRESS= EXTRA_SSH_PORT=
    local stage remote_ip remote_port local_ip ssh_port NGINX_ACTIVE=no DOCKER_ACTIVE=no release asset download_url digest sha256 ssh_csv port attempt protocol
    local -a preflight_args reality_args port_args
    while (($#)); do
        case "$1" in
            --server-address|--reality-target|--kcp-port|--reality-port|--ssh-port)
                (($# >= 2)) || die "Missing value for $1"
                case "$1" in
                    --server-address) ADDRESS=$2 ;;
                    --reality-target) TARGET=$2 ;;
                    --kcp-port) KCP_PORT=$2 ;;
                    --reality-port) REALITY_PORT=$2 ;;
                    --ssh-port) EXTRA_SSH_PORT=$2 ;;
                esac
                shift 2 ;;
            -h|--help)
                echo 'Usage: bash deploy.sh install [--server-address IP] [--reality-target HOST] [--kcp-port PORT] [--reality-port PORT] [--ssh-port PORT]'
                return 0 ;;
            *) die "Unknown install option: $1" ;;
        esac
    done
    require_root
    require_ssh
    [[ -f "$HELPER_SOURCE" ]] || die 'xray_vps.py must be beside deploy.sh.'
    [[ "$TARGET" =~ ^[a-zA-Z0-9.-]+$ ]] || die 'Target must be a DNS hostname, without URL or port.'
    exec 8>/run/lock/xray-vps-setup.lock
    flock -n 8 || die 'Another setup is running.'
    preflight_args=()
    [[ -z "$REALITY_PORT" ]] || preflight_args+=(--reality-port "$REALITY_PORT")
    [[ -z "$KCP_PORT" ]] || preflight_args+=(--kcp-port "$KCP_PORT")
    [[ -z "$EXTRA_SSH_PORT" ]] || preflight_args+=(--ssh-port "$EXTRA_SSH_PORT")
    preflight_main "${preflight_args[@]}"

    echo 'Installing Ubuntu packages: curl, unzip, python3, openssl, ufw, fail2ban and iproute2.'
    export DEBIAN_FRONTEND=noninteractive
    apt-get update
    apt-get install -y --no-install-recommends ca-certificates curl unzip python3 openssl ufw fail2ban iproute2
    download() { curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 180 --retry 3 "$@"; }
    stage=$(mktemp -d /root/xray-vps-stage.XXXXXXXX)
    trap 'rc=$?; echo "Setup stopped (exit $rc). Private staging: $stage" >&2; exit "$rc"' ERR
    read -r remote_ip remote_port local_ip ssh_port <<< "$SSH_CONNECTION"
    [[ "$ssh_port" =~ ^[1-9][0-9]{0,4}$ ]] && (( ssh_port <= 65535 )) || die 'Invalid SSH_CONNECTION port.'
    {
        printf '%s\n' "$ssh_port"
        /usr/sbin/sshd -T | awk '$1 == "port" {print $2}'
        [[ -z "$EXTRA_SSH_PORT" ]] || printf '%s\n' "$EXTRA_SSH_PORT"
    } | sort -nu > "$stage/ssh-ports.txt"
    ss -H -lnt | python3 "$HELPER_SOURCE" listening > "$stage/listener-tcp-ports.txt"
    for protocol in tcp udp; do
        : > "$stage/docker-all-${protocol}.txt"
        : > "$stage/docker-public-${protocol}.txt"
    done
    if systemctl is-active --quiet docker 2>/dev/null; then
        DOCKER_ACTIVE=yes
        snapshot_docker_ports "$HELPER_SOURCE" "$stage/docker-before"
        for protocol in tcp udp; do
            mv "$stage/docker-before-all-${protocol}.txt" "$stage/docker-all-${protocol}.txt"
            mv "$stage/docker-before-public-${protocol}.txt" "$stage/docker-public-${protocol}.txt"
        done
        echo "Docker detected. Published TCP ports: $(paste -sd, "$stage/docker-all-tcp.txt" || true)"
        echo "Docker detected. Published UDP ports: $(paste -sd, "$stage/docker-all-udp.txt" || true)"
    fi
    printf '%s\n' "$DOCKER_ACTIVE" > "$stage/docker-active.txt"
    cat "$stage/listener-tcp-ports.txt" "$stage/docker-public-tcp.txt" | sort -nu > "$stage/preserve-tcp-ports.txt"
    if systemctl is-active --quiet nginx 2>/dev/null || pgrep -x nginx >/dev/null 2>&1; then
        NGINX_ACTIVE=yes
        [[ -s "$stage/preserve-tcp-ports.txt" ]] || die 'Nginx is active but no public TCP listener could be verified.'
        echo "Nginx detected. Preserving current public TCP ports: $(paste -sd, "$stage/preserve-tcp-ports.txt")"
    fi
    if ufw status | grep -qx 'Status: active'; then
        printf '%s\n' active > "$stage/ufw-original-state.txt"
        echo 'Existing active UFW detected; its defaults and existing rules will be preserved.'
    else
        ufw show added | grep -q '^ufw ' && die 'UFW is inactive but has saved rules.'
        printf '%s\n' inactive > "$stage/ufw-original-state.txt"
    fi
    reality_args=(--protocol tcp)
    while read -r port; do reality_args+=(--exclude "$port"); done < "$stage/ssh-ports.txt"
    while read -r port; do reality_args+=(--exclude "$port"); done < "$stage/listener-tcp-ports.txt"
    while read -r port; do reality_args+=(--exclude "$port"); done < "$stage/docker-all-tcp.txt"
    if [[ -z "$REALITY_PORT" ]]; then
        if ss -H -lnt 'sport = :443' | grep -q . || grep -qx 443 "$stage/docker-all-tcp.txt"; then
            REALITY_PORT=$(python3 "$HELPER_SOURCE" port "${reality_args[@]}")
            echo "TCP 443 is occupied; random REALITY TCP port selected: $REALITY_PORT"
        else
            REALITY_PORT=443
            echo 'TCP 443 is free; REALITY will use TCP 443.'
        fi
    else
        ss -H -lnt "sport = :$REALITY_PORT" | grep -q . && die 'Requested REALITY TCP port is occupied.'
        grep -qx "$REALITY_PORT" "$stage/docker-all-tcp.txt" && die 'Requested REALITY TCP port is published by Docker.'
    fi
    grep -qx "$REALITY_PORT" "$stage/ssh-ports.txt" && die 'REALITY must not use an SSH TCP port.'
    port_args=(--exclude "$REALITY_PORT")
    while read -r port; do port_args+=(--exclude "$port"); done < "$stage/ssh-ports.txt"
    while read -r port; do port_args+=(--exclude "$port"); done < "$stage/listener-tcp-ports.txt"
    while read -r port; do port_args+=(--exclude "$port"); done < "$stage/docker-all-tcp.txt"
    while read -r port; do port_args+=(--exclude "$port"); done < "$stage/docker-all-udp.txt"
    if [[ -z "$KCP_PORT" ]]; then
        KCP_PORT=$(python3 "$HELPER_SOURCE" port "${port_args[@]}")
        echo "Random KCP UDP port selected: $KCP_PORT"
    else
        python3 "$HELPER_SOURCE" port "${port_args[@]}" --check "$KCP_PORT"
    fi
    ss -H -lnu "sport = :$KCP_PORT" | grep -q . && die 'KCP UDP port is occupied.'
    if [[ -z "$ADDRESS" ]]; then
        ADDRESS=$(download -4 --max-time 20 https://api.ipify.org) || ADDRESS=
        [[ -n "$ADDRESS" ]] || ADDRESS=$(download -4 --max-time 20 https://ipv4.icanhazip.com)
    fi
    python3 - "$HELPER_SOURCE" "$ADDRESS" "$TARGET" "$KCP_PORT" "$REALITY_PORT" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("xray_vps", sys.argv[1])
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
module.validate(dict(address=sys.argv[2], target=sys.argv[3], kcp_port=int(sys.argv[4]), reality_port=int(sys.argv[5])), resolve=True)
PY
    echo "Public address detected: $ADDRESS"
    echo "Validating REALITY target: $TARGET"
    timeout 25 openssl s_client -connect "$TARGET:443" -servername "$TARGET" -tls1_3 -alpn h2 \
        -verify_hostname "$TARGET" -verify_return_error -CApath /etc/ssl/certs </dev/null > "$stage/target-check.txt" 2>&1 \
        || die "Target TLS verification failed; inspect $stage/target-check.txt."
    grep -q 'ALPN protocol: h2' "$stage/target-check.txt" || die 'Target did not negotiate HTTP/2.'
    [[ "$(timedatectl show -p NTPSynchronized --value)" == yes ]] || {
        timedatectl set-ntp true
        for attempt in $(seq 1 15); do
            [[ "$(timedatectl show -p NTPSynchronized --value)" == yes ]] && break
            sleep 2
        done
    }
    [[ "$(timedatectl show -p NTPSynchronized --value)" == yes ]] || die 'Time is not synchronized.'
    download -H 'Accept: application/vnd.github+json' -H 'X-GitHub-Api-Version: 2022-11-28' \
        https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$stage/release-metadata.json"
    read -r release asset download_url digest < <(python3 "$HELPER_SOURCE" release "$stage/release-metadata.json" "$(dpkg --print-architecture)")
    sha256=${digest#sha256:}
    echo "Downloading latest stable Xray $release / $asset"
    download "$download_url" -o "$stage/xray.zip"
    printf '%s  %s\n' "$sha256" "$stage/xray.zip" | sha256sum --check --status || die 'SHA256 mismatch.'
    unzip -q "$stage/xray.zip" xray LICENSE -d "$stage/core"
    chmod 0755 "$stage/core/xray"
    python3 "$HELPER_SOURCE" configure --xray "$stage/core/xray" --output "$stage/generated" \
        --version "$release" --address "$ADDRESS" --target "$TARGET" --kcp-port "$KCP_PORT" --reality-port "$REALITY_PORT"
    "$stage/core/xray" run -test -config "$stage/generated/config.json"

    if getent passwd xray-vps >/dev/null; then
        xray_account_valid || die 'Existing xray-vps account is not safe to reuse.'
    else
        useradd --system --user-group --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin xray-vps
    fi
    install -d -m 0755 "$LIB"
    install -d -o root -g xray-vps -m 0750 /etc/xray-vps
    install -d -m 0700 "$BASE"
    install -m 0755 "$stage/core/xray" "$LIB/xray"
    install -m 0644 "$stage/core/LICENSE" "$LIB/LICENSE"
    install -m 0644 "$HELPER_SOURCE" "$LIB/xray_vps.py"
    install -m 0755 "$SELF" /usr/local/sbin/xray-vps
    install -o root -g xray-vps -m 0640 "$stage/generated/config.json" "$CONF"
    for file in state.json client-info.txt links.txt; do install -m 0600 "$stage/generated/$file" "$BASE/$file"; done
    for file in ssh-ports.txt listener-tcp-ports.txt preserve-tcp-ports.txt \
        docker-active.txt docker-all-tcp.txt docker-all-udp.txt docker-public-tcp.txt docker-public-udp.txt \
        ufw-original-state.txt target-check.txt release-metadata.json; do
        install -m 0600 "$stage/$file" "$BASE/$file"
    done
    printf '%s\n' "$stage" > "$BASE/staging-path.txt"
    cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray VPS (VMess KCP DTLS and VLESS REALITY)
Documentation=https://github.com/XTLS/Xray-core
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=xray-vps
Group=xray-vps
ExecStart=/usr/local/lib/xray-vps/xray run -config /etc/xray-vps/config.json
Restart=on-failure
RestartSec=5s
LimitNOFILE=65536
UMask=0077
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
PrivateDevices=true
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK
StandardOutput=journal
StandardError=journal
[Install]
WantedBy=multi-user.target
UNIT
    cat > /etc/systemd/system/xray-vps-firewall-rollback.service <<'UNIT'
[Unit]
Description=Revert unconfirmed Xray VPS firewall change
[Service]
Type=oneshot
ExecStart=/usr/local/sbin/xray-vps firewall-rollback
UNIT
    cat > /etc/systemd/system/xray-vps-firewall-rollback.timer <<'UNIT'
[Unit]
Description=Ten minute Xray VPS firewall confirmation window
[Timer]
OnActiveSec=10min
AccuracySec=1s
Unit=xray-vps-firewall-rollback.service
[Install]
WantedBy=timers.target
UNIT
    chmod 0644 /etc/systemd/system/xray.service /etc/systemd/system/xray-vps-firewall-rollback.{service,timer}
    if [[ "$(cat "$BASE/ufw-original-state.txt")" == inactive ]]; then
        sed -i 's/^IPV6=.*/IPV6=yes/' /etc/default/ufw
        grep -qx 'IPV6=yes' /etc/default/ufw || die 'Could not enable UFW IPv6 coverage.'
    fi
    systemctl daemon-reload
    /usr/local/sbin/xray-vps firewall-enable
    if [[ "$NGINX_ACTIVE" == yes ]]; then
        if ! systemctl is-active --quiet nginx 2>/dev/null && ! pgrep -x nginx >/dev/null 2>&1; then
            die 'Nginx stopped unexpectedly; keep the rollback timer active.'
        fi
        while read -r port; do
            ss -H -lnt "sport = :$port" | grep -q . || die "Existing TCP listener $port disappeared; keep the rollback timer active."
        done < "$BASE/listener-tcp-ports.txt"
        echo 'Nginx remains active and all original host TCP listeners remain bound.'
    fi
    if [[ "$DOCKER_ACTIVE" == yes ]]; then
        systemctl is-active --quiet docker || die 'Docker stopped unexpectedly; keep the firewall rollback timer active.'
        snapshot_docker_ports "$LIB/xray_vps.py" "$stage/docker-after"
        for protocol in tcp udp; do
            cmp -s "$BASE/docker-all-${protocol}.txt" "$stage/docker-after-all-${protocol}.txt" \
                || die "Docker $protocol port mappings changed during installation; keep the rollback timer active."
            cmp -s "$BASE/docker-public-${protocol}.txt" "$stage/docker-after-public-${protocol}.txt" \
                || die "Docker public $protocol bindings changed during installation; keep the rollback timer active."
        done
        echo 'Docker remains active and its published port mappings are unchanged.'
    fi
    ssh_csv=$(paste -sd, "$BASE/ssh-ports.txt")
    cat > /etc/fail2ban/jail.d/xray-vps-sshd.local <<EOF
[sshd]
enabled = true
backend = systemd
port = $ssh_csv
maxretry = 5
findtime = 10m
bantime = 1h
EOF
    chmod 0644 /etc/fail2ban/jail.d/xray-vps-sshd.local
    fail2ban-client -t
    systemctl enable fail2ban
    systemctl restart fail2ban
    echo
    echo 'Deployment staged successfully. Keep this SSH window OPEN.'
    echo "REALITY TCP PORT (open this exact TCP port in the cloud firewall): $REALITY_PORT"
    echo "KCP UDP PORT (open this exact UDP port in the cloud firewall): $KCP_PORT"
    [[ "$REALITY_PORT" == 443 ]] || echo 'NOTICE: REALITY is using a non-443 port because TCP 443 was occupied.'
    echo 'Open a SECOND PuTTY session within 10 minutes and run:'
    echo 'sudo env SSH_CONNECTION="$SSH_CONNECTION" /usr/local/sbin/xray-vps confirm'
    trap - ERR
}

check_service() {
    local port proto
    systemctl is-active --quiet xray || return 1
    while read -r port proto; do
        ss -H -ln"$proto" "sport = :$port" | grep -q . || return 1
    done < <(python3 - "$BASE/state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); print(s['kcp_port'],'u'); print(s['reality_port'],'t')
PY
)
}

remove_managed_ufw_rules() {
    local number
    while :; do
        number=$(ufw status numbered | sed -n '/# xray-vps managed/s/^\[[[:space:]]*\([0-9][0-9]*\)\].*/\1/p' | tail -n 1)
        [[ -n "$number" ]] || break
        ufw --force delete "$number" >/dev/null
    done
}

replace_existing_main() {
    local confirmation=${1:-} fragment backup saved_rules unmanaged_rules index
    local -a paths labels
    require_root
    [[ "$confirmation" == --confirm && $# -eq 1 ]] \
        || die 'Usage: deploy.sh replace-existing --confirm'
    systemctl cat v2ray.service >/dev/null 2>&1 \
        && die 'An existing V2Ray service was detected; refusing to replace an unrelated service.'
    if command -v xray >/dev/null || command -v v2ray >/dev/null; then
        die 'An unmanaged Xray/V2Ray command is present in PATH; refusing automatic replacement.'
    fi
    fragment=$(systemctl show -p FragmentPath --value xray.service 2>/dev/null || true)
    if [[ -n "$fragment" && -f "$fragment" ]]; then
        grep -Fq '/usr/local/lib/xray-vps/xray run -config /etc/xray-vps/config.json' "$fragment" \
            || die "The existing xray.service is not managed by this kit: $fragment"
    fi
    if getent passwd xray-vps >/dev/null; then
        xray_account_valid || die 'Existing xray-vps account does not match the restricted account created by this kit.'
    fi
    if command -v ufw >/dev/null && ! ufw status | grep -qx 'Status: active'; then
        saved_rules=$(ufw show added | awk '/^ufw /')
        if [[ -n "$saved_rules" ]]; then
            unmanaged_rules=$(printf '%s\n' "$saved_rules" | grep -Fv 'xray-vps' || true)
            [[ -z "$unmanaged_rules" ]] \
                || die 'UFW is inactive and contains rules not owned by this kit; refusing to reset them.'
        fi
    fi

    backup=$(mktemp -d "/root/xray-vps-replaced-$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX")
    chmod 0700 "$backup"
    printf 'Replacement backup created at UTC: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$backup/MANIFEST.txt"
    systemctl disable --now xray-vps-firewall-rollback.timer >/dev/null 2>&1 || true
    systemctl disable --now xray.service >/dev/null 2>&1 || true
    if command -v ufw >/dev/null; then
        if ufw status | grep -qx 'Status: active'; then
            remove_managed_ufw_rules
        elif [[ -n "${saved_rules:-}" ]]; then
            ufw --force reset >/dev/null
            ufw --force disable >/dev/null
        fi
    fi

    paths=(
        "$BASE"
        "$LIB"
        /etc/xray-vps
        /etc/systemd/system/xray.service
        /etc/systemd/system/xray-vps-firewall-rollback.service
        /etc/systemd/system/xray-vps-firewall-rollback.timer
        /etc/fail2ban/jail.d/xray-vps-sshd.local
        /usr/local/sbin/xray-vps
    )
    labels=(state library config xray.service firewall-rollback.service firewall-rollback.timer fail2ban-sshd.local manager)
    for index in "${!paths[@]}"; do
        if [[ -e "${paths[$index]}" || -L "${paths[$index]}" ]]; then
            mv -- "${paths[$index]}" "$backup/${labels[$index]}"
            printf '%s -> %s\n' "${paths[$index]}" "${labels[$index]}" >> "$backup/MANIFEST.txt"
        fi
    done
    systemctl daemon-reload
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        fail2ban-client reload >/dev/null || warn 'Fail2ban reload failed; the new installation will validate it again.'
    fi
    echo "Existing managed Xray deployment archived: $backup"
    echo 'Nginx, Docker, SSH and their configuration were not changed.'
    echo 'Next: rerun deploy.sh preflight, then deploy.sh install.'
}

rollback_firewall() {
    [[ -f "$BASE/firewall-pending" ]] || return 0
    if [[ "$(cat "$BASE/ufw-original-state.txt")" == active ]]; then
        remove_managed_ufw_rules
        echo 'Existing UFW remained active; only the new Xray rules were removed.'
    else
        ufw --force reset >/dev/null
        ufw --force disable
        echo 'UFW reverted to its original inactive, empty-rules state.'
    fi
    systemctl stop xray
    systemctl disable --now xray-vps-firewall-rollback.timer || true
    mv "$BASE/firewall-pending" "$BASE/firewall-rolled-back"
    echo 'Xray stopped. Nginx, Docker and SSH configuration were not changed.'
}

manage_main() {
    local command=${1:-status} remote_ip remote_port local_ip ssh_port original_ufw port proto
    local login_user passwd_entry account uid gid home primary_group destination stage backup number
    shift || true
    require_root
    [[ -f "$BASE/state.json" ]] || die 'Deployment state not found.'
    exec 9>/run/lock/xray-vps.lock
    flock -x 9
    case "$command" in
        status)
            systemctl --no-pager --full status xray || true
            ufw status verbose
            ss -lntup
            if [[ -f "$BASE/firewall-pending" ]]; then
                echo 'WARNING: firewall confirmation pending; Xray will be stopped on timeout.'
                systemctl list-timers --all --no-pager xray-vps-firewall-rollback.timer
            fi ;;
        show-client) cat "$BASE/client-info.txt" ;;
        show-links) cat "$BASE/links.txt" ;;
        check)
            "$LIB/xray" run -test -config "$CONF"
            check_service || die 'Service or listening ports not healthy.'
            ufw status verbose
            echo 'Local checks passed. This does not verify cloud firewall or client connectivity.' ;;
        firewall-enable)
            require_ssh
            read -r remote_ip remote_port local_ip ssh_port <<< "$SSH_CONNECTION"
            [[ "$ssh_port" =~ ^[0-9]+$ ]] && (( ssh_port > 0 && ssh_port <= 65535 )) || die 'Invalid SSH port.'
            printf '%s\n' "$SSH_CONNECTION" > "$BASE/firewall-pending"
            systemctl enable xray-vps-firewall-rollback.timer
            systemctl restart xray-vps-firewall-rollback.timer
            systemctl is-active --quiet xray-vps-firewall-rollback.timer || die 'Rollback timer not active.'
            trap 'rc=$?; trap - ERR; rollback_firewall; exit "$rc"' ERR
            original_ufw=$(cat "$BASE/ufw-original-state.txt")
            [[ "$original_ufw" == active || "$original_ufw" == inactive ]] || die 'Invalid saved UFW state.'
            if [[ "$original_ufw" == inactive ]]; then
                ufw insert 1 allow "$ssh_port/tcp" comment 'xray-vps SSH current session'
                while read -r port; do
                    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) || die 'Invalid saved SSH port.'
                    ufw allow "$port/tcp" comment 'xray-vps SSH listener'
                done < "$BASE/ssh-ports.txt"
                while read -r port; do
                    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) || die 'Invalid preserved TCP port.'
                    ufw allow "$port/tcp" comment 'xray-vps preserved listener'
                done < "$BASE/preserve-tcp-ports.txt"
                while read -r port; do
                    [[ "$port" =~ ^[0-9]+$ ]] && (( port > 0 && port <= 65535 )) || die 'Invalid preserved Docker UDP port.'
                    ufw allow "$port/udp" comment 'xray-vps preserved Docker UDP'
                done < "$BASE/docker-public-udp.txt"
            fi
            while read -r port proto; do ufw allow "$port/$proto" comment 'xray-vps managed'; done < <(python3 - "$BASE/state.json" <<'PY'
import json,sys
s=json.load(open(sys.argv[1])); print(s['kcp_port'],'udp'); print(s['reality_port'],'tcp')
PY
)
            if [[ "$original_ufw" == inactive ]]; then
                ufw default deny incoming
                ufw default allow outgoing
                ufw logging low
                ufw --force enable
            else
                ufw status | grep -qx 'Status: active' || die 'Existing UFW unexpectedly became inactive.'
            fi
            systemctl enable --now xray
            sleep 2
            check_service
            trap - ERR
            echo 'Within 10 minutes, open a SECOND SSH session and run the confirmation command.' ;;
        confirm|firewall-confirm)
            [[ -f "$BASE/firewall-pending" ]] || die 'No pending firewall change.'
            require_ssh
            [[ "$SSH_CONNECTION" != "$(cat "$BASE/firewall-pending")" ]] || die 'Open a second PuTTY connection first.'
            check_service || die 'Service unhealthy; keep the rollback timer.'
            ufw status | grep -qx 'Status: active' || die 'UFW is inactive.'
            systemctl disable --now xray-vps-firewall-rollback.timer
            mv "$BASE/firewall-pending" "$BASE/firewall-confirmed"
            "$LIB/xray" run -test -config "$CONF"
            echo 'SERVER CONFIRMATION PASSED'
            echo 'Next: run sudo xray-vps show-links.' ;;
        firewall-rollback) rollback_firewall ;;
        export-client)
            login_user=${1:-${SUDO_USER:-root}}
            [[ "$login_user" =~ ^[a-zA-Z_][a-zA-Z0-9_.-]{0,31}$ ]] || die 'Invalid login username.'
            passwd_entry=$(getent passwd "$login_user") || die "Login user not found: $login_user"
            IFS=: read -r account _ uid gid _ home _ <<< "$passwd_entry"
            [[ "$account" == "$login_user" && "$home" == /* && -d "$home" ]] || die 'Invalid login user home.'
            primary_group=$(id -gn "$login_user")
            destination="$home/xray-vps-client-info.txt"
            [[ ! -L "$destination" ]] || die 'Refusing to overwrite a symbolic link.'
            install -o "$login_user" -g "$primary_group" -m 0600 "$BASE/client-info.txt" "$destination"
            echo "Client information exported to $destination" ;;
        rotate-credentials)
            [[ ! -f "$BASE/firewall-pending" ]] || die 'Confirm firewall first.'
            stage=$(mktemp -d "$BASE/rotate.XXXXXXXX")
            python3 "$LIB/xray_vps.py" configure --xray "$LIB/xray" --state "$BASE/state.json" --output "$stage"
            "$LIB/xray" run -test -config "$stage/config.json"
            backup=$(mktemp -d "$BASE/backup.XXXXXXXX")
            cp -p "$CONF" "$backup/config.json"
            cp -p "$BASE/state.json" "$BASE/client-info.txt" "$BASE/links.txt" "$backup/"
            commit_rotation() {
                install -o root -g xray-vps -m 0640 "$stage/config.json" /etc/xray-vps/config.next || return 1
                mv /etc/xray-vps/config.next "$CONF" || return 1
                systemctl restart xray || return 1
                sleep 2
                check_service || return 1
                for name in state.json client-info.txt links.txt; do
                    install -m 0600 "$stage/$name" "$BASE/$name.next" || return 1
                    mv "$BASE/$name.next" "$BASE/$name" || return 1
                done
            }
            if commit_rotation; then
                echo "Credentials rotated. Private backup: $backup"
            else
                install -o root -g xray-vps -m 0640 "$backup/config.json" "$CONF"
                for name in state.json client-info.txt links.txt; do install -m 0600 "$backup/$name" "$BASE/$name"; done
                systemctl restart xray || true
                die "Rotation failed; original configuration restored. Backup: $backup"
            fi ;;
        *) die 'Usage: xray-vps {status|check|show-client|show-links|confirm|export-client [USER]|rotate-credentials}' ;;
    esac
}

command=${1:-}
[[ -n "$command" ]] || die 'Usage: deploy.sh {preflight|install|confirm}; installed: xray-vps {status|check|show-links|rotate-credentials}'
shift
case "$command" in
    preflight) preflight_main "$@" ;;
    install) install_main "$@" ;;
    replace-existing) replace_existing_main "$@" ;;
    *) manage_main "$command" "$@" ;;
esac
