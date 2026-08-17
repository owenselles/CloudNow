#!/usr/bin/env python3

"""Regression tests for the frozen GFN source and reviewed-optimization guard."""

from __future__ import annotations

import copy
import hashlib
import json
import pathlib
import subprocess
import sys
import tempfile
import unittest


SCRIPT_DIRECTORY = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIRECTORY))

from verify_gfn_frozen import (  # noqa: E402
    ESTABLISHED_BASELINE_COMMIT,
    ESTABLISHED_BASELINE_DESCRIPTION,
    ESTABLISHED_FILE_MANIFEST_SHA256,
    ESTABLISHED_REVIEWED_OPTIMIZATIONS_SHA256,
    ManifestError,
    _file_manifest_hash,
    _load_manifest,
    _reviewed_optimization_manifest_hash,
    verify,
)


class FrozenGFNSourceGuardTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.repository_root = pathlib.Path(self.temporary_directory.name)
        self.source_paths = {
            "CloudNow/GFN.swift": self.repository_root / "CloudNow/GFN.swift",
            "CloudNow/Renderer.swift": (
                self.repository_root / "CloudNow/Renderer.swift"
            ),
        }
        self.source_paths["CloudNow/GFN.swift"].parent.mkdir(parents=True)
        self.baseline_contents = {
            "CloudNow/GFN.swift": b"established\n",
            "CloudNow/Renderer.swift": b"renderer-established\n",
        }
        self.approved_contents = {
            "CloudNow/GFN.swift": b"approved-optimization\n",
            "CloudNow/Renderer.swift": b"approved-renderer-optimization\n",
        }
        for relative_path, contents in self.baseline_contents.items():
            self.source_paths[relative_path].write_bytes(contents)

        self._git("init", "--quiet")
        self._git("config", "user.email", "guard@example.invalid")
        self._git("config", "user.name", "GFN Guard")
        self._git("add", "CloudNow/GFN.swift", "CloudNow/Renderer.swift")
        self._git("commit", "--quiet", "-m", "baseline")
        self.baseline_commit = self._git("rev-parse", "HEAD").strip()
        self.baseline_description = "Test frozen baseline"
        self.baseline_files = {
            relative_path: hashlib.sha256(contents).hexdigest()
            for relative_path, contents in self.baseline_contents.items()
        }
        self.approved_hashes = {
            relative_path: hashlib.sha256(contents).hexdigest()
            for relative_path, contents in self.approved_contents.items()
        }
        self.manifest_path = self.repository_root / "manifest.json"

    def tearDown(self) -> None:
        self.temporary_directory.cleanup()

    def test_passes_when_manifest_and_worktree_match_baseline(self) -> None:
        self._write_manifest()

        _, failures = self._verify()

        self.assertEqual(failures, [])

    def test_passes_multiple_reviewed_optimization_hashes(self) -> None:
        reviewed_optimizations = self._reviewed_optimizations()
        for relative_path, contents in self.approved_contents.items():
            self.source_paths[relative_path].write_bytes(contents)
        self._write_manifest(reviewed_optimizations=reviewed_optimizations)

        _, failures = self._verify()

        self.assertEqual(failures, [])
        payload = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        self.assertEqual(payload["files"], self.baseline_files)
        self.assertEqual(len(payload["reviewedOptimizations"]), 2)

    def test_repository_manifest_anchors_only_reviewed_files(self) -> None:
        manifest_path = SCRIPT_DIRECTORY / "gfn-frozen-sources.json"
        baseline_commit, baseline_description, files, reviewed = _load_manifest(
            manifest_path
        )

        self.assertEqual(baseline_commit, ESTABLISHED_BASELINE_COMMIT)
        self.assertEqual(
            baseline_description,
            ESTABLISHED_BASELINE_DESCRIPTION,
        )
        self.assertEqual(len(files), 52)
        self.assertEqual(
            _file_manifest_hash(files),
            ESTABLISHED_FILE_MANIFEST_SHA256,
        )
        self.assertEqual(
            set(reviewed),
            {
                "CloudNow/AppDataManager.swift",
                "CloudNow/MemoryLifecycleCoordinator.swift",
                "CloudNow/Streaming/GFNVideoDecoderH265.swift",
                "CloudNow/Video/VideoSurfaceView.swift",
            },
        )
        self.assertEqual(
            _reviewed_optimization_manifest_hash(reviewed),
            ESTABLISHED_REVIEWED_OPTIMIZATIONS_SHA256,
        )
        for relative_path, optimization in reviewed.items():
            self.assertEqual(
                optimization["baselineSHA256"],
                files[relative_path],
            )

    def test_rejects_original_source_after_optimization_is_approved(self) -> None:
        reviewed_optimizations = self._reviewed_optimizations()
        self._write_manifest(reviewed_optimizations=reviewed_optimizations)

        _, failures = self._verify()

        self.assertEqual(len(failures), 2)
        self.assertTrue(
            all("reviewed optimization hash" in failure for failure in failures)
        )

    def test_rejects_source_drift_after_approved_optimization(self) -> None:
        relative_path = "CloudNow/GFN.swift"
        reviewed_optimizations = {
            relative_path: self._reviewed_optimization(relative_path)
        }
        self._write_manifest(reviewed_optimizations=reviewed_optimizations)
        self.source_paths[relative_path].write_text("unreviewed\n", encoding="utf-8")

        _, failures = self._verify()

        self.assertEqual(len(failures), 1)
        self.assertIn("reviewed optimization hash", failures[0])
        self.assertIn("original frozen baseline hash", failures[0])

    def test_rejects_file_manifest_drift_even_when_source_matches_it(self) -> None:
        changed_contents = b"changed\n"
        relative_path = "CloudNow/GFN.swift"
        self.source_paths[relative_path].write_bytes(changed_contents)
        changed_files = dict(self.baseline_files)
        changed_files[relative_path] = hashlib.sha256(changed_contents).hexdigest()
        self._write_manifest(files=changed_files)

        _, failures = self._verify(expected_files=self.baseline_files)

        self.assertEqual(len(failures), 1)
        self.assertIn("frozen file manifest hash", failures[0])

    def test_rejects_reviewed_optimization_metadata_drift(self) -> None:
        reviewed_optimizations = self._reviewed_optimizations()
        for relative_path, contents in self.approved_contents.items():
            self.source_paths[relative_path].write_bytes(contents)
        self._write_manifest(reviewed_optimizations=reviewed_optimizations)
        changed_optimizations = copy.deepcopy(reviewed_optimizations)
        changed_optimizations["CloudNow/GFN.swift"]["reason"] = "Different reason"
        self._write_manifest(reviewed_optimizations=changed_optimizations)

        _, failures = self._verify(
            expected_reviewed_optimizations=reviewed_optimizations
        )

        self.assertEqual(len(failures), 1)
        self.assertIn("reviewed optimization manifest hash", failures[0])

    def test_rejects_baseline_origin_metadata_drift(self) -> None:
        self._write_manifest(
            baseline_commit="f" * 40,
            baseline_description="Changed baseline",
        )

        _, failures = self._verify()

        self.assertEqual(len(failures), 2)
        self.assertIn("baseline commit", failures[0])
        self.assertIn("baseline description", failures[1])

    def test_rejects_unexpected_manifest_key(self) -> None:
        payload = self._manifest_payload()
        payload["unreviewedPolicy"] = True
        self.manifest_path.write_text(json.dumps(payload), encoding="utf-8")

        with self.assertRaisesRegex(ManifestError, "unexpected keys"):
            self._verify()

    def test_rejects_malformed_reviewed_optimizations(self) -> None:
        relative_path = "CloudNow/GFN.swift"
        valid = self._reviewed_optimization(relative_path)
        malformed_cases = {
            "not an object": {relative_path: "invalid"},
            "missing required key": {
                relative_path: {
                    "baselineSHA256": valid["baselineSHA256"],
                    "approvedSHA256": valid["approvedSHA256"],
                }
            },
            "invalid baseline hash": {
                relative_path: {**valid, "baselineSHA256": "invalid"}
            },
            "invalid approved hash": {
                relative_path: {**valid, "approvedSHA256": "invalid"}
            },
            "unchanged approved hash": {
                relative_path: {
                    **valid,
                    "approvedSHA256": valid["baselineSHA256"],
                }
            },
            "empty reason": {relative_path: {**valid, "reason": ""}},
            "unknown frozen file": {
                "CloudNow/Unknown.swift": {
                    **valid,
                    "baselineSHA256": "a" * 64,
                }
            },
            "mismatched baseline hash": {
                relative_path: {**valid, "baselineSHA256": "a" * 64}
            },
        }

        for label, reviewed_optimizations in malformed_cases.items():
            with self.subTest(label=label):
                self._write_manifest(
                    reviewed_optimizations=reviewed_optimizations
                )
                with self.assertRaises(ManifestError):
                    self._verify()

    def test_rejects_path_escape(self) -> None:
        files = {"../GFN.swift": self.baseline_files["CloudNow/GFN.swift"]}
        self._write_manifest(files=files)

        _, failures = self._verify(expected_files=files)

        self.assertEqual(
            failures,
            ["../GFN.swift: invalid repository-relative path"],
        )

    def test_does_not_require_baseline_commit_to_exist_in_repository(self) -> None:
        nonexistent_commit = "f" * 40
        self._write_manifest(baseline_commit=nonexistent_commit)

        _, failures = self._verify(expected_baseline_commit=nonexistent_commit)

        self.assertEqual(failures, [])

    def _git(self, *arguments: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(self.repository_root), *arguments],
            check=True,
            capture_output=True,
            text=True,
        )
        return result.stdout

    def _verify(
        self,
        expected_files: dict[str, str] | None = None,
        expected_reviewed_optimizations: dict[str, object] | None = None,
        expected_baseline_commit: str | None = None,
        expected_baseline_description: str | None = None,
    ) -> tuple[str, list[str]]:
        payload = json.loads(self.manifest_path.read_text(encoding="utf-8"))
        reviewed_optimizations = (
            payload["reviewedOptimizations"]
            if expected_reviewed_optimizations is None
            else expected_reviewed_optimizations
        )
        return verify(
            self.repository_root,
            self.manifest_path,
            expected_manifest_hash=_file_manifest_hash(
                expected_files or payload["files"]
            ),
            expected_reviewed_optimizations_hash=(
                _reviewed_optimization_manifest_hash(reviewed_optimizations)
            ),
            expected_baseline_commit=(
                expected_baseline_commit or self.baseline_commit
            ),
            expected_baseline_description=(
                expected_baseline_description or self.baseline_description
            ),
        )

    def _manifest_payload(
        self,
        *,
        files: dict[str, str] | None = None,
        reviewed_optimizations: dict[str, object] | None = None,
        baseline_commit: str | None = None,
        baseline_description: str | None = None,
    ) -> dict[str, object]:
        return {
            "baselineCommit": baseline_commit or self.baseline_commit,
            "baselineDescription": (
                baseline_description or self.baseline_description
            ),
            "files": files or self.baseline_files,
            "reviewedOptimizations": reviewed_optimizations or {},
        }

    def _write_manifest(
        self,
        *,
        files: dict[str, str] | None = None,
        reviewed_optimizations: dict[str, object] | None = None,
        baseline_commit: str | None = None,
        baseline_description: str | None = None,
    ) -> None:
        payload = self._manifest_payload(
            files=files,
            reviewed_optimizations=reviewed_optimizations,
            baseline_commit=baseline_commit,
            baseline_description=baseline_description,
        )
        self.manifest_path.write_text(json.dumps(payload), encoding="utf-8")

    def _reviewed_optimization(self, relative_path: str) -> dict[str, str]:
        return {
            "baselineSHA256": self.baseline_files[relative_path],
            "approvedSHA256": self.approved_hashes[relative_path],
            "reason": f"Reviewed optimization for {relative_path}",
        }

    def _reviewed_optimizations(self) -> dict[str, dict[str, str]]:
        return {
            relative_path: self._reviewed_optimization(relative_path)
            for relative_path in self.source_paths
        }


if __name__ == "__main__":
    unittest.main()
