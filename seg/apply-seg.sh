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

USAGE="Usage: $0 failclosed | $0 routing <BACKHAUL_INTERFACE> <BACKHAUL_MTU> | $0 backhaul <BACKHAUL_INTERFACE> <BACKHAUL_MTU> | $0 egress <BACKHAUL_INTERFACE> <VPS1_BACKHAUL_IP> <VPS2_BACKHAUL_IP> | $0 singbox <VLESS_PORT> <REALITY_SERVER_NAME> | $0 snapshot|restore <seg-gateway|seg-exit> <BACKHAUL_INTERFACE> | $0 snapshot-drop"

[[ $# -ge 1 ]] || die "$USAGE"

STAGE="$1"
STAGING_DIR="/root/.seg-sync"
BACKUP_DIR="$(mktemp -d /root/.seg-backup.XXXXXX)"
ROLLBACK_ACTION=""
CLEANUP_FILES=()

on_exit()
{
    local exit_code=$?

    if [[ "$exit_code" -ne 0 && -n "$ROLLBACK_ACTION" ]]; then
        log WARN "Stage $STAGE failed; restoring the previous state."
        trap - ERR
        "$ROLLBACK_ACTION" || log ERROR "Rollback of stage $STAGE failed; check the node manually."
    fi

    rm -rf "$BACKUP_DIR"

    if [[ "${#CLEANUP_FILES[@]}" -gt 0 ]]; then
        rm -f "${CLEANUP_FILES[@]}"
    fi

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

# ------------------------------------------------------------
# Stage backhaul (both roles, items 16 and 17)
# ------------------------------------------------------------
# Installs /etc/amnezia/amneziawg/<interface>.conf and keeps awg-quick@<interface> running with it.
# The configuration holds the backhaul private key and the PSK: it is never printed.

BH_INTERFACE=""
BH_DST=""
BH_WAS_ACTIVE=0
BH_WAS_ENABLED=0

bh_config_value()
{
    # bh_config_value <file> <key>: first value of "Key = value" (the [Interface] section comes first).
    sed -nE "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*([^[:space:]#]+).*$/\1/p" "$1" | head -n1
}

backhaul_state_ok()
{
    # Compares the running interface with the installed configuration. Prints the first mismatch.
    local file="$1" interface="$2" mtu="$3"
    local address listen_port peer_key actual

    ip link show "$interface" >/dev/null 2>&1 || { echo "interface $interface does not exist"; return 1; }

    ip link show "$interface" | head -n1 | grep -Eq '<[^>]*\bUP\b' || { echo "interface $interface is not up"; return 1; }

    actual="$(cat "/sys/class/net/${interface}/mtu")"
    [[ "$actual" == "$mtu" ]] || { echo "MTU is $actual, expected $mtu"; return 1; }

    address="$(bh_config_value "$file" Address)"
    ip -4 addr show dev "$interface" | grep -Fq "inet ${address}" || { echo "address $address is not set"; return 1; }

    listen_port="$(bh_config_value "$file" ListenPort)"

    if [[ -n "$listen_port" ]]; then
        actual="$(awg show "$interface" listen-port)"
        [[ "$actual" == "$listen_port" ]] || { echo "listen port is $actual, expected $listen_port"; return 1; }
    fi

    peer_key="$(bh_config_value "$file" PublicKey)"
    actual="$(awg show "$interface" peers)"
    [[ "$actual" == "$peer_key" ]] || { echo "the peer public key differs from the configuration"; return 1; }

    actual="$(ip -4 route show dev "$interface" | grep -vc 'proto kernel' || true)"
    [[ "$actual" == "0" ]] || { echo "the interface holds routes besides its own subnet"; return 1; }

    return 0
}

rollback_backhaul()
{
    restore_file "$BH_DST"

    if [[ -f "$BH_DST" ]]; then
        chmod 600 "$BH_DST"

        if [[ "$BH_WAS_ACTIVE" == "1" ]]; then
            systemctl restart "awg-quick@${BH_INTERFACE}.service" || true
        fi
    else
        systemctl disable --now "awg-quick@${BH_INTERFACE}.service" >/dev/null 2>&1 || true
        systemctl reset-failed "awg-quick@${BH_INTERFACE}.service" >/dev/null 2>&1 || true
    fi
}

stage_backhaul()
{
    local interface="$1"
    local mtu="$2"
    local source="${STAGING_DIR}/${interface}.conf"
    local unit="awg-quick@${interface}.service"

    [[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid backhaul interface: $interface"
    [[ "$mtu" =~ ^[0-9]+$ ]] && (( mtu >= 576 && mtu <= 1500 )) || die "Invalid backhaul MTU: $mtu"

    BH_INTERFACE="$interface"
    BH_DST="/etc/amnezia/amneziawg/${interface}.conf"

    [[ -f "$source" ]] || die "$source not found"

    # The candidate is removed on any exit (see on_exit): it contains secrets.
    CLEANUP_FILES+=("$source")

    check_unresolved "$source"
    log OK "No unresolved template variables found."

    grep -Eq '^[[:space:]]*Table[[:space:]]*=[[:space:]]*off[[:space:]]*$' "$source" || die "The candidate must set Table = off"
    ! grep -Eqi '^[[:space:]]*(PostUp|PostDown|PreUp|PreDown|DNS|SaveConfig)[[:space:]]*=' "$source" || \
        die "The candidate must not contain PostUp, PostDown, PreUp, PreDown, DNS or SaveConfig"
    [[ "$(bh_config_value "$source" MTU)" == "$mtu" ]] || die "MTU in the candidate differs from $mtu"

    # awg-quick strip parses the configuration without touching the system.
    awg-quick strip "$source" >/dev/null
    log OK "Backhaul candidate parsed (awg-quick strip)."

    systemctl is-active --quiet "$unit" && BH_WAS_ACTIVE=1 || true
    systemctl is-enabled --quiet "$unit" 2>/dev/null && BH_WAS_ENABLED=1 || true

    if same_file "$source" "$BH_DST" &&
       [[ "$BH_WAS_ACTIVE" == "1" && "$BH_WAS_ENABLED" == "1" ]] &&
       backhaul_state_ok "$BH_DST" "$interface" "$mtu" >/dev/null; then
        log OK "Backhaul $interface is already current."
        ensure_keepalive
        return 0
    fi

    backup_file "$BH_DST"
    ROLLBACK_ACTION=rollback_backhaul

    install -d -o root -g root -m 700 /etc/amnezia/amneziawg
    install -o root -g root -m 600 "$source" "$BH_DST"
    systemctl daemon-reload
    systemctl enable "$unit" >/dev/null

    # awg-quick has no reload: a changed configuration needs a restart of the interface.
    if [[ "$BH_WAS_ACTIVE" == "1" ]]; then
        log INFO "Restarting $unit."
        systemctl restart "$unit"
    else
        systemctl start "$unit"
    fi

    systemctl is-active --quiet "$unit" || die "$unit is not active"

    local problem
    problem="$(backhaul_state_ok "$BH_DST" "$interface" "$mtu" || true)"
    [[ -z "$problem" ]] || die "Backhaul check failed: $problem"

    # The keepalive unit exists only on seg-exit; it needs the running backhaul.
    ensure_keepalive

    ROLLBACK_ACTION=""
    log OK "Backhaul $interface installed and verified."
}

# ------------------------------------------------------------
# Stage egress (seg-exit, item 17)
# ------------------------------------------------------------
# Firewall and NAT (nftables), the DNS resolver on the backhaul address and the keepalive unit.
# The keepalive unit is enabled here and started by the backhaul stage (it requires the interface).

EG_FILES=(
    "seg-exit.nft:/etc/seg/seg-exit.nft"
    "seg-exit-fw.service:/etc/systemd/system/seg-exit-fw.service"
    "seg-exit-keepalive.service:/etc/systemd/system/seg-exit-keepalive.service"
    "unbound-seg.conf:/etc/unbound/unbound.conf.d/seg.conf"
)

EG_WAS_FW_ACTIVE=0
EG_WAS_UNBOUND_ACTIVE=0
EG_WAS_FW_ENABLED=0

ensure_keepalive()
{
    if [[ -f /etc/systemd/system/seg-exit-keepalive.service ]]; then
        systemctl enable --now seg-exit-keepalive.service >/dev/null
        systemctl is-active --quiet seg-exit-keepalive.service || die "seg-exit-keepalive.service is not active"
        log OK "seg-exit-keepalive.service is active."
    fi
}

egress_state_ok()
{
    # egress_state_ok <interface> <vps1 backhaul ip> <vps2 backhaul ip>: prints the first mismatch.
    local interface="$1" vps1="$2" vps2="$3"
    local unit listing

    for unit in seg-exit-fw.service seg-exit-keepalive.service unbound.service; do
        systemctl is-enabled --quiet "$unit" 2>/dev/null || { echo "$unit is not enabled"; return 1; }
    done

    for unit in seg-exit-fw.service unbound.service; do
        systemctl is-active --quiet "$unit" || { echo "$unit is not active"; return 1; }
    done

    listing="$(nft list table inet seg_exit 2>/dev/null)" || { echo "table seg_exit is missing"; return 1; }

    grep -Fq "ip saddr ${vps2} ip daddr ${vps1} udp dport 53 accept" <<<"$listing" || { echo "the DNS udp rule is missing"; return 1; }
    grep -Fq "ip saddr ${vps2} ip daddr ${vps1} tcp dport 53 accept" <<<"$listing" || { echo "the DNS tcp rule is missing"; return 1; }
    grep -Fq "iifname \"${interface}\" meta nfproto ipv6 counter" <<<"$listing" || { echo "the IPv6 drop rule is missing"; return 1; }

    listing="$(nft list table ip seg_exit_nat 2>/dev/null)" || { echo "table seg_exit_nat is missing"; return 1; }

    grep -Fq "ip saddr ${vps2} oifname != \"${interface}\" masquerade" <<<"$listing" || { echo "the masquerade rule is missing"; return 1; }

    ss -H -lnu 'sport = :53' | grep -Fq "${vps1}:53" || { echo "unbound does not listen on ${vps1}:53 (udp)"; return 1; }
    ss -H -lnt 'sport = :53' | grep -Fq "${vps1}:53" || { echo "unbound does not listen on ${vps1}:53 (tcp)"; return 1; }

    [[ "$(sysctl -n net.ipv4.ip_forward)" == "1" ]] || { echo "IPv4 forwarding is off"; return 1; }

    return 0
}

rollback_egress()
{
    local pair destination

    for pair in "${EG_FILES[@]}"; do
        restore_file "${pair#*:}"
    done

    systemctl daemon-reload

    if [[ -f /etc/seg/seg-exit.nft && -f /etc/systemd/system/seg-exit-fw.service ]]; then
        # Previous version: load it again, never leave the node without the firewall.
        nft -f /etc/seg/seg-exit.nft
    else
        systemctl disable --now seg-exit-fw.service >/dev/null 2>&1 || true
        nft delete table inet seg_exit >/dev/null 2>&1 || true
        nft delete table ip seg_exit_nat >/dev/null 2>&1 || true
        systemctl disable seg-exit-keepalive.service >/dev/null 2>&1 || true
    fi

    if [[ "$EG_WAS_UNBOUND_ACTIVE" == "1" ]]; then
        systemctl restart unbound.service || true
    fi
}

stage_egress()
{
    local interface="$1" vps1="$2" vps2="$3"
    local pair source destination changed=0

    [[ "$interface" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid backhaul interface: $interface"

    local address
    for address in "$vps1" "$vps2"; do
        [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Invalid backhaul address: $address"
    done

    for pair in "${EG_FILES[@]}"; do
        source="${STAGING_DIR}/${pair%%:*}"

        [[ -f "$source" ]] || die "$source not found"
        check_unresolved "$source"
    done

    log OK "No unresolved template variables found."

    [[ -s /var/lib/unbound/root.key ]] || die "/var/lib/unbound/root.key is missing (bootstrap-seg.sh prepares it)"

    nft -c -f "${STAGING_DIR}/seg-exit.nft"
    log OK "nftables candidate validated (nft -c)."

    unbound-checkconf "${STAGING_DIR}/unbound-seg.conf" >/dev/null
    log OK "unbound candidate validated (unbound-checkconf)."

    systemctl is-active --quiet seg-exit-fw.service && EG_WAS_FW_ACTIVE=1 || true
    systemctl is-enabled --quiet seg-exit-fw.service 2>/dev/null && EG_WAS_FW_ENABLED=1 || true
    systemctl is-active --quiet unbound.service && EG_WAS_UNBOUND_ACTIVE=1 || true

    for pair in "${EG_FILES[@]}"; do
        same_file "${STAGING_DIR}/${pair%%:*}" "${pair#*:}" || changed=1
    done

    if [[ "$changed" == "0" ]] && egress_state_ok "$interface" "$vps1" "$vps2" >/dev/null; then
        log OK "Egress configuration is already current."

        for pair in "${EG_FILES[@]}"; do
            rm -f "${STAGING_DIR}/${pair%%:*}"
        done

        return 0
    fi

    for pair in "${EG_FILES[@]}"; do
        backup_file "${pair#*:}"
    done

    ROLLBACK_ACTION=rollback_egress

    install -d -o root -g root -m 755 /etc/seg /etc/unbound/unbound.conf.d

    for pair in "${EG_FILES[@]}"; do
        install -o root -g root -m 644 "${STAGING_DIR}/${pair%%:*}" "${pair#*:}"
    done

    # The firewall is loaded first, so the DNS resolver and the backhaul never run without it.
    systemctl daemon-reload
    systemctl enable seg-exit-fw.service seg-exit-keepalive.service unbound.service >/dev/null

    # reload replaces both tables in one nftables transaction; restart would delete them first (ExecStop).
    if [[ "$EG_WAS_FW_ACTIVE" == "1" ]]; then
        systemctl reload seg-exit-fw.service
    else
        systemctl start seg-exit-fw.service
    fi

    sysctl -q -w net.ipv4.ip_forward=1

    if [[ "$EG_WAS_UNBOUND_ACTIVE" == "1" ]]; then
        systemctl restart unbound.service
    else
        systemctl start unbound.service
    fi

    local problem
    problem="$(egress_state_ok "$interface" "$vps1" "$vps2" || true)"
    [[ -z "$problem" ]] || die "Egress check failed: $problem"

    ROLLBACK_ACTION=""

    for pair in "${EG_FILES[@]}"; do
        rm -f "${STAGING_DIR}/${pair%%:*}"
    done

    log OK "Egress (firewall, NAT, DNS) installed and verified."
}

# ------------------------------------------------------------
# Stage singbox (seg-gateway, items 19 and 20)
# ------------------------------------------------------------
# sing-box with VLESS/REALITY and the server-side routing. The configuration holds the REALITY private
# key and the client UUIDs: root:sing-box 640, never printed. When the first installation fails sing-box
# stays stopped (fail-closed is not touched); a failed update restores the previous configuration.

SB_CONFIG_SRC="${STAGING_DIR}/sing-box-config.json"
SB_UNIT_SRC="${STAGING_DIR}/sing-box.service"
SB_CONFIG_DST="/etc/sing-box/config.json"
SB_UNIT_DST="/etc/systemd/system/sing-box.service"
SB_WAS_ACTIVE=0
SB_WAS_ENABLED=0
SB_WAS_INSTALLED=0

singbox_state_ok()
{
    # singbox_state_ok <port> <server name>: prints the first mismatch.
    local port="$1" server_name="$2"
    local deadline=$(( SECONDS + 15 ))

    systemctl is-enabled --quiet sing-box.service 2>/dev/null || { echo "sing-box.service is not enabled"; return 1; }
    systemctl is-active --quiet sing-box.service || { echo "sing-box.service is not active"; return 1; }

    until ss -H -lnt "sport = :${port}" | grep -q .; do
        (( SECONDS < deadline )) || { echo "nothing listens on tcp ${port}"; return 1; }
        sleep 1
    done

    [[ "$(ps -o user= -p "$(systemctl show -p MainPID --value sing-box.service)" | tr -d ' ')" == "sing-box" ]] || { echo "sing-box does not run as the user sing-box"; return 1; }

    # An unauthenticated connection is passed by REALITY to the handshake server: the answer must be a real
    # certificate for the configured server name.
    echo | timeout 10 openssl s_client -connect "127.0.0.1:${port}" -servername "$server_name" 2>/dev/null |
        grep -q 'BEGIN CERTIFICATE' || { echo "REALITY did not pass the unauthenticated handshake to ${server_name}"; return 1; }

    return 0
}

rollback_singbox()
{
    if [[ "$SB_WAS_INSTALLED" == "0" ]]; then
        # First installation: sing-box stays stopped and disabled. It is stopped while its unit file
        # still exists; afterwards the candidate files are removed.
        systemctl disable --now sing-box.service >/dev/null 2>&1 || true
        restore_file "$SB_CONFIG_DST"
        restore_file "$SB_UNIT_DST"
        systemctl daemon-reload
        systemctl reset-failed sing-box.service >/dev/null 2>&1 || true
        return 0
    fi

    restore_file "$SB_CONFIG_DST"
    restore_file "$SB_UNIT_DST"
    systemctl daemon-reload

    chown root:sing-box "$SB_CONFIG_DST"
    chmod 640 "$SB_CONFIG_DST"

    if [[ "$SB_WAS_ACTIVE" == "1" ]]; then
        systemctl restart sing-box.service || true
    fi
}

stage_singbox()
{
    local port="$1" server_name="$2"

    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) || die "Invalid VLESS port: $port"
    [[ "$server_name" =~ ^[A-Za-z0-9.-]{1,253}$ ]] || die "Invalid REALITY server name: $server_name"

    [[ -f "$SB_CONFIG_SRC" ]] || die "$SB_CONFIG_SRC not found"
    [[ -f "$SB_UNIT_SRC" ]] || die "$SB_UNIT_SRC not found"

    # The candidate holds secrets: removed on any exit (see on_exit).
    CLEANUP_FILES+=("$SB_CONFIG_SRC" "$SB_UNIT_SRC")

    check_unresolved "$SB_CONFIG_SRC"
    check_unresolved "$SB_UNIT_SRC"
    log OK "No unresolved template variables found."

    [[ -x /usr/local/bin/sing-box ]] || die "/usr/local/bin/sing-box is missing (bootstrap-seg.sh installs it)"
    id sing-box >/dev/null 2>&1 || die "The user sing-box is missing (bootstrap-seg.sh creates it)"

    # sing-box is never started without fail-closed.
    systemctl is-active --quiet seg-failclosed.service || die "seg-failclosed.service is not active"
    nft list table inet seg_failclosed >/dev/null || die "Table seg_failclosed is missing"

    # The check runs with the Linux binary: routing_mark is accepted only there.
    /usr/local/bin/sing-box check -c "$SB_CONFIG_SRC" || die "sing-box check rejected the candidate"
    log OK "sing-box configuration candidate validated (sing-box check)."

    systemctl is-active --quiet sing-box.service && SB_WAS_ACTIVE=1 || true
    systemctl is-enabled --quiet sing-box.service 2>/dev/null && SB_WAS_ENABLED=1 || true
    [[ -f "$SB_CONFIG_DST" && -f "$SB_UNIT_DST" ]] && SB_WAS_INSTALLED=1 || true

    if same_file "$SB_CONFIG_SRC" "$SB_CONFIG_DST" &&
       same_file "$SB_UNIT_SRC" "$SB_UNIT_DST" &&
       [[ "$SB_WAS_ACTIVE" == "1" && "$SB_WAS_ENABLED" == "1" ]] &&
       singbox_state_ok "$port" "$server_name" >/dev/null; then
        log OK "sing-box is already current."
        return 0
    fi

    backup_file "$SB_CONFIG_DST"
    backup_file "$SB_UNIT_DST"
    ROLLBACK_ACTION=rollback_singbox

    install -d -o root -g sing-box -m 750 /etc/sing-box
    install -o root -g sing-box -m 640 "$SB_CONFIG_SRC" "$SB_CONFIG_DST"
    install -o root -g root -m 644 "$SB_UNIT_SRC" "$SB_UNIT_DST"
    systemctl daemon-reload
    systemctl enable sing-box.service >/dev/null

    # sing-box applies a configuration only at start: a changed one needs a restart (connections reconnect).
    if [[ "$SB_WAS_ACTIVE" == "1" ]]; then
        log INFO "Restarting sing-box."
        systemctl restart sing-box.service
    else
        systemctl start sing-box.service
    fi

    local problem
    problem="$(singbox_state_ok "$port" "$server_name" || true)"
    [[ -z "$problem" ]] || die "sing-box check failed: $problem"

    ROLLBACK_ACTION=""
    log OK "sing-box installed and verified."
}

# ------------------------------------------------------------
# Snapshot and restore of the whole node configuration (roadmap, item 28)
# ------------------------------------------------------------
# The snapshot is taken before the first change of a run and restored when a later stage fails: the node returns
# to the working state it had before the run. Fail-closed is never weakened: when the node had none before, the
# new fail-closed stays. A node that had no sing-box before is left with sing-box stopped and disabled.
# The snapshot holds secrets (backhaul keys, REALITY key): root only, removed after a successful restore or run.

SNAP_DIR="/root/.seg-snapshot"

snapshot_files()
{
    # snapshot_files <role> <interface>
    if [[ "$1" == "seg-gateway" ]]; then
        printf '%s\n' \
            /etc/seg/seg-failclosed.nft \
            /etc/systemd/system/seg-failclosed.service \
            "/etc/amnezia/amneziawg/${2}.conf" \
            /etc/sing-box/config.json \
            /etc/systemd/system/sing-box.service \
            /etc/sysctl.d/90-seg-rp-filter.conf
    else
        printf '%s\n' \
            /etc/seg/seg-exit.nft \
            /etc/systemd/system/seg-exit-fw.service \
            /etc/systemd/system/seg-exit-keepalive.service \
            /etc/unbound/unbound.conf.d/seg.conf \
            "/etc/amnezia/amneziawg/${2}.conf"
    fi
}

snapshot_units()
{
    if [[ "$1" == "seg-gateway" ]]; then
        printf '%s\n' seg-failclosed.service "awg-quick@${2}.service" sing-box.service
    else
        printf '%s\n' seg-exit-fw.service "awg-quick@${2}.service" seg-exit-keepalive.service unbound.service
    fi
}

check_role_and_interface()
{
    [[ "$1" == "seg-gateway" || "$1" == "seg-exit" ]] || die "Invalid role: $1"
    [[ "$2" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid backhaul interface: $2"
}

stage_snapshot()
{
    local role="$1" interface="$2" file unit

    check_role_and_interface "$role" "$interface"

    # Only the latest snapshot is kept: an earlier one belongs to an aborted run.
    rm -rf "$SNAP_DIR"
    install -d -o root -g root -m 700 "$SNAP_DIR" "$SNAP_DIR/files"

    {
        echo "role ${role}"
        echo "interface ${interface}"
        echo "taken $(date '+%Y-%m-%d %H:%M:%S')"
    } >"$SNAP_DIR/manifest"

    while IFS= read -r file; do
        if [[ -f "$file" ]]; then
            mkdir -p "$SNAP_DIR/files$(dirname "$file")"
            cp -a "$file" "$SNAP_DIR/files$file"
            echo "present ${file}" >>"$SNAP_DIR/manifest"
            echo "meta ${file} $(stat -c '%a %U:%G' "$file")" >>"$SNAP_DIR/manifest"
        else
            echo "absent ${file}" >>"$SNAP_DIR/manifest"
        fi
    done < <(snapshot_files "$role" "$interface")

    while IFS= read -r unit; do
        local active=0 enabled=0

        systemctl is-active --quiet "$unit" 2>/dev/null && active=1 || true
        systemctl is-enabled --quiet "$unit" 2>/dev/null && enabled=1 || true
        echo "unit ${unit} active=${active} enabled=${enabled}" >>"$SNAP_DIR/manifest"
    done < <(snapshot_units "$role" "$interface")

    # The directory is 700 root: the copies keep the mode and the owner of the originals (cp -a), which the
    # restore needs (for example the sing-box user reads its configuration through the group).
    log OK "Snapshot of $(grep -c '^present ' "$SNAP_DIR/manifest") file(s) and $(grep -c '^unit ' "$SNAP_DIR/manifest") unit state(s) taken."
}

snap_present()
{
    grep -Fxq "present $1" "$SNAP_DIR/manifest"
}

snap_meta()
{
    # snap_meta <file>: the recorded "<mode> <owner>:<group>"
    local line
    line="$(grep -F "meta $1 " "$SNAP_DIR/manifest" | head -n1 || true)"
    printf '%s\n' "${line#meta $1 }"
}

snap_unit_flag()
{
    # snap_unit_flag <unit> <active|enabled>: prints 1 or 0 (nothing when the unit is not in the snapshot)
    local line
    line="$(grep -F "unit $1 " "$SNAP_DIR/manifest" | head -n1 || true)"

    if [[ "$2" == "active" ]]; then
        sed -nE 's/.* active=([01]) .*/\1/p' <<<"$line"
    else
        sed -nE 's/.* enabled=([01])$/\1/p' <<<"$line"
    fi
}

stage_restore()
{
    local role="$1" interface="$2" file unit

    check_role_and_interface "$role" "$interface"

    [[ -f "$SNAP_DIR/manifest" ]] || die "There is no snapshot to restore ($SNAP_DIR)"
    grep -Fxq "role ${role}" "$SNAP_DIR/manifest" || die "The snapshot belongs to another role"
    grep -Fxq "interface ${interface}" "$SNAP_DIR/manifest" || die "The snapshot belongs to another interface"

    log INFO "Restoring the node to the snapshot: $(grep '^taken ' "$SNAP_DIR/manifest")"

    local backhaul_conf="/etc/amnezia/amneziawg/${interface}.conf"
    local backhaul_unit="awg-quick@${interface}.service"
    local backhaul_changed=0 singbox_changed=0 unbound_changed=0

    # What differs from the snapshot decides which services need a restart.
    if snap_present "$backhaul_conf"; then
        cmp -s "$SNAP_DIR/files$backhaul_conf" "$backhaul_conf" || backhaul_changed=1
    else
        backhaul_changed=1
    fi

    if [[ "$role" == "seg-gateway" ]]; then
        snap_present /etc/sing-box/config.json && cmp -s "$SNAP_DIR/files/etc/sing-box/config.json" /etc/sing-box/config.json &&
            snap_present /etc/systemd/system/sing-box.service && cmp -s "$SNAP_DIR/files/etc/systemd/system/sing-box.service" /etc/systemd/system/sing-box.service || singbox_changed=1

        # A node that had no sing-box: stopped and disabled before its files are removed.
        if ! snap_present /etc/sing-box/config.json || ! snap_present /etc/systemd/system/sing-box.service; then
            systemctl disable --now sing-box.service >/dev/null 2>&1 || true
        fi
    else
        snap_present /etc/unbound/unbound.conf.d/seg.conf && cmp -s "$SNAP_DIR/files/etc/unbound/unbound.conf.d/seg.conf" /etc/unbound/unbound.conf.d/seg.conf || unbound_changed=1

        if ! snap_present /etc/systemd/system/seg-exit-keepalive.service; then
            systemctl disable --now seg-exit-keepalive.service >/dev/null 2>&1 || true
        fi

        if ! snap_present /etc/systemd/system/seg-exit-fw.service; then
            systemctl disable --now seg-exit-fw.service >/dev/null 2>&1 || true
            nft delete table inet seg_exit >/dev/null 2>&1 || true
            nft delete table ip seg_exit_nat >/dev/null 2>&1 || true
        fi
    fi

    if ! snap_present "$backhaul_conf"; then
        systemctl disable --now "$backhaul_unit" >/dev/null 2>&1 || true
    fi

    # Files: the previous content comes back, a file that did not exist is removed. Fail-closed is the exception:
    # a node that had none keeps the new one (the restore never weakens it).
    while IFS= read -r file; do
        if snap_present "$file"; then
            mkdir -p "$(dirname "$file")"
            cp -a "$SNAP_DIR/files$file" "$file"

            # The recorded mode and owner are applied explicitly as well.
            read -r meta_mode meta_owner <<<"$(snap_meta "$file")"
            [[ -z "${meta_mode:-}" ]] || chmod "$meta_mode" "$file"
            [[ -z "${meta_owner:-}" ]] || chown "$meta_owner" "$file"
        elif [[ "$file" != /etc/seg/seg-failclosed.nft && "$file" != /etc/systemd/system/seg-failclosed.service ]]; then
            rm -f "$file"
        fi
    done < <(snapshot_files "$role" "$interface")

    systemctl daemon-reload

    # Enabled flags of the units that existed
    while IFS= read -r unit; do
        if [[ "$(snap_unit_flag "$unit" enabled)" == "1" ]]; then
            systemctl enable "$unit" >/dev/null 2>&1 || true
        elif [[ -f "/etc/systemd/system/${unit}" ]] && snap_present "/etc/systemd/system/${unit}"; then
            systemctl disable "$unit" >/dev/null 2>&1 || true
        fi
    done < <(snapshot_units "$role" "$interface")

    if [[ "$role" == "seg-gateway" ]]; then
        # Fail-closed: the previous table is loaded again in one transaction; a node that had none keeps the new one.
        if snap_present /etc/seg/seg-failclosed.nft && snap_present /etc/systemd/system/seg-failclosed.service; then
            if systemctl is-active --quiet seg-failclosed.service; then
                systemctl reload seg-failclosed.service
            else
                systemctl start seg-failclosed.service
            fi
        fi
    fi

    if snap_present "$backhaul_conf"; then
        if [[ "$(snap_unit_flag "$backhaul_unit" active)" == "1" ]]; then
            if [[ "$backhaul_changed" == "1" ]] || ! systemctl is-active --quiet "$backhaul_unit"; then
                systemctl restart "$backhaul_unit"
            fi
        fi
    fi

    if [[ "$role" == "seg-gateway" ]]; then
        if snap_present /etc/sing-box/config.json && snap_present /etc/systemd/system/sing-box.service; then
            if [[ "$(snap_unit_flag sing-box.service active)" == "1" ]]; then
                if [[ "$singbox_changed" == "1" ]] || ! systemctl is-active --quiet sing-box.service; then
                    systemctl restart sing-box.service
                fi
            else
                systemctl stop sing-box.service >/dev/null 2>&1 || true
            fi
        fi
    else
        if snap_present /etc/systemd/system/seg-exit-fw.service; then
            if [[ "$(snap_unit_flag seg-exit-fw.service active)" == "1" ]]; then
                if systemctl is-active --quiet seg-exit-fw.service; then
                    systemctl reload seg-exit-fw.service
                else
                    systemctl start seg-exit-fw.service
                fi
            fi
        fi

        if [[ "$unbound_changed" == "1" ]]; then
            systemctl restart unbound.service || true
        fi

        if snap_present /etc/systemd/system/seg-exit-keepalive.service && [[ "$(snap_unit_flag seg-exit-keepalive.service active)" == "1" ]]; then
            systemctl enable --now seg-exit-keepalive.service >/dev/null
        fi
    fi

    # Verification: the files and the services are as they were.
    local problems=()

    while IFS= read -r file; do
        if snap_present "$file"; then
            cmp -s "$SNAP_DIR/files$file" "$file" || problems+=("${file}:differs")
            [[ "$(stat -c '%a %U:%G' "$file" 2>/dev/null)" == "$(snap_meta "$file")" ]] || problems+=("${file}:mode-or-owner-differs")
        elif [[ "$file" != /etc/seg/seg-failclosed.nft && "$file" != /etc/systemd/system/seg-failclosed.service && -e "$file" ]]; then
            problems+=("${file}:should-not-exist")
        fi
    done < <(snapshot_files "$role" "$interface")

    while IFS= read -r unit; do
        local was_active
        was_active="$(snap_unit_flag "$unit" active)"

        [[ -n "$was_active" ]] || continue

        if [[ "$was_active" == "1" ]]; then
            systemctl is-active --quiet "$unit" || problems+=("${unit}:not-active")
        elif [[ "$unit" == "sing-box.service" || "$unit" == "seg-exit-keepalive.service" ]]; then
            ! systemctl is-active --quiet "$unit" || problems+=("${unit}:should-be-stopped")
        fi
    done < <(snapshot_units "$role" "$interface")

    if [[ "$role" == "seg-gateway" ]]; then
        nft list table inet seg_failclosed >/dev/null 2>&1 || problems+=("fail-closed-table-missing")
    fi

    if [[ "${#problems[@]}" -gt 0 ]]; then
        log ERROR "The restore is not complete: ${problems[*]}. The snapshot is kept in $SNAP_DIR." >&2
        exit 1
    fi

    rm -rf "$SNAP_DIR"
    log OK "The node is restored to the state before the run."
}

stage_snapshot_drop()
{
    rm -rf "$SNAP_DIR"
    log OK "The snapshot is removed."
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
    backhaul)
        [[ $# -eq 3 ]] || die "$USAGE"
        stage_backhaul "$2" "$3"
        ;;
    egress)
        [[ $# -eq 4 ]] || die "$USAGE"
        stage_egress "$2" "$3" "$4"
        ;;
    snapshot)
        [[ $# -eq 3 ]] || die "$USAGE"
        stage_snapshot "$2" "$3"
        ;;
    restore)
        [[ $# -eq 3 ]] || die "$USAGE"
        stage_restore "$2" "$3"
        ;;
    snapshot-drop)
        [[ $# -eq 1 ]] || die "$USAGE"
        stage_snapshot_drop
        ;;
    singbox)
        [[ $# -eq 3 ]] || die "$USAGE"
        stage_singbox "$2" "$3"
        ;;
    *)
        die "Unknown stage: $STAGE. $USAGE"
        ;;
esac

log OK "APPLY_SEG_OK stage=$STAGE"
log DONE "Script completed successfully."
