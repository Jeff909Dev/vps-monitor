#!/usr/bin/env python3
"""Writes fixtures/status.json (English) and fixtures/status.es.json (Spanish): one invented host, `web-1`, as
`vpsmon --lang <en|es> status` would print it (docs/contract.md, schema 2). Both files hold the same numbers; only the
strings the server translates differ. Deterministic: rerunning rewrites the same bytes.

Usage: python3 app/scripts/make-fixtures.py
"""

import importlib.util
import json
import math
import sys
from importlib.machinery import SourceFileLoader
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
GIB = 1024**3
MIB = 1024**2
AT = 1795264909.3
UPTIME = 3283000
HZ = 100  # clock ticks per second, for the start times in the act ids


def ticks(started_at: float) -> int:
    """A process's start time in clock ticks since boot, as /proc/<pid>/stat field 22."""
    return int((started_at - (AT - UPTIME)) * HZ)


# Strings the server prints in --lang come from the server itself, so the fixtures (and the screenshots drawn from them)
# never drift from what a real server says. Everything else (ids, paths, commands, names) is never translated.
def load_vpsmon():
    loader = SourceFileLoader("vpsmon", str(ROOT / "server" / "vpsmon"))
    spec = importlib.util.spec_from_loader("vpsmon", loader)
    module = importlib.util.module_from_spec(spec)
    sys.modules["vpsmon"] = module  # dataclasses look their module up here
    loader.exec_module(module)
    return module


VPSMON = load_vpsmon()

# Disk actions: id, risk, items (label, bytes), biggest item first. The scan stores at most 25 items per action.
ACTIONS = [
    ("tmp-stale", "safe", [
        ("/tmp/build-cache-3f2a", int(2.6 * GIB)),
        ("/tmp/playwright-artifacts-81c0", int(1.4 * GIB)),
        ("/var/tmp/pg-restore-2026-11-02", int(1.1 * GIB)),
        ("/tmp/node-compile-cache", int(0.7 * GIB)),
        ("/tmp/tsc-out-7d19", int(0.4 * GIB)),
        ("/tmp/core.web-worker.21877", int(0.3 * GIB)),
    ] + [(f"/tmp/upload-{i:04x}", int((0.05 - i * 0.001) * GIB)) for i in range(32)]),
    ("docker-images", "review", [
        ("registry.example.com/web:1.3.0 (8f2c1d9a0b3e)", int(1.3 * GIB)),
        ("registry.example.com/web:1.2.4 (2a7e5c0f9d1b)", int(1.2 * GIB)),
        ("registry.example.com/api:2.0.0-rc.1 (c41b8e2d7f60)", int(0.9 * GIB)),
        ("postgres:15-bookworm (6d3f0a1c8e2b)", int(0.4 * GIB)),
        ("node:20-bookworm (b9e8d7c6a5f4)", int(1.1 * GIB)),
    ]),
    ("claude-tmp", "safe", [
        ("/tmp/claude-1000/-home-deploy-code-api/0b6f4e2a-9c1d-4f3b-8a7e-5d2c1b0a9f8e", int(0.9 * GIB)),
        ("/tmp/claude-1000/-home-deploy-code-web/7e3d2c1b-0a9f-4e8d-b7c6-a5f4e3d2c1b0", int(0.7 * GIB)),
        ("/tmp/claude-0/-root-infra/3c2b1a0f-9e8d-4c7b-a6f5-e4d3c2b1a0f9", int(0.4 * GIB)),
        ("/tmp/claude-1000/-home-deploy-code-api/9a8b7c6d-5e4f-4a3b-9c2d-1e0f9a8b7c6d", int(0.3 * GIB)),
    ]),
    ("pkg-caches", "safe", [
        ("/home/deploy/.npm/_cacache", int(1.1 * GIB)),
        ("/home/deploy/.cache/pip", int(0.4 * GIB)),
        ("/root/.cache/go-build", int(0.3 * GIB)),
        ("/home/deploy/.cache/yarn", int(0.1 * GIB)),
    ]),
    ("docker-build-cache", "review", [("@build-cache", int(1.6 * GIB))]),
    ("journal", "safe", [
        ("/var/log/journal/4f1c2b7a9e0d/system@00061f2a-0000000000a1b2c3.journal", int(0.3 * GIB)),
        ("/var/log/journal/4f1c2b7a9e0d/system@00061e9b-00000000009a8b7c.journal", int(0.3 * GIB)),
        ("/var/log/journal/4f1c2b7a9e0d/user-1000@00061e40-0000000000123abc.journal", int(0.2 * GIB)),
    ]),
    ("big-logs", "review", [
        ("/home/deploy/code/api/logs/debug.log", int(0.5 * GIB)),
        ("/var/log/nginx/access.log.1", int(0.3 * GIB)),
    ]),
    ("claude-versions", "safe", [
        ("/home/deploy/.local/share/claude/versions/2.1.301", int(0.21 * GIB)),
        ("/home/deploy/.local/share/claude/versions/2.1.297", int(0.21 * GIB)),
        ("/root/.local/share/claude/versions/2.1.288", int(0.2 * GIB)),
    ]),
    ("apt-cache", "safe", [(f"/var/cache/apt/archives/{name}", int(mb * MIB)) for name, mb in [
        ("linux-image-6.8.0-49-generic_6.8.0-49.49_amd64.deb", 14.6),
        ("linux-modules-6.8.0-49-generic_6.8.0-49.49_amd64.deb", 140.2),
        ("docker-ce_27.3.1-1~ubuntu.24.04~noble_amd64.deb", 25.9),
        ("postgresql-16_16.6-0ubuntu0.24.04.1_amd64.deb", 16.8),
        ("nodejs_20.18.1-1nodesource1_amd64.deb", 31.5),
    ]]),
]

# Which map group each action frees, and where each big-logs item lies (the contract's MAP_GROUPS column "Freeable").
ACTION_GROUP = {
    "tmp-stale": "temp", "claude-tmp": "temp", "docker-images": "docker", "docker-build-cache": "docker",
    "pkg-caches": "caches", "apt-cache": "caches", "journal": "logs", "claude-versions": "home",
}


def big_log_group(path: str) -> str:
    return "logs" if path.startswith("/var/log/") else "home"


# Map groups: id, bytes, children (path, bytes). "rest" takes what is left so the groups add up to usedBytes.
MAP_USED = int(118.6 * GIB)
MAP = [
    ("docker", int(31.4 * GIB), [("/var/lib/docker/overlay2", int(24.8 * GIB)), ("/var/lib/docker/volumes", int(4.1 * GIB)),
                                 ("/var/lib/docker/buildkit", int(1.7 * GIB)), ("/var/lib/containerd", int(0.6 * GIB))]),
    ("home", int(24.2 * GIB), [("/home/deploy/code", int(14.9 * GIB)), ("/home/deploy/.local", int(3.2 * GIB)),
                               ("/home/deploy/backups", int(2.8 * GIB)), ("/root/infra", int(1.4 * GIB)),
                               ("/home/deploy/.config", int(0.4 * GIB)), ("/root/.local", int(0.3 * GIB))]),
    ("temp", int(12.7 * GIB), [("/tmp/build-cache-3f2a", int(2.6 * GIB)), ("/tmp/claude-1000", int(2.4 * GIB)),
                               ("/tmp/playwright-artifacts-81c0", int(1.4 * GIB)),
                               ("/var/tmp/pg-restore-2026-11-02", int(1.1 * GIB)),
                               ("/tmp/node-compile-cache", int(0.7 * GIB)), ("/tmp/claude-0", int(0.4 * GIB))]),
    ("system", int(11.3 * GIB), [("/usr", int(7.9 * GIB)), ("/opt", int(1.8 * GIB)), ("/snap", int(1.3 * GIB)),
                                 ("/boot", int(0.3 * GIB))]),
    ("claude", int(6.1 * GIB), [("/home/deploy/.claude/projects", int(4.6 * GIB)), ("/root/.claude/projects", int(0.9 * GIB)),
                                ("/home/deploy/.claude/shell-snapshots", int(0.3 * GIB))]),
    ("caches", int(5.4 * GIB), [("/home/deploy/.npm", int(1.6 * GIB)), ("/home/deploy/.cache", int(1.4 * GIB)),
                                ("/var/cache/apt", int(0.6 * GIB)), ("/root/.cache", int(0.5 * GIB))]),
    ("swap", 4 * GIB, [("/swapfile", 4 * GIB)]),
    ("logs", int(3.3 * GIB), [("/var/log/journal", int(1.9 * GIB)), ("/var/log/nginx", int(0.8 * GIB)),
                              ("/var/log/postgresql", int(0.2 * GIB))]),
]
MAP_CHILDREN_REST = [("/srv/web", int(6.4 * GIB)), ("/var/lib/postgresql", int(5.1 * GIB)), ("/srv/api", int(2.1 * GIB)),
                     ("/var/lib/redis", int(0.3 * GIB))]

# RAM by program: name, processes (id fields), group bytes, count. Processes biggest first, at most 6.
def proc(pid, user, command, mb, tree_mb, children, started_ago_h, killable=True):
    started = AT - started_ago_h * 3600
    return {
        "id": f"proc:{pid}:{ticks(started)}", "pid": pid, "user": user, "command": command,
        "bytes": int(mb * MIB), "treeBytes": int(tree_mb * MIB), "children": children,
        "startedAt": round(started, 1), "killable": killable,
    }


MEM_GROUPS = [
    ("node", 23, 3.9, [
        proc(41822, "deploy", "node /srv/api/dist/server.js --port 3000", 1180, 1460, 3, 70),
        proc(41907, "deploy", "node /srv/web/.next/standalone/server.js", 860, 860, 0, 70),
        proc(58113, "deploy", "node /home/deploy/code/api/node_modules/.bin/vitest --watch", 610, 790, 4, 5),
        proc(60231, "deploy", "node /home/deploy/.npm/_npx/9c1f/node_modules/.bin/mcp-server-filesystem /home/deploy/code",
             240, 240, 0, 3),
        proc(61002, "deploy", "node /srv/worker/dist/queue.js", 210, 210, 0, 70),
        proc(61877, "root", "node /usr/lib/node_modules/pm2/bin/pm2 daemon", 95, 95, 0, 200),
    ]),
    ("postgres", 12, 2.4, [
        proc(1544, "postgres", "postgres: 16/main: deploy app_production 127.0.0.1(51234) idle", 640, 640, 0, 30),
        proc(1203, "postgres", "/usr/lib/postgresql/16/bin/postgres -D /var/lib/postgresql/16/main", 420, 2450, 11, 900),
        proc(1547, "postgres", "postgres: 16/main: deploy app_production 127.0.0.1(51240) idle", 380, 380, 0, 30),
        proc(1219, "postgres", "postgres: 16/main: checkpointer", 310, 310, 0, 900),
        proc(1221, "postgres", "postgres: 16/main: autovacuum launcher", 120, 120, 0, 900),
        proc(1220, "postgres", "postgres: 16/main: background writer", 96, 96, 0, 900),
    ]),
    ("claude", 4, 1.9, [
        proc(52310, "deploy", "claude --dangerously-skip-permissions", 820, 1240, 6, 6.01, killable=False),
        proc(49876, "deploy", "claude", 520, 610, 2, 15.7, killable=False),
        proc(47120, "deploy", "claude --model opus", 330, 380, 1, 74.2, killable=False),
        proc(33018, "root", "claude", 270, 290, 1, 59.4, killable=False),
    ]),
    ("chrome", 17, 1.3, [
        proc(58840, "deploy", "/opt/google/chrome/chrome --headless=new --remote-debugging-port=9222 --user-data-dir=/tmp/pw-profile",
             310, 1310, 16, 4),
        proc(58871, "deploy", "/opt/google/chrome/chrome --type=renderer --headless=new --lang=en-US", 250, 250, 0, 4),
        proc(58873, "deploy", "/opt/google/chrome/chrome --type=renderer --headless=new --lang=en-US", 210, 210, 0, 4),
        proc(58850, "deploy", "/opt/google/chrome/chrome --type=gpu-process --headless=new", 120, 120, 0, 4),
        proc(58875, "deploy", "/opt/google/chrome/chrome --type=renderer --headless=new --lang=en-US", 95, 95, 0, 4),
        proc(58852, "deploy", "/opt/google/chrome/chrome --type=utility --utility-sub-type=network.mojom.NetworkService",
             60, 60, 0, 4),
    ]),
    ("dockerd", 1, 0.42, [
        proc(980, "root", "/usr/bin/dockerd -H fd:// --containerd=/run/containerd/containerd.sock", 430, 430, 0, 911,
             killable=False),
    ]),
    ("python3", 3, 0.36, [
        proc(23011, "deploy", "python3 /srv/reports/nightly.py --since 7d", 260, 260, 0, 1),
        proc(1388, "root", "/usr/bin/python3 /usr/bin/networkd-dispatcher --run-startup-triggers", 48, 48, 0, 911),
        proc(1501, "root", "/usr/bin/python3 /usr/share/unattended-upgrades/unattended-upgrade-shutdown", 32, 32, 0, 911),
    ]),
    ("redis-server", 1, 0.21, [
        proc(1190, "redis", "/usr/bin/redis-server 127.0.0.1:6379", 215, 215, 0, 911),
    ]),
    ("nginx", 5, 0.09, [
        proc(1301, "www-data", "nginx: worker process", 22, 22, 0, 911),
        proc(1302, "www-data", "nginx: worker process", 21, 21, 0, 911),
        proc(1303, "www-data", "nginx: worker process", 19, 19, 0, 911),
        proc(1304, "www-data", "nginx: worker process", 18, 18, 0, 911),
        proc(1288, "root", "nginx: master process /usr/sbin/nginx -g daemon on; master_process on;", 12, 104, 4, 911),
    ]),
]

WORKERS = [
    # name, user, workspace, state, idle hours, pid, mem GB, processes, version, flags
    ("api-refactor", "deploy", "/home/deploy/code/api", "busy", 0.01, 52310, 1.21, 7, "2.1.330",
     "--dangerously-skip-permissions"),
    ("docs-site", "deploy", "/home/deploy/code/docs", "idle", 0.7, 49876, 0.6, 3, "2.1.330", ""),
    ("billing-tests", "deploy", "/home/deploy/code/billing", "idle", 50.2, 47120, 0.37, 2, "2.1.327", "--model opus"),
    ("infra-notes", "root", "/root/infra", "idle", 26.4, 33018, 0.28, 2, "2.1.324", ""),
]
SESSION_IDS = ["1f0e9d8c-7b6a-4f5e-8d4c-3b2a1f0e9d8c", "5a4b3c2d-1e0f-4a9b-8c7d-6e5f4a3b2c1d",
               "9e8d7c6b-5a4f-4e3d-9c2b-1a0f9e8d7c6b", "2c3d4e5f-6a7b-4c8d-9e0f-1a2b3c4d5e6f"]

DISK_TOTAL = 150 * GIB
DISK_USED = int(121.4 * GIB)
DISK_FREE = int(21.1 * GIB)  # root's reserved blocks make used + free < total, as df shows
GROWTH = 214_000_000.0


def actions(lang: str) -> list[dict]:
    tr = VPSMON.Text(lang)
    out = []
    for id_, risk, items in ACTIONS:
        assert VPSMON.ACTIONS[id_].risk == risk, id_
        items = sorted(items, key=lambda item: -item[1])
        stored = {"id": id_, "bytes": sum(size for _, size in items), "count": len(items),
                  "items": [{"label": "Build Cache" if label == "@build-cache" else label, "bytes": size}
                            for label, size in items]}
        out.append(VPSMON.action_view(stored, tr))
    out.sort(key=lambda action: -action["bytes"])
    return out


def freeable_by_group(published: list[dict]) -> dict[str, dict[str, int]]:
    """What each published action frees in each group: all of it in its one group; big-logs item by item."""
    shares: dict[str, dict[str, int]] = {}
    for action in published:
        if action["id"] == "big-logs":
            for item in action["items"]:
                group = big_log_group(item["label"])
                shares.setdefault(group, {}).setdefault("big-logs", 0)
                shares[group]["big-logs"] += item["bytes"]
        else:
            shares.setdefault(ACTION_GROUP[action["id"]], {})[action["id"]] = action["bytes"]
    return shares


def disk_map(lang: str, published: list[dict]) -> dict:
    tr = VPSMON.Text(lang)
    shares = freeable_by_group(published)
    groups = []
    for id_, size, children in MAP + [("rest", MAP_USED - sum(size for _, size, _ in MAP), MAP_CHILDREN_REST)]:
        title, hint = tr(f"map.{id_}.title"), tr(f"map.{id_}.hint")
        mine = shares.get(id_, {})
        groups.append({
            "id": id_, "title": title, "hint": hint, "bytes": size,
            "freeableBytes": min(size, sum(mine.values())),
            "actions": [a for a, _ in sorted(mine.items(), key=lambda kv: -kv[1])],
            "children": [{"path": path, "bytes": b} for path, b in sorted(children, key=lambda c: -c[1])[:6]],
        })
    rest = groups.pop()
    groups.sort(key=lambda g: -g["bytes"])
    return {"usedBytes": MAP_USED, "groups": groups + [rest]}


def memory() -> dict:
    groups = []
    for name, count, gb, processes in MEM_GROUPS:
        processes = sorted(processes, key=lambda p: -p["bytes"])[:6]
        assert sum(p["bytes"] for p in processes) <= gb * GIB * 1.02, name
        groups.append({"name": name, "bytes": int(gb * GIB), "count": count, "processes": processes})
    groups.sort(key=lambda g: -g["bytes"])
    return {
        "totalBytes": 16 * GIB, "availableBytes": int(4.7 * GIB),
        "swapTotalBytes": 4 * GIB, "swapUsedBytes": int(0.9 * GIB),
        "processBytes": int(11.2 * GIB), "groups": groups[:8],
    }


def workers() -> list[dict]:
    out = []
    for i, (name, user, workspace, state, idle_h, pid, gb, nprocs, version, flags) in enumerate(WORKERS):
        since = AT - idle_h * 3600
        started = since - (6 + i * 9) * 3600
        session = SESSION_IDS[i]
        resume = " ".join(part for part in ["claude", flags, "--resume", session] if part)
        out.append({
            "id": f"worker:{pid}:{ticks(started)}", "pid": pid, "user": user, "name": name, "workspace": workspace,
            "state": state, "stateSince": round(since, 1), "lastActivity": round(since, 1),
            "startedAt": round(started, 1), "memBytes": int(gb * GIB), "processes": nprocs, "sessionId": session,
            "version": version, "resumeCommand": resume,
            "closable": state == "idle" and idle_h >= 0.5,
        })
    # Busy first, then idle longest first.
    out.sort(key=lambda w: (w["state"] != "busy", w["lastActivity"]))
    return out


def history() -> list[dict]:
    """The last 24 h at 5-minute steps, oldest first: the disk creeps up, RAM breathes with the day."""
    rows = []
    for i in range(288):
        at = AT - (287 - i) * 300
        hours_ago = (287 - i) / 12
        used = DISK_USED - int(GROWTH * hours_ago) + int(180 * MIB * math.sin(i / 7))
        avail = int((5.4 + 1.1 * math.sin(i / 23) - 0.6 * (i / 287)) * GIB)
        swap = int((0.7 + 0.2 * (i / 287) + 0.05 * math.sin(i / 11)) * GIB)
        busy = 1 + (1 if 96 <= i < 180 else 0) + (1 if 130 <= i < 150 else 0)
        rows.append({"at": round(at, 1), "diskUsedBytes": used, "memAvailableBytes": avail, "swapUsedBytes": swap,
                     "busy": busy, "idle": 4 - busy})
    rows[-1]["diskUsedBytes"] = DISK_USED
    rows[-1]["memAvailableBytes"] = int(4.7 * GIB)
    rows[-1]["swapUsedBytes"] = int(0.9 * GIB)
    rows[-1]["busy"], rows[-1]["idle"] = 1, 3
    return rows


def status(lang: str) -> dict:
    published = actions(lang)
    return {
        "schema": 2, "ok": True, "version": "0.2.0", "host": "web-1", "at": AT, "uptimeSec": UPTIME,
        "cpu": {"cores": 8, "load1": 2.37, "load5": 1.98, "load15": 1.64},
        "memory": memory(),
        "disk": {"mount": "/", "totalBytes": DISK_TOTAL, "usedBytes": DISK_USED, "freeBytes": DISK_FREE,
                 "growthBytesPerHour": GROWTH, "fullInHours": DISK_FREE / GROWTH},
        "services": [{"name": "nginx", "active": True}, {"name": "postgresql", "active": True},
                     {"name": "docker", "active": True}],
        "oomKills": [{"at": round(AT - 5.2 * 3600, 1), "process": "chrome", "pid": 57012}],
        "workers": workers(),
        "history": history(),
        "scan": {"at": round(AT - 2.1 * 3600, 1), "running": False, "actions": published,
                 "map": disk_map(lang, published)},
    }


def check(s: dict) -> None:
    groups = s["scan"]["map"]["groups"]
    assert sum(g["bytes"] for g in groups) == s["scan"]["map"]["usedBytes"]
    assert groups[-1]["id"] == "rest" and all(g["freeableBytes"] <= g["bytes"] for g in groups)
    published = {a["id"] for a in s["scan"]["actions"]}
    assert all(set(g["actions"]) <= published for g in groups)
    sizes = [a["bytes"] for a in s["scan"]["actions"]]
    assert sizes == sorted(sizes, reverse=True)
    for group in s["memory"]["groups"]:
        assert all(p["treeBytes"] >= p["bytes"] for p in group["processes"])


def main() -> None:
    for lang, name in [("en", "status.json"), ("es", "status.es.json")]:
        s = status(lang)
        check(s)
        (ROOT / "fixtures" / name).write_text(json.dumps(s, indent=2, ensure_ascii=False) + "\n")
        print(f"fixtures/{name}")


if __name__ == "__main__":
    main()
