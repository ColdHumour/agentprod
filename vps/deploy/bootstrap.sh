#!/usr/bin/env bash
# Stage the deployment kit from GitHub or from files uploaded by upload-kit.ps1.
set -Eeuo pipefail
export LC_ALL=C
umask 077

REPOSITORY=ColdHumour/agentprod
REF=main
SOURCE_DIR=
MODE=github
DESTINATION=/root/xray-vps-kit
REPLACE=no
BACKUP=
STAGE=
CREATED_DESTINATION=no
SUCCESS=no
die() { echo "ERROR: $*" >&2; exit 1; }
usage() {
    echo 'GitHub: sudo bash bootstrap.sh [--ref BRANCH_TAG_OR_COMMIT] [--replace]'
    echo 'Upload: sudo bash bootstrap.sh --source-dir "$HOME" [--replace]'
}
while (($#)); do
    case "$1" in
        --ref) (($# >= 2)) || die 'Missing value for --ref'; REF=$2; shift 2 ;;
        --source-dir) (($# >= 2)) || die 'Missing value for --source-dir'; SOURCE_DIR=$2; MODE=upload; shift 2 ;;
        --replace) REPLACE=yes; shift ;;
        -h|--help) usage; exit 0 ;;
        *) usage; die "Unknown option: $1" ;;
    esac
done
[[ $EUID -eq 0 ]] || die 'Run with sudo or as root.'

cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    [[ -z "$STAGE" || ! -d "$STAGE" ]] || rm -rf -- "$STAGE"
    if [[ "$SUCCESS" == yes ]]; then
        [[ -z "$BACKUP" || ! -d "$BACKUP" ]] || rm -rf -- "$BACKUP"
    else
        if [[ "$CREATED_DESTINATION" == yes && -e "$DESTINATION" ]]; then
            rm -rf -- "$DESTINATION"
        fi
        if [[ -n "$BACKUP" && -d "$BACKUP" ]]; then
            mv -- "$BACKUP" "$DESTINATION"
            echo "Previous script kit restored after bootstrap failure: $DESTINATION" >&2
        fi
    fi
    exit "$rc"
}
trap cleanup EXIT

if [[ -e "$DESTINATION" || -L "$DESTINATION" ]]; then
    [[ "$REPLACE" == yes ]] || die "$DESTINATION already exists; rerun with --replace to replace only this script kit."
    [[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || die 'Existing script-kit path is not a normal directory.'
    BACKUP=$(mktemp -d /root/xray-vps-kit.backup.XXXXXXXX)
    rmdir -- "$BACKUP"
    mv -- "$DESTINATION" "$BACKUP"
    echo 'Existing script kit moved aside until the replacement passes validation.'
fi

if [[ "$MODE" == upload ]]; then
    [[ -d "$SOURCE_DIR" ]] || die 'Uploaded-file directory not found.'
    SOURCE_DIR=$(cd -- "$SOURCE_DIR" && pwd -P)
    [[ -f "$SOURCE_DIR/xray-vps-ubuntu22.04-kit.zip" ]] || die 'Deployment ZIP is missing.'
    [[ -f "$SOURCE_DIR/SHA256SUMS.txt" ]] || die 'SHA256SUMS.txt is missing.'
    (cd -- "$SOURCE_DIR" && sha256sum -c SHA256SUMS.txt)
    if ! command -v unzip >/dev/null; then
        apt-get update
        apt-get install -y --no-install-recommends unzip
    fi
    CREATED_DESTINATION=yes
    unzip -q "$SOURCE_DIR/xray-vps-ubuntu22.04-kit.zip" -d /root || {
        unzip_status=$?
        # Info-ZIP uses status 1 for recoverable warnings such as legacy Windows
        # backslash separators. Required-file and syntax checks below remain mandatory.
        (( unzip_status == 1 )) || die "Could not extract the deployment ZIP (unzip exit $unzip_status)."
        echo 'ZIP extraction completed with a warning; validating every required file.'
    }
else
    [[ "$REF" =~ ^[A-Za-z0-9][A-Za-z0-9._/-]{0,127}$ ]] || die 'Invalid Git ref.'
    [[ "$REF" != *'..'* && "$REF" != */ ]] || die 'Invalid Git ref.'
    if ! command -v curl >/dev/null; then
        apt-get update
        apt-get install -y --no-install-recommends ca-certificates curl
    fi
    STAGE=$(mktemp -d /root/xray-vps-github.XXXXXXXX)
    archive="$STAGE/repository.tar.gz"
    url="https://codeload.github.com/$REPOSITORY/tar.gz/$REF"
    echo "Downloading https://github.com/$REPOSITORY at ref: $REF"
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 \
        --connect-timeout 15 --max-time 180 --retry 3 "$url" -o "$archive"
    archive_sha256=$(sha256sum "$archive" | awk '{print $1}')
    tar -xzf "$archive" -C "$STAGE"
    mapfile -t matches < <(find "$STAGE" -type f -path '*/vps/deploy/deploy.sh' -print)
    [[ ${#matches[@]} -eq 1 ]] || die 'Archive does not contain exactly one vps/deploy directory.'
    source_dir=$(dirname -- "${matches[0]}")
    [[ -z "$(find "$source_dir" -type l -print -quit)" ]] || die 'Refusing a deploy directory containing symbolic links.'
    CREATED_DESTINATION=yes
    install -d -m 0700 "$DESTINATION"
    for file in deploy.sh xray_vps.py README.md; do
        [[ -f "$source_dir/$file" ]] || die "Repository snapshot is missing: $file"
        install -m 0600 "$source_dir/$file" "$DESTINATION/$file"
    done
    cat > "$DESTINATION/SOURCE.txt" <<EOF
Repository: https://github.com/$REPOSITORY
Requested ref: $REF
Downloaded archive SHA256: $archive_sha256
Downloaded at UTC: $(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
    chmod 0600 "$DESTINATION/SOURCE.txt"
fi

[[ -d "$DESTINATION" && ! -L "$DESTINATION" ]] || die 'Deployment ZIP did not create a normal script-kit directory.'
[[ -z "$(find "$DESTINATION" -type l -print -quit)" ]] || die 'Refusing a script kit containing symbolic links.'
for file in deploy.sh xray_vps.py README.md; do
    [[ -f "$DESTINATION/$file" ]] || die "Missing required file: $file"
done
if ! command -v python3 >/dev/null; then
    apt-get update
    apt-get install -y --no-install-recommends python3
fi
chmod 0700 "$DESTINATION/deploy.sh"
chmod -R go-w "$DESTINATION"
bash -n "$DESTINATION/deploy.sh"
python3 - "$DESTINATION/xray_vps.py" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
compile(path.read_text(encoding="utf-8"), str(path), "exec")
PY
echo "SCRIPT KIT READY: $DESTINATION"
echo 'Next: sudo env SSH_CONNECTION="$SSH_CONNECTION" bash /root/xray-vps-kit/deploy.sh preflight'
SUCCESS=yes
