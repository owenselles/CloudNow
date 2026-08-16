#!/usr/bin/env python3

"""Regression tests for the established GFN source guard."""

from __future__ import annotations

import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))

from verify_gfn_frozen import verify  # noqa: E402


class FrozenGFNSourceGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository_root = pathlib.Path(self.temporary_directory.name)
        self.source_path = self.repository_root / "CloudNow/GFN.swift"
        self.source_path.parent.mkdir(parents=True)
        self.source_path.write_text("established\n", encoding="utf-8")
        self._git("init", "--quiet")
        self._git("config", "user.email", "guard@example.invalid")
        self._git("config", "user.name", "GFN Guard")
        self._git("add", "CloudNow/GFN.swift")
        self._git("commit", "--quiet", "-m", "baseline")
        self.baseline_commit = self._git("rev-parse", "HEAD").strip()
        self.baseline_hash = hashlib.sha256(b"established\n").hexdigest()
        self.manifest_path = self.repository_root / "manifest.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_passes_when_manifest_and_worktree_match_baseline(self) -> None:
        self._write_manifest(self.baseline_hash)

        _, failures = verify(self.repository_root, self.manifest_path)

        self.assertEqual(failures, [])

    def test_rejects_manifest_hash_not_anchored_to_baseline(self) -> None:
        changed = b"changed\n"
        self.source_path.write_bytes(changed)
        self._write_manifest(hashlib.sha256(changed).hexdigest())

        _, failures = verify(self.repository_root, self.manifest_path)

        self.assertEqual(len(failures), 1)
        self.assertIn("does not match established baseline hash", failures[0])

    def test_rejects_worktree_change_after_baseline_anchor_check(self) -> None:
        self._write_manifest(self.baseline_hash)
        self.source_path.write_text("changed\n", encoding="utf-8")

        _, failures = verify(self.repository_root, self.manifest_path)

        self.assertEqual(len(failures), 1)
        self.assertIn("worktree hash", failures[0])

    def test_rejects_path_escape(self) -> None:
        payload = {
            "baselineCommit": self.baseline_commit,
            "files": {"../GFN.swift": self.baseline_hash},
        }
        self.manifest_path.write_text(json.dumps(payload), encoding="utf-8")

        _, failures = verify(self.repository_root, self.manifest_path)

        self.assertEqual(
            failures,
            ["../GFN.swift: invalid repository-relative path"],
        )

    def _git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.repository_root), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout

    def _write_manifest(self, expected_hash: str) -> None:
        payload = {
            "baselineCommit": self.baseline_commit,
            "files": {"CloudNow/GFN.swift": expected_hash},
        }
        self.manifest_path.write_text(json.dumps(payload), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
