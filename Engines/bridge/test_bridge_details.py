"""Tests for account details in the bridge (SPEC R-1105a). Run with the bundled interpreter:

    python3 -I Engines/bridge/test_bridge_details.py <site-packages>
"""

import csv
import json
import os
import sys
import tempfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
if len(sys.argv) > 1:
    sys.path.insert(1, sys.argv.pop(1))

import mediapull_bridge as bridge  # noqa: E402


class Capture:
    def __init__(self):
        self.events = []

    def emit(self, _event_type, **fields):
        self.events.append((_event_type, fields))


def test_lists_hold_names_and_are_written_as_csv():
    capture = Capture()
    bridge.EMITTER = capture
    bridge.DETAILS["lists"].clear()
    bridge.record_list_entry("followers", "https://www.instagram.com/first.user/",
                             {"username": "first.user", "full_name": "First", "pk": 11, "is_private": True})
    bridge.record_list_entry("followers", "https://www.instagram.com/second_user/", {})
    with tempfile.TemporaryDirectory() as staging:
        bridge.write_details(staging)
        path = os.path.join(staging, "followers.csv")
        with open(path, encoding="utf-8") as handle:
            rows = list(csv.DictReader(handle))
    assert [row["username"] for row in rows] == ["first.user", "second_user"], rows
    assert rows[0]["id"] == "11" and rows[0]["is_private"] == "True"
    assert capture.events == [("document", {"kind": "followers", "path": path, "count": 2})], capture.events


def test_profile_is_kept_whole_without_private_keys():
    capture = Capture()
    bridge.EMITTER = capture
    bridge.DETAILS["lists"].clear()
    bridge.DETAILS["profile"] = bridge.plain({"username": "acct", "biography": "Hi", "_extractor": object(),
                                              "bio_links": [{"url": "https://example.com"}], "counts": {"media": 3}})
    with tempfile.TemporaryDirectory() as staging:
        bridge.write_details(staging)
        with open(os.path.join(staging, "profile.json"), encoding="utf-8") as handle:
            profile = json.load(handle)
    bridge.DETAILS["profile"] = None
    assert profile == {"bio_links": [{"url": "https://example.com"}], "biography": "Hi", "counts": {"media": 3}, "username": "acct"}
    assert capture.events[0][0] == "document" and capture.events[0][1]["kind"] == "profile"


def test_engine_cache_stays_in_memory():
    with tempfile.TemporaryDirectory() as staging:
        bridge.configure_gallery_dl({"url": "https://www.instagram.com/example/"}, staging)
        from gallery_dl import cache
        assert not cache.path(), cache.path()


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print("ok  ", test.__name__)
    print(f"{len(tests)} tests, 0 failures")
