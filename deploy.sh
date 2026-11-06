#!/usr/bin/env bash
# deploy.sh - push orcd-scrub to many ZFS nodes over ssh and run install.sh there.
#
#   ./deploy.sh [options] host1 host2 ...
#   ./deploy.sh [options] -f hosts.txt        (one host per line, # comments ok)
#
# Options
#   -f FILE            read hosts from FILE
#   -u USER            ssh user (default: current user; uses sudo unless root)
#   -P N               parallel hosts (default 8)
#   -o "SSH OPTS"      extra ssh options
#   --status           just show `orcd-scrub status` on each host
#   --plan             just show `orcd-scrub plan` for each managed pool
#   --check            only report pools / OpenZFS version / -S support per host
#   --cmd "ARGS"       run `orcd-scrub ARGS` on each host, e.g.
#                      --cmd "set max-runtime 24h check-after 12h --start"
#   --yes              allow destructive install args (--reinit, --purge, --force-config)
#   --                 everything after is passed to install.sh, e.g.
#                      -- --pools "data1 data2" --baseline 2026-09-01 --dry-run
#                      -- --uninstall
#
# Upgrade: `./deploy.sh -f hosts.txt` with no install args upgrades in place;
# each pool's run window (watermark, learned limit, active/paused scrub) and
# /etc/orcd-scrub.conf are kept, a running scrub is not interrupted.
#
# Pools: install.sh auto-detects pools named ^data[0-9]+$ (data1, data2, ...) on
# each host; hosts without matching pools are skipped cleanly.
# Logs: ./deploy-logs/<host>.log
set -euo pipefail

SRC_DIR=$(cd "$(dirname "$0")" && pwd)
HOSTS=(); HOSTFILE=""; SSH_USER=""; PAR=8; SSH_EXTRA=""; MODE=install; INSTALL_ARGS=(); CMD_ARGS=""; YES=0

while (( $# )); do
    case $1 in
        -f) HOSTFILE=$2; shift 2 ;;
        -u) SSH_USER=$2; shift 2 ;;
        -P) PAR=$2; shift 2 ;;
        -o) SSH_EXTRA=$2; shift 2 ;;
        --status) MODE=status; shift ;;
        --plan) MODE=plan; shift ;;
        --check) MODE=check; shift ;;
        --cmd) MODE=cmd; CMD_ARGS=$2; shift 2 ;;
        --yes) YES=1; shift ;;
        --) shift; INSTALL_ARGS=("$@"); break ;;
        -h|--help) sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        -*) echo "unknown option $1" >&2; exit 2 ;;
        *) HOSTS+=("$1"); shift ;;
    esac
done
if [[ -n $HOSTFILE ]]; then
    while read -r h _; do [[ -z $h || $h == \#* ]] || HOSTS+=("$h"); done < "$HOSTFILE"
fi
(( ${#HOSTS[@]} )) || { echo "no hosts given (see --help)" >&2; exit 2; }
if [[ $MODE == install ]] && (( ! YES )); then
    for a in "${INSTALL_ARGS[@]}"; do
        case $a in --reinit|--purge|--force-config)
            echo "refusing '$a' on ${#HOSTS[@]} host(s): it discards run-window state or config. Add --yes to confirm." >&2
            exit 2 ;;
        esac
    done
fi

for f in orcd-scrub.sh install.sh orcd-scrub.conf systemd/orcd-scrub@.service systemd/orcd-scrub@.timer; do
    [[ -f $SRC_DIR/$f ]] || { echo "missing $SRC_DIR/$f" >&2; exit 1; }
done
for f in orcd-scrub.sh install.sh; do
    bash -n "$SRC_DIR/$f" || { echo "ABORT: $SRC_DIR/$f has a syntax error (corrupted copy?) - nothing deployed" >&2; exit 1; }
done
echo "source: orcd-scrub $(sed -nE 's/^VERSION=(.*)/\1/p' "$SRC_DIR/orcd-scrub.sh"), sha256 $(sha256sum "$SRC_DIR/orcd-scrub.sh" | cut -c1-16)"

LOGDIR=$SRC_DIR/deploy-logs; mkdir -p "$LOGDIR"
BUNDLE=$(mktemp --suffix=.tgz); trap 'rm -f "$BUNDLE"' EXIT
tar -C "$SRC_DIR" -czf "$BUNDLE" orcd-scrub.sh install.sh orcd-scrub.conf systemd

# quote install args for the remote shell
Q_ARGS=""; for a in "${INSTALL_ARGS[@]}"; do Q_ARGS+=" $(printf '%q' "$a")"; done

# shellcheck disable=SC2329  # used via export -f / xargs
remote_cmd() {
    local sudo='sudo -n'
    [[ ${SSH_USER:-$USER} == root ]] && sudo=''
    case $MODE in
        install) cat <<EOF
set -e; t=\$(mktemp -d); trap 'rm -rf "\$t"' EXIT
tar -xzf - -C "\$t"
$sudo bash "\$t/install.sh"$Q_ARGS
EOF
        ;;
        status) echo "cat >/dev/null; $sudo /usr/local/sbin/orcd-scrub status" ;;
        cmd) echo "cat >/dev/null; $sudo /usr/local/sbin/orcd-scrub $CMD_ARGS" ;;
        plan) echo "cat >/dev/null; for f in /var/lib/orcd-scrub/*.state; do [ -e \"\$f\" ] && $sudo /usr/local/sbin/orcd-scrub plan \$(basename \$f .state); done" ;;
        check) cat <<'EOF'
cat >/dev/null
v=$(zpool version 2>/dev/null | head -1 || echo 'no zfs')
p=$(zpool list -H -o name 2>/dev/null | grep -E '^data[0-9]+$' | tr '\n' ' ')
o=$(zpool scrub -S 2000-01-01 -E 2000-01-02 orcd_probe_nonexistent_pool 2>&1)
if grep -qiE 'invalid option|unrecognized option' <<<"$o"; then s=NO; else s=yes; fi
echo "zfs=$v  pools=[${p:-none}]  scrub -S/-E: $s"
EOF
        ;;
    esac
}

# shellcheck disable=SC2329
deploy_one() {
    local h=$1 dest=$1 log=$LOGDIR/$1.log rc
    [[ -n $SSH_USER ]] && dest=$SSH_USER@$h
    # shellcheck disable=SC2086
    if ssh -o BatchMode=yes -o ConnectTimeout=10 $SSH_EXTRA "$dest" "bash -c $(printf '%q' "$(remote_cmd)")" \
          < "$BUNDLE" > "$log" 2>&1; then rc=0; else rc=$?; fi
    if (( rc == 0 )); then
        printf '%-20s OK\n' "$h"
    else
        printf '%-20s FAILED (rc=%d) see %s\n' "$h" "$rc" "$log"
    fi
    if [[ $MODE != install ]]; then sed "s/^/  $h: /" "$log"
    else grep -E "^\[(install|orcd-scrub)" "$log" | sed "s/^/  /" || true; fi
    (( rc == 255 )) && rc=1   # xargs stops ALL remaining hosts on exit status 255
    return "$rc"
}
export -f deploy_one remote_cmd
export SSH_USER SSH_EXTRA MODE Q_ARGS BUNDLE LOGDIR CMD_ARGS

echo "== orcd-scrub $MODE on ${#HOSTS[@]} host(s), parallel $PAR =="
set +e
printf '%s\n' "${HOSTS[@]}" | xargs -P "$PAR" -I{} bash -c 'deploy_one "$@"' _ {}
rc=$?
set -e
echo "== done (logs in $LOGDIR) =="
exit $rc
