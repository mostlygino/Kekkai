#!/bin/sh
# Downloads Natural Earth 1:110m countries (public domain) and trims it to App/Resources/world.json:
# [{"cc": ISO code, "l": [lon, lat] label point, "p": [ring, ...] with rings as flat [lon, lat, ...]}]
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
curl -fsSL https://raw.githubusercontent.com/nvkelso/natural-earth-vector/master/geojson/ne_110m_admin_0_countries.geojson -o "$tmp/ne.json"
python3 -I - "$tmp/ne.json" App/Resources/world.json <<'PY'
import json, sys
out = []
for f in json.load(open(sys.argv[1]))["features"]:
    p = f["properties"]
    cc = p.get("ISO_A2_EH") or p.get("ISO_A2")
    if not cc or cc == "-99" or cc == "AQ":
        continue
    g = f["geometry"]
    polys = g["coordinates"] if g["type"] == "MultiPolygon" else [g["coordinates"]]
    rings = [[round(v, 2) for pt in poly[0] for v in pt] for poly in polys]   # outer rings only
    out.append({"cc": cc, "l": [round(p["LABEL_X"], 2), round(p["LABEL_Y"], 2)], "p": rings})
json.dump(out, open(sys.argv[2], "w"), separators=(",", ":"))
print(f"map: {len(out)} countries -> {sys.argv[2]}")
PY
