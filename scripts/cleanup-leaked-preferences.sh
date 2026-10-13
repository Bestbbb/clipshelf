#!/bin/bash
set -euo pipefail

# Default: list only. An explicit confirmation moves recognized test files into
# a dedicated Trash folder; it never permanently deletes application settings.
python3 - "$@" <<'PY'
import argparse
from datetime import datetime, timezone
import os
from pathlib import Path
import stat
import sys

parser = argparse.ArgumentParser(description="List old ClipShelf test preference files; optionally move them to Trash.")
parser.add_argument("--apply", action="store_true")
parser.add_argument("--confirm", help="Exact confirmation: MOVE TEST PREFERENCES TO TRASH")
args = parser.parse_args()
directory = Path.home() / "Library" / "Preferences"
prefixes = ("ClipShelf.cleanup-tests.", "clipshelf-language-tests.", "io.github.bestbbb.clipshelf.validation.")
files = []
if directory.exists():
    for path in sorted(directory.iterdir()):
        info = path.lstat()
        if (path.name.startswith(prefixes) and path.suffix == ".plist"
                and stat.S_ISREG(info.st_mode) and info.st_uid == os.geteuid() and info.st_nlink == 1):
            files.append((path, (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size)))
for path, _ in files:
    print(path.name)
print(f"Recognized test files: {len(files)}. App settings are excluded.", flush=True)
if not args.apply or not files:
    sys.exit(0)
phrase = "MOVE TEST PREFERENCES TO TRASH"
confirmation = args.confirm
if confirmation is None:
    try:
        with open("/dev/tty", "r+") as terminal:
            terminal.write(f"Type {phrase} to proceed: "); terminal.flush()
            confirmation = terminal.readline().strip()
    except OSError:
        sys.exit("Confirmation requires a terminal or the explicit --confirm phrase.")
if confirmation != phrase:
    sys.exit("Cancelled; no files were moved.")
destination = Path.home() / ".Trash" / ("ClipShelf-test-preferences-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
destination.mkdir(mode=0o700)
for path, identity in files:
    info = path.lstat()
    current = (info.st_dev, info.st_ino, info.st_mtime_ns, info.st_size)
    if current != identity or not stat.S_ISREG(info.st_mode) or info.st_uid != os.geteuid():
        sys.exit(f"Stopped: {path.name} changed. Already moved files remain recoverable in {destination}.")
    os.rename(path, destination / path.name)
print(f"Moved {len(files)} test files to {destination}. Restore them from Trash if needed.")
PY
