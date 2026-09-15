#!/usr/bin/env python3
"""Fail when a quoted #include only resolves on a case-insensitive filesystem.

ARMSX3 and RPCS3 are developed largely on macOS and Windows, where
    #include "Emu/system.h"
happily finds rpcs3/Emu/System.h. On Linux -- every CI runner, and the Android
cross build -- it does not, and the build dies ~50 minutes in with a
one-line "file not found" that says nothing about why it worked for the author.

This catches that class in under a second, so it is a `Fork checks` failure
instead of a wasted core build.

Rule: an include is reported only when it fails to resolve with exact case AND
resolves when case is ignored. Everything else is left alone -- the tree has
~120 quoted includes that resolve through -isystem paths, generated headers or
platform SDKs this script deliberately knows nothing about, and guessing at
those would make the check useless.
"""

import os
import re
import sys

# The quoted-include search path shared by the targets this fork builds. Only
# roots that exist in a clean checkout; missing ones are skipped, not an error.
INCLUDE_ROOTS = ("", "rpcs3", "3rdparty")

# Where first-party sources live. 3rdparty is excluded on purpose: its files are
# not ours to fix, and upstream projects build on Linux already.
SOURCE_DIRS = ("rpcs3", "android/src", "Utilities", "util")

SOURCE_SUFFIXES = (".cpp", ".cc", ".h", ".hpp", ".inl")
SKIP_DIRS = {".git", "build", "build-a13", "build-a14", "build-a15"}

INCLUDE_RE = re.compile(r'^[ \t]*#[ \t]*include[ \t]+"([^"]+)"', re.M)


def index_root(base):
    """lowercased relative path -> the real relative path, for one search root."""
    out = {}
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
        for name in filenames:
            rel = os.path.relpath(os.path.join(dirpath, name), base)
            out.setdefault(rel.lower(), rel)
    return out


def main():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

    roots = [os.path.join(root, r) if r else root for r in INCLUDE_ROOTS]
    roots = [r for r in roots if os.path.isdir(r)]
    indexes = [(r, index_root(r)) for r in roots]

    sources = []
    for src_dir in SOURCE_DIRS:
        base = os.path.join(root, src_dir)
        if not os.path.isdir(base):
            continue
        for dirpath, dirnames, filenames in os.walk(base):
            dirnames[:] = [d for d in dirnames if d not in SKIP_DIRS]
            for name in filenames:
                if name.endswith(SOURCE_SUFFIXES):
                    sources.append(os.path.join(dirpath, name))

    findings = []
    for path in sorted(sources):
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()

        own_dir = os.path.dirname(path)
        for match in INCLUDE_RE.finditer(text):
            inc = match.group(1).replace("\\", "/")

            # Exact resolution: the including file's own directory first, as the
            # quoted form does, then the -I roots.
            candidates = [os.path.join(own_dir, inc)]
            candidates += [os.path.join(r, inc) for r in roots]
            if any(os.path.exists(c) for c in candidates):
                continue

            actual = None
            lowered = inc.lower()
            if os.path.dirname(lowered) == "":
                for name in os.listdir(own_dir):
                    if name.lower() == lowered:
                        actual = os.path.relpath(os.path.join(own_dir, name), root)
                        break
            if actual is None:
                for base, index in indexes:
                    if lowered in index:
                        actual = os.path.relpath(os.path.join(base, index[lowered]), root)
                        break
            if actual is None:
                # Unresolvable here for some other reason (an -isystem path, a
                # generated header, a platform SDK). Not this check's business.
                continue

            line = text.count("\n", 0, match.start()) + 1
            findings.append((os.path.relpath(path, root), line, inc, actual))

    if not findings:
        print("includes: %d first-party sources, no case-only resolutions" % len(sources))
        return 0

    for path, line, inc, actual in findings:
        print('%s:%d: include "%s" resolves only if case is ignored; the file is %s'
              % (path, line, inc, actual), file=sys.stderr)
    print("", file=sys.stderr)
    print("%d include(s) that build on macOS/Windows and fail on Linux." % len(findings),
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
