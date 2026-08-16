#!/usr/bin/env python3

"""Tests for the deterministic capability coverage gate."""

from __future__ import annotations

import pathlib
import tempfile
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

    def make_manifest(
        self,
        regions: list[dict[str, str]],
    ) -> validate_coverage.CoverageManifest:
        return validate_coverage.parse_coverage_manifest({
            "schemaVersion": 1,
            "scope": "test-regions",
            "title": "Test region coverage",
            "metric": "xccov-executable-lines",
            "requiredCoverage": 1.0,
            "regions": regions,
        })

    def test_all_required_executable_lines_pass(self) -> None:
        archive = self.make_archive(
            {path: [1, 4] for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )
        report = self.make_report(
            {path: (2, 2) for path in validate_coverage.REQUIRED_SOURCE_PATHS}
        )

        results = validate_coverage.evaluate_coverage(report, archive)

        self.assertTrue(all(result.passed for result in results))
        payload = validate_coverage.render_json(results)
        self.assertEqual(payload["executableLines"], 6)
        self.assertNotIn("scope", payload)

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

    def test_marker_delimited_regions_gate_only_selected_lines(self) -> None:
        relative_path = "Sources/Feature.swift"
        manifest = self.make_manifest([{
            "label": "decision logic",
            "path": relative_path,
            "startMarker": "coverage:test:start",
            "endMarker": "coverage:test:end",
        }])
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            source_path = source_root / relative_path
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "// coverage:test:start\n"
                "let selected = true\n"
                "let covered = selected\n"
                "// coverage:test:end\n"
                "let outside = false\n",
                encoding="utf-8",
            )
            archive = {
                f"/checkout/{relative_path}": [
                    {"line": 2, "isExecutable": True, "executionCount": 1},
                    {"line": 3, "isExecutable": True, "executionCount": 2},
                    {"line": 5, "isExecutable": True, "executionCount": 0},
                ]
            }

            results = validate_coverage.evaluate_region_coverage(
                archive,
                source_root,
                manifest.regions,
            )

        self.assertEqual(len(results), 1)
        self.assertTrue(results[0].passed)
        self.assertEqual(results[0].covered_lines, 2)
        self.assertEqual(results[0].executable_lines, 2)
        self.assertEqual(results[0].start_line, 2)
        self.assertEqual(results[0].end_line, 3)
        payload = validate_coverage.render_json(
            results,
            scope=manifest.scope,
        )
        self.assertEqual(payload["scope"], "test-regions")
        self.assertEqual(payload["files"][0]["label"], "decision logic")

    def test_marker_region_reports_uncovered_executable_line(self) -> None:
        relative_path = "Sources/Feature.swift"
        manifest = self.make_manifest([{
            "label": "decision logic",
            "path": relative_path,
            "startMarker": "coverage:test:start",
            "endMarker": "coverage:test:end",
        }])
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            source_path = source_root / relative_path
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "// coverage:test:start\n"
                "let uncovered = false\n"
                "// coverage:test:end\n",
                encoding="utf-8",
            )
            results = validate_coverage.evaluate_region_coverage(
                {
                    f"/checkout/{relative_path}": [{
                        "line": 2,
                        "isExecutable": True,
                        "executionCount": 0,
                    }]
                },
                source_root,
                manifest.regions,
            )

        self.assertFalse(results[0].passed)
        self.assertEqual(results[0].uncovered_lines, (2,))
        self.assertIn("Uncovered executable lines: 2", (
            validate_coverage.render_text(results, title=manifest.title)
        ))

    def test_region_markers_must_be_unique_and_ordered(self) -> None:
        relative_path = "Sources/Feature.swift"
        manifest = self.make_manifest([{
            "label": "decision logic",
            "path": relative_path,
            "startMarker": "coverage:test:start",
            "endMarker": "coverage:test:end",
        }])
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            source_path = source_root / relative_path
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "// coverage:test:end\n"
                "let value = true\n"
                "// coverage:test:start\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                validate_coverage.CoverageDataError,
                "reversed or empty",
            ):
                validate_coverage.evaluate_region_coverage(
                    self.make_archive({relative_path: [1, 1, 1]}),
                    source_root,
                    manifest.regions,
                )

            source_path.write_text(
                "// coverage:test:start\n"
                "// coverage:test:start\n"
                "let value = true\n"
                "// coverage:test:end\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                validate_coverage.CoverageDataError,
                "found 2 and 1",
            ):
                validate_coverage.evaluate_region_coverage(
                    self.make_archive({relative_path: [1, 1, 1, 1]}),
                    source_root,
                    manifest.regions,
                )

    def test_regions_must_not_overlap(self) -> None:
        relative_path = "Sources/Feature.swift"
        manifest = self.make_manifest([
            {
                "label": "outer logic",
                "path": relative_path,
                "startMarker": "coverage:outer:start",
                "endMarker": "coverage:outer:end",
            },
            {
                "label": "inner logic",
                "path": relative_path,
                "startMarker": "coverage:inner:start",
                "endMarker": "coverage:inner:end",
            },
        ])
        with tempfile.TemporaryDirectory() as temporary_directory:
            source_root = pathlib.Path(temporary_directory)
            source_path = source_root / relative_path
            source_path.parent.mkdir(parents=True)
            source_path.write_text(
                "// coverage:outer:start\n"
                "let one = true\n"
                "// coverage:inner:start\n"
                "let two = true\n"
                "// coverage:inner:end\n"
                "// coverage:outer:end\n",
                encoding="utf-8",
            )
            with self.assertRaisesRegex(
                validate_coverage.CoverageDataError,
                "coverage regions overlap",
            ):
                validate_coverage.evaluate_region_coverage(
                    self.make_archive({relative_path: [1, 1, 1, 1, 1, 1]}),
                    source_root,
                    manifest.regions,
                )

    def test_manifest_rejects_escaping_paths_and_duplicate_labels(self) -> None:
        base_region = {
            "label": "decision logic",
            "path": "../Feature.swift",
            "startMarker": "coverage:test:start",
            "endMarker": "coverage:test:end",
        }
        with self.assertRaisesRegex(
            validate_coverage.CoverageDataError,
            "must stay inside",
        ):
            self.make_manifest([base_region])

        base_region["path"] = "Sources/Feature.swift"
        with self.assertRaisesRegex(
            validate_coverage.CoverageDataError,
            "duplicate coverage region label",
        ):
            self.make_manifest([base_region, dict(base_region)])


if __name__ == "__main__":
    unittest.main()
