#!/usr/bin/env python3
"""Builds MediaPull/Resources/SiteCatalogue.json from a gallery-dl source checkout (SPEC R-1111b).

The catalogue names every site the bundled gallery-dl supports, says how it signs in, and lists the site's own
switches that choose what media to download, with gallery-dl's defaults. Run it when the bundled gallery-dl changes:

    scripts/build_site_catalogue.py <gallery-dl source folder at the bundled tag>
"""

import html
import json
import os
import re
import sys

# Switches that only choose which media to fetch, with the label the Downloads pane shows. Anything that writes
# metadata only, follows other accounts, or changes account state (such as watching a user) is left out.
LABELS = {
    "videos": "Videos", "audio": "Audio", "gif": "Animated GIFs", "livephoto": "Live Photo videos", "covers": "Covers",
    "quoted": "Quoted posts", "reposts": "Reposts", "reblogs": "Reblogs", "retweets": "Retweets", "renotes": "Renotes",
    "replies": "Replies", "cards": "Link cards", "embeds": "Embedded media", "inline": "Inline images",
    "stories": "Story pins", "mature": "Mature content", "flash": "Flash originals", "svg": "SVG versions",
    "recursive": "Subfolders", "thumbnails": "Thumbnails", "previews": "Preview images", "external": "Media on linked sites",
}
AUTH = {"": "none", "Supported": "optional", "Cookies": "cookies", "OAuth": "oauth", "API Key": "key", "Required": "required"}


def options(path):
    text = open(path, encoding="utf-8").read()
    found = {}
    for block in re.split(r"\n(?=extractor\.[^\n]+\n-{3,}\n)", text):
        match = re.match(r"extractor\.([^\n]+)\n-{3,}\n(.*)", block, re.S)
        if not match:
            continue
        kind = re.search(r"Type\n\s+(.+?)\n(?=\S)", match.group(2), re.S)
        default = re.search(r"Default\n\s+(.+?)\n(?=\S)", match.group(2), re.S)
        if not kind or not kind.group(1).strip().startswith("``bool``"):
            continue
        for name in (n.strip() for n in match.group(1).split("|")):
            site, _, key = name.partition(".")
            if key not in LABELS or site == "*":
                continue
            site = site.strip("[]").lower()
            value = (default.group(1).split()[0] if default else "``false``").strip("`") == "true"
            found.setdefault(site, []).append({"key": key, "label": LABELS[key], "default": value})
    return found


def sites(path):
    text = open(path, encoding="utf-8").read()
    found = {}
    for row in re.finditer(r'<tr id="([^"]+)"[^>]*>(.*?)</tr>', text, re.S):
        cells = [html.unescape(re.sub(r"<[^>]+>", "", c)).strip().replace("\xa0", " ")
                 for c in re.findall(r"<td[^>]*>(.*?)</td>", row.group(2), re.S)]
        if len(cells) >= 4:
            found[row.group(1)] = {"name": cells[0], "home": cells[1], "auth": AUTH.get(cells[3], "optional")}
    return found


def main():
    source = sys.argv[1]
    version = re.search(r'__version__ = "([^"]+)"', open(os.path.join(source, "gallery_dl", "version.py")).read()).group(1)
    catalogue = {"galleryDL": version, "sites": sites(os.path.join(source, "docs", "supportedsites.md")),
                 "options": options(os.path.join(source, "docs", "configuration.rst"))}
    out = os.path.join(os.path.dirname(__file__), "..", "MediaPull", "Resources", "SiteCatalogue.json")
    with open(out, "w", encoding="utf-8") as file:
        json.dump(catalogue, file, indent=1, sort_keys=True, ensure_ascii=False)
        file.write("\n")
    print(f"{len(catalogue['sites'])} sites, {len(catalogue['options'])} with switches, gallery-dl {version}")


if __name__ == "__main__":
    main()
