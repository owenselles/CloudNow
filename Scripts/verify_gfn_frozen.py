#!/usr/bin/env python3

"""Fail when Xbox quality work changes the frozen GFN production baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import subprocess
import sys
from collections.abc import Mapping
from typing import Any


DEFAULT_MANIFEST = pathlib.Path("Scripts/gfn-frozen-sources.json")
LOWERCASE_HEX_DIGITS = frozenset("0123456789abcdef")


class ManifestError(ValueError):
    """Raised when the frozen-source manifest is invalid."""


def _is_lowercase_hex(value: object, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in LOWERCASE_HEX_DIGITS for character in value)
    )


def _load_manifest(path: pathlib.Path) -> tuple[str, Mapping[str, str]]:
    try:
        payload: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read {path}: {error}") from error

    if not isinstance(payload, dict):
        raise ManifestError("manifest root must be an object")
    baseline_commit = payload.get("baselineCommit")
    files = payload.get("files")
    if not _is_lowercase_hex(baseline_commit, 40):
        raise ManifestError(
            "baselineCommit must be a full lowercase Git commit hash"
        )
    if not isinstance(files, dict) or not files:
        raise ManifestError("files must be a non-empty object")
    if not all(
        isinstance(relative_path, str)
        and _is_lowercase_hex(expected_hash, 64)
        for relative_path, expected_hash in files.items()
    ):
        raise ManifestError(
            "each file entry must map a path to a lowercase SHA-256 hash"
        )
    return baseline_commit, files


def _baseline_file_hash(
    repository_root: pathlib.Path,
    baseline_commit: str,
    relative_path: str,
) -> tuple[str | None, str | None]:
    result = subprocess.run(
        [
            "git",
            "-C",
            str(repository_root),
            "show",
            f"{baseline_commit}:{relative_path}",
        ],
        check=False,
        capture_output=True,
    )
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        return None, detail or "git show failed"
    return hashlib.sha256(result.stdout).hexdigest(), None


def verify(
    repository_root: pathlib.Path,
    manifest_path: pathlib.Path,
) -> tuple[str, list[str]]:
    baseline_commit, files = _load_manifest(manifest_path)
    resolved_root = repository_root.resolve()
    failures: list[str] = []

    for relative_path, expected_hash in sorted(files.items()):
        manifest_path = pathlib.PurePosixPath(relative_path)
        if (
            manifest_path.is_absolute()
            or ".." in manifest_path.parts
            or "\\" in relative_path
            or not manifest_path.parts
        ):
            failures.append(f"{relative_path}: invalid repository-relative path")
            continue

        candidate = (resolved_root / relative_path).resolve()
        if resolved_root not in candidate.parents:
            failures.append(f"{relative_path}: path escapes repository root")
            continue

        baseline_hash, baseline_error = _baseline_file_hash(
            resolved_root,
            baseline_commit,
            relative_path,
        )
        if baseline_hash is None:
            failures.append(
                f"{relative_path}: cannot read established baseline "
                f"{baseline_commit} ({baseline_error})"
            )
            continue
        if baseline_hash != expected_hash:
            failures.append(
                f"{relative_path}: manifest hash {expected_hash} does not match "
                f"established baseline hash {baseline_hash}"
            )
            continue

        try:
            actual_hash = hashlib.sha256(candidate.read_bytes()).hexdigest()
        except OSError as error:
            failures.append(f"{relative_path}: cannot read file ({error})")
            continue
        if actual_hash != expected_hash:
            failures.append(
                f"{relative_path}: established baseline hash {expected_hash}, "
                f"worktree hash {actual_hash}"
            )

    return baseline_commit, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--repository-root",
        type=pathlib.Path,
        default=pathlib.Path(__file__).resolve().parent.parent,
    )
    parser.add_argument("--manifest", type=pathlib.Path)
    arguments = parser.parse_args()

    repository_root = arguments.repository_root.resolve()
    manifest_path = (
        arguments.manifest.resolve()
        if arguments.manifest is not None
        else repository_root / DEFAULT_MANIFEST
    )
    try:
        baseline_commit, failures = verify(repository_root, manifest_path)
    except ManifestError as error:
        print(f"GFN frozen-source guard failed: {error}", file=sys.stderr)
        return 2

    if failures:
        print(
            "GFN frozen-source guard failed. Xbox quality work must not change "
            "the established GFN production baseline.",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        print(
            f"Established pre-Beta branch baseline: {baseline_commit}",
            file=sys.stderr,
        )
        return 1

    print(
        f"GFN frozen-source guard passed: {len(_load_manifest(manifest_path)[1])} "
        f"files match established pre-Beta branch baseline "
        f"{baseline_commit}."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
