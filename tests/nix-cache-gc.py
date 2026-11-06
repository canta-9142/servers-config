"""Exercise retention using an isolated file cache, without a local Nix store."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

SCRIPT = Path(sys.argv.pop(1)).resolve()
spec = importlib.util.spec_from_file_location("cache_gc", SCRIPT)
gc = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gc)
DAY = 86400
NOW = 100 * DAY


class RetentionTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.cache = Path(temporary.name) / "cache"
        (self.cache / "nar").mkdir(parents=True)
        self.state = Path(temporary.name) / "publications.json"
        gc.save_state(self.state, {"initialized": NOW - 30 * DAY, "publications": []})

    def artifact(self, letter, references=(), nar=None):
        name = letter * 32 + "-artifact"
        url = "nar/" + (nar or letter) + ".nar.zst"
        reference_line = ("References: " + " ".join(path[11:] for path in references)).rstrip()
        (self.cache / url).write_text("payload")
        (self.cache / (letter * 32 + ".narinfo")).write_text(
            f"StorePath: /nix/store/{name}\nURL: {url}\n{reference_line}\n"
        )
        return "/nix/store/" + name

    def record(self, roots, when):
        gc.record(self.cache, self.state, roots, when)

    def collect(self, dry_run=False):
        with contextlib.redirect_stdout(io.StringIO()) as output:
            gc.collect(self.cache, self.state, NOW, dry_run)
        return output.getvalue()

    def snapshot(self):
        return {str(path): path.read_bytes() for path in self.state.parent.rglob("*") if path.is_file()}

    def test_retention_keeps_recent_closures_and_shared_dependencies(self):
        dependency = self.artifact("a")
        old = self.artifact("b", [dependency])
        recent = self.artifact("c", [dependency])
        latest = self.artifact("d")
        self.record([old], NOW - 15 * DAY)
        self.record([recent], NOW - 14 * DAY)
        self.record([latest], NOW - DAY)
        (self.cache / "nar/orphan.nar.zst").write_text("failed copy")
        # Age of payloads is irrelevant: recent closures may use old dependencies.
        self.collect()
        self.assertEqual({path.stem for path in self.cache.glob("*.narinfo")}, {letter * 32 for letter in "acd"})
        self.assertEqual({path.name for path in (self.cache / "nar").iterdir()}, {"a.nar.zst", "c.nar.zst", "d.nar.zst"})
        self.assertEqual(len(json.loads(self.state.read_text())["publications"]), 2)
        self.collect()  # Safe to repeat after old metadata has already been deleted.

    def test_latest_publication_is_retained_indefinitely_with_all_roots(self):
        old = self.artifact("a")
        latest = [self.artifact("b"), self.artifact("c")]
        self.record([old], NOW - 25 * DAY)
        self.record(latest, NOW - 20 * DAY)
        self.collect()
        self.assertEqual(len(list(self.cache.glob("*.narinfo"))), 2)
        gc.closure(self.cache, latest)

    def test_shared_nar_survives_removal_of_other_metadata(self):
        old = self.artifact("a", nar="shared")
        latest = self.artifact("b", nar="shared")
        self.record([old], NOW - 15 * DAY)
        self.record([latest], NOW)
        self.collect()
        self.assertTrue((self.cache / "nar/shared.nar.zst").exists())

    def test_initial_grace_period_protects_untracked_legacy_cache(self):
        legacy = self.artifact("a")
        self.state.unlink()
        self.collect()
        self.record([self.artifact("b")], NOW)
        with contextlib.redirect_stdout(io.StringIO()):
            gc.collect(self.cache, self.state, NOW + 13 * DAY)
        gc.closure(self.cache, [legacy])
        with contextlib.redirect_stdout(io.StringIO()):
            gc.collect(self.cache, self.state, NOW + 14 * DAY)
        self.assertFalse((self.cache / ("a" * 32 + ".narinfo")).exists())

    def test_no_successful_publications_never_deletes_legacy_cache(self):
        self.artifact("a")
        before = self.snapshot()
        self.collect()
        self.assertEqual(before, self.snapshot())

    def test_dry_run_leaves_files_and_records_unchanged(self):
        self.record([self.artifact("a")], NOW - 15 * DAY)
        self.record([self.artifact("b")], NOW)
        before = self.snapshot()
        self.assertIn("Would delete", self.collect(dry_run=True))
        self.assertEqual(before, self.snapshot())
        self.state.unlink()
        self.collect(dry_run=True)
        self.assertFalse(self.state.exists())

    def test_missing_retained_dependency_or_payload_aborts_before_deletion(self):
        dependency = self.artifact("a")
        self.record([self.artifact("b")], NOW - 15 * DAY)
        self.record([self.artifact("c", [dependency])], NOW)
        for path in (self.cache / ("a" * 32 + ".narinfo"), self.cache / "nar/c.nar.zst"):
            with self.subTest(path=path):
                contents = path.read_bytes()
                path.unlink()
                before = self.snapshot()
                with self.assertRaises((ValueError, FileNotFoundError)):
                    self.collect()
                self.assertEqual(before, self.snapshot())
                path.write_bytes(contents)

    def test_corrupt_metadata_and_state_abort_before_deletion(self):
        self.record([self.artifact("a")], NOW - 15 * DAY)
        self.record([self.artifact("b")], NOW)
        for path in (self.cache / ("a" * 32 + ".narinfo"), self.state):
            with self.subTest(path=path):
                contents = path.read_bytes()
                path.write_text("broken")
                before = self.snapshot()
                with self.assertRaises((ValueError, KeyError)):
                    self.collect()
                self.assertEqual(before, self.snapshot())
                path.write_bytes(contents)

    def test_unsafe_url_and_symlink_abort_without_removing_external_files(self):
        self.record([self.artifact("a")], NOW - 15 * DAY)
        latest = self.artifact("b")
        self.record([latest], NOW)
        info = self.cache / ("a" * 32 + ".narinfo")
        original = info.read_text()
        info.write_text(original.replace("nar/a.nar.zst", "../publications.json"))
        before = self.snapshot()
        with self.assertRaises(ValueError):
            self.collect()
        self.assertEqual(before, self.snapshot())
        info.write_text(original)
        nar = self.cache / "nar/b.nar.zst"
        nar.unlink()
        nar.symlink_to(self.state)
        before = self.snapshot()
        with self.assertRaises(ValueError):
            self.collect()
        self.assertEqual(before, self.snapshot())

    def test_failed_record_does_not_change_latest_success(self):
        self.record([self.artifact("a")], NOW)
        before = self.snapshot()
        with self.assertRaises(FileNotFoundError):
            self.record(["/nix/store/" + "b" * 32 + "-missing"], NOW)
        self.assertEqual(before, self.snapshot())

    def test_missing_references_field_aborts_before_deletion(self):
        self.record([self.artifact("a")], NOW - 15 * DAY)
        self.record([self.artifact("b")], NOW)
        info = self.cache / ("b" * 32 + ".narinfo")
        info.write_text(info.read_text().replace("References:\n", ""))
        before = self.snapshot()
        with self.assertRaises(KeyError):
            self.collect()
        self.assertEqual(before, self.snapshot())

    def test_nonfinite_timestamp_aborts_before_deletion(self):
        self.record([self.artifact("a")], NOW - 15 * DAY)
        self.record([self.artifact("b")], NOW)
        state = json.loads(self.state.read_text())
        state["publications"][0]["time"] = float("nan")
        self.state.write_text(json.dumps(state))
        before = self.snapshot()
        with self.assertRaises(ValueError):
            self.collect()
        self.assertEqual(before, self.snapshot())

    def test_invalid_cli_arguments_fail(self):
        for args in ([], ["gc", "--unknown"], ["record"]):
            result = subprocess.run([sys.executable, str(SCRIPT), *args], capture_output=True)
            self.assertNotEqual(result.returncode, 0)


if __name__ == "__main__":
    unittest.main()
