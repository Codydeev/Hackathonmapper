"""Download public, timestamped GPS traces from OpenStreetMap for Finnish
hiking areas. These are real people walking real trails, and they are the
training data for the movement model.

    python ml/fetch_osm.py            # all areas
    python ml/fetch_osm.py hervanta   # one area

Each area is saved as ml/data/raw/<area>.json: a list of segments, each a list
of [unix_time, lat, lon]. Only segments with timestamps are kept.
"""

import json
import sys
import time
import urllib.request
import xml.etree.ElementTree as ET
from datetime import datetime
from pathlib import Path

# (lon_min, lat_min, lon_max, lat_max). The API limits a box to 0.25 deg².
AREAS = {
    # Held out for testing: the forest between Hervanta campus and Suolijärvi.
    'hervanta': (23.78, 61.42, 23.90, 61.47),
    'kauppi': (23.79, 61.50, 23.88, 61.53),
    'pyynikki': (23.70, 61.48, 23.76, 61.50),
    'seitseminen': (23.38, 61.90, 23.55, 61.97),
    'helvetinjarvi': (23.80, 62.00, 23.95, 62.07),
    'nuuksio': (24.45, 60.27, 24.62, 60.35),
    'sipoonkorpi': (25.13, 60.28, 25.25, 60.36),
    'keskuspuisto': (24.88, 60.20, 24.96, 60.27),
    'repovesi': (26.80, 61.15, 26.95, 61.22),
}

API = 'https://api.openstreetmap.org/api/0.6/trackpoints?bbox={},{},{},{}&page={}'
UA = 'Hackathonmapper-movement-model/0.1 (STUHI hackathon research; contact silas@stuhi.org)'
MAX_PAGES = 25
OUT = Path(__file__).parent / 'data' / 'raw'


def fetch(url, tries=3):
    for i in range(tries):
        try:
            req = urllib.request.Request(url, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=90) as r:
                return r.read()
        except Exception as e:
            print(f'  retry {i + 1}: {e}')
            time.sleep(5 * (i + 1))
    raise RuntimeError(f'failed: {url}')


def parse(gpx):
    root = ET.fromstring(gpx)
    segs = []
    for seg in root.iterfind('.//{*}trkseg'):
        pts = []
        for p in seg.iterfind('{*}trkpt'):
            t = p.find('{*}time')
            if t is None or not t.text:
                continue
            ts = datetime.fromisoformat(t.text.replace('Z', '+00:00')).timestamp()
            pts.append([ts, float(p.get('lat')), float(p.get('lon'))])
        if len(pts) >= 2:
            segs.append(pts)
    n = sum(1 for _ in root.iterfind('.//{*}trkpt'))
    return segs, n


def main(names):
    OUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        dest = OUT / f'{name}.json'
        if dest.exists():
            print(f'{name}: already downloaded')
            continue
        box = AREAS[name]
        segs, total = [], 0
        for page in range(MAX_PAGES):
            try:
                s, n = parse(fetch(API.format(*box, page)))
            except RuntimeError as e:
                print(f'{name}: stopping early, {e}')
                break
            segs += s
            total += n
            print(f'{name} page {page}: {n} points, {len(s)} timed segments', flush=True)
            if n < 5000:
                break
            time.sleep(1.5)
        dest.write_text(json.dumps(segs))
        print(f'{name}: {total} points, {len(segs)} segments -> {dest}')


if __name__ == '__main__':
    main(sys.argv[1:] or list(AREAS))
