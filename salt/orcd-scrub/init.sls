# ===================================================================
# SaltStack State: engaging/role/orcd-scrub/init.sls
#
# Deploys orcd-scrub (rolling-window ZFS scrub) from a checkout of
# github.com/mit-orcd/orcd-scrub kept on the Salt master, and keeps it
# installed. Nodes need no GitHub access or credentials.
#
# Master, once (in the file root):
#   cd <file_root>/engaging/role/orcd-scrub
#   git clone https://github.com/mit-orcd/orcd-scrub.git src
#   ln -s src/salt/orcd-scrub/init.sls init.sls
# New version:
#   git -C <file_root>/engaging/role/orcd-scrub/src pull
#
#   salt-call state.apply engaging.role.orcd-scrub            # on the node
#   salt-call state.apply engaging.role.orcd-scrub test=True  # dry run
#   salt '<minion>' state.apply engaging.role.orcd-scrub      # from master
#
# Re-applying is safe: install.sh is an in-place upgrade that keeps
# /etc/orcd-scrub.conf and every pool's run window (watermark, cycle end,
# learned limit, active/paused window) and never touches a running scrub.
# It only runs when `install.sh --check` reports something missing or
# out of date. Timers are systemd-enabled, so they survive reboots.
#
# Never passes --reinit / --force-config / --purge; do those by hand.
#
# Pillar (all optional, see salt/pillar.example.sls):
#   orcd-scrub:
#     source: salt://engaging/role/orcd-scrub/src
#     target: /opt/orcd-scrub
#     pools: "data1 data2"                # default: auto-detect
#     pool_regex: '^data[0-9]+$'
#     baseline: "YYYY-MM-DD[ HH:MM]"      # only for pools without state
#     start_now: False
#     keep_stock: False
#     settings:                           # orcd-scrub set --no-reset KEY VALUE
#       max-runtime: 4d
#       check-after: 2d
# ===================================================================

{% set c = salt['pillar.get']('orcd-scrub', {}) %}
{% set source = c.get('source', 'salt://' ~ slspath ~ '/src') %}
{% set src = c.get('target', '/opt/orcd-scrub') %}
{% set bin = '/usr/local/sbin/orcd-scrub' %}

{% set args = [] %}
{% if c.get('pools') %}{% do args.append("--pools '" ~ (c.pools if c.pools is string else c.pools | join(' ')) ~ "'") %}{% endif %}
{% if c.get('pool_regex') %}{% do args.append("--pool-regex '" ~ c.pool_regex ~ "'") %}{% endif %}
{% if c.get('baseline') %}{% do args.append("--baseline '" ~ c.baseline ~ "'") %}{% endif %}
{% if c.get('start_now') %}{% do args.append('--start-now') %}{% endif %}
{% if c.get('keep_stock') %}{% do args.append('--keep-stock') %}{% endif %}
{% set args = args | join(' ') %}

{% set kv = [] %}
{% for k, v in c.get('settings', {}) | dictsort %}{% do kv.append(k ~ " '" ~ v ~ "'") %}{% endfor %}
{% set kv = kv | join(' ') %}

{% if not salt['cmd.which']('zpool') %}
orcd-scrub-not-zfs:
  test.show_notification:
    - text: "zpool not found - not a ZFS node, orcd-scrub skipped"
{% else %}

# exact copy of the master's checkout; anything else in the target is removed
orcd-scrub-src:
  file.recurse:
    - name: {{ src }}
    - source: {{ source }}
    - user: root
    - group: root
    - dir_mode: '0700'
    - file_mode: keep
    - clean: True
    - exclude_pat: E@(^|/)\.git(/|$)

orcd-scrub-install:
  cmd.run:
    - name: bash {{ src }}/install.sh {{ args }}
    - unless: bash {{ src }}/install.sh --check {{ args }}
    - require:
      - file: orcd-scrub-src

{% if kv %}
# --no-reset: keeps the schedule (next start) and the running scrub; new limits
# apply from the next run (`orcd-scrub reattach POOL` applies them to a running one)
orcd-scrub-settings:
  cmd.run:
    - name: {{ bin }} set --no-reset {{ kv }}
    - unless: {{ bin }} set --check {{ kv }}
    - require:
      - cmd: orcd-scrub-install
{% endif %}

{% endif %}
