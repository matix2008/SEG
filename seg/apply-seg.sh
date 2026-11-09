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
[[ $# -eq 1 ]] || die "Usage: $0 failclosed"

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

case "$STAGE" in
    failclosed)
        stage_failclosed
        ;;
    *)
        die "Unknown stage: $STAGE. Usage: $0 failclosed"
        ;;
esac

log OK "APPLY_SEG_OK stage=$STAGE"
log DONE "Script completed successfully."
