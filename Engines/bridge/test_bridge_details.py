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


def test_stream_options_map_extras():
    import mediapull_bridge as bridge

    request = {"video": {"format": "bv*+ba/b"}, "extras": {
        "playlist": True, "playlist_items": "1-5", "max_downloads": 3, "date_after": "20260101", "rate_limit": 1000000,
        "subtitles": ["en", "fr"], "auto_subtitles": True, "thumbnail": True, "description": True}}
    options = bridge.stream_options(request, "/tmp/staging", None, lambda info: None)
    assert options["noplaylist"] is False
    assert options["playlist_items"] == "1-5"
    assert options["max_downloads"] == 3
    assert options["ratelimit"] == 1000000
    assert options["subtitleslangs"] == ["en", "fr"] and options["writeautomaticsub"] is True
    assert options["writethumbnail"] and options["writedescription"]
    assert str(options["daterange"].start) == "2026-01-01"
    single = bridge.stream_options({"video": {}}, "/tmp/staging", None, lambda info: None)
    assert single["noplaylist"] is True and "writesubtitles" not in single
    assert single["hls_prefer_native"] is True and single["external_downloader"] == {}
    capture = Capture()
    bridge.EMITTER = capture
    assert single["match_filter"]({"id": "x", "is_live": True}) == "Live streams can't be saved."
    assert single["match_filter"]({"id": "y", "live_status": "was_live"}) is None
    assert capture.events and capture.events[0][1]["code"] == "unavailable"



def test_profile_parts_are_read_without_network():
    from gallery_dl import extractor

    choices, defaults = bridge.content_choices(extractor.find("https://x.com/someone"))
    assert {"media", "tweets", "likes"} <= set(choices) and defaults == ["timeline"], (choices, defaults)
    choices, defaults = bridge.content_choices(extractor.find("https://www.deviantart.com/someone"))
    assert "scraps" in choices and defaults == ["gallery"], (choices, defaults)
    assert bridge.content_choices(extractor.find("https://www.flickr.com/photos/someone/")) == ([], [])


def test_site_choices_reach_gallery_dl_and_unknown_switches_do_not():
    from gallery_dl import config

    with tempfile.TemporaryDirectory() as staging:
        bridge.configure_gallery_dl({"category": "twitter", "include": ["media", "likes"], "cookies": "/tmp/c.txt",
                                     "user_agent": "Browser/1.0",
                                     "site_options": {"retweets": True, "auto-watch": True, "videos": "yes"}}, staging)
    section = config.get(("extractor",), "twitter")
    assert section["include"] == ["media", "likes"] and section["retweets"] is True, section
    assert "auto-watch" not in section and "videos" not in section, section
    assert section["user-agent"] == "Browser/1.0"
    with tempfile.TemporaryDirectory() as staging:
        bridge.configure_gallery_dl({"category": "tumblr", "site_keys": {"api-key": " k ", "password": "x", "api-secret": 3}}, staging)
    tumblr = config.get(("extractor",), "tumblr")
    assert tumblr["api-key"] == "k" and "password" not in tumblr and "api-secret" not in tumblr, tumblr
    processors = config.get((), "extractor")["postprocessors"]
    assert processors[0]["name"] == "ugoira" and processors[0]["extension"] == "mp4"


def test_messages_never_carry_query_secrets():
    text = bridge._clean("HttpError: '401 Unauthorized' for 'https://api.example.com/v1/posts?api_key=K1&user_id=42&sig=S3' "
                         "(https://cdn.example.com/a.jpg?token=T4#x) sessionid=abc; 'access_token': 'T5' password=P6")
    for secret in ("K1", "42", "S3", "T4", "T5", "P6", "abc"):
        assert secret not in text, text
    assert "https://api.example.com/v1/posts?REDACTED" in text and "401 Unauthorized" in text, text
    assert bridge._clean("no 'token' in the response") == "no 'token' in the response"


def test_checkpoints_belong_to_instagram_only():
    import logging

    capture = Capture()
    bridge.EMITTER = capture
    handler = bridge.EventLogHandler()

    def log(name, message):
        handler.emit(logging.LogRecord(name, logging.ERROR, __file__, 1, message, None, None))

    def reset(instagram):
        bridge.STATE.update(checkpoint=None, errors=[], instagram=instagram)

    reset(False)
    log("deviantart", "HttpError: '429 Too Many Requests' for 'https://www.deviantart.com/api'")
    log("deviantart", "Redirect to login page")
    assert bridge.STATE["checkpoint"] is None and len(bridge.STATE["errors"]) == 2, bridge.STATE
    reset(False)
    log("instagram", "HttpError: '429 Too Many Requests' for 'https://www.instagram.com/api'")
    assert bridge.STATE["checkpoint"]["kind"] == "rate_limit", bridge.STATE
    reset(True)
    log("downloader.http", "'429 Too Many Requests' for 'https://scontent.cdninstagram.com/a.jpg'")
    assert bridge.STATE["checkpoint"]["kind"] == "rate_limit", bridge.STATE
    reset(False)
    with tempfile.TemporaryDirectory() as staging:
        bridge.configure_gallery_dl({"url": "https://www.instagram.com/someone/"}, staging)
        assert bridge.STATE["instagram"] is True
        bridge.configure_gallery_dl({"url": "https://www.deviantart.com/someone"}, staging)
        assert bridge.STATE["instagram"] is False
    reset(False)


def test_browser_user_agent_goes_with_cookies():
    from gallery_dl import config

    with tempfile.TemporaryDirectory() as staging:
        bridge.configure_gallery_dl({"url": "https://www.deviantart.com/someone", "cookies": "/tmp/c.txt", "user_agent": "Browser/1.0"},
                                    staging)
        assert config.get(("extractor",), "user-agent") == "Browser/1.0"
        bridge.configure_gallery_dl({"url": "https://www.instagram.com/someone/", "cookies": "/tmp/c.txt", "user_agent": "Browser/1.0"},
                                    staging)
        assert config.get(("extractor",), "user-agent") is None
        assert "user-agent" not in config.get(("extractor",), "instagram")
        bridge.configure_gallery_dl({"url": "https://www.deviantart.com/someone", "user_agent": "Browser/1.0"}, staging)
        assert config.get(("extractor",), "user-agent") is None
        bridge.configure_gallery_dl({"category": "reddit", "cookies": "/tmp/c.txt", "user_agent": "Browser/1.0",
                                     "site_keys": {"client-id": "id"}}, staging)
        assert config.get(("extractor",), "reddit")["user-agent"].startswith("macos:mediapull")
    bridge.STATE["instagram"] = False


def test_signal_path_writes_a_parsable_line_without_the_lock():
    read_fd, write_fd = os.pipe()
    emitter = bridge.Emitter(os.fdopen(write_fd, "w", buffering=1, encoding="utf-8"))
    with emitter.lock:
        emitter.stream.write('{"v": 1, "seq": 1, "type": "lo')
        emitter.emit_last("done", status="cancelled", counts={})
    emitter.stream.close()
    with os.fdopen(read_fd, encoding="utf-8") as handle:
        lines = handle.read().splitlines()
    assert json.loads(lines[1]) == {"v": 1, "seq": 1, "type": "done", "status": "cancelled", "counts": {}}, lines



def test_undated_items_are_kept_and_never_end_a_listing():
    import datetime

    from gallery_dl import dt

    tracker = bridge.KnownTracker(set(), 0)
    tracker.date_from = datetime.datetime(2026, 1, 1)
    tracker.date_to = datetime.datetime(2026, 12, 31)
    # A profile picture has no date: gallery-dl gives a false datetime of year 1, which must not read as "too old".
    assert tracker.outside_dates({"date": dt.NONE}, "posts") is False
    assert tracker.outside_dates({"post_date": dt.NONE, "date": dt.NONE}, "avatar") is False
    assert tracker.outside_dates({"date": datetime.datetime(2026, 6, 1)}, "posts") is False
    assert "date" not in bridge.item_meta("https://example.com/a.jpg", {"date": dt.NONE, "category": "instagram"})


def test_each_file_of_a_post_has_its_own_key():
    first = bridge.item_key({"category": "pixiv", "id": 1234, "num": 1}, "https://example.com/a.jpg")
    second = bridge.item_key({"category": "pixiv", "id": 1234, "num": 2}, "https://example.com/b.jpg")
    assert first == "pixiv:1234:1" and second == "pixiv:1234:2", (first, second)
    assert bridge.item_key({"category": "site", "id": 99}, "https://example.com/c.jpg") == "site:99"
    assert bridge.item_key({"category": "instagram", "media_id": "55", "num": 3}, "u") == "ig:55"


def test_events_are_valid_json_even_with_nan_or_huge_numbers():
    class Stream:
        def __init__(self):
            self.text = ""

        def write(self, text):
            self.text += text

        def flush(self):
            pass

    stream = Stream()
    emitter = bridge.Emitter(stream)
    emitter.emit("file", path="/x", bytes=float("nan"),
                 meta={"width": float("inf"), "list": [float("-inf"), 1.5], "size": 10 ** 30})
    event = json.loads(stream.text)
    assert event["bytes"] is None and event["meta"]["width"] is None, event
    assert event["meta"]["list"] == [None, 1.5] and event["meta"]["size"] == 10 ** 30, event
    assert "NaN" not in stream.text and "Infinity" not in stream.text


def test_folder_names_from_site_metadata_never_leave_the_job_folder():
    import tempfile as _tempfile
    from gallery_dl import config, extractor, path

    bridge.harden_gallery_dl_paths()
    with _tempfile.TemporaryDirectory() as root:
        job = os.path.join(root, "job")
        config.clear()
        config.set((), "extractor", {"base-directory": job, "directory": ["{category}", "{path:I}", "{title}"],
                                     "filename": "{name}.{extension}"})
        found = extractor.find("https://example.org/a.jpg")
        if hasattr(found, "initialize"):
            found.initialize()
        fmt = path.PathFormat(found)
        kwdict = {"category": "site", "path": ["..", "..", ".", "Elsewhere"], "title": " .. ", "name": "../../x",
                  "extension": "jpg"}
        fmt.set_directory(kwdict)
        fmt.set_filename(kwdict)
        fmt.build_path()
        real = os.path.realpath(fmt.realpath)
        assert real.startswith(os.path.realpath(job) + os.sep), real
        config.clear()

def test_a_taller_video_in_another_codec_is_noted():
    info = {"height": 1080, "formats": [{"vcodec": "avc1", "height": 1080}, {"vcodec": "vp9", "height": 2160},
                                        {"vcodec": "none", "height": None}]}
    assert bridge.higher_resolution(info) == "2160p"
    assert bridge.video_meta(info)["higher_res_available"] == "2160p"
    assert bridge.higher_resolution({"height": 2160, "formats": [{"vcodec": "vp9", "height": 2160}]}) is None
    assert bridge.higher_resolution({"height": None, "formats": []}) is None

def test_a_sites_own_request_interval_is_never_undercut():
    from gallery_dl import config

    with tempfile.TemporaryDirectory() as staging:
        bridge.configure_gallery_dl({"url": "https://www.reddit.com/user/someone", "pacing": {"request_delay": [0.1, 0.2]}}, staging)
        interval = config.get(("extractor", "reddit"), "sleep-request")
        assert interval and interval[0] >= 0.6, interval
        # A site only reached through another site's page keeps its own pace too (audit round 1, A12).
        others = [category for category, own in bridge.site_request_intervals().items() if category != "reddit"]
        assert others
        queued = config.get(("extractor", others[0]), "sleep-request")
        assert queued and queued[-1] >= bridge.site_request_intervals()[others[0]][1], queued
    config.clear()

def test_instagram_is_gentle_by_default_and_never_retried():
    from gallery_dl import config

    with tempfile.TemporaryDirectory() as staging:
        bridge.configure_gallery_dl({"url": "https://www.instagram.com/someone/"}, staging)
        assert config.get(("extractor",), "sleep-request") == [8.0, 15.0]
        assert config.get(("extractor", "instagram"), "retries") == 0
        assert config.get(("extractor", "instagram"), "sleep-429") == 0
    config.clear()

def test_posts_are_known_by_post_and_number_but_stories_only_by_media_id():
    known = {"igp:3001:2", "igp:9000:1"}
    tracker = bridge.KnownTracker(known, 0)
    post_item = {"category": "instagram", "subcategory": "posts", "post_id": "3001", "num": 2, "media_id": "77"}
    assert tracker.observe(post_item, bridge.item_key(post_item, "u")) is True
    story = {"category": "instagram", "subcategory": "stories", "post_id": "9000", "num": 1, "media_id": "88"}
    assert tracker.observe(story, bridge.item_key(story, "u")) is False
    other = {"category": "instagram", "subcategory": "posts", "post_id": "3001", "num": 3, "media_id": "78"}
    assert tracker.observe(other, bridge.item_key(other, "u")) is False


def test_files_from_the_stories_tray_and_saved_posts_say_so():
    """Audit round 1 (A1): gallery-dl lists others' stories and saved posts through child extractors."""
    bridge.STATE["collection"] = bridge.collection_of("https://www.instagram.com/stories/me/")
    meta = bridge.item_meta("x", {"category": "instagram", "subcategory": "stories", "username": "bob"})
    assert meta["collection"] == "stories-tray"
    bridge.STATE["collection"] = bridge.collection_of("https://www.instagram.com/alice/saved/")
    assert bridge.item_meta("x", {"category": "instagram", "subcategory": "posts"})["collection"] == "saved"
    bridge.STATE["collection"] = bridge.collection_of("https://www.instagram.com/alice/")
    assert "collection" not in bridge.item_meta("x", {"category": "instagram", "subcategory": "posts"})
    # Whole path segments only (audit 2, A2-m2): @meg's story is not the tray, a query is not a path.
    assert bridge.collection_of("https://www.instagram.com/stories/meg/3512/") is None
    assert bridge.collection_of("https://www.instagram.com/p/ABC/?x=/saved/") is None
    bridge.STATE["collection"] = None



def test_the_known_run_marks_the_listing_as_walked():
    """D-87: an early stop at the folder's known posts is a complete walk of what was missing."""
    from gallery_dl import exception

    tracker = bridge.KnownTracker({"ig:1", "ig:2"}, 2)
    for number in (1, 2):
        tracker.observe({"category": "instagram", "subcategory": "posts", "post_id": str(number)}, f"ig:{number}")
    try:
        tracker.observe({"category": "instagram", "subcategory": "posts", "post_id": "3"}, "ig:3")
    except exception.StopExtraction:
        pass
    assert tracker.stopped


def test_the_posts_listing_ends_after_a_full_walk():
    """Audit 4 (A4-M1): gallery-dl's GraphQL paginator ends without clearing its cursor; the end is read from the posts
    generator running out, with the real paginator. A walk that stops part way does not end the listing."""
    import json as _json
    from gallery_dl.extractor import instagram

    bridge.EMITTER = Capture()
    bridge.patch_instagram()

    def walk(pages, stop_after=None):
        extr = instagram.InstagramPostsExtractor.from_url("https://www.instagram.com/alice/posts/")
        extr._cursor = None
        extr.csrf_token = "x"
        queue = list(pages)

        class Response:
            def __init__(self, text):
                self.text = text

        extr.request = lambda url, **kw: Response(_json.dumps({"data": {"conn": queue.pop(0)}}))
        api = instagram.InstagramAPI.__new__(instagram.InstagramAPI)
        api.extractor = extr
        api.exc = None
        api._prepare_graphql = lambda *a: ({}, {"doc_id": "1", "variables": "{}"})

        class Feed:
            def user_feed(self, _item):
                return api._pagination_graphql("PolarisProfilePostsTabContentQuery_connection", {"after": None}, "conn")

        extr.api = Feed()
        for number, _post in enumerate(extr.posts(), 1):
            if stop_after and number >= stop_after:
                break
        return getattr(extr, "_mediapull_listing_end", False)

    pages = [
        {"edges": [{"node": {"id": i}} for i in range(12)], "page_info": {"has_next_page": True, "end_cursor": "C1"}},
        {"edges": [{"node": {"id": i}} for i in range(12, 20)], "page_info": {"has_next_page": False, "end_cursor": None}},
    ]
    assert walk(pages) is True
    assert walk(pages, stop_after=5) is False


def test_single_failed_files_leave_the_pull_partial():
    """Audit 4 (A4-M3): files that failed one by one are fetched again by Retry Failed; a listing that broke off is not."""
    saved = dict(bridge.STATE)
    try:
        bridge.STATE.update(download_failed=2, extraction_failed=False, violations=0)
        assert bridge.pull_status(0) == "completed"
        assert bridge.pull_status(4) == "partial"
        assert bridge.pull_status(4 | 1) == "failed"
        bridge.STATE["extraction_failed"] = True
        assert bridge.pull_status(4) == "failed"
        bridge.STATE.update(download_failed=0, extraction_failed=False)
        assert bridge.pull_status(4) == "failed", "an HTTP error of the listing alone is a failure"
    finally:
        bridge.STATE.clear()
        bridge.STATE.update(saved)


def test_the_account_is_reported_when_its_name_is_looked_up():
    """Audit 5 (A5-M1): every listing of an account looks the name up first (the real InstagramAPI.user); the account and
    its id are reported then, once, before any file, whatever content was chosen."""
    from gallery_dl.extractor import instagram

    capture = Capture()
    bridge.EMITTER = capture
    bridge.patch_instagram()
    extr = instagram.InstagramPostsExtractor.from_url("https://www.instagram.com/alice/posts/")
    api = instagram.InstagramAPI.__new__(instagram.InstagramAPI)
    api.extractor = extr
    api.exc = None
    api.user_by_web = lambda handle: {"id": "4242", "username": handle}
    api.user_by_id = lambda user_id: {"id": user_id, "username": "alice", "full_name": "Alice", "media_count": 3}
    extr._assign_user = lambda user: user
    for _ in range(2):
        assert api.user("alice")["id"] == "4242"
    accounts = [fields for kind, fields in capture.events if kind == "account"]
    assert len(accounts) == 1, capture.events
    assert accounts[0]["user_id"] == "4242" and accounts[0]["username"] == "alice", accounts


def test_playlist_videos_that_fail_are_counted():
    """Audit 11 (A11-M3), audit 12 (A12-M3): in a playlist a video that fails is a failed file, one that can never be
    downloaded is skipped, and outside a playlist errors stay log lines (the download itself fails)."""
    capture = Capture()
    bridge.EMITTER = capture
    saved = list(bridge.STATE.get("errors") or [])
    try:
        bridge.STATE["errors"] = []
        logger = bridge.StreamLogger(True)
        logger.error("ERROR: [site] abc: HTTP Error 500")
        logger.error("ERROR: [site] def: Private video. Sign in if you've been granted access")
        bridge.StreamLogger(False).error("ERROR: something")
    finally:
        bridge.STATE["errors"] = saved
    errors = [fields for kind, fields in capture.events if kind == "error"]
    assert [e["code"] for e in errors] == ["download_failed", "unavailable"], errors
    assert all(e["fatal"] is False for e in errors)


def test_only_videos_that_can_never_download_are_skipped():
    """Audit 13 (A13-M1, C13-m5): a rate limit, members-only and age-checked videos are failures Retry offers; private
    and removed videos are skipped."""
    rate = ("ERROR: [youtube] abc: Video unavailable. This content isn't available, try again later. The current session "
            "has been rate-limited by YouTube for up to an hour.")
    assert bridge.problem_code(rate) == "download_failed"
    assert bridge.problem_code("ERROR: [youtube] abc: Sign in to confirm your age.") == "download_failed"
    assert bridge.problem_code("ERROR: [youtube] abc: Join this channel to get access to members-only content") == "download_failed"
    assert bridge.problem_code("ERROR: [youtube] abc: Private video. Sign in if you've been granted access") == "unavailable"
    assert bridge.problem_code("ERROR: [youtube] abc: Video unavailable. This video has been removed by the uploader") == "unavailable"
    assert bridge.problem_code("ERROR: HTTP Error 500") == "download_failed"


def test_a_retry_keeps_the_limit():
    """Audit 13 (A13-M2): a Retry asks yt-dlp only for what is left of "At most"."""
    request = {"extras": {"playlist": True, "max_downloads": 10, "skip_ids": [str(n) for n in range(8)]}}
    options = bridge.stream_options(request, "/tmp/staging", bridge.StreamLogger(True), lambda info: None)
    assert options["max_downloads"] == 2, options["max_downloads"]


def test_a_retry_skips_saved_videos():
    """Audit 12 (A12-M3): a playlist's Retry Failed downloads only the videos not saved yet."""
    check = bridge.skip_saved(bridge.refuse_live_streams, {"abc"})
    assert check({"id": "abc"}) == "Already saved."
    assert check({"id": "xyz"}) is None


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print("ok  ", test.__name__)
    print(f"{len(tests)} tests, 0 failures")

