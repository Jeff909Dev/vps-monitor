import fcntl
import importlib.machinery
import importlib.util
import json
import os
import shutil
import socket
import string
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
FIXTURE = HERE.parent / "fixtures" / "status.json"
# A `du -x -B1 --max-depth=4 --threshold=10M /` of a fictional host (user deploy, apps in /srv, Docker, a swapfile) and
# the statvfs used bytes read when it finished.
DU_SAMPLE = HERE.parent / "fixtures" / "dumap.txt"


def load_vpsmon():
    loader = importlib.machinery.SourceFileLoader("vpsmon", str(HERE / "vpsmon"))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader("vpsmon", loader))
    sys.modules["vpsmon"] = module
    loader.exec_module(module)
    return module


vpsmon = load_vpsmon()
EN, ES = vpsmon.Text("en"), vpsmon.Text("es")
NOW = 1_795_264_909.0
HOUR = 3600
LIVE_ID = "11111111-1111-4111-8111-111111111111"
OLD_ID = "22222222-2222-4222-8222-222222222222"
RECENT_ID = "33333333-3333-4333-8333-333333333333"
TOUCHED_ID = "44444444-4444-4444-8444-444444444444"
OPEN_ID = "55555555-5555-4555-8555-555555555555"


class ResumeCommand(unittest.TestCase):
    def test_keeps_flags_and_drops_plugin_dir_and_old_resume(self):
        argv = [
            "/home/deploy/.local/bin/claude", "--plugin-dir", "/home/deploy/.config/agent-view/ab/agent-view",
            "--dangerously-skip-permissions", "--effort", "xhigh", "--resume", "d323da7d-old",
        ]
        self.assertEqual(
            vpsmon.resume_command(argv, "new-id"),
            "claude --dangerously-skip-permissions --effort xhigh --resume new-id",
        )

    def test_drops_short_resume_continue_and_equals_forms(self):
        argv = ["claude", "-r", "old", "--continue", "--plugin-dir=/x", "--resume=old2", "--model", "opus"]
        self.assertEqual(vpsmon.resume_command(argv, "sid"), "claude --model opus --resume sid")

    def test_bare_resume_does_not_swallow_the_next_flag(self):
        self.assertEqual(
            vpsmon.resume_command(["claude", "--resume", "--verbose"], "sid"), "claude --verbose --resume sid"
        )


def fake_bin(folder, name, script):
    path = Path(folder) / name
    path.write_text("#!/bin/sh\n" + script)
    path.chmod(0o755)
    return path


@unittest.skipIf(os.geteuid() == 0, "these check what vpsmon does when it is not root")
class Commands(unittest.TestCase):
    """The command line as the app runs it, with sudo replaced by a fake that shows what it was asked."""

    def run_vpsmon(self, *args, sudo=None):
        with tempfile.TemporaryDirectory() as bin_dir:
            if sudo is not None:
                fake_bin(bin_dir, "sudo", sudo)
            env = {**os.environ, "PATH": bin_dir}
            return subprocess.run([sys.executable, str(HERE / "vpsmon"), *args], capture_output=True, text=True, env=env)

    def test_version_needs_no_root_and_matches_the_repo(self):
        r = self.run_vpsmon("version")
        version = (HERE.parent / "VERSION").read_text().strip()
        self.assertEqual((r.returncode, json.loads(r.stdout)), (0, {"ok": True, "version": version, "schema": 2}))
        self.assertEqual(vpsmon.VERSION, version)

    def test_another_user_runs_the_same_command_through_sudo(self):
        r = self.run_vpsmon("--lang", "es", "act", "tmp-stale", "--dry-run", sudo='printf "%s\\n" "$@"')
        self.assertEqual(r.stdout.splitlines(), ["-n", str(HERE / "vpsmon"), "--lang", "es", "act", "tmp-stale", "--dry-run"])

    def test_sudos_own_refusal_reaches_the_app(self):
        r = self.run_vpsmon("status", sudo='echo "sudo: a password is required" >&2; exit 1')
        self.assertEqual((r.returncode, r.stdout), (1, ""))
        self.assertIn("a password is required", r.stderr)

    def test_without_sudo_it_says_so(self):
        r = self.run_vpsmon("--lang", "es", "status")
        self.assertEqual(r.returncode, 1)
        self.assertIn("command not found", r.stderr)
        self.assertEqual(json.loads(r.stdout)["error"], vpsmon.MESSAGES["es"]["err.no-sudo"])

    def test_a_bad_command_is_a_usage_error_before_any_sudo(self):
        r = self.run_vpsmon("act", sudo="echo called; exit 0")
        self.assertEqual(r.returncode, 2)
        self.assertNotIn("called", r.stdout)


class Uninstall(unittest.TestCase):
    def test_removes_what_the_installer_added_and_keeps_the_audit_log(self):
        with tempfile.TemporaryDirectory() as prefix:
            paths = vpsmon.Paths.under(prefix)
            for path in (paths.bin, *paths.units, paths.sudoers, paths.config, paths.file("scan.json"), paths.audit_log):
                os.makedirs(os.path.dirname(path), exist_ok=True)
                Path(path).write_text("x")
            first = vpsmon.cmd_uninstall(paths)
            self.assertEqual(
                sorted(first["removed"]),
                sorted([*paths.units, paths.sudoers, os.path.dirname(paths.config), paths.state, paths.bin]),
            )
            self.assertFalse(any(os.path.lexists(p) for p in first["removed"]))
            self.assertTrue(os.path.exists(paths.audit_log))
            self.assertEqual(vpsmon.cmd_uninstall(paths), {"ok": True, "removed": []})


class ScanLock(unittest.TestCase):
    def test_a_scan_that_finds_another_running_says_so_and_does_nothing(self):
        with tempfile.TemporaryDirectory() as state:
            paths = vpsmon.Paths(state=state)
            fd = os.open(paths.file("scan.lock"), os.O_RDWR | os.O_CREAT)
            fcntl.flock(fd, fcntl.LOCK_EX)
            try:
                self.assertTrue(vpsmon.scan_running(paths))
                self.assertEqual(vpsmon.cmd_scan(paths, background=False), {"ok": True, "running": True})
                self.assertEqual(vpsmon.cmd_scan(paths, background=True), {"ok": True, "running": True})
            finally:
                os.close(fd)
            self.assertFalse(vpsmon.scan_running(paths))
            self.assertFalse(os.path.exists(paths.file("scan.json")))


class Messages(unittest.TestCase):
    def fields(self, text):
        return sorted(f for _, f, _, _ in string.Formatter().parse(text) if f is not None)

    def test_both_languages_have_the_same_keys_and_the_same_fields(self):
        en, es = vpsmon.MESSAGES["en"], vpsmon.MESSAGES["es"]
        self.assertEqual(sorted(en), sorted(es))
        for key in en:
            self.assertEqual(self.fields(en[key]), self.fields(es[key]), key)

    def test_every_action_and_map_group_reads_in_both_languages(self):
        for tr in (EN, ES):
            for action in vpsmon.REGISTRY:
                view = vpsmon.action_view({"id": action.id, "bytes": 1, "risk": action.risk, "count": 2, "items": []}, tr)
                self.assertTrue(view["title"] and view["detail"], action.id)
                self.assertNotIn("{", view["detail"])
            stored = {"usedBytes": 9, "groups": [{"id": g.id, "bytes": 1, "children": []} for g in vpsmon.MAP_GROUPS]}
            for group in vpsmon.map_view(stored, [], tr)["groups"]:
                self.assertTrue(group["title"] and group["hint"], group["id"])

    def test_counts_and_sizes_follow_the_language(self):
        self.assertEqual(EN.count(155741, "folder"), "155,741 folders")
        self.assertEqual(ES.count(155741, "folder"), "155.741 carpetas")
        self.assertEqual((EN.count(1, "folder"), ES.count(1, "folder")), ("1 folder", "1 carpeta"))

    def test_a_handled_error_reads_in_the_requested_language(self):
        error = vpsmon.Fail("err.unknown-action", id="nope")
        self.assertEqual(error.text(EN), "Unknown action nope")
        self.assertEqual(error.text(ES), "No conozco la acción nope")

    def test_status_titles_follow_the_language(self):
        stored = {"id": "tmp-stale", "bytes": 5, "risk": "safe", "count": 38, "items": []}
        self.assertEqual(vpsmon.action_view(stored, EN)["detail"][:10], "38 entries")
        self.assertEqual(vpsmon.action_view(stored, ES)["detail"][:11], "38 entradas")
        self.assertIsNone(vpsmon.action_view({**stored, "id": "retired-action"}, EN))

    def test_an_unknown_language_is_a_usage_error(self):
        r = subprocess.run([sys.executable, str(HERE / "vpsmon"), "--lang", "fr", "status"], capture_output=True, text=True)
        self.assertEqual(r.returncode, 2)
        self.assertEqual(json.loads(r.stdout)["ok"], False)


def history(rows_per_hour, hours, start_used, per_hour):
    step = HOUR / rows_per_hour
    n = int(hours * rows_per_hour)
    return [
        {"at": NOW - (n - 1 - i) * step, "diskUsedBytes": int(start_used + per_hour * (i * step / HOUR) + (i % 3) * 1000)}
        for i in range(n)
    ]


class Growth(unittest.TestCase):
    def test_slope_over_last_day(self):
        rows = history(12, 24, 290e9, 540e6)
        self.assertAlmostEqual(vpsmon.growth_per_hour(rows, NOW), 540e6, delta=1e5)

    def test_ignores_rows_older_than_a_day(self):
        old = [{"at": NOW - 30 * HOUR, "diskUsedBytes": 0}]
        rows = old + history(12, 6, 290e9, 100e6)
        self.assertAlmostEqual(vpsmon.growth_per_hour(rows, NOW), 100e6, delta=1e5)

    def test_null_with_less_than_an_hour(self):
        self.assertIsNone(vpsmon.growth_per_hour(history(12, 0.9, 290e9, 540e6), NOW))
        self.assertIsNone(vpsmon.growth_per_hour([], NOW))

    def test_full_in_hours(self):
        self.assertAlmostEqual(vpsmon.full_in_hours(4_000_000_000, 500_000_000.0), 8.0)
        self.assertIsNone(vpsmon.full_in_hours(4_000_000_000, -1.0))
        self.assertIsNone(vpsmon.full_in_hours(4_000_000_000, None))


class WorkerRules(unittest.TestCase):
    def test_closable_needs_idle_for_thirty_minutes(self):
        self.assertTrue(vpsmon.is_closable("idle", NOW - 31 * 60, NOW))
        self.assertFalse(vpsmon.is_closable("idle", NOW - 29 * 60, NOW))
        self.assertFalse(vpsmon.is_closable("busy", NOW - 5 * HOUR, NOW))
        self.assertFalse(vpsmon.is_closable("unknown", NOW - 5 * HOUR, NOW))

    def test_busy_first_then_idle_longest_first(self):
        workers = [
            {"name": "idle-recent", "state": "idle", "lastActivity": NOW - 60},
            {"name": "odd", "state": "unknown", "lastActivity": NOW - 9 * HOUR},
            {"name": "busy", "state": "busy", "lastActivity": NOW},
            {"name": "idle-old", "state": "idle", "lastActivity": NOW - 8 * HOUR},
        ]
        self.assertEqual(
            [w["name"] for w in vpsmon.sort_workers(workers)], ["busy", "idle-old", "idle-recent", "odd"]
        )

    def test_descendants_walk_the_whole_subtree(self):
        children = {10: [11, 12], 11: [13], 99: [100]}
        self.assertEqual(sorted(vpsmon.descendants(children, 10)), [11, 12, 13])


class Parsers(unittest.TestCase):
    def test_oom_kill_lines_from_the_kernel_and_earlyoom(self):
        kernel = ("Out of memory: Killed process 438914 (node (vitest 2)) total-vm:14302448kB, anon-rss:2755380kB, "
                  "file-rss:6272kB, shmem-rss:0kB, UID:1000 pgtables:80224kB oom_score_adj:500")
        self.assertEqual(vpsmon.parse_oom_kill(kernel), (438914, "node (vitest 2)"))
        cgroup = "Memory cgroup out of memory: Killed process 77 (postgres) total-vm:900kB, anon-rss:800kB"
        self.assertEqual(vpsmon.parse_oom_kill(cgroup), (77, "postgres"))
        line = 'sending SIGTERM to process 1312552 uid 1000 "node": badness 834, VmRSS 8 MiB'
        self.assertEqual(vpsmon.parse_oom_kill(line), (1312552, "node"))
        self.assertIsNone(vpsmon.parse_oom_kill("sending SIGTERM when mem <=  4.00% and swap <= 100.00%,"))
        self.assertIsNone(vpsmon.parse_oom_kill("low memory! at or below SIGTERM limits: mem  4.00%"))

    def test_journal_vacuum_removes_oldest_archives_until_under_limit(self):
        mib = 1024 * 1024
        files = [
            ("system.journal", 128 * mib, NOW, False),
            ("system@a.journal", 128 * mib, NOW - 3 * HOUR, True),
            ("system@b.journal", 128 * mib, NOW - 2 * HOUR, True),
            ("system@c.journal", 128 * mib, NOW - 1 * HOUR, True),
        ]
        self.assertEqual(vpsmon.journal_excess(files, 200 * mib), ["system@a.journal", "system@b.journal", "system@c.journal"])
        self.assertEqual(vpsmon.journal_excess(files, 300 * mib), ["system@a.journal", "system@b.journal"])

    def test_docker_sizes(self):
        self.assertEqual(vpsmon.parse_docker_size("238MB"), 238_000_000)
        self.assertEqual(vpsmon.parse_docker_size("1.18GB"), 1_180_000_000)
        self.assertEqual(vpsmon.parse_docker_size("57.8kB"), 57_800)


class Services(unittest.TestCase):
    def test_watched_units_then_failed_units_nobody_watches(self):
        view = vpsmon.services_view(
            ["nginx", "docker"], ["failed", "active"], ["certbot.service", "nginx.service", "backup.timer"]
        )
        self.assertEqual(view, [
            {"name": "nginx", "active": False}, {"name": "docker", "active": True},
            {"name": "certbot", "active": False}, {"name": "backup.timer", "active": False},
        ])
        self.assertEqual(vpsmon.services_view([], [], []), [])

    def test_the_config_keeps_only_valid_unit_names(self):
        self.assertEqual(vpsmon.parse_config(None), {"services": []})
        self.assertEqual(vpsmon.parse_config({"services": "nginx"}), {"services": []})
        self.assertEqual(
            vpsmon.parse_config({"services": ["nginx", 3, "-H", "a b", "getty@tty1.service"], "other": 1}),
            {"services": ["nginx", "getty@tty1.service"]},
        )


def touch_tree(root, mtime):
    for folder, dirs, files in os.walk(root):
        for name in dirs + files:
            os.utime(os.path.join(folder, name), (mtime, mtime), follow_symlinks=False)
    os.utime(root, (mtime, mtime))


DAY = 24 * HOUR


class DiskActionCase(unittest.TestCase):
    """A fake host in a temp dir. Files get real ctimes, which no test can move back, so `now` lies 30 days ahead:
    everything starts quiet, and a test makes an entry recent by setting its mtime close to `now`."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.tmp.name))
        r = self.root
        for d in ("proc", "tmp", "var_tmp", "home", "roothome", "srv"):
            (r / d).mkdir()
        self.paths = vpsmon.Paths(
            state=str(r / "state"),
            audit_log=str(r / "vpsmon.log"),
            proc=str(r / "proc"),
            tmp=str(r / "tmp"),
            var_tmp=str(r / "var_tmp"),
            home=str(r / "home"),
            root_home=str(r / "roothome"),
            log_roots=(str(r / "tmp"), str(r / "var_tmp"), str(r / "home"), str(r / "roothome"), str(r / "srv")),
            journal=str(r / "journal"),
            apt_archives=str(r / "archives"),
        )
        self.now = time.time() + 30 * DAY

    def tearDown(self):
        self.tmp.cleanup()

    def live(self, **facts):
        return vpsmon.Live(self.paths, self.now, **{"session_ids": set(), "used_paths": set(), "mounts": set(), **facts})

    def write(self, rel, size=10):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(b"x" * size)
        return path

    def sparse(self, rel, size):
        path = self.root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        with open(path, "wb") as f:
            f.truncate(size)
        return path

    def recent(self, rel, ago=HOUR):
        touch_tree(self.root / rel, self.now - ago)

    def names(self, items):
        return sorted(str(Path(i.ref).relative_to(self.root)) for i in items)

    def assert_idempotent(self, action, live):
        first = action.plan(live)
        self.assertTrue(first)
        self.assertEqual(action.apply(live, [i.ref for i in first]), (first, 0))
        self.assertEqual(action.plan(live), [])
        return first


class TmpStale(DiskActionCase):
    def build(self):
        for name in ("old-build", "recent-build", "touched", "open-dir", "mounted", "systemd-private-x", ".X11-unix",
                     ".X1-lock", "tmux-1000", f"claude-{os.getuid()}", "vpsmon-install.abc"):
            self.write(f"tmp/{name}/out.txt", 4096)
        self.write("tmp/old-file.txt", 4096)
        self.write("tmp/sockets/keep.txt")
        sock = socket.socket(socket.AF_UNIX)
        sock.bind(str(self.root / "tmp" / "sockets" / "s"))
        sock.close()
        os.mkfifo(self.root / "tmp" / "pipe")
        self.write("var_tmp/week-old/cache.bin", 4096)
        self.write("var_tmp/days-old/cache.bin", 4096)
        self.recent("tmp/recent-build")
        os.utime(self.root / "tmp" / "touched" / "out.txt", (self.now - 60, self.now - 60))
        self.recent("var_tmp/days-old", ago=3 * DAY)
        return self.live(used_paths={str(self.root / "tmp" / "open-dir" / "out.txt")},
                         mounts={str(self.root / "tmp" / "mounted")})

    def test_selects_quiet_unused_entries_of_tmp_after_a_day_and_of_var_tmp_after_a_week(self):
        live = self.build()
        items = vpsmon.ACTIONS["tmp-stale"].plan(live)
        self.assertEqual(self.names(items), ["tmp/old-build", "tmp/old-file.txt", "var_tmp/week-old"])
        self.assertGreaterEqual(items[0].bytes, 4096)

    def test_apply_removes_them_and_a_second_plan_is_empty(self):
        live = self.build()
        self.assert_idempotent(vpsmon.ACTIONS["tmp-stale"], live)
        left = sorted(p.name for p in (self.root / "tmp").iterdir())
        self.assertNotIn("old-build", left)
        for kept in ("recent-build", "touched", "open-dir", "mounted", "sockets", "pipe", "systemd-private-x", ".X11-unix"):
            self.assertIn(kept, left)
        self.assertTrue((self.root / "var_tmp" / "days-old").is_dir())

    def test_an_old_mtime_does_not_hide_a_fresh_copy(self):
        # tar and cp -p keep the archive's mtimes; the ctime still says the copy is new.
        old = self.write("tmp/extracted/data.txt")
        touch_tree(self.root / "tmp" / "extracted", time.time() - 10 * DAY)
        live = vpsmon.Live(self.paths, time.time() + HOUR, session_ids=set(), used_paths=set(), mounts=set())
        self.assertEqual(vpsmon.ACTIONS["tmp-stale"].plan(live), [])
        self.assertTrue(old.exists())

    def test_refs_outside_its_shape_are_refused(self):
        live = self.build()
        tmp = self.root / "tmp"
        refs = [str(tmp), str(self.root), str(tmp / "old-build" / "out.txt"), str(tmp / "recent-build" / ".." / "old-build"),
                str(self.root / "home" / "x"), str(tmp / "tmux-1000"), str(tmp / f"claude-{os.getuid()}")]
        self.assertEqual(vpsmon.ACTIONS["tmp-stale"].plan(live, within=refs), [])

    def test_act_selects_again_and_the_scan_keeps_only_the_biggest(self):
        for i in range(30):
            self.write(f"tmp/bulk-{i:02}/x", 4096 * (i + 1))
        action = vpsmon.ACTIONS["tmp-stale"]
        summary = action.summary(action.plan(self.live()))
        self.assertEqual(len(summary["items"]), vpsmon.MAX_ITEMS)
        self.assertEqual(summary["count"], 30)
        os.makedirs(self.paths.state)
        Path(self.paths.file("scan.json")).write_text(json.dumps({"schema": 2, "at": self.now, "actions": [summary]}))
        # act reads the host itself: an empty fake /proc means nothing is in use and nothing is mounted.
        dry = vpsmon.act_disk(self.paths, action, dry_run=True, now=self.now, tr=EN)
        self.assertEqual((dry["freedBytes"], len(dry["items"])), (summary["bytes"], vpsmon.MAX_ITEMS))
        self.assertTrue((self.root / "tmp" / "bulk-00").is_dir())
        done = vpsmon.act_disk(self.paths, action, dry_run=False, now=self.now, tr=EN)
        self.assertEqual(done["freedBytes"], summary["bytes"])
        self.assertEqual(done["message"], "Removed 30 items")
        self.assertEqual(list((self.root / "tmp").iterdir()), [])
        record = json.loads(Path(self.paths.audit_log).read_text())
        self.assertEqual((record["count"], len(record["items"])), (30, vpsmon.MAX_ITEMS))


class ClaudeTmp(DiskActionCase):
    def build(self):
        uid = os.getuid()
        slug = f"tmp/claude-{uid}/-home-deploy-code-api"
        for sid in (LIVE_ID, OLD_ID, RECENT_ID, TOUCHED_ID, OPEN_ID):
            self.write(f"{slug}/{sid}/out/result.txt", 4096)
        self.write(f"{slug}/not-a-session/old.txt")
        self.write(f"tmp/claude-{uid}/bash-edit-diff/{OLD_ID}/diff.txt")
        self.write(f"tmp/claude-{uid}/all-test.log")
        # Named for another uid but owned by this one: not that user's folder.
        self.write(f"tmp/claude-{uid + 1}/-home-other/{OLD_ID}/out.txt")
        self.recent(f"{slug}/{RECENT_ID}")
        os.utime(self.root / slug / TOUCHED_ID / "out" / "result.txt", (self.now - 60, self.now - 60))
        return self.root / slug

    def test_selects_only_dead_quiet_session_dirs_of_their_owner(self):
        slug_dir = self.build()
        live = self.live(session_ids={LIVE_ID}, used_paths={str(slug_dir / OPEN_ID / "out" / "result.txt")})
        items = vpsmon.ACTIONS["claude-tmp"].plan(live)
        self.assertEqual([i.ref for i in items], [str(slug_dir / OLD_ID)])
        self.assertGreaterEqual(items[0].bytes, 4096)

    def test_plan_twice_after_apply_is_empty(self):
        slug_dir = self.build()
        live = self.live(session_ids={LIVE_ID}, used_paths={str(slug_dir / OPEN_ID / "out" / "result.txt")})
        self.assert_idempotent(vpsmon.ACTIONS["claude-tmp"], live)
        self.assertTrue((slug_dir / LIVE_ID).is_dir())
        self.assertTrue((slug_dir.parent / "all-test.log").is_file())
        self.assertTrue((slug_dir.parent / "bash-edit-diff").is_dir())

    def test_act_rejects_refs_outside_its_shape(self):
        slug_dir = self.build()
        live = self.live(session_ids={LIVE_ID})
        refs = [
            str(self.root),
            str(slug_dir.parent / "bash-edit-diff" / OLD_ID),
            str(slug_dir / OLD_ID / ".." / LIVE_ID),
            str(slug_dir / LIVE_ID),
            str(slug_dir / "not-a-session"),
            str(self.root / "tmp" / f"claude-{os.getuid() + 1}" / "-home-other" / OLD_ID),
        ]
        self.assertEqual(vpsmon.ACTIONS["claude-tmp"].plan(live, within=refs), [])


class ActTwice(DiskActionCase):
    def test_an_action_gone_from_the_scan_frees_nothing(self):
        os.makedirs(self.paths.state)
        Path(self.paths.file("scan.json")).write_text(json.dumps({"schema": 2, "at": NOW, "actions": []}))
        result = vpsmon.act_disk(self.paths, vpsmon.ACTIONS["claude-tmp"], dry_run=False, now=NOW, tr=ES)
        self.assertEqual((result["ok"], result["freedBytes"], result["message"]), (True, 0, "Nada que liberar"))


class WriteScan(DiskActionCase):
    def test_actions_land_first_and_the_last_map_stays_until_the_new_one(self):
        os.makedirs(self.paths.state)
        old_map = {"usedBytes": 1, "groups": []}
        Path(self.paths.file("scan.json")).write_text(json.dumps({"schema": 2, "at": NOW - HOUR, "actions": [], "map": old_map}))
        actions = [{"id": "journal", "bytes": 5, "items": []}, {"id": "apt-cache", "bytes": 9, "items": []}]
        first = vpsmon.write_scan(self.paths, NOW, actions, None)
        self.assertEqual(([a["id"] for a in first["actions"]], first["map"]), (["apt-cache", "journal"], old_map))
        # An act while du runs takes its action out; the second write must not bring it back.
        scan = json.loads(Path(self.paths.file("scan.json")).read_text())
        scan["actions"] = [a for a in scan["actions"] if a["id"] != "journal"]
        scan["appliedAt"] = {"journal": NOW + 60}
        Path(self.paths.file("scan.json")).write_text(json.dumps(scan))
        new_map = {"usedBytes": 2, "groups": []}
        vpsmon.write_scan(self.paths, NOW, actions, new_map)
        saved = json.loads(Path(self.paths.file("scan.json")).read_text())
        self.assertEqual(([a["id"] for a in saved["actions"]], saved["map"]), (["apt-cache"], new_map))


class BigLogs(DiskActionCase):
    def test_big_unused_logs_outside_pruned_dirs_and_outside_other_actions_items(self):
        big = 201 * 1024 * 1024
        keep = self.sparse("home/deploy/code/app/server.log", big)
        self.sparse("home/deploy/code/app/node_modules/pkg/huge.log", big)
        self.sparse("home/deploy/code/app/.git/huge.log", big)
        self.sparse("home/deploy/code/app/small.log", 1024)
        self.sparse("home/deploy/code/app/data.bin", big)
        held = self.sparse("home/deploy/code/app/open.log", big)
        srv = self.sparse("srv/api/logs/api.log", big)
        # tmp-stale takes this whole folder, log included; the active one stays, so its log is big-logs'.
        self.sparse("tmp/old-build/run.log", big)
        active = self.sparse("tmp/active-build/run.log", big)
        self.write("tmp/active-build/progress.txt")
        self.recent("tmp/active-build/progress.txt")
        uid = os.getuid()
        self.sparse(f"tmp/claude-{uid}/-home-x/{OLD_ID}/tasks/run.log", big)
        live_log = self.sparse(f"tmp/claude-{uid}/-home-x/{LIVE_ID}/tasks/run.log", big)
        live = self.live(session_ids={LIVE_ID}, used_paths={str(held)})
        items = vpsmon.ACTIONS["big-logs"].plan(live)
        self.assertEqual(sorted(i.ref for i in items), sorted(map(str, [keep, srv, active, live_log])))
        self.assert_idempotent(vpsmon.ACTIONS["big-logs"], live)
        self.assertTrue(held.exists())


class ClaudeVersions(DiskActionCase):
    def install(self, home, versions, current):
        for v in versions:
            self.write(f"{home}/.local/share/claude/versions/{v}", 8192)
        (self.root / home / ".local" / "bin").mkdir(parents=True)
        os.symlink(self.root / home / ".local/share/claude/versions" / current, self.root / home / ".local/bin/claude")

    def test_every_home_keeps_its_current_newer_and_running_versions(self):
        self.install("home/deploy", ("2.1.320", "2.1.322", "2.1.328", "2.1.330", "2.1.331", "2.1.331.tmp"), "2.1.330")
        self.install("roothome", ("1.0.1", "1.0.2"), "1.0.2")
        running = self.root / "home/deploy/.local/share/claude/versions/2.1.328"
        live = self.live(used_paths={str(running)})
        items = vpsmon.ACTIONS["claude-versions"].plan(live)
        self.assertEqual(
            self.names(items),
            ["home/deploy/.local/share/claude/versions/2.1.320", "home/deploy/.local/share/claude/versions/2.1.322",
             "roothome/.local/share/claude/versions/1.0.1"],
        )
        self.assert_idempotent(vpsmon.ACTIONS["claude-versions"], live)
        self.assertEqual(
            sorted(os.listdir(self.root / "home/deploy/.local/share/claude/versions")),
            ["2.1.328", "2.1.330", "2.1.331", "2.1.331.tmp"],
        )


class PkgCaches(DiskActionCase):
    def test_the_four_caches_of_every_home_never_npx_never_through_a_symlink(self):
        for rel in ("home/deploy/.npm/_cacache/a", "home/deploy/.npm/_npx/server/index.js", "home/deploy/.cache/pip/b",
                    "home/deploy/.cache/yarn/c", "roothome/.cache/go-build/d", "srv/elsewhere/pip/e"):
            self.write(rel, 4096)
        (self.root / "home/eve").mkdir()
        os.symlink(self.root / "srv/elsewhere", self.root / "home/eve/.cache")
        live = self.live()
        self.assertEqual(
            self.names(vpsmon.ACTIONS["pkg-caches"].plan(live)),
            ["home/deploy/.cache/pip", "home/deploy/.cache/yarn", "home/deploy/.npm/_cacache", "roothome/.cache/go-build"],
        )
        refused = [str(self.root / "home/deploy/.npm/_npx"), str(self.root / "home/eve/.cache/pip")]
        self.assertEqual(vpsmon.ACTIONS["pkg-caches"].plan(live, within=refused), [])
        self.assert_idempotent(vpsmon.ACTIONS["pkg-caches"], live)
        self.assertTrue((self.root / "home/deploy/.npm/_npx/server/index.js").exists())
        self.assertTrue((self.root / "srv/elsewhere/pip/e").exists())


class Docker(DiskActionCase):
    def test_only_dangling_anonymous_volumes_and_scanned_size_is_reused(self):
        anon = "a" * 64
        live = self.live(dangling_volumes={anon: str(self.root / "missing")}, scanned_bytes={anon: 123})
        plan = vpsmon.ACTIONS["docker-volumes"].plan(live, within=[anon, "named-db", "b" * 64])
        self.assertEqual([(i.ref, i.bytes) for i in plan], [(anon, 123)])

    def test_build_cache_is_one_item_when_docker_reports_any(self):
        action = vpsmon.ACTIONS["docker-build-cache"]
        self.assertEqual([(i.ref, i.bytes) for i in action.plan(self.live(build_cache=5_238_000_000))],
                         [("build-cache", 5_238_000_000)])
        self.assertEqual(action.plan(self.live(build_cache=0)), [])
        self.assertEqual(vpsmon.parse_docker_size("5.238GB (71%)"), 5_238_000_000)
        self.assertEqual(vpsmon.parse_docker_size("0B"), 0)

    def test_actions_whose_tool_is_missing_are_not_published(self):
        ids = lambda tools: [a.id for a in vpsmon.published(self.live(tools=tools))]
        self.assertEqual(ids(set()), ["tmp-stale", "claude-tmp", "big-logs", "claude-versions", "pkg-caches"])
        self.assertIn("docker-build-cache", ids({"docker"}))
        self.assertNotIn("journal", ids({"docker"}))


GB = 1024**3


def du_lines(sizes):
    return "".join(f"{b}\t{p}\n" for p, b in sizes.items())


class DiskMap(unittest.TestCase):
    """The disk map: groups that add up to all the used space, each byte counted once, in its most specific root."""

    DU = {
        "/home/deploy/code/api": 5 * GB,
        "/home/deploy/code": 7 * GB,
        "/home/deploy/.claude/projects": 3 * GB,
        "/home/deploy/.claude": 4 * GB,
        "/home/deploy/.cache/pip": 1 * GB,
        "/home/deploy/.cache": 2 * GB,
        "/home/deploy/backups": 3 * GB,
        "/home/deploy": 17 * GB,
        "/home": 17 * GB,
        "/root/.npm": 1 * GB,
        "/root": 1 * GB,
        "/srv/api": 6 * GB,
        "/srv": 6 * GB,
        "/tmp/claude-1000": 2 * GB,
        "/tmp": 3 * GB,
        "/var/tmp": 1 * GB,
        "/var/lib/docker/overlay2": 8 * GB,
        "/var/lib/docker": 9 * GB,
        "/var/lib/postgresql": 2 * GB,
        "/var/lib": 11 * GB,
        "/var/log/journal": 2 * GB,
        "/var/log": 3 * GB,
        "/var/cache/apt": 1 * GB,
        "/var/cache": 1 * GB,
        "/var": 16 * GB,
        "/usr": 5 * GB,
        "/": 52 * GB,
    }
    SWAP = {"/swapfile": 4 * GB}
    USED = 53 * GB

    def build(self, du=None, used=None, files=None):
        return vpsmon.build_map(du or self.DU, self.USED if used is None else used, self.SWAP if files is None else files)

    def groups(self, m):
        return {g["id"]: g for g in m["groups"]}

    def children(self, group):
        return [(c["path"], c["bytes"] // GB) for c in group["children"]]

    def test_groups_add_up_to_the_used_bytes_and_the_rest_is_last(self):
        m = self.build()
        self.assertEqual(m["usedBytes"], self.USED)
        self.assertEqual(sum(g["bytes"] for g in m["groups"]), self.USED)
        sizes = [g["bytes"] for g in m["groups"][:-1]]
        self.assertEqual(sizes, sorted(sizes, reverse=True))
        self.assertEqual(m["groups"][-1]["id"], "rest")
        sizes = {gid: g["bytes"] // GB for gid, g in self.groups(m).items()}
        self.assertEqual(
            sizes,
            {"home": 11, "claude": 4, "caches": 4, "docker": 9, "logs": 3, "temp": 4, "swap": 4, "system": 5, "rest": 9},
        )

    def test_a_root_inside_another_groups_root_counts_only_in_its_own_group(self):
        groups = self.groups(self.build())
        # /home/deploy holds 17 GB, of which ~/.claude (4) and ~/.cache (2) belong to their own groups; /root holds
        # only ~/.npm, a cache.
        self.assertEqual(groups["home"]["bytes"], 11 * GB)
        self.assertEqual(self.children(groups["home"]), [("/home/deploy/code", 7), ("/home/deploy/backups", 3)])
        self.assertEqual(self.children(groups["claude"]), [("/home/deploy/.claude/projects", 3)])
        self.assertEqual(self.children(groups["caches"]), [("/home/deploy/.cache/pip", 1), ("/var/cache/apt", 1)])

    def test_swap_is_sized_from_the_files_blocks(self):
        groups = self.groups(self.build(files={"/swapfile": 4 * GB, "/swap.img": 2 * GB}))
        self.assertEqual(groups["swap"]["bytes"], 6 * GB)
        self.assertEqual(self.children(groups["swap"]), [("/swapfile", 4), ("/swap.img", 2)])
        with tempfile.TemporaryDirectory() as tmp:
            sparse = Path(tmp) / "swapfile"
            with open(sparse, "wb") as f:
                f.truncate(GB)
            (Path(tmp) / "swapfile2").write_bytes(b"x" * 8192)
            sizes = vpsmon.root_files([f"{tmp}/swapfile*"])
        self.assertLess(sizes[str(sparse)], 1024 * 1024)
        self.assertGreaterEqual(sizes[str(Path(tmp) / "swapfile2")], 8192)

    def test_at_most_six_children(self):
        du = {"/home/deploy": 40 * GB, "/": 40 * GB}
        du.update({f"/home/deploy/dir{i}": i * GB for i in range(1, 9)})
        home = self.groups(self.build(du, used=100 * GB, files={}))["home"]
        self.assertEqual([c["bytes"] // GB for c in home["children"]], [8, 7, 6, 5, 4, 3])

    def test_the_rest_splits_what_no_group_holds_into_folders(self):
        rest = self.groups(self.build())["rest"]
        self.assertEqual(self.children(rest), [("/srv/api", 6), ("/var/lib/postgresql", 2)])
        # Together they are everything du saw outside the groups; the other GB is what du cannot see.
        self.assertEqual(rest["bytes"], 9 * GB)

    def test_groups_bigger_than_the_used_bytes_leave_no_negative_rest(self):
        m = self.build(used=30 * GB)
        self.assertNotIn("rest", self.groups(m))
        self.assertEqual(sum(g["bytes"] for g in m["groups"]), m["usedBytes"])

    def test_a_missing_or_empty_root_drops_its_group(self):
        du = {p: b for p, b in self.DU.items() if not p.startswith("/var/lib/docker")}
        self.assertNotIn("docker", self.groups(self.build(du)))
        self.assertNotIn("swap", self.groups(self.build(files={})))

    def test_the_du_of_a_fictional_host(self):
        lines = DU_SAMPLE.read_text().splitlines()
        used = int(lines[0].removeprefix("# statvfs used "))
        du = vpsmon.parse_du("\n".join(lines[1:]))
        self.assertGreater(len(du), 50)
        m = vpsmon.build_map(du, used, {"/swapfile": 4 * GB})
        self.assertEqual(sum(g["bytes"] for g in m["groups"]), used)
        groups = self.groups(m)
        self.assertEqual(m["groups"][-1]["id"], "rest")
        self.assertEqual(set(groups), {g.id for g in vpsmon.MAP_GROUPS})
        for group in m["groups"]:
            self.assertLessEqual(len(group["children"]), vpsmon.MAP_CHILDREN)
            sizes = [c["bytes"] for c in group["children"]]
            self.assertEqual(sizes, sorted(sizes, reverse=True))
        paths = [(g["id"], c["path"]) for g in m["groups"] for c in g["children"]]
        for gid, a in paths:
            for other, b in paths:
                if gid != other:
                    self.assertFalse(vpsmon.within(a, b), f"{gid} {a} inside {other} {b}")
        self.assertIn(("claude", "/home/deploy/.claude/projects"), paths)
        self.assertIn(("rest", "/srv/web/uploads"), paths)
        self.assertNotIn(("home", "/home/deploy/.cache"), paths)

    def test_du_prints_deep_enough_for_every_groups_children(self):
        self.assertEqual(vpsmon.DU_DEPTH, 4)

    def test_parse_du_skips_noise(self):
        text = "1024\t/a\nnot a line\n2048\t/a b/c\td\n\n"
        self.assertEqual(vpsmon.parse_du(text), {"/a": 1024, "/a b/c\td": 2048})


class Freeable(unittest.TestCase):
    STORED = {
        "usedBytes": 100 * GB,
        "groups": [
            {"id": "home", "bytes": 40 * GB, "children": []},
            {"id": "docker", "bytes": 3 * GB, "children": []},
            {"id": "temp", "bytes": 20 * GB, "children": []},
            {"id": "logs", "bytes": 5 * GB, "children": []},
            {"id": "rest", "bytes": 32 * GB, "children": []},
        ],
    }

    def item(self, ref, size):
        return {"label": ref, "ref": ref, "bytes": size}

    def view(self, actions):
        return {g["id"]: (g["freeableBytes"], g["actions"]) for g in vpsmon.map_view(self.STORED, actions, EN)["groups"]}

    def test_each_item_counts_where_its_path_lives(self):
        actions = [
            {"id": "claude-tmp", "bytes": 5 * GB, "items": [self.item("/tmp/claude-1000/-x/" + OLD_ID, 5 * GB)]},
            {"id": "big-logs", "bytes": 4 * GB, "items": [
                self.item("/home/deploy/code/api/server.log", 2 * GB),
                self.item("/home/deploy/.claude/debug/huge.log", 1 * GB),
                self.item("/var/tmp/build/run.log", 1 * GB),
            ]},
            {"id": "tmp-stale", "bytes": 7 * GB, "items": [self.item("/tmp/build-cache-3f2a", 7 * GB)]},
            {"id": "journal", "bytes": GB, "items": [self.item("/var/log/journal", GB)]},
        ]
        self.assertEqual(
            self.view(actions),
            {
                "home": (3 * GB, ["big-logs"]),
                "docker": (0, []),
                "temp": (13 * GB, ["tmp-stale", "claude-tmp", "big-logs"]),
                "logs": (GB, ["journal"]),
                "rest": (0, []),
            },
        )

    def test_refs_that_are_not_paths_count_for_the_group_that_lists_the_action(self):
        actions = [
            {"id": "docker-volumes", "bytes": 2 * GB, "items": [self.item("a" * 64, 2 * GB)]},
            {"id": "docker-images", "bytes": 4 * GB, "items": [self.item("sha256:" + "b" * 64, 4 * GB)]},
        ]
        # Image sizes are what `docker image ls` reports, so they can outgrow the space docker holds: capped.
        self.assertEqual(self.view(actions)["docker"], (3 * GB, ["docker-images", "docker-volumes"]))

    def test_status_without_a_map_yet(self):
        self.assertEqual(vpsmon.map_view(None, [], EN), {"usedBytes": 0, "groups": []})


MB = 1024 * 1024
BOOT = 1_795_000_000


class FakeProc:
    """A /proc tree in a temp dir: what read_procs, the worker finder and status read."""

    def __init__(self, root: Path):
        self.root = root
        root.mkdir(parents=True, exist_ok=True)
        (root / "meminfo").write_text(
            "MemTotal: 16000000 kB\nMemFree: 2000000 kB\nMemAvailable: 9000000 kB\nSwapTotal: 4000000 kB\n"
            "SwapFree: 3000000 kB\n"
        )
        (root / "uptime").write_text("3283000.12 9000000.00\n")
        (root / "stat").write_text(f"cpu  1 2 3 4\nbtime {BOOT}\n")

    def add(self, pid, ppid, comm, mem_mb=10, swap_mb=0, uid=None, start=None, cmdline=None, environ=None, exe=sys.executable):
        d = self.root / str(pid)
        d.mkdir()
        start = pid * 100 if start is None else start
        fields = ["S", str(ppid)] + ["0"] * 17 + [str(start)] + ["0"] * 5
        (d / "stat").write_text(f"{pid} ({comm}) {' '.join(fields)}\n")
        uid = os.getuid() if uid is None else uid
        status = f"Name:\t{comm}\nUid:\t{uid}\t{uid}\t{uid}\t{uid}\n"
        if mem_mb is not None:
            status += f"RssAnon:\t{mem_mb * 1024} kB\nVmSwap:\t{swap_mb * 1024} kB\n"
        (d / "status").write_text(status)
        (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in (cmdline or [comm])) + b"\0")
        (d / "environ").write_bytes(b"".join(f"{k}={v}\0".encode() for k, v in (environ or {}).items()))
        if exe:
            os.symlink(exe, d / "exe")
        return f"proc:{pid}:{start}"


class ProcCase(unittest.TestCase):
    """A host with systemd, an SSH session running vpsmon, a tmux holding a Claude Code session, node, postgres."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.tmp.name))
        self.proc = FakeProc(self.root / "proc")
        self.cfg = self.root / "claude-config"
        (self.cfg / "sessions").mkdir(parents=True)
        self.paths = vpsmon.Paths(state=str(self.root / "state"), audit_log=str(self.root / "vpsmon.log"),
                                  proc=str(self.proc.root))
        p = self.proc
        p.add(1, 0, "systemd", 12)
        p.add(2, 0, "kthreadd", None, exe=False)
        p.add(3, 2, "kworker/0:1", None, exe=False)
        p.add(40, 1, "systemd-journal", 60)
        p.add(41, 1, "dockerd", 80)
        p.add(42, 1, "containerd-shim-runc-v2", 15)
        p.add(43, 42, "postgres", 300, cmdline=["postgres", "-D", "/var/lib/postgresql/data"])
        p.add(44, 43, "postgres", 100)
        # The SSH session that runs vpsmon: its whole chain is out of reach.
        p.add(500, 1, "sshd-session", 5)
        p.add(501, 500, "bash", 4)
        p.add(502, 501, "sudo", 3)
        p.add(os.getpid(), 502, "python3", 30)
        # tmux holds a Claude Code session: ending tmux would end the session.
        p.add(600, 1, "tmux: server", 8)
        p.add(601, 600, "bash", 4)
        p.add(602, 601, "claude", 900, swap_mb=100, cmdline=["claude", "--resume", "old", "--model", "opus"],
                            environ={"CLAUDE_CONFIG_DIR": str(self.cfg)})
        p.add(603, 602, "node", 200)
        self.worker = "worker:602:60200"
        (self.cfg / "sessions" / "602.json").write_text(json.dumps({
            "pid": 602, "procStart": 60200, "sessionId": LIVE_ID, "cwd": "/home/deploy/code/api", "name": "api-refactor",
            "status": "idle", "statusUpdatedAt": (time.time() - 2 * HOUR) * 1000, "startedAt": (time.time() - 9 * HOUR) * 1000,
            "version": "2.1.330",
        }))
        # A claude without a session file (a helper) and one whose file names an older process: not workers.
        p.add(610, 1, "claude", 50, cmdline=["claude", "--chrome-native-host"], environ={"CLAUDE_CONFIG_DIR": str(self.cfg)})
        p.add(611, 1, "claude", 50, environ={"CLAUDE_CONFIG_DIR": str(self.cfg)})
        (self.cfg / "sessions" / "611.json").write_text(json.dumps({"procStart": 1, "sessionId": OLD_ID, "status": "idle"}))
        self.node = p.add(700, 1, "node", 400, swap_mb=20, cmdline=["node", "/srv/api/server.js", "--port", "3000"])
        p.add(701, 700, "node", 200)
        p.add(702, 701, "esbuild", 50)
        p.add(800, 1, "python3", 120, exe=False)
        # A daemon run from sbin (a VPN, say), and a shell whose child is one.
        p.add(810, 1, "vpnd", 30, exe="/usr/sbin/vpnd")
        p.add(820, 1, "bash", 4)
        p.add(821, 820, "web", 20, exe="/usr/local/sbin/web")

    def tearDown(self):
        self.tmp.cleanup()

    def snapshot(self):
        procs = vpsmon.read_procs(self.paths.proc)
        sessions = vpsmon.find_sessions(procs, self.paths)
        children = vpsmon.children_of(procs)
        return procs, children, sessions


class MemoryGroups(ProcCase):
    def memory(self):
        procs, children, sessions = self.snapshot()
        protected = {s.proc.pid for s in sessions} | {os.getpid()}
        return vpsmon.memory_groups(procs, children, protected, self.paths.proc)

    def test_ram_groups_by_program_biggest_first(self):
        memory = self.memory()
        groups = {g["name"]: g for g in memory["groups"]}
        self.assertEqual([g["name"] for g in memory["groups"]][:3], ["claude", "node", "postgres"])
        self.assertEqual((groups["node"]["bytes"], groups["node"]["count"]), (820 * MB, 3))
        self.assertEqual(groups["claude"]["bytes"], 1100 * MB)
        # Kernel threads have no memory map: they count nowhere.
        total = 12 + 60 + 80 + 15 + 300 + 100 + 5 + 4 + 3 + 30 + 8 + 4 + 1000 + 200 + 50 + 50 + 420 + 200 + 50 + 120 + 54
        self.assertEqual(memory["processBytes"], total * MB)
        self.assertNotIn("kthreadd", groups)
        self.assertLessEqual(len(memory["groups"]), vpsmon.MEM_GROUPS)

    def test_each_process_shows_what_ending_its_tree_frees(self):
        node = {g["name"]: g for g in self.memory()["groups"]}["node"]["processes"]
        first = node[0]
        self.assertEqual(first["id"], self.node)
        self.assertEqual((first["bytes"], first["treeBytes"], first["children"]), (420 * MB, 670 * MB, 2))
        self.assertEqual(first["command"], "node /srv/api/server.js --port 3000")
        self.assertEqual(first["startedAt"], BOOT + 70000 / os.sysconf("SC_CLK_TCK"))
        self.assertEqual([p["bytes"] for p in node], sorted((p["bytes"] for p in node), reverse=True))

    def test_what_may_be_ended(self):
        procs, children, sessions = self.snapshot()
        protected = {s.proc.pid for s in sessions} | {os.getpid()}
        can_end = {pid for pid in procs
                   if vpsmon.killable(pid, procs, children, protected, lambda q: vpsmon.exe_of(self.paths.proc, q))}
        self.assertEqual(can_end, {43, 44, 603, 610, 611, 700, 701, 702})
        self.assertFalse(820 in can_end or 821 in can_end or 810 in can_end)

    def test_at_most_six_processes_and_long_commands_are_cut(self):
        for i in range(10):
            self.proc.add(900 + i, 1, "worker-pool", 500 + i, cmdline=["worker-pool", "x" * 300])
        pool = {g["name"]: g for g in self.memory()["groups"]}["worker-pool"]
        self.assertEqual((pool["count"], len(pool["processes"])), (10, vpsmon.MEM_PROCESSES))
        self.assertEqual(len(pool["processes"][0]["command"]), vpsmon.COMMAND_MAX)


class Workers(ProcCase):
    def test_a_worker_is_a_claude_with_a_live_session_file(self):
        procs, children, sessions = self.snapshot()
        self.assertEqual([s.proc.pid for s in sessions], [602])
        view = vpsmon.worker_view(sessions[0], procs, children, time.time(), self.paths.proc)
        self.assertEqual(view["id"], self.worker)
        self.assertEqual(view["user"], vpsmon.user_name(os.getuid()))
        self.assertEqual((view["memBytes"], view["processes"]), (1200 * MB, 2))
        self.assertEqual(view["resumeCommand"], f"claude --model opus --resume {LIVE_ID}")
        self.assertTrue(view["closable"])

    def test_closing_refuses_what_is_not_an_idle_worker(self):
        with self.assertRaises(vpsmon.Fail) as e:
            vpsmon.act_worker(self.paths, "worker:610:61000", True, time.time(), EN)
        self.assertEqual(e.exception.key, "err.no-session")
        with self.assertRaises(vpsmon.Fail) as e:
            vpsmon.act_worker(self.paths, "worker:602:1", True, time.time(), EN)
        self.assertEqual(e.exception.key, "err.worker-gone")

    def test_dry_run_close_names_the_resume_command(self):
        dry = vpsmon.act_worker(self.paths, self.worker, True, time.time(), EN)
        self.assertEqual((dry["freedBytes"], dry["message"]), (1200 * MB, "Would close api-refactor (2 processes)"))
        self.assertEqual(dry["resumeCommand"], f"claude --model opus --resume {LIVE_ID}")


class ActProc(ProcCase):
    def act(self, ident):
        return vpsmon.act_proc(self.paths, ident, True, time.time(), EN)

    def refusal(self, ident):
        with self.assertRaises(vpsmon.Fail) as e:
            self.act(ident)
        return e.exception.key

    def test_dry_run_ends_the_whole_tree(self):
        dry = self.act(self.node)
        self.assertEqual((dry["freedBytes"], dry["dryRun"]), (670 * MB, True))
        self.assertEqual(dry["message"], "Would end node (3 processes)")
        self.assertEqual([i["label"] for i in dry["items"]][0], "node 700")
        self.assertFalse(Path(self.paths.audit_log).exists())

    def test_refuses_protected_processes_reused_pids_and_bad_ids(self):
        self.assertEqual(self.refusal("proc:600:60000"), "err.not-killable")  # tmux holds a worker
        self.assertEqual(self.refusal(self.worker.replace("worker", "proc")), "err.not-killable")
        self.assertEqual(self.refusal("proc:501:50100"), "err.not-killable")  # an ancestor of vpsmon
        self.assertEqual(self.refusal("proc:1:100"), "err.not-killable")
        self.assertEqual(self.refusal("proc:800:80000"), "err.not-killable")  # no exe
        self.assertEqual(self.refusal("proc:700:1"), "err.proc-gone")  # same pid, another process
        self.assertEqual(self.refusal("proc:99999:1"), "err.proc-gone")
        self.assertEqual(self.refusal("proc:700"), "err.proc-id")


def load_checker():
    spec = importlib.util.spec_from_file_location("check_contract", HERE / "check_contract.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class Contract(ProcCase):
    """`status` on the fake host, end to end, against check_contract.py."""

    def status(self, tr=EN):
        now = time.time()
        actions = [
            vpsmon.ACTIONS["tmp-stale"].summary([vpsmon.Item("/tmp/build-cache-3f2a", 2_900_000_000)]),
            vpsmon.ACTIONS["big-logs"].summary([
                vpsmon.Item("/home/deploy/code/api/server.log", 300 * MB),
                vpsmon.Item("/var/log/nginx/access.log", 250 * MB),
            ]),
            vpsmon.ACTIONS["docker-images"].summary([vpsmon.Item("sha256:" + "c" * 64, 10**9, "api:old (cccccccccccc)")]),
        ]
        lines = DU_SAMPLE.read_text().splitlines()
        disk_map = vpsmon.build_map(vpsmon.parse_du("\n".join(lines[1:])), int(lines[0].split()[-1]), {"/swapfile": 4 * GB})
        os.makedirs(self.paths.state)
        vpsmon.write_scan(self.paths, now - HOUR, actions, disk_map)
        rows = [{"at": now - (12 - i) * HOUR, "diskUsedBytes": 10**11 + i * 10**8, "memAvailableBytes": 9 * 10**9,
                 "swapUsedBytes": 0, "busy": 1, "idle": 2} for i in range(12)]
        Path(self.paths.file("history.jsonl")).write_text("".join(json.dumps(r) + "\n" for r in rows))
        return vpsmon.cmd_status(self.paths, now, tr)

    def check(self, data, via_file=True):
        with tempfile.NamedTemporaryFile("w", suffix=".json") as f:
            json.dump(data, f)
            f.flush()
            args, stdin = ([f.name], None) if via_file else ([], json.dumps(data))
            return subprocess.run([sys.executable, str(HERE / "check_contract.py"), *args], input=stdin,
                                  capture_output=True, text=True)

    def test_status_of_a_host_meets_the_contract_in_both_languages(self):
        for tr in (EN, ES):
            data = self.status(tr)
            result = self.check(data)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertTrue(result.stdout.startswith("ok: 1 workers, 8 mem groups"), result.stdout)
            self.assertEqual(data["scan"]["actions"][0]["title"], tr("action.tmp-stale.title"))
            temp = next(g for g in data["scan"]["map"]["groups"] if g["id"] == "temp")
            self.assertEqual((temp["title"], temp["actions"]), (tr("map.temp.title"), ["tmp-stale"]))
            shutil.rmtree(self.paths.state)
        self.assertEqual(self.check(data, via_file=False).returncode, 0)

    def test_drift_is_caught(self):
        data = self.status()
        data["workers"][0]["memoryBytes"] = data["workers"][0].pop("memBytes")
        data["disk"]["usedBytes"] = 1.5
        data["memory"]["totalBytes"] = None
        data["memory"]["groups"][0]["processes"][0]["id"] = "pid:12"
        data["scan"]["actions"][0]["id"] = "retired-tmp"
        data["workers"][0]["state"] = "sleeping"
        result = self.check(data)
        self.assertEqual(result.returncode, 1)
        for path in ("workers[].memBytes", "workers[].memoryBytes", "disk.usedBytes", "memory.totalBytes",
                     "memory.groups[].processes[].id", "scan.actions[].id", "workers[].state"):
            self.assertIn(path, result.stdout)

    def test_a_map_that_does_not_add_up_is_caught(self):
        data = self.status()
        groups = data["scan"]["map"]["groups"]
        groups[0]["bytes"] += 1
        groups[1]["freeableBytes"] = groups[1]["bytes"] + 1
        groups[2]["actions"].append("journal")
        groups.insert(0, groups.pop())
        result = self.check(data)
        self.assertEqual(result.returncode, 1)
        for message in ("groups add up to", "freeableBytes over bytes", "names unpublished action journal", "rest is not last"):
            self.assertIn(message, result.stdout)

    def test_nullable_fields(self):
        data = self.status()
        data["disk"]["growthBytesPerHour"] = None
        data["disk"]["fullInHours"] = None
        data["scan"] = {"at": None, "running": False, "actions": [], "map": {"usedBytes": 0, "groups": []}}
        result = self.check(data)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_the_checker_lists_exactly_vpsmons_ids(self):
        checker = load_checker()
        self.assertEqual(checker.ACTION_IDS, {a.id for a in vpsmon.REGISTRY})
        self.assertEqual(checker.MAP_IDS, {g.id for g in vpsmon.MAP_GROUPS})

    @unittest.skipUnless(json.loads(FIXTURE.read_text()).get("schema") == 2, "the app's fixture is not schema 2 yet")
    def test_the_apps_fixture_meets_the_contract(self):
        result = self.check(json.loads(FIXTURE.read_text()))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


@unittest.skipUnless(sys.platform == "linux" and hasattr(os, "pidfd_open"), "pidfds are Linux only")
class EndTreeOnLinux(unittest.TestCase):
    def test_act_proc_ends_a_real_process_and_its_child(self):
        parent = subprocess.Popen(["sh", "-c", "sleep 300 & wait"])
        for _ in range(50):
            procs = vpsmon.read_procs("/proc")
            kids = [p for p in procs.values() if p.ppid == parent.pid]
            if kids:
                break
            time.sleep(0.05)
        child = kids[0]
        with tempfile.TemporaryDirectory() as tmp:
            paths = vpsmon.Paths(state=tmp, audit_log=os.path.join(tmp, "vpsmon.log"))
            ident = f"proc:{parent.pid}:{procs[parent.pid].start}"
            done = vpsmon.act_proc(paths, ident, False, time.time(), EN)
            self.assertEqual(done["message"], "Ended sh (2 processes)")
        parent.wait(timeout=10)
        time.sleep(0.2)
        again = vpsmon.read_proc("/proc", child.pid)
        self.assertTrue(again is None or again.start != child.start or again.comm == "sleep" and again.mem is None)


if __name__ == "__main__":
    unittest.main()
