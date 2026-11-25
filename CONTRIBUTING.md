# Contributing

Bug reports and pull requests are welcome. For a large change, open an issue first so we can agree on the approach.

## Build from source

You need macOS 14 or later, Xcode 16 or later for Swift 6, and Python 3.10 or later for the server tests.

```sh
make test       # the app's unit tests (swift test), then the server's unit tests
make app        # build/VPS Monitor.app, universal and ad-hoc signed
make installer  # build/dist/vpsmon-install.sh, the server installer
make dist       # every release asset in build/dist; check the app with scripts/verify-dist.sh
make render     # the popover drawn from fixtures/status.json, as PNGs in build/render
make status     # what the popover would say about your server
make run        # build the app and open it
```

`make test` does not connect to any server.

## Test the server on a disposable machine

vpsmon runs as root, and `act` deletes files and ends processes. Test it on a virtual machine or a cloud server you can throw away, never on a server that matters. It needs Linux with systemd and Python 3.10 or later.

1. Run `make installer` and copy `build/dist/vpsmon-install.sh` to the machine.
2. On the machine, run `sudo sh vpsmon-install.sh --user "$USER"`. It prints one JSON line with what it changed. Run it again: `changed` is empty.
3. From your Mac, check the output against the contract: `ssh <host> vpsmon status > status.json`, then `python3 server/check_contract.py status.json`.
4. On the machine, run `vpsmon scan`, then `vpsmon act <id> --dry-run` to see what an action would do without changing anything.
5. Run `sudo vpsmon uninstall` when you are done.

CI installs, checks, scans, reinstalls and uninstalls the same way on a fresh Ubuntu 24.04 runner. It does not run `act`.

## Pull requests

- Keep one change per pull request.
- Say how you tested it. For a server change, say which distribution you tested on, and for an `act` change include the `--dry-run` output.
- Keep `server/vpsmon` to the Python standard library. It has to run on a bare server.
- When the `status` output changes, change `docs/contract.md`, `fixtures/status.json` and `server/check_contract.py` in the same pull request. Every user-facing string needs an English and a Spanish entry.
- Run `make test` before you push. CI runs the same command.

## Release

1. Set the new version in `VERSION` and in the `VERSION = "x.y.z"` line of `server/vpsmon`.
2. Run `scripts/check-version.sh v<version>` and `make dist`.
3. Push the tag `v<version>`. The release workflow opens a draft release. Check it, then publish it.
