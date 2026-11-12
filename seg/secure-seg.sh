#!/usr/bin/env bash
# SEG node security hardening (roadmap, item 13): SSH key-only, Fail2Ban, automatic updates, UFW.
#
#   secure-seg.sh seg-gateway <VLESS_PORT> <BACKHAUL_PORT> <VPS1_PUBLIC_IP> <BACKHAUL_INTERFACE>
#   secure-seg.sh seg-exit <BACKHAUL_INTERFACE> <VPS1_BACKHAUL_IP> <VPS2_BACKHAUL_IP>
#
# Firewall rules of the role are tagged with a "seg:" comment. A repeated run adds the rules of the
# current parameters and then removes tagged rules that are no longer wanted (changed port or IP).
# Rules without the tag (SSH, anything else) are left alone.
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

[[ "${EUID}" -eq 0 ]] || die "secure-seg.sh must be run as root"

USAGE="Usage: $0 seg-gateway <VLESS_PORT> <BACKHAUL_PORT> <VPS1_PUBLIC_IP> <BACKHAUL_INTERFACE> | $0 seg-exit <BACKHAUL_INTERFACE> <VPS1_BACKHAUL_IP> <VPS2_BACKHAUL_IP>"

is_port()
{
    [[ "$1" =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 ))
}

is_ipv4()
{
    local octet
    local -a octets

    [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1

    IFS=. read -r -a octets <<<"$1"

    for octet in "${octets[@]}"; do
        (( 10#$octet <= 255 )) || return 1
    done
}

is_interface()
{
    [[ "$1" =~ ^[A-Za-z0-9_.-]{1,15}$ ]]
}

[[ $# -ge 1 ]] || die "$USAGE"

ROLE="$1"

case "$ROLE" in
    seg-gateway)
        [[ $# -eq 5 ]] || die "$USAGE"
        VLESS_PORT="$2"
        BACKHAUL_PORT="$3"
        VPS1_PUBLIC_IP="$4"
        BACKHAUL_INTERFACE="$5"

        is_port "$VLESS_PORT" || die "Invalid VLESS port: $VLESS_PORT"
        is_port "$BACKHAUL_PORT" || die "Invalid backhaul port: $BACKHAUL_PORT"
        is_ipv4 "$VPS1_PUBLIC_IP" || die "Invalid VPS1 public IP: $VPS1_PUBLIC_IP"
        is_interface "$BACKHAUL_INTERFACE" || die "Invalid backhaul interface: $BACKHAUL_INTERFACE"
        [[ "$VLESS_PORT" != "22" ]] || die "VLESS port must not be 22 (SSH)"
        ;;
    seg-exit)
        [[ $# -eq 4 ]] || die "$USAGE"
        BACKHAUL_INTERFACE="$2"
        VPS1_BACKHAUL_IP="$3"
        VPS2_BACKHAUL_IP="$4"

        is_interface "$BACKHAUL_INTERFACE" || die "Invalid backhaul interface: $BACKHAUL_INTERFACE"
        is_ipv4 "$VPS1_BACKHAUL_IP" || die "Invalid VPS1 backhaul IP: $VPS1_BACKHAUL_IP"
        is_ipv4 "$VPS2_BACKHAUL_IP" || die "Invalid VPS2 backhaul IP: $VPS2_BACKHAUL_IP"
        ;;
    *)
        die "$USAGE"
        ;;
esac

log INFO "Role: $ROLE"

[[ -s /root/.ssh/authorized_keys ]] || \
    die "/root/.ssh/authorized_keys is missing or empty"

log OK "Root authorized_keys exists and is non-empty."

# ------------------------------------------------------------
# SSH
# ------------------------------------------------------------

log INFO "Applying SSH key-only hardening."
SSH_DROPIN="/etc/ssh/sshd_config.d/00-seg-hardening.conf"

cat >"$SSH_DROPIN" <<'SSH_EOF'
PermitRootLogin prohibit-password
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
SSH_EOF

chmod 644 "$SSH_DROPIN"
sshd -t

EFFECTIVE="$(sshd -T)"

grep -q '^passwordauthentication no$' <<<"$EFFECTIVE" || \
    die "Effective PasswordAuthentication is not 'no'"

grep -q '^kbdinteractiveauthentication no$' <<<"$EFFECTIVE" || \
    die "Effective KbdInteractiveAuthentication is not 'no'"

grep -Eq '^permitrootlogin (prohibit-password|without-password)$' \
    <<<"$EFFECTIVE" || \
    die "Effective PermitRootLogin is incorrect"

systemctl reload ssh
log OK "SSH configuration validated and reloaded."

# ------------------------------------------------------------
# journald: bounded disk usage
# ------------------------------------------------------------

log INFO "Limiting the systemd journal size."
JOURNALD_DROPIN="/etc/systemd/journald.conf.d/00-seg.conf"
JOURNALD_WANTED="$(printf '%s\n' \
    '[Journal]' \
    'SystemMaxUse=200M' \
    'SystemKeepFree=2G' \
    'MaxRetentionSec=1month')"

if [[ "$(cat "$JOURNALD_DROPIN" 2>/dev/null)" == "$JOURNALD_WANTED" ]]; then
    log OK "journald limits are already in place."
else
    mkdir -p /etc/systemd/journald.conf.d
    printf '%s\n' "$JOURNALD_WANTED" >"$JOURNALD_DROPIN"
    chmod 644 "$JOURNALD_DROPIN"
    systemctl restart systemd-journald
    log OK "journald limits applied (SystemMaxUse=200M, SystemKeepFree=2G, MaxRetentionSec=1month)."
fi

# ------------------------------------------------------------
# Fail2Ban and automatic updates
# ------------------------------------------------------------

log INFO "Configuring Fail2Ban for SSH."
cat >/etc/fail2ban/jail.d/sshd.local <<'FAIL2BAN_EOF'
[sshd]
enabled = true
backend = systemd
FAIL2BAN_EOF

systemctl enable --now fail2ban
systemctl restart fail2ban
systemctl is-active --quiet fail2ban
log OK "Fail2Ban is active."

log INFO "Configuring automatic security updates."
cat >/etc/apt/apt.conf.d/20auto-upgrades <<'APT_EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT_EOF

systemctl enable --now apt-daily.timer >/dev/null 2>&1 || true
systemctl enable --now apt-daily-upgrade.timer >/dev/null 2>&1 || true
log OK "Automatic update timers configured."

# ------------------------------------------------------------
# UFW
# ------------------------------------------------------------

DESIRED_TAGS=()

add_rule()
{
    # add_rule <tag> <ufw arguments...>
    local tag="$1"
    shift

    ufw "$@" comment "$tag" >/dev/null
    DESIRED_TAGS+=("$tag")
    log INFO "UFW rule: ufw $* ($tag)"
}

remove_stale_rules()
{
    local line num tag wanted
    local stale=()
    local pattern='^\[[[:space:]]*([0-9]+)\].*#[[:space:]]*(seg:[A-Za-z0-9:._-]+)[[:space:]]*$'

    while IFS= read -r line; do
        [[ "$line" =~ $pattern ]] || continue

        num="${BASH_REMATCH[1]}"
        tag="${BASH_REMATCH[2]}"
        wanted=0

        for t in "${DESIRED_TAGS[@]}"; do
            [[ "$t" == "$tag" ]] && wanted=1
        done

        if [[ "$wanted" == "0" ]]; then
            stale+=("$num")
            log INFO "Stale SEG rule found: $tag"
        fi
    done < <(ufw status numbered)

    # Delete from the highest number down: numbers shift after every deletion.
    if [[ "${#stale[@]}" -gt 0 ]]; then
        for num in $(printf '%s\n' "${stale[@]}" | sort -rn); do
            ufw --force delete "$num" >/dev/null
        done

        log OK "Removed ${#stale[@]} stale SEG rule(s)."
    fi
}

log INFO "Configuring UFW for $ROLE."
ufw default deny incoming
ufw default allow outgoing
ufw default deny routed
ufw allow 22/tcp

if [[ "$ROLE" == "seg-gateway" ]]; then
    add_rule "seg:vless-tcp:${VLESS_PORT}" \
        allow "${VLESS_PORT}/tcp"

    add_rule "seg:backhaul-udp:${BACKHAUL_PORT}:${VPS1_PUBLIC_IP}" \
        allow from "$VPS1_PUBLIC_IP" to any port "$BACKHAUL_PORT" proto udp
else
    EXTERNAL_INTERFACE="$(ip -4 route show default | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"

    [[ -n "$EXTERNAL_INTERFACE" ]] || die "Unable to determine the external interface (no IPv4 default route)"
    [[ "$EXTERNAL_INTERFACE" != "$BACKHAUL_INTERFACE" ]] || die "The default route uses the backhaul interface"

    add_rule "seg:dns-udp:${BACKHAUL_INTERFACE}:${VPS2_BACKHAUL_IP}:${VPS1_BACKHAUL_IP}" \
        allow in on "$BACKHAUL_INTERFACE" from "$VPS2_BACKHAUL_IP" to "$VPS1_BACKHAUL_IP" port 53 proto udp

    add_rule "seg:dns-tcp:${BACKHAUL_INTERFACE}:${VPS2_BACKHAUL_IP}:${VPS1_BACKHAUL_IP}" \
        allow in on "$BACKHAUL_INTERFACE" from "$VPS2_BACKHAUL_IP" to "$VPS1_BACKHAUL_IP" port 53 proto tcp

    add_rule "seg:route:${BACKHAUL_INTERFACE}:${EXTERNAL_INTERFACE}:${VPS2_BACKHAUL_IP}" \
        route allow in on "$BACKHAUL_INTERFACE" out on "$EXTERNAL_INTERFACE" from "$VPS2_BACKHAUL_IP"
fi

# A fail-closed table that is already missing (removed by hand or lost) is not caused by the UFW reload below and
# must not block this stage: the later fail-closed stage of the same run restores it, -Check reports it.
FAILCLOSED_BEFORE=0
if [[ "$ROLE" == "seg-gateway" ]] && nft list table inet seg_failclosed >/dev/null 2>&1; then
    FAILCLOSED_BEFORE=1
fi

# Same for the services of the role: a service that was already stopped before this run (by hand, after a failure)
# is not caused by the UFW reload and must not block the run; the later stages start it again, -Check reports it.
declare -A ACTIVE_BEFORE=()
for unit in seg-failclosed.service seg-exit-fw.service seg-exit-keepalive.service "awg-quick@${BACKHAUL_INTERFACE}.service"; do
    if systemctl is-active --quiet "$unit" 2>/dev/null; then
        ACTIVE_BEFORE["$unit"]=1
    fi
done

ufw --force enable
ufw reload
remove_stale_rules
log OK "UFW configuration applied."

ufw status | grep -q '^Status: active' || die "UFW is not active after configuration"

ADDED="$(ufw show added)"

grep -Eq '^ufw allow 22/tcp' <<<"$ADDED" || die "UFW rule for 22/tcp was not found after configuration"

for tag in "${DESIRED_TAGS[@]}"; do
    grep -Fq "comment '$tag'" <<<"$ADDED" || die "UFW rule $tag was not found after configuration"
done

log OK "UFW active state and the rules of the role verified."

# Rules that this script did not create are not removed, but they may open ports the role does not need.
while IFS= read -r rule; do
    [[ "$rule" == "ufw allow 22/tcp" || "$rule" == *"comment 'seg:"* ]] && continue
    log WARN "UFW has a rule outside the SEG set: $rule"
done < <(grep '^ufw ' <<<"$ADDED")

# ------------------------------------------------------------
# Final state
# ------------------------------------------------------------

log INFO "Verifying final security state."
ufw status

systemctl is-active --quiet fail2ban

require_active_if_enabled()
{
    local unit

    for unit in "$@"; do
        if systemctl is-enabled --quiet "$unit" 2>/dev/null; then
            if systemctl is-active --quiet "$unit"; then
                continue
            fi

            if [[ -n "${ACTIVE_BEFORE[$unit]:-}" ]]; then
                die "$unit is enabled but not active"
            fi

            log WARN "$unit was already inactive before this run; a later stage starts it again."
        fi
    done
}

# The units below are installed by later stages: on a fresh node none of them exists yet.
# sing-box is not checked here: it stays stopped when the first installation fails (fail-closed is kept).
if [[ "$ROLE" == "seg-gateway" ]]; then
    require_active_if_enabled seg-failclosed.service "awg-quick@${BACKHAUL_INTERFACE}.service"

    # UFW reload must not remove the fail-closed table: it is a separate nftables table.
    if systemctl is-active --quiet seg-failclosed.service; then
        if [[ "$FAILCLOSED_BEFORE" == "1" ]]; then
            nft list table inet seg_failclosed >/dev/null || die "Table seg_failclosed is missing after the UFW reload"
        elif ! nft list table inet seg_failclosed >/dev/null 2>&1; then
            log WARN "Table seg_failclosed was already missing before this run; the fail-closed stage restores it."
        fi
    fi
else
    require_active_if_enabled seg-exit-fw.service "awg-quick@${BACKHAUL_INTERFACE}.service" seg-exit-keepalive.service
fi

log OK "Fail2Ban and the enabled SEG services are active."
log OK "SECURE_SEG_OK role=$ROLE"
log DONE "Script completed successfully."
