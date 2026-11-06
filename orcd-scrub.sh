#!/usr/bin/env bash
# shellcheck disable=SC2004  # ${S[KEY]} in arithmetic is intentional (assoc array)
# orcd-scrub - rolling-window ZFS scrub using `zpool scrub -S/-E` (OpenZFS >= 2.4)
#
# Idea
#   Instead of scrubbing the whole pool, only scrub blocks born since the last
#   completed window ("watermark"), with a small overlap. No scrub session may
#   run longer than MAX_RUNTIME (default 24h).
#
#   * Monthly: on/after MONTHLY_DAY of a new month, scrub [watermark-overlap, now].
#   * After CHECK_AFTER (12h) of runtime, if elapsed + zpool's ETA > MAX_RUNTIME,
#     the scrub is stopped and the window is cut in half (or in quarters when the
#     ETA says half would still not fit, see SHRINK_MAX_HALVINGS). The reduced
#     window is scrubbed CATCHUP_INTERVAL (7d) later; on success the watermark
#     moves to the end of that window and the next catch-up continues from there
#     every CONTINUE_INTERVAL (default = CATCHUP_INTERVAL) until the watermark has
#     caught up to "now". Then it waits for the next month.
#   * If zpool's % done / ETA turn out not to be relative to the -S/-E window
#     (a window finishes while zpool still reported < 50 %), the ETA-based early
#     cut is switched off for that pool (ETA_CUT=auto); MAX_RUNTIME still applies.
#   * A scrub of ours that finished while nobody watched it (crash, kill -9)
#     is still credited: the watermark advances on the next timer run.
#   * -S dates before the pool's date->txg history began scrub from pool
#     creation, so halving such a window does not reduce the work. When a cut
#     window needed about as long as the previous one (ON_TOO_SLOW=auto), the
#     window is kept and finished incrementally: run to MAX_RUNTIME, pause,
#     resume on the next catch-up run.
#   * The working window size is remembered (WINDOW_LIMIT) so later cycles start
#     with a size that is known to fit; it is doubled again when the measured
#     throughput says twice the window would still fit (GROW_HEADROOM).
#   * One scrub per host (SERIALIZE_POOLS=yes): if another managed pool on this
#     server is scrubbing/resilvering, a due run is DEFERRED; when the running
#     pool's run ends it starts the deferred pool's service (oldest first).
#   * Below MIN_WINDOW the window is not halved any more: the scrub is allowed to
#     run to MAX_RUNTIME, then PAUSED and resumed on the next catch-up run.
#
# Usage
#   orcd-scrub run    [--force] [--dry-run] POOL   timer entry point (decides if due)
#   orcd-scrub plan   POOL                         show what `run` would do now
#   orcd-scrub status [POOL...]                    show state (all pools if none)
#   orcd-scrub kick   POOL                         start orcd-scrub@POOL.service now as a
#                                                  forced run (resumes a paused scrub of ours)
#   orcd-scrub reattach POOL                       apply changed settings to the RUNNING scrub
#                                                  without pausing it (restarts only the monitor)
#   orcd-scrub init   POOL [--baseline "YYYY-MM-DD[ HH:MM]"] [--start-now] [--reinit]
#   orcd-scrub reset-limit POOL                    forget the learned window size
#                                                  (and re-trust zpool's ETA)
#   orcd-scrub config                              show effective settings
#   orcd-scrub set [--no-reset] [--start] [--pool P]... KEY VALUE [KEY VALUE...]
#        KEY: max-runtime | check-after   (also: poll-interval overlap min-window
#             catchup-interval continue-interval lag-alert monthly-day
#             on-too-slow auto|halve|pause   eta-cut auto|yes|no)
#        VALUE: 90m, 12h, 2d or seconds (max-runtime up to 30d)
#        Writes /etc/orcd-scrub.conf. Changing max-runtime or check-after also
#        resets the run info of all (or the given) pools - last result, learned
#        window limit, cycle month, any paused/orphaned scrub of ours is cancelled
#        - so a fresh run is due immediately (same day). Watermark is kept.
#        --start  also start orcd-scrub@POOL.service right away.
#
# Config: /etc/orcd-scrub.conf (shell variables, see defaults below)
# State : /var/lib/orcd-scrub/<pool>.state, history in <pool>.history
set -uo pipefail

PROG=orcd-scrub
VERSION=1.3.0

# ----------------------------------------------------------------- defaults
CONF_FILE=${ORCD_SCRUB_CONF:-/etc/orcd-scrub.conf}
STATE_DIR=/var/lib/orcd-scrub
ZPOOL=${ZPOOL:-zpool}
DROPIN_DIR=${ORCD_DROPIN_DIR:-/etc/systemd/system/orcd-scrub@.service.d}

MAX_RUNTIME=$((24*3600))       # hard cap for one scrub session
CHECK_AFTER=$((12*3600))       # start evaluating ETA after this much runtime
POLL_INTERVAL=300              # seconds between status polls
OVERLAP=$((24*3600))           # re-scrub this much before the watermark
MIN_WINDOW=$((2*86400))        # never halve below this (must be > OVERLAP)
CATCHUP_INTERVAL=$((7*86400))  # wait this long after a cut/partial run
INTERVAL_SLACK=$((12*3600))    # tolerance so a daily timer hits "a week later"
MONTHLY_DAY=1                  # day of month a new cycle may start
LEARN_LIMIT=yes                # remember window size that fit; grow after fast runs
GROW_HEADROOM=75               # double WINDOW_LIMIT if 2x would take < 75% of MAX_RUNTIME
ADVANCE_ON_ERRORS=yes          # advance watermark even if scrub found unrepairable errors
DEFAULT_BASELINE=""            # used by init when no completed scrub is found
MAILTO=""                      # optional: mail alerts (needs `mail`)
SERIALIZE_POOLS=yes            # only one pool per host scrubs at a time
CONTINUE_INTERVAL=""           # wait after a COMPLETED partial window (default: CATCHUP_INTERVAL)
SHRINK_MAX_HALVINGS=2          # an ETA-based cut may halve up to this many times at once (1 = plain halving)
ETA_CUT=auto                   # early cut on zpool ETA: auto (until ETA proves not window-relative) | yes | no
ON_TOO_SLOW=auto               # halve: stop + halve | pause: keep window, finish over several sessions
                               # auto: halve, but pause when the last cut showed work does not shrink
LAG_ALERT=$((62*86400))        # alert when the watermark is older than this (0 = off)

# shellcheck source=/dev/null
[[ -r $CONF_FILE ]] && . "$CONF_FILE"
: "${CONTINUE_INTERVAL:=$CATCHUP_INTERVAL}"

# ------------------------------------------------------------------ helpers
# Test hook: ORCD_TEST_CLOCK=<file> makes now()/nap() use a fake clock.
now() {
    if [[ -n ${ORCD_TEST_CLOCK:-} ]]; then cat "$ORCD_TEST_CLOCK"; else date +%s; fi
}
nap() {
    if [[ -n ${ORCD_TEST_CLOCK:-} ]]; then
        echo $(( $(cat "$ORCD_TEST_CLOCK") + $1 )) > "$ORCD_TEST_CLOCK"
    else
        sleep "$1"
    fi
}

log()  { echo "[$PROG${POOL:+ $POOL}] $*"; logger -t "$PROG" -- "${POOL:-}: $*" 2>/dev/null || true; }
warn() { echo "[$PROG${POOL:+ $POOL}] WARNING: $*" >&2; logger -p user.warning -t "$PROG" -- "${POOL:-}: $*" 2>/dev/null || true; }
die()  { echo "[$PROG${POOL:+ $POOL}] ERROR: $*" >&2; logger -p user.err -t "$PROG" -- "${POOL:-}: $*" 2>/dev/null || true; exit 1; }

alert() {   # important events -> log + optional mail
    warn "$*"
    if [[ -n $MAILTO ]] && command -v mail >/dev/null 2>&1; then
        printf '%s\n\n%s\n' "$*" "$($ZPOOL status "$POOL" 2>&1)" \
            | mail -s "[$PROG] $(hostname -s) $POOL: ${1:0:80}" "$MAILTO" || true
    fi
}

zdate()  { date -d "@$1" '+%Y-%m-%d %H:%M'; }       # format accepted by -S/-E
hdate()  { date -d "@$1" '+%Y-%m-%d %H:%M %Z'; }
hdur()   { local s=$1; printf '%dd%02dh%02dm' $((s/86400)) $((s%86400/3600)) $((s%3600/60)); }
floor_min() { echo $(( $1 / 60 * 60 )); }

# "1 days 02:03:04" | "02:03:04" -> seconds
dhms_to_s() {
    local s=$1 d=0 h m sec
    if [[ $s =~ ([0-9]+)\ days?\ ([0-9]+):([0-9]+):([0-9]+) ]]; then
        d=${BASH_REMATCH[1]}; h=${BASH_REMATCH[2]}; m=${BASH_REMATCH[3]}; sec=${BASH_REMATCH[4]}
    elif [[ $s =~ ([0-9]+):([0-9]+):([0-9]+) ]]; then
        h=${BASH_REMATCH[1]}; m=${BASH_REMATCH[2]}; sec=${BASH_REMATCH[3]}
    else
        echo ""; return
    fi
    echo $(( 10#$d*86400 + 10#$h*3600 + 10#$m*60 + 10#$sec ))
}

# ------------------------------------------------------------------- state
declare -A S
state_file()   { echo "$STATE_DIR/$POOL.state"; }
history_file() { echo "$STATE_DIR/$POOL.history"; }

state_load() {
    S=( [WATERMARK]=0 [WINDOW_LIMIT]=0 [LAST_CYCLE_MONTH]="" [CYCLE_END]=0
        [LAST_RESULT]=none [LAST_RUN_START]=0 [LAST_RUN_END]=0
        [RUN_STATE]=idle [ACTIVE_START]=0 [ACTIVE_END]=0 [ACTIVE_SINCE]=0
        [ETA_TRUST]=yes [ACTIVE_ACC]=0 )
    local f k v; f=$(state_file)
    [[ -r $f ]] || return 1
    while IFS='=' read -r k v; do
        [[ $k =~ ^[A-Z_]+$ ]] || continue
        S[$k]=$v
    done < "$f"
    return 0
}

state_save() {
    local f tmp k; f=$(state_file)
    [[ ${DRY_RUN:-0} == 1 ]] && return 0
    mkdir -p "$STATE_DIR"
    tmp=$(mktemp "$f.XXXXXX")
    {
        echo "# $PROG state for pool $POOL - written $(date '+%F %T')"
        for k in $(printf '%s\n' "${!S[@]}" | sort); do echo "$k=${S[$k]}"; done
    } > "$tmp"
    mv -f "$tmp" "$f"
}

hist_add() {  # result start end win_start win_end note
    [[ ${DRY_RUN:-0} == 1 ]] && return 0
    local h; h=$(history_file)
    [[ -s $h ]] || echo "# run_start|run_end|duration|result|window_start|window_end|note" > "$h"
    echo "$(hdate "$2")|$(hdate "$3")|$(hdur $(( $3 - $2 )))|$1|$(zdate "$4")|$(zdate "$5")|${6:-}" >> "$h"
}

# --------------------------------------------------------------- zpool glue
scan_block() {   # the "scan:" section of zpool status
    $ZPOOL status "${1:-$POOL}" 2>/dev/null | sed -n '/^ *scan:/,/^ *config:/p' | sed '$d'
}

# sets: SCAN_STATE (scrubbing|paused|resilvering|finished|canceled|none),
#       SCAN_ETA (s or ""), SCAN_PCT, SCAN_ERRORS, SCAN_END_EPOCH, SCAN_REPAIRED
scan_parse() {   # [pool] (default $POOL)
    local b; b=$(scan_block "${1:-}")
    SCAN_STATE=none SCAN_ETA="" SCAN_PCT="" SCAN_ERRORS="" SCAN_END_EPOCH=0 SCAN_REPAIRED=""
    if   grep -q 'resilver in progress' <<<"$b"; then SCAN_STATE=resilvering
    elif grep -q 'scrub paused'         <<<"$b"; then SCAN_STATE=paused
    elif grep -q 'scrub in progress'    <<<"$b"; then SCAN_STATE=scrubbing
    elif grep -q 'scrub canceled'       <<<"$b"; then SCAN_STATE=canceled
    elif grep -q 'scrub repaired'       <<<"$b"; then SCAN_STATE=finished
    fi
    SCAN_PCT=$(grep -oE '[0-9.]+% done' <<<"$b" | head -1 | cut -d% -f1)
    local eta; eta=$(grep -oE '([0-9]+ days? )?[0-9]+:[0-9]{2}:[0-9]{2} to go' <<<"$b" | head -1)
    [[ -n $eta ]] && SCAN_ETA=$(dhms_to_s "$eta")
    if [[ $SCAN_STATE == finished ]]; then
        local line; line=$(grep -m1 'scrub repaired' <<<"$b")
        SCAN_REPAIRED=$(sed -nE 's/.*scrub repaired ([^ ]+) .*/\1/p' <<<"$line")
        SCAN_ERRORS=$(sed -nE 's/.* with ([0-9]+) errors.*/\1/p' <<<"$line")
        local d; d=$(sed -nE 's/.* errors on (.*)$/\1/p' <<<"$line")
        [[ -n $d ]] && SCAN_END_EPOCH=$(date -d "$d" +%s 2>/dev/null || echo 0)
    fi
}

# Feature probe: ask zpool to range-scrub a pool that cannot exist. A zpool
# without -S/-E rejects the option ("invalid option"); one with it gets as far
# as looking up the pool. Falls back to the OpenZFS version (>= 2.4).
supports_range() {
    local out v maj min
    out=$($ZPOOL scrub -S "2000-01-01" -E "2000-01-02" orcd_probe_nonexistent_pool 2>&1)
    if grep -qiE "invalid option|unrecognized option|illegal option" <<<"$out"; then return 1; fi
    if grep -qiE "no such pool|cannot open|missing pool|does not exist" <<<"$out"; then return 0; fi
    v=$($ZPOOL version 2>/dev/null | sed -nE 's/^zfs-([0-9]+)\.([0-9]+).*/\1 \2/p' | head -1)
    [[ -n $v ]] && { read -r maj min <<<"$v"; (( maj > 2 || (maj == 2 && min >= 4) )); return; }
    return 1
}

# ------------------------------------------------------- one scrub per host
deferred_file() { echo "$STATE_DIR/$1.deferred"; }

# Prints "<pool>:<state>" of the first OTHER managed pool that is scrubbing or
# resilvering; returns 1 if none.
other_pool_busy() {
    [[ $SERIALIZE_POOLS == yes ]] || return 1
    local f p st
    for f in "$STATE_DIR"/*.state; do
        [[ -e $f ]] || continue
        p=$(basename "$f" .state)
        [[ $p == "$POOL" ]] && continue
        $ZPOOL list -H -o name "$p" >/dev/null 2>&1 || continue
        st=$(scan_parse "$p"; echo "$SCAN_STATE")
        if [[ $st == scrubbing || $st == resilvering ]]; then echo "$p:$st"; return 0; fi
    done
    return 1
}

defer_run() {  # $1 = blocker
    local mode=normal; [[ $FORCE == 1 ]] && mode=force
    [[ ${DRY_RUN:-0} == 1 ]] || printf '%s %s %s\n' "$mode" "$(now)" "$1" > "$(deferred_file "$POOL")"
    log "deferred ($WHY): $1 on this host - will start when it finishes"
}

# After our run ends, start the oldest deferred pool on this host.
kick_deferred() {
    [[ $SERIALIZE_POOLS == yes ]] || return 0
    local f p
    f=$(find "$STATE_DIR" -maxdepth 1 -name '*.deferred' -printf '%T@ %p\n' 2>/dev/null \
        | sort -n | awk '{print $2}' | grep -v "/$POOL.deferred\$" | head -1)
    [[ -n $f ]] || return 0
    p=$(basename "$f" .deferred)
    if [[ -n ${ORCD_TEST_CLOCK:-} ]] || ! command -v systemctl >/dev/null; then
        log "would start deferred pool $p (orcd-scrub@$p.service)"; return 0
    fi
    if systemctl start --no-block "orcd-scrub@$p.service"; then
        log "started deferred pool $p (orcd-scrub@$p.service)"
    else
        warn "could not start orcd-scrub@$p.service - the daily timer will retry"
    fi
}

# ---------------------------------------------------------------- decisions
# Sets WHY and returns 0 if a run is due now.
decide() {
    local t month day since
    t=$(now); month=$(date -d "@$t" +%Y-%m); day=$(date -d "@$t" +%-d)
    since=$(( t - ${S[LAST_RUN_START]} ))
    scan_parse

    if [[ ${S[RUN_STATE]} == running && $SCAN_STATE == scrubbing ]]; then
        WHY=adopt; return 0           # our scrub survived a reboot/service restart
    fi
    if [[ ${S[RUN_STATE]} == running || ${S[RUN_STATE]} == paused ]] && [[ $SCAN_STATE == finished ]] \
       && (( SCAN_END_EPOCH > 0 && SCAN_END_EPOCH + 120 >= ${S[ACTIVE_SINCE]} )); then
        WHY=finished-unattended; return 0   # ours, completed while nobody monitored it
    fi
    if [[ ${S[RUN_STATE]} == paused ]]; then
        if [[ $SCAN_STATE == paused ]]; then
            if (( since >= CATCHUP_INTERVAL - INTERVAL_SLACK )) || [[ $FORCE == 1 ]]; then
                WHY=resume; return 0
            fi
            WHY="paused scrub waits for catch-up interval ($(hdur $(( CATCHUP_INTERVAL - INTERVAL_SLACK - since ))) left)"
            return 1
        fi
        warn "state says paused but pool scan state is '$SCAN_STATE' - treating as interrupted"
        S[RUN_STATE]=idle; S[LAST_RESULT]=interrupted
    fi
    case $SCAN_STATE in
        scrubbing|resilvering|paused)
            WHY="pool busy (foreign $SCAN_STATE) - skipping"; return 1 ;;
    esac
    [[ ${S[RUN_STATE]} == running ]] && { S[RUN_STATE]=idle; S[LAST_RESULT]=interrupted; }

    if [[ $FORCE == 1 ]]; then WHY=forced; return 0; fi

    case ${S[LAST_RESULT]} in
        reset)
            WHY="restart after settings change"; return 0 ;;
        halved|widened|interrupted|canceled|error)
            if (( since >= CATCHUP_INTERVAL - INTERVAL_SLACK )); then
                WHY="catch-up after ${S[LAST_RESULT]}"; return 0
            fi
            WHY="last run ${S[LAST_RESULT]}; next catch-up in $(hdur $(( CATCHUP_INTERVAL - INTERVAL_SLACK - since )))"
            return 1 ;;
    esac
    if (( ${S[WATERMARK]} < ${S[CYCLE_END]} )); then
        if (( since >= CONTINUE_INTERVAL - INTERVAL_SLACK )); then
            WHY="catch-up (watermark behind cycle end $(zdate "${S[CYCLE_END]}"))"; return 0
        fi
        WHY="behind cycle end; next catch-up in $(hdur $(( CONTINUE_INTERVAL - INTERVAL_SLACK - since )))"
        return 1
    fi
    if [[ $month != "${S[LAST_CYCLE_MONTH]}" ]] && (( day >= MONTHLY_DAY )); then
        WHY="new monthly cycle $month"; return 0
    fi
    WHY="caught up; next cycle on day $MONTHLY_DAY of next month"
    return 1
}

# ------------------------------------------------------------ next start
TIMER_UNIT=${ORCD_TIMER_UNIT:-/etc/systemd/system/orcd-scrub@.timer}

# Daily fire time "HH:MM" and random delay from the timer unit (default 02:00, 30m)
timer_slot() {
    TIMER_HM=02:00 TIMER_DELAY=30m
    [[ -r $TIMER_UNIT ]] || return 0
    local l
    l=$(sed -nE 's/^OnCalendar=(.*[[:space:]])?([0-9]{1,2}:[0-9]{2})(:[0-9]{2})?[[:space:]]*$/\2/p' "$TIMER_UNIT" | head -1)
    [[ -n $l ]] && TIMER_HM=$l
    l=$(sed -nE 's/^RandomizedDelaySec=[[:space:]]*([^[:space:]]+).*/\1/p' "$TIMER_UNIT" | head -1)
    [[ -n $l ]] && TIMER_DELAY=$l
}

# First daily timer fire at or after epoch $1
next_fire() {
    local due=$1 t c sd
    t=$(now); (( due < t )) && due=$t
    if [[ -z ${ORCD_TEST_CLOCK:-} ]] && command -v systemctl >/dev/null; then
        sd=$(systemctl show "orcd-scrub@$POOL.timer" -p NextElapseUSecRealtime --value 2>/dev/null)
        if [[ -n $sd && $sd != n/a ]] && sd=$(date -d "$sd" +%s 2>/dev/null) && (( sd >= due )) \
           && (( sd < due + 86400 + 3600 )); then
            echo "$sd"; return
        fi
    fi
    local d; d=$(date -d "@$due" +%F)
    c=$(date -d "$d $TIMER_HM" +%s)
    # date math on the date only: "02:00 + 1 day" would parse "+1" as a UTC offset
    (( c < due )) && c=$(date -d "$(date -d "$d + 1 day" +%F) $TIMER_HM" +%s)
    echo "$c"
}

# Sets NEXT_AT (epoch of the timer run that will start work, 0 = running now)
# and NEXT_WHAT. Mirrors decide(); read-only.
next_start() {
    local t since due="" month day
    t=$(now); since=$(( t - ${S[LAST_RUN_START]} )); NEXT_AT=0; NEXT_WHAT=""
    timer_slot
    FORCE=0
    if decide 2>/dev/null; then
        case $WHY in
            adopt) NEXT_WHAT="running now"; return ;;
            finished-unattended) NEXT_WHAT="credit finished scrub" ;;
            resume) NEXT_WHAT="resume paused scrub" ;;
            *) NEXT_WHAT="$WHY" ;;
        esac
        due=$t
    elif [[ $WHY == "pool busy"* ]]; then
        due=$t; NEXT_WHAT="re-check (${WHY% - *})"
    elif [[ ${S[RUN_STATE]} == paused ]]; then
        due=$(( ${S[LAST_RUN_START]} + CATCHUP_INTERVAL - INTERVAL_SLACK )); NEXT_WHAT="resume paused scrub"
    else
        case ${S[LAST_RESULT]} in
            halved|widened|interrupted|canceled|error)
                due=$(( ${S[LAST_RUN_START]} + CATCHUP_INTERVAL - INTERVAL_SLACK ))
                NEXT_WHAT="catch-up after ${S[LAST_RESULT]}" ;;
        esac
        if [[ -z $due ]] && (( ${S[WATERMARK]} < ${S[CYCLE_END]} )); then
            due=$(( ${S[LAST_RUN_START]} + CONTINUE_INTERVAL - INTERVAL_SLACK ))
            NEXT_WHAT="catch-up toward cycle end $(zdate "${S[CYCLE_END]}")"
        fi
        if [[ -z $due ]]; then
            month=$(date -d "@$t" +%Y-%m); day=$(date -d "@$t" +%-d)
            if [[ $month != "${S[LAST_CYCLE_MONTH]}" ]] && (( day < MONTHLY_DAY )); then
                due=$(date -d "$month-$(printf %02d "$MONTHLY_DAY")" +%s)
            else
                due=$(date -d "$month-01 + 1 month + $(( MONTHLY_DAY - 1 )) days" +%s)
            fi
            NEXT_WHAT="new monthly cycle"
        fi
    fi
    NEXT_AT=$(next_fire "$due")
    [[ -r $(deferred_file "$POOL") ]] && NEXT_WHAT+="; DEFERRED until $(cut -d' ' -f3 "$(deferred_file "$POOL")") finishes"
}

next_start_line() {
    next_start
    if (( NEXT_AT == 0 )); then echo "$NEXT_WHAT"; return; fi
    local note="" sd
    if [[ -z ${ORCD_TEST_CLOCK:-} ]] && command -v systemctl >/dev/null \
       && ! systemctl is-enabled -q "orcd-scrub@$POOL.timer" 2>/dev/null; then
        note="  WARNING: orcd-scrub@$POOL.timer is not enabled"
    fi
    sd=""; [[ $TIMER_DELAY != 0 ]] && sd=" (+ up to $TIMER_DELAY)"
    echo "$(date -d "@$NEXT_AT" '+%a %Y-%m-%d %H:%M %Z')$sd - $NEXT_WHAT$note"
}

# Sets WIN_S, WIN_E, WIN_LIMITED (1 if capped by WINDOW_LIMIT)
compute_window() {
    local t; t=$(floor_min "$(now)")
    WIN_S=$(floor_min $(( ${S[WATERMARK]} - OVERLAP )))
    WIN_E=$t; WIN_LIMITED=0
    local lim=${S[WINDOW_LIMIT]}
    if (( lim > 0 && WIN_S + lim < t )); then
        WIN_E=$(floor_min $(( WIN_S + lim ))); WIN_LIMITED=1
    fi
    (( WIN_E > WIN_S )) || die "empty window $(zdate "$WIN_S") .. $(zdate "$WIN_E")"
}

# ------------------------------------------------------------------ actions
on_success() {
    local t0=$1 t1=$2 dur=$(( $2 - $1 ))
    local note="repaired=${SCAN_REPAIRED:-?} errors=${SCAN_ERRORS:-?}"
    # A window that finishes while zpool still showed < 50 % done means % done /
    # ETA are relative to the whole pool, not to -S/-E: stop trusting the ETA.
    if [[ -n ${LAST_PCT:-} && ${S[ETA_TRUST]} == yes ]] && (( dur >= 3600 && ${LAST_PCT%.*} < 50 )); then
        S[ETA_TRUST]=no; note+=" eta-untrusted(last ${LAST_PCT}%)"
        [[ $ETA_CUT == auto ]] && alert "window finished while zpool reported only ${LAST_PCT}% done - zpool's ETA is not relative to the -S/-E window here; ETA-based early cut disabled for $POOL (MAX_RUNTIME still enforced). Undo: $PROG reset-limit $POOL"
    fi
    if [[ ${SCAN_ERRORS:-0} != 0 ]]; then
        alert "scrub of window $(zdate "${S[ACTIVE_START]}")..$(zdate "${S[ACTIVE_END]}") finished with ${SCAN_ERRORS} errors"
        if [[ $ADVANCE_ON_ERRORS != yes ]]; then
            S[LAST_RESULT]=error; S[RUN_STATE]=idle; S[LAST_RUN_END]=$t1
            hist_add error "$t0" "$t1" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" "$note"
            state_save; return
        fi
    fi
    S[WATERMARK]=${S[ACTIVE_END]}
    (( ${S[CYCLE_END]} < ${S[ACTIVE_END]} )) && S[CYCLE_END]=${S[ACTIVE_END]}
    # grow the learned limit when measured throughput says 2x would still fit
    # comfortably: total/win * 2*limit < MAX_RUNTIME * GROW_HEADROOM%
    # (total includes sessions before a pause, else a resumed window looks fast)
    local win=$(( ${S[ACTIVE_END]} - ${S[ACTIVE_START]} )) total=$(( dur + ${S[ACTIVE_ACC]:-0} ))
    (( ${S[ACTIVE_ACC]:-0} > 0 )) && note+=" total=$(hdur "$total")"
    S[ACTIVE_ACC]=0
    if [[ $LEARN_LIMIT == yes ]] && (( ${S[WINDOW_LIMIT]} > 0 && win > 0 )) \
       && (( total * 2 * ${S[WINDOW_LIMIT]} * 100 < MAX_RUNTIME * GROW_HEADROOM * win )); then
        S[WINDOW_LIMIT]=$(( ${S[WINDOW_LIMIT]} * 2 ))
        note+=" limit->$(hdur "${S[WINDOW_LIMIT]}")"
    fi
    [[ $LEARN_LIMIT == yes ]] || S[WINDOW_LIMIT]=0
    S[LAST_RESULT]=completed; S[RUN_STATE]=idle; S[LAST_RUN_END]=$t1
    state_save
    hist_add completed "$t0" "$t1" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" "$note"
    log "completed in $(hdur "$dur") ($note); watermark -> $(zdate "${S[WATERMARK]}")"
}

hdur_to_s() {  # "2d08h00m" -> seconds ("" if not that format)
    [[ $1 =~ ^([0-9]+)d([0-9]+)h([0-9]+)m$ ]] || { echo ""; return; }
    echo $(( 10#${BASH_REMATCH[1]}*86400 + 10#${BASH_REMATCH[2]}*3600 + 10#${BASH_REMATCH[3]}*60 ))
}
pct_bp() {  # "22.39" -> 2239 (basis points)
    local p=${1:-0} i f=""
    i=${p%%.*}; [[ $p == *.* ]] && f=${p#*.}; f="${f}00"
    echo $(( 10#${i:-0} * 100 + 10#${f:0:2} ))
}

# Reference from the last cut: REF_START, REF_WIN, REF_PROJ (projected total
# runtime of that window). Falls back to the last "halved" history line, so
# state written by older versions works too.
cut_ref() {
    REF_START=${S[CUT_START]:-0} REF_WIN=${S[CUT_WIN]:-0} REF_PROJ=${S[CUT_PROJ]:-0}
    (( REF_PROJ > 0 )) && return 0
    local h line ws we note el eta bp; h=$(history_file)
    [[ -r $h ]] || return 0
    line=$(grep -E '^[^#].*\|halved\|' "$h" | tail -1)
    [[ -n $line ]] || return 0
    IFS='|' read -r _ _ _ _ ws we note <<<"$line"
    if [[ $note =~ ETA\ ([0-9dhm]+)\ after\ ([0-9dhm]+) ]]; then
        eta=$(hdur_to_s "${BASH_REMATCH[1]}"); el=$(hdur_to_s "${BASH_REMATCH[2]}")
        [[ -n $eta && -n $el ]] && REF_PROJ=$(( el + eta ))
    elif [[ $note =~ MAX_RUNTIME\ ([0-9dhm]+)\ at\ ([0-9.]+)% ]]; then
        el=$(hdur_to_s "${BASH_REMATCH[1]}"); bp=$(pct_bp "${BASH_REMATCH[2]}")
        [[ -n $el ]] && (( bp > 0 )) && REF_PROJ=$(( el * 10000 / bp ))
    fi
    REF_START=$(date -d "$ws" +%s 2>/dev/null || echo 0)
    REF_WIN=$(( $(date -d "$we" +%s 2>/dev/null || echo 0) - REF_START ))
}

# True if a window with the same start but a clearly different length needs
# about the same scrub time - e.g. -S predates the pool's date->txg history, so
# every such window is a full-pool scrub. Halving cannot help then.
work_ignores_window() {  # win proj   (remembers the verdict for this window start)
    local win=$1 proj=$2 d
    cut_ref
    [[ ${S[NOSHRINK_START]:-0} != 0 && ${S[NOSHRINK_START]} == "${S[ACTIVE_START]}" ]] && return 0
    (( proj > 0 && REF_PROJ > 0 && REF_WIN > 0 )) || return 1
    d=$(( ${S[ACTIVE_START]} - REF_START )); (( d < 0 )) && d=$(( -d ))
    (( d <= 7200 )) || return 1
    if (( win * 3 <= REF_WIN * 2 )); then        # window shrank to <= 2/3 ...
        (( proj * 100 >= REF_PROJ * 75 )) || return 1   # ... but work did not
    elif (( win * 2 >= REF_WIN * 3 )); then      # window grew to >= 3/2 ...
        (( proj * 100 <= REF_PROJ * 133 )) || return 1  # ... but work did not
    else
        return 1
    fi
    S[NOSHRINK_START]=${S[ACTIVE_START]}
}

# What to do with a window that will not finish within MAX_RUNTIME: halve | pause
slow_action() {  # win proj
    local win=$1 proj=$2
    (( win / 2 >= MIN_WINDOW )) || { echo pause; return; }
    case $ON_TOO_SLOW in
        pause) echo pause ;;
        halve) echo halve ;;
        *) if work_ignores_window "$win" "$proj"; then echo pause; else echo halve; fi ;;
    esac
}

on_too_slow() {  # stop + halve, or pause (resumed on the next catch-up run)
    # $3 = projected total runtime of this window, 0 if unknown
    local t0=$1 why=$2 proj=${3:-0} t1 win=$(( ${S[ACTIVE_END]} - ${S[ACTIVE_START]} ))
    t1=$(now)
    if [[ $(slow_action "$win" "$proj") == halve ]]; then
        S[CUT_START]=${S[ACTIVE_START]}; S[CUT_WIN]=$win; S[CUT_PROJ]=$proj
        # halve; halve again while the projected time of the smaller window still
        # exceeds GROW_HEADROOM% of MAX_RUNTIME (bounded by SHRINK_MAX_HALVINGS, MIN_WINDOW)
        local new=$(( win / 2 )) n=1 p=$(( proj / 2 ))
        local target=$(( MAX_RUNTIME * GROW_HEADROOM / 100 ))
        while (( proj > 0 && p > target && n < SHRINK_MAX_HALVINGS && new / 2 >= MIN_WINDOW )); do
            new=$(( new / 2 )); p=$(( p / 2 )); n=$(( n + 1 ))
        done
        $ZPOOL scrub -s "$POOL" || warn "zpool scrub -s failed"
        S[WINDOW_LIMIT]=$new
        S[LAST_RESULT]=halved; S[RUN_STATE]=idle; S[LAST_RUN_END]=$t1
        state_save
        hist_add halved "$t0" "$t1" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" "$why; /$(( 1 << n ))"
        alert "scrub stopped ($why); window cut to 1/$(( 1 << n )) = $(hdur "${S[WINDOW_LIMIT]}"), next try $(zdate "${S[ACTIVE_START]}")..$(zdate $(( ${S[ACTIVE_START]} + ${S[WINDOW_LIMIT]} ))) in ~$(hdur "$CATCHUP_INTERVAL")"
    elif [[ $ON_TOO_SLOW != pause ]] && (( ${S[ACTIVE_END]} < ${S[CYCLE_END]} )) \
         && work_ignores_window "$win" "$proj"; then
        # finishing this cut window would leave the watermark where the next
        # window costs as much again: drop it, next run scrubs start..now
        $ZPOOL scrub -s "$POOL" || warn "zpool scrub -s failed"
        S[WINDOW_LIMIT]=0
        S[LAST_RESULT]=widened; S[RUN_STATE]=idle; S[LAST_RUN_END]=$t1
        state_save
        hist_add widened "$t0" "$t1" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" "$why; work does not shrink with the window"
        alert "scrub stopped ($why); work does not shrink with the window (last cut $(hdur "$REF_WIN") ~$(hdur "$REF_PROJ"), this $(hdur "$win") ~$(hdur "$proj")) - next try $(zdate "${S[ACTIVE_START]}")..now, finished over several sessions, in ~$(hdur "$CATCHUP_INTERVAL")"
    else
        local reason
        $ZPOOL scrub -p "$POOL" || warn "zpool scrub -p failed"
        if (( win / 2 < MIN_WINDOW )); then
            reason="window at minimum"; S[WINDOW_LIMIT]=$win
        elif work_ignores_window "$win" "$proj"; then
            reason="work does not shrink with the window (last cut: $(hdur "$REF_WIN") needed ~$(hdur "$REF_PROJ"), this $(hdur "$win") ~$(hdur "$proj")) - finishing it incrementally"
        else
            reason="ON_TOO_SLOW=pause"
            [[ $LEARN_LIMIT == yes ]] && S[WINDOW_LIMIT]=$(( win / 2 ))
        fi
        S[ACTIVE_ACC]=$(( ${S[ACTIVE_ACC]:-0} + t1 - SEG_T0 ))
        S[LAST_RESULT]=paused; S[RUN_STATE]=paused; S[LAST_RUN_END]=$t1
        state_save
        hist_add paused "$t0" "$t1" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" "$why; $reason"
        alert "window $(hdur "$win") still too slow ($why); scrub PAUSED ($reason), will resume in ~$(hdur "$CATCHUP_INTERVAL")"
    fi
}

# The cut window costs as much as the window it was cut from: restart it as
# ACTIVE_START..now in the same session (same price, but the watermark then
# jumps past the region that makes every window expensive).
widen_window() {  # t0 win proj
    local t1 e; t1=$(now); e=$(floor_min "$t1")
    $ZPOOL scrub -s "$POOL" || warn "zpool scrub -s failed"
    hist_add widened "$1" "$t1" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" \
        "work does not shrink with the window (last cut $(hdur "$REF_WIN") ~$(hdur "$REF_PROJ"), this $(hdur "$2") ~$(hdur "$3")); restarted as ..$(zdate "$e")"
    if ! $ZPOOL scrub -S "$(zdate "${S[ACTIVE_START]}")" -E "$(zdate "$e")" "$POOL"; then
        S[RUN_STATE]=idle; S[LAST_RESULT]=error; S[LAST_RUN_END]=$t1; S[WINDOW_LIMIT]=0; state_save
        alert "could not restart widened window $(zdate "${S[ACTIVE_START]}")..$(zdate "$e")"; return 1
    fi
    alert "work does not shrink with the window ($(hdur "$2") ~$(hdur "$3"), last cut $(hdur "$REF_WIN") ~$(hdur "$REF_PROJ")); restarted as $(zdate "${S[ACTIVE_START]}")..$(zdate "$e"), finished over several sessions"
    S[ACTIVE_END]=$e; S[ACTIVE_ACC]=0; S[WINDOW_LIMIT]=0
    (( ${S[CYCLE_END]} < e )) && S[CYCLE_END]=$e
    state_save
}

eta_cut_enabled() {
    case $ETA_CUT in
        yes) return 0 ;;
        no)  return 1 ;;
        *)   [[ ${S[ETA_TRUST]} == yes ]] ;;
    esac
}

# Alert (once per run) when the watermark lags too far behind: windows that fit
# into MAX_RUNTIME, scrubbed every CONTINUE_INTERVAL, cannot keep up with writes.
check_lag() {
    (( LAG_ALERT > 0 && ${S[WATERMARK]} > 0 )) || return 0
    local lag=$(( $(now) - ${S[WATERMARK]} ))
    (( lag > LAG_ALERT )) || return 0
    alert "watermark $(zdate "${S[WATERMARK]}") is $(hdur "$lag") behind (LAG_ALERT $(hdur "$LAG_ALERT")); window limit $(hdur "${S[WINDOW_LIMIT]}"), catch-ups every $(hdur "$CONTINUE_INTERVAL") - consider a shorter continue-interval or a longer max-runtime"
}

TERMINATED=0
LAST_PCT=""
SEG_T0=0    # start of the current zpool scrub within this session
on_term() { TERMINATED=1; }

monitor() {  # $1 = session start epoch
    local t0=$1 t el keep_going=0; SEG_T0=$1
    trap on_term TERM INT
    while :; do
        if (( TERMINATED )); then
            $ZPOOL scrub -p "$POOL" 2>/dev/null || true
            S[RUN_STATE]=paused; S[LAST_RESULT]=paused; S[LAST_RUN_END]=$(now)
            S[ACTIVE_ACC]=$(( ${S[ACTIVE_ACC]:-0} + $(now) - SEG_T0 ))
            state_save
            hist_add paused "$t0" "$(now)" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" "service stopped"
            warn "terminated - scrub paused, will resume on next catch-up run"
            exit 0
        fi
        scan_parse
        t=$(now); el=$(( t - t0 ))
        case $SCAN_STATE in
            finished)
                if (( SCAN_END_EPOCH > 0 && SCAN_END_EPOCH + 120 < ${S[ACTIVE_SINCE]} )); then
                    warn "finished-scrub timestamp predates our start; assuming ours anyway"
                fi
                on_success "$t0" "$t"; return 0 ;;
            canceled|none|resilvering|paused)
                S[RUN_STATE]=idle; S[LAST_RESULT]=canceled; S[LAST_RUN_END]=$t
                [[ $SCAN_STATE == paused ]] && { S[RUN_STATE]=paused; S[LAST_RESULT]=paused
                                                 S[ACTIVE_ACC]=$(( ${S[ACTIVE_ACC]:-0} + t - SEG_T0 )); }
                state_save
                hist_add "${S[LAST_RESULT]}" "$t0" "$t" "${S[ACTIVE_START]}" "${S[ACTIVE_END]}" "external: $SCAN_STATE"
                alert "scrub ended unexpectedly (pool scan state: $SCAN_STATE); watermark not advanced"
                return 1 ;;
        esac
        # still scrubbing
        LAST_PCT=$SCAN_PCT
        local win=$(( ${S[ACTIVE_END]} - ${S[ACTIVE_START]} )) acc=${S[ACTIVE_ACC]:-0} bp proj
        local sel=$(( t - SEG_T0 ))    # runtime of the current zpool scrub in this session
        if (( el >= MAX_RUNTIME )); then
            bp=$(pct_bp "${SCAN_PCT:-0}"); proj=0
            (( bp > 0 )) && proj=$(( (acc + sel) * 10000 / bp ))
            on_too_slow "$t0" "hit MAX_RUNTIME $(hdur "$MAX_RUNTIME") at ${SCAN_PCT:-?}%" "$proj"; return 1
        fi
        if (( el >= CHECK_AFTER && ! keep_going )) && [[ -n $SCAN_ETA ]] && eta_cut_enabled \
           && (( win >= 2 * MIN_WINDOW )) && (( el + SCAN_ETA > MAX_RUNTIME )); then
            proj=$(( acc + sel + SCAN_ETA ))
            if [[ $(slow_action "$win" "$proj") == pause ]]; then
                keep_going=1
                if [[ $ON_TOO_SLOW != pause ]] && (( ${S[ACTIVE_END]} < ${S[CYCLE_END]} )) \
                   && work_ignores_window "$win" "$proj"; then
                    widen_window "$t0" "$win" "$proj" || return 1
                    SEG_T0=$(now)
                else
                    work_ignores_window "$win" "$proj" || true
                    log "ETA $(hdur "$SCAN_ETA") after $(hdur "$el") (${SCAN_PCT:-?}%) exceeds $(hdur "$MAX_RUNTIME"), but halving would not help - continuing to MAX_RUNTIME, then pause"
                fi
            else
                on_too_slow "$t0" "ETA $(hdur "$SCAN_ETA") after $(hdur "$el") (${SCAN_PCT:-?}%) exceeds $(hdur "$MAX_RUNTIME")" "$proj"
                return 1
            fi
        fi
        nap "$POLL_INTERVAL" &
        wait $! 2>/dev/null || true
    done
}

# -------------------------------------------------------------------- cmds
cmd_init() {
    local baseline="" start_now=0 reinit=0
    while (( $# )); do
        case $1 in
            --baseline) baseline=$2; shift 2 ;;
            --start-now) start_now=1; shift ;;
            --reinit) reinit=1; shift ;;
            *) POOL=$1; shift ;;
        esac
    done
    [[ -n ${POOL:-} ]] || die "init: pool required"
    $ZPOOL list -H -o name "$POOL" >/dev/null 2>&1 || die "pool $POOL not found"
    if state_load && [[ $reinit == 0 ]]; then
        log "state exists (watermark $(zdate "${S[WATERMARK]}")); use --reinit to overwrite"; return 0
    fi
    state_load || true
    local wm=0
    if [[ -n $baseline ]]; then
        wm=$(date -d "$baseline" +%s) || die "bad --baseline '$baseline'"
    else
        scan_parse
        if [[ $SCAN_STATE == finished && $SCAN_END_EPOCH -gt 0 ]]; then
            wm=$SCAN_END_EPOCH; log "baseline from last completed scrub: $(hdate "$wm")"
        elif [[ -n $DEFAULT_BASELINE ]]; then
            wm=$(date -d "$DEFAULT_BASELINE" +%s)
        else
            die "no completed scrub found on $POOL; pass --baseline"
        fi
    fi
    local t; t=$(now)
    S[WATERMARK]=$wm; S[CYCLE_END]=$wm; S[WINDOW_LIMIT]=0
    S[LAST_RESULT]=none; S[RUN_STATE]=idle; S[LAST_RUN_START]=0; S[LAST_RUN_END]=0
    if [[ $start_now == 1 ]]; then S[LAST_CYCLE_MONTH]=""; else S[LAST_CYCLE_MONTH]=$(date -d "@$t" +%Y-%m); fi
    state_save
    log "initialised: watermark $(zdate "$wm"); first cycle: $([[ $start_now == 1 ]] && echo 'next timer run' || echo "day $MONTHLY_DAY of next month")"
}

cmd_run() {
    while (( $# )); do
        case $1 in
            --force) FORCE=1; shift ;;
            --dry-run) DRY_RUN=1; shift ;;
            *) POOL=$1; shift ;;
        esac
    done
    [[ -n ${POOL:-} ]] || die "run: pool required"
    (( MIN_WINDOW > OVERLAP )) || die "MIN_WINDOW must be larger than OVERLAP"
    $ZPOOL list -H -o name "$POOL" >/dev/null 2>&1 || die "pool $POOL not found"
    supports_range || die "'zpool scrub -S/-E' not supported by $($ZPOOL version 2>/dev/null | head -1) (need OpenZFS >= 2.4)"
    mkdir -p "$STATE_DIR"
    exec 9>"$STATE_DIR/$POOL.lock"
    flock -n 9 || die "another $PROG instance holds the lock for $POOL"
    state_load || die "no state for $POOL - run: $PROG init $POOL --baseline 'YYYY-MM-DD'"

    local dfile; dfile=$(deferred_file "$POOL")
    if [[ -r $dfile ]] && [[ $(cut -d' ' -f1 "$dfile") == force ]]; then
        FORCE=1; log "picking up deferred forced run"
    fi
    if ! decide; then
        log "not due: $WHY"; [[ ${DRY_RUN:-0} == 1 ]] || rm -f "$dfile"; return 0
    fi
    log "due: $WHY"

    if [[ $WHY == finished-unattended ]]; then
        log "our scrub of $(zdate "${S[ACTIVE_START]}")..$(zdate "${S[ACTIVE_END]}") finished unattended on $(hdate "$SCAN_END_EPOCH")"
        [[ ${DRY_RUN:-0} == 1 ]] && return 0
        on_success "${S[ACTIVE_SINCE]}" "$SCAN_END_EPOCH"
        check_lag; kick_deferred; return 0
    fi

    # host-wide critical section: check other pools + start ours atomically, so
    # two timers firing together cannot both start
    local blocker=""
    if [[ $WHY != adopt ]]; then
        exec 8>"$STATE_DIR/.host.lock"
        flock -w 120 8 || die "could not get host lock"
        if blocker=$(other_pool_busy); then
            defer_run "$blocker"; flock -u 8; exec 8>&-; return 0
        fi
    fi
    [[ ${DRY_RUN:-0} == 1 ]] || rm -f "$dfile"
    local t0; t0=$(now)

    case $WHY in
        adopt)
            log "re-attaching to running scrub of $(zdate "${S[ACTIVE_START]}")..$(zdate "${S[ACTIVE_END]}")"
            [[ ${DRY_RUN:-0} == 1 ]] && return 0
            local rc=0; monitor "${S[ACTIVE_SINCE]}" || rc=$?
            check_lag; kick_deferred; return "$rc" ;;
        resume)
            log "resuming paused scrub of $(zdate "${S[ACTIVE_START]}")..$(zdate "${S[ACTIVE_END]}")"
            [[ ${DRY_RUN:-0} == 1 ]] && return 0
            $ZPOOL scrub "$POOL" || { S[RUN_STATE]=idle; S[LAST_RESULT]=error; state_save; die "resume failed"; }
            ;;
        *)
            compute_window
            [[ $WHY == "new monthly cycle"* ]] && S[LAST_CYCLE_MONTH]=$(date -d "@$t0" +%Y-%m)
            if (( ! WIN_LIMITED )); then
                S[CYCLE_END]=$WIN_E; S[LAST_CYCLE_MONTH]=$(date -d "@$t0" +%Y-%m)
            elif [[ $WHY == "new monthly cycle"* ]]; then
                S[CYCLE_END]=$(floor_min "$t0")
            fi
            log "scrubbing window $(zdate "$WIN_S") .. $(zdate "$WIN_E") ($(hdur $(( WIN_E - WIN_S ))))$( (( WIN_LIMITED )) && echo ", capped by learned limit $(hdur "${S[WINDOW_LIMIT]}")")"
            if [[ ${DRY_RUN:-0} == 1 ]]; then
                echo "  would run: $ZPOOL scrub -S '$(zdate "$WIN_S")' -E '$(zdate "$WIN_E")' $POOL"; return 0
            fi
            $ZPOOL scrub -S "$(zdate "$WIN_S")" -E "$(zdate "$WIN_E")" "$POOL" \
                || { S[LAST_RESULT]=error; S[LAST_RUN_START]=$t0; S[LAST_RUN_END]=$(now); state_save
                     die "zpool scrub -S/-E failed to start"; }
            S[ACTIVE_START]=$WIN_S; S[ACTIVE_END]=$WIN_E; S[ACTIVE_ACC]=0
            ;;
    esac
    S[RUN_STATE]=running; S[ACTIVE_SINCE]=$t0; S[LAST_RUN_START]=$t0; S[LAST_RUN_END]=0
    state_save
    if [[ $WHY != adopt ]]; then flock -u 8; exec 8>&-; fi
    local rc=0
    monitor "$t0" || rc=$?
    check_lag
    kick_deferred
    return "$rc"
}

cmd_plan() {
    POOL=${1:?plan: pool required}
    state_load || die "no state for $POOL"
    FORCE=0; DRY_RUN=1
    if decide; then
        local b; if [[ $WHY != adopt ]] && b=$(other_pool_busy); then echo "$POOL: DUE but would be DEFERRED ($WHY; $b)"; return 0; fi
        echo "$POOL: DUE ($WHY)"
        if [[ $WHY != adopt && $WHY != resume && $WHY != finished-unattended ]]; then
            compute_window
            echo "  window: $(zdate "$WIN_S") .. $(zdate "$WIN_E") ($(hdur $(( WIN_E - WIN_S ))))"
        fi
    else
        echo "$POOL: not due ($WHY)"
        echo "  next start: $(next_start_line)"
    fi
}

cmd_status() {
    local pools=("$@")
    if (( ${#pools[@]} == 0 )); then
        local f; for f in "$STATE_DIR"/*.state; do [[ -e $f ]] && pools+=("$(basename "$f" .state)"); done
    fi
    (( ${#pools[@]} )) || { echo "no pools initialised in $STATE_DIR"; return 0; }
    for POOL in "${pools[@]}"; do
        state_load || { echo "$POOL: no state"; continue; }
        local lim=unlimited; (( ${S[WINDOW_LIMIT]} > 0 )) && lim=$(hdur "${S[WINDOW_LIMIT]}")
        scan_parse
        cat <<EOF
== $POOL ==
  watermark      : $(zdate "${S[WATERMARK]}")  ($(hdur $(( $(now) - ${S[WATERMARK]} ))) ago; newer data not yet scrubbed, minus overlap)
  cycle end      : $(zdate "${S[CYCLE_END]}")  cycle month: ${S[LAST_CYCLE_MONTH]:-none}
  window limit   : $lim   (max runtime $(hdur "$MAX_RUNTIME"), check after $(hdur "$CHECK_AFTER"), ETA cut: $(eta_cut_enabled && echo on || echo off))
  run state      : ${S[RUN_STATE]}   last result: ${S[LAST_RESULT]}$( [[ -r $(deferred_file "$POOL") ]] && echo "   DEFERRED behind $(cut -d' ' -f3 "$(deferred_file "$POOL")") since $(hdate "$(cut -d' ' -f2 "$(deferred_file "$POOL")")")")
  last run       : $( (( ${S[LAST_RUN_START]} )) && echo "$(hdate "${S[LAST_RUN_START]}") -> $( (( ${S[LAST_RUN_END]} )) && hdate "${S[LAST_RUN_END]}" || echo '...')" || echo never)
  active window  : $( (( ${S[ACTIVE_START]} )) && echo "$(zdate "${S[ACTIVE_START]}") .. $(zdate "${S[ACTIVE_END]}")" || echo -)
  pool scan      : $SCAN_STATE ${SCAN_PCT:+($SCAN_PCT% done${SCAN_ETA:+, ETA $(hdur "$SCAN_ETA")})}
  next start     : $(next_start_line)
EOF
        local h; h=$(history_file)
        [[ -s $h ]] && { echo "  recent history:"; grep -v '^#' "$h" | tail -5 | sed 's/^/    /'; }
    done
}

cmd_kick() {
    POOL=${1:?kick: pool required}
    state_load || die "no state for $POOL"
    mkdir -p "$STATE_DIR"
    exec 9>"$STATE_DIR/$POOL.lock"
    flock -n 9 || die "a run is active on $POOL - stop it first: systemctl stop orcd-scrub@$POOL"
    printf 'force %s kick\n' "$(now)" > "$(deferred_file "$POOL")"
    flock -u 9; exec 9>&-
    if [[ -n ${ORCD_TEST_CLOCK:-} ]] || ! command -v systemctl >/dev/null; then
        log "forced run queued; start it with: $PROG run $POOL"; return 0
    fi
    systemctl start --no-block "orcd-scrub@$POOL.service" || die "systemctl start orcd-scrub@$POOL.service failed"
    log "started orcd-scrub@$POOL.service (forced run); follow with: journalctl -fu orcd-scrub@$POOL"
}

# Apply the current config to a running scrub of ours WITHOUT pausing it:
# the monitor (not the scrub) is killed with SIGKILL, so its pause-on-stop
# handler does not run; zfs keeps scrubbing; a fresh service re-attaches
# (adopt) with the new settings and the new systemd start timeout. Runtime
# since the session start still counts toward MAX_RUNTIME.
cmd_reattach() {
    POOL=${1:?reattach: pool required}
    state_load || die "no state for $POOL"
    scan_parse
    [[ ${S[RUN_STATE]} == running && $SCAN_STATE == scrubbing ]] \
        || die "no running scrub of ours on $POOL (run state ${S[RUN_STATE]}, pool scan $SCAN_STATE) - nothing to re-attach; use '$PROG kick $POOL'"
    command -v systemctl >/dev/null || die "systemctl not found"
    local u="orcd-scrub@$POOL.service" i
    write_timeout_dropin
    if systemctl is-active -q "$u"; then
        log "detaching the old monitor of $u (SIGKILL; the zfs scrub keeps running)"
        systemctl kill --kill-whom=all -s SIGKILL "$u" || die "systemctl kill $u failed"
        for (( i = 0; i < 30; i++ )); do systemctl is-active -q "$u" || break; sleep 1; done
        systemctl is-active -q "$u" && die "$u still active after SIGKILL"
    fi
    systemctl reset-failed "$u" 2>/dev/null || true
    scan_parse
    [[ $SCAN_STATE == scrubbing ]] || die "pool scan is now '$SCAN_STATE' (expected scrubbing) - check 'zpool status $POOL'"
    systemctl start --no-block "$u" || die "systemctl start $u failed"
    log "re-attached: $u monitors the running scrub with the current settings (max $(hdur "$MAX_RUNTIME"), check $(hdur "$CHECK_AFTER"), on-too-slow $ON_TOO_SLOW); follow with: journalctl -fu $u"
}

cmd_reset_limit() {
    POOL=${1:?pool required}; state_load || die "no state"
    S[WINDOW_LIMIT]=0; S[ETA_TRUST]=yes; state_save; log "window limit cleared, zpool ETA trusted again"
}

# ------------------------------------------------------------- config / set
# "24h" "90m" "2d" "3600" "3600s" -> seconds
parse_dur() {
    [[ $1 =~ ^([0-9]+)([smhd]?)$ ]] || return 1
    local n=${BASH_REMATCH[1]}
    case ${BASH_REMATCH[2]} in
        d) echo $(( n*86400 )) ;; h) echo $(( n*3600 )) ;; m) echo $(( n*60 )) ;; *) echo "$n" ;;
    esac
}
dur_expr() {  # seconds -> readable shell arithmetic for the config file
    local s=$1
    if   (( s % 86400 == 0 )); then echo "\$(($(( s/86400 ))*86400))"
    elif (( s % 3600 == 0 ));  then echo "\$(($(( s/3600 ))*3600))"
    else echo "$s"; fi
}

conf_set() {  # KEY VALUE
    local key=$1 val=$2 tag
    tag="# set $(date '+%F %H:%M') via '$PROG set'"
    [[ -e $CONF_FILE ]] || echo "# /etc/orcd-scrub.conf - sourced by $PROG" > "$CONF_FILE"
    if grep -qE "^${key}=" "$CONF_FILE"; then
        sed -i -E "s|^${key}=.*|${key}=${val}   ${tag}|" "$CONF_FILE"
    else
        echo "${key}=${val}   ${tag}" >> "$CONF_FILE"
    fi
}

# systemd must not kill a run before the script's own MAX_RUNTIME logic acts
write_timeout_dropin() {
    [[ -n ${ORCD_TEST_CLOCK:-} && -z ${ORCD_DROPIN_DIR:-} ]] && return 0
    local h=$(( (MAX_RUNTIME + 3600 + 3599) / 3600 ))
    mkdir -p "$DROPIN_DIR" || { warn "cannot create $DROPIN_DIR"; return 0; }
    printf '# written by %s: MAX_RUNTIME (%s) + 1h\n[Service]\nTimeoutStartSec=%sh\n' \
        "$PROG" "$(hdur "$MAX_RUNTIME")" "$h" > "$DROPIN_DIR/10-timeout.conf"
    [[ -z ${ORCD_TEST_CLOCK:-} ]] && command -v systemctl >/dev/null && systemctl daemon-reload 2>/dev/null
    log "systemd TimeoutStartSec set to ${h}h ($DROPIN_DIR/10-timeout.conf)"
}

# Reset run bookkeeping so a new run is due right away. Keeps the watermark.
reset_run_info() {
    POOL=$1
    state_load || { warn "no state for $POOL - skipped"; return 0; }
    exec 9>"$STATE_DIR/$POOL.lock"
    if ! flock -n 9; then
        exec 9>&-
        die "a run is active on $POOL - stop it first: systemctl stop orcd-scrub@$POOL (and any manual run)"
    fi
    scan_parse
    if [[ ${S[RUN_STATE]} == running && $SCAN_STATE == scrubbing ]]; then
        flock -u 9; exec 9>&-
        die "our scrub of $(zdate "${S[ACTIVE_START]}")..$(zdate "${S[ACTIVE_END]}") is running unmonitored - not cancelling it. Use '$PROG set --no-reset ...' and then '$PROG kick $POOL' to re-attach"
    fi
    if [[ ${S[RUN_STATE]} == paused && $SCAN_STATE == paused ]]; then
        log "cancelling our ${SCAN_STATE} scrub of $(zdate "${S[ACTIVE_START]}")..$(zdate "${S[ACTIVE_END]}") (reset)"
        $ZPOOL scrub -s "$POOL" || warn "zpool scrub -s failed"
    elif [[ $SCAN_STATE == scrubbing || $SCAN_STATE == paused || $SCAN_STATE == resilvering ]]; then
        warn "pool has a foreign $SCAN_STATE - left alone; the next run will wait for it"
    fi
    local t; t=$(now)
    hist_add reset "$t" "$t" "${S[WATERMARK]}" "${S[WATERMARK]}" \
        "settings changed (max $(hdur "$MAX_RUNTIME"), check $(hdur "$CHECK_AFTER")); was ${S[LAST_RESULT]}/${S[RUN_STATE]} limit=$(hdur "${S[WINDOW_LIMIT]}")"
    S[LAST_RUN_START]=0; S[LAST_RUN_END]=0; S[LAST_RESULT]=reset; S[RUN_STATE]=idle
    S[ACTIVE_START]=0; S[ACTIVE_END]=0; S[ACTIVE_SINCE]=0; S[ACTIVE_ACC]=0
    S[WINDOW_LIMIT]=0; S[LAST_CYCLE_MONTH]=""; S[CYCLE_END]=${S[WATERMARK]}
    state_save; rm -f "$(deferred_file "$POOL")"
    flock -u 9; exec 9>&-
    log "run info reset; watermark kept at $(zdate "${S[WATERMARK]}"); next run is due now"
}

cmd_set() {
    local reset=1 start=0 pools=() k v key secs timing=0 changed=()
    local new_max=$MAX_RUNTIME new_chk=$CHECK_AFTER
    declare -A NEW=()
    while (( $# )); do
        case $1 in
            --no-reset) reset=0; shift ;;
            --start) start=1; shift ;;
            --pool) pools+=("$2"); shift 2 ;;
            *=*) k=${1%%=*}; v=${1#*=}; shift; set -- "$k" "$v" "$@" ;;
            *)  k=$1; v=${2:-}; [[ -n $v ]] || die "set: missing value for '$k'"; shift 2
                case $k in
                    max-runtime|MAX_RUNTIME)           key=MAX_RUNTIME; timing=1 ;;
                    check-after|CHECK_AFTER)           key=CHECK_AFTER; timing=1 ;;
                    poll-interval|POLL_INTERVAL)       key=POLL_INTERVAL ;;
                    overlap|OVERLAP)                   key=OVERLAP ;;
                    min-window|MIN_WINDOW)             key=MIN_WINDOW ;;
                    catchup-interval|CATCHUP_INTERVAL) key=CATCHUP_INTERVAL ;;
                    continue-interval|CONTINUE_INTERVAL) key=CONTINUE_INTERVAL ;;
                    lag-alert|LAG_ALERT)               key=LAG_ALERT ;;
                    monthly-day|MONTHLY_DAY)
                        [[ $v =~ ^([1-9]|1[0-9]|2[0-8])$ ]] || die "monthly-day must be 1..28"
                        NEW[MONTHLY_DAY]=$v; continue ;;
                    on-too-slow|ON_TOO_SLOW)
                        [[ $v =~ ^(auto|halve|pause)$ ]] || die "on-too-slow must be auto|halve|pause"
                        NEW[ON_TOO_SLOW]=$v; continue ;;
                    eta-cut|ETA_CUT)
                        [[ $v =~ ^(auto|yes|no)$ ]] || die "eta-cut must be auto|yes|no"
                        NEW[ETA_CUT]=$v; continue ;;
                    *) die "set: unknown key '$k'" ;;
                esac
                secs=$(parse_dur "$v") || die "set: bad duration '$v' (use e.g. 90m, 12h, 2d)"
                NEW[$key]=$secs ;;
        esac
    done
    (( ${#NEW[@]} )) || die "set: nothing to set (e.g. $PROG set max-runtime 24h check-after 12h)"
    [[ -n ${NEW[MAX_RUNTIME]:-} ]] && new_max=${NEW[MAX_RUNTIME]}
    [[ -n ${NEW[CHECK_AFTER]:-} ]] && new_chk=${NEW[CHECK_AFTER]}
    (( new_max >= 3600 && new_max <= 30*86400 )) || die "max-runtime must be between 1h and 30d"
    (( new_chk >= 600 && new_chk < new_max ))    || die "check-after ($(hdur "$new_chk")) must be >= 10m and < max-runtime ($(hdur "$new_max"))"
    if [[ -n ${NEW[MIN_WINDOW]:-}${NEW[OVERLAP]:-} ]]; then
        (( ${NEW[MIN_WINDOW]:-$MIN_WINDOW} > ${NEW[OVERLAP]:-$OVERLAP} )) || die "min-window must be larger than overlap"
    fi
    [[ ${DRY_RUN:-0} == 1 ]] && { for k in "${!NEW[@]}"; do echo "would set $k=${NEW[$k]}"; done; return 0; }

    # pools to reset: given, else every initialised pool
    if (( ${#pools[@]} == 0 )); then
        local f; for f in "$STATE_DIR"/*.state; do [[ -e $f ]] && pools+=("$(basename "$f" .state)"); done
    fi
    # refuse up front if any of them has an active run (before touching config)
    if (( timing && reset )); then
        local p
        for p in "${pools[@]}"; do
            exec 9>"$STATE_DIR/$p.lock"
            flock -n 9 || { exec 9>&-; POOL=$p; die "a run is active on $p - stop it first: systemctl stop orcd-scrub@$p"; }
            flock -u 9; exec 9>&-
            POOL=$p
            if state_load && scan_parse && [[ ${S[RUN_STATE]} == running && $SCAN_STATE == scrubbing ]]; then
                die "our scrub on $p is running unmonitored; a reset would cancel it. Use --no-reset, then '$PROG kick $p'"
            fi
            POOL=""
        done
    fi

    for k in "${!NEW[@]}"; do
        case $k in
            MONTHLY_DAY|ON_TOO_SLOW|ETA_CUT) conf_set "$k" "${NEW[$k]}" ;;
            *) conf_set "$k" "$(dur_expr "${NEW[$k]}")" ;;
        esac
        printf -v "$k" '%s' "${NEW[$k]}"
        changed+=("$k=${NEW[$k]}")
    done
    log "updated $CONF_FILE: ${changed[*]}"
    [[ -n ${NEW[MAX_RUNTIME]:-} ]] && write_timeout_dropin

    if (( timing && reset )); then
        local p; for p in "${pools[@]}"; do reset_run_info "$p"; done
        if (( start )); then
            for p in "${pools[@]}"; do
                if [[ -z ${ORCD_TEST_CLOCK:-} ]]; then
                    systemctl start --no-block "orcd-scrub@$p.service" && POOL=$p log "started orcd-scrub@$p.service"
                fi
            done
        else
            echo "A run is now due. Start it today with:  systemctl start --no-block orcd-scrub@<pool>.service"
            echo "(or wait for the daily timer at 02:00)"
        fi
    else
        (( timing )) && log "--no-reset: run info kept; new limits apply from the next run"
        local p
        for p in "${pools[@]}"; do
            exec 9>"$STATE_DIR/$p.lock"
            if ! flock -n 9; then
                echo "orcd-scrub@$p is running with the OLD settings. Apply them to that run without"
                echo "pausing the scrub:  $PROG reattach $p"
            else
                flock -u 9
            fi
            exec 9>&-
        done
    fi
    POOL=""
}

cmd_config() {
    local k
    echo "# effective settings (defaults + $CONF_FILE)"
    for k in MAX_RUNTIME CHECK_AFTER POLL_INTERVAL OVERLAP MIN_WINDOW CATCHUP_INTERVAL CONTINUE_INTERVAL \
             INTERVAL_SLACK LAG_ALERT; do
        printf '%-19s %8s s  (%s)\n' "$k" "${!k}" "$(hdur "${!k}")"
    done
    for k in MONTHLY_DAY LEARN_LIMIT GROW_HEADROOM SHRINK_MAX_HALVINGS ETA_CUT ON_TOO_SLOW ADVANCE_ON_ERRORS \
             SERIALIZE_POOLS DEFAULT_BASELINE MAILTO STATE_DIR; do
        printf '%-19s %s\n' "$k" "${!k}"
    done
    [[ -r $DROPIN_DIR/10-timeout.conf ]] && grep -h '^TimeoutStartSec' "$DROPIN_DIR/10-timeout.conf" | sed 's/^/systemd unit      /'
}

usage() { sed -n '3,/^set -uo/p' "$0" | sed '$d; s/^# \{0,1\}//'; }

FORCE=0; DRY_RUN=${DRY_RUN:-0}
case ${1:-} in
    run)         shift; cmd_run "$@" ;;
    plan)        shift; cmd_plan "$@" ;;
    status)      shift; cmd_status "$@" ;;
    init)        shift; cmd_init "$@" ;;
    reset-limit) shift; cmd_reset_limit "$@" ;;
    kick)        shift; cmd_kick "$@" ;;
    reattach)    shift; cmd_reattach "$@" ;;
    set)         shift; cmd_set "$@" ;;
    config)      cmd_config ;;
    sync-unit)   write_timeout_dropin ;;
    check-support) if supports_range; then echo yes; else echo no; exit 1; fi ;;
    -V|--version) echo "$PROG $VERSION" ;;
    *) usage; exit 2 ;;
esac
