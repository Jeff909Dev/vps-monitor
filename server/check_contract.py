#!/usr/bin/env python3
"""Check that a `vpsmon status` JSON has exactly the schema-3 shape of docs/contract.md.

Usage: python3 server/check_contract.py [status.json]      (stdin when no file is given)
       ssh <host> /usr/local/bin/vpsmon status | python3 server/check_contract.py

Every key must exist with the type in SHAPE, and no key may be added. A list in SHAPE gives the shape of each element
by its first element, and an object whose one key is "*" is a map: any keys, each value of that shape. Integers stay
integers; a float also accepts an integer. Ids must be ones the contract lists or match its id patterns. The disks
list / first, then the other mounts by path, each device once. The disk map must add up: its groups sum to usedBytes,
no group frees more than it holds, rest comes last, and a group only names published actions. Exit 0 when it all
holds, 1 when it does not.
"""

import json
import re
import sys
from pathlib import Path

SCHEMA = 3
SHAPE = {
    "schema": 3,
    "ok": True,
    "version": "0.3.0",
    "host": "web-1",
    "at": 0.5,
    "uptimeSec": 0,
    "cpu": {"cores": 0, "load1": 0.5, "load5": 0.5, "load15": 0.5},
    "memory": {
        "totalBytes": 0, "availableBytes": 0, "swapTotalBytes": 0, "swapUsedBytes": 0, "processBytes": 0,
        "groups": [{
            "name": "node", "bytes": 0, "count": 0,
            "processes": [{
                "id": "proc:1:1", "pid": 0, "user": "deploy", "command": "node /srv/api/server.js", "bytes": 0,
                "treeBytes": 0, "children": 0, "startedAt": 0.5, "killable": True,
            }],
        }],
    },
    "disks": [{"mount": "/", "device": "/dev/sda1", "fstype": "ext4", "totalBytes": 0, "usedBytes": 0, "freeBytes": 0,
               "growthBytesPerHour": 0.5, "fullInHours": 0.5}],
    "services": [{"name": "nginx", "active": True}],
    "oomKills": [{"at": 0.5, "process": "node", "pid": 0}],
    "workers": [{
        "id": "worker:1:1", "pid": 0, "user": "deploy", "name": "api-refactor", "workspace": "/home/deploy/code/api",
        "state": "idle", "stateSince": 0.5, "lastActivity": 0.5, "startedAt": 0.5, "memBytes": 0, "processes": 0,
        "sessionId": "", "version": "", "resumeCommand": "", "closable": True,
    }],
    "history": [{"at": 0.5, "disks": {"*": 0}, "memAvailableBytes": 0, "swapUsedBytes": 0, "busy": 0, "idle": 0}],
    "scan": {
        "at": 0.5,
        "running": False,
        "actions": [{"id": "tmp-stale", "title": "", "detail": "", "bytes": 0, "risk": "safe", "count": 0,
                     "items": [{"label": "", "bytes": 0}]}],
        "map": {
            "usedBytes": 0,
            "groups": [{"id": "temp", "title": "", "hint": "", "bytes": 0, "freeableBytes": 0, "actions": ["tmp-stale"],
                        "children": [{"path": "/tmp", "bytes": 0}]}],
        },
    },
}
NULLABLE = {"disks[].growthBytesPerHour", "disks[].fullInHours", "scan.at"}
ACTION_IDS = {
    "tmp-stale", "claude-tmp", "big-logs", "claude-versions", "pkg-caches", "journal", "apt-cache", "docker-images",
    "docker-volumes", "docker-build-cache",
}
MAP_IDS = {"home", "claude", "caches", "docker", "logs", "temp", "swap", "system", "rest"}
ENUMS = {
    "schema": {SCHEMA},
    "workers[].state": {"busy", "idle", "unknown"},
    "scan.actions[].risk": {"safe", "review"},
    "scan.actions[].id": ACTION_IDS,
    "scan.map.groups[].id": MAP_IDS,
    "scan.map.groups[].actions[]": ACTION_IDS,
}
PATTERNS = {
    "workers[].id": re.compile(r"worker:\d+:\d+"),
    "memory.groups[].processes[].id": re.compile(r"proc:\d+:\d+"),
}
MEM_GROUPS, MEM_PROCESSES = 8, 6


def kind(value) -> str:
    if value is None:
        return "null"
    if isinstance(value, bool):
        return "bool"
    if isinstance(value, int):
        return "int"
    return {float: "float", str: "str", list: "list", dict: "object"}[type(value)]


def shape_errors(expected, actual, path: str) -> list[str]:
    want, got = kind(expected), kind(actual)
    if got == "null":
        return [] if path in NULLABLE else [f"{path}: null where the contract has {want}"]
    if want != got and not (want == "float" and got == "int"):
        return [f"{path}: {got} where the contract has {want}"]
    if want == "object" and list(expected) == ["*"]:
        return [e for k, v in actual.items() for e in shape_errors(expected["*"], v, f"{path}.{k}")]
    if want == "object":
        prefix = f"{path}." if path else ""
        errors = [f"{prefix}{k}: missing" for k in expected if k not in actual]
        errors += [f"{prefix}{k}: not in the contract" for k in actual if k not in expected]
        for k in expected.keys() & actual.keys():
            errors += shape_errors(expected[k], actual[k], prefix + k)
        return errors
    if want == "list":
        return [e for item in actual for e in shape_errors(expected[0], item, f"{path}[]")]
    allowed, pattern = ENUMS.get(path), PATTERNS.get(path)
    if allowed is not None and actual not in allowed:
        return [f"{path}: {actual!r} is not one of {sorted(allowed)}"]
    if pattern is not None and not pattern.fullmatch(actual):
        return [f"{path}: {actual!r} does not match {pattern.pattern}"]
    return []


def disk_errors(disks: list[dict]) -> list[str]:
    mounts, devices = [d["mount"] for d in disks], [d["device"] for d in disks]
    errors = []
    if mounts[:1] != ["/"]:
        errors.append("disks: / is not first")
    if mounts[1:] != sorted(set(mounts[1:]) - {"/"}):
        errors.append("disks: the mounts after / are not each once, by path")
    errors += [f"disks: device {d} listed twice" for d in sorted(set(devices)) if devices.count(d) > 1]
    return errors


def map_errors(scan: dict) -> list[str]:
    disk_map, published = scan["map"], {a["id"] for a in scan["actions"]}
    groups = disk_map["groups"]
    total = sum(g["bytes"] for g in groups)
    errors = []
    if groups and total != disk_map["usedBytes"]:
        errors.append(f"scan.map: groups add up to {total}, usedBytes is {disk_map['usedBytes']}")
    errors += [f"scan.map.groups[{g['id']}]: freeableBytes over bytes" for g in groups if g["freeableBytes"] > g["bytes"]]
    errors += [f"scan.map.groups[{g['id']}]: names unpublished action {a}"
               for g in groups for a in g["actions"] if a not in published]
    if any(g["id"] == "rest" for g in groups[:-1]):
        errors.append("scan.map: rest is not last")
    return errors


def memory_errors(memory: dict) -> list[str]:
    groups = memory["groups"]
    errors = []
    if len(groups) > MEM_GROUPS:
        errors.append(f"memory.groups: {len(groups)} groups, at most {MEM_GROUPS}")
    if [g["bytes"] for g in groups] != sorted((g["bytes"] for g in groups), reverse=True):
        errors.append("memory.groups: not biggest first")
    if sum(g["bytes"] for g in groups) > memory["processBytes"]:
        errors.append("memory.groups: add up to more than processBytes")
    errors += [f"memory.groups[{g['name']}]: more than {MEM_PROCESSES} processes"
               for g in groups if len(g["processes"]) > MEM_PROCESSES]
    return errors


def check(actual) -> list[str]:
    errors = sorted(set(shape_errors(SHAPE, actual, "")))
    return errors or disk_errors(actual["disks"]) + map_errors(actual["scan"]) + memory_errors(actual["memory"])


def main() -> int:
    text = Path(sys.argv[1]).read_text() if len(sys.argv) > 1 else sys.stdin.read()
    actual = json.loads(text)
    errors = check(actual)
    for error in errors:
        print(error)
    if errors:
        print(f"FAIL: {len(errors)} contract mismatches")
        return 1
    scan = actual["scan"]
    print(
        f"ok: {len(actual['disks'])} disks, {len(actual['workers'])} workers, "
        f"{len(actual['memory']['groups'])} mem groups, {len(actual['services'])} services, "
        f"{len(scan['actions'])} actions, {len(scan['map']['groups'])} map groups, {len(actual['history'])} history rows"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
