"""MediaPull engine bridge (protocol version 1, SPEC Appendix A).

Reads one JSON request on stdin, drives gallery-dl or yt-dlp, and writes JSON Lines events to
the original stdout. Anything the engines print goes to stderr instead, so the event stream
can never be corrupted by engine output.
"""

import datetime
import hashlib
import json
import logging
import math
import os
import re
import signal
import subprocess
import sys
import threading
import time
import traceback
import weakref

PROTOCOL = 1
VIDEO_EXTENSIONS = {"mp4", "mov", "m4v", "webm", "mkv"}
NON_SITE_CATEGORIES = {"directlink", "generic", "recursive", "noop", "ytdl", "test", "oauth"}
SITE_KEY_NAMES = {"api-key", "api-secret", "client-id", "client-secret", "user-id", "access-token", "api-token"}
# Site switches the Downloads pane may set: each only chooses what media to fetch (SPEC R-1111b).
SITE_OPTION_KEYS = {"videos", "audio", "gif", "livephoto", "covers", "quoted", "reposts", "reblogs", "retweets", "renotes",
                    "replies", "cards", "embeds", "inline", "stories", "mature", "flash", "svg", "recursive", "thumbnails",
                    "previews", "external"}


def _finite(value):
    """NaN and infinity are not JSON; site metadata can carry them, and the app would drop the whole event."""
    if isinstance(value, float):
        return value if math.isfinite(value) else None
    if isinstance(value, dict):
        return {key: _finite(item) for key, item in value.items()}
    if isinstance(value, (list, tuple)):
        return [_finite(item) for item in value]
    return value


def _event_json(event):
    return json.dumps(_finite(event), default=_json_default, ensure_ascii=True, allow_nan=False)


class Emitter:
    def __init__(self, stream):
        self.stream = stream
        self.seq = 0
        self.lock = threading.Lock()

    def emit(self, _event_type, **fields):
        with self.lock:
            self.seq += 1
            event = {"v": PROTOCOL, "seq": self.seq, "type": _event_type}
            event.update(fields)
            try:
                # ASCII only: U+2028, U+2029 and U+0085 in a caption would otherwise split the line on the Swift side.
                self.stream.write(_event_json(event) + "\n")
                self.stream.flush()
            except (BrokenPipeError, ValueError):
                os._exit(0)

    def emit_last(self, _event_type, **fields):
        """For signal handlers: never takes the lock (the signal may land inside emit) and writes past the buffer. The
        leading newline ends any line the interrupted emit left half written, so this one still parses."""
        event = {"v": PROTOCOL, "seq": self.seq + 1, "type": _event_type}
        event.update(fields)
        try:
            os.write(self.stream.fileno(), ("\n" + _event_json(event) + "\n").encode("utf-8"))
        except (OSError, ValueError):
            pass


def _json_default(value):
    if isinstance(value, datetime.datetime):
        return value.strftime("%Y-%m-%d %H:%M:%S") if value else None
    if isinstance(value, (set, tuple)):
        return list(value)
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


EMITTER = None
STATE = {"checkpoint": None, "errors": [], "private": False, "not_found": False, "outdated": False,
         "violations": 0, "cursors": {}, "instagram": False, "collection": None, "download_failed": 0,
         "extraction_failed": False}
# Helper processes the engines start (ffmpeg), so a cancelled job stops them too.
CHILDREN = weakref.WeakSet()


def track_children():
    if getattr(subprocess.Popen.__init__, "_mediapull", False):
        return
    original = subprocess.Popen.__init__

    def init(self, *args, **kwargs):
        original(self, *args, **kwargs)
        CHILDREN.add(self)

    init._mediapull = True
    subprocess.Popen.__init__ = init


def stop_children():
    for child in list(CHILDREN):
        try:
            child.terminate()
        except Exception:
            pass


# MARK: Logging and classification

CHECKPOINT_PATTERNS = (
    (re.compile(r"redirect to login page", re.I), "login"),
    (re.compile(r"redirect to challenge page", re.I), "challenge"),
    (re.compile(r"checkpoint_required|challenge_required", re.I), "challenge"),
    (re.compile(r"feedback_required", re.I), "feedback"),
    (re.compile(r"429 Too Many Requests", re.I), "rate_limit"),
    (re.compile(r"401 Unauthorized.*(wait|few minutes)", re.I), "rate_limit"),
)


# Signed URLs and API keys travel in query strings (api_key, token, sig, user_id...), and engine errors quote whole addresses.
_URL_QUERY = re.compile(r"(https?://[^\s?#'\"<>()\[\]]+)[?#][^\s'\"<>()\[\]]*", re.I)
_SECRET_FIELD = re.compile(
    r"\b((?:sessionid|csrftoken|ds_user_id|fb_dtsg|lsd|api[_-]?key|api[_-]?secret|client[_-]?secret|access[_-]?token|"
    r"refresh[_-]?token|auth[_-]?token|token|secret|password|passwd|signature|sig|user[_-]?id|session[_-]?id|cookie)"
    r"['\"]?\s*[=:]\s*['\"]?)[^&;,\s'\"}]+", re.I)


def _clean(text):
    text = _URL_QUERY.sub(r"\1?REDACTED", str(text))
    text = _SECRET_FIELD.sub(r"\1REDACTED", text)
    return text[:2000]


def _is_instagram_url(url):
    from urllib.parse import urlsplit
    host = (urlsplit(str(url)).hostname or "").lower()
    return host == "instagram.com" or host.endswith(".instagram.com")


class EventLogHandler(logging.Handler):
    def emit(self, record):
        try:
            message = record.getMessage()
        except Exception:
            return
        level = record.levelname.lower()
        if record.levelno < logging.INFO:
            return
        if record.levelno >= logging.WARNING:
            EMITTER.emit("log", level=level, logger=record.name, message=_clean(message))
        lowered = message.lower()
        # Checkpoints pause Instagram (cooldown, sign-in); another site's 429 or login is an ordinary error.
        instagram = STATE["instagram"] or record.name == "instagram"
        for pattern, kind in CHECKPOINT_PATTERNS if instagram else ():
            if pattern.search(message):
                if kind == "rate_limit" and record.levelno < logging.ERROR and "waiting" in lowered:
                    return
                if STATE["checkpoint"] is None:
                    url = None
                    found = re.search(r"\((https?://[^)\s]+)\)", message)
                    if found:
                        url = found.group(1)
                    if url is None and kind == "login":
                        url = "https://www.instagram.com/accounts/login/"
                    STATE["checkpoint"] = {"kind": kind, "url": url, "message": _clean(message)}
                return
        if "posts are private" in lowered or "this account is private" in lowered:
            STATE["private"] = True
        elif "could not be found" in lowered or "notfounderror" in lowered or "404 not found" in lowered:
            if record.levelno >= logging.ERROR:
                STATE["not_found"] = True
        elif "failed to load api data" in lowered or "keyerror" in lowered or "unexpected error" in lowered:
            STATE["outdated"] = True
        if record.levelno >= logging.ERROR:
            STATE["errors"].append(_clean(message))


def install_logging():
    handler = EventLogHandler()
    handler.setLevel(logging.INFO)
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(logging.INFO)


# MARK: Request handling

def read_request():
    raw = sys.stdin.read()
    return json.loads(raw) if raw.strip() else {}


def configure_paths(request):
    for path in reversed(request.get("paths") or []):
        if path and path not in sys.path:
            sys.path.insert(0, path)


def install_guard():
    import egress_guard

    def report(exc):
        STATE["violations"] += 1
        EMITTER.emit("policy_violation", method=exc.method, host=_host(exc.url), path=_path(exc.url),
                     reason=exc.reason)

    egress_guard.install(report)


def _host(url):
    from urllib.parse import urlsplit
    return urlsplit(str(url)).netloc


def _path(url):
    from urllib.parse import urlsplit
    return urlsplit(str(url)).path


def versions():
    info = {"python": sys.version.split()[0], "protocol": PROTOCOL}
    try:
        from gallery_dl import version as gdl_version
        info["gallery_dl"] = gdl_version.__version__
    except Exception as exc:
        info["gallery_dl_error"] = str(exc)
    try:
        from yt_dlp import version as ytdlp_version
        info["yt_dlp"] = ytdlp_version.__version__
    except Exception as exc:
        info["yt_dlp_error"] = str(exc)
    ffmpeg = _which("ffmpeg")
    if ffmpeg:
        try:
            out = subprocess.run([ffmpeg, "-hide_banner", "-version"], capture_output=True, text=True, timeout=10).stdout
            info["ffmpeg"] = out.split()[2] if out else None
        except Exception:
            info["ffmpeg"] = None
    return info


def _which(name):
    for folder in os.environ.get("PATH", "").split(os.pathsep):
        candidate = os.path.join(folder, name)
        if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
            return candidate
    return None


# MARK: gallery-dl configuration

STAGING = {"root": None}


def inside_staging(path):
    """Engines build paths from site metadata; only files inside the job's folder are reported."""
    root = STAGING["root"]
    if not root or not path:
        return False
    real_root = os.path.realpath(root)
    return os.path.realpath(path).startswith(real_root.rstrip(os.sep) + os.sep)


def harden_gallery_dl_paths():
    """gallery-dl keeps `..` and `.` as folder names, and site metadata (a gallery title, a list formatted with `:I`)
    can supply them, which would write files outside the job's folder. Every such segment becomes `_` before any file
    is written (D-42)."""
    from gallery_dl import path as gdl_path

    if getattr(gdl_path.PathFormat.build_directory, "_mediapull", False):
        return
    original = gdl_path.PathFormat.build_directory

    def build_directory(self, kwdict):
        return [segment if segment.strip(" .") else "_" for segment in original(self, kwdict)]

    build_directory._mediapull = True
    gdl_path.PathFormat.build_directory = build_directory


def site_request_intervals():
    """{category: (min, max)}: every extractor's own default interval between requests (the slowest per category)."""
    try:
        from gallery_dl import extractor as gdl_extractor

        classes = list(gdl_extractor._list_classes())
    except Exception:
        return {}
    intervals = {}
    for cls in classes:
        interval = getattr(cls, "request_interval", 0) or 0
        low, high = (interval, interval) if isinstance(interval, (int, float)) else (interval[0], interval[-1])
        if high:
            old = intervals.get(cls.category, (0.0, 0.0))
            intervals[cls.category] = (max(old[0], float(low)), max(old[1], float(high)))
    return intervals


def configure_gallery_dl(request, staging):
    STAGING["root"] = staging
    harden_gallery_dl_paths()
    urls = [url for url in (request.get("urls") or [request.get("url")]) if url]
    STATE["instagram"] = request.get("op") == "account" or request.get("category") == "instagram" or any(map(_is_instagram_url, urls))
    from gallery_dl import config, output

    config.clear()
    # Keep gallery-dl's cache (tokens and session details) in memory: no state outside the job (SPEC R-506).
    config.set(("cache",), "file", None)
    pacing = request.get("pacing") or {}
    delay = pacing.get("request_delay") or [8.0, 15.0]
    extractor = {
        "base-directory": staging,
        "skip": True,
        "retries": 2,
        "timeout": 60,
        "sleep-request": delay,
        "sleep-429": 120,
        # Animated works stored as frames (pixiv, danbooru) become MP4 with the hardware encoder; nothing else is touched.
        "postprocessors": [{
            "name": "ugoira", "extension": "mp4", "mode": "concat", "keep-files": False, "mtime": False,
            "ffmpeg-location": os.path.join(os.environ.get("MEDIAPULL_HELPERS") or "", "ffmpeg") if os.environ.get("MEDIAPULL_HELPERS") else "ffmpeg",
            "ffmpeg-args": ["-c:v", "h264_videotoolbox", "-q:v", "65", "-pix_fmt", "yuv420p", "-vf", "crop=iw-mod(iw\\,2):ih-mod(ih\\,2)"],
            "libx264-prevent-odd": False, "ffmpeg-output": False,
        }],
        "instagram": {
            "retries": 0,
            "sleep-429": 0,
            "include": request.get("include") or ["posts"],
            "videos": True,
            "previews": False,
            "warn-videos": False,
            "pinned": True,
            "order-files": "asc",
        },
    }
    # R-1203: never faster than a site's own interval between requests. A global sleep-request replaces gallery-dl's
    # per-site default, so the slower of the two is set for every site, including ones whose extractors another site's
    # page hands work to (a Reddit post linking an Imgur album).
    for category, own in site_request_intervals().items():
        section = extractor.setdefault(category, {})
        if "sleep-request" not in section:
            section["sleep-request"] = [max(delay[0], own[0]), max(delay[-1], own[1])]
    site = request.get("category")
    if site and site != "instagram":
        # Per-site choices from the Downloads pane (SPEC R-1111b): which parts of a profile, and the
        # site's own switches (videos, reblogs, replies...). Only booleans from a known list are passed on.
        section = extractor.setdefault(site, {})
        if request.get("include"):
            section["include"] = request["include"]
        for key, value in (request.get("site_options") or {}).items():
            if key in SITE_OPTION_KEYS and isinstance(value, bool):
                section[key] = value
        # The person's own API key for the site, from the Keychain (only known key names, only strings).
        for key, value in (request.get("site_keys") or {}).items():
            if key in SITE_KEY_NAMES and isinstance(value, str) and value.strip():
                section[key] = value.strip()
    # Signed-in sessions and challenge cookies are tied to the browser that made them. Instagram is left out: gallery-dl
    # imitates a whole Chrome browser there (headers and TLS), and another browser's user agent would contradict it.
    if request.get("cookies") and request.get("user_agent") and not STATE["instagram"]:
        (extractor.setdefault(site, {}) if site else extractor)["user-agent"] = request["user_agent"]
    if site == "reddit" and extractor.get("reddit", {}).get("client-id"):
        # Reddit's API with the person's own app wants an app user agent, and does not use the browser's cookies.
        extractor["reddit"]["user-agent"] = "macos:mediapull:1.6 (personal media archive)"
    if request.get("cookies"):
        extractor["cookies"] = request["cookies"]
        extractor["cookies-update"] = True
    cursor = request.get("cursor")
    if cursor:
        extractor["instagram"]["posts"] = {"cursor": cursor}
    if request.get("filter"):
        extractor["image-filter"] = request["filter"]
    if request.get("range"):
        # Which items of a gallery to download, such as "1-50" (gallery-dl's image-range). Galleries that list their items
        # as separate pages (one image each) are limited by chapter-range too; profiles split into parts are not.
        extractor["image-range"] = request["range"]
        if not request.get("include"):
            extractor["chapter-range"] = request["range"]
    config.set((), "extractor", extractor)

    video = request.get("video") or {}
    ytdl = {
        "module": "yt_dlp",
        "format": video.get("format") or "bv*+ba/b",
        "forward-cookies": True,
        "raw-options": {
            "merge_output_format": "mp4",
            "format_sort": video.get("format_sort") or ["res", "vcodec:h265", "acodec:aac"],
            "ffmpeg_location": os.environ.get("MEDIAPULL_HELPERS") or None,
            "cachedir": False,
            "quiet": True,
            "no_warnings": False,
            "noprogress": True,
        },
    }
    config.set((), "downloader", {"part": True, "mtime": False, "ytdl": ytdl, "progress": None})
    config.set((), "output", {"mode": "null", "progress": False, "log": None})
    output.select = lambda: ProgressOutput()


class ProgressOutput:
    def __init__(self):
        self.path = None
        self.last = 0.0

    def start(self, path):
        self.path = path

    def skip(self, path):
        pass

    def success(self, path):
        pass

    def progress(self, bytes_total, bytes_downloaded, bytes_per_second):
        now = time.time()
        if now - self.last < 0.5:
            return
        self.last = now
        EMITTER.emit("progress", received=bytes_downloaded, total=bytes_total, speed=bytes_per_second)


def patch_sleep():
    from gallery_dl.extractor import common

    original_sleep = common.Extractor.sleep

    def sleep(self, seconds, reason):
        if seconds and seconds > 0.5:
            kind = "rate_limit" if "429" in str(reason) else "pacing"
            EMITTER.emit("wait", seconds=round(float(seconds), 1), reason=kind)
        return original_sleep(self, seconds, reason)

    common.Extractor.sleep = sleep

    original_wait = common.Extractor.wait

    def wait(self, seconds=None, until=None, adjust=1.0, reason="rate limit"):
        if seconds:
            EMITTER.emit("wait", seconds=round(float(seconds), 1), reason="rate_limit")
        elif until:
            try:
                remaining = (until.timestamp() if hasattr(until, "timestamp") else float(until)) - time.time()
                EMITTER.emit("wait", seconds=round(max(remaining, 0), 1), reason="rate_limit")
            except Exception:
                pass
        return original_wait(self, seconds, until, adjust, reason)

    common.Extractor.wait = wait


def patch_instagram():
    """Reads Instagram's error bodies (gallery-dl only logs the status) so challenges, login
    requests and rate limits become checkpoint events, and reports the cursor after every page."""
    try:
        from gallery_dl.extractor import instagram
        from gallery_dl import exception
    except Exception:
        return
    if getattr(instagram.InstagramExtractor.request, "_mediapull", False):
        return
    original_request = instagram.InstagramExtractor.request

    def request(self, url, **kwargs):
        try:
            return original_request(self, url, **kwargs)
        except exception.HttpError as exc:
            classify_instagram_error(exc)
            raise

    request._mediapull = True
    instagram.InstagramExtractor.request = request

    original_cursor = instagram.InstagramExtractor._update_cursor

    def update_cursor(self, cursor):
        result = original_cursor(self, cursor)
        if cursor:
            EMITTER.emit("cursor", subcategory=self.subcategory, value=str(cursor))
        return result

    instagram.InstagramExtractor._update_cursor = update_cursor

    # The listing reached its end when the posts generator runs out. Its paginators differ (the GraphQL one ends without
    # clearing the cursor, audit 4, A4-M1), so the end is read from the generator, not from the cursor.
    original_posts = instagram.InstagramPostsExtractor.posts

    def posts(self):
        yield from original_posts(self)
        self._mediapull_listing_end = True

    instagram.InstagramPostsExtractor.posts = posts

    # Every listing of an account looks its name up first: the account is reported then, before any of its files, so the
    # app can refuse a name another person has taken since a folder was made (audit 5, A5-M1). Only a Profile information
    # pull reported it before, and after the media.
    original_user = instagram.InstagramAPI.user
    reported = set()

    def user(self, handle, check_private=True):
        result = original_user(self, handle, check_private)
        fields = account_fields(result if isinstance(result, dict) else {})
        if fields["user_id"] and fields["user_id"] not in reported:
            reported.add(fields["user_id"])
            EMITTER.emit("account", **fields)
        return result

    instagram.InstagramAPI.user = user


def classify_instagram_error(exc):
    if STATE["checkpoint"] is not None:
        return
    response = getattr(exc, "response", None)
    status = getattr(response, "status_code", 0) or 0
    body = {}
    try:
        body = response.json() if response is not None else {}
    except Exception:
        body = {}
    if not isinstance(body, dict):
        body = {}
    message = str(body.get("message") or "")
    lowered = message.lower()
    challenge = body.get("challenge") if isinstance(body.get("challenge"), dict) else {}
    url = body.get("checkpoint_url") or challenge.get("url")
    if url and str(url).startswith("/"):
        url = "https://www.instagram.com" + str(url)
    kind = None
    if "checkpoint_required" in lowered or "challenge_required" in lowered or body.get("checkpoint_url"):
        kind = "challenge"
    elif "feedback_required" in lowered or body.get("feedback_required"):
        kind = "feedback"
    elif "login_required" in lowered or body.get("require_login"):
        kind = "login"
        url = url or "https://www.instagram.com/accounts/login/"
    elif status == 429 or (status == 401 and "wait" in lowered):
        kind = "rate_limit"
    if kind:
        STATE["checkpoint"] = {"kind": kind, "url": url, "message": _clean(message or f"HTTP {status}")}


# MARK: Item metadata

META_KEYS = ("category", "subcategory", "username", "fullname", "post_shortcode", "post_id", "num", "count",
             "date", "post_date", "description", "post_url", "highlight_title", "media_id", "shortcode",
             "width", "height", "width_original", "height_original", "extension", "filename", "title",
             "type", "id", "author", "user", "owner_id")


def collection_of(url):
    """`stories-tray` for the stories of accounts the person follows, `saved` for saved posts and collections."""
    from urllib.parse import urlsplit

    parts = urlsplit(url or "")
    if not (parts.hostname or "").endswith("instagram.com"):
        return None
    segments = [segment for segment in parts.path.split("/") if segment]
    if segments[:2] == ["stories", "me"]:
        return "stories-tray"
    if len(segments) >= 2 and segments[1] == "saved":
        return "saved"
    return None


def item_meta(url, kwdict):
    meta = {}
    if STATE.get("collection") and kwdict.get("category") == "instagram":
        meta["collection"] = STATE["collection"]
    for key in META_KEYS:
        if key not in kwdict:
            continue
        value = kwdict[key]
        if key == "user":
            if isinstance(value, dict):
                name = value.get("username") or value.get("name") or value.get("screen_name")
                if name:
                    meta["user_name"] = str(name)
            elif isinstance(value, str):
                meta["user_name"] = value
            continue
        if key == "author":
            if isinstance(value, dict):
                value = value.get("username") or value.get("name") or value.get("nick")
            if value is None:
                continue
            value = str(value)
        if isinstance(value, datetime.datetime):
            # gallery-dl marks a missing date with a false datetime (year 1): leave the date out instead.
            if not value:
                continue
            value = value.strftime("%Y-%m-%d %H:%M:%S")
        elif isinstance(value, (dict, list, tuple, set)):
            continue
        elif isinstance(value, bool) or value is None:
            continue
        elif isinstance(value, int) and key in ("post_id", "media_id", "id", "owner_id"):
            value = str(value)
        meta[key] = value
    if kwdict.get("pinned"):
        meta["pinned"] = True
    for key in ("width_original", "height_original"):
        if meta.get(key) == 0:
            meta.pop(key)
    return meta


def item_key(kwdict, url):
    category = kwdict.get("category") or "item"
    if category == "instagram" and kwdict.get("media_id"):
        return f"ig:{kwdict['media_id']}"
    for field in ("media_id", "id", "post_id"):
        value = kwdict.get(field)
        if value not in (None, ""):
            # A post's files share its id on some sites (Pixiv, Kemono): the file's number in the post tells them apart
            # (D-75). A media_id is already the file's own.
            suffix = f":{kwdict.get('num')}" if field != "media_id" and kwdict.get("num") else ""
            return f"{category}:{value}{suffix}"
    return f"{category}:url:{hashlib.sha256(str(url).encode()).hexdigest()[:20]}"


# Instagram parts whose files keep their place in a post: a carousel's items can be removed but never reordered or added
# to, so a post's id with an item's number names that file. Stories and highlights shift as a tray changes, so they are
# known only by their media id.
POSITIONAL_SUBCATEGORIES = {"posts", "post", "reels", "reel", "tagged", "reposts", "user"}


def positional_key(kwdict):
    """`igp:<post_id>:<num>` for an Instagram post's file, the form a folder's metadata files give (D-79)."""
    if kwdict.get("category") != "instagram" or kwdict.get("subcategory") not in POSITIONAL_SUBCATEGORIES:
        return None
    post, num = kwdict.get("post_id"), kwdict.get("num")
    return f"igp:{post}:{num}" if post and num else None


def item_event(url, kwdict):
    meta = item_meta(url, kwdict)
    extension = str(kwdict.get("extension") or "").lower()
    is_video = url.startswith("ytdl:") or extension in VIDEO_EXTENSIONS or bool(kwdict.get("video_url") and kwdict.get("video_url") == url)
    fallback = kwdict.get("_fallback")
    fallback_url = None
    if fallback:
        try:
            fallback_url = next(iter(fallback))
        except Exception:
            fallback_url = None
    video = None
    if is_video:
        video = {"variant": "dash" if url.startswith("ytdl:") else "progressive"}
        if fallback_url:
            video["fallback_url"] = fallback_url
    headers = kwdict.get("_http_headers")
    return {
        "key": item_key(kwdict, url),
        "kind": "video" if is_video else "image",
        "subcategory": kwdict.get("subcategory"),
        "url": url,
        "thumb_url": kwdict.get("display_url") if kwdict.get("category") == "instagram" else None,
        "width": kwdict.get("width") or None,
        "height": kwdict.get("height") or None,
        "video": video,
        "headers": dict(headers) if isinstance(headers, dict) else None,
        "meta": meta,
    }


def _parse_date(text):
    if not text:
        return None
    try:
        value = datetime.datetime.fromisoformat(str(text).replace("Z", "+00:00"))
        return value.replace(tzinfo=None) if value.tzinfo is None else value.astimezone(datetime.timezone.utc).replace(tzinfo=None)
    except ValueError:
        return None


class KnownTracker:
    """Stops pagination after a run of fully known, non-pinned posts (SPEC R-1112), and applies
    the date window without letting an old pinned post end the listing."""

    date_from = None
    date_to = None
    chronological = {"posts", "reels", "post", "user", "tagged"}

    def __init__(self, known, limit, own=frozenset()):
        self.known = known
        # A Retry's or Resume's own items: skipped, but never counted towards the early stop, which is about what the
        # library held before the job (D-103, audit 20, A20-M1).
        self.own = own
        self.limit = limit
        self.post = None
        self.post_known = True
        self.post_own = False
        self.post_pinned = False
        self.run = 0
        self.stopped = False

    def observe(self, kwdict, key):
        from gallery_dl import exception

        post = kwdict.get("post_id") or kwdict.get("post_shortcode") or key
        if post != self.post:
            self._close_post()
            self.post = post
            self.post_known = True
            self.post_own = False
            self.post_pinned = bool(kwdict.get("pinned"))
        # A file is known by its media id, or (Instagram posts) by its post and number, the form a folder's metadata
        # files give when MediaPull did not record the media id (D-79).
        alternative = positional_key(kwdict)
        held = key in self.known or (alternative is not None and alternative in self.known)
        mine = not held and (key in self.own or (alternative is not None and alternative in self.own))
        is_known = held or mine
        if not is_known:
            self.post_known = False
        if mine:
            self.post_own = True
        if self.limit and self.run >= self.limit:
            # The listing ends at posts the folder has: everything older was walked before.
            self.stopped = True
            raise exception.StopExtraction()
        return is_known

    def outside_dates(self, kwdict, subcategory):
        """True when the item is outside the date window; stops at the first old non-pinned post."""
        from gallery_dl import exception

        date = kwdict.get("post_date") or kwdict.get("date")
        # Undated items (a profile picture, gallery-dl's false "no date") are always kept and never end the listing.
        if not isinstance(date, datetime.datetime) or not date:
            return False
        date = date.replace(tzinfo=None) if date.tzinfo is None else date.astimezone(datetime.timezone.utc).replace(tzinfo=None)
        if self.date_to and date > self.date_to:
            return True
        if self.date_from and date < self.date_from:
            if not kwdict.get("pinned") and subcategory in self.chronological:
                raise exception.StopExtraction()
            return True
        return False

    def _close_post(self):
        if self.post is None:
            return
        if self.post_known and self.post_own:
            return
        if self.post_known and not self.post_pinned:
            self.run += 1
        elif not self.post_known:
            self.run = 0


def known_sets(request):
    """What a pull knows: the folder's items, the job's own items (Retry, Resume), and the owners' items (the tray)."""
    return (load_known(request), load_known({"known_ids": request.get("retry_ids")}),
            load_known({"known_ids": request.get("owners_known_ids")}))


def tracker_for(collection, known, retry, limit, owners=frozenset()):
    """Saved posts and others' stories are not the account's: its folder's known items and early stop do not apply, but a
    Retry's own saved items do (D-103), and the tray knows what its owners' folders remember (D-104). A job's own items
    never count towards the early stop (audit 20, A20-M1)."""
    if collection == "stories-tray":
        return KnownTracker(owners, None, retry)
    if collection:
        return KnownTracker(retry, None)
    return KnownTracker(known, limit, retry)


def load_known(request):
    path = request.get("known_ids")
    if not path:
        return set()
    try:
        with open(path, encoding="utf-8") as handle:
            return set(json.load(handle))
    except Exception:
        return set()


# MARK: Jobs

def make_jobs(request):
    from gallery_dl import extractor as gdl_extractor, job

    # What a Retry's own job saved is known to every listing it walks, collections too, so a file deleted since is not
    # fetched again (D-103, audit 18, A18-M1, C18-M1).
    known, retry, owners = known_sets(request)
    limit = int(request.get("stop_after_known") or 0)
    KnownTracker.date_from = _parse_date(request.get("date_from"))
    KnownTracker.date_to = _parse_date(request.get("date_to"))

    class ScanJob(job.Job):
        def __init__(self, extr, parent=None):
            job.Job.__init__(self, extr, parent)
            self.tracker = KnownTracker(known, limit)
            self.visited = parent.visited if parent is not None else set()

        def handle_url(self, url, kwdict):
            event = item_event(url, kwdict)
            if self.tracker.outside_dates(kwdict, self.extractor.subcategory):
                EMITTER.emit("skip", key=event["key"], reason="date")
                return
            if self.tracker.observe(kwdict, event["key"]):
                EMITTER.emit("skip", key=event["key"], reason="known")
                return
            EMITTER.emit("item", **event)

        def handle_directory(self, kwdict):
            if self.extractor.subcategory == "info":
                EMITTER.emit("account", **account_fields(kwdict))

        def handle_queue(self, url, kwdict):
            if self.extractor.subcategory in LIST_SUBCATEGORIES:
                record_list_entry(self.extractor.subcategory, url, kwdict)
                return
            if url in self.visited:
                return
            self.visited.add(url)
            cls = kwdict.get("_extractor")
            extr = cls.from_url(url) if cls else gdl_extractor.find(url)
            if extr:
                ScanJob(extr, self).run()

        def handle_finalize(self):
            cursor = getattr(self.extractor, "_cursor", None)
            if cursor:
                EMITTER.emit("cursor", subcategory=self.extractor.subcategory, value=str(cursor))

    class PullJob(job.DownloadJob):
        def __init__(self, url, parent=None):
            job.DownloadJob.__init__(self, url, parent)
            # Saved posts and others' stories are not the account's: its folder's known items and early stop do not
            # apply to them.
            self.tracker = tracker_for(STATE.get("collection"), known, retry, limit, owners)

        def dispatch(self, extractor):
            # A listing that broke off (an error, not the early stop) is told apart from files that failed one by one: only
            # the second leaves the pull "partial", walked to its end with some files to fetch again (audit 4, A4-M3).
            from gallery_dl import exception
            try:
                return job.DownloadJob.dispatch(self, extractor)
            except exception.StopExtraction:
                raise
            except (exception.TerminateExtraction, exception.RestartExtraction):
                raise
            except BaseException:
                STATE["extraction_failed"] = True
                raise

        def initialize(self, kwdict=None):
            job.DownloadJob.initialize(self, kwdict)
            import collections
            hooks = self.hooks if isinstance(self.hooks, dict) else collections.defaultdict(list)
            if not isinstance(hooks, collections.defaultdict):
                hooks = collections.defaultdict(list, hooks)
            hooks["after"].append(self._file_done)
            hooks["error"].append(self._file_failed)
            self.hooks = hooks
            self.out = ProgressOutput()

        def handle_url(self, url, kwdict):
            key = item_key(kwdict, url)
            if self.tracker.outside_dates(kwdict, self.extractor.subcategory):
                EMITTER.emit("skip", key=key, reason="date")
                return
            if self.tracker.observe(kwdict, key):
                EMITTER.emit("skip", key=key, reason="known")
                return
            EMITTER.emit("item", **item_event(url, kwdict))
            job.DownloadJob.handle_url(self, url, kwdict)

        def handle_directory(self, kwdict):
            if self.extractor.subcategory == "info":
                EMITTER.emit("account", **account_fields(kwdict))
                DETAILS["profile"] = plain(kwdict)
                return
            job.DownloadJob.handle_directory(self, kwdict)

        def handle_queue(self, url, kwdict):
            # Follower and following lists queue every account in them; record the names, never open them.
            if self.extractor.subcategory in LIST_SUBCATEGORIES:
                record_list_entry(self.extractor.subcategory, url, kwdict)
                return
            job.DownloadJob.handle_queue(self, url, kwdict)

        def handle_skip(self):
            pathfmt = self.pathfmt
            if pathfmt is not None and pathfmt.kwdict:
                path = pathfmt.path
                if path and os.path.isfile(path):
                    self._emit_file(path, pathfmt.kwdict)
            job.DownloadJob.handle_skip(self)

        def _file_done(self, pathfmt):
            self._emit_file(pathfmt.path, pathfmt.kwdict)

        def _file_failed(self, pathfmt):
            kwdict = pathfmt.kwdict or {}
            STATE["download_failed"] += 1
            EMITTER.emit("error", code="download_failed", message="Failed to download a file",
                         key=item_key(kwdict, kwdict.get("_url") or ""), fatal=False)

        def _emit_file(self, path, kwdict):
            url = kwdict.get("_url") or ""
            if not inside_staging(path):
                # Cannot happen once folder names are cleaned; if it ever does, the stray file is not left behind.
                try:
                    os.remove(path)
                except OSError:
                    pass
                EMITTER.emit("error", code="unsafe_path", message="A file path left the working folder", fatal=False)
                return
            try:
                size = os.path.getsize(path)
            except OSError:
                size = None
            EMITTER.emit("file", key=item_key(kwdict, url), path=path, bytes=size,
                         meta=item_meta(url, kwdict), subcategory=kwdict.get("subcategory"))

        def handle_finalize(self):
            cursor = getattr(self.extractor, "_cursor", None)
            if cursor:
                EMITTER.emit("cursor", subcategory=self.extractor.subcategory, value=str(cursor))
            # Whether the posts listing was walked to its end or to the folder's known posts, or stopped part way
            # (an error, a check), so MediaPull knows where posts may still be missing (D-87).
            if getattr(self.extractor, "category", None) == "instagram" and self.extractor.subcategory == "posts" \
                    and not STATE.get("collection"):
                complete = self.tracker.stopped or getattr(self.extractor, "_mediapull_listing_end", False)
                EMITTER.emit("listing", subcategory="posts", complete=bool(complete), cursor=str(cursor) if cursor else None)
            job.DownloadJob.handle_finalize(self)

    return ScanJob, PullJob


# Account details collected during a pull (SPEC R-1105a): follower lists hold names only, and the
# accounts in them are never opened; the profile is kept whole.
DETAILS = {"lists": {}, "profile": None}
LIST_SUBCATEGORIES = ("followers", "following")


def record_list_entry(subcategory, url, kwdict):
    rows = DETAILS["lists"].setdefault(subcategory, [])
    user = kwdict or {}
    rows.append({
        "username": user.get("username") or url.rstrip("/").rsplit("/", 1)[-1],
        "full_name": user.get("full_name") or "",
        "id": str(user.get("pk") or user.get("id") or ""),
        "is_private": bool(user.get("is_private")),
        "is_verified": bool(user.get("is_verified")),
        "profile_url": url,
    })


def plain(value):
    """The JSON-safe part of a metadata value."""
    if isinstance(value, (str, int, float, bool)) or value is None:
        return value
    if isinstance(value, dict):
        return {str(k): plain(v) for k, v in value.items() if not str(k).startswith("_")}
    if isinstance(value, (list, tuple)):
        return [plain(v) for v in value]
    return str(value)


def write_details(staging):
    """Writes collected lists and the profile into the staging folder and reports them."""
    import csv
    for subcategory, rows in DETAILS["lists"].items():
        path = os.path.join(staging, subcategory + ".csv")
        with open(path, "w", newline="", encoding="utf-8") as handle:
            writer = csv.DictWriter(handle, fieldnames=["username", "full_name", "id", "is_private", "is_verified", "profile_url"])
            writer.writeheader()
            writer.writerows(rows)
        EMITTER.emit("document", kind=subcategory, path=path, count=len(rows))
    if DETAILS["profile"] is not None:
        path = os.path.join(staging, "profile.json")
        with open(path, "w", encoding="utf-8") as handle:
            json.dump(DETAILS["profile"], handle, ensure_ascii=False, indent=2, sort_keys=True)
        EMITTER.emit("document", kind="profile", path=path, count=1)


def account_fields(kwdict):
    def count(value):
        if isinstance(value, dict):
            return value.get("count")
        return value

    hd = kwdict.get("hd_profile_pic_url_info")
    avatar = (hd.get("url") if isinstance(hd, dict) else None) or kwdict.get("profile_pic_url_hd") or kwdict.get("profile_pic_url")
    friendship = kwdict.get("friendship_status") if isinstance(kwdict.get("friendship_status"), dict) else {}
    followed = friendship.get("following") if friendship else kwdict.get("followed_by_viewer")
    return {
        "username": kwdict.get("username"),
        "full_name": kwdict.get("full_name") or kwdict.get("fullname"),
        "user_id": str(kwdict.get("id") or kwdict.get("pk") or ""),
        "is_private": bool(kwdict.get("is_private")),
        "followed_by_viewer": bool(followed) if followed is not None else None,
        "post_count": count(kwdict.get("media_count")) or count(kwdict.get("edge_owner_to_timeline_media")),
        "avatar_url": avatar,
        "biography": (kwdict.get("biography") or "")[:500],
    }


def pull_status(status):
    """"partial" when the listing ran to its end and only single files failed (gallery-dl's status 4 means both a failed
    file and an HTTP error of the listing, so the listing's own failure is tracked apart)."""
    if status == 0:
        return "completed"
    if status & ~4 == 0 and STATE["download_failed"] and not STATE["extraction_failed"] and not STATE["violations"]:
        return "partial"
    return "failed"


def finish(status, counts=None):
    checkpoint = STATE["checkpoint"]
    if checkpoint:
        EMITTER.emit("checkpoint", **checkpoint)
        status = "blocked"
    elif STATE["violations"]:
        status = "failed"
    if STATE["private"]:
        EMITTER.emit("error", code="private", message="This account is private.", fatal=True)
    if STATE["not_found"]:
        EMITTER.emit("error", code="not_found", message="Nothing was found at this address.", fatal=True)
    if STATE["outdated"] and status != "completed":
        EMITTER.emit("error", code="engine_outdated",
                     message="The site may have changed. Check for engine updates.", fatal=False)
    EMITTER.emit("done", status=status, counts=counts or {}, errors=STATE["errors"][-5:])


def run_gallery_job(request, kind):
    staging = request["staging"]
    os.makedirs(staging, exist_ok=True)
    configure_gallery_dl(request, staging)
    patch_sleep()
    patch_instagram()
    ScanJob, PullJob = make_jobs(request)
    urls = request.get("urls") or [request["url"]]
    status = 0
    for url in urls:
        cls = ScanJob if kind == "scan" else PullJob
        # gallery-dl runs the stories tray and saved posts as child extractors of other kinds, so their files cannot tell
        # where they came from: the address they were listed under is passed on with each one.
        STATE["collection"] = collection_of(url)
        try:
            status |= cls(url).run()
        except Exception as exc:
            from gallery_dl import exception
            if isinstance(exc, exception.NoExtractorError):
                EMITTER.emit("error", code="unsupported", message="This address is not supported.", fatal=True)
                status |= 64
            else:
                raise
        if STATE["checkpoint"] or STATE["violations"]:
            break
    if kind != "scan":
        write_details(staging)
    finish(pull_status(status), {"status": status})


def op_account(request):
    request = dict(request)
    request["include"] = ["info"]
    staging = request.get("staging") or os.getcwd()
    configure_gallery_dl(request, staging)
    patch_sleep()
    patch_instagram()
    ScanJob, _ = make_jobs(request)
    username = request["username"].lstrip("@")
    status = ScanJob(f"https://www.instagram.com/{username}/info/").run()
    finish("completed" if status == 0 else "failed")


class _Captured(Exception):
    pass


def content_choices(extr):
    """For a profile page that gallery-dl splits into parts (gallery, scraps, media, likes...), the parts it offers and
    the ones it downloads by default. Read from the extractor without any network request."""
    from gallery_dl.extractor import common

    if not isinstance(extr, common.Dispatch):
        return [], []
    captured = {}

    def capture(extractor_data, default=(), alt=None):
        captured["data"], captured["default"], captured["alt"] = extractor_data, default, alt
        raise _Captured()

    def no_network(*args, **kwargs):
        raise _Captured()

    extr._dispatch_extractors = capture
    extr.request = no_network
    try:
        result = extr.items()
        if hasattr(result, "__next__"):
            next(result, None)
    except Exception:
        pass
    data = captured.get("data")
    if not data:
        return [], []
    choices = list(data.keys()) if isinstance(data, dict) else [entry[0].subcategory for entry in data]
    for sub, sub_alt, _url in captured.get("alt") or ():
        if sub_alt not in choices:
            choices.append(sub_alt)
    default = captured.get("default") or ()
    if isinstance(default, str):
        default = choices if default == "all" else default.replace(" ", "").split(",")
    return choices, [d for d in default if d in choices]


def op_supports(request):
    """Whether gallery-dl handles an address, and what the Downloads pane can offer for it (SPEC R-1111b)."""
    from gallery_dl import extractor as gdl_extractor

    url = request.get("url") or ""
    found = None
    try:
        extr = gdl_extractor.find(url)
    except Exception:
        extr = None
    if extr is not None and extr.category not in NON_SITE_CATEGORIES:
        choices, defaults = content_choices(extr)
        found = {"category": extr.category, "subcategory": extr.subcategory,
                 "basecategory": getattr(extr, "basecategory", "") or "", "root": getattr(extr, "root", None),
                 "choices": choices, "defaults": defaults}
    EMITTER.emit("supports", url=url, supported=found is not None, **(found or {}))
    EMITTER.emit("done", status="completed", counts={})


def higher_resolution(info):
    """The tallest video the site offered, when it is taller than the one downloaded (R-1607: a policy that never
    re-encodes takes the best H.264 or HEVC, and the sidecar says what else there was)."""
    heights = [f.get("height") for f in info.get("formats") or []
               if f.get("vcodec") not in (None, "none") and isinstance(f.get("height"), int)]
    best, chosen = max(heights, default=None), info.get("height")
    return f"{best}p" if best and isinstance(chosen, int) and best > chosen else None


def video_meta(info):
    """The details of a downloaded video that its metadata file and name are built from."""
    return {
        "higher_res_available": higher_resolution(info),
        "title": info.get("title"), "width": info.get("width"), "height": info.get("height"), "vcodec": info.get("vcodec"),
        "duration": info.get("duration"), "uploader": info.get("uploader") or info.get("channel"),
        "uploader_id": info.get("uploader_id") or info.get("channel_id"), "id": info.get("id"),
        "upload_date": info.get("upload_date"), "timestamp": info.get("timestamp"), "webpage_url": info.get("webpage_url"),
        "extractor": (info.get("extractor_key") or info.get("extractor") or "").lower(), "description": (info.get("description") or "")[:2000],
    }


def op_video_info(request):
    """Lists a page's video formats without downloading anything (SPEC section 35)."""
    import yt_dlp

    class Quiet:
        def debug(self, message):
            pass

        def info(self, message):
            pass

        def warning(self, message):
            EMITTER.emit("log", level="warning", logger="yt-dlp", message=_clean(message))

        def error(self, message):
            STATE["errors"].append(_clean(message))

    options = {"quiet": True, "skip_download": True, "noplaylist": True, "playlist_items": "1", "cachedir": False, "logger": Quiet(),
               "http_headers": {"User-Agent": request["user_agent"]} if request.get("user_agent") else {}}
    if request.get("cookies"):
        options["cookiefile"] = request["cookies"]
    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            info = ydl.extract_info(request["url"], download=False)
    except Exception as exc:
        EMITTER.emit("error", code="no_video", message=_clean(str(exc))[:300], fatal=True)
        finish("failed")
        return
    if info and info.get("_type") == "playlist":
        entries = [entry for entry in (info.get("entries") or []) if entry]
        info = entries[0] if entries else None
    if not info or not info.get("formats"):
        EMITTER.emit("error", code="no_video", message="No downloadable video was found on this page.", fatal=True)
        finish("failed")
        return
    formats = []
    for fmt in info.get("formats") or []:
        vcodec, acodec = fmt.get("vcodec") or "none", fmt.get("acodec") or "none"
        if vcodec == "none" and acodec == "none":
            continue
        if (fmt.get("protocol") or "").startswith(("m3u8", "http_dash_segments")) and fmt.get("ext") not in ("mp4", "m4a", "webm"):
            continue
        formats.append({
            "id": fmt.get("format_id"), "ext": fmt.get("ext"), "height": fmt.get("height"), "width": fmt.get("width"),
            "fps": fmt.get("fps"), "vcodec": vcodec, "acodec": acodec, "abr": fmt.get("abr"), "tbr": fmt.get("tbr"),
            "size": fmt.get("filesize") or fmt.get("filesize_approx"), "drm": bool(fmt.get("has_drm")),
        })
    meta = video_meta(info)
    meta["thumbnail"] = info.get("thumbnail")
    EMITTER.emit("video_info", formats=formats, **meta)
    finish("completed")


def refuse_live_streams(info, incomplete=False):
    """A live stream never ends and would need ffmpeg's network downloaders: say so plainly instead of failing later. It is
    skipped, like a video not out yet (audit 13, A13-m2)."""
    if info.get("is_live") or info.get("live_status") in ("is_live", "is_upcoming"):
        message = "Live streams can't be saved."
        STATE["errors"].append(message)
        STATE.setdefault("problems", []).append("unavailable")
        EMITTER.emit("error", code="unavailable", message=message, key=info.get("id"), fatal=False)
        return message
    return None


def skip_saved(inner, saved):
    """A Retry of a playlist runs it again and downloads only the videos not saved yet (audit 12, A12-M3; D-102). The
    video looked at last names a failure whose message has no id."""
    def check(info, incomplete=False):
        video = str(info.get("id") or "")
        if saved and video in saved:
            return "Already saved."
        if video and not incomplete:
            STATE["current_id"] = video
        return inner(info, incomplete=incomplete)
    return check


def failed_video(text):
    """The id of the video an error is about, to tell failures apart: yt-dlp writes "[site] id: reason", else the video
    looked at last."""
    match = re.search(r"\[[^\]]+\] ([^\s:]+): ", text)
    return match.group(1) if match else STATE.get("current_id")


# A video that can never be downloaded is skipped; anything that may work later is a failure Retry Failed offers. A rate
# limit says "Video unavailable ... try again later", and members-only and age-checked videos download with the site's
# sign-in (R-3505), so those are looked for first (audit 13, A13-M1, C13-m5).
MAY_WORK_LATER = ("try again later", "rate-limit", "rate limit", "too many requests", "http error 429", "confirm your age",
                  "members-only", "members only", "join this channel", "sign in to confirm you")
UNAVAILABLE = ("private video", "has been removed", "no longer available", "has been terminated", "premieres in",
               "available in your country", "this video is not available", "video unavailable")


def problem_code(text):
    """"unavailable" for a video that can never be downloaded, else "download_failed"."""
    lower = text.lower()
    if any(words in lower for words in MAY_WORK_LATER):
        return "download_failed"
    return "unavailable" if any(words in lower for words in UNAVAILABLE) else "download_failed"


class StreamLogger:
    """yt-dlp's logger for downloads. In a playlist yt-dlp goes on past a video it cannot download: that video is a
    failure the app counts and offers to retry, never only a log line (audit 11, A11-M3), and one that can never be
    downloaded (private, members only, removed, not yet out) is skipped instead (audit 12, A12-M3)."""

    def __init__(self, playlist):
        self.playlist = playlist

    def debug(self, message):
        pass

    def info(self, message):
        pass

    def warning(self, message):
        # A subtitle or thumbnail that did not come is said by the app, from what came beside each video (audit 16,
        # C16-m1, A16-m1).
        EMITTER.emit("log", level="warning", logger="yt-dlp", message=_clean(message))

    def error(self, message):
        text = _clean(message)
        STATE["errors"].append(text)
        code = problem_code(text)
        STATE.setdefault("problems", []).append(code)
        EMITTER.emit("log", level="error", logger="yt-dlp", message=text)
        # Every video's problem is reported, a page with several videos asked for as one included (audit 16, A16-M3).
        EMITTER.emit("error", code=code, message=text[:300], key=failed_video(text), fatal=False)


def stream_options(request, staging, logger, progress):
    """yt-dlp options for a download: the chosen format plus the person's extra choices (SPEC R-3505)."""
    import yt_dlp

    video = request.get("video") or {}
    extras = request.get("extras") or {}
    headers = {}
    if request.get("referer"):
        headers["Referer"] = request["referer"]
    if request.get("user_agent"):
        headers["User-Agent"] = request["user_agent"]
    options = {
        "outtmpl": {"default": "%(id).60s.%(ext)s"},
        "paths": {"home": staging, "temp": staging},
        "format": video.get("format") or "bv*+ba/b",
        "format_sort": video.get("format_sort") or ["res", "vcodec:h265", "acodec:aac"],
        "merge_output_format": video.get("merge") or "mp4",
        "cachedir": False,
        "noplaylist": not extras.get("playlist"),
        "quiet": True,
        "noprogress": True,
        "logger": logger,
        "progress_hooks": [progress],
        "http_headers": headers,
        "ffmpeg_location": os.environ.get("MEDIAPULL_HELPERS") or None,
        "allow_unplayable_formats": False,
        "check_formats": False,
        "retries": 3,
        "fragment_retries": 5,
        # A video's own problem is logged, classed and reported at the end, never raised: a subtitle that fails is then a
        # warning, not the end of the download (audit 15, A15-M4).
        "ignoreerrors": True,
        # The bundled ffmpeg has no network protocols (R-507): yt-dlp's own downloaders fetch every stream.
        "hls_prefer_native": True,
        "external_downloader": {},
        "match_filter": skip_saved(refuse_live_streams, set(extras.get("skip_ids") or [])),
    }
    if extras.get("playlist_items"):
        options["playlist_items"] = extras["playlist_items"]
    if extras.get("max_downloads"):
        # "At most" applies to every run, a Retry included (D-102).
        options["max_downloads"] = int(extras["max_downloads"])
    if extras.get("date_after") or extras.get("date_before"):
        options["daterange"] = yt_dlp.utils.DateRange(extras.get("date_after"), extras.get("date_before"))
    if extras.get("rate_limit"):
        options["ratelimit"] = int(extras["rate_limit"])
    languages = extras.get("subtitles") or []
    if languages:
        options["writesubtitles"] = True
        options["writeautomaticsub"] = bool(extras.get("auto_subtitles"))
        options["subtitleslangs"] = languages
        options["subtitlesformat"] = "vtt/srt/best"
    if extras.get("thumbnail"):
        options["writethumbnail"] = True
    if extras.get("description"):
        options["writedescription"] = True
    if request.get("cookies"):
        options["cookiefile"] = request["cookies"]
    return options


def emit_stream_files(info, base_key):
    """Reports a finished video and the files written beside it (subtitles, thumbnail, description)."""
    downloads = info.get("requested_downloads") or []
    path = (downloads[0].get("filepath") if downloads else None) or info.get("filepath") or info.get("_filename")
    if not path or not os.path.isfile(path) or not inside_staging(path):
        return False
    key = f"{base_key}:{info.get('id') or os.path.basename(path)}"
    EMITTER.emit("file", key=key, path=path, bytes=os.path.getsize(path), meta=video_meta(info))
    for language, subtitle in (info.get("requested_subtitles") or {}).items():
        extra = (subtitle or {}).get("filepath")
        if extra and os.path.isfile(extra) and inside_staging(extra):
            EMITTER.emit("attachment", key=key, path=extra, kind=f"subtitles.{language}")
    for thumbnail in info.get("thumbnails") or []:
        extra = thumbnail.get("filepath")
        if extra and os.path.isfile(extra) and inside_staging(extra):
            EMITTER.emit("attachment", key=key, path=extra, kind="thumbnail")
    description = os.path.splitext(path)[0] + ".description"
    if os.path.isfile(description) and inside_staging(description):
        EMITTER.emit("attachment", key=key, path=description, kind="description")
    return True


def op_stream(request):
    import yt_dlp
    from yt_dlp.postprocessor.common import PostProcessor

    staging = request["staging"]
    os.makedirs(staging, exist_ok=True)
    STAGING["root"] = staging
    playlist = bool((request.get("extras") or {}).get("playlist"))

    last = {"t": 0.0}

    def progress(info):
        now = time.time()
        if info.get("status") == "downloading" and now - last["t"] >= 0.5:
            last["t"] = now
            EMITTER.emit("progress", received=info.get("downloaded_bytes"),
                         total=info.get("total_bytes") or info.get("total_bytes_estimate"),
                         speed=info.get("speed"))

    base_key = request.get("key") or "stream"
    emitted = {"count": 0}

    class Emit(PostProcessor):
        # Runs after each video is complete, so playlists report every video as it finishes.
        def run(self, info):
            if emit_stream_files(info, base_key):
                emitted["count"] += 1
            return [], info

    extras_skip = bool((request.get("extras") or {}).get("skip_ids"))
    options = stream_options(request, staging, StreamLogger(playlist), progress)
    try:
        with yt_dlp.YoutubeDL(options) as ydl:
            ydl.add_post_processor(Emit(), when="after_move")
            ydl.extract_info(request["url"], download=True)
    except yt_dlp.utils.MaxDownloadsReached:
        pass
    except yt_dlp.utils.DownloadError:
        # A single video's problem was logged (and classed) before yt-dlp raised it: it ends below as unavailable or failed,
        # never as an internal error (audit 14, A14-m1).
        if not STATE["errors"]:
            raise
    if emitted["count"]:
        finish("partial" if STATE["errors"] else "completed", {"files": emitted["count"]})
    elif extras_skip and not STATE["errors"]:
        # A Retry that found every video saved already has nothing to do: done, not failed (audit 17, C17-m3).
        finish("completed", {"files": 0})
    else:
        message = STATE["errors"][-1] if STATE["errors"] else "The stream could not be downloaded."
        # Nothing that could ever be downloaded (all private or removed, or a live stream) is not offered for Retry (audit
        # 13, C13-m4, A13-m2).
        problems = STATE.get("problems") or []
        code = "unavailable" if problems and all(p == "unavailable" for p in problems) else "download_failed"
        EMITTER.emit("error", code=code, message=message[:300], fatal=True)
        finish("failed")


def op_install_wheel(request):
    import zipfile

    wheel = request["wheel"]
    target = request["target"]
    with zipfile.ZipFile(wheel) as archive:
        names = archive.namelist()
        native = [n for n in names if n.endswith((".so", ".dylib", ".pyd", ".dll"))]
        if native:
            EMITTER.emit("error", code="native_code", message="The update contains native code and was refused.",
                         fatal=True)
            finish("failed")
            return
        for name in names:
            if name.startswith("/") or ".." in name.split("/"):
                EMITTER.emit("error", code="unsafe_path", message="The update contains unsafe paths.", fatal=True)
                finish("failed")
                return
        os.makedirs(target, exist_ok=True)
        archive.extractall(target)
    import compileall
    compileall.compile_dir(target, quiet=1, invalidation_mode=None)
    finish("completed")


def op_selftest(request):
    info = versions()
    problems = []
    if "gallery_dl" not in info:
        problems.append("gallery-dl could not be loaded")
    if "yt_dlp" not in info:
        problems.append("yt-dlp could not be loaded")
    import egress_guard
    try:
        egress_guard.check("POST", "https://upload.example.invalid/upload", data=b"x", files={"f": b"x"})
        problems.append("egress guard allowed an upload")
    except egress_guard.PolicyViolation:
        pass
    try:
        import requests
        requests.Session().request("PUT", "https://example.invalid/", data=b"x")
        problems.append("egress guard did not wrap requests")
    except egress_guard.PolicyViolation:
        pass
    except Exception as exc:
        problems.append(f"egress guard check failed: {exc}")
    STATE["violations"] = 0
    if not info.get("ffmpeg"):
        problems.append("ffmpeg was not found")
    EMITTER.emit("hello", **info)
    if problems:
        EMITTER.emit("error", code="selftest", message="; ".join(problems), fatal=True)
        EMITTER.emit("done", status="failed", counts={})
    else:
        EMITTER.emit("done", status="completed", counts={})


def main():
    global EMITTER
    events_fd = os.dup(1)
    os.dup2(2, 1)
    sys.stdout = sys.stderr
    EMITTER = Emitter(os.fdopen(events_fd, "w", buffering=1, encoding="utf-8"))

    def on_signal(signum, frame):
        stop_children()
        EMITTER.emit_last("done", status="cancelled", counts={})
        os._exit(130)

    signal.signal(signal.SIGINT, on_signal)
    signal.signal(signal.SIGTERM, on_signal)
    track_children()

    try:
        request = read_request()
    except ValueError as exc:
        EMITTER.emit("error", code="internal", message=f"Bad request: {exc}", fatal=True)
        EMITTER.emit("done", status="failed", counts={})
        return 2
    if request.get("v", PROTOCOL) != PROTOCOL:
        EMITTER.emit("error", code="protocol", message="Protocol version mismatch.", fatal=True)
        EMITTER.emit("done", status="failed", counts={})
        return 2

    configure_paths(request)
    install_logging()
    op = request.get("op")
    try:
        install_guard()
        if op == "hello":
            EMITTER.emit("hello", **versions())
            EMITTER.emit("done", status="completed", counts={})
        elif op == "selftest":
            op_selftest(request)
        elif op == "supports":
            op_supports(request)
        elif op == "account":
            op_account(request)
        elif op in ("scan", "pull"):
            run_gallery_job(request, op)
        elif op == "fetch":
            run_gallery_job(request, "pull")
        elif op == "stream":
            op_stream(request)
        elif op == "video_info":
            op_video_info(request)
        elif op == "install_wheel":
            op_install_wheel(request)
        else:
            EMITTER.emit("error", code="internal", message=f"Unknown operation {op}", fatal=True)
            EMITTER.emit("done", status="failed", counts={})
            return 2
    except Exception as exc:
        name = exc.__class__.__name__
        if name == "PolicyViolation":
            finish("failed")
            return 1
        traceback.print_exc()
        EMITTER.emit("error", code="internal", message=_clean(f"{name}: {exc}"), fatal=True)
        EMITTER.emit("done", status="failed", counts={})
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
