#!/usr/bin/env bash
# install.sh - install orcd-scrub (rolling-window ZFS scrub) on THIS node.
#
#   sudo ./install.sh [options]
#
# Options
#   --pools "data1 data2"   pools to manage (default: auto-detect by POOL_REGEX)
#   --pool-regex RE         auto-detect regex (default: ^data[0-9]+$)
#   --baseline "YYYY-MM-DD[ HH:MM]"
#                           watermark for pools without state (default: date of the
#                           last completed scrub reported by `zpool status`)
#   --start-now             first cycle on next timer run instead of next month
#   --reinit                overwrite existing per-pool state (dangerous)
#   --keep-stock            do NOT disable the stock zfs-scrub-*@pool timers / cron
#   --force-config          overwrite /etc/orcd-scrub.conf (old one saved as .bak)
#   --dry-run               print what would be done
#   --check                 change nothing; exit 0 if this node is already installed
#                           from this source with every pool initialised and its
#                           timer enabled, else list what is missing and exit 1
#                           (used as the Salt `unless:` guard)
#   --uninstall [--purge]   remove units/binary (purge also removes state + config)
#
# Upgrade: re-running install.sh (or deploy.sh) on a node that already has
# orcd-scrub is an in-place upgrade. Per-pool state (watermark, cycle end,
# learned window limit, active/paused window) and /etc/orcd-scrub.conf are kept;
# a backup of both goes to /var/lib/orcd-scrub/backup/ first. A scrub that is
# running keeps running under the old code; the new code takes over at the next
# run. If the new binary cannot read the existing state it is rolled back.
set -euo pipefail

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
BIN=/usr/local/sbin/orcd-scrub
CONF=/etc/orcd-scrub.conf
UNIT_DIR=/etc/systemd/system
STATE_DIR=/var/lib/orcd-scrub

POOLS=""; POOL_REGEX='^data[0-9]+$'; BASELINE=""; START_NOW=0; REINIT=0
KEEP_STOCK=0; FORCE_CONFIG=0; DRY=0; CHECK=0; UNINSTALL=0; PURGE=0; FAILED=()

while (( $# )); do
    case $1 in
        --pools) POOLS=$2; shift 2 ;;
        --pool-regex) POOL_REGEX=$2; shift 2 ;;
        --baseline) BASELINE=$2; shift 2 ;;
        --start-now) START_NOW=1; shift ;;
        --reinit) REINIT=1; shift ;;
        --keep-stock) KEEP_STOCK=1; shift ;;
        --force-config) FORCE_CONFIG=1; shift ;;
        --dry-run) DRY=1; shift ;;
        --check) CHECK=1; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --purge) PURGE=1; shift ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *) echo "unknown option: $1" >&2; exit 2 ;;
    esac
done

H=$(hostname -s)
say() { echo "[install $H] $*"; }
run() { if (( DRY )); then echo "  + $*"; else "$@"; fi; }

(( EUID == 0 )) || { echo "must run as root" >&2; exit 1; }
command -v zpool >/dev/null || { say "zpool not found - not a ZFS node, skipping"; exit 0; }

detect_pools() {
    if [[ -n $POOLS ]]; then echo "$POOLS"; return; fi
    zpool list -H -o name 2>/dev/null | grep -E "$POOL_REGEX" | tr '\n' ' ' || true
}

stock_units() {  # stock OpenZFS scrub timers for pool $1
    local p=$1 u
    for u in zfs-scrub-weekly@"$p".timer zfs-scrub-monthly@"$p".timer zfs-scrub@"$p".timer; do
        echo "$u"
    done
    # any other timer names listed in the config
    # shellcheck disable=SC2154
    for u in ${STOCK_TIMERS:-}; do echo "${u//%p/$p}"; done
}

# --------------------------------------------------------------- uninstall
if (( UNINSTALL )); then
    for u in $(systemctl list-units --all --plain --no-legend 'orcd-scrub@*.timer' 2>/dev/null | awk '{print $1}'); do
        run systemctl disable --now "$u" || true
    done
    run rm -f "$UNIT_DIR/orcd-scrub@.service" "$UNIT_DIR/orcd-scrub@.timer" "$BIN"
    run rm -rf "$UNIT_DIR/orcd-scrub@.service.d"
    run systemctl daemon-reload
    if (( PURGE )); then run rm -rf "$STATE_DIR" "$CONF"; fi
    say "uninstalled$( (( PURGE )) && echo ' (purged state+config)'). Re-enable stock scrub timers if wanted, e.g.: systemctl enable --now zfs-scrub-monthly@data1.timer"
    exit 0
fi

# ------------------------------------------------------------------- check
if (( CHECK )); then
    need=()
    cmp -s "$SRC_DIR/orcd-scrub.sh" "$BIN" || need+=("$BIN differs from source")
    for u in orcd-scrub@.service orcd-scrub@.timer; do
        cmp -s "$SRC_DIR/systemd/$u" "$UNIT_DIR/$u" || need+=("$u differs from source")
    done
    [[ -e $CONF ]] || need+=("$CONF missing")
    # shellcheck source=/dev/null
    [[ -r $CONF ]] && . "$CONF"
    for p in $(detect_pools); do
        [[ -r $STATE_DIR/$p.state ]] || need+=("$p not initialised")
        systemctl is-enabled -q "orcd-scrub@$p.timer" 2>/dev/null || need+=("orcd-scrub@$p.timer not enabled")
        systemctl is-active -q "orcd-scrub@$p.timer" 2>/dev/null || need+=("orcd-scrub@$p.timer not active")
        if (( ! KEEP_STOCK )); then
            for u in $(stock_units "$p"); do
                systemctl is-enabled -q "$u" 2>/dev/null && need+=("stock $u enabled")
            done
        fi
    done
    if (( ${#need[@]} )); then
        say "install needed: $(IFS=';'; echo "${need[*]}")"; exit 1
    fi
    say "up to date ($("$BIN" --version))"; exit 0
fi

# ----------------------------------------------------------------- install
for f in orcd-scrub.sh install.sh; do
    if ! err=$(bash -n "$SRC_DIR/$f" 2>&1); then
        say "ERROR: $f has a syntax error (corrupted copy?) - nothing installed: $err"; exit 1
    fi
done
# same probe as orcd-scrub (it is the source of truth)
if ! ZPOOL=zpool ORCD_SCRUB_CONF=/dev/null bash "$SRC_DIR/orcd-scrub.sh" check-support >/dev/null; then
    say "ERROR: 'zpool scrub -S/-E' not supported by $(zpool version 2>/dev/null | head -1 || echo 'unknown zfs') (need OpenZFS >= 2.4)"
    say "probe output: $(zpool scrub -S 2000-01-01 -E 2000-01-02 orcd_probe_nonexistent_pool 2>&1 | head -2 | tr '\n' ' ')"
    exit 1
fi

read -r -a PL <<<"$(detect_pools)"
if (( ${#PL[@]} == 0 )); then say "no pools matching '$POOL_REGEX' - nothing to do"; exit 0; fi
say "pools: ${PL[*]}"

# ---------------------------------------------------- upgrade safety net
state_key() { sed -n "s/^$2=//p" "$STATE_DIR/$1.state" 2>/dev/null; }
edate() { if [[ ${1:-0} =~ ^[1-9][0-9]*$ ]]; then date -d "@$1" '+%F %H:%M'; else echo -; fi; }
window_sig() {  # the fields that define a pool's run window
    local k; for k in WATERMARK CYCLE_END WINDOW_LIMIT ACTIVE_START ACTIVE_END RUN_STATE; do
        printf '%s=%s ' "$k" "$(state_key "$1" "$k")"
    done
}
NEW_VER=$(sed -nE 's/^VERSION=(.*)/\1/p' "$SRC_DIR/orcd-scrub.sh")
OLD_VER=""; [[ -x $BIN ]] && OLD_VER=$("$BIN" --version 2>/dev/null | awk '{print $2}')
if [[ -z $OLD_VER && -e $BIN ]]; then OLD_VER=unknown; fi
declare -A SIG_BEFORE=()
HAVE_STATE=0
for p in "${PL[@]}"; do
    [[ -r $STATE_DIR/$p.state ]] || continue
    HAVE_STATE=1; SIG_BEFORE[$p]=$(window_sig "$p")
done
if [[ -n $OLD_VER || $HAVE_STATE == 1 ]]; then
    say "upgrade: ${OLD_VER:-none} -> $NEW_VER (state and $CONF are kept)"
    (( REINIT )) && say "WARNING: --reinit given - existing pool state WILL be overwritten (backup below)"
    if (( HAVE_STATE )) || [[ -e $CONF ]]; then
        BK=$STATE_DIR/backup/$(date +%Y%m%d-%H%M%S).tgz
        run install -d -m 0750 "$STATE_DIR/backup"
        # shellcheck disable=SC2046
        run tar -czf "$BK" --ignore-failed-read -P \
            $(ls -d "$STATE_DIR"/*.state "$STATE_DIR"/*.history "$STATE_DIR"/*.deferred "$CONF" \
                     "$UNIT_DIR/orcd-scrub@.service.d" 2>/dev/null)
        say "backup: $BK"
        (( DRY )) || { ls -1t "$STATE_DIR"/backup/*.tgz 2>/dev/null | tail -n +21 | xargs -r rm -f; } || true
    fi
    for p in "${PL[@]}"; do
        if systemctl is-active -q "orcd-scrub@$p.service" 2>/dev/null; then
            say "orcd-scrub@$p.service is running (window $(edate "$(state_key "$p" ACTIVE_START)")..$(edate "$(state_key "$p" ACTIVE_END)")) - left untouched; $NEW_VER takes over at its next run"
        fi
    done
fi

# atomic replace: a running instance keeps its (old) inode; keep previous for rollback
[[ -e $BIN ]] && run cp -a "$BIN" "$BIN.prev"
run install -D -m 0755 "$SRC_DIR/orcd-scrub.sh" "$BIN.new"
run mv -f "$BIN.new" "$BIN"
if (( ! DRY )); then
    for p in "${!SIG_BEFORE[@]}"; do
        if ! out=$("$BIN" plan "$p" 2>&1); then
            say "ERROR: new orcd-scrub cannot handle existing state of $p: $out"
            if [[ -e $BIN.prev ]]; then mv -f "$BIN.prev" "$BIN"; say "rolled back to $OLD_VER"; fi
            exit 1
        fi
    done
fi
run install -D -m 0644 "$SRC_DIR/systemd/orcd-scrub@.service" "$UNIT_DIR/orcd-scrub@.service"
run install -D -m 0644 "$SRC_DIR/systemd/orcd-scrub@.timer"   "$UNIT_DIR/orcd-scrub@.timer"
if [[ ! -e $CONF ]]; then
    run install -m 0644 "$SRC_DIR/orcd-scrub.conf" "$CONF"
elif (( FORCE_CONFIG )); then
    run cp -a "$CONF" "$CONF.bak"; run install -m 0644 "$SRC_DIR/orcd-scrub.conf" "$CONF"
elif ! cmp -s "$SRC_DIR/orcd-scrub.conf" "$CONF"; then
    run install -m 0644 "$SRC_DIR/orcd-scrub.conf" "$CONF.new"
    say "kept existing $CONF (new defaults in $CONF.new)"
fi
run install -d -m 0750 "$STATE_DIR"
# keep systemd's start timeout above MAX_RUNTIME from the (possibly customised) config
run "$BIN" sync-unit
run systemctl daemon-reload
# shellcheck source=/dev/null
[[ -r $CONF ]] && . "$CONF"

# Debian/Ubuntu zfsutils cron runs a full scrub on the 2nd Sunday
CRON=/etc/cron.d/zfsutils-linux
if (( ! KEEP_STOCK )) && [[ -f $CRON ]] && grep -qE '^[^#].*(zfs-linux/scrub|zpool scrub)' "$CRON"; then
    run cp -a "$CRON" "$CRON.orcd-bak"
    run sed -i -E 's|^([^#].*(zfs-linux/scrub\|zpool scrub).*)$|# disabled by orcd-scrub: \1|' "$CRON"
    say "disabled scrub line in $CRON (backup $CRON.orcd-bak)"
fi

for p in "${PL[@]}"; do
    zpool list -H -o name "$p" >/dev/null 2>&1 || { say "pool $p not present - skipped"; continue; }
    if (( ! KEEP_STOCK )); then
        for u in $(stock_units "$p"); do
            if systemctl is-enabled -q "$u" 2>/dev/null || systemctl is-active -q "$u" 2>/dev/null; then
                run systemctl disable --now "$u" && say "disabled stock $u"
            fi
        done
    fi
    args=(init "$p")
    [[ -n $BASELINE ]] && args+=(--baseline "$BASELINE")
    (( START_NOW )) && args+=(--start-now)
    (( REINIT )) && args+=(--reinit)
    if (( DRY )); then echo "  + $BIN ${args[*]}"
    elif ! "$BIN" "${args[@]}"; then
        say "ERROR: init of $p failed - timer NOT enabled for $p (pass --baseline?)"; FAILED+=("$p"); continue
    fi
    run systemctl enable --now "orcd-scrub@$p.timer"
done

if (( ! DRY )); then
    # the run window must survive an upgrade unchanged
    for p in "${!SIG_BEFORE[@]}"; do
        after=$(window_sig "$p")
        if [[ $after == "${SIG_BEFORE[$p]}" ]]; then
            say "$p: run window preserved (watermark $(edate "$(state_key "$p" WATERMARK)"), limit $(state_key "$p" WINDOW_LIMIT)s, $(state_key "$p" RUN_STATE))"
        elif (( REINIT )); then
            say "$p: state re-initialised as requested (was: ${SIG_BEFORE[$p]})"
        else
            say "WARNING: $p state changed during install (a run may have ended meanwhile) - before: ${SIG_BEFORE[$p]} after: $after; backup: ${BK:-none}"
        fi
    done
    systemctl list-timers --no-pager 'orcd-scrub@*' || true
    "$BIN" status "${PL[@]}" || true
fi
(( ${#FAILED[@]} == 0 )) || { say "done with errors: ${FAILED[*]}"; exit 1; }
say "done"
