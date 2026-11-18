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


class Capture:
    def __init__(self):
        self.events = []

    def emit(self, kind, **fields):
        self.events.append((kind, fields))

    def emit_last(self, kind, **fields):
        self.events.append((kind, fields))


class MadeUpIE(InfoExtractor):
    _VALID_URL = r"madeup://(?P<id>.+)"
    IE_NAME = "madeup"

    def _real_extract(self, url):
        video = self._match_id(url)
        if video == "list":
            def entries():
                for name in SITE["videos"]:
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
            info["subtitles"] = {"en": [{"url": "madeup-media://sub-" + video, "ext": "vtt"}]}
        return info


original_init = yt_dlp.YoutubeDL.__init__


def init(self, *args, **kwargs):
    original_init(self, *args, **kwargs)
    site = MadeUpIE(self)
    self._ies = {"MadeUp": site, **self._ies}
    self._ies_instances = {"MadeUp": site, **self._ies_instances}


def download(self, name, info, subtitle=False, test=False):
    if subtitle and SITE.get("subtitle_fails"):
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
    files = [fields["key"].split(":")[-1] for kind, fields in capture.events if kind == "file"]
    errors = [fields for kind, fields in capture.events if kind == "error"]
    return files, errors


def test_a_retry_downloads_the_failed_videos():
    """Audit 15 (A15-M1): a Retry by id downloads the videos asked for, with ids in the listing or not."""
    files, _ = run("madeup://list", True, {"only_ids": ["b"], "skip_ids": ["a", "c"]})
    assert files == ["b"], files
    files, _ = run("madeup://list", True, {"only_ids": ["c"], "skip_ids": ["a", "b"]}, no_ids=True)
    assert files == ["c"], files


def test_a_failed_video_is_named_and_the_rest_downloaded():
    """Audit 14 (A14-M1): a video that fails is reported with its id; the others are downloaded up to the limit."""
    files, errors = run("madeup://list", True, {"max_downloads": 3}, problems={"b": "HTTP Error 500"})
    assert files == ["a", "c", "d"], files
    assert [(e["code"], e.get("key")) for e in errors if not e["fatal"]] == [("download_failed", "b")], errors


def test_a_subtitle_that_fails_never_stops_the_video():
    """Audit 15 (A15-M4, A15-m1): the video is saved and the missing subtitle is said."""
    files, errors = run("madeup://a", False, {"subtitles": ["en"]}, subtitles=True, subtitle_fails=True)
    assert files == ["a"], (files, errors)
    assert any(e["code"] == "note" for e in errors), errors
    files, errors = run("madeup://list", True, {"subtitles": ["en"]}, videos=["a", "b"], subtitles=True, subtitle_fails=True)
    assert files == ["a", "b"], files
    assert sum(e["code"] == "note" for e in errors) == 2, errors


def test_a_single_video_that_can_never_download_offers_no_retry():
    """Audit 13 (C13-m4), audit 14 (A14-m1): a private single video ends unavailable; a failing one ends failed."""
    _, errors = run("madeup://a", False, problems={"a": "Private video. Sign in if you've been granted access"})
    assert [(e["code"], e["fatal"]) for e in errors] == [("unavailable", True)], errors
    _, errors = run("madeup://a", False, problems={"a": "HTTP Error 500"})
    assert [(e["code"], e["fatal"]) for e in errors] == [("download_failed", True)], errors


if __name__ == "__main__":
    tests = [value for name, value in sorted(globals().items()) if name.startswith("test_")]
    for test in tests:
        test()
        print("ok  ", test.__name__)
    print(f"{len(tests)} tests, 0 failures")
