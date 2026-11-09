#!/usr/bin/env bash
# SEG node configuration stages (roadmap, items 14-20). One stage per run:
#
#   apply-seg.sh failclosed
#
# Candidate files are staged by sync-servers.ps1 -Mode SEG in /root/.seg-sync/. A stage validates the
# candidates, backs up what it replaces, installs, verifies and restores the previous state on failure.
# A failed stage never weakens fail-closed: an installed fail-closed table is restored, and on the first
# installation the node simply stays without the new configuration.
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

log START "Script started."

[[ "${EUID}" -eq 0 ]] || die "apply-seg.sh must be run as root"

USAGE="Usage: $0 failclosed | $0 routing <BACKHAUL_INTERFACE> <BACKHAUL_MTU>"

[[ $# -ge 1 ]] || die "$USAGE"

STAGE="$1"
STAGING_DIR="/root/.seg-sync"
BACKUP_DIR="$(mktemp -d /root/.seg-backup.XXXXXX)"
ROLLBACK_ACTION=""

on_exit()
{
    local exit_code=$?

    if [[ "$exit_code" -ne 0 && -n "$ROLLBACK_ACTION" ]]; then
        log WARN "Stage $STAGE failed; restoring the previous state."
        trap - ERR
        "$ROLLBACK_ACTION" || log ERROR "Rollback of stage $STAGE failed; check the node manually."
    fi

    rm -rf "$BACKUP_DIR"
    exit "$exit_code"
}

trap on_exit EXIT

check_unresolved()
{
    if grep -q '{{[^}]*}}' "$1"; then
        log ERROR "Unresolved variables in $(basename "$1")" >&2
        grep -n '{{[^}]*}}' "$1" >&2 || true
        exit 1
    fi
}

backup_file()
{
    # backup_file <path>: keeps a copy of the current file, or a marker when it does not exist yet.
    local path="$1"
    local key
    key="$(printf '%s' "$path" | tr '/' '_')"

    if [[ -f "$path" ]]; then
        cp -a "$path" "${BACKUP_DIR}/${key}"
    else
        : >"${BACKUP_DIR}/${key}.absent"
    fi
}

restore_file()
{
    local path="$1"
    local key
    key="$(printf '%s' "$path" | tr '/' '_')"

    if [[ -f "${BACKUP_DIR}/${key}" ]]; then
        cp -a "${BACKUP_DIR}/${key}" "$path"
    elif [[ -f "${BACKUP_DIR}/${key}.absent" ]]; then
        rm -f "$path"
    fi
}

same_file()
{
    [[ -f "$2" ]] && cmp -s "$1" "$2"
}

# ------------------------------------------------------------
# Stage failclosed (seg-gateway, item 14)
# ------------------------------------------------------------

FC_NFT_SRC="${STAGING_DIR}/seg-failclosed.nft"
FC_UNIT_SRC="${STAGING_DIR}/seg-failclosed.service"
FC_NFT_DST="/etc/seg/seg-failclosed.nft"
FC_UNIT_DST="/etc/systemd/system/seg-failclosed.service"
FC_WAS_ACTIVE=0
FC_WAS_ENABLED=0

failclosed_table_ok()
{
    # The loaded table must hold the drop rule for the marked traffic and the unmatched-direct counter.
    local mark interface listing

    mark="$(sed -nE 's/^[[:space:]]*meta mark (0x[0-9a-fA-F]+) oifname != .*counter drop$/\1/p' "$FC_NFT_DST" | head -n1)"
    interface="$(sed -nE 's/^[[:space:]]*meta mark 0x[0-9a-fA-F]+ oifname != "([^"]+)" counter drop$/\1/p' "$FC_NFT_DST" | head -n1)"

    [[ -n "$mark" && -n "$interface" ]] || return 1

    mark="$(printf '0x%08x' "$((mark))")"
    listing="$(nft list table inet seg_failclosed 2>/dev/null)" || return 1

    grep -Fq "meta mark ${mark} oifname != \"${interface}\" counter" <<<"$listing" &&
        grep -Fq 'drop' <<<"$listing" &&
        grep -Fq 'counter unmatched_direct' <<<"$listing"
}

rollback_failclosed()
{
    restore_file "$FC_NFT_DST"
    restore_file "$FC_UNIT_DST"
    systemctl daemon-reload

    if [[ -f "$FC_NFT_DST" && -f "$FC_UNIT_DST" ]]; then
        # Previous version: load it again, never leave the node without the table.
        nft -f "$FC_NFT_DST"

        if [[ "$FC_WAS_ENABLED" == "1" ]]; then
            systemctl enable seg-failclosed.service >/dev/null 2>&1 || true
        fi
    else
        systemctl disable seg-failclosed.service >/dev/null 2>&1 || true
        nft delete table inet seg_failclosed >/dev/null 2>&1 || true
        systemctl reset-failed seg-failclosed.service >/dev/null 2>&1 || true
    fi
}

stage_failclosed()
{
    [[ -f "$FC_NFT_SRC" ]] || die "$FC_NFT_SRC not found"
    [[ -f "$FC_UNIT_SRC" ]] || die "$FC_UNIT_SRC not found"

    check_unresolved "$FC_NFT_SRC"
    check_unresolved "$FC_UNIT_SRC"
    log OK "No unresolved template variables found."

    # Syntax and semantics are checked without loading anything.
    nft -c -f "$FC_NFT_SRC"
    log OK "nftables candidate validated (nft -c)."

    systemctl is-active --quiet seg-failclosed.service && FC_WAS_ACTIVE=1 || true
    systemctl is-enabled --quiet seg-failclosed.service 2>/dev/null && FC_WAS_ENABLED=1 || true

    if same_file "$FC_NFT_SRC" "$FC_NFT_DST" &&
       same_file "$FC_UNIT_SRC" "$FC_UNIT_DST" &&
       [[ "$FC_WAS_ACTIVE" == "1" && "$FC_WAS_ENABLED" == "1" ]] &&
       failclosed_table_ok; then
        log OK "Fail-closed is already current."
        rm -f "$FC_NFT_SRC" "$FC_UNIT_SRC"
        return 0
    fi

    backup_file "$FC_NFT_DST"
    backup_file "$FC_UNIT_DST"
    ROLLBACK_ACTION=rollback_failclosed

    install -d -o root -g root -m 755 /etc/seg
    install -o root -g root -m 644 "$FC_NFT_SRC" "$FC_NFT_DST"
    install -o root -g root -m 644 "$FC_UNIT_SRC" "$FC_UNIT_DST"
    systemctl daemon-reload
    systemctl enable seg-failclosed.service >/dev/null

    # reload replaces the table in one nftables transaction, so there is no moment without the rule;
    # restart would delete the table first (ExecStop).
    if [[ "$FC_WAS_ACTIVE" == "1" ]]; then
        systemctl reload seg-failclosed.service
    else
        systemctl start seg-failclosed.service
    fi

    systemctl is-active --quiet seg-failclosed.service || die "seg-failclosed.service is not active"
    systemctl is-enabled --quiet seg-failclosed.service || die "seg-failclosed.service is not enabled"
    failclosed_table_ok || die "Table seg_failclosed does not contain the expected rules"

    ROLLBACK_ACTION=""
    rm -f "$FC_NFT_SRC" "$FC_UNIT_SRC"
    log OK "Fail-closed installed and verified."
}

# ------------------------------------------------------------
# Stage routing (seg-gateway, item 15)
# ------------------------------------------------------------
# Selected traffic reaches the backhaul through sing-box bind_interface, not through routing tables:
# the main table must stay as it is and the backhaul must not hold routes beyond its own subnet.
# Reverse-path filtering must not be strict, or replies arriving from the backhaul are dropped.

RP_DROPIN="/etc/sysctl.d/90-seg-rp-filter.conf"

read_rp_filter()
{
    cat "/proc/sys/net/ipv4/conf/$1/rp_filter"
}

max_number()
{
    (( $1 >= $2 )) && echo "$1" || echo "$2"
}

stage_routing()
{
    local interface="$1"
    local mtu="$2"

    [[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid backhaul interface: $interface"
    [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 576 && mtu <= 1500 )) || die "Invalid backhaul MTU: $mtu"

    # 1. The main table is not changed: the default route leaves through the public interface.
    local default_dev
    default_dev="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"

    [[ -n "$default_dev" ]] || die "No IPv4 default route"
    [[ "$default_dev" != "$interface" ]] || die "The default route uses the backhaul interface $interface"
    log OK "Main table: the default route leaves through $default_dev."

    if [[ -n "$(ip rule show | grep -vE 'lookup (local|main|default)$' || true)" ]]; then
        log WARN "Policy routing rules exist besides the standard ones; SEG does not use them:"
        ip rule show | grep -vE 'lookup (local|main|default)$' || true
    else
        log OK "No policy routing rules (SEG uses bind_interface, not ip rule)."
    fi

    local interface_exists=0
    ip link show "$interface" >/dev/null 2>&1 && interface_exists=1

    if [[ "$interface_exists" == "1" ]]; then
        local extra
        extra="$(ip -4 route show dev "$interface" | grep -v 'proto kernel' || true)"

        [[ -z "$extra" ]] || die "The backhaul interface holds routes besides its own subnet (Table = off is required): $extra"
        log OK "The backhaul interface holds only its own subnet route."

        local actual_mtu
        actual_mtu="$(cat "/sys/class/net/${interface}/mtu")"

        if [[ "$actual_mtu" == "$mtu" ]]; then
            log OK "Backhaul MTU is $mtu."
        else
            log WARN "Backhaul MTU is $actual_mtu, expected $mtu; the backhaul stage applies it."
        fi
    else
        log INFO "Interface $interface does not exist yet; it is created by the backhaul stage."
    fi

    # 2. Reverse-path filtering: the effective value is the larger of 'all' and the interface value;
    # an interface that does not exist yet inherits 'default'. 1 means strict.
    local all_value default_value interface_value effective
    all_value="$(read_rp_filter all)"
    default_value="$(read_rp_filter default)"

    if [[ "$interface_exists" == "1" ]]; then
        interface_value="$(read_rp_filter "$interface")"
    else
        interface_value="$default_value"
    fi

    effective="$(max_number "$all_value" "$interface_value")"

    if [[ "$effective" == "1" ]]; then
        log WARN "rp_filter is strict for the backhaul (all=$all_value, interface=$interface_value); setting loose mode (2)."

        cat >"$RP_DROPIN" <<'RP_EOF'
# SEG: replies from the backhaul must not be dropped by strict reverse-path filtering.
net.ipv4.conf.all.rp_filter=2
net.ipv4.conf.default.rp_filter=2
RP_EOF

        sysctl -q -p "$RP_DROPIN"

        if [[ "$interface_exists" == "1" ]]; then
            sysctl -q -w "net.ipv4.conf.${interface}.rp_filter=2"
        fi

        all_value="$(read_rp_filter all)"
        interface_value="$([[ "$interface_exists" == "1" ]] && read_rp_filter "$interface" || read_rp_filter default)"
        effective="$(max_number "$all_value" "$interface_value")"
    fi

    [[ "$effective" != "1" ]] || die "rp_filter is still strict for the backhaul"
    log OK "rp_filter is not strict for the backhaul (all=$all_value, interface=$interface_value, effective=$effective)."
}

case "$STAGE" in
    failclosed)
        [[ $# -eq 1 ]] || die "$USAGE"
        stage_failclosed
        ;;
    routing)
        [[ $# -eq 3 ]] || die "$USAGE"
        stage_routing "$2" "$3"
        ;;
    *)
        die "Unknown stage: $STAGE. $USAGE"
        ;;
esac

log OK "APPLY_SEG_OK stage=$STAGE"
log DONE "Script completed successfully."
