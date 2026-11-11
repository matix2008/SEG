#!/usr/bin/env bash
# SEG node state check (roadmap, item 26). Read-only: it changes nothing on the node.
# sync-servers.ps1 -Mode SEG -Check runs it through ssh without uploading it and compares the answers
# with the local source of truth.
#
#   check-node.sh seg-gateway <VLESS_PORT> <BACKHAUL_PORT> <VPS1_PUBLIC_IP> <BACKHAUL_INTERFACE> <SING_BOX_VERSION>
#   check-node.sh seg-exit <BACKHAUL_INTERFACE> <VPS1_BACKHAUL_IP> <VPS2_BACKHAUL_IP>
#
# Prints "CHECK NAME=value" lines; it never fails on a bad node state (the lines tell), only on bad arguments.
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

USAGE="Usage: $0 seg-gateway <VLESS_PORT> <BACKHAUL_PORT> <VPS1_PUBLIC_IP> <BACKHAUL_INTERFACE> <SING_BOX_VERSION> | $0 seg-exit <BACKHAUL_INTERFACE> <VPS1_BACKHAUL_IP> <VPS2_BACKHAUL_IP>"

is_ipv4()
{
    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]
}

[[ $# -ge 1 ]] || die "$USAGE"

ROLE="$1"

case "$ROLE" in
    seg-gateway)
        [[ $# -eq 6 ]] || die "$USAGE"
        VLESS_PORT="$2"
        BACKHAUL_PORT="$3"
        VPS1_PUBLIC_IP="$4"
        INTERFACE="$5"
        SING_BOX_VERSION="$6"

        [[ "$VLESS_PORT" =~ ^[0-9]{1,5}$ && "$BACKHAUL_PORT" =~ ^[0-9]{1,5}$ ]] || die "Invalid port"
        is_ipv4 "$VPS1_PUBLIC_IP" || die "Invalid VPS1 public IP"
        [[ "$SING_BOX_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "Invalid sing-box version"
        ;;
    seg-exit)
        [[ $# -eq 4 ]] || die "$USAGE"
        INTERFACE="$2"
        VPS1_BACKHAUL="$3"
        VPS2_BACKHAUL="$4"

        is_ipv4 "$VPS1_BACKHAUL" && is_ipv4 "$VPS2_BACKHAUL" || die "Invalid backhaul address"
        ;;
    *)
        die "$USAGE"
        ;;
esac

[[ "$INTERFACE" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid interface: $INTERFACE"

# ------------------------------------------------------------
# Base state
# ------------------------------------------------------------

# shellcheck disable=SC1091
source /etc/os-release
echo "CHECK OS=${ID:-unknown} ${VERSION_ID:-unknown}"
echo "CHECK KERNEL=$(uname -r)"

if [[ -f /var/run/reboot-required ]]; then
    echo "CHECK REBOOT_REQUIRED=yes"
else
    echo "CHECK REBOOT_REQUIRED=no"
fi

# ------------------------------------------------------------
# Software installed by bootstrap-seg.sh
# ------------------------------------------------------------

missing=()

command -v awg >/dev/null 2>&1 || missing+=("awg")
command -v awg-quick >/dev/null 2>&1 || missing+=("awg-quick")
command -v nft >/dev/null 2>&1 || missing+=("nft")
modinfo amneziawg >/dev/null 2>&1 || missing+=("amneziawg-module")

if [[ "$ROLE" == "seg-gateway" ]]; then
    installed="$(/usr/local/bin/sing-box version 2>/dev/null | sed -n '1s/^sing-box version //p' || true)"

    [[ "$installed" == "$SING_BOX_VERSION" ]] || missing+=("sing-box-${SING_BOX_VERSION}(installed:${installed:-none})")
    id sing-box >/dev/null 2>&1 || missing+=("user-sing-box")
else
    command -v unbound >/dev/null 2>&1 || missing+=("unbound")
    [[ -s /var/lib/unbound/root.key ]] || missing+=("unbound-root.key")
fi

if [[ "${#missing[@]}" -eq 0 ]]; then
    echo "CHECK PACKAGES=OK"
else
    echo "CHECK PACKAGES=MISSING ${missing[*]}"
fi

# ------------------------------------------------------------
# Files managed by sync-servers.ps1: SHA-256 (the content is never printed)
# ------------------------------------------------------------

if [[ "$ROLE" == "seg-gateway" ]]; then
    files=(
        /etc/seg/seg-failclosed.nft
        /etc/systemd/system/seg-failclosed.service
        "/etc/amnezia/amneziawg/${INTERFACE}.conf"
        /etc/sing-box/config.json
        /etc/systemd/system/sing-box.service
    )
else
    files=(
        /etc/seg/seg-exit.nft
        /etc/systemd/system/seg-exit-fw.service
        /etc/systemd/system/seg-exit-keepalive.service
        /etc/unbound/unbound.conf.d/seg.conf
        "/etc/amnezia/amneziawg/${INTERFACE}.conf"
    )
fi

for file in "${files[@]}"; do
    if [[ -f "$file" ]]; then
        echo "CHECK FILE ${file}=$(sha256sum "$file" | cut -d' ' -f1)"
    else
        echo "CHECK FILE ${file}=MISSING"
    fi
done

# ------------------------------------------------------------
# Services: every unit of the role must be enabled and active
# ------------------------------------------------------------

if [[ "$ROLE" == "seg-gateway" ]]; then
    units=(seg-failclosed.service "awg-quick@${INTERFACE}.service" sing-box.service)
else
    units=(seg-exit-fw.service "awg-quick@${INTERFACE}.service" seg-exit-keepalive.service unbound.service)
fi

bad=()

for unit in "${units[@]}"; do
    systemctl is-enabled --quiet "$unit" 2>/dev/null || bad+=("${unit}:not-enabled")
    systemctl is-active --quiet "$unit" 2>/dev/null || bad+=("${unit}:not-active")
done

# A running sing-box keeps the file it was started from: after a new version is installed it must be restarted.
if [[ "$ROLE" == "seg-gateway" ]] && systemctl is-active --quiet sing-box.service 2>/dev/null; then
    sb_pid="$(systemctl show -p MainPID --value sing-box.service 2>/dev/null || true)"

    if [[ "$sb_pid" =~ ^[0-9]+$ ]] && (( sb_pid > 0 )) &&
       [[ "$(stat -L -c '%d:%i' "/proc/${sb_pid}/exe" 2>/dev/null)" != "$(stat -c '%d:%i' /usr/local/bin/sing-box 2>/dev/null)" ]]; then
        bad+=("sing-box.service:old-binary")
    fi
fi

if [[ "${#bad[@]}" -eq 0 ]]; then
    echo "CHECK SERVICES=OK"
else
    echo "CHECK SERVICES=FAIL ${bad[*]}"
fi

# ------------------------------------------------------------
# Role specific passive checks
# ------------------------------------------------------------

if [[ "$ROLE" == "seg-gateway" ]]; then
    # Fail-closed: the unit, the table, the drop rule for the marked traffic and the counter.
    reasons=()
    nft_file=/etc/seg/seg-failclosed.nft
    listing="$(nft list table inet seg_failclosed 2>/dev/null || true)"

    systemctl is-active --quiet seg-failclosed.service 2>/dev/null || reasons+=("unit-not-active")
    [[ -n "$listing" ]] || reasons+=("table-missing")

    if [[ -f "$nft_file" && -n "$listing" ]]; then
        mark="$(sed -nE 's/^[[:space:]]*meta mark (0x[0-9a-fA-F]+) oifname != .*counter drop$/\1/p' "$nft_file" | head -n1)"
        rule_interface="$(sed -nE 's/^[[:space:]]*meta mark 0x[0-9a-fA-F]+ oifname != "([^"]+)" counter drop$/\1/p' "$nft_file" | head -n1)"

        if [[ -n "$mark" && -n "$rule_interface" ]]; then
            mark="$(printf '0x%08x' "$((mark))")"
            grep -Fq "meta mark ${mark} oifname != \"${rule_interface}\" counter" <<<"$listing" || reasons+=("drop-rule-missing")
            [[ "$rule_interface" == "$INTERFACE" ]] || reasons+=("rule-interface-differs")
        else
            reasons+=("drop-rule-not-in-file")
        fi

        grep -Fq 'counter unmatched_direct' <<<"$listing" || reasons+=("counter-missing")
    fi

    if [[ "${#reasons[@]}" -eq 0 ]]; then
        echo "CHECK FAIL_CLOSED=OK"
    else
        echo "CHECK FAIL_CLOSED=FAIL ${reasons[*]}"
    fi
else
    # Exit: firewall and NAT tables, forwarding, the resolver on the backhaul address and the interface.
    reasons=()

    nft list table inet seg_exit >/dev/null 2>&1 || reasons+=("filter-table-missing")
    nft list table ip seg_exit_nat >/dev/null 2>&1 || reasons+=("nat-table-missing")
    [[ "$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)" == "1" ]] || reasons+=("ip-forward-off")
    ss -H -lnu 'sport = :53' | grep -Fq "${VPS1_BACKHAUL}:53" || reasons+=("unbound-udp-not-listening")
    ss -H -lnt 'sport = :53' | grep -Fq "${VPS1_BACKHAUL}:53" || reasons+=("unbound-tcp-not-listening")

    if [[ "${#reasons[@]}" -eq 0 ]]; then
        echo "CHECK EXIT_FIREWALL=OK"
    else
        echo "CHECK EXIT_FIREWALL=FAIL ${reasons[*]}"
    fi

    # The backhaul as seen from the exit: the interface and its handshake with the gateway.
    if ip link show "$INTERFACE" >/dev/null 2>&1 && ip -4 addr show dev "$INTERFACE" | grep -Fq "inet ${VPS1_BACKHAUL}/"; then
        echo "CHECK BACKHAUL_IF=UP"
    else
        echo "CHECK BACKHAUL_IF=DOWN"
    fi

    line="$(awg show "$INTERFACE" latest-handshakes 2>/dev/null | head -n1 || true)"
    timestamp="$(awk '{ print $2 }' <<<"$line")"

    if [[ -z "$timestamp" || "$timestamp" == "0" ]]; then
        echo "CHECK HANDSHAKE_EXIT=NONE"
    else
        age=$(( $(date +%s) - timestamp ))

        if [[ "$age" -le 150 ]]; then
            echo "CHECK HANDSHAKE_EXIT=FRESH age=${age}s"
        else
            echo "CHECK HANDSHAKE_EXIT=STALE age=${age}s"
        fi
    fi
fi

# ------------------------------------------------------------
# Security: SSH key only, UFW with the rules of the role, Fail2Ban
# ------------------------------------------------------------

problems=()
effective="$(sshd -T 2>/dev/null || true)"

grep -q '^passwordauthentication no$' <<<"$effective" || problems+=("ssh-password-login")
grep -q '^kbdinteractiveauthentication no$' <<<"$effective" || problems+=("ssh-kbd-interactive")
grep -Eq '^permitrootlogin (prohibit-password|without-password)$' <<<"$effective" || problems+=("ssh-root-login")

ufw status 2>/dev/null | grep -q '^Status: active' || problems+=("ufw-inactive")
ufw status verbose 2>/dev/null | grep -q '^Default: deny (incoming)' || problems+=("ufw-incoming-not-denied")

added="$(ufw show added 2>/dev/null || true)"
grep -Eq '^ufw allow 22/tcp' <<<"$added" || problems+=("ufw-ssh-rule")

# The tags are the ones secure-seg.sh puts on its rules.
if [[ "$ROLE" == "seg-gateway" ]]; then
    tags=("seg:vless-tcp:${VLESS_PORT}" "seg:backhaul-udp:${BACKHAUL_PORT}:${VPS1_PUBLIC_IP}")
else
    external="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
    tags=(
        "seg:dns-udp:${INTERFACE}:${VPS2_BACKHAUL}:${VPS1_BACKHAUL}"
        "seg:dns-tcp:${INTERFACE}:${VPS2_BACKHAUL}:${VPS1_BACKHAUL}"
        "seg:route:${INTERFACE}:${external}:${VPS2_BACKHAUL}"
    )
fi

for tag in "${tags[@]}"; do
    grep -Fq "comment '${tag}'" <<<"$added" || problems+=("ufw-rule-${tag}")
done

systemctl is-active --quiet fail2ban 2>/dev/null || problems+=("fail2ban-inactive")

if [[ "${#problems[@]}" -eq 0 ]]; then
    echo "CHECK SECURITY=OK"
else
    echo "CHECK SECURITY=FAIL ${problems[*]}"
fi

log OK "CHECK_NODE_DONE role=${ROLE}"
