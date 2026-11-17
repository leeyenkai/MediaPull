#!/usr/bin/env python3
"""Invariant lints (SPEC section 25): patterns that earlier audits found again and again, checked on every run.

A line may be exempted with a marker on the same line or the line above:

    // lint:allow <rule> <reason>

The reason is required, so every exception is explained where it is made.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP = "MediaPull"
KIT = "MediaPullKit/Sources"

RULES = [
    {
        "id": "shortcut",
        "why": "Return and Escape shortcuts fire while typing in the web page or in a hidden section (D-47)",
        "pattern": re.compile(r"keyboardShortcut\(\.(defaultAction|cancelAction)"),
        "paths": [APP],
    },
    {
        "id": "main-io",
        "why": "file moves, copies, listings and reads block the main actor; run them off the main actor (LibraryModel.offMain or a detached task)",
        "pattern": re.compile(
            r"(?<![A-Za-z])(moveItem|copyItem|contentsOfDirectory|enumerator)\(|Data\(contentsOf|\.trashItem\("
        ),
        "paths": [APP],
        "skip_files": ["MediaPull/App/SelfTest.swift"],
    },
    {
        "id": "unsafe-int",
        "why": "Int64(Double) and Int(Double) trap on NaN, infinity and large values; use SafeNumber",
        "pattern": re.compile(r"\bInt(64)?\((?!exactly|clamping|truncatingIfNeeded)[^)]*\.double\b|\.double\.map \{ Int"),
        "paths": [APP, KIT],
    },
    {
        "id": "icon-label",
        "why": "icon-only buttons need an accessibility label (R-2402)",
        "pattern": re.compile(r"label: \{ Image\(systemName"),
        "paths": [APP],
        "needs_nearby": re.compile(r"accessibilityLabel"),
        "window": 4,
    },
    {
        "id": "silent-write",
        "why": "a write that fails silently loses the person's data; report it, or say why it may fail quietly",
        "pattern": re.compile(r"try\? .*(\.write\(to|[^e]moveItem\(|\.moveItem\(|copyItem\(|replaceItem)"),
        "paths": [APP, KIT],
        "skip_files": ["MediaPull/App/SelfTest.swift"],
    },
]

ALLOW = re.compile(r"lint:allow\s+((?:[\w-]+\s+)+)\S")
RULE_IDS = {"shortcut", "main-io", "unsafe-int", "icon-label", "silent-write"}


def files(paths):
    for folder in paths:
        for base, _, names in os.walk(os.path.join(ROOT, folder)):
            for name in names:
                if name.endswith(".swift"):
                    yield os.path.relpath(os.path.join(base, name), ROOT)


def allowed(lines, index, rule_id):
    for candidate in (lines[index], lines[index - 1] if index > 0 else ""):
        for match in ALLOW.finditer(candidate):
            named = [word for word in match.group(1).split() if word in RULE_IDS]
            if rule_id in named:
                return True
    return False


def main():
    problems = 0
    for rule in RULES:
        hits = []
        for path in files(rule["paths"]):
            if path in rule.get("skip_files", []):
                continue
            with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
                lines = handle.read().splitlines()
            for index, line in enumerate(lines):
                stripped = line.strip()
                if stripped.startswith("//") or not rule["pattern"].search(line):
                    continue
                if "needs_nearby" in rule:
                    window = "\n".join(lines[index : index + rule["window"] + 1])
                    if rule["needs_nearby"].search(window):
                        continue
                if allowed(lines, index, rule["id"]):
                    continue
                hits.append(f"{path}:{index + 1}: {stripped}")
        if hits:
            problems += len(hits)
            print(f"error: [{rule['id']}] {rule['why']}:")
            for hit in hits:
                print("  ", hit)
    if problems:
        print(f"{problems} invariant problem(s). Fix them, or mark a justified exception with // lint:allow <rule> <reason>.")
        sys.exit(1)
    print("Invariant lints passed.")


if __name__ == "__main__":
    main()
