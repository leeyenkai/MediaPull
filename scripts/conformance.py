#!/usr/bin/env python3
"""Checks docs/CONFORMANCE.md against docs/SPEC.md and the code (SPEC section 25).

Every requirement (R-nnn) in the spec must have one row in the ledger with a status:

    built      implemented; "Implemented by" names code and "Proved by" names a test or self-test
    person     implemented; can only be checked by a person (drag and drop, Quick Look, a signed-in pull)
    amended    implemented as amended by the decision named in the note (D-nn)
    dropped    removed from scope by the decision named in the note (D-nn)
    partial    open: partly implemented (the note says what is missing)
    missing    open: not implemented

Names in backticks in "Implemented by" and "Proved by" must exist: a Swift or Python identifier (the last component of
`Type.member`), a repository path, or a self-test flag (`--selftest-...`). With --strict (used by check.sh at release),
open rows fail the check; otherwise they are listed.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATUSES = {"built", "person", "amended", "dropped", "partial", "missing"}
OPEN = {"partial", "missing"}
SOURCE_DIRS = ["MediaPull", "MediaPullKit/Sources", "MediaPullKit/Tests", "Engines/bridge", "scripts"]


def read(path):
    with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
        return handle.read()


def spec_requirements():
    return sorted(set(re.findall(r"\*\*(R-\d+[a-z]?)\*\*", read("docs/SPEC.md"))), key=sort_key)


def sort_key(rid):
    match = re.match(r"R-(\d+)([a-z]?)", rid)
    return (int(match.group(1)), match.group(2))


def source_text():
    chunks = []
    for folder in SOURCE_DIRS:
        for base, _, files in os.walk(os.path.join(ROOT, folder)):
            if "/." in base or "/Fixtures" in base:
                continue
            for name in files:
                if name.endswith((".swift", ".py", ".js", ".sh")):
                    with open(os.path.join(base, name), encoding="utf-8", errors="replace") as handle:
                        chunks.append(handle.read())
    return "\n".join(chunks)


def ledger_rows():
    rows = {}
    problems = []
    for number, line in enumerate(read("docs/CONFORMANCE.md").splitlines(), 1):
        cells = [cell.strip() for cell in line.strip().strip("|").split("|")]
        if len(cells) < 5 or not re.fullmatch(r"R-\d+[a-z]?", cells[0]):
            continue
        rid, status, implemented, proved, note = cells[:5]
        if rid in rows:
            problems.append(f"line {number}: {rid} is listed twice")
        rows[rid] = (number, status, implemented, proved, note)
    return rows, problems


def name_exists(name, text):
    if name.startswith("--selftest"):
        return name in text
    if "/" in name or re.search(r"\.(swift|py|js|sh|json|md)$", name):
        return os.path.exists(os.path.join(ROOT, name))
    last = re.split(r"[.(]", name.rstrip(")"))
    last = [part for part in last if part][-1] if last else name
    return re.search(r"\b" + re.escape(last) + r"\b", text) is not None


def main():
    strict = "--strict" in sys.argv
    required = spec_requirements()
    rows, problems = ledger_rows()
    text = source_text()
    open_rows = []
    for rid in required:
        if rid not in rows:
            problems.append(f"{rid} is in the spec but not in docs/CONFORMANCE.md")
            continue
        number, status, implemented, proved, note = rows[rid]
        if status not in STATUSES:
            problems.append(f"line {number}: {rid} has unknown status '{status}'")
            continue
        if status in ("amended", "dropped") and not re.search(r"D-\d+", note):
            problems.append(f"line {number}: {rid} is {status} but names no decision")
        if status in ("built", "person", "amended") and "`" not in implemented:
            problems.append(f"line {number}: {rid} is {status} but names no code")
        if status == "built" and "`" not in proved:
            problems.append(f"line {number}: {rid} is built but names no test or self-test")
        for name in re.findall(r"`([^`]+)`", implemented + " " + proved):
            if not name_exists(name, text):
                problems.append(f"line {number}: {rid} names `{name}`, which does not exist")
        if status in OPEN:
            open_rows.append(f"{rid} ({status}): {note}")
    for rid in rows:
        if rid not in required:
            problems.append(f"{rid} is in docs/CONFORMANCE.md but not in the spec")
    for problem in problems:
        print("error:", problem)
    if open_rows:
        print(f"{len(open_rows)} requirement(s) open:")
        for row in open_rows:
            print("  ", row)
    if problems or (strict and open_rows):
        sys.exit(1)
    print(f"Conformance: {len(required)} requirements, {len(open_rows)} open.")


if __name__ == "__main__":
    main()
