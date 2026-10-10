#!/usr/bin/env python3
"""Expose the dedicated signing keychain only for a local build's duration."""
import os
import shlex
import subprocess
import sys


def keychains():
    return shlex.split(subprocess.check_output(
        ["/usr/bin/security", "list-keychains", "-d", "user"], text=True))


def set_keychains(paths):
    subprocess.run(["/usr/bin/security", "list-keychains", "-d", "user", "-s", *paths], check=True)


def with_keychain(keychain, command):
    original = keychains()
    added = keychain not in original
    try:
        if added:
            set_keychains([*original, keychain])
        return subprocess.call(command)
    finally:
        if added:
            # Preserve changes another app made while the build was running.
            current = keychains()
            if keychain in current:
                set_keychains([path for path in current if path != keychain])


if __name__ == "__main__":
    if os.environ.get("CLIPSHELF_LOCAL_SIGNING") != "1" or len(sys.argv) != 2:
        raise SystemExit("This helper requires the local signing build environment.")
    raise SystemExit(with_keychain(os.environ["CLIPSHELF_SIGNING_KEYCHAIN"], ["/bin/bash", sys.argv[1]]))
