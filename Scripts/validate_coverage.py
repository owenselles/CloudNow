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


class CoverageDataError(ValueError):
    """Raised when xccov output cannot support the required coverage gate."""


@dataclasses.dataclass(frozen=True)
class FileCoverage:
    path: str
    covered_lines: int
    executable_lines: int
    uncovered_lines: tuple[int, ...]

    @property
    def passed(self) -> bool:
        return (
            self.executable_lines > 0
            and self.covered_lines == self.executable_lines
        )

    def as_json(self) -> dict[str, Any]:
        return {
            "path": self.path,
            "coveredLines": self.covered_lines,
            "executableLines": self.executable_lines,
            "lineCoverage": self.covered_lines / self.executable_lines,
            "uncoveredLines": list(self.uncovered_lines),
            "passed": self.passed,
        }


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


def render_text(results: Sequence[FileCoverage]) -> str:
    lines = [
        "Required deterministic capability coverage",
        "Metric: xccov executable lines (required: 100.00%)",
    ]
    for result in results:
        status = "PASS" if result.passed else "FAIL"
        percentage = 100 * result.covered_lines / result.executable_lines
        lines.append(
            f"{status} {result.path}: {percentage:.2f}% "
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


def render_json(results: Sequence[FileCoverage]) -> dict[str, Any]:
    total_covered = sum(result.covered_lines for result in results)
    total_executable = sum(result.executable_lines for result in results)
    return {
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
        results = evaluate_coverage(
            load_xccov_report(arguments.result_bundle),
            load_xccov_archive(arguments.result_bundle),
        )
    except CoverageDataError as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    text_report = render_text(results)
    json_report = render_json(results)
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
