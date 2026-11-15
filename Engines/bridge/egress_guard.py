"""Egress guard for the bundled engines (SPEC R-505).

Installed before any engine code runs. Every HTTP request made by gallery-dl (through
requests.Session) or yt-dlp (through YoutubeDL.urlopen) is checked here first:

- GET and HEAD to http and https URLs are allowed, without a body.
- POST is allowed only for Instagram's GraphQL read endpoints (an operation name that is a query and
  names no write action), YouTube's player and next endpoints, which read a video's details, and the
  read-only POSTs other sites need (READ_POSTS, D-72): listings, searches, file links and anonymous tokens,
  each audited against the bundled gallery-dl. Never logins, files, multipart or binary bodies, or a large body.
- A few GETs that act on an account (READ_GETS_DENIED) are refused as well.
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

# Read-only POSTs that gallery-dl's site extractors need (D-72, docs/spikes/gallery-dl-post-audit.md): (hosts, path, body rule).
# Hosts match exactly or as a parent domain. Logins, consent forms that could be stored on a signed-in account, and
# anything that changes an account (favourites, watching, likes, rating settings, quota resets) are not listed.
_RULE34_SEARCH = r"/api/v2/post/search/(root|playlist/[^/]+)"
READ_POSTS = (
    (("artstation.com",), r"/api/v2/(search/projects\.json|csrf_protection/token\.json)", None),
    (("api-neo.500px.com",), r"/graphql", "graphql"),
    (("api.audiochan.com",), r"/audios/[^/]+/(play-intent|stream-url)", None),
    (("behance.net",), r"/v3/graphql", "graphql"),
    (("dl.bunkr.cr",), r"/api/_001_v2", None),
    (("search-new.civitai.com",), r"/multi-search", None),
    (("api.cosmos.so",), r"/graphql", "graphql"),
    (("deviantart.com",), r"/oauth2/token", "client_credentials"),
    (("reddit.com",), r"/api/v1/access_token", "installed_client"),
    (("api.joyreactor.com",), r"/graphql", "graphql"),
    (("members.luscious.net",), r"/graphql/nobatch", "graphql"),
    (("www.blogger.com",), r"/_/BloggerVideoPlayerUi/data/batchexecute", None),
    (("cyberfile.me",), r"/account/ajax/(load_files|file_details)", "no_password"),
    (("cosplayrule34.com",), r"/cms/load-more-photos\.php", None),
    (("plurk.com",), r"/(Responses/get|TimeLine/getPlurks)", None),
    (("filester.me",), r"/v2/api/public/download", "no_password"),
    (("furry34.com", "rule34.xyz", "rule34.world", "rule34vault.com", "yiffverse.com"), _RULE34_SEARCH, None),
    (("api.gofile.io",), r"/accounts", "empty"),
    (("imx.to", "img.yt", "imx.bz", "imx.tw", "acidimg.cc", "imgclick.net", "silverpic.net", "silverpic.com"), r"/.*", "interstitial"),
    (("algolianet.com",), r"/1/indexes/\*/queries", None),
    (("steamcommunity.com",), r"/(id|profiles)/[^/]+/[^/]+/screenshots", None),
    (("vk.com",), r"/al_photos\.php", "vk_show"),
    (("furaffinity.net",), r"/search", None),
    (("hentai-foundry.com",), r"/site/filters", None),
    (("inkbunny.net",), r"/api_login\.php", "guest"),
    (("kabe-uchiroom.com",), r"/get_posts\.php", None),
    (("kagane.si",), r"/api/(integrity|v2/books/[^/]+)", None),
    (("lexica.art",), r"/api/infinite-prompts", None),
    (("api.lofter.com",), r"/(v2\.0/blogHomePage\.api|oldapi/post/detail\.api)", None),
    (("mangapark.com", "mangapark.net", "mangapark.org", "mangapark.me", "mangapark.io", "mangapark.to", "comicpark.com",
      "comicpark.net", "comicpark.org", "comicpark.me", "comicpark.io", "comicpark.to", "readpark.com", "readpark.net",
      "readpark.org", "readpark.me", "readpark.io", "readpark.to", "parkmanga.com", "parkmanga.net", "parkmanga.org",
      "mpark.to"), r"/apo", "graphql"),
    (("misskey.io", "misskey.design", "misskey.art", "sushi.ski"), r"/api/(users/show|users/notes|users/following|notes/show)", None),
    (("e-hentai.org", "exhentai.org"), r"/api\.php", "ehentai"),
    (("pornhub.com",), r"/[^/]+/[^/]+/(photos|gifs)(/[^/]+)?/ajax", None),
    (("poipiku.com",), r"/f/(ShowIllustDetailF|ShowAppendFileF)\.jsp", None),
    (("api.schale.network",), r"/books/detail/[^/]+/[^/]+", None),
    (("api.scrolller.com",), r"/admin", "graphql"),
    (("sxypix.com",), r"/php/gall\.php", None),
    (("slickpic.com",), r"/xhr/photo/get/list", None),
    (("steamgriddb.com",), r"/api/public/search/assets", None),
    (("api.x.com", "api.twitter.com"), r"/1\.1/guest/activate\.json", "empty"),
    (("uploadir.com",), r"/u/[^/]+/download.*|/files/[^/]+/download.*", None),
    (("passport.weibo.com",), r"/visitor/genvisitor2", None),
    (("ibb.co", "imgbb.com"), r"/json", "imgbb_list"),
    (("booru.bcbnsfw.space", "snootbooru.com", "visuabusters.com", "ricardo.adacor.org"),
     r"(/booru)?/\.gatekeeper/cmd/accept18plusUnverified", None),
    (("webmshare.com",), r"/is_adult", None),
)
EHENTAI_METHODS = ("gdata", "gtoken", "showpage", "imagedispatch")
INTERSTITIAL_FIELDS = {"imgContinue", "op", "id", "pre", "adb", "next"}
# GETs that act on an account: thanking or liking a post.
READ_GETS_DENIED = (
    (("vipergirls.to",), r"/post_thanks\.php", r"do=post_thanks_add"),
)

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
        host = (parts.hostname or "").lower()
        for hosts, path, query in READ_GETS_DENIED:
            if _host_in(host, hosts) and re.fullmatch(path, parts.path) and re.search(query, parts.query or ""):
                raise PolicyViolation(method, url, "this request would act on an account")
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
    for hosts, pattern, rule in READ_POSTS:
        if _host_in(host, hosts) and re.fullmatch(pattern, parts.path.rstrip("/") or "/"):
            _check_body(rule, method, url, data, headers, parts)
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


def _host_in(host, hosts):
    return any(host == h or host.endswith("." + h) for h in hosts)


def _fields(data):
    if isinstance(data, dict):
        return {str(k): v for k, v in data.items()}
    if isinstance(data, (bytes, bytearray)):
        return _parse_text_body(bytes(data).decode("utf-8", "replace"))
    if isinstance(data, str):
        return _parse_text_body(data)
    return {}


def _first(value):
    return value[0] if isinstance(value, list) and value else value


def _check_body(rule, method, url, data, headers, parts):
    """The body rules for READ_POSTS: each makes sure the request reads and never signs in or acts on an account."""
    fields = _fields(data)
    lowered = {k.lower() for k in fields}
    if {"password", "pass", "passwd", "refresh_token", "otp"} & lowered and rule != "guest":
        raise PolicyViolation(method, url, "sign-in requests are never sent")
    if rule is None:
        return
    if rule == "graphql":
        query = _first(fields.get("query"))
        names = [str(_first(fields.get(k))) for k in ("operationName",) if fields.get(k)]
        names += [v for k, vs in parse_qs(parts.query).items() if k in ("operationName", "q") for v in vs]
        if isinstance(query, str) and query.strip():
            document = re.sub(r"#[^\n]*", "", query)
            if re.search(r"\b(mutation|subscription)\b", document, re.IGNORECASE):
                raise PolicyViolation(method, url, "GraphQL mutations are never sent")
        elif not names:
            raise PolicyViolation(method, url, "GraphQL request without a query or an operation name")
        for name in names:
            if re.search(r"(Login|Mutation|^(Like|Follow|Unfollow|Create|Delete|Update|Add|Remove|Vote|Report|Save|Mark|Send))", name):
                raise PolicyViolation(method, url, f"operation {name} is not a read")
    elif rule == "client_credentials":
        if _first(fields.get("grant_type")) != "client_credentials":
            raise PolicyViolation(method, url, "only the public access token is requested")
    elif rule == "installed_client":
        if _first(fields.get("grant_type")) != "https://oauth.reddit.com/grants/installed_client":
            raise PolicyViolation(method, url, "only the app-only access token is requested")
    elif rule == "guest":
        if _first(fields.get("username")) != "guest" or (_first(fields.get("password")) or ""):
            raise PolicyViolation(method, url, "only the guest session is opened")
    elif rule == "ehentai":
        if _first(fields.get("method")) not in EHENTAI_METHODS:
            raise PolicyViolation(method, url, "only gallery and image reads are sent")
    elif rule == "interstitial":
        if not fields or set(fields) - INTERSTITIAL_FIELDS or (fields.get("op") and _first(fields["op"]) != "view"):
            raise PolicyViolation(method, url, "only the continue-to-image form is sent")
    elif rule == "vk_show":
        if _first(fields.get("act")) != "show":
            raise PolicyViolation(method, url, "only photo listings are read")
    elif rule == "imgbb_list":
        if _first(fields.get("action")) != "list":
            raise PolicyViolation(method, url, "only album listings are read")
    elif rule == "empty":
        if fields:
            raise PolicyViolation(method, url, "this token request carries no data")
    elif rule == "no_password":
        pass


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
