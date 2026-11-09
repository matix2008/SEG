#!/usr/bin/env bash
# SEG backhaul check on seg-gateway (roadmap, item 18). Read-only: it changes no configuration.
# The same checks serve the apply order (sing-box is not started when they fail) and -Check.
#
#   check-backhaul.sh <INTERFACE> <VPS1_BACKHAUL_IP> <VPS2_BACKHAUL_IP> <VPS1_PUBLIC_IP> <SEG_MARK> [SING_BOX_CONFIG]
#
# Prints CHECK <NAME>=<value> lines and BACKHAUL_CHECK_OK when everything passes (exit 0), otherwise
# the failing checks are listed with [ERROR] and the exit code is 1.
set -Eeuo pipefail

SCRIPT_NAME="${SEG_SCRIPT_NAME:-$(basename "$0")}"

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

USAGE="Usage: $0 <INTERFACE> <VPS1_BACKHAUL_IP> <VPS2_BACKHAUL_IP> <VPS1_PUBLIC_IP> <SEG_MARK> [SING_BOX_CONFIG]"

[[ $# -ge 5 && $# -le 6 ]] || die "$USAGE"

INTERFACE="$1"
VPS1_BACKHAUL="$2"
VPS2_BACKHAUL="$3"
VPS1_PUBLIC="$4"
SEG_MARK="$5"
SING_BOX_CONFIG="${6:-}"

# A handshake older than this is stale: AmneziaWG renews the session about every two minutes under
# traffic, and seg-exit-keepalive keeps traffic flowing. SEG_MAX_HANDSHAKE_AGE and SEG_HANDSHAKE_WAIT
# (seconds) override the limits for tests.
MAX_HANDSHAKE_AGE="${SEG_MAX_HANDSHAKE_AGE:-150}"
HANDSHAKE_WAIT="${SEG_HANDSHAKE_WAIT:-60}"

[[ "$MAX_HANDSHAKE_AGE" =~ ^[0-9]+$ && "$HANDSHAKE_WAIT" =~ ^[0-9]+$ ]] || die "Invalid handshake limits"

[[ "$INTERFACE" =~ ^[A-Za-z0-9_.-]{1,15}$ ]] || die "Invalid interface: $INTERFACE"

for address in "$VPS1_BACKHAUL" "$VPS2_BACKHAUL" "$VPS1_PUBLIC"; do
    [[ "$address" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "Invalid address: $address"
done

[[ "$SEG_MARK" =~ ^0x[0-9a-fA-F]+$ ]] || die "Invalid mark: $SEG_MARK"

FAILURES=()

fail()
{
    FAILURES+=("$1")
    log ERROR "$1"
}

# ------------------------------------------------------------
# Interface and addresses
# ------------------------------------------------------------

if ip link show "$INTERFACE" >/dev/null 2>&1 &&
   ip link show "$INTERFACE" | head -n1 | grep -Eq '<[^>]*\bUP\b'; then
    echo "CHECK INTERFACE=UP"
else
    echo "CHECK INTERFACE=DOWN"
    fail "Interface $INTERFACE is missing or down"
fi

if ip -4 addr show dev "$INTERFACE" 2>/dev/null | grep -Fq "inet ${VPS2_BACKHAUL}/"; then
    echo "CHECK BACKHAUL_ADDRESS=OK"
else
    echo "CHECK BACKHAUL_ADDRESS=MISSING"
    fail "Backhaul address $VPS2_BACKHAUL is not set on $INTERFACE"
fi

# ------------------------------------------------------------
# Handshake: DNS queries to VPS1 generate the traffic that starts a handshake when none is fresh
# ------------------------------------------------------------

handshake_age()
{
    # Prints the age in seconds of the latest handshake of the (single) peer, or -1 when there was none.
    local line timestamp now

    line="$(awg show "$INTERFACE" latest-handshakes 2>/dev/null | head -n1 || true)"
    timestamp="$(awk '{ print $2 }' <<<"$line")"
    now="$(date +%s)"

    if [[ -z "$timestamp" || "$timestamp" == "0" ]]; then
        echo -1
    else
        echo $(( now - timestamp ))
    fi
}

age=-1
waited=0

while true; do
    age="$(handshake_age)"

    if [[ "$age" -ge 0 && "$age" -le "$MAX_HANDSHAKE_AGE" ]]; then
        break
    fi

    if [[ "$waited" -ge "$HANDSHAKE_WAIT" ]]; then
        break
    fi

    dig +short +time=2 +tries=1 example.com "@${VPS1_BACKHAUL}" >/dev/null 2>&1 || true
    sleep 3
    waited=$(( waited + 3 ))
done

if [[ "$age" -lt 0 ]]; then
    echo "CHECK HANDSHAKE=NONE"
    fail "No handshake with VPS1 within ${HANDSHAKE_WAIT}s"
elif [[ "$age" -gt "$MAX_HANDSHAKE_AGE" ]]; then
    echo "CHECK HANDSHAKE=STALE age=${age}s"
    fail "The latest handshake is ${age}s old (limit ${MAX_HANDSHAKE_AGE}s)"
else
    echo "CHECK HANDSHAKE=FRESH age=${age}s"
fi

# ------------------------------------------------------------
# DNS of VPS1 through the backhaul
# ------------------------------------------------------------

dns_answer="$(dig +short +time=3 +tries=2 cloudflare.com "@${VPS1_BACKHAUL}" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)"

if [[ -n "$dns_answer" ]]; then
    echo "CHECK BACKHAUL_DNS=OK"
else
    echo "CHECK BACKHAUL_DNS=FAIL"
    fail "VPS1 resolver ${VPS1_BACKHAUL} did not answer through the backhaul"
fi

# ------------------------------------------------------------
# Internet egress: the external address seen through the backhaul must be the address of VPS1
# ------------------------------------------------------------

egress_ip=""

for url in https://api.ipify.org https://ifconfig.me/ip https://icanhazip.com; do
    egress_ip="$(curl -s --max-time 8 --interface "$INTERFACE" "$url" 2>/dev/null | tr -d '[:space:]' || true)"

    if [[ "$egress_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        break
    fi

    egress_ip=""
done

if [[ -z "$egress_ip" ]]; then
    echo "CHECK EGRESS_IP=NONE"
    fail "No Internet egress through the backhaul"
elif [[ "$egress_ip" == "$VPS1_PUBLIC" ]]; then
    echo "CHECK EGRESS_IP=${egress_ip}"
else
    echo "CHECK EGRESS_IP=${egress_ip}"
    fail "The external address through the backhaul is ${egress_ip}, expected ${VPS1_PUBLIC}"
fi

# ------------------------------------------------------------
# The selected outbound of sing-box is bound to the backhaul (when a configuration is given)
# ------------------------------------------------------------

if [[ -n "$SING_BOX_CONFIG" ]]; then
    if [[ ! -f "$SING_BOX_CONFIG" ]]; then
        echo "CHECK SELECTED_ROUTING=NO_CONFIG"
        fail "sing-box configuration not found: $SING_BOX_CONFIG"
    elif python3 - "$SING_BOX_CONFIG" "$INTERFACE" "$SEG_MARK" <<'PY'
import json, sys

path, interface, mark = sys.argv[1], sys.argv[2], int(sys.argv[3], 16)

def as_int(value):
    return int(value, 0) if isinstance(value, str) else value

with open(path, encoding="utf-8") as handle:
    outbounds = json.load(handle).get("outbounds", [])

selected = [o for o in outbounds if o.get("tag") == "seg-out"]

if len(selected) != 1:
    sys.exit("expected exactly one outbound seg-out")

if selected[0].get("bind_interface") != interface:
    sys.exit("seg-out is not bound to " + interface)

if as_int(selected[0].get("routing_mark")) != mark:
    sys.exit("seg-out does not carry the SEG mark")

others = [o.get("tag") for o in outbounds if o is not selected[0] and o.get("routing_mark") is not None and as_int(o["routing_mark"]) == mark]

if others:
    sys.exit("the SEG mark is used by another outbound: " + ", ".join(map(str, others)))
PY
    then
        echo "CHECK SELECTED_ROUTING=OK"
    else
        echo "CHECK SELECTED_ROUTING=FAIL"
        fail "The selected outbound is not bound to ${INTERFACE} with the SEG mark"
    fi
fi

# ------------------------------------------------------------
# Unmatched-direct counter (information, never a failure): new connections of the insurance DIRECT.
# A non-zero value means that clients send traffic to the gateway that is not in seg-list.
# ------------------------------------------------------------

unmatched="$(nft list counter inet seg_failclosed unmatched_direct 2>/dev/null | sed -nE 's/.*packets ([0-9]+) bytes.*/\1/p' | head -n1 || true)"
echo "CHECK UNMATCHED_DIRECT=${unmatched:-UNKNOWN}"

# ------------------------------------------------------------
# Result
# ------------------------------------------------------------

if [[ "${#FAILURES[@]}" -gt 0 ]]; then
    log ERROR "Backhaul check failed: ${#FAILURES[@]} problem(s)."
    exit 1
fi

log OK "BACKHAUL_CHECK_OK"
log DONE "Script completed successfully."
