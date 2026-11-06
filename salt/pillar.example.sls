# Host pillar for a ZFS server running orcd-scrub (e.g. hstor006-n1.sls).
# Add the role, then optionally the orcd-scrub block. Everything in the block
# is optional; with no block the pools matching ^data[0-9]+$ are auto-detected.

role:
  - standalone
  - storage
  - telegraf
  - orcd-scrub
states:
  - engaging.role
  - firewalld.disable

orcd-scrub:
  # pools: "data1 data2"
  # baseline: "2026-07-31"        # only used for pools that have no state yet
  settings:                       # applied with `orcd-scrub set --no-reset`
    max-runtime: 4d
    check-after: 2d
    # on-too-slow: auto
