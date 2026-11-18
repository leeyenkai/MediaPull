"""Downloads through the real bridge and the bundled yt-dlp, with a made-up site and downloader, so nothing reaches the
network. Plain asserts: the bundled Python has no unittest. Arguments: the site-packages folder."""

import os
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
sys.path.insert(1, sys.argv[1])

import mediapull_bridge as bridge  # noqa: E402
import yt_dlp  # noqa: E402
from yt_dlp.extractor.common import InfoExtractor  # noqa: E402
from yt_dlp.utils import DownloadError, ExtractorError  # noqa: E402

SITE = {}
LAST = []


class Capture:
    def __init__(self):
        self.events = []

    # The event's own name is not called "kind": attachment events carry a field of that name (audit 17, A17-m5).
    def emit(self, _event_type, **fields):
        self.events.append((_event_type, fields))

    def emit_last(self, _event_type, **fields):
        self.events.append((_event_type, fields))


class MadeUpIE(InfoExtractor):
    _VALID_URL = r"madeup://(?P<id>.+)"
    IE_NAME = "madeup"

    def _real_extract(self, url):
        video = self._match_id(url)
        if video == "list":
            def entries():
                for name in SITE["videos"]:
                    if SITE.get("page_fails_after") and SITE["videos"].index(name) > SITE["videos"].index(SITE["page_fails_after"]):
                        raise ExtractorError("Unable to download JSON metadata: HTTP Error 500", video_id="list", expected=True)
                    if SITE.get("no_ids"):
                        yield self.url_result("madeup://" + name)
                    else:
                        yield self.url_result("madeup://" + name, MadeUpIE, name)
            return self.playlist_result(entries(), "list", "A list")
        problem = SITE.get("problems", {}).get(video)
        if problem:
            raise ExtractorError(problem, expected=True)
        info = {"id": video, "title": video, "url": "madeup-media://" + video, "ext": "mp4"}
        if SITE.get("subtitles"):
            info["subtitles"] = {lang: [{"url": "madeup-media://sub-" + lang + "-" + video, "ext": "vtt"}]
                                 for lang in SITE.get("languages", ["en"])}
        return info


original_init = yt_dlp.YoutubeDL.__init__


def init(self, *args, **kwargs):
    original_init(self, *args, **kwargs)
    site = MadeUpIE(self)
    self._ies = {"MadeUp": site, **self._ies}
    self._ies_instances = {"MadeUp": site, **self._ies_instances}


def download(self, name, info, subtitle=False, test=False):
    if subtitle and (SITE.get("subtitle_fails") or any(name.endswith("." + lang + ".vtt") for lang in SITE.get("missing", []))):
        raise DownloadError("HTTP Error 429: Too Many Requests")
    os.makedirs(os.path.dirname(name) or ".", exist_ok=True)
    with open(name, "wb") as handle:
        handle.write(b"x")
    return True, True


yt_dlp.YoutubeDL.__init__ = init
yt_dlp.YoutubeDL.dl = download


def run(url, playlist, extras=None, **site):
    SITE.clear()
    SITE.update(site)
    SITE.setdefault("videos", list("abcdef"))
    bridge.STATE["errors"] = []
    bridge.STATE.pop("problems", None)
    bridge.STATE.pop("current_id", None)
    capture = Capture()
    bridge.EMITTER = capture
    request = {"url": url, "staging": tempfile.mkdtemp(), "extras": dict(extras or {}, playlist=playlist), "key": "video:madeup"}
    bridge.op_stream(request)
    LAST[:] = capture.events
    files = [fields["key"].split(":")[-1] for kind, fields in capture.events if kind == "file"]
    errors = [fields for kind, fields in capture.events if kind == "error"]
    return files, errors


def test_a_retry_downloads_what_is_not_saved_yet():
    """D-100 (audit 16, A16-M1): a Retry runs the list again and downloads only the videos not saved yet, within what is
    left of "At most", with ids in the listing or not, and after a page of the listing failed."""
    files, _ = run("madeup://list", True, {"skip_ids": ["a", "c"], "max_downloads": 1})
    assert files == ["b"], files
    files, _ = run("madeup://list", True, {"skip_ids": ["a", "b"], "max_downloads": 2}, no_ids=True)
    assert files == ["c", "d"], files
    files, errors = run("madeup://list", True, {}, page_fails_after="c")
    assert files == ["a", "b", "c"], files
    assert [e["code"] for e in errors if not e["fatal"]] == ["download_failed"], errors
    files, _ = run("madeup://list", True, {"skip_ids": ["a", "b", "c"]})
    assert files == ["d", "e", "f"], files


def test_a_retry_with_everything_saved_is_done():
    """Audit 17 (C17-m3): a Retry that finds every video saved ends done, with no error."""
    files, errors = run("madeup://list", True, {"skip_ids": list("abcdef")})
    assert files == [] and errors == [], (files, errors)
    done = [fields for kind, fields in LAST if kind == "done"]
    assert done and done[-1].get("status") == "completed", done


def test_every_video_of_a_page_asked_for_as_one_is_reported():
    """Audit 16 (A16-M3): a page that turns out to hold several videos reports each one that fails."""
    files, errors = run("madeup://list", False, {}, videos=["a", "b", "c"], problems={"b": "HTTP Error 403"})
    assert files == ["a", "c"], files
    assert [(e["code"], e.get("key")) for e in errors if not e["fatal"]] == [("download_failed", "b")], errors


def test_a_failed_video_is_named_and_the_rest_downloaded():
    """Audit 14 (A14-M1): a video that fails is reported with its id; the others are downloaded up to the limit."""
    files, errors = run("madeup://list", True, {"max_downloads": 3}, problems={"b": "HTTP Error 500"})
    assert files == ["a", "c", "d"], files
    assert [(e["code"], e.get("key")) for e in errors if not e["fatal"]] == [("download_failed", "b")], errors


def test_a_subtitle_that_fails_never_stops_the_video():
    """Audit 15 (A15-M4): the video is saved (the app says the subtitle is missing, from what came beside it)."""
    files, errors = run("madeup://a", False, {"subtitles": ["en"]}, subtitles=True, subtitle_fails=True)
    assert files == ["a"], (files, errors)
    assert not any(e["fatal"] for e in errors), errors
    files, errors = run("madeup://list", True, {"subtitles": ["en"]}, videos=["a", "b"], subtitles=True, subtitle_fails=True)
    assert files == ["a", "b"], files


def test_subtitles_that_come_are_reported_beside_their_video():
    """Audit 17 (A17-m1, A17-m5): each subtitle language that came is an attachment of its video, so the app can say
    which did not."""
    run_files, errors = run("madeup://a", False, {"subtitles": ["en", "fr"]}, subtitles=True, languages=["en", "fr"],
                            missing=["fr"])
    assert run_files == ["a"], (run_files, errors)
    kinds = [fields["kind"] for kind, fields in LAST if kind == "attachment"]
    assert kinds == ["subtitles.en"], kinds


def test_a_single_video_that_can_never_download_offers_no_retry():
    """Audit 13 (C13-m4), audit 14 (A14-m1): a private single video ends unavailable; a failing one ends failed."""
    _, errors = run("madeup://a", False, problems={"a": "Private video. Sign in if you've been granted access"})
    assert [(e["code"], e["fatal"]) for e in errors] == [("unavailable", False), ("unavailable", True)], errors
    _, errors = run("madeup://a", False, problems={"a": "HTTP Error 500"})
    assert [(e["code"], e["fatal"]) for e in errors] == [("download_failed", False), ("download_failed", True)], errors


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print("ok  ", test.__name__)
    print(f"{len(tests)} tests, 0 failures")
