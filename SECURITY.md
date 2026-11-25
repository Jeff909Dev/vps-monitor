# Security

## What runs with elevated access

VPS Monitor reads and changes your server as root, so this page says exactly what runs and where.

- **vpsmon runs as root.** It is one Python script at `/usr/local/bin/vpsmon`, owned by root with mode 0755. When another user starts it, it runs itself again with `sudo -n`. The systemd timer `vpsmon-sample.timer` runs `vpsmon sample` as root every 5 minutes to record the history. vpsmon keeps its state in `/var/lib/vpsmon` and writes one line for each action it applies to `/var/log/vpsmon.log`.
- **The sudoers rule.** With `--user <name>`, the installer writes `/etc/sudoers.d/vpsmon` with one line, `<name> ALL=(root) NOPASSWD: /usr/local/bin/vpsmon`, and checks it with `visudo -cf` before it moves it in place. That user can then run `/usr/local/bin/vpsmon` as root without a password, and no other command. Every vpsmon command counts, including `act` and `uninstall`, so anyone who can log in as that user can apply the same cleanups as the app.
- **What vpsmon changes.** `status` only reads. `act <id>` applies one action that vpsmon itself published: a cleanup that deletes files, or ending one process tree. Before it acts, it checks the action again against the live state of the server. The rules for each action are in [docs/contract.md](docs/contract.md). `vpsmon uninstall` removes the timer, its units, the sudoers rule, `/etc/vpsmon`, `/var/lib/vpsmon` and the script, and keeps the log.
- **The SSH connection.** The app connects with your own SSH user and key. It accepts a new server's host key on the first connection (`StrictHostKeyChecking=accept-new`) and refuses to connect when that key changes. To check the key before the first connection, connect once with `ssh` in Terminal and compare the fingerprint with the one your provider shows.
- **What the app runs on the server.** The app only ever runs `/usr/local/bin/vpsmon` with fixed arguments. The one exception is the install step, which runs `sh -s` with the installer bundled in the app on stdin. The app never builds a command from data it received. When you confirm an action, it sends back only an id that the server published, never a path or a process ID of its own.
- **No telemetry.** The app sends nothing anywhere. Its only network connection is your SSH connection.

## Supported versions

Only the latest release gets fixes. Keep vpsmon on the server at the version of your app. The app offers the update when the copy it bundles is newer.

## Report a vulnerability

Do not open a public issue for a security problem. Use **Report a vulnerability** on the [Security tab](https://github.com/Jeff909Dev/vps-monitor/security) of this repository. The report stays private until a fix is out.
