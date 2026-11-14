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
