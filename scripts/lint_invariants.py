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
        "why": "listings and reads block the main actor; run them off the main actor (a detached task or @concurrent)",
        "pattern": re.compile(r"(?<![A-Za-z])(contentsOfDirectory|enumerator)\(|Data\(contentsOf"),
        "paths": [APP],
        "skip_files": ["MediaPull/App/SelfTest.swift"],
    },
    {
        # D-107: moves, copies and trashing of the person's files go through FileOps (off the main actor, metadata file
        # with its media, never overwriting); only MediaPull's own data in Application Support may be moved here.
        "id": "file-write",
        "why": "move, copy and trash files through FileOps (D-107); only MediaPull's own app data may use FileManager directly",
        "pattern": re.compile(r"(?<![A-Za-z])(moveItem|copyItem|replaceItem|trashItem|copyfile)\(|renamex_np"),
        "paths": [APP],
        "skip_files": ["MediaPull/App/SelfTest.swift"],
        "allow_as": "app-data",
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

# R-510: Apple's frameworks and the project's own modules only (no analytics, crash-reporting or update SDKs). Adding a
# module here is a decision for the spec (CLAUDE.md: no third-party Swift packages).
APPLE_AND_OWN = {
    "AVFoundation", "AVKit", "Accelerate", "AppKit", "CoreGraphics", "CoreML", "CoreServices", "CryptoKit", "Foundation",
    "IOKit", "ImageIO", "MapKit", "Observation", "PackageDescription", "Quartz", "QuartzCore", "Security", "SwiftData", "SwiftUI",
    "Synchronization", "UniformTypeIdentifiers", "UserNotifications", "VideoToolbox", "Vision", "WebKit", "XCTest", "os",
    "MediaPullAnalysis", "MediaPullBrowser", "MediaPullCore", "MediaPullEngines", "MediaPullLibrary", "MediaPullMedia",
    "MediaPullNet", "MediaPullStore",
}
RULES.append({
    "id": "framework",
    "why": "only Apple frameworks and MediaPull's own modules may be imported (R-510)",
    "pattern": re.compile(r"^\s*(?:@testable\s+)?import\s+(?!(?:" + "|".join(sorted(APPLE_AND_OWN)) + r")\b)\w+"),
    "paths": [APP, KIT, "MediaPullKit/Tests"],
})
RULES.append({
    "id": "framework",
    "why": "the package has no third-party dependencies (CLAUDE.md, R-510)",
    "pattern": re.compile(r"\.package\("),
    "paths": ["MediaPullKit"],
    "skip_files": [],
})

ALLOW = re.compile(r"lint:allow\s+((?:[\w-]+\s+)+)\S")
RULE_IDS = {"shortcut", "main-io", "unsafe-int", "icon-label", "silent-write", "framework", "app-data"}
# Markers that must sit on (or just above) a line their rule matches: an exception that excuses nothing is removed, so the
# count of exceptions stays the count of real ones (D-107).
CHECKED_MARKERS = {"main-io": "main-io", "app-data": "file-write"}


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
                if allowed(lines, index, rule.get("allow_as", rule["id"])):
                    continue
                hits.append(f"{path}:{index + 1}: {stripped}")
        if hits:
            problems += len(hits)
            print(f"error: [{rule['id']}] {rule['why']}:")
            for hit in hits:
                print("  ", hit)
    patterns = {rule["id"]: rule["pattern"] for rule in RULES}
    stale = []
    for path in files([APP]):
        if path == "MediaPull/App/SelfTest.swift":
            continue
        with open(os.path.join(ROOT, path), encoding="utf-8") as handle:
            lines = handle.read().splitlines()
        for index, line in enumerate(lines):
            for match in ALLOW.finditer(line):
                for word in match.group(1).split():
                    rule_id = CHECKED_MARKERS.get(word)
                    if rule_id is None:
                        continue
                    covered = lines[index : index + 2]
                    if not any(patterns[rule_id].search(text) and not text.strip().startswith("//") for text in covered):
                        stale.append(f"{path}:{index + 1}: {line.strip()}")
    if stale:
        problems += len(stale)
        print("error: [stale-marker] a lint:allow marker for main-io or app-data excuses nothing on its line or the next; remove it:")
        for hit in stale:
            print("  ", hit)
    if problems:
        print(f"{problems} invariant problem(s). Fix them, or mark a justified exception with // lint:allow <rule> <reason>.")
        sys.exit(1)
    print("Invariant lints passed.")


if __name__ == "__main__":
    main()
