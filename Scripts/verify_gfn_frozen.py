#!/usr/bin/env python3

"""Reject GFN source drift outside the frozen baseline and reviewed optimizations."""

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
ESTABLISHED_REVIEWED_OPTIMIZATIONS_SHA256 = (
    "77fcbc2086a757df52f321f4e17c7c5f77d6de0d81068229743ac1e558673630"
)
ESTABLISHED_BASELINE_COMMIT = "c401cb8cc73bb7dab20232eab994b4958af8e3a2"
ESTABLISHED_BASELINE_DESCRIPTION = "Established pre-Beta branch baseline"
MANIFEST_KEYS = frozenset(
    {"baselineCommit", "baselineDescription", "files", "reviewedOptimizations"}
)
REVIEWED_OPTIMIZATION_KEYS = frozenset(
    {"baselineSHA256", "approvedSHA256", "reason"}
)


class ManifestError(ValueError):
    """Raised when the frozen-source manifest is invalid."""


def _is_lowercase_hex(value: object, length: int) -> bool:
    return (
        isinstance(value, str)
        and len(value) == length
        and all(character in LOWERCASE_HEX_DIGITS for character in value)
    )


def _load_manifest(
    path: pathlib.Path,
) -> tuple[str, str, Mapping[str, str], Mapping[str, Mapping[str, str]]]:
    try:
        payload: Any = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as error:
        raise ManifestError(f"cannot read {path}: {error}") from error

    if not isinstance(payload, dict):
        raise ManifestError("manifest root must be an object")
    if set(payload) != MANIFEST_KEYS:
        missing = sorted(MANIFEST_KEYS - set(payload))
        unexpected = sorted(set(payload) - MANIFEST_KEYS)
        details = []
        if missing:
            details.append(f"missing keys: {', '.join(missing)}")
        if unexpected:
            details.append(f"unexpected keys: {', '.join(unexpected)}")
        raise ManifestError(f"manifest keys are invalid ({'; '.join(details)})")

    baseline_commit = payload.get("baselineCommit")
    baseline_description = payload.get("baselineDescription")
    files = payload.get("files")
    reviewed_optimizations = payload.get("reviewedOptimizations")
    if not _is_lowercase_hex(baseline_commit, 40):
        raise ManifestError(
            "baselineCommit must be a full lowercase Git commit hash"
        )
    if (
        not isinstance(baseline_description, str)
        or not baseline_description
        or baseline_description != baseline_description.strip()
    ):
        raise ManifestError("baselineDescription must be a non-empty trimmed string")
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
    if not isinstance(reviewed_optimizations, dict):
        raise ManifestError("reviewedOptimizations must be an object")

    for relative_path, optimization in reviewed_optimizations.items():
        if not isinstance(relative_path, str) or not relative_path:
            raise ManifestError("each reviewed optimization must have a file path")
        if not isinstance(optimization, dict):
            raise ManifestError(
                f"{relative_path}: reviewed optimization must be an object"
            )
        if set(optimization) != REVIEWED_OPTIMIZATION_KEYS:
            raise ManifestError(
                f"{relative_path}: reviewed optimization keys must be "
                "baselineSHA256, approvedSHA256, and reason"
            )
        baseline_hash = optimization["baselineSHA256"]
        approved_hash = optimization["approvedSHA256"]
        reason = optimization["reason"]
        if not _is_lowercase_hex(baseline_hash, 64):
            raise ManifestError(
                f"{relative_path}: baselineSHA256 must be a lowercase SHA-256 hash"
            )
        if not _is_lowercase_hex(approved_hash, 64):
            raise ManifestError(
                f"{relative_path}: approvedSHA256 must be a lowercase SHA-256 hash"
            )
        if baseline_hash == approved_hash:
            raise ManifestError(
                f"{relative_path}: approvedSHA256 must differ from baselineSHA256"
            )
        if not isinstance(reason, str) or not reason or reason != reason.strip():
            raise ManifestError(
                f"{relative_path}: reason must be a non-empty trimmed string"
            )
        if relative_path not in files:
            raise ManifestError(
                f"{relative_path}: reviewed optimization is not in frozen files"
            )
        if baseline_hash != files[relative_path]:
            raise ManifestError(
                f"{relative_path}: baselineSHA256 does not match frozen file hash"
            )

    return baseline_commit, baseline_description, files, reviewed_optimizations


def _file_manifest_hash(files: Mapping[str, str]) -> str:
    encoded = json.dumps(
        files,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _reviewed_optimization_manifest_hash(
    reviewed_optimizations: Mapping[str, Mapping[str, str]],
) -> str:
    encoded = json.dumps(
        reviewed_optimizations,
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def verify(
    repository_root: pathlib.Path,
    manifest_path: pathlib.Path,
    expected_manifest_hash: str = ESTABLISHED_FILE_MANIFEST_SHA256,
    expected_reviewed_optimizations_hash: str = (
        ESTABLISHED_REVIEWED_OPTIMIZATIONS_SHA256
    ),
    expected_baseline_commit: str = ESTABLISHED_BASELINE_COMMIT,
    expected_baseline_description: str = ESTABLISHED_BASELINE_DESCRIPTION,
) -> tuple[str, list[str]]:
    (
        baseline_commit,
        baseline_description,
        files,
        reviewed_optimizations,
    ) = _load_manifest(manifest_path)
    resolved_root = repository_root.resolve()
    failures: list[str] = []

    if baseline_commit != expected_baseline_commit:
        failures.append(
            f"baseline commit {baseline_commit} does not match established commit "
            f"{expected_baseline_commit}"
        )
    if baseline_description != expected_baseline_description:
        failures.append(
            f"baseline description {baseline_description!r} does not match "
            f"established description {expected_baseline_description!r}"
        )
    actual_manifest_hash = _file_manifest_hash(files)
    if actual_manifest_hash != expected_manifest_hash:
        failures.append(
            "frozen file manifest hash "
            f"{actual_manifest_hash} does not match established hash "
            f"{expected_manifest_hash}"
        )
    actual_optimization_hash = _reviewed_optimization_manifest_hash(
        reviewed_optimizations
    )
    if actual_optimization_hash != expected_reviewed_optimizations_hash:
        failures.append(
            "reviewed optimization manifest hash "
            f"{actual_optimization_hash} does not match established hash "
            f"{expected_reviewed_optimizations_hash}"
        )
    if failures:
        return baseline_commit, failures

    for relative_path, expected_hash in sorted(files.items()):
        relative_path_object = pathlib.PurePosixPath(relative_path)
        if (
            relative_path_object.is_absolute()
            or ".." in relative_path_object.parts
            or "\\" in relative_path
            or not relative_path_object.parts
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
        reviewed_optimization = reviewed_optimizations.get(relative_path)
        approved_hash = (
            reviewed_optimization["approvedSHA256"]
            if reviewed_optimization is not None
            else expected_hash
        )
        if actual_hash != approved_hash:
            if reviewed_optimization is not None:
                failures.append(
                    f"{relative_path}: reviewed optimization hash {approved_hash}, "
                    f"worktree hash {actual_hash}; original frozen baseline hash "
                    f"{expected_hash}"
                )
                continue
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
            "GFN frozen-source guard failed. GFN production files must match "
            "the established baseline or an explicitly reviewed optimization.",
            file=sys.stderr,
        )
        for failure in failures:
            print(f"- {failure}", file=sys.stderr)
        print(
            f"Established pre-Beta branch baseline: {baseline_commit}",
            file=sys.stderr,
        )
        return 1

    _, _, files, reviewed_optimizations = _load_manifest(manifest_path)
    frozen_count = len(files) - len(reviewed_optimizations)
    print(
        f"GFN frozen-source guard passed: {frozen_count} files match the "
        f"established pre-Beta baseline and {len(reviewed_optimizations)} "
        f"reviewed optimizations match approved hashes (origin "
        f"{baseline_commit})."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
