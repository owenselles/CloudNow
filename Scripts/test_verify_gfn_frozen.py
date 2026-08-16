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

from verify_gfn_frozen import _file_manifest_hash, verify  # noqa: E402


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

        _, failures = self._verify()

        self.assertEqual(failures, [])

    def test_rejects_manifest_hash_not_anchored_to_frozen_digest(self) -> None:
        changed = b"changed\n"
        self.source_path.write_bytes(changed)
        self._write_manifest(hashlib.sha256(changed).hexdigest())

        _, failures = self._verify(expected_hash=self.baseline_hash)

        self.assertEqual(len(failures), 1)
        self.assertIn("does not match established hash", failures[0])

    def test_rejects_worktree_change_after_baseline_anchor_check(self) -> None:
        self._write_manifest(self.baseline_hash)
        self.source_path.write_text("changed\n", encoding="utf-8")

        _, failures = self._verify()

        self.assertEqual(len(failures), 1)
        self.assertIn("worktree hash", failures[0])

    def test_rejects_path_escape(self) -> None:
        payload = {
            "baselineCommit": self.baseline_commit,
            "files": {"../GFN.swift": self.baseline_hash},
        }
        self.manifest_path.write_text(json.dumps(payload), encoding="utf-8")

        _, failures = verify(
            self.repository_root,
            self.manifest_path,
            expected_manifest_hash=_file_manifest_hash(payload["files"]),
        )

        self.assertEqual(
            failures,
            ["../GFN.swift: invalid repository-relative path"],
        )

    def test_does_not_require_baseline_commit_to_exist(self) -> None:
        self._write_manifest(self.baseline_hash, baseline_commit="f" * 40)

        _, failures = self._verify()

        self.assertEqual(failures, [])

    def _git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.repository_root), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout

    def _verify(self, expected_hash: str | None = None) -> tuple[str, list[str]]:
        payload = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        manifest_hash = _file_manifest_hash(payload["files"])
        if expected_hash is not None:
            manifest_hash = _file_manifest_hash(
                {"CloudNow/GFN.swift": expected_hash}
            )
        return verify(
            self.repository_root,
            self.manifest_path,
            expected_manifest_hash=manifest_hash,
        )

    def _write_manifest(
        self,
        expected_hash: str,
        baseline_commit: str | None = None,
    ) -> None:
        payload = {
            "baselineCommit": baseline_commit or self.baseline_commit,
            "files": {"CloudNow/GFN.swift": expected_hash},
        }
        self.manifest_path.write_text(json.dumps(payload), encoding="utf-8")


if __name__ == "__main__":
    unittest.main()
