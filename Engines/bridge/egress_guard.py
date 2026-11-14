"""Egress guard for the bundled engines (SPEC R-505).

Installed before any engine code runs. Every HTTP request made by gallery-dl (through
requests.Session) or yt-dlp (through YoutubeDL.urlopen) is checked here first:

- GET and HEAD to http and https URLs are allowed, without a body.
- POST is allowed only for Instagram's GraphQL read endpoints (an operation name that is a query and
  names no write action) and YouTube's player and next endpoints, which read a video's details. Never
  files, multipart or binary bodies, or a large body.
- Everything else raises PolicyViolation before any byte leaves the machine.
"""

import inspect
import json
import re
from urllib.parse import parse_qs, urlsplit

MAX_POST_BODY = 16 * 1024
DENIED_WORDS = re.compile(
    r"(Mutation|Like|Follow|Comment|Seen|Upload|Create|Delete|Edit|Save|Mark|Share|Send|Report|Block|"
    r"Mute|Vote|Subscribe|Unfollow|Remove|Update|Accept|Approve|Reply)",
    re.IGNORECASE,
)
POST_HOSTS = ("instagram.com",)
POST_PATHS = ("/graphql/query", "/api/graphql")
# YouTube's read endpoints for one video (D-55). Writing actions (like, subscribe, comment) live at other paths.
YOUTUBE_HOSTS = ("youtube.com", "youtubei.googleapis.com")
YOUTUBE_PATHS = ("/youtubei/v1/player", "/youtubei/v1/next")
BODY_TYPES_DENIED = ("multipart/", "application/octet-stream", "image/", "video/", "audio/")

_reporter = None


class PolicyViolation(Exception):
    def __init__(self, method, url, reason):
        Exception.__init__(self, f"Blocked {method} {url}: {reason}")
        self.method = method
        self.url = url
        self.reason = reason


def _operation_names(data, headers):
    names = []
    if headers:
        for key, value in dict(headers).items():
            if str(key).lower() == "x-fb-friendly-name" and value:
                names.append(str(value))
    fields = {}
    if isinstance(data, dict):
        fields = {str(k): v for k, v in data.items()}
    elif isinstance(data, (bytes, bytearray)):
        text = bytes(data).decode("utf-8", "replace")
        fields = _parse_text_body(text)
    elif isinstance(data, str):
        fields = _parse_text_body(data)
    for key in ("fb_api_req_friendly_name", "operationName"):
        value = fields.get(key)
        if isinstance(value, list):
            value = value[0] if value else None
        if value:
            names.append(str(value))
    query = fields.get("query")
    if isinstance(query, list):
        query = query[0] if query else None
    if isinstance(query, str) and query.strip():
        document = re.sub(r"#[^\n]*", "", query)
        if re.search(r"\b(mutation|subscription)\b", document, re.IGNORECASE):
            names.append("Mutation")
        else:
            head = document.strip().split("{", 1)[0].strip()
            names.append(head.split("(")[0].replace("query", "", 1).strip() + "Query")
    return names


def _parse_text_body(text):
    text = text.strip()
    if text.startswith("{"):
        try:
            value = json.loads(text)
            return value if isinstance(value, dict) else {}
        except ValueError:
            return {}
    return {k: v for k, v in parse_qs(text, keep_blank_values=True).items()}


def _body_size(data):
    if data is None:
        return 0
    if isinstance(data, (bytes, bytearray, str)):
        return len(data)
    if isinstance(data, dict):
        return len(json.dumps(data, default=str))
    return MAX_POST_BODY + 1


def check(method, url, data=None, headers=None, files=None):
    """Raises PolicyViolation unless the request is a permitted read."""
    method = (method or "GET").upper()
    parts = urlsplit(str(url))
    if parts.scheme not in ("http", "https"):
        raise PolicyViolation(method, url, "only http and https are allowed")
    if method in ("GET", "HEAD"):
        if files:
            raise PolicyViolation(method, url, "file bodies are never sent")
        if data not in (None, b"", "", {}):
            raise PolicyViolation(method, url, "reads never carry a body")
        return
    if method != "POST":
        raise PolicyViolation(method, url, "only GET, HEAD and read-only POST requests are allowed")
    if files:
        raise PolicyViolation(method, url, "file bodies are never sent")
    if hasattr(data, "read") or (data is not None and not isinstance(data, (dict, bytes, bytearray, str))):
        raise PolicyViolation(method, url, "streamed bodies are never sent")
    if _body_size(data) > MAX_POST_BODY:
        raise PolicyViolation(method, url, "body too large for a read query")
    host = (parts.hostname or "").lower()
    path = parts.path.rstrip("/").lower()
    if headers:
        for key, value in dict(headers).items():
            if str(key).lower() == "content-type" and str(value).lower().startswith(BODY_TYPES_DENIED):
                raise PolicyViolation(method, url, "binary and multipart bodies are never sent")
    if any(host == h or host.endswith("." + h) for h in YOUTUBE_HOSTS) and path in YOUTUBE_PATHS:
        return
    if not any(host == h or host.endswith("." + h) for h in POST_HOSTS) or path not in POST_PATHS:
        raise PolicyViolation(method, url, "POST is only allowed for Instagram GraphQL and YouTube player read requests")
    names = _operation_names(data, headers)
    if not names:
        raise PolicyViolation(method, url, "GraphQL request without an operation name")
    for name in names:
        if "Query" not in name and not name.lower().endswith("query"):
            raise PolicyViolation(method, url, f"operation {name} is not a query")
        if DENIED_WORDS.search(re.sub("query", "", name, flags=re.IGNORECASE)):
            raise PolicyViolation(method, url, f"operation {name} names a write action")


def _report(exc):
    if _reporter is not None:
        try:
            _reporter(exc)
        except Exception:
            pass


def install(reporter=None, patch_ytdlp=True):
    """Wraps the engines' HTTP entry points. Safe to call more than once."""
    global _reporter
    _reporter = reporter

    import requests

    if not getattr(requests.Session.request, "_mediapull_guard", False):
        original = requests.Session.request
        signature = inspect.signature(original)

        def guarded_request(self, method, url, *args, **kwargs):
            try:
                bound = signature.bind(self, method, url, *args, **kwargs).arguments
            except TypeError:
                bound = dict(kwargs)
            data = bound.get("data")
            json_body = bound.get("json")
            if json_body is not None and data in (None, b"", "", {}):
                data = json_body
            try:
                check(method, url, data=data, headers=bound.get("headers"), files=bound.get("files"))
            except PolicyViolation as exc:
                _report(exc)
                raise
            return original(self, method, url, *args, **kwargs)

        guarded_request._mediapull_guard = True
        requests.Session.request = guarded_request

    if patch_ytdlp:
        try:
            import yt_dlp
        except Exception:
            return
        cls = yt_dlp.YoutubeDL
        if not getattr(cls.urlopen, "_mediapull_guard", False):
            original_urlopen = cls.urlopen

            def guarded_urlopen(self, req):
                if isinstance(req, str):
                    method, url, data, headers = "GET", req, None, None
                else:
                    url = getattr(req, "url", None) or getattr(req, "full_url", "")
                    data = getattr(req, "data", None)
                    method = getattr(req, "method", None) or ("POST" if data else "GET")
                    headers = getattr(req, "headers", None)
                try:
                    check(method, url, data=data, headers=headers)
                except PolicyViolation as exc:
                    _report(exc)
                    raise
                return original_urlopen(self, req)

            guarded_urlopen._mediapull_guard = True
            cls.urlopen = guarded_urlopen
