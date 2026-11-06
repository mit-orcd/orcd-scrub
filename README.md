# orcd-scrub — rolling-window ZFS scrub

Replaces full-pool scrubs with **time-ranged scrubs** (`zpool scrub -S <date> -E <date>`,
OpenZFS ≥ 2.4) so that no scrub session runs longer than **24 h** (configurable).

## How it works

State per pool lives in `/var/lib/orcd-scrub/<pool>.state` (history in `<pool>.history`).
The key value is the **watermark**: everything written before it has been scrubbed.

| Situation | Action |
|---|---|
| New month, on/after day `MONTHLY_DAY` (1), watermark caught up | scrub `[watermark − 1 day, now]` |
| After 12 h, `elapsed + zpool ETA > 24 h` | `zpool scrub -s`, **halve the window** (quarter it if the ETA says half would still need > 75 % of 24 h; `SHRINK_MAX_HALVINGS`), retry 7 days later (`CATCHUP_INTERVAL`) |
| Reduced window completes | watermark → end of that window; next window starts there every `CONTINUE_INTERVAL` (default 7 d) until caught up to "now" |
| Caught up | wait for the 1st of next month |
| Window already ≤ 2 × `MIN_WINDOW` and still > 24 h | at 24 h `zpool scrub -p` (pause); resume 7 days later |
| Service stopped / node reboot mid-scrub | scrub is paused; resumed on next catch-up |
| Node crashed / service killed, our scrub finished meanwhile | credited on the next timer run (watermark advances) |
| A window finishes while zpool still showed < 50 % done | zpool's ETA is not window-relative: ETA-based early cut switched off for that pool (`ETA_CUT=auto`), 24 h hard cap stays |
| Watermark older than `LAG_ALERT` (62 d) | alert after each run: the pool cannot keep up at this cadence |
| A cut window needs about as long as the window it was cut from (same start) | halving can't help, typically because `-S` predates the pool's date→txg history so every such window is a full-pool scrub. A cut-down window is restarted as `start..now`; the window is then **finished incrementally**: run to `MAX_RUNTIME`, `zpool scrub -p`, resume on the next catch-up (`ON_TOO_SLOW=auto`) |
| Pool busy with resilver / foreign scrub | skip, try next day |
| **Another pool on the same server is scrubbing/resilvering** (`SERIALIZE_POOLS=yes`) | run is **deferred**; when the other pool's run ends it starts `orcd-scrub@<deferred>.service` (oldest first). A deferred `--force` run stays forced |

The halved size is remembered (`WINDOW_LIMIT`), so later cycles start with a window known
to fit instead of wasting another 12 h. It is doubled when measured throughput shows that
twice the window would still fit within 75 % of the max runtime (runtime before a pause
counts, so a paused-and-resumed window does not look faster than it was).

**Keeping up.** With weekly catch-ups the pool can scrub at most `MAX_RUNTIME` per
`CONTINUE_INTERVAL`. If a window that fits in 24 h covers fewer days of writes than
`CONTINUE_INTERVAL` + `OVERLAP`, the watermark falls further behind every week (the lag alert
fires). Fix by shortening the cadence (`orcd-scrub set continue-interval 1d`), raising
`max-runtime`, or reducing `OVERLAP`.

The timer fires **daily at 02:00** (±30 min); the script decides whether anything is due and
exits immediately otherwise.

## Files

| File | Installed to |
|---|---|
| `orcd-scrub.sh` | `/usr/local/sbin/orcd-scrub` |
| `orcd-scrub.conf` | `/etc/orcd-scrub.conf` (not overwritten if present; `.new` written) |
| `systemd/orcd-scrub@.service`, `systemd/orcd-scrub@.timer` | `/etc/systemd/system/` |
| `install.sh` | per-node installer |
| `deploy.sh` | multi-node ssh deployer |
| `salt/orcd-scrub/init.sls` | Salt state `engaging.role.orcd-scrub` (copy to `engaging/role/orcd-scrub/`) |
| `salt/pillar.example.sls` | host pillar example |
| `tests/` | mock `zpool` + fake-clock simulator |

## Install on one node

```bash
sudo ./install.sh --baseline 2026-09-01            # data1/data2 auto-detected
sudo ./install.sh --pools "data1" --start-now       # explicit pool, start on next timer run
sudo ./install.sh --dry-run
sudo ./install.sh --uninstall [--purge]
```

Without `--baseline`, the watermark comes from the last completed scrub in `zpool status`.
By default the first cycle runs on the 1st of next month (`--start-now` to run on the next daily fire).
The installer disables the stock `zfs-scrub-{weekly,monthly}@<pool>.timer` units and the scrub line in
`/etc/cron.d/zfsutils-linux` (Debian/Ubuntu); `--keep-stock` leaves them alone.

## Deploy to many nodes

```bash
./deploy.sh --check -f hosts.txt                          # ZFS version, data* pools, -S support
./deploy.sh -f hosts.txt -- --baseline 2026-09-01 --dry-run
./deploy.sh -f hosts.txt -P 16 -- --baseline 2026-09-01
./deploy.sh --status -f hosts.txt
./deploy.sh --plan   -f hosts.txt                         # what would run today
./deploy.sh -f hosts.txt -- --uninstall
```

Uses `ssh -o BatchMode=yes` and `sudo -n` (unless `-u root`). Hosts without matching pools are skipped.
Per-host logs: `deploy-logs/<host>.log`.

## Deploy with Salt

Copy `salt/orcd-scrub/init.sls` to `engaging/role/orcd-scrub/init.sls` in the Salt file root, then on a node:

```bash
salt-call state.apply engaging.role.orcd-scrub test=True    # what would change
salt-call state.apply engaging.role.orcd-scrub
```

The state clones or updates [mit-orcd/orcd-scrub](https://github.com/mit-orcd/orcd-scrub) (pillar
`orcd-scrub:rev`, default `main`) into `/opt/orcd-scrub` and runs `install.sh` from that checkout.
`install.sh` runs only when `install.sh --check` finds something missing: the binary or units differ from
the checkout, a pool has no state, or a pool's timer is not enabled. Re-applying is therefore a no-op until
the repo changes, and a change is the in-place upgrade described below, which keeps every pool's run window.
The timers are systemd-enabled, so they come back after a reboot; a highstate also restores anything
that went missing. Nodes without `zpool` are skipped.

Pillar (host file, see `salt/pillar.example.sls`): add `orcd-scrub` to `role:`, plus an optional block:

```yaml
orcd-scrub:
  pools: "data1 data2"        # default: auto-detect ^data[0-9]+$
  baseline: "2026-07-31"      # only for pools without state
  settings:                   # orcd-scrub set --no-reset ..., only when different
    max-runtime: 4d
    check-after: 2d
```

`settings` are applied with `--no-reset`, so the next start date stays as it is, and a running scrub
keeps running. Run `orcd-scrub reattach <pool>` to apply them to that scrub. The state never passes
`--reinit`, `--force-config` or `--purge`.

The repo is private, so each node needs read access. Set one of these in a protected pillar, not in the
host file in git: `orcd-scrub:https_token` (a fine-grained read-only token) or `orcd-scrub:deploy_key`
(the private half of a read-only deploy key; the GitHub host key is pinned by the state). The checkout is
mode 0700 because `git.latest` can store the token in `.git/config`.

## Upgrade (keeps the run window)

```bash
./deploy.sh -f hosts.txt -- --dry-run      # see what would change
./deploy.sh -f hosts.txt                   # in-place upgrade, no install args needed
```

Re-running the installer on a node that already has orcd-scrub is an upgrade:

- Each pool's state stays as it is: watermark, cycle end, learned window limit, and the active or paused window.
  `init` is a no-op for pools that already have state. Before anything is touched, the state, history,
  config and systemd drop-in are backed up to `/var/lib/orcd-scrub/backup/<timestamp>.tgz` (the last 20 are kept).
- `/etc/orcd-scrub.conf` is kept (values from `orcd-scrub set` survive), and new defaults go to `.conf.new`.
  Settings that are missing from the old config fall back to the built-in defaults, which match 1.2.0 behaviour.
- The binary is replaced atomically, and the previous one is kept as `orcd-scrub.prev`. A running
  `orcd-scrub@<pool>.service` is **not** restarted: its scrub continues under the old code, and the new
  version takes over at the next run (or re-attaches to the running scrub after a reboot).
- The new binary must be able to read every existing state file (`orcd-scrub plan`), or the
  previous binary is restored and the install fails.
- Finally each pool reports `run window preserved (...)`, or a warning that shows the before and after values.
- `deploy.sh` refuses `--reinit`, `--purge` and `--force-config` unless `--yes` is given.

Restore from a backup: `systemctl stop orcd-scrub@<pool>; tar -xzPf /var/lib/orcd-scrub/backup/<ts>.tgz`.

## Change the time limits

Defaults: hard limit `max-runtime` **24h**, check/cut point `check-after` **12h**.

```bash
orcd-scrub config                                       # effective values
orcd-scrub set max-runtime 24h check-after 12h          # all initialised pools
orcd-scrub set max-runtime 18h check-after 6h --start   # ...and start the run now
orcd-scrub set --pool data1 check-after 8h              # reset only data1's run info
orcd-scrub set --no-reset max-runtime 30h               # keep run info, apply next run
orcd-scrub set continue-interval 1d                     # catch up daily instead of weekly (no reset)
./deploy.sh -f hosts.txt --cmd "set max-runtime 24h check-after 12h --start"
```

Changing either value rewrites `/etc/orcd-scrub.conf` and the systemd timeout drop-in
(`max-runtime` + 1h). It also **resets the run info**: last result, learned window limit and
cycle month are cleared, and a paused or orphaned scrub of ours is cancelled. The **watermark is kept**,
so the next run is due immediately and scrubs `[watermark − 1 day, now]` under the new limits.
If a run is active, it refuses; stop the run first with `systemctl stop orcd-scrub@<pool>`.

## Operate

```bash
orcd-scrub check-support          # does this zpool accept scrub -S/-E
orcd-scrub status                 # all pools, incl. "next start" (timer slot of the next run, or "running now")
orcd-scrub plan data1             # would it run now, and which window
orcd-scrub run --force data1      # run now regardless of schedule (foreground)
orcd-scrub kick data1             # same, via orcd-scrub@data1.service (resumes our paused scrub now)
orcd-scrub run --dry-run data1
orcd-scrub reset-limit data1      # forget learned window size
orcd-scrub init data1 --baseline "2026-09-01 00:00" --reinit
journalctl -u orcd-scrub@data1 -t orcd-scrub
```

Set `MAILTO=` in `/etc/orcd-scrub.conf` for alerts on halving, pausing and scrub errors.

## Caveats to check on a test pool first

- **ETA from windowed scrubs.** The early cut relies on zpool's `… to go` estimate. If `% done` / ETA
  turn out to be relative to the whole pool, the first window that completes while showing < 50 %
  switches the early cut off for that pool (alert; `orcd-scrub status` shows `ETA cut: off`). Until
  then a pessimistic ETA can cut a window to 1/4 at most. Force with `ETA_CUT=yes|no`;
  `orcd-scrub reset-limit <pool>` re-enables it.
- `-S/-E` map dates to TXGs. Dates before the feature was enabled scrub from pool creation, and large
  clock jumps skew the mapping (see `zpool-scrub(8)`). So the **first window on a pool upgraded to 2.4
  is a full scrub** no matter how it is cut, and it must end after the upgrade date, or the next window
  is a full scrub again. `ON_TOO_SLOW=auto` detects this (halving didn't reduce the work) and finishes
  the window over several `MAX_RUNTIME` sessions instead of halving. Seen on hstor010 data2: an 85-day
  and a 43-day window both projected ≈ 72 h. `ON_TOO_SLOW=pause` always does this; `halve` is the 1.2.0 behaviour.

### Changing settings for a scrub that is running (without pausing it)

The monitor reads the config when it starts, so `set` only affects later runs. To apply new values
to the run in progress **without pausing the zfs scrub**, which avoids the slow metadata re-scan after a resume:

```bash
orcd-scrub set --no-reset max-runtime 16d on-too-slow pause   # --no-reset: never cancels anything
orcd-scrub reattach data1    # SIGKILLs only the monitor (no pause handler), zfs keeps scrubbing,
                             # a fresh service re-attaches with the new settings + systemd timeout
```

Runtime counts from the original session start. `set` without `--no-reset` refuses while a scrub of
ours runs unmonitored, because the reset would cancel it.

### Handing a running scrub over to a new version

An upgrade does not touch a running `orcd-scrub@<pool>.service`; it keeps the old code until the run ends.
To switch now without losing scrub progress:

```bash
systemctl stop orcd-scrub@data2      # old code pauses the scrub, records RUN_STATE=paused
orcd-scrub kick data2                # new code resumes the same scrub/window immediately
orcd-scrub status data2; journalctl -fu orcd-scrub@data2
```
- `ADVANCE_ON_ERRORS=yes`: a window with unrepairable errors still advances the watermark (with an alert),
  because re-scrubbing won't fix it. Set it to `no` to keep retrying the same window.
- data1 and data2 on the same host never scrub at the same time (`SERIALIZE_POOLS=yes`). Set it to `no` to allow parallel scrubs.
- Stopping the service pauses the scrub. To cancel it for good, run `zpool scrub -s <pool>` after `systemctl stop`.

## Test without ZFS

```bash
tests/sim.sh 1800 130    # 30 days of data ≈ 15 h → halving, weekly catch-up
tests/sim.sh 300 100     # fast pool → monthly only
tests/sim.sh 30000 75    # very slow → MIN_WINDOW pause/resume, lag alert
tests/sim.sh 5000 130    # ETA says 1/2 is not enough → cut to 1/4
MOCK_PCT_SCALE=0.05 tests/sim.sh 1800 130            # zpool % done relative to whole pool
SIM_CONF="CONTINUE_INTERVAL=86400" tests/sim.sh 5000 130   # daily catch-ups
MOCK_FEATURE_SINCE=2026-10-20 MOCK_POOL_CREATED=2026-04-01 \
  SIM_CONF="MAX_RUNTIME=172800 CHECK_AFTER=86400" tests/sim.sh 1211 100   # data2: pre-2.4 dates = full scrub
SIM_SCRIPT=/path/to/old/orcd-scrub.sh tests/sim.sh 1800 130  # compare with another version
```

The simulator needs GNU `date`, `sed`, `find` and `flock`. On macOS, install them with
`brew install coreutils gnu-sed findutils flock` and put their `gnubin` directories first in `PATH`.
