#!/usr/bin/env python3
"""Reject LCOV reports with source files below the required coverage."""

from argparse import ArgumentParser
from pathlib import Path


def parse_lcov(path: Path) -> dict[str, tuple[int, int]]:
    coverage: dict[str, tuple[int, int]] = {}
    source: str | None = None
    found = 0
    hit = 0

    for line in path.read_text(encoding="utf-8").splitlines():
        if line.startswith("SF:"):
            source = line[3:]
            found = 0
            hit = 0
        elif line.startswith("DA:") and source is not None:
            found += 1
            hit += int(line.split(",", 1)[1]) > 0
        elif line == "end_of_record" and source is not None:
            previous_hit, previous_found = coverage.get(source, (0, 0))
            coverage[source] = (previous_hit + hit, previous_found + found)
            source = None

    return coverage


def main() -> int:
    parser = ArgumentParser()
    parser.add_argument("report", type=Path)
    parser.add_argument("--minimum", type=int, default=80)
    parser.add_argument("--ignore-prefix", action="append", default=[])
    arguments = parser.parse_args()

    failures: list[str] = []
    for source, (hit, found) in sorted(parse_lcov(arguments.report).items()):
        if found == 0 or any(source.startswith(prefix) for prefix in arguments.ignore_prefix):
            continue
        percent = 100 * hit / found
        result = f"{source}: {percent:.2f}% ({hit}/{found})"
        print(result)
        if hit * 100 <= arguments.minimum * found:
            failures.append(result)

    if failures:
        print(f"\nFiles at or below {arguments.minimum}% coverage:")
        for failure in failures:
            print(f"  {failure}")
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
