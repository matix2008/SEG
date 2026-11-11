#!/usr/bin/env bash
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

[[ "${EUID}" -eq 0 ]] || die "bootstrap.sh must be run as root"
[[ $# -eq 1 ]] || die "Usage: $0 <AWG_PORT>"

AWG_PORT="$1"

if ! [[ "$AWG_PORT" =~ ^[0-9]+$ ]] ||
   (( AWG_PORT < 1 || AWG_PORT > 65535 )); then
    die "Invalid AWG port: $AWG_PORT"
fi

SRC_CONF="/root/.amnezia-sync/awg0.conf"
SRC_SERVICE="/root/.amnezia-sync/awg-iptables.service"
DST_DIR="/etc/amnezia/amneziawg"
DST_CONF="${DST_DIR}/awg0.conf"
DST_SERVICE="/etc/systemd/system/awg-iptables.service"

cleanup_staging()
{
    rm -f "$SRC_CONF" "$SRC_SERVICE"
}

trap cleanup_staging EXIT

[[ -f "$SRC_CONF" ]] || die "$SRC_CONF not found"
[[ -f "$SRC_SERVICE" ]] || die "$SRC_SERVICE not found"

log OK "Required source files found."

if grep -q '{{[^}]*}}' "$SRC_CONF"; then
    log ERROR "Unresolved variables in awg0.conf" >&2
    grep -n '{{[^}]*}}' "$SRC_CONF" >&2 || true
    exit 1
fi

if grep -q '{{[^}]*}}' "$SRC_SERVICE"; then
    log ERROR "Unresolved variables in awg-iptables.service" >&2
    grep -n '{{[^}]*}}' "$SRC_SERVICE" >&2 || true
    exit 1
fi

log OK "No unresolved template variables found."

CONFIG_PORT="$(
    sed -nE \
      's/^[[:space:]]*ListenPort[[:space:]]*=[[:space:]]*([0-9]+).*$/\1/p' \
      "$SRC_CONF" |
    head -n1
)"

[[ "$CONFIG_PORT" == "$AWG_PORT" ]] || \
    die "ListenPort=$CONFIG_PORT, expected $AWG_PORT"

log OK "ListenPort verified: $AWG_PORT"

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

DEBIAN_FRONTEND=noninteractive apt-get install -y amneziawg
log OK "AmneziaWG package installed."

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
log OK "AmneziaWG kernel module and command-line tools verified."

if ip -6 route get 2606:4700:4700::1111 2>/dev/null | grep -q ' src '; then
    log OK "Global IPv6 route/source detected."
else
    log WARN "No usable global IPv6 route/source detected. IPv6 traffic through the VPN may not work on this VPS."
fi

log INFO "Enabling IPv4/IPv6 forwarding."
cat >/etc/sysctl.d/99-amneziawg-forwarding.conf <<'SYSCTL_EOF'
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1
SYSCTL_EOF

sysctl --system >/dev/null

[[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || die "IPv4 forwarding is not enabled"
[[ "$(sysctl -n net.ipv6.conf.all.forwarding)" == "1" ]] || die "IPv6 forwarding is not enabled"
log OK "IPv4/IPv6 forwarding enabled and verified."

# Some provider images ship with UFW already active and the AWG UDP port closed,
# so the VPN could not be verified before hardening. Disable it only while the
# server is not hardened yet; secure.sh enables UFW again with the SSH and AWG
# rules. A hardened server (repair run) keeps its firewall untouched.
HARDENING_DROPIN="/etc/ssh/sshd_config.d/00-amnezia-hardening.conf"

if [[ ! -f "$HARDENING_DROPIN" ]] &&
   command -v ufw >/dev/null 2>&1 &&
   [[ "$(ufw status 2>/dev/null | head -n1)" == "Status: active" ]]; then
    log WARN "UFW is active before hardening; disabling it so the VPN can be verified. secure.sh enables it again."
    ufw --force disable
fi

log INFO "Installing AmneziaWG configuration and NAT/FORWARD service."
install -d -o root -g root -m 700 "$DST_DIR"

BACKUP=""

if [[ -f "$DST_CONF" ]]; then
    BACKUP="$(mktemp)"
    cp -a "$DST_CONF" "$BACKUP"
    log INFO "Existing awg0.conf backed up for rollback."
fi

install -o root -g root -m 600 "$SRC_CONF" "$DST_CONF"
install -o root -g root -m 644 "$SRC_SERVICE" "$DST_SERVICE"

systemctl daemon-reload
systemctl enable awg-quick@awg0.service >/dev/null
systemctl enable awg-iptables.service >/dev/null
log OK "Configuration files installed and services enabled."

log INFO "Starting/restarting awg0."

AWG_START_OK=1
if systemctl is-active --quiet awg-quick@awg0.service; then
    if ! systemctl restart awg-quick@awg0.service; then
        AWG_START_OK=0
    fi
else
    if ! systemctl start awg-quick@awg0.service; then
        AWG_START_OK=0
    fi
fi

if [[ "$AWG_START_OK" != "1" ]] || ! systemctl is-active --quiet awg-quick@awg0.service; then
    log ERROR "awg0 failed to start" >&2

    if [[ -n "$BACKUP" && -f "$BACKUP" ]]; then
        log WARN "Restoring previous awg0.conf."
        install -o root -g root -m 600 "$BACKUP" "$DST_CONF"
        systemctl restart awg-quick@awg0.service || true
    fi

    exit 1
fi

log OK "awg-quick@awg0.service is active."

log INFO "Starting/restarting NAT/FORWARD rules service."

if systemctl is-active --quiet awg-iptables.service; then
    systemctl restart awg-iptables.service
else
    systemctl start awg-iptables.service
fi

systemctl is-active --quiet awg-iptables.service
log OK "awg-iptables.service is active."

rm -f "${BACKUP:-}"

log INFO "Verification output follows."
ip -br address show awg0
awg show awg0

log OK "BOOTSTRAP_OK"
log INFO "SECURITY_NOT_APPLIED"
log DONE "Script completed successfully."
