#!/usr/bin/env python3

"""Validate localization table parity and literal production key usage."""

from __future__ import annotations

import collections
import pathlib
import re
import sys


KEY_PATTERN = re.compile(r'^\s*"((?:\\.|[^"\\])+)":\s*"', re.MULTILINE)
LITERAL_USAGE_PATTERN = re.compile(
    r'L10n\.(?:text|format)\(\s*"((?:\\.|[^"\\])+)"',
    re.MULTILINE,
)


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

    keys_by_path: dict[pathlib.Path, set[str]] = {}
    failed = False
    for source_path in source_paths:
        keys = KEY_PATTERN.findall(source_path.read_text(encoding="utf-8"))
        keys_by_path[source_path] = set(keys)
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

    english_path = localization_directory / "L10nEN.swift"
    english_keys = keys_by_path.get(english_path)
    if not english_keys:
        print(
            f"error: English localization table missing or empty: {english_path}",
            file=sys.stderr,
        )
        return 1

    for source_path, keys in keys_by_path.items():
        missing = sorted(english_keys - keys)
        unexpected = sorted(keys - english_keys)
        if missing:
            failed = True
            print(
                f"error: {source_path.name} is missing keys: " + ", ".join(missing),
                file=sys.stderr,
            )
        if unexpected:
            failed = True
            print(
                f"error: {source_path.name} has unexpected keys: "
                + ", ".join(unexpected),
                file=sys.stderr,
            )

    production_root = repository_root / "CloudNow"
    literal_usages: set[str] = set()
    for source_path in production_root.rglob("*.swift"):
        literal_usages.update(
            LITERAL_USAGE_PATTERN.findall(source_path.read_text(encoding="utf-8"))
        )
    missing_usage_keys = sorted(literal_usages - english_keys)
    if missing_usage_keys:
        failed = True
        print(
            "error: production source references missing localization keys: "
            + ", ".join(missing_usage_keys),
            file=sys.stderr,
        )

    if failed:
        return 1

    print(
        f"Localization source validation passed: {len(source_paths)} tables, "
        f"{len(english_keys)} keys, {len(literal_usages)} literal usages, "
        "exact parity, no duplicates, and no missing production keys."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
