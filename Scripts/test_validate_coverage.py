#!/usr/bin/env python3

"""Tests for the deterministic capability coverage gate."""

from __future__ import annotations

import unittest

import validate_coverage


class CoverageValidatorTests(unittest.TestCase):
    def make_archive(
        self,
        execution_counts: dict[str, list[int]],
    ) -> dict[str, list[dict[str, int | bool]]]:
        return {
            f"/checkout/{path}": [
                {
                    "line": index,
                    "isExecutable": True,
                    "executionCount": count,
                }
                for index, count in enumerate(counts, start=1)
            ]
            for path, counts in execution_counts.items()
        }

    def make_report(
        self,
        totals: dict[str, tuple[int, int]],
    ) -> list[dict[str, list[dict[str, int | str]]]]:
        return [
            {
                "files": [
                    {
                        "path": f"/checkout/{path}",
                        "coveredLines": covered,
                        "executableLines": executable,
                    }
                    for path, (covered, executable) in totals.items()
                ]
            }
        ]

    def test_all_required_executable_lines_pass(self) -> None:
        archive = self.make_archive(
            {path: [1, 4] for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )
        report = self.make_report(
            {path: (2, 2) for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )

        results = validate_coverage.evaluate_coverage(report, archive)

        self.assertTrue(all(result.passed for result in results))
        self.assertEqual(
            validate_coverage.render_json(results)["executableLines"],
            6,
        )

    def test_uncovered_line_fails_with_line_number(self) -> None:
        counts = {
            path: [1] for path in validate_coverage.REQUIRED_SOURCE_PATHS
        }
        counts[validate_coverage.REQUIRED_SOURCE_PATHS[0]] = [1, 0]
        report_totals = {
            path: (1, 1) for path in validate_coverage.REQUIRED_SOURCE_PATHS
        }
        report_totals[validate_coverage.REQUIRED_SOURCE_PATHS[0]] = (1, 2)
        results = validate_coverage.evaluate_coverage(
            self.make_report(report_totals),
            self.make_archive(counts),
        )

        self.assertFalse(results[0].passed)
        self.assertEqual(results[0].uncovered_lines, (2,))
        self.assertIn(
            "Uncovered executable lines: 2",
            validate_coverage.render_text(results),
        )

    def test_file_summary_deficit_fails_even_when_source_lines_executed(self) -> None:
        archive = self.make_archive(
            {path: [1] for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )
        report_totals = {
            path: (1, 1) for path in validate_coverage.REQUIRED_SOURCE_PATHS
        }
        report_totals[validate_coverage.REQUIRED_SOURCE_PATHS[0]] = (1, 2)

        results = validate_coverage.evaluate_coverage(
            self.make_report(report_totals),
            archive,
        )

        self.assertFalse(results[0].passed)
        self.assertFalse(validate_coverage.render_json(results)["passed"])

    def test_non_executable_lines_do_not_reduce_coverage(self) -> None:
        archive = self.make_archive(
            {path: [1] for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )
        archive[f"/checkout/{validate_coverage.REQUIRED_SOURCE_PATHS[0]}"].append(
            {"line": 2, "isExecutable": False}
        )
        report = self.make_report(
            {path: (1, 1) for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )

        results = validate_coverage.evaluate_coverage(report, archive)

        self.assertTrue(all(result.passed for result in results))

    def test_missing_required_file_is_an_error(self) -> None:
        archive = self.make_archive(
            {path: [1] for path in validate_coverage.REQUIRED_SOURCE_PATHS[1:]}
        )
        report = self.make_report(
            {path: (1, 1) for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )

        with self.assertRaisesRegex(
            validate_coverage.CoverageDataError,
            "found 0",
        ):
            validate_coverage.evaluate_coverage(report, archive)

    def test_zero_executable_lines_is_an_error(self) -> None:
        archive = self.make_archive(
            {path: [1] for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )
        archive[f"/checkout/{validate_coverage.REQUIRED_SOURCE_PATHS[0]}"] = [
            {"line": 1, "isExecutable": False}
        ]
        report = self.make_report(
            {path: (1, 1) for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )

        with self.assertRaisesRegex(
            validate_coverage.CoverageDataError,
            "no executable lines",
        ):
            validate_coverage.evaluate_coverage(report, archive)


if __name__ == "__main__":
    unittest.main()
