# ===================================================================
# SaltStack State: engaging/role/orcd-scrub/init.sls
#
# Deploys orcd-scrub (rolling-window ZFS scrub) straight from the git
# remote and keeps it installed:
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
#     repo: https://github.com/mit-orcd/orcd-scrub.git
#     rev: main
#     target: /opt/orcd-scrub
#     https_token: <read-only token>      # private repo over https, or
#     deploy_key: |                       # private repo over ssh
#       -----BEGIN OPENSSH PRIVATE KEY-----
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
{% set deploy_key = c.get('deploy_key', '') %}
{% set https_token = c.get('https_token', '') %}
{% set repo = c.get('repo', 'git@github.com:mit-orcd/orcd-scrub.git' if deploy_key else 'https://github.com/mit-orcd/orcd-scrub.git') %}
{% set rev = c.get('rev', 'main') %}
{% set src = c.get('target', '/opt/orcd-scrub') %}
{% set key_file = '/root/.ssh/orcd-scrub-deploy' %}
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

orcd-scrub-git:
  pkg.installed:
    - name: git

{% if deploy_key %}
orcd-scrub-deploy-key:
  file.managed:
    - name: {{ key_file }}
    - contents_pillar: orcd-scrub:deploy_key
    - user: root
    - group: root
    - mode: '0600'
    - dir_mode: '0700'
    - makedirs: True
    - show_changes: False

orcd-scrub-github-hostkey:
  ssh_known_hosts.present:
    - name: github.com
    - user: root
    - enc: ssh-ed25519
    - key: AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
{% endif %}

# local edits in the checkout are discarded; the remote is the source of truth
orcd-scrub-repo:
  git.latest:
    - name: {{ repo }}
    - target: {{ src }}
    - rev: {{ rev }}
    - user: root
    - force_reset: True
    - force_clone: True
{% if deploy_key %}
    - identity: {{ key_file }}
{% elif https_token %}
    - https_user: x-access-token
    - https_pass: {{ https_token }}
{% endif %}
    - require:
      - pkg: orcd-scrub-git
{% if deploy_key %}
      - file: orcd-scrub-deploy-key
      - ssh_known_hosts: orcd-scrub-github-hostkey
{% endif %}

# root only: with https_token the remote URL in .git/config may carry the token
orcd-scrub-repo-perms:
  file.directory:
    - name: {{ src }}
    - user: root
    - group: root
    - mode: '0700'
    - require:
      - git: orcd-scrub-repo

orcd-scrub-install:
  cmd.run:
    - name: bash {{ src }}/install.sh {{ args }}
    - unless: bash {{ src }}/install.sh --check {{ args }}
    - require:
      - file: orcd-scrub-repo-perms

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
