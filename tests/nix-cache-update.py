"""Exercise the updater with real Git history and isolated external commands."""
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1)).resolve()


def git(directory, *args):
    return subprocess.check_output(
        ["git", "-C", str(directory), *args], stderr=subprocess.DEVNULL, text=True
    ).strip()


MOCK = r'''
import json, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
stage = "publish" if name == "sudo" else "status" if name == "curl" else "update" if args[:2] == ["flake", "update"] else "build" if args[0] == "build" else "verify"
commit = subprocess.check_output(["git", "rev-parse", "HEAD"], text=True).strip()
log = pathlib.Path(os.environ["EVENT_LOG"])
events = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
if stage == "status":
    payload = json.loads(args[args.index("--data") + 1])
    assert payload["state"] == "success"
    assert payload["target_url"] == os.environ["CACHE_UPDATE_RUN_URL"]
    assert any(arg.endswith("/statuses/" + commit) for arg in args)
    assert "Authorization: token " + os.environ["CACHE_UPDATE_TOKEN"] in args
    remote = subprocess.check_output(["git", "--git-dir", os.environ["TEST_REMOTE"], "rev-parse", "main"], text=True).strip()
    assert remote == commit
with log.open("a") as handle:
    handle.write(json.dumps({"stage": stage, "commit": commit}) + "\n")
if os.environ.get("FAIL_STAGE") == stage:
    sys.exit(1)
if stage == "update" and not os.environ.get("NO_UPDATE"):
    with open("flake.lock", "a") as handle:
        handle.write("updated\n")
if stage == "build":
    result = pathlib.Path("result")
    result.unlink(missing_ok=True)
    result.symlink_to(os.environ["TEST_OUTPUT"])
if stage == "verify" and os.environ.get("CONFLICT"):
    previous = sum(event["stage"] == "verify" for event in events)
    if os.environ["CONFLICT"] == "always" or previous == 0:
        other = os.environ["OTHER_CLONE"]
        def git(*args):
            subprocess.run(["git", "-C", other, *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git("fetch", "origin", "main")
        git("reset", "--hard", "FETCH_HEAD")
        pathlib.Path(other, "setting").write_text(str(previous + 1))
        git("add", "setting")
        git("commit", "-m", "Concurrent setting change")
        git("push", "origin", "HEAD:main")
'''


class UpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.remote = self.root / "remote.git"
        self.work = self.root / "work"
        self.other = self.root / "other"
        subprocess.run(["git", "init", "--bare", "--initial-branch=main", str(self.remote)], check=True, stdout=subprocess.DEVNULL)
        subprocess.run(["git", "clone", str(self.remote), str(self.work)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git(self.work, "config", "user.name", "Test")
        git(self.work, "config", "user.email", "test@example.invalid")
        (self.work / "flake.lock").write_text("initial\n")
        key = self.work / "hosts/laptop/nix-cache.pub"
        key.parent.mkdir(parents=True)
        key.write_text("test-public-key\n")
        git(self.work, "add", ".")
        git(self.work, "commit", "-m", "Initial configuration")
        git(self.work, "push", "origin", "main")
        self.initial = git(self.work, "rev-parse", "HEAD")
        subprocess.run(["git", "clone", str(self.remote), str(self.other)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        git(self.other, "config", "user.name", "Other")
        git(self.other, "config", "user.email", "other@example.invalid")
        tools = self.root / "tools"
        tools.mkdir()
        for name in ("nix", "sudo", "curl"):
            executable = tools / name
            executable.write_text("#!" + sys.executable + "\n" + MOCK)
            executable.chmod(0o755)
        output = self.root / "system-output"
        output.write_text("system\n")
        self.env = os.environ | {
            "PATH": str(tools) + os.pathsep + os.environ["PATH"],
            "EVENT_LOG": str(self.root / "events"),
            "TEST_REMOTE": str(self.remote),
            "OTHER_CLONE": str(self.other),
            "TEST_OUTPUT": str(output),
            "CACHE_UPDATE_TOKEN": "dummy-token-only",
            "CACHE_UPDATE_RUN_URL": "https://example.invalid/actions/runs/1",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null",
        }

    def run_update(self, **extra):
        result = subprocess.run([shutil.which("bash"), str(SCRIPT)], cwd=self.work, env=self.env | extra, capture_output=True, text=True)
        self.assertNotIn(self.env["CACHE_UPDATE_TOKEN"], result.stdout + result.stderr)
        return result

    def events(self):
        path = Path(self.env["EVENT_LOG"])
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def head(self):
        return git(self.remote, "rev-parse", "main")

    def test_success_only_pushes_after_verification(self):
        result = self.run_update()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual([event["stage"] for event in self.events()], ["update", "build", "publish", "verify", "status"])
        self.assertNotEqual(self.head(), self.initial)
        self.assertIn("[skip ci]", git(self.remote, "log", "-1", "--format=%s", "main"))
        self.assertEqual(git(self.remote, "diff-tree", "--no-commit-id", "--name-only", "-r", "main"), "flake.lock")

    def test_failure_never_pushes_an_unverified_update(self):
        for stage in ("update", "build", "publish", "verify"):
            with self.subTest(stage=stage):
                git(self.work, "reset", "--hard", self.initial)
                Path(self.env["EVENT_LOG"]).unlink(missing_ok=True)
                self.assertNotEqual(self.run_update(FAIL_STAGE=stage).returncode, 0)
                self.assertEqual(self.head(), self.initial)
                self.assertEqual(self.events()[-1]["stage"], stage)

    def test_no_change_verifies_without_creating_a_commit(self):
        result = self.run_update(NO_UPDATE="1")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.head(), self.initial)
        self.assertEqual(self.events()[-1]["stage"], "status")

    def test_conflict_rebuilds_from_new_main(self):
        result = self.run_update(CONFLICT="once")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(event["stage"] == "build" for event in self.events()), 2)
        self.assertEqual(git(self.remote, "show", "main:setting"), "1")
        self.assertEqual(self.events()[-1]["commit"], self.head())

    def test_repeated_conflicts_stop_after_three_attempts(self):
        self.assertNotEqual(self.run_update(CONFLICT="always").returncode, 0)
        self.assertEqual(sum(event["stage"] == "build" for event in self.events()), 3)
        self.assertEqual(git(self.remote, "show", "main:flake.lock"), "initial")
        self.assertEqual(git(self.remote, "show", "main:setting"), "3")

    def test_push_failure_does_not_force_or_retry_without_a_conflict(self):
        hook = self.remote / "hooks/pre-receive"
        hook.write_text("#!" + shutil.which("bash") + "\nexit 1\n")
        hook.chmod(0o755)
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual(self.head(), self.initial)
        self.assertEqual(sum(event["stage"] == "build" for event in self.events()), 1)

    def test_status_failure_is_reported_after_a_verified_push(self):
        self.assertNotEqual(self.run_update(FAIL_STAGE="status").returncode, 0)
        self.assertNotEqual(self.head(), self.initial)
        self.assertEqual(self.events()[-1]["stage"], "status")

    def test_dirty_input_is_not_discarded(self):
        (self.work / "flake.lock").write_text("local-change\n")
        self.assertNotEqual(self.run_update().returncode, 0)
        self.assertEqual((self.work / "flake.lock").read_text(), "local-change\n")
        self.assertFalse(self.events())


unittest.main()
