#!/usr/bin/env bash
# SEG node status (read-only): resources, services, backhaul and, on the gateway, the addresses of the connected
# clients. Changes nothing on the node and leaves nothing on it. scripts\status-servers.ps1 -Mode SEG runs it
# through ssh without uploading it.
#
#   status-node.sh seg-gateway <VLESS_PORT> <BACKHAUL_INTERFACE>
#   status-node.sh seg-exit <BACKHAUL_INTERFACE>
#
# Prints "STATUS NAME=value" lines. The values of DISK, MEMORY, JOURNAL, SERVICES and BACKHAUL start with
# OK or WARN (the thresholds are the ones of check-node.sh). CLIENT_IP lines list the distinct client addresses
# with an established connection to the VLESS port: sing-box keeps no per-user counters, so no names.
set -Eeuo pipefail

SCRIPT_NAME="${SEG_SCRIPT_NAME:-$(basename "$0")}"

log()
{
    local level="$1"
    shift
    printf '%s [%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$SCRIPT_NAME" "$level" "$*"
}

die()
{
    log ERROR "$*" >&2
    exit 1
}

USAGE="Usage: $0 seg-gateway <VLESS_PORT> <BACKHAUL_INTERFACE> | $0 seg-exit <BACKHAUL_INTERFACE>"

[[ $# -ge 1 ]] || die "$USAGE"

ROLE="$1"

case "$ROLE" in
    seg-gateway)
        [[ $# -eq 3 ]] || die "$USAGE"
        VLESS_PORT="$2"
        INTERFACE="$3"
        [[ "$VLESS_PORT" =~ ^[0-9]{1,5}$ ]] || die "Invalid port"
        ;;
    seg-exit)
        [[ $# -eq 2 ]] || die "$USAGE"
        INTERFACE="$2"
        ;;
    *)
        die "$USAGE"
        ;;
esac

[[ "$INTERFACE" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid interface: $INTERFACE"

DISK_WARN_PERCENT=75
MEMORY_WARN_AVAILABLE_PERCENT=15
JOURNAL_WARN_BYTES=$((180 * 1024 * 1024))
VARLOG_WARN_BYTES=$((300 * 1024 * 1024))
HANDSHAKE_FRESH_SECONDS=150

emit()
{
    echo "STATUS $1=$2"
}

iec()
{
    numfmt --to=iec "$1"
}

# ------------------------------------------------------------
# System
# ------------------------------------------------------------

# shellcheck disable=SC1091
source /etc/os-release
emit OS "${ID:-unknown} ${VERSION_ID:-unknown}"
emit KERNEL "$(uname -r)"
emit UPTIME "$(uptime -p)"

read -r load1 load5 load15 _ </proc/loadavg
emit LOAD "${load1} ${load5} ${load15} ($(nproc) CPU)"

if [[ -f /var/run/reboot-required ]]; then
    emit REBOOT_REQUIRED yes
else
    emit REBOOT_REQUIRED no
fi

# ------------------------------------------------------------
# Disk, memory, logs
# ------------------------------------------------------------

disk_used="$(df -P / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"
disk_line="$(df -Ph / | awk 'NR == 2 { print $3 " of " $2 ", free " $4 }')"
inode_used="$(df -Pi / | awk 'NR == 2 { gsub("%", "", $5); print $5 }')"
disk_state=OK
{ [[ "${disk_used:-0}" -ge "$DISK_WARN_PERCENT" ]] || [[ "${inode_used:-0}" =~ ^[0-9]+$ && "$inode_used" -ge "$DISK_WARN_PERCENT" ]]; } && disk_state=WARN
emit DISK "${disk_state} used ${disk_used}% (${disk_line}), inodes ${inode_used:--}%"

mem_total_kb="$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)"
mem_available_kb="$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)"
swap_total_kb="$(awk '/^SwapTotal:/ { print $2 }' /proc/meminfo)"
swap_free_kb="$(awk '/^SwapFree:/ { print $2 }' /proc/meminfo)"
mem_available_percent=$(( mem_available_kb * 100 / mem_total_kb ))
mem_state=OK
[[ "$mem_available_percent" -lt "$MEMORY_WARN_AVAILABLE_PERCENT" ]] && mem_state=WARN
emit MEMORY "${mem_state} available ${mem_available_percent}% ($((mem_available_kb / 1024)) MB of $((mem_total_kb / 1024)) MB), swap used $(( (swap_total_kb - swap_free_kb) / 1024 )) MB of $((swap_total_kb / 1024)) MB"

journal_bytes="$(du -sb /var/log/journal 2>/dev/null | awk '{ print $1 }')"
varlog_bytes="$(du -sxb /var/log 2>/dev/null | awk '{ print $1 }')"
journal_bytes="${journal_bytes:-0}"
varlog_bytes="${varlog_bytes:-0}"
journal_state=OK
{ [[ "$journal_bytes" -ge "$JOURNAL_WARN_BYTES" ]] || [[ "$varlog_bytes" -ge "$VARLOG_WARN_BYTES" ]]; } && journal_state=WARN
emit JOURNAL "${journal_state} journald $(iec "$journal_bytes"), /var/log $(iec "$varlog_bytes")"

apt_bytes="$(du -sb /var/cache/apt 2>/dev/null | awk '{ print $1 }')"
kernels="$(dpkg-query -W -f='${Package} ${Status}\n' 'linux-image-[0-9]*' 2>/dev/null | grep -c ' installed$' || true)"
updates="$(apt-get -s upgrade 2>/dev/null | grep -c '^Inst' || true)"
emit PACKAGES "apt cache $(iec "${apt_bytes:-0}"), kernels ${kernels}, pending updates ${updates}"

# ------------------------------------------------------------
# Services
# ------------------------------------------------------------

if [[ "$ROLE" == "seg-gateway" ]]; then
    units=(seg-failclosed.service "awg-quick@${INTERFACE}.service" sing-box.service fail2ban.service)
else
    units=(seg-exit-fw.service "awg-quick@${INTERFACE}.service" seg-exit-keepalive.service unbound.service fail2ban.service)
fi

services_state=OK
services_text=""

for unit in "${units[@]}"; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    [[ "$state" == "active" ]] || services_state=WARN
    services_text+=" ${unit%.service}=${state:-unknown}"
done

emit SERVICES "${services_state}${services_text}"

# ------------------------------------------------------------
# Backhaul
# ------------------------------------------------------------

backhaul_state=WARN
backhaul_text="interface ${INTERFACE} is down"

if ip link show "$INTERFACE" >/dev/null 2>&1; then
    timestamp="$(awg show "$INTERFACE" latest-handshakes 2>/dev/null | head -n1 | awk '{ print $2 }' || true)"
    transfer="$(awg show "$INTERFACE" transfer 2>/dev/null | head -n1 || true)"
    rx="$(awk '{ print $2 }' <<<"$transfer")"
    tx="$(awk '{ print $3 }' <<<"$transfer")"
    traffic=""

    if [[ "$rx" =~ ^[0-9]+$ && "$tx" =~ ^[0-9]+$ ]]; then
        traffic=", received $(iec "$rx"), sent $(iec "$tx")"
    fi

    if [[ -z "$timestamp" || "$timestamp" == "0" ]]; then
        backhaul_text="no handshake${traffic}"
    else
        age=$(( $(date +%s) - timestamp ))
        backhaul_text="handshake ${age}s ago${traffic}"
        [[ "$age" -le "$HANDSHAKE_FRESH_SECONDS" ]] && backhaul_state=OK
    fi
fi

emit BACKHAUL "${backhaul_state} ${backhaul_text}"

# ------------------------------------------------------------
# Gateway: sing-box and the connected clients
# ------------------------------------------------------------

if [[ "$ROLE" == "seg-gateway" ]]; then
    version="$(/usr/local/bin/sing-box version 2>/dev/null | awk 'NR == 1 { print $3 }' || true)"
    sb_pid="$(systemctl show -p MainPID --value sing-box.service 2>/dev/null || true)"
    sb_rss=""

    if [[ "$sb_pid" =~ ^[0-9]+$ ]] && (( sb_pid > 0 )); then
        rss_kb="$(awk '/^VmRSS:/ { print $2 }' "/proc/${sb_pid}/status" 2>/dev/null || true)"
        [[ "$rss_kb" =~ ^[0-9]+$ ]] && sb_rss=", memory $((rss_kb / 1024)) MB"
    fi

    emit SING_BOX "${version:-unknown}${sb_rss}"

    clients="$(ss -Htn state established "( sport = :${VLESS_PORT} )" 2>/dev/null \
        | awk '{ print $4 }' \
        | sed -E 's/:[0-9]+$//; s/^\[//; s/\]$//; s/^::ffff://' \
        | sort -u || true)"

    count=0

    while IFS= read -r address; do
        [[ -n "$address" ]] || continue
        count=$((count + 1))
        emit CLIENT_IP "$address"
    done <<<"$clients"

    emit CLIENTS "$count"
fi

log OK "STATUS_NODE_DONE role=${ROLE}"
