"""Stand-in bridge for `--selftest-update`, never bundled with the app.

Replays recorded Instagram events offline so the whole update path in the app runs without the network: it skips every
item the request's known list names (by `ig:<media_id>` or, for posts and Reels, `igp:<post_id>:<num>`, as the real
bridge does, D-79) and reports the rest as files copied into staging. It reads only the replay file the self-test wrote
into its engine home folder.
"""

import json
import os
import shutil
import sys

POSITIONAL = ("posts", "reels", "tagged", "reposts")


def main():
    request = json.loads(sys.stdin.read() or "{}")
    seq = 0

    def emit(kind, **fields):
        nonlocal seq
        seq += 1
        sys.stdout.write(json.dumps({"v": 1, "seq": seq, "type": kind, **fields}) + "\n")
        sys.stdout.flush()

    emit("hello", python=sys.version.split()[0], protocol=1)
    if request.get("op") == "stream":
        return stream(request, emit)
    if request.get("op") == "supports":
        # A made-up gallery site at example.org (`--selftest-save-as`), worked out locally as the real bridge does.
        if "example.org" in str(request.get("url") or ""):
            emit("supports", supported=True, category="testsite", subcategory="user", choices=[], defaults=[])
        else:
            emit("supports", supported=False)
        emit("done", status="completed", counts={})
        return 0
    if request.get("op") == "video_info":
        with open(os.path.join(os.environ["HOME"], "replay.json"), encoding="utf-8") as handle:
            info = json.load(handle).get("video_info")
        if info:
            emit("video_info", formats=[], **info)
        emit("done", status="completed", counts={})
        return 0
    if request.get("op") != "pull":
        emit("done", status="completed", counts={})
        return 0
    with open(os.path.join(os.environ["HOME"], "replay.json"), encoding="utf-8") as handle:
        replay = json.load(handle)
    def listed(name):
        if not request.get(name):
            return set()
        with open(request[name], encoding="utf-8") as handle:
            return set(json.load(handle))

    # As the real bridge's tracker_for: the stories tray is read against the owners' list, saved posts against the saved
    # list, everything else against the known list.
    known, owners, saved = listed("known_ids"), listed("owners_known_ids"), listed("saved_known_ids")
    # A job's own items (retry_ids) are skipped but never count towards the early stop, as KnownTracker does.
    own = listed("retry_ids")
    # A gallery address replays the gallery's own items.
    items = replay.get("gallery_items") if "example.org" in str(request.get("url") or "") else replay["items"]
    emit("account", **replay["account"])
    # As the real bridge: only the content asked for is listed, and only a walk of the posts listing reports its end.
    include = set(request.get("include") or [])
    walks_posts = not include or "posts" in include
    # "fail_files": item numbers whose file fails to download; the walk goes on and the pull ends "partial".
    fail_files = set(replay.get("fail_files") or [])
    failed_files = 0
    counts = {"found": 0, "downloaded": 0, "skipped": 0, "failed": 0}
    # "stop_after": the pull is cut off after that many items, as when MediaPull quits part way.
    stop_after = replay.get("stop_after")
    # As the real bridge: a cursor "after-N" continues after the Nth item, and stop_after_known ends the listing after that
    # many known items in a row.
    start = 0
    if str(request.get("cursor") or "").startswith("after-"):
        start = int(str(request["cursor"]).split("-", 1)[1])
    stop_known = request.get("stop_after_known")
    known_in_a_row = 0
    # "fail_after_listing": the posts listing ends, then the pull fails (as a failed Reel download would).
    fail_after_listing = replay.get("fail_after_listing")
    emit("log", level="info", logger="stand-in", message=f"start {start}")
    # "cursor_posts_only": as the real engine, a cursor places only the posts listing; other parts are listed from the top.
    posts_only = replay.get("cursor_posts_only")
    # "checkpoint_after": Instagram asks for a check after that many files, and the pull is held.
    checkpoint_after = replay.get("checkpoint_after")
    for number, item in enumerate(items, 1):
        if number <= start and (not posts_only or item["meta"].get("subcategory") == "posts"):
            continue
        if checkpoint_after is not None and counts["downloaded"] >= checkpoint_after:
            emit("checkpoint", kind="challenge", url="https://www.instagram.com/challenge/", message="A check is needed.")
            emit("done", status="failed", counts=counts)
            return 0
        if stop_known and known_in_a_row >= stop_known:
            break
        if stop_after is not None and number > stop_after:
            emit("error", code="network", message="Stopped part way.", fatal=True)
            emit("done", status="failed", counts=counts)
            return 0
        meta = item["meta"]
        if include and meta.get("subcategory") not in include:
            continue
        keys = {item["key"]}
        if meta.get("subcategory") in POSITIONAL and meta.get("post_id") and meta.get("num"):
            keys.add(f"igp:{meta['post_id']}:{meta['num']}")
        counts["found"] += 1
        against = owners if meta.get("subcategory") == "stories-tray" else saved if meta.get("subcategory") in ("saved", "collection") else known
        if keys & own and not keys & against:
            counts["skipped"] += 1
            emit("skip", key=item["key"], reason="own")
            emit("cursor", subcategory="posts", value=f"after-{number}")
            continue
        if keys & against:
            counts["skipped"] += 1
            known_in_a_row += 1
            emit("skip", key=item["key"], reason="known")
            emit("cursor", subcategory="posts", value=f"after-{number}")
            continue
        known_in_a_row = 0
        if number in fail_files:
            failed_files += 1
            emit("error", code="download_failed", message="Failed to download a file", key=item["key"], fatal=False)
            emit("cursor", subcategory="posts", value=f"after-{number}")
            continue
        target = os.path.join(request["staging"], os.path.basename(item["source"]))
        shutil.copyfile(item["source"], target)
        counts["downloaded"] += 1
        emit("file", key=item["key"], path=target, bytes=os.path.getsize(target), subcategory=meta.get("subcategory"), meta=meta)
        emit("cursor", subcategory="posts", value=f"after-{number}")
    # The listing ended: at its last item, or at the folder's known posts (D-87).
    if walks_posts:
        emit("listing", subcategory="posts", complete=True, cursor=None)
    if fail_after_listing:
        emit("error", code="network", message="A Reel could not be downloaded.", fatal=True)
        emit("done", status="failed", counts=counts)
        return 0
    emit("done", status="partial" if failed_files else "completed", counts=counts)
    return 0


def stream(request, emit):
    """Video downloads (`--selftest-save-as`): the replay's "videos" are reported as downloaded, except those whose id the
    request's extras name in skip_ids, as yt-dlp's match filter skips them in the real bridge."""
    with open(os.path.join(os.environ["HOME"], "replay.json"), encoding="utf-8") as handle:
        replay = json.load(handle)
    skip = set((request.get("extras") or {}).get("skip_ids") or [])
    for video in replay.get("videos") or []:
        meta = video["meta"]
        if meta.get("id") in skip:
            emit("log", level="info", logger="stand-in", message=f"skipped {meta.get('id')}")
            continue
        target = os.path.join(request["staging"], os.path.basename(video["source"]))
        shutil.copyfile(video["source"], target)
        emit("file", key=video["key"], path=target, bytes=os.path.getsize(target), subcategory="video", meta=meta)
    emit("done", status="completed", counts={})
    return 0


if __name__ == "__main__":
    sys.exit(main())
