#!/usr/bin/env python3

"""Fail when Xbox quality work changes the frozen GFN production baseline."""

from __future__ import annotations

import argparse
import hashlib
import json
import pathlib
import sys
from collections.abc import Mapping
from typing import Any


DEFAULT_MANIFEST = pathlib.Path("Scripts/gfn-frozen-sources.json")
LOWERCASE_HEX_DIGITS = frozenset("0123456789abcdef")
ESTABLISHED_FILE_MANIFEST_SHA256 = (
    "302ebee16c5e61901ea0f5deac49fe3ab85f5a18c1cab67e96344ca4242d7af2"
)


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


def _file_manifest_hash(files: Mapping[str, str]) -> str:
    encoded = json.dumps(
        files,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def verify(
    repository_root: pathlib.Path,
    manifest_path: pathlib.Path,
    expected_manifest_hash: str = ESTABLISHED_FILE_MANIFEST_SHA256,
) -> tuple[str, list[str]]:
    baseline_commit, files = _load_manifest(manifest_path)
    resolved_root = repository_root.resolve()
    failures: list[str] = []

    actual_manifest_hash = _file_manifest_hash(files)
    if actual_manifest_hash != expected_manifest_hash:
        failures.append(
            "frozen file manifest hash "
            f"{actual_manifest_hash} does not match established hash "
            f"{expected_manifest_hash}"
        )
        return baseline_commit, failures

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

        try:
            actual_hash = hashlib.sha256(candidate.read_bytes()).hexdigest()
        except OSError as error:
            failures.append(f"{relative_path}: cannot read file ({error})")
            continue
        if actual_hash != expected_hash:
            failures.append(
                f"{relative_path}: frozen baseline hash {expected_hash}, "
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
