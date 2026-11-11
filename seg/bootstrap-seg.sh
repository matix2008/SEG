#!/usr/bin/env bash
# SEG node bootstrap (roadmap, item 13): installs packages and prepares the node for its role.
# It installs software only. Configurations, units and services of the SEG node are installed by
# the later stages of sync-servers.ps1 -Mode SEG (fail-closed, backhaul, egress, sing-box).
#
#   bootstrap-seg.sh seg-gateway <SING_BOX_VERSION> <SING_BOX_SHA256>
#   bootstrap-seg.sh seg-exit
#
# Idempotent: a repeated run repairs a partly installed node.
set -Eeuo pipefail

SCRIPT_NAME="$(basename "$0")"

log()
{
    local level="$1"
    shift
    printf '%s [%s] [%s] %s\n' \
        "$(date '+%Y-%m-%d %H:%M:%S')" \
        "$SCRIPT_NAME" \
        "$level" \
        "$*"
}

die()
{
    log ERROR "$*" >&2
    exit 1
}

on_error()
{
    local exit_code=$?
    local line_no="$1"
    local command="$2"

    log ERROR "line ${line_no}: ${command} (code ${exit_code})" >&2
    exit "$exit_code"
}

trap 'on_error "$LINENO" "$BASH_COMMAND"' ERR

# Launchpad sometimes answers with a temporary error (HTTP 500); only this command is retried.
add_amnezia_ppa()
{
    local attempt
    local max_attempts=3
    local delay=25

    for ((attempt = 1; attempt <= max_attempts; attempt++)); do
        if add-apt-repository -y ppa:amnezia/ppa; then
            return 0
        fi

        if ((attempt < max_attempts)); then
            log WARN "add-apt-repository failed (attempt ${attempt}/${max_attempts}); retrying in ${delay} s."
            sleep "$delay"
        fi
    done

    die "add-apt-repository ppa:amnezia/ppa failed after ${max_attempts} attempts (Launchpad may be temporarily unavailable): run sync again later"
}

log START "Script started."

[[ "${EUID}" -eq 0 ]] || die "bootstrap-seg.sh must be run as root"

USAGE="Usage: $0 seg-gateway <SING_BOX_VERSION> <SING_BOX_SHA256> | $0 seg-exit"

[[ $# -ge 1 ]] || die "$USAGE"

ROLE="$1"

case "$ROLE" in
    seg-gateway)
        [[ $# -eq 3 ]] || die "$USAGE"
        SING_BOX_VERSION="$2"
        SING_BOX_SHA256="$3"

        [[ "$SING_BOX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || \
            die "Invalid sing-box version: $SING_BOX_VERSION"
        [[ "$SING_BOX_SHA256" =~ ^[0-9a-f]{64}$ ]] || \
            die "Invalid sing-box SHA-256 (64 lowercase hex characters expected)"
        ;;
    seg-exit)
        [[ $# -eq 1 ]] || die "$USAGE"
        ;;
    *)
        die "$USAGE"
        ;;
esac

log INFO "Role: $ROLE"

# shellcheck disable=SC1091
source /etc/os-release

[[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]] || \
    die "Ubuntu 24.04 is required; found ${ID:-unknown} ${VERSION_ID:-unknown}"

STAGING_DIR="/root/.seg-sync"
WORK_DIR=""
SING_BOX_PACKAGE=""

if [[ "$ROLE" == "seg-gateway" ]]; then
    SING_BOX_PACKAGE="${STAGING_DIR}/sing-box-${SING_BOX_VERSION}-linux-amd64.tar.gz"
fi

cleanup()
{
    [[ -z "$WORK_DIR" ]] || rm -rf "$WORK_DIR"
    [[ -z "$SING_BOX_PACKAGE" ]] || rm -f "$SING_BOX_PACKAGE"
}

trap cleanup EXIT

# ------------------------------------------------------------
# Common: AmneziaWG (the backhaul runs on it on both nodes)
# ------------------------------------------------------------

log INFO "Installing AmneziaWG."

# Wait for a concurrent apt/dpkg run instead of failing on its lock.
cat >/etc/apt/apt.conf.d/00-amnezia-lock-timeout <<'APT_LOCK_EOF'
DPkg::Lock::Timeout "300";
APT_LOCK_EOF

if ! apt-cache policy amneziawg 2>/dev/null |
     grep -Eq 'Candidate:[[:space:]]+[^ (]'; then

    log INFO "Amnezia PPA is required; adding ppa:amnezia/ppa."
    add_amnezia_ppa
    apt-get update
    log OK "Amnezia PPA added and package lists updated."
else
    log INFO "AmneziaWG package candidate is already available."
fi

DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg nftables
log OK "AmneziaWG and nftables packages installed."

LATEST_KERNEL="$(find /lib/modules -mindepth 1 -maxdepth 1 -printf '%f\n' 2>/dev/null | sort -V | tail -n1)"
if [[ -n "$LATEST_KERNEL" && -e "/lib/modules/$LATEST_KERNEL/build" ]] && command -v dkms >/dev/null 2>&1; then
    if ! dkms status 2>/dev/null | grep -F 'amneziawg/' | grep -F "$LATEST_KERNEL" | grep -q 'installed'; then
        log INFO "Building DKMS modules for latest installed kernel: $LATEST_KERNEL"
        dkms autoinstall -k "$LATEST_KERNEL"
    fi
fi

modprobe amneziawg
modinfo amneziawg >/dev/null
command -v awg >/dev/null
command -v awg-quick >/dev/null
command -v nft >/dev/null
log OK "AmneziaWG kernel module, command-line tools and nftables verified."

install -d -o root -g root -m 755 /etc/seg
install -d -o root -g root -m 700 /etc/amnezia/amneziawg

# ------------------------------------------------------------
# seg-gateway: sing-box from the package verified on the laptop
# ------------------------------------------------------------

install_sing_box()
{
    local installed=""

    if [[ -x /usr/local/bin/sing-box ]]; then
        installed="$(/usr/local/bin/sing-box version 2>/dev/null | sed -n '1s/^sing-box version //p' || true)"
    fi

    if [[ "$installed" == "$SING_BOX_VERSION" ]]; then
        log OK "sing-box $SING_BOX_VERSION is already installed."
        return 0
    fi

    [[ -f "$SING_BOX_PACKAGE" ]] || die "$SING_BOX_PACKAGE not found"

    local actual
    actual="$(sha256sum "$SING_BOX_PACKAGE" | cut -d' ' -f1)"

    [[ "$actual" == "$SING_BOX_SHA256" ]] || \
        die "SHA-256 of the sing-box package does not match (expected $SING_BOX_SHA256, actual $actual)"

    log OK "sing-box package SHA-256 verified on the node."

    WORK_DIR="$(mktemp -d)"
    tar -xzf "$SING_BOX_PACKAGE" -C "$WORK_DIR"

    local binaries=()
    mapfile -t binaries < <(find "$WORK_DIR" -type f -name sing-box)

    [[ "${#binaries[@]}" -eq 1 ]] || die "Expected exactly one sing-box binary in the package, found ${#binaries[@]}"

    chmod 755 "${binaries[0]}"

    local version_line
    version_line="$("${binaries[0]}" version | head -n1)"

    [[ "$version_line" == "sing-box version $SING_BOX_VERSION" ]] || \
        die "Unexpected sing-box version in the package: $version_line"

    # Replace atomically: a running sing-box keeps its old binary until restarted by the later stage.
    install -o root -g root -m 755 "${binaries[0]}" /usr/local/bin/sing-box.new
    mv -f /usr/local/bin/sing-box.new /usr/local/bin/sing-box

    if systemctl is-active --quiet sing-box.service 2>/dev/null; then
        log WARN "sing-box is running; the new binary is used after the next restart."
    fi

    log OK "sing-box $SING_BOX_VERSION installed to /usr/local/bin/sing-box."
}

if [[ "$ROLE" == "seg-gateway" ]]; then
    install_sing_box

    if ! id sing-box >/dev/null 2>&1; then
        useradd --system --no-create-home --home-dir /nonexistent --shell /usr/sbin/nologin sing-box
        log OK "System user sing-box created."
    fi

    install -d -o root -g sing-box -m 750 /etc/sing-box
    log OK "Gateway preparation completed (sing-box binary, user and directories)."
fi

# ------------------------------------------------------------
# seg-exit: DNS resolver package and forwarding
# ------------------------------------------------------------

if [[ "$ROLE" == "seg-exit" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get install -y unbound unbound-anchor
    log OK "unbound and unbound-anchor installed."

    # Without root.key the service does not start; unbound-anchor returns 1 when it has just updated the file.
    rc=0
    unbound-anchor -a /var/lib/unbound/root.key || rc=$?
    [[ "$rc" -le 1 ]] || die "unbound-anchor failed with code $rc"
    chown unbound:unbound /var/lib/unbound/root.key
    log OK "DNSSEC trust anchor prepared."

    cat >/etc/sysctl.d/99-seg-exit.conf <<'SYSCTL_EOF'
net.ipv4.ip_forward=1
SYSCTL_EOF

    sysctl --system >/dev/null

    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || die "IPv4 forwarding is not enabled"
    log OK "IPv4 forwarding enabled and verified."
fi

log OK "BOOTSTRAP_SEG_OK role=$ROLE"
log DONE "Script completed successfully."
