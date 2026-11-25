# The root half of vpsmon-install.sh. scripts/make-installer.sh puts it after the functions that print the embedded
# files (vpsmon_script, vpsmon_service, vpsmon_timer) and VPSMON_VERSION. Every path lies under VPSMON_PREFIX, empty
# outside tests, so a test can install into a temp dir. It checks every input before it changes anything.
set -euf

prefix=${VPSMON_PREFIX:-}
bin=$prefix/usr/local/bin/vpsmon
units=$prefix/etc/systemd/system
config=$prefix/etc/vpsmon/config.json
state=$prefix/var/lib/vpsmon
sudoers=$prefix/etc/sudoers.d/vpsmon
changed=""

json_string() {
  printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')"
}

fail() {
  printf '{"ok":false,"error":"%s"}\n' "$1"
  exit "${2:-1}"
}

note() {
  changed="$changed
$1"
}

# Writes what the function $1 prints to $2 with mode $3, through a temp file and a rename, only when it differs, and
# says so in put_changed. It reports through a variable, not its status: set -e does not reach into a function that
# runs inside && or ||.
put() {
  put_changed=""
  put_new=$(mktemp)
  "$1" >"$put_new"
  if [ -f "$2" ] && cmp -s "$put_new" "$2"; then
    rm -f "$put_new"
    return 0
  fi
  mkdir -p "$(dirname "$2")"
  cp "$put_new" "$2.vpsmon-new"
  rm -f "$put_new"
  chmod "$3" "$2.vpsmon-new"
  chown 0:0 "$2.vpsmon-new"
  mv -f "$2.vpsmon-new" "$2"
  put_changed=1
  note "$2"
}

user=""
watch=""
uninstall=""
while [ $# -gt 0 ]; do
  case $1 in
    --user) [ $# -ge 2 ] || fail usage 2; user=$2; shift 2 ;;
    --watch) [ $# -ge 2 ] || fail usage 2; watch=$2; shift 2 ;;
    --uninstall) uninstall=1; shift ;;
    *) fail usage 2 ;;
  esac
done

command -v python3 >/dev/null 2>&1 && python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || fail python3

if [ -n "$uninstall" ]; then
  script=$(mktemp)
  vpsmon_script >"$script"
  set +e
  python3 "$script" uninstall
  code=$?
  rm -f "$script"
  exit "$code"
fi

if [ -n "$user" ]; then
  case $user in -* | *[!A-Za-z0-9._-]*) fail bad-user 2 ;; esac
  id -u "$user" >/dev/null 2>&1 || fail no-such-user
  command -v visudo >/dev/null 2>&1 || fail visudo-missing
fi
services=""
for unit in $(printf '%s' "$watch" | tr ',' ' '); do
  case $unit in -* | *[!A-Za-z0-9@_.:\\-]*) fail bad-unit 2 ;; esac
  services="$services${services:+, }$(json_string "$unit")"
done

put vpsmon_script "$bin" 0755

if [ ! -d "$state" ]; then
  mkdir -p "$state"
  chmod 0755 "$state"
  note "$state"
fi

if [ ! -e "$config" ]; then
  mkdir -p "$(dirname "$config")"
  printf '{"services": [%s]}\n' "$services" >"$config.vpsmon-new"
  chmod 0644 "$config.vpsmon-new"
  mv -f "$config.vpsmon-new" "$config"
  note "$config"
fi

if [ -n "$user" ]; then
  rule="$user ALL=(root) NOPASSWD: /usr/local/bin/vpsmon"
  if ! { [ -f "$sudoers" ] && grep -qxF "$rule" "$sudoers"; }; then
    mkdir -p "$(dirname "$sudoers")"
    # A name with a dot: sudo skips it while it is being checked.
    candidate=$(dirname "$sudoers")/.vpsmon.new
    { [ -f "$sudoers" ] && cat "$sudoers"; printf '%s\n' "$rule"; } >"$candidate"
    chmod 0440 "$candidate"
    chown 0:0 "$candidate"
    if ! visudo -cf "$candidate" >/dev/null 2>&1; then
      rm -f "$candidate"
      fail sudoers-invalid
    fi
    mv -f "$candidate" "$sudoers"
    note "$sudoers"
  fi
fi

if [ -d "$prefix/run/systemd/system" ] && command -v systemctl >/dev/null 2>&1; then
  put vpsmon_service "$units/vpsmon-sample.service" 0644
  units_changed=$put_changed
  put vpsmon_timer "$units/vpsmon-sample.timer" 0644
  if [ -n "$units_changed$put_changed" ]; then
    systemctl daemon-reload
    note daemon-reload
  fi
  if ! systemctl is-enabled --quiet vpsmon-sample.timer; then
    systemctl enable --now --quiet vpsmon-sample.timer
    note timer-enabled
  elif ! systemctl is-active --quiet vpsmon-sample.timer; then
    systemctl start vpsmon-sample.timer
    note timer-started
  fi
else
  note no-systemd-timer-skipped
fi

list=""
IFS='
'
for item in $changed; do
  list="$list${list:+,}$(json_string "$item")"
done
printf '{"ok":true,"version":"%s","changed":[%s]}\n' "$VPSMON_VERSION" "$list"
