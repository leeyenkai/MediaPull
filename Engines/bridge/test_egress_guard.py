"""Tests for the engine egress guard (SPEC R-505). Run with the bundled interpreter:

    python3 -I Engines/bridge/test_egress_guard.py <site-packages>
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
if len(sys.argv) > 1:
    sys.path.insert(1, sys.argv.pop(1))

import egress_guard  # noqa: E402
from egress_guard import PolicyViolation, check  # noqa: E402


class GuardTests:
    def test_reads_are_allowed(self):
        check("GET", "https://www.instagram.com/api/v1/users/web_profile_info/?username=x")
        check("HEAD", "https://scontent.cdninstagram.com/v/a.jpg")
        check("get", "http://example.com/a.png")

    def test_instagram_graphql_queries_are_allowed(self):
        check("POST", "https://www.instagram.com/api/graphql",
              data={"fb_api_req_friendly_name": "PolarisProfilePostsTabContentQuery_connection", "doc_id": "1", "variables": "{}"},
              headers={"X-FB-Friendly-Name": "PolarisProfilePostsTabContentQuery_connection"})
        check("POST", "https://www.instagram.com/graphql/query", data="fb_api_req_friendly_name=PolarisProfilePageContentQuery&doc_id=2")

    def test_write_operations_are_blocked(self):
        for name in ("usePolarisLikeMediaMutation", "PolarisFollowMutation", "PolarisStoriesSeenQuery", "CommentCreateQuery",
                     "SaveMediaQuery"):
            with self.assertRaises(PolicyViolation, msg=name):
                check("POST", "https://www.instagram.com/api/graphql", data={"fb_api_req_friendly_name": name})

    def test_audited_site_reads_are_allowed(self):
        check("POST", "https://www.deviantart.com/oauth2/token", data={"grant_type": "client_credentials"})
        check("POST", "https://www.behance.net/v3/graphql", data={"query": "query GetProfileProjects($u: String) { user { id } }"})
        check("POST", "https://api.e-hentai.org/api.php", data={"method": "gdata", "gidlist": [[1, "a"]]})
        check("POST", "https://inkbunny.net/api_login.php", data={"username": "guest", "password": ""})
        check("POST", "https://api.x.com/1.1/guest/activate.json")
        check("POST", "https://www.reddit.com/api/v1/access_token",
              data={"grant_type": "https://oauth.reddit.com/grants/installed_client", "device_id": "DO_NOT_TRACK_THIS_DEVICE"})
        check("POST", "https://members.luscious.net/graphql/nobatch/?operationName=AlbumGet", data={"variables": {"id": 1}})
        check("POST", "https://imx.to/i/abc", data={"imgContinue": "Continue+to+image+...+"})
        check("POST", "https://rule34.xyz/api/v2/post/search/root", data={"tag": "x", "skip": 0})
        check("POST", "https://misskey.io/api/users/notes", data={"userId": "1", "limit": 100})

    def test_sign_ins_and_account_actions_stay_blocked(self):
        blocked = [
            ("POST", "https://www.deviantart.com/oauth2/token", {"grant_type": "refresh_token", "refresh_token": "x"}),
            ("POST", "https://www.deviantart.com/api/v1/oauth2/user/friends/watch/someone", {}),
            ("POST", "https://e-hentai.org/gallerypopups.php?act=addfav", {"favcat": "1"}),
            ("POST", "https://e-hentai.org/api.php", {"method": "rategallery"}),
            ("POST", "https://e-hentai.org/home.php", {"reset_imagelimit": "Reset Limit"}),
            ("POST", "https://inkbunny.net/api_login.php", {"username": "me", "password": "secret"}),
            ("POST", "https://www.behance.net/v3/graphql", {"query": "mutation Follow { follow(id: 1) }"}),
            ("POST", "https://api.scrolller.com/admin", {"query": "query LoginQuery { login }", "operationName": "LoginQuery"}),
            ("POST", "https://www.newgrounds.com/suitabilities", {"suitabilities": "a"}),
            ("POST", "https://www.newgrounds.com/age-verification/ignore-filter", {}),
            ("POST", "https://toyhou.se/~account/warnings/accept", {}),
            ("POST", "https://www.reddit.com/api/v1/access_token", {"grant_type": "refresh_token"}),
            ("POST", "https://imx.to/i/abc", {"imgContinue": "x", "password": "y"}),
            ("POST", "https://vk.com/al_photos.php", {"act": "like"}),
        ]
        for method, url, data in blocked:
            with self.assertRaises(PolicyViolation, msg=url):
                check(method, url, data=data)
        with self.assertRaises(PolicyViolation):
            check("GET", "https://vipergirls.to/post_thanks.php?do=post_thanks_add&p=1")
        check("GET", "https://vipergirls.to/threads/1")

    def test_graphql_persisted_writes_are_blocked_on_site_endpoints(self):
        for url, name in (("https://api.cosmos.so/graphql", "likePhoto"), ("https://api.cosmos.so/graphql", "followUser"),
                          ("https://api.cosmos.so/graphql", "addElementToCluster"), ("https://www.behance.net/v3/graphql", "SAVEPROJECT"),
                          ("https://members.luscious.net/graphql/nobatch/?operationName=AlbumAddFavorite", None)):
            data = {"operationName": name, "variables": {"id": 1}} if name else {"variables": {"id": 1}}
            with self.assertRaises(PolicyViolation, msg=f"{url} {name}"):
                check("POST", url, data=data)
        for name in ("SubredditQuery", "RedditUserPostsQuery", "GetFollowingSubreddits", "GetUserPublicElementsV2", "Get_comicNode",
                     "GetMoodboardItemsAndRecommendations"):
            check("POST", "https://api.scrolller.com/admin", data={"operationName": name, "variables": {"id": 1}})

    def test_sign_in_keys_are_found_at_any_depth(self):
        for data in ({"variables": {"input": {"password": "x"}}, "operationName": "GetClusterBasic"},
                     {"operationName": "GetClusterBasic", "variables": '{"auth": [{"refresh_token": "x"}]}'},
                     '{"query": "query Q { a }", "variables": {"login": {"Password": "x"}}}'):
            with self.assertRaises(PolicyViolation, msg=str(data)):
                check("POST", "https://api.cosmos.so/graphql", data=data)
        with self.assertRaises(PolicyViolation):
            check("POST", "https://rule34.xyz/api/v2/post/search/root", data={"filter": {"otp": "1"}})

    def test_youtube_channel_pages_are_read(self):
        body = '{"context": {"client": {"clientName": "WEB"}}, "continuation": "abc"}'
        check("POST", "https://www.youtube.com/youtubei/v1/browse?prettyPrint=false", data=body)
        with self.assertRaises(PolicyViolation):
            check("POST", "https://www.youtube.com/youtubei/v1/browse/edit_playlist", data=body)

    def test_urllib_redirect_hops_are_checked(self):
        import urllib.request

        from yt_dlp.networking._urllib import RedirectHandler

        reported = []
        egress_guard.install(reported.append, patch_ytdlp=False)
        # yt-dlp's handler keeps the method and body on 307 and 308 (the standard one refuses to resend a POST).
        handler = RedirectHandler()
        start = urllib.request.Request("https://www.deviantart.com/oauth2/token", data=b"grant_type=client_credentials", method="POST")
        # A 307 keeps the method and body: a POST to a host outside the allowed reads must be stopped.
        with self.assertRaises(PolicyViolation):
            handler.redirect_request(start, None, 307, "Temporary Redirect", {}, "https://collector.example.invalid/token")
        get = urllib.request.Request("https://example.com/a.jpg")
        follow = handler.redirect_request(get, None, 302, "Found", {}, "https://cdn.example.com/a.jpg")
        self.assertEqual(follow.full_url, "https://cdn.example.com/a.jpg")

    def test_every_redirect_hop_is_checked(self):
        import io
        import requests

        reported = []
        egress_guard.install(reported.append, patch_ytdlp=False)

        class Redirecting(requests.adapters.BaseAdapter):
            def __init__(self, status, location):
                requests.adapters.BaseAdapter.__init__(self)
                self.status, self.location, self.sent = status, location, []

            def send(self, request, **kwargs):
                self.sent.append((request.method, request.url))
                response = requests.Response()
                response.request, response.url, response.raw = request, request.url, io.BytesIO(b"")
                if request.url.startswith("https://www.deviantart.com/"):
                    response.status_code = self.status
                    response.headers["Location"] = self.location
                else:
                    response.status_code = 200
                return response

            def close(self):
                pass

        for status in (307, 308):
            adapter = Redirecting(status, "https://collector.example.invalid/token")
            session = requests.Session()
            session.mount("https://", adapter)
            with self.assertRaises(PolicyViolation, msg=str(status)):
                session.post("https://www.deviantart.com/oauth2/token", data={"grant_type": "client_credentials"})
            self.assertEqual(adapter.sent, [("POST", "https://www.deviantart.com/oauth2/token")])
        self.assertEqual(len(reported), 2)
        # A 303 turns the POST into a GET, which may go anywhere.
        adapter = Redirecting(303, "https://images.example.invalid/a.png")
        session = requests.Session()
        session.mount("https://", adapter)
        session.post("https://www.deviantart.com/oauth2/token", data={"grant_type": "client_credentials"})
        self.assertEqual(adapter.sent[-1], ("GET", "https://images.example.invalid/a.png"))

    def test_graphql_mutation_documents_are_blocked(self):
        ig = "https://www.instagram.com/graphql/query"
        with self.assertRaises(PolicyViolation):
            check("POST", ig, data='{"query": "mutation Like { like(id: 1) }"}')
        with self.assertRaises(PolicyViolation):
            check("POST", ig, data='{"query": "fragment F on U { id } mutation M { like(id: 1) }"}')
        with self.assertRaises(PolicyViolation):
            check("POST", ig, data={"fb_api_req_friendly_name": "PolarisunfollowQuery"})
        check("POST", ig, data='{"operationName": "UserMediaQuery", "query": "query UserMediaQuery { a }"}')

    def test_post_is_limited_to_instagram_graphql(self):
        for url in ("https://evil.example/graphql", "https://www.instagram.com/api/v1/upload/graphql",
                    "https://instagram.com.evil.example/api/graphql"):
            with self.assertRaises(PolicyViolation, msg=url):
                check("POST", url, data={"fb_api_req_friendly_name": "ExfilQuery"})
        with self.assertRaises(PolicyViolation):
            check("POST", "https://www.instagram.com/api/graphql", data={"fb_api_req_friendly_name": "AQuery"},
                  headers={"Content-Type": "multipart/form-data; boundary=x"})

    def test_youtube_video_reads_are_allowed_and_nothing_else(self):
        body = '{"context": {"client": {"clientName": "WEB"}}, "videoId": "aqz-KE-bpKQ"}'
        check("POST", "https://www.youtube.com/youtubei/v1/player?prettyPrint=false", data=body)
        check("POST", "https://youtubei.googleapis.com/youtubei/v1/next", data=body)
        for url in ("https://www.youtube.com/youtubei/v1/like/like", "https://www.youtube.com/youtubei/v1/subscription/subscribe",
                    "https://www.youtube.com/youtubei/v1/comment/create_comment", "https://www.youtube.com/upload",
                    "https://youtube.com.evil.example/youtubei/v1/player"):
            with self.assertRaises(PolicyViolation, msg=url):
                check("POST", url, data=body)
        with self.assertRaises(PolicyViolation):
            check("POST", "https://www.youtube.com/youtubei/v1/player", data="x" * 20000)
        with self.assertRaises(PolicyViolation):
            check("POST", "https://www.youtube.com/youtubei/v1/player", data=b"\x00", headers={"Content-Type": "application/octet-stream"})

    def test_reads_never_carry_a_body(self):
        with self.assertRaises(PolicyViolation):
            check("GET", "https://example.com/", data="x" * 1000)
        check("GET", "https://example.com/", data=None)

    def test_uploads_and_other_methods_are_blocked(self):
        for method in ("PUT", "PATCH", "DELETE", "OPTIONS"):
            with self.assertRaises(PolicyViolation):
                check(method, "https://example.com/")
        with self.assertRaises(PolicyViolation):
            check("POST", "https://www.instagram.com/api/graphql", files={"photo": b"x"})
        with self.assertRaises(PolicyViolation):
            check("POST", "https://i.instagram.com/rupload_igphoto/x", data=b"\xff\xd8")
        with self.assertRaises(PolicyViolation):
            check("POST", "https://www.instagram.com/api/graphql", data="x" * 20000)
        with self.assertRaises(PolicyViolation):
            check("GET", "file:///etc/passwd")

    def test_requests_session_is_wrapped(self):
        reported = []
        egress_guard.install(reported.append, patch_ytdlp=False)
        import requests

        with self.assertRaises(PolicyViolation):
            requests.Session().request("POST", "https://upload.example.invalid/", files={"f": b"x"})
        with self.assertRaises(PolicyViolation):
            requests.Session().request("GET", "https://example.invalid/", None, "positional body")
        self.assertEqual(len(reported), 2)


class _Raises:
    def __init__(self, kind, msg=None):
        self.kind = kind
        self.msg = msg

    def __enter__(self):
        return self

    def __exit__(self, kind, value, traceback):
        if kind is None:
            raise AssertionError(f"{self.kind.__name__} not raised {self.msg or ''}")
        return issubclass(kind, self.kind)


def main():
    suite = GuardTests()
    suite.assertRaises = lambda kind, msg=None: _Raises(kind, msg)
    suite.assertEqual = lambda a, b: None if a == b else (_ for _ in ()).throw(AssertionError(f"{a} != {b}"))
    names = [name for name in dir(suite) if name.startswith("test_")]
    failures = 0
    for name in names:
        try:
            getattr(suite, name)()
            print(f"ok   {name}")
        except Exception as exc:
            failures += 1
            print(f"FAIL {name}: {exc}")
    print(f"{len(names)} tests, {failures} failures")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
