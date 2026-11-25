# vpsmon contract (schema 3)

The Mac app talks to a Linux server only through `vpsmon`, a single Python 3.10+ stdlib script installed at
`/usr/local/bin/vpsmon`. The app runs it over SSH with a fixed argument vector:

    ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new -o ControlMaster=auto -o ControlPath=<temp>/vpsmon-<hash> \
        -o ControlPersist=300 -o ConnectTimeout=8 [-p <port>] [-l <user>] [-i <key> -o IdentitiesOnly=yes] \
        <host> /usr/local/bin/vpsmon --lang <en|es> <command>

`<hash>` is 16 hex characters of SHA-256 over the user, host, port and key. ssh's own `%C` is 40 characters, and
under macOS's 49-character temp folder it would overflow the 104-byte limit of a Unix socket path.

`vpsmon` needs root. When it starts as another user it re-executes itself as `sudo -n /usr/local/bin/vpsmon <same
arguments>`, so the app never decides whether to use sudo. The installer adds the sudoers rule that makes this work
without a password (see [Install](#install)). When sudo refuses, its own message (`a password is required`,
`command not found`) reaches the app on stderr. `version` and usage errors answer without root.

The server owns every fact, every judgment about what is safe, and every mutation. The app renders, colors and asks
for confirmation. It never builds a shell command from data and never sends a path or a PID of its own. It sends back
an action `id` that the server itself published, and the server re-derives that action from live state before acting.

All sizes are bytes (integers). All times are Unix seconds (floats allowed). Every command prints one JSON object on
stdout and exits 0 on success, 1 on a handled error (`{"ok": false, "error": "<user-facing, in --lang>"}`), 2 on usage.

## Language

`--lang en|es` comes before the command and defaults to `en`. It sets the language of every user-facing string the
server prints: action titles and details, map group titles and hints, `act` messages and errors. Ids, paths, process
names and commands are never translated. An unknown language is a usage error. `vpsmon` keeps its strings in one table
with an entry per language, so a missing translation fails the tests, not the user.

## Commands

| Command | Writes | Cost | Purpose |
| --- | --- | --- | --- |
| `status` | nothing | < 2 s on a host with 850 processes | Live snapshot plus the cached scan and the history. Pure reader. |
| `sample` | `history.jsonl`, maybe starts a scan | timer | Run by `vpsmon-sample.timer` every 5 min. Appends one history row and starts a background scan when the last one started more than 6 h ago. |
| `scan` | `scan.json` | minutes | Recomputes the disk actions, saves them, then measures the disk map and saves it, at nice 19 and the idle IO class. A scan that finds another one running returns `{"ok":true,"running":true}` and does nothing. `--background` starts it as the transient unit `vpsmon-scan` (`systemd-run`, so it outlives ssh and the timer), or, without systemd, as a detached child in its own session that logs to `scan.log`, and returns `{"ok":true,"started":true}` or `{"ok":true,"running":true}`. |
| `act <id>` | what it frees, `scan.json`, audit log | seconds to minutes | Applies one published action: a disk action, `worker:<pid>:<start>` or `proc:<pid>:<start>`. `--dry-run` prints what it would do and changes nothing. The app waits up to an hour. |
| `uninstall` | removes everything the installer added | seconds | Stops and removes the timer, the units, the sudoers rule, `/etc/vpsmon`, `/var/lib/vpsmon` and the script itself. Keeps `/var/log/vpsmon.log`. Prints `{"ok":true,"removed":[<paths>]}`; a rerun removes nothing. |
| `version` | nothing | instant | `{"ok":true,"version":"0.3.0","schema":3}`. |

State lives in `/var/lib/vpsmon/`: `history.jsonl` (only `sample` writes it, kept 7 days) and `scan.json` (written by
`scan` and `act` under `flock` on `/var/lib/vpsmon/lock`, always tmp + rename). A history row is the shape of
`status.history`, with `disks` holding the used bytes of each disk `sample` saw. A row that 0.2.0 wrote has
`diskUsedBytes` instead, the used bytes of `/`: vpsmon reads it as `"disks": {"/": diskUsedBytes}`, so root's growth and
forecast carry across the upgrade. A running scan holds `flock` on `/var/lib/vpsmon/scan.lock`, which is what
`scan.running` reports. `scan.json` keeps every item of every action (status shows 25), the map, and the time each
action was last applied, so a scan that started before an `act` does not bring that action back. Replan actions (below)
store only their biggest 25 items. `scan.json` holds ids, sizes and counts but no text: the scan runs from the timer
with no language, so `status` renders titles, details and hints in the `--lang` of each call. It carries `"schema": 2`,
the version of its own format, which moves only when the scan's shape does (schema 3 of `status` left it as it was). A
`scan.json` in another format is ignored, and the next sample scans again.
Audit log: `/var/log/vpsmon.log`, one JSON line per `act` (time, `SUDO_USER`, id, item count, the first 25 items, freed
bytes, result, and for workers the resume command).

### Config

`/etc/vpsmon/config.json` is optional. A missing or unreadable file means the defaults.

```jsonc
{ "services": ["nginx", "docker"] }   // systemd units to watch; default []
```

## `status` output

```jsonc
{
  "schema": 3,
  "ok": true,
  "version": "0.3.0",                 // vpsmon's own version; the app offers an update when its bundled copy is newer
  "host": "my-vps",                   // socket.gethostname()
  "at": 1795264909.3,
  "uptimeSec": 3283000,
  "cpu": { "cores": 16, "load1": 5.41, "load5": 4.72, "load15": 4.65 },
  "memory": {
    "totalBytes": 0, "availableBytes": 0, "swapTotalBytes": 0, "swapUsedBytes": 0,
    "processBytes": 0,                // sum of every process's RssAnon + VmSwap
    "groups": [ /* MemGroup, biggest first, at most 8 */ ]
  },
  "disks": [ /* Disk: / first, then the other disks by mount path */ ],
  "services": [ { "name": "nginx", "active": true } ],  // see Services
  "oomKills": [ { "at": 1795260000, "process": "node", "pid": 1234 } ],   // last 24 h, newest first
  "workers": [ /* Worker; [] when the host runs no Claude Code sessions */ ],
  "history": [ {                     // last 24 h, oldest first
    "at": 0,
    "disks": { "/": 0, "/mnt/data": 0 },  // used bytes by mount; a disk mounted later is missing from older rows
    "memAvailableBytes": 0, "swapUsedBytes": 0, "busy": 1, "idle": 16
  } ],
  "scan": { "at": 1795250000, "running": false, "actions": [ /* Action */ ], "map": { /* Map */ } }
  // scan.at is null, actions is [] and map.groups is [] when no scan has ever finished
}
```

### Disk

Every real disk mounted on the server, from PID 1's mount table (`/proc/1/mounts`), with its `statvfs` sizes:

- `/` always, whatever its filesystem (a container's root is `overlay`). With no line for `/` in the table, its `device`
  and `fstype` are `""`.
- Then every other mount of a block-device filesystem: `ext2`, `ext3`, `ext4`, `xfs`, `btrfs`, `zfs`, `f2fs`. That
  leaves out snaps (`squashfs`), `tmpfs`, `overlay`, `proc`, `sysfs`, `cgroup` and network filesystems, whose `statvfs`
  can hang `status` on a dead server. `/boot` and everything under it (`/boot/efi`) hold the kernel, not data, and a
  mount on a file (Docker's `/etc/hosts`) is no disk.
- A path mounted twice is its last mount, the one in use.
- One entry per device: bind mounts and Docker volumes repeat a device, so each device keeps its shortest mount path
  (`/` for root's). ZFS datasets share their pool's free space, so the datasets of one pool count as one device
  (`tank` and `tank/media`).
- A disk other than `/` whose `statvfs` fails is left out.

```jsonc
{
  "mount": "/mnt/data",
  "device": "/dev/sdb",               // the mount source: a block device, a ZFS dataset
  "fstype": "ext4",
  "totalBytes": 0, "usedBytes": 0, "freeBytes": 0,   // statvfs: blocks, blocks - bfree, bavail (df's Size, Used, Avail)
  "growthBytesPerHour": 540000000,    // least-squares slope of this mount's usedBytes over the last 24 h; null with < 1 h of history
  "fullInHours": 7.4                  // freeBytes / growth when growth > 0, else null
}
```

The disk map and the disk actions are about `/` only: the map measures the root filesystem, and the actions look in
fixed folders (`/tmp`, `/var`, the homes) that live on `/` on most servers.

### Services

Every unit listed in the config, with `active` from `systemctl is-active`, then every unit that
`systemctl list-units --state=failed` reports and the config does not list, with `active: false` and its name
without a `.service` suffix. Config entries that are not unit names are dropped. A host with no config
and no failed unit has `[]`. A host without systemd has `[]`.

### OOM kills

Kills by the kernel OOM killer (kernel messages from every boot, not only `journalctl -k`'s current one: lines
`Out of memory: Killed process <pid> (<name>)`, also from a memory cgroup) and by earlyoom when it is installed
(`sending SIG… to process <pid> uid <uid> "<name>"`), merged by pid, newest first. One journal query reads both.

### MemGroup

Where the RAM goes, by program. Every process with a user-space memory map counts: its bytes are `RssAnon + VmSwap`
from `/proc/<pid>/status`. That is what ending it would give back. Measured on a host with 849 processes: 0.04 s, against
1.1 s for `Pss + SwapPss` from `smaps_rollup`, for a total within 2% of it. Processes group by `comm`. The 8 biggest
groups are published, biggest first.

```jsonc
{
  "name": "node",                     // /proc/<pid>/comm
  "bytes": 9100000000,                // sum over the group
  "count": 41,                        // processes in the group
  "processes": [                      // biggest first, at most 6
    {
      "id": "proc:12345:987654",      // the act id: pid + start time in clock ticks (/proc/<pid>/stat field 22)
      "pid": 12345,
      "user": "deploy",               // owner's name, or the uid as a string
      "command": "node /srv/app/server.js --port 3000",   // cmdline joined with spaces, at most 160 characters
      "bytes": 420000000,             // this process only
      "treeBytes": 610000000,         // this process and all its descendants: what "end" frees
      "children": 3,                  // descendants that "end" also ends
      "startedAt": 1795000000.0,
      "killable": true                // see act proc
    }
  ]
}
```

A process is **not killable** when any of these holds:

- it is PID 1 or a kernel thread (no `/proc/<pid>/exe` target, or a descendant of PID 2);
- it is `vpsmon` itself or one of its ancestors (the SSH session the app is using);
- its `comm` is a system process: `systemd`, anything starting with `systemd-`, `(sd-pam)`, `init`, `sshd`,
  `sshd-session`, `sshd-auth`, `sudo`, `login`, `agetty`, `dbus-daemon`, `dbus-broker`, `polkitd`, `cron`, `crond`,
  `atd`, `rsyslogd`, `journald`, `udevd`, `containerd`, anything starting with `containerd-shim`, `dockerd`,
  `docker-proxy`, `earlyoom`, `snapd`, `multipathd`, `chronyd`, `ntpd`, `unattended-upgr`,
  `networkd-dispat`, `packagekitd`, `ModemManager`, `irqbalance`, `qemu-ga`, `cloud-init`, `fail2ban-server`;
- its exe lies in `/usr/sbin`, `/sbin` or `/usr/local/sbin`, where system daemons live (a VPN daemon that carries the
  SSH session, a web server, a database);
- it is a Claude Code worker (see Worker). Workers close from the agents list, which keeps their resume command;
- its tree holds a process that one of the rules above protects (ending the tree would end it too): a `tmux` server
  holding Claude Code sessions, a shell that runs `sudo`. This rule also covers vpsmon's ancestors.

### Worker

A worker is a live Claude Code session: a process whose `comm` is exactly `claude`, owned by any user, that has a
session file `$CLAUDE_CONFIG_DIR/sessions/<pid>.json`. `CLAUDE_CONFIG_DIR` comes from `/proc/<pid>/environ`, and
defaults to `<owner's home>/.claude`. Processes without that file (for example `claude --chrome-native-host`) are not
workers. The session file's `procStart` is the process start time in clock ticks; a file whose `procStart` differs from
the live process is stale and ignored.

```jsonc
{
  "id": "worker:170180:302344108",    // the act id: pid + procStart from the session file (guards PID reuse)
  "pid": 170180,
  "user": "deploy",
  "name": "api-refactor",             // session file "name"
  "workspace": "/home/deploy/code/api",   // session file "cwd"
  "state": "idle",                    // session file "status": "busy" | "idle"; anything else -> "unknown"
  "stateSince": 1795038803.9,         // statusUpdatedAt / 1000
  "lastActivity": 1795038803.9,       // equals stateSince: transcript mtimes move without real activity
  "startedAt": 1795005441.7,
  "memBytes": 1210000000,             // RssAnon + VmSwap over the process and all its descendants
  "processes": 9,                     // size of that subtree
  "sessionId": "6c3a70d8-1bef-4596-b6d5-0aeaf831d905",
  "version": "2.1.327",
  "resumeCommand": "claude --dangerously-skip-permissions --resume 6c3a70d8-…",  // original flags kept; --plugin-dir, --session-id and any old --resume/-r/--continue/-c dropped
  "closable": true                    // state == "idle" and now - lastActivity >= 30 min
}
```

### Action (disk)

```jsonc
{
  "id": "tmp-stale",
  "title": "Old temporary files",     // in --lang
  "detail": "38 entries in /tmp and /var/tmp that no process uses, untouched for a day",   // in --lang
  "bytes": 15100000000,
  "risk": "safe",                     // "safe" | "review"
  "count": 38,                        // every item the action would free; items shows at most 25 of them
  "items": [ { "label": "/tmp/build-cache-3f2a", "bytes": 2900000000 } ]   // biggest first, at most 25
}
```

Only actions with `bytes > 0` are published, biggest first. "In use" below means a process has the path, or something
inside it, as its cwd, its root, its exe, an open file (`/proc/*/fd`) or a mapped file (`/proc/*/maps`), or a filesystem
is mounted on it or inside it. "Quiet for T" means the newest mtime or ctime of anything inside is older than T: `tar`
and `cp -p` keep old mtimes, and a fresh copy still has a fresh ctime. Sizes stay on the item's filesystem. A
**replan** action selects thousands of items, so the scan stores only its biggest 25 and `act` selects again from live
state with the same rule. A path whose folders are not all real directories (a symlink on the way) is never selected.
Items in a user's folders (`claude-tmp`, `big-logs`, `claude-versions`, `pkg-caches`) are deleted with the rights of
the first user other than root who owns a folder above them, since that user could swap what lies below; root deletes
only below folders root owns.

| id | risk | Plan (what is selected) | Apply |
| --- | --- | --- | --- |
| `tmp-stale` | safe | Every entry directly inside `/tmp` (quiet for 24 h) and `/var/tmp` (quiet for 7 days) that is not in use, holds no socket and no FIFO, and is not a system entry: `systemd-private-*`, `snap-private-tmp`, `.X*-unix`, `.X*-lock`, `.ICE-unix`, `.font-unix`, `.Test-unix`, `tmux-*`, `ssh-*`, `claude-<uid>`, `vpsmon*`, `lost+found`. Replan. | `rm -rf` each, one at a time, re-checking each |
| `claude-tmp` | safe | Claude Code's per-session folders `/tmp/claude-<uid>/<slug>/<uuid>/` (`<slug>` starts with `-`, `<uuid>` is a UUID, the folder owned by `<uid>`) whose `<uuid>` is not the sessionId of a live worker, that are not in use, and quiet for 6 h | `rm -rf` each |
| `big-logs` | review | `*.log` files over 200 MB under `/tmp`, `/var/tmp`, `/home`, `/root`, `/srv`, `/opt` and `/var/log`, on each root's own filesystem (pruning `node_modules` and `.git`), not open by any process, and not inside an item of `tmp-stale` or `claude-tmp` | truncate to 0, then unlink |
| `claude-versions` | safe | For every home (`/home/*`, `/root`): `~/.local/share/claude/versions/<v>` older than the target of `~/.local/bin/claude` and not the `exe` of any live process | `rm -rf` |
| `pkg-caches` | safe | For every home: `~/.npm/_cacache`, `~/.cache/pip`, `~/.cache/yarn`, `~/.cache/go-build` (never `~/.npm/_npx`: MCP servers run from it) | `rm -rf` each |
| `journal` | safe | archived journal files that `--vacuum-size=200M` would remove (oldest first until the total fits) | `journalctl --vacuum-size=200M` |
| `apt-cache` | safe | `/var/cache/apt/archives/*.deb` | `apt-get clean` |
| `docker-images` | review | images not used by any container, running or stopped; size is the unpacked size from `docker image ls` | `docker image rm <id>` each (not `prune -a`, which would also delete an image pulled after the plan) |
| `docker-volumes` | review | dangling anonymous volumes (64-hex names, `dangling=true`, label `com.docker.volume.anonymous`) | `docker volume rm` each |
| `docker-build-cache` | review | the reclaimable build cache that `docker system df` reports, as one item | `docker builder prune -af` (without `-a` it keeps cache that `docker system df` counts as reclaimable) |

Actions whose tool is missing (`journalctl`, `apt-get`, `docker`) are never published.

### Map (disk)

Where the used space of `/` goes, in blocks that add up to all of it. The scan measures it with one pass of
`du -x -B1 --max-depth=4 --threshold=10M /` (the depth is the deepest a group's children reach). The threshold drops
directories under 10 MB.

```jsonc
{
  "usedBytes": 289374429184,          // statvfs used bytes when the scan measured the map
  "groups": [                         // biggest first, "rest" last; the bytes add up to usedBytes exactly
    {
      "id": "temp",
      "title": "Temporary files",     // in --lang
      "hint": "/tmp and /var/tmp",    // in --lang
      "bytes": 81000000000,
      "freeableBytes": 2100000000,    // what the published actions would free here; never more than bytes
      "actions": ["tmp-stale", "claude-tmp"],   // published actions that free space here, biggest share first
      "children": [ { "path": "/tmp/claude-1000", "bytes": 30000000000 } ]   // biggest first, at most 6
    }
  ]
}
```

The registry, in `MAP_GROUPS` in `server/vpsmon`. A root may hold a glob within one path component. A root may lie
inside another group's root: the most specific root wins, so its bytes are subtracted from the outer group, and the
outer group's children skip it. A root that is a file (a swapfile) is sized from its blocks, because `du` lists only
directories. A group whose roots do not exist, or hold 0 bytes, is left out.

| id | Roots | Children | Freeable |
| --- | --- | --- | --- |
| `home` | `/home/*`, `/root` | one level inside each root (`/home/deploy/code`) | `big-logs`, `claude-versions` |
| `claude` | `/home/*/.claude`, `/root/.claude` | one level down | |
| `caches` | `/var/cache`, `/home/*/.cache`, `/home/*/.npm`, `/root/.cache`, `/root/.npm` | one level down | `pkg-caches`, `apt-cache` |
| `docker` | `/var/lib/docker`, `/var/lib/containerd` | one level down | `docker-images`, `docker-volumes`, `docker-build-cache` |
| `logs` | `/var/log` | one level down | `journal`, `big-logs` |
| `temp` | `/tmp`, `/var/tmp` | one level down | `tmp-stale`, `claude-tmp`, `big-logs` |
| `swap` | `/swapfile*`, `/swap.img` | the files | |
| `system` | `/usr`, `/opt`, `/boot`, `/snap`, `/var/lib/snapd` | the roots | |
| `rest` | everything else | the directories three levels below `/` that no group holds | |

`rest` is `usedBytes` minus every other group, so it also holds what `du` cannot see: deleted files that a process
still holds open, and the gap between the start and the end of the scan. If the other groups add up to more than
statvfs used, `rest` is left out and `usedBytes` is their sum.

`status` computes `freeableBytes` and `actions` from the actions still published, so a group stops showing space as
freeable once its action has run. An action that one group lists counts all its bytes there. An action that several
groups list (`big-logs`) counts each item in the group whose roots hold the item's path. Docker refs are not paths, so
they count in `docker`. Docker image sizes are unpacked sizes, so `freeableBytes` is capped at the group's `bytes`.

## `act <id>` output

```jsonc
{ "ok": true, "id": "tmp-stale", "freedBytes": 15100000000, "message": "Removed 38 entries", "dryRun": false,
  "items": [ { "label": "…", "bytes": 0 } ],
  "resumeCommand": "claude … --resume <id>" }      // only for worker:<pid>:<procStart>
```

`act <disk-id>`: takes the items the last scan stored for that action, re-checks each against live state with the
rule the scan used, applies the ones that still qualify, and removes the action from `scan.json` under the lock. It
never adds an item the scan did not show, except for a replan action. Running it twice is harmless: the second plan is
empty and returns `{"ok": true, "freedBytes": 0, "message": "<nothing to free>"}`. A second `act` while one is still
applying is an error. `--dry-run` takes no lock.

`act worker:<pid>:<procStart>`: refuses unless the process is still `comm == "claude"`, started at `procStart`, its
session file has the same `procStart`, and it is idle and closable. Snapshot the descendant PIDs with their start times,
re-read the session file and refuse if it is no longer idle, send SIGTERM to the claude PID through a pidfd, wait up to
10 s, SIGKILL it if still alive, then SIGTERM any snapshotted descendant still alive with the same start time. Never
signal anything by name pattern. Append the resume line (with `cd <workspace> &&`) to
`$CLAUDE_CONFIG_DIR/vpsmon-closed-sessions.md` (owned by the worker's user) and to the audit log. `freedBytes` is the
worker's `memBytes`.

`act proc:<pid>:<start>`: refuses unless the process still exists with that start time and is still killable by the
rule in MemGroup, evaluated now. Then it ends the process tree exactly as for a worker (pidfd SIGTERM, 10 s, SIGKILL,
then the snapshotted descendants). `freedBytes` is the tree's `RssAnon + VmSwap` read just before the signal.

## Install

`vpsmon-install.sh` is one self-contained POSIX `sh` file built from `server/` by `scripts/make-installer.sh`. It holds
`vpsmon` and both systemd units. It is a release asset, and the app bundles the same file.

    vpsmon-install.sh [--user <name>] [--watch <unit,unit>] [--uninstall]

- Run as root, it installs `vpsmon`, `vpsmon-sample.service` and `vpsmon-sample.timer`, creates `/var/lib/vpsmon`,
  writes `/etc/vpsmon/config.json` when it is missing (with `--watch` units, else `{"services": []}`), enables the
  timer, and, with `--user`, adds `<user> ALL=(root) NOPASSWD: /usr/local/bin/vpsmon` to `/etc/sudoers.d/vpsmon`
  (next to other users' lines; mode 0440, checked with `visudo -cf` before it is moved in place). Rerunning changes
  nothing when everything is current. It prints one JSON line: `{"ok":true,"version":"0.3.0","changed":[…]}`, where
  `changed` lists the files and folders it wrote and `daemon-reload`, `timer-enabled`, `timer-started`.
- On a host without systemd (a container) it installs the script and the rest, skips the units and the timer, and
  says so with `no-systemd-timer-skipped` in `changed`, on every run.
- It checks every input before it changes anything. Errors: `{"ok":false,"error":"<code>"}` with exit 2 for `usage`,
  `bad-user` and `bad-unit`, exit 1 for `no-such-user`, `visudo-missing`, `sudoers-invalid` and `python3` (no Python
  3.10 or newer).
- Run as another user, it writes its payload to a temp file and runs it with `sudo -n`, adding `--user <that user>`.
  When sudo needs a password it prints `{"ok":false,"error":"sudo-password","user":"<that user>"}` and exits 1, and
  `{"ok":false,"error":"sudo-missing","user":"<that user>"}` when there is no sudo at all.
- `--uninstall` runs `vpsmon uninstall` and prints its answer.
- The app installs with `ssh <options> <host> sh -s` and the bundled file on stdin. When the answer is
  `sudo-password`, it shows a command to paste into Terminal instead:
  `curl -fsSL https://github.com/Jeff909Dev/vps-monitor/releases/download/v<version>/vpsmon-install.sh | sudo sh -s -- --user <ssh user>`.

## Testing

`VPSMON_PREFIX=<dir>` is a testing hook. vpsmon then keeps its own files (state, audit log, config, script, units,
sudoers rule) under `<dir>` and runs as whoever starts it, without sudo; what it watches (`/proc`, `/tmp`, the homes)
stays the real host. The installer puts every path it writes or checks under `<dir>`, `/run/systemd/system` included.
`server/check_contract.py [status.json]` checks a `status` answer (a file, or stdin) against this schema.
