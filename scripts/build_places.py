"""Compiles GeoNames data into the offline place table (SPEC R-3605, D-59).

Usage: build_places.py <geonames folder> <output places.tsv>
Output: name, region, country, latitude, longitude, population; one place per line, tab separated.
"""

import csv
import io
import sys
import zipfile

src, out = sys.argv[1], sys.argv[2]

countries = {}
with open(f"{src}/countryInfo.txt", encoding="utf-8") as f:
    for line in f:
        if line.startswith("#"):
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) > 4:
            countries[parts[0]] = parts[4]

regions = {}
with open(f"{src}/admin1CodesASCII.txt", encoding="utf-8") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) > 1:
            regions[parts[0]] = parts[1]

rows = []
with zipfile.ZipFile(f"{src}/cities1000.zip") as z:
    with z.open("cities1000.txt") as raw:
        for parts in csv.reader(io.TextIOWrapper(raw, encoding="utf-8"), delimiter="\t", quoting=csv.QUOTE_NONE):
            if len(parts) < 15:
                continue
            name, lat, lon, cc, admin1, population = parts[1], parts[4], parts[5], parts[8], parts[10], parts[14]
            clean = lambda s: s.replace("\t", " ").strip()
            rows.append((clean(name), clean(regions.get(f"{cc}.{admin1}", "")), clean(countries.get(cc, cc)),
                         f"{float(lat):.4f}", f"{float(lon):.4f}", population or "0"))

rows.sort(key=lambda r: (r[2], r[1], r[0]))
with open(out, "w", encoding="utf-8") as f:
    for r in rows:
        f.write("\t".join(r) + "\n")
print(f"{len(rows)} places written to {out}")
