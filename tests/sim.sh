#!/usr/bin/env bash
# Simulate months of daily timer runs against a mock zpool with a fake clock.
#   tests/sim.sh SEC_PER_DAY_OF_DATA DAYS [init args]
#   e.g. tests/sim.sh 1800 130     (30 days of data takes 15h -> halving)
#        tests/sim.sh 300 100      (fast pool -> monthly only)
#        tests/sim.sh 30000 75     (very slow -> MIN_WINDOW pause/resume)
#   env: SIM_CONF="KEY=VAL ..."   extra config lines (e.g. "CONTINUE_INTERVAL=86400")
#        MOCK_PCT_SCALE=0.05      zpool % done/ETA relative to the whole pool
#        SIM_POLL=1800            POLL_INTERVAL (larger = faster simulation)
#        MOCK_FEATURE_SINCE=2026-10-20 [MOCK_POOL_CREATED=2026-04-01]
#                                 -S before this date scrubs from pool creation
#        SIM_SCRIPT=path          script under test (default ../orcd-scrub.sh)
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
W=$(mktemp -d); trap 'rm -rf "$W"' EXIT
export ZPOOL="python3 $HERE/zpool" TZ=${TZ:-America/New_York}
export MOCK_ZPOOL_STATE=$W/mock.json ORCD_TEST_CLOCK=$W/clock MOCK_SEC_PER_DAY=$1
{ echo "STATE_DIR=$W/state"; echo "POLL_INTERVAL=${SIM_POLL:-1800}"; tr ' ' '\n' <<<"${SIM_CONF:-}"; } > "$W/conf"
export ORCD_SCRUB_CONF=$W/conf
S="bash ${SIM_SCRIPT:-$HERE/../orcd-scrub.sh}"
date -d '2026-10-23 10:00' +%s > "$W/clock"
$S init data1 --baseline 2026-09-01 ${3:-}
d0=$(date -d '2026-10-24 02:00' +%s)
for ((i=0;i<$2;i++)); do
  t=$((d0+i*86400)); (( $(cat "$W/clock") < t )) && echo $t > "$W/clock"
  out=$($S run data1 2>&1 | grep -v 'not due')
  [[ -n $out ]] && { echo "--- $(date -d @$t '+%a %F')"; echo "$out" | sed 's/^/  /'; }
done
echo; $S status data1
