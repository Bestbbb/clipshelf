#!/usr/bin/env python3
"""Run native tests and fail if they add/remove ClipShelf preference files."""

import argparse
import json
from pathlib import Path
import subprocess
import sys


def preference_files(directory: Path) -> set[str]:
    if not directory.exists():
        return set()
    return {path.name for path in directory.iterdir()
            if "clipshelf" in path.name.casefold() and path.is_file()}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--log", type=Path)
    parser.add_argument("test_args", nargs=argparse.REMAINDER)
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[2]
    preferences = Path.home() / "Library" / "Preferences"
    before = preference_files(preferences)
    arguments = options.test_args
    if arguments[:1] == ["--"]:
        arguments = arguments[1:]
    command = ["swift", "test", "--package-path", str(repository / "native"), *arguments]
    if options.log:
        options.log.parent.mkdir(parents=True, exist_ok=True)
        with options.log.open("w") as output:
            result = subprocess.run(command, cwd=repository, stdout=output, stderr=subprocess.STDOUT)
    else:
        result = subprocess.run(command, cwd=repository)
    after = preference_files(preferences)
    report = {"before_count": len(before), "after_count": len(after),
              "added": sorted(after - before), "removed": sorted(before - after),
              "tests_exit_code": result.returncode}
    print(json.dumps(report, ensure_ascii=False), flush=True)
    return result.returncode or (1 if before != after else 0)


if __name__ == "__main__":
    sys.exit(main())
