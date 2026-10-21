#!/bin/sh
# Downloads DB-IP "IP to Country Lite" (CC BY 4.0) and packs it into App/Resources/geoip.bin.
# Attribution is shown in the app (Map pane and Settings > About).
#
# geoip.bin layout, all big-endian, both tables sorted by start address:
#   "KKGEO1" | u32 v4count | u32 v6count
#   v4count x (u32 start, u32 end, 2 bytes ISO country)
#   v6count x (16 bytes start, 16 bytes end, 2 bytes ISO country)
set -e
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
for month in $(date -u +%Y-%m) $(date -u -v-1m +%Y-%m); do
  curl -fsSL "https://download.db-ip.com/free/dbip-country-lite-$month.csv.gz" -o "$tmp/db.csv.gz" && break
done
gunzip -c "$tmp/db.csv.gz" > "$tmp/db.csv"
python3 -I - "$tmp/db.csv" App/Resources/geoip.bin <<'PY'
import csv, ipaddress, struct, sys
v4, v6 = [], []
for start, end, cc in csv.reader(open(sys.argv[1], newline="")):
    if cc == "ZZ" or len(cc) != 2:
        continue
    a, b = ipaddress.ip_address(start), ipaddress.ip_address(end)
    (v4 if a.version == 4 else v6).append((int(a), int(b), cc.encode()))
v4.sort(); v6.sort()
with open(sys.argv[2], "wb") as f:
    f.write(b"KKGEO1" + struct.pack(">II", len(v4), len(v6)))
    for a, b, cc in v4:
        f.write(struct.pack(">II", a, b) + cc)
    for a, b, cc in v6:
        f.write(a.to_bytes(16, "big") + b.to_bytes(16, "big") + cc)
print(f"GeoIP: {len(v4)} IPv4 + {len(v6)} IPv6 ranges -> {sys.argv[2]}")
PY
