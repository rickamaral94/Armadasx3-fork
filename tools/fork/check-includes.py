#!/usr/bin/env python3
"""Fail when an #include only resolves on a case-insensitive filesystem.

ARMSX3 and RPCS3 are developed largely on macOS and Windows, where

    #include "Emu/system.h"      (the file is Emu/System.h)
    #include <gl/gl.h>           (the file is savers/compat/GL/gl.h)

both find their target. On Linux -- every CI runner, and the Android cross
build -- neither does, and the build dies forty to fifty minutes in with a
one-line "file not found" that says nothing about why it worked for the author.
Both of those are real bugs this fork hit, one per build, an hour apart.

The rule, which is the whole design: an include is reported only when the
repository contains a file at that path suffix with DIFFERENT case and none
with the same case. Nothing else is judged. The tree has ~120 includes that
resolve through -isystem paths, generated headers or platform SDKs (Qt, ffmpeg,
protobuf, the NDK, the Windows SDK); a checker with opinions about those would
be wrong constantly and get ignored.
"""

import os
import re
import sys

# First-party sources. 3rdparty and git submodules are excluded: not ours to
# fix, and those projects build on Linux already.
SOURCE_DIRS = (
    "rpcs3",
    "Utilities",
    "util",
    "android/src",
    "android/armsx3-ui/app/src/main/cpp",
)

SOURCE_SUFFIXES = (".cpp", ".cc", ".c", ".h", ".hpp", ".inl")
SKIP_DIRS = {".git", "build", "build-a13", "build-a14", "build-a15", ".cxx"}

# Both spellings, keeping which one was used: it decides how a bare name is
# treated below. <> and "" differ in search order, not in case sensitivity.
INCLUDE_RE = re.compile(r'^[ \t]*#[ \t]*include[ \t]+(?:<([^>]+)>|"([^"]+)")', re.M)


def walk(base):
    """Yield files under base, skipping build output and nested git repos."""
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames[:] = [
            d for d in dirnames
            if d not in SKIP_DIRS
            and not os.path.exists(os.path.join(dirpath, d, ".git"))
        ]
        for name in filenames:
            yield os.path.join(dirpath, name)


def main():
    root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))

    # basename (lowercased) -> repo-relative paths, with "/" separators.
    by_name = {}
    for path in walk(root):
        rel = os.path.relpath(path, root).replace(os.sep, "/")
        by_name.setdefault(os.path.basename(rel).lower(), []).append(rel)

    sources = []
    for src_dir in SOURCE_DIRS:
        base = os.path.join(root, src_dir)
        if os.path.isdir(base):
            sources += [p for p in walk(base) if p.endswith(SOURCE_SUFFIXES)]

    findings = []
    for path in sorted(sources):
        with open(path, encoding="utf-8", errors="replace") as handle:
            text = handle.read()

        own_dir = os.path.dirname(path)

        for match in INCLUDE_RE.finditer(text):
            angled = match.group(1) is not None
            inc = (match.group(1) or match.group(2)).replace("\\", "/")

            if "/" not in inc:
                # A bare name matched against every file in the tree is pure
                # noise: <elf.h> is libc's, <config.h> is autotools', and both
                # collide with unrelated headers here. A bare quoted name does
                # resolve next to its own file, so that much is checkable.
                if angled:
                    continue
                actual = None
                for name in os.listdir(own_dir):
                    if name == inc:
                        actual = None
                        break
                    if name.lower() == inc.lower():
                        actual = os.path.relpath(os.path.join(own_dir, name), root)
                if actual is None:
                    continue
            else:
                candidates = by_name.get(os.path.basename(inc).lower(), ())
                if not candidates:
                    continue  # not a file this repository carries at all

                suffix = "/" + inc
                # Same case somewhere in the tree: whatever the compiler ends
                # up picking, case is not the problem.
                if any(c == inc or c.endswith(suffix) for c in candidates):
                    continue

                lowered = suffix.lower()
                actual = next(
                    (c for c in candidates
                     if c.lower() == inc.lower() or c.lower().endswith(lowered)),
                    None,
                )
                if actual is None:
                    continue

            line = text.count("\n", 0, match.start()) + 1
            findings.append((os.path.relpath(path, root), line, inc, actual))

    if not findings:
        print("includes: %d first-party sources, no case-only resolutions" % len(sources))
        return 0

    for path, line, inc, actual in findings:
        print("%s:%d: #include %s resolves only if case is ignored; the file is %s"
              % (path, line, inc, actual), file=sys.stderr)
    print("", file=sys.stderr)
    print("%d include(s) that build on macOS/Windows and fail on Linux." % len(findings),
          file=sys.stderr)
    return 1


if __name__ == "__main__":
    sys.exit(main())
