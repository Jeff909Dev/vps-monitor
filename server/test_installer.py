"""The generated vpsmon-install.sh, run for real against a temp prefix. id, sudo, chown, visudo and systemctl are
fakes on PATH, so the installer believes it is root (or not) without being either."""

import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parent
VERSION = (REPO / "VERSION").read_text().strip()

FAKES = {
    # Known users: deploy and ci. FAKE_UID is who runs the installer; FAKE_USER, the name id -un gives.
    "id": """
case "$1" in
  -u) if [ $# -ge 2 ]; then case $2 in deploy|ci|root) echo 1000 ;; *) exit 1 ;; esac; else echo "${FAKE_UID:-0}"; fi ;;
  -un) echo "${FAKE_USER:-deploy}" ;;
esac
""",
    "sudo": """
[ "$1" = -n ] && shift
if [ "${FAKE_SUDO:-ok}" = password ]; then echo "sudo: a password is required" >&2; exit 1; fi
FAKE_UID=0 exec "$@"
""",
    "chown": "exit 0\n",
    "visudo": """
[ "${FAKE_VISUDO:-ok}" = ok ] || exit 1
grep -qvE '^[a-z]+ ALL=\\(root\\) NOPASSWD: /usr/local/bin/vpsmon$' "$2" && exit 1
exit 0
""",
    # Keeps the timer's state in FAKE_STATE and logs every call.
    "systemctl": """
echo "$*" >>"$FAKE_STATE/calls"
case "$1" in
  is-enabled) [ -f "$FAKE_STATE/enabled" ] ;;
  is-active) [ -f "$FAKE_STATE/active" ] ;;
  enable) touch "$FAKE_STATE/enabled" "$FAKE_STATE/active" ;;
  start) touch "$FAKE_STATE/active" ;;
esac
""",
}


TOOLS = ("sh", "cat", "mktemp", "cmp", "mkdir", "dirname", "cp", "rm", "chmod", "mv", "sed", "tr", "grep", "true",
         "touch", "tail")


class Installer(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.build = tempfile.TemporaryDirectory()
        cls.installer = Path(cls.build.name) / "vpsmon-install.sh"
        subprocess.run([str(REPO / "scripts" / "make-installer.sh"), str(cls.installer)], check=True)

    @classmethod
    def tearDownClass(cls):
        cls.build.cleanup()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        root = Path(self.tmp.name)
        self.prefix, self.fakes, self.state = root / "root", root / "bin", root / "systemd-state"
        for d in (self.prefix, self.fakes, self.state):
            d.mkdir()
        for name, script in FAKES.items():
            (self.fakes / name).write_text("#!/bin/sh\n" + script)
            (self.fakes / name).chmod(0o755)
        os.symlink(sys.executable, self.fakes / "python3")
        # PATH is this folder alone: the real sudo must never be in reach.
        for tool in TOOLS:
            os.symlink(shutil.which(tool, path="/usr/bin:/bin"), self.fakes / tool)

    def tearDown(self):
        self.tmp.cleanup()

    def install(self, *args, stdin=False, without=(), **env):
        for name in without:
            (self.fakes / name).unlink()
        env = {"PATH": str(self.fakes), "VPSMON_PREFIX": str(self.prefix), "FAKE_STATE": str(self.state),
               "TMPDIR": self.tmp.name, **env}
        if stdin:
            cmd, text = ["sh", "-s", "--", *args], self.installer.read_text()
        else:
            cmd, text = ["sh", str(self.installer), *args], None
        r = subprocess.run(cmd, input=text, capture_output=True, text=True, env=env)
        out = json.loads(r.stdout.strip().splitlines()[-1]) if r.stdout.strip() else None
        return r.returncode, out, r.stderr

    def file(self, rel):
        return self.prefix / rel

    def mode(self, rel):
        return stat.S_IMODE(self.file(rel).stat().st_mode)

    def with_systemd(self):
        (self.prefix / "run" / "systemd" / "system").mkdir(parents=True)

    def calls(self):
        path = self.state / "calls"
        return path.read_text().splitlines() if path.exists() else []

    def test_the_generated_file_is_valid_sh(self):
        r = subprocess.run(["sh", "-n", str(self.installer)], capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stderr)

    def test_root_installs_everything_and_a_rerun_changes_nothing(self):
        self.with_systemd()
        code, out, err = self.install("--user", "deploy", "--watch", "nginx,docker")
        self.assertEqual(code, 0, err)
        self.assertEqual((out["ok"], out["version"]), (True, VERSION))
        units = "etc/systemd/system"
        self.assertEqual(
            [Path(c).name if c.startswith("/") else c for c in out["changed"]],
            ["vpsmon", "vpsmon", "config.json", "vpsmon", "vpsmon-sample.service", "vpsmon-sample.timer",
             "daemon-reload", "timer-enabled"],
        )
        self.assertEqual(self.file("usr/local/bin/vpsmon").read_text(), (HERE / "vpsmon").read_text())
        self.assertEqual(self.mode("usr/local/bin/vpsmon"), 0o755)
        self.assertEqual(self.file(f"{units}/vpsmon-sample.timer").read_text(),
                         (HERE / "systemd" / "vpsmon-sample.timer").read_text())
        self.assertTrue(self.file("var/lib/vpsmon").is_dir())
        self.assertEqual(json.loads(self.file("etc/vpsmon/config.json").read_text()), {"services": ["nginx", "docker"]})
        self.assertEqual(self.file("etc/sudoers.d/vpsmon").read_text(),
                         "deploy ALL=(root) NOPASSWD: /usr/local/bin/vpsmon\n")
        self.assertEqual(self.mode("etc/sudoers.d/vpsmon"), 0o440)
        self.assertIn("enable --now --quiet vpsmon-sample.timer", self.calls())

        code, again, err = self.install("--user", "deploy", "--watch", "postgresql")
        self.assertEqual((code, again["changed"]), (0, []), err)
        # The config is written only when it is missing.
        self.assertEqual(json.loads(self.file("etc/vpsmon/config.json").read_text()), {"services": ["nginx", "docker"]})

        (self.state / "active").unlink()
        code, out, err = self.install()
        self.assertEqual(out["changed"], ["timer-started"])

    def test_without_systemd_it_installs_the_script_and_says_the_timer_is_skipped(self):
        code, out, err = self.install()
        self.assertEqual(code, 0, err)
        self.assertEqual(out["changed"][-1], "no-systemd-timer-skipped")
        self.assertTrue(self.file("usr/local/bin/vpsmon").exists())
        self.assertFalse(self.file("etc/systemd/system").exists())
        self.assertEqual(json.loads(self.file("etc/vpsmon/config.json").read_text()), {"services": []})
        self.assertFalse(self.file("etc/sudoers.d/vpsmon").exists())
        self.assertEqual(self.install()[1]["changed"], ["no-systemd-timer-skipped"])

    def test_read_from_stdin_as_the_app_sends_it(self):
        code, out, err = self.install("--user", "deploy", stdin=True)
        self.assertEqual((code, out["ok"]), (0, True), err)
        self.assertTrue(self.file("etc/sudoers.d/vpsmon").exists())

    def test_another_user_goes_through_sudo_and_gets_the_rule(self):
        code, out, err = self.install(stdin=True, FAKE_UID="1000", FAKE_USER="ci")
        self.assertEqual((code, out["ok"]), (0, True), err)
        self.assertEqual(self.file("etc/sudoers.d/vpsmon").read_text(), "ci ALL=(root) NOPASSWD: /usr/local/bin/vpsmon\n")
        # A second user is added, not swapped in.
        self.install(FAKE_UID="1000", FAKE_USER="deploy")
        self.assertEqual(
            self.file("etc/sudoers.d/vpsmon").read_text().splitlines(),
            ["ci ALL=(root) NOPASSWD: /usr/local/bin/vpsmon", "deploy ALL=(root) NOPASSWD: /usr/local/bin/vpsmon"],
        )

    def test_sudo_that_wants_a_password_is_reported_and_nothing_changes(self):
        code, out, err = self.install(stdin=True, FAKE_UID="1000", FAKE_USER="deploy", FAKE_SUDO="password")
        self.assertEqual((code, out), (1, {"ok": False, "error": "sudo-password", "user": "deploy"}))
        self.assertEqual(list(self.prefix.iterdir()), [])

    def test_no_sudo_at_all_is_reported(self):
        code, out, _ = self.install(FAKE_UID="1000", without=("sudo",))
        self.assertEqual((code, out), (1, {"ok": False, "error": "sudo-missing", "user": "deploy"}))

    def test_a_sudoers_file_visudo_rejects_never_lands(self):
        code, out, _ = self.install("--user", "deploy", FAKE_VISUDO="fail")
        self.assertEqual((code, out), (1, {"ok": False, "error": "sudoers-invalid"}))
        self.assertEqual(list(self.file("etc/sudoers.d").iterdir()), [])

    def test_bad_input_changes_nothing(self):
        for args, error, want in ((["--watch", "nginx;reboot"], "bad-unit", 2), (["--user", "nobody-here"], "no-such-user", 1),
                                  (["--user", "-x"], "bad-user", 2), (["--frobnicate"], "usage", 2)):
            code, out, _ = self.install(*args)
            self.assertEqual((code, out), (want, {"ok": False, "error": error}), args)
        code, out, _ = self.install("--user", "deploy", without=("visudo",))
        self.assertEqual(out, {"ok": False, "error": "visudo-missing"})
        self.assertEqual(list(self.prefix.iterdir()), [])

    def test_uninstall_removes_what_install_added(self):
        self.install("--user", "deploy")
        log = self.file("var/log/vpsmon.log")
        log.parent.mkdir(parents=True)
        log.write_text("{}\n")
        code, out, err = self.install("--uninstall")
        self.assertEqual((code, out["ok"]), (0, True), err)
        self.assertFalse(self.file("usr/local/bin/vpsmon").exists())
        self.assertFalse(self.file("etc/sudoers.d/vpsmon").exists())
        self.assertFalse(self.file("etc/vpsmon").exists())
        self.assertFalse(self.file("var/lib/vpsmon").exists())
        self.assertTrue(log.exists())
        self.assertEqual(self.install("--uninstall")[1], {"ok": True, "removed": []})


if __name__ == "__main__":
    unittest.main()
