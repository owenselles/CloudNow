#!/usr/bin/env python3

"""Enforce executable-line coverage for deterministic cloud capability code."""

from __future__ import annotations

import argparse
import dataclasses
import json
import pathlib
import subprocess
import sys
from collections.abc import Mapping, Sequence
from typing import Any


REQUIRED_SOURCE_PATHS = (
    "CloudNow/Services/CloudGamingCapabilities.swift",
    "CloudNow/GFN/GFNCapabilityAdapter.swift",
    "CloudNow/Xbox/XboxCapabilityAdapter.swift",
)

DEFAULT_TITLE = "Required deterministic capability coverage"


class CoverageDataError(ValueError):
    """Raised when xccov output cannot support the required coverage gate."""


@dataclasses.dataclass(frozen=True)
class FileCoverage:
    path: str
    covered_lines: int
    executable_lines: int
    uncovered_lines: tuple[int, ...]
    label: str | None = None
    start_line: int | None = None
    end_line: int | None = None

    @property
    def passed(self) -> bool:
        return (
            self.executable_lines > 0
            and self.covered_lines == self.executable_lines
        )

    def as_json(self) -> dict[str, Any]:
        payload: dict[str, Any] = {
            "path": self.path,
            "coveredLines": self.covered_lines,
            "executableLines": self.executable_lines,
            "lineCoverage": self.covered_lines / self.executable_lines,
            "uncoveredLines": list(self.uncovered_lines),
            "passed": self.passed,
        }
        if self.label is not None:
            payload["label"] = self.label
            payload["startLine"] = self.start_line
            payload["endLine"] = self.end_line
        return payload

    @property
    def display_name(self) -> str:
        if self.label is None:
            return self.path
        return (
            f"{self.path} [{self.label}: "
            f"lines {self.start_line}-{self.end_line}]"
        )


@dataclasses.dataclass(frozen=True)
class CoverageRegion:
    label: str
    path: str
    start_marker: str
    end_marker: str


@dataclasses.dataclass(frozen=True)
class CoverageManifest:
    scope: str
    title: str
    regions: tuple[CoverageRegion, ...]


def _records_for_path(
    archive: Mapping[str, Any],
    relative_path: str,
) -> Sequence[Mapping[str, Any]]:
    normalized_suffix = f"/{relative_path}"
    matches = [
        records
        for source_path, records in archive.items()
        if isinstance(source_path, str)
        and source_path.replace("\\", "/").endswith(normalized_suffix)
    ]
    if len(matches) != 1:
        raise CoverageDataError(
            f"expected exactly one xccov entry for {relative_path}, "
            f"found {len(matches)}"
        )
    records = matches[0]
    if not isinstance(records, list):
        raise CoverageDataError(
            f"xccov entry for {relative_path} is not a line-record array"
        )
    if not all(isinstance(record, dict) for record in records):
        raise CoverageDataError(
            f"xccov entry for {relative_path} contains an invalid line record"
        )
    return records


def _summary_for_path(
    report: Sequence[Mapping[str, Any]],
    relative_path: str,
) -> Mapping[str, Any]:
    normalized_suffix = f"/{relative_path}"
    matches = [
        file_summary
        for target_summary in report
        if isinstance(target_summary, dict)
        for file_summary in target_summary.get("files", [])
        if isinstance(file_summary, dict)
        and str(file_summary.get("path", ""))
        .replace("\\", "/")
        .endswith(normalized_suffix)
    ]
    if len(matches) != 1:
        raise CoverageDataError(
            f"expected exactly one xccov file summary for {relative_path}, "
            f"found {len(matches)}"
        )
    return matches[0]


def parse_coverage_manifest(payload: Mapping[str, Any]) -> CoverageManifest:
    if payload.get("schemaVersion") != 1:
        raise CoverageDataError("coverage manifest has an unsupported schema")
    if payload.get("metric") != "xccov-executable-lines":
        raise CoverageDataError("coverage manifest has an unsupported metric")
    if payload.get("requiredCoverage") != 1.0:
        raise CoverageDataError("coverage manifest must require 100% coverage")

    scope = payload.get("scope")
    title = payload.get("title")
    raw_regions = payload.get("regions")
    if not isinstance(scope, str) or not scope.strip():
        raise CoverageDataError("coverage manifest scope is missing")
    if not isinstance(title, str) or not title.strip():
        raise CoverageDataError("coverage manifest title is missing")
    if not isinstance(raw_regions, list) or not raw_regions:
        raise CoverageDataError("coverage manifest has no source regions")

    regions: list[CoverageRegion] = []
    labels: set[str] = set()
    for raw_region in raw_regions:
        if not isinstance(raw_region, dict):
            raise CoverageDataError("coverage manifest contains an invalid region")
        values = {
            key: raw_region.get(key)
            for key in ("label", "path", "startMarker", "endMarker")
        }
        if not all(
            isinstance(value, str) and value.strip()
            for value in values.values()
        ):
            raise CoverageDataError(
                "coverage manifest region fields must be non-empty strings"
            )
        label = str(values["label"])
        relative_path = str(values["path"])
        start_marker = str(values["startMarker"])
        end_marker = str(values["endMarker"])
        path = pathlib.PurePosixPath(relative_path)
        if (
            path.is_absolute()
            or ".." in path.parts
            or relative_path != relative_path.replace("\\", "/")
        ):
            raise CoverageDataError(
                f"coverage region path must stay inside the source root: "
                f"{relative_path}"
            )
        if label in labels:
            raise CoverageDataError(f"duplicate coverage region label: {label}")
        if start_marker == end_marker:
            raise CoverageDataError(
                f"coverage region markers must differ: {label}"
            )
        labels.add(label)
        regions.append(
            CoverageRegion(
                label=label,
                path=relative_path,
                start_marker=start_marker,
                end_marker=end_marker,
            )
        )
    return CoverageManifest(
        scope=scope.strip(),
        title=title.strip(),
        regions=tuple(regions),
    )


def load_coverage_manifest(path: pathlib.Path) -> CoverageManifest:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"))
    except OSError as error:
        raise CoverageDataError(
            f"could not read coverage manifest: {path}"
        ) from error
    except json.JSONDecodeError as error:
        raise CoverageDataError("coverage manifest is not valid JSON") from error
    if not isinstance(payload, dict):
        raise CoverageDataError("coverage manifest JSON is not an object")
    return parse_coverage_manifest(payload)


def _line_range_for_region(
    source_root: pathlib.Path,
    region: CoverageRegion,
) -> tuple[int, int]:
    source_path = source_root / region.path
    try:
        lines = source_path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise CoverageDataError(
            f"could not read source for coverage region {region.label}: "
            f"{region.path}"
        ) from error

    start_lines = [
        index
        for index, line in enumerate(lines, start=1)
        if region.start_marker in line
    ]
    end_lines = [
        index
        for index, line in enumerate(lines, start=1)
        if region.end_marker in line
    ]
    if len(start_lines) != 1 or len(end_lines) != 1:
        raise CoverageDataError(
            f"coverage region {region.label} expected one start and end "
            f"marker, found {len(start_lines)} and {len(end_lines)}"
        )
    start_line = start_lines[0] + 1
    end_line = end_lines[0] - 1
    if start_line > end_line:
        raise CoverageDataError(
            f"coverage region {region.label} has reversed or empty markers"
        )
    return start_line, end_line


def evaluate_region_coverage(
    archive: Mapping[str, Any],
    source_root: pathlib.Path,
    regions: Sequence[CoverageRegion],
) -> tuple[FileCoverage, ...]:
    results: list[FileCoverage] = []
    ranges_by_path: dict[str, list[tuple[int, int, str]]] = {}
    for region in regions:
        start_line, end_line = _line_range_for_region(source_root, region)
        existing_ranges = ranges_by_path.setdefault(region.path, [])
        for existing_start, existing_end, existing_label in existing_ranges:
            if start_line <= existing_end and existing_start <= end_line:
                raise CoverageDataError(
                    f"coverage regions overlap in {region.path}: "
                    f"{existing_label} and {region.label}"
                )
        existing_ranges.append((start_line, end_line, region.label))

        records = _records_for_path(archive, region.path)
        try:
            executable_records = [
                record
                for record in records
                if record.get("isExecutable") is True
                and start_line <= int(record["line"]) <= end_line
            ]
        except (KeyError, TypeError, ValueError) as error:
            raise CoverageDataError(
                f"xccov returned an invalid line record for region "
                f"{region.label} in {region.path}"
            ) from error
        if not executable_records:
            raise CoverageDataError(
                f"xccov reported no executable lines for region "
                f"{region.label} in {region.path}"
            )
        try:
            executable_lines = tuple(
                sorted(int(record["line"]) for record in executable_records)
            )
            uncovered_lines = tuple(
                sorted(
                    int(record["line"])
                    for record in executable_records
                    if int(record.get("executionCount", 0)) <= 0
                )
            )
        except (KeyError, TypeError, ValueError) as error:
            raise CoverageDataError(
                f"xccov returned an invalid line record for region "
                f"{region.label} in {region.path}"
            ) from error
        if len(set(executable_lines)) != len(executable_lines):
            raise CoverageDataError(
                f"xccov returned duplicate executable line records for region "
                f"{region.label} in {region.path}"
            )
        results.append(
            FileCoverage(
                path=region.path,
                covered_lines=len(executable_lines) - len(uncovered_lines),
                executable_lines=len(executable_lines),
                uncovered_lines=uncovered_lines,
                label=region.label,
                start_line=start_line,
                end_line=end_line,
            )
        )
    return tuple(results)


def evaluate_coverage(
    report: Sequence[Mapping[str, Any]],
    archive: Mapping[str, Any],
    required_paths: Sequence[str] = REQUIRED_SOURCE_PATHS,
) -> tuple[FileCoverage, ...]:
    results: list[FileCoverage] = []
    for relative_path in required_paths:
        summary = _summary_for_path(report, relative_path)
        records = _records_for_path(archive, relative_path)
        executable_records = [
            record for record in records if record.get("isExecutable") is True
        ]
        if not executable_records:
            raise CoverageDataError(
                f"xccov reported no executable lines for {relative_path}"
            )

        try:
            uncovered_lines = tuple(
                sorted(
                    int(record["line"])
                    for record in executable_records
                    if int(record.get("executionCount", 0)) <= 0
                )
            )
        except (KeyError, TypeError, ValueError) as error:
            raise CoverageDataError(
                f"xccov returned an invalid line record for {relative_path}"
            ) from error

        try:
            covered_lines = int(summary["coveredLines"])
            executable_lines = int(summary["executableLines"])
        except (KeyError, TypeError, ValueError) as error:
            raise CoverageDataError(
                f"xccov returned an invalid file summary for {relative_path}"
            ) from error
        if executable_lines <= 0 or not 0 <= covered_lines <= executable_lines:
            raise CoverageDataError(
                f"xccov returned invalid executable-line totals for {relative_path}"
            )
        results.append(
            FileCoverage(
                path=relative_path,
                covered_lines=covered_lines,
                executable_lines=executable_lines,
                uncovered_lines=uncovered_lines,
            )
        )
    return tuple(results)


def render_text(
    results: Sequence[FileCoverage],
    title: str = DEFAULT_TITLE,
) -> str:
    lines = [
        title,
        "Metric: xccov executable lines (required: 100.00%)",
    ]
    for result in results:
        status = "PASS" if result.passed else "FAIL"
        percentage = 100 * result.covered_lines / result.executable_lines
        lines.append(
            f"{status} {result.display_name}: {percentage:.2f}% "
            f"({result.covered_lines}/{result.executable_lines})"
        )
        if result.uncovered_lines:
            uncovered = ", ".join(str(line) for line in result.uncovered_lines)
            lines.append(f"  Uncovered executable lines: {uncovered}")

    total_covered = sum(result.covered_lines for result in results)
    total_executable = sum(result.executable_lines for result in results)
    passed = all(result.passed for result in results)
    lines.append(
        f"Coverage gate {'passed' if passed else 'failed'}: "
        f"{total_covered}/{total_executable} executable lines."
    )
    lines.append(
        "Swift branch coverage is not evaluated: the pinned Xcode/Swift "
        "toolchain emits a zero LLVM branch denominator for these sources."
    )
    return "\n".join(lines) + "\n"


def render_json(
    results: Sequence[FileCoverage],
    scope: str | None = None,
) -> dict[str, Any]:
    total_covered = sum(result.covered_lines for result in results)
    total_executable = sum(result.executable_lines for result in results)
    payload = {
        "schemaVersion": 1,
        "metric": "xccov-executable-lines",
        "requiredCoverage": 1.0,
        "passed": all(result.passed for result in results),
        "coveredLines": total_covered,
        "executableLines": total_executable,
        "files": [result.as_json() for result in results],
        "branchCoverage": {
            "evaluated": False,
            "reason": (
                "The pinned Xcode/Swift toolchain emits a zero LLVM branch "
                "denominator for these Swift sources."
            ),
        },
    }
    if scope is not None:
        payload["scope"] = scope
    return payload


def run_xccov(result_bundle: pathlib.Path, arguments: Sequence[str]) -> Any:
    command = [
        "xcrun",
        "xccov",
        "view",
        *arguments,
        str(result_bundle),
    ]
    completed = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        text=True,
    )
    if completed.returncode != 0:
        raise CoverageDataError(
            f"xccov exited with status {completed.returncode}"
        )
    try:
        return json.loads(completed.stdout)
    except json.JSONDecodeError as error:
        raise CoverageDataError("xccov returned invalid JSON") from error


def load_xccov_report(result_bundle: pathlib.Path) -> Sequence[Mapping[str, Any]]:
    report = run_xccov(
        result_bundle,
        ("--report", "--files-for-target", "CloudNow.app", "--json"),
    )
    if not isinstance(report, list):
        raise CoverageDataError("xccov file-report JSON is not an array")
    return report


def load_xccov_archive(result_bundle: pathlib.Path) -> Mapping[str, Any]:
    archive = run_xccov(result_bundle, ("--archive", "--json"))
    if not isinstance(archive, dict):
        raise CoverageDataError("xccov archive JSON is not an object")
    return archive


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--result-bundle", required=True, type=pathlib.Path)
    parser.add_argument("--text-report", required=True, type=pathlib.Path)
    parser.add_argument("--json-report", required=True, type=pathlib.Path)
    parser.add_argument(
        "--manifest",
        type=pathlib.Path,
        help="Gate executable lines inside marker-delimited source regions.",
    )
    parser.add_argument(
        "--source-root",
        type=pathlib.Path,
        help="Repository root used to resolve manifest source paths.",
    )
    return parser.parse_args()


def main() -> int:
    arguments = parse_arguments()
    if not arguments.result_bundle.is_dir():
        print(
            f"error: result bundle does not exist: {arguments.result_bundle}",
            file=sys.stderr,
        )
        return 2

    try:
        if arguments.manifest is None:
            results = evaluate_coverage(
                load_xccov_report(arguments.result_bundle),
                load_xccov_archive(arguments.result_bundle),
            )
            scope = None
            title = DEFAULT_TITLE
        else:
            manifest = load_coverage_manifest(arguments.manifest)
            source_root = arguments.source_root
            if source_root is None:
                source_root = pathlib.Path(__file__).resolve().parent.parent
            results = evaluate_region_coverage(
                load_xccov_archive(arguments.result_bundle),
                source_root,
                manifest.regions,
            )
            scope = manifest.scope
            title = manifest.title
    except CoverageDataError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    text_report = render_text(results, title=title)
    json_report = render_json(results, scope=scope)
    arguments.text_report.parent.mkdir(parents=True, exist_ok=True)
    arguments.json_report.parent.mkdir(parents=True, exist_ok=True)
    arguments.text_report.write_text(text_report, encoding="utf-8")
    arguments.json_report.write_text(
        json.dumps(json_report, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    print(text_report, end="")
    return 0 if json_report["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
