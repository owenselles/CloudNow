#!/usr/bin/env python3

"""Reject duplicate keys in CloudNow localization source tables."""

from __future__ import annotations

import collections
import pathlib
import re
import sys


KEY_PATTERN = re.compile(r'^\s*"((?:\\.|[^"\\])+)":\s*"', re.MULTILINE)


def main() -> int:
    repository_root = pathlib.Path(__file__).resolve().parent.parent
    localization_directory = repository_root / "CloudNow" / "Localization"
    source_paths = sorted(localization_directory.glob("L10n*.swift"))
    if not source_paths:
        print(
            f"error: no localization tables found under {localization_directory}",
            file=sys.stderr,
        )
        return 1

    failed = False
    for source_path in source_paths:
        keys = KEY_PATTERN.findall(source_path.read_text(encoding="utf-8"))
        duplicates = sorted(
            key
            for key, count in collections.Counter(keys).items()
            if count > 1
        )
        if duplicates:
            failed = True
            print(
                f"error: {source_path.name} declares duplicate keys: "
                + ", ".join(duplicates),
                file=sys.stderr,
            )

    if failed:
        return 1

    print(
        f"Localization source validation passed: {len(source_paths)} tables, "
        "no duplicate keys."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
