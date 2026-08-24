#!/usr/bin/env python3
# Copyright 2026 Serge Rabyking
# SPDX-License-Identifier: Apache-2.0 WITH SHL-2.1
"""Every source file states this repository's licence, and the right one.

A licence header applied inconsistently is worse than useless: a reviewer
cannot tell whether a file without one was an oversight or was
deliberately contributed under other terms, and that ambiguity is what a
licence audit stops on. A file carrying the WRONG identifier is worse --
it is a claim rather than a gap.

The sibling Python projects read this identifier from their packaging
metadata, so it has one owner there. This repository publishes no
package, so the identifier is stated here instead -- once -- and the
licence files that back it are checked to exist, so the claim and the
texts cannot drift apart.

    python3 scripts/checklicence.py
"""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent.parent

# Hardware, so the Apache grant carries Solderpad's exception for the
# things a licence written for software does not cover -- making,
# having made, and the silicon itself.
LICENCE = "Apache-2.0 WITH SHL-2.1"
BACKING = ("LICENSE", "LICENSE-APACHE")
SUFFIXES = (".py", ".v", ".sv", ".sh", ".tcl", ".xdc", ".c", ".h",
            ".core")
# JSON carries no comment syntax, so pipeline.json, board.json and
# design.json cannot hold a header; they are covered by the LICENSE
# files instead. Named here so the gap is a decision, not an oversight.
NO_COMMENT_SYNTAX = (".json",)


def main() -> int:
    problems = []
    for name in BACKING:
        if not (HERE / name).is_file():
            problems.append(f"{name} is missing, but every source file "
                            f"claims {LICENCE}")

    listed = subprocess.run(["git", "-C", str(HERE), "ls-files"],
                            capture_output=True, text=True).stdout.split()
    checked = 0
    for rel in listed:
        if not rel.endswith(SUFFIXES):
            continue
        path = HERE / rel
        if not path.is_file():
            continue
        checked += 1
        head = "".join(path.read_text(encoding="utf-8", errors="replace")
                       .splitlines(True)[:6])
        found = re.search(r"SPDX-License-Identifier:\s*(.+?)\s*"
                          r"(?:-->|\*/)?\s*$", head, re.M)
        if not found:
            problems.append(f"{rel}: no SPDX-License-Identifier in its first "
                            f"lines (expected {LICENCE})")
        elif found.group(1) != LICENCE:
            problems.append(f"{rel}: claims {found.group(1)!r}, but this "
                            f"repository publishes as {LICENCE!r}")

    # A check that finds nothing passes forever.
    if checked < 5:
        problems.append(f"only {checked} source files found; this check is "
                        "not covering the tree it is meant to cover")

    if problems:
        print(f"{len(problems)} licence problem(s):", file=sys.stderr)
        for p in problems:
            print(f"  {p}", file=sys.stderr)
        return 1
    print(f"  licence: OK -- {checked} source files carry {LICENCE}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
