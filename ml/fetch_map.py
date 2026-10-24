"""Download the map the model looks at: paths, roads and water from
OpenStreetMap for every training and test area.

    python ml/fetch_map.py            # all areas
    python ml/fetch_map.py hervanta   # one area

Paths, roads and small lakes come from the Overpass API. Big lakes drawn as
multipolygons (Näsijärvi, Pyhäjärvi...) are huge, so for those Overpass only
returns their ids and the outlines come from Nominatim, simplified to ~10 m.

Saves ml/data/map/<area>.json: {"paths": [[[lat, lon], ...], ...], "roads":
[...], "water": [...], "water_holes": [...]} (water as closed rings, holes
are islands).
"""

import json
import sys
import time
import urllib.parse
import urllib.request
from pathlib import Path

from fetch_osm import AREAS, UA

OUT = Path(__file__).parent / 'data' / 'map'
OVERPASS = ['https://overpass-api.de/api/interpreter', 'https://overpass.private.coffee/api/interpreter',
            'https://overpass.kumi.systems/api/interpreter']
NOMINATIM = 'https://nominatim.openstreetmap.org/lookup?format=geojson&polygon_geojson=1&polygon_threshold=0.0001&osm_ids={}'
PAD_LAT, PAD_LON = 0.006, 0.012   # ~650 m, so map patches at the area edge are complete

PATHS = {'footway', 'path', 'track', 'bridleway', 'steps', 'cycleway', 'pedestrian', 'corridor'}
ROADS = {'residential', 'service', 'unclassified', 'tertiary', 'secondary', 'primary', 'trunk', 'living_street',
         'road', 'tertiary_link', 'secondary_link', 'primary_link', 'motorway', 'motorway_link', 'trunk_link'}

QUERY = """[out:json][timeout:180];
(
  way["highway"]({b});
  way["natural"="water"]({b});
  way["waterway"="riverbank"]({b});
);
out geom;
relation["natural"="water"]({b});
out ids;"""


def get(url, data=None, tries=6):
    for i in range(tries):
        u = url[i % len(url)] if isinstance(url, list) else url
        try:
            req = urllib.request.Request(u, data=data, headers={'User-Agent': UA})
            with urllib.request.urlopen(req, timeout=240) as r:
                return json.loads(r.read())
        except Exception as ex:
            print(f'  retry {i + 1} ({u.split("/")[2]}): {ex}', flush=True)
            time.sleep(15 * (i + 1))
    raise RuntimeError(f'failed: {url}')


def fetch(area):
    w, s, e, n = AREAS[area]
    b = f'{s - PAD_LAT},{w - PAD_LON},{n + PAD_LAT},{e + PAD_LON}'
    osm = get(OVERPASS, urllib.parse.urlencode({'data': QUERY.format(b=b)}).encode())
    out = {'paths': [], 'roads': [], 'water': [], 'water_holes': []}
    rel_ids = []
    for el in osm['elements']:
        if el['type'] == 'relation':
            rel_ids.append(el['id'])
            continue
        if 'geometry' not in el:
            continue
        tags = el.get('tags', {})
        line = [[p['lat'], p['lon']] for p in el['geometry']]
        hw = tags.get('highway')
        if hw in PATHS:
            out['paths'].append(line)
        elif hw in ROADS:
            out['roads'].append(line)
        elif tags.get('natural') == 'water' or tags.get('waterway') == 'riverbank':
            out['water'].append(line)
    for i in range(0, len(rel_ids), 20):
        time.sleep(1.5)   # Nominatim allows one request per second
        fc = get(NOMINATIM.format(','.join(f'R{r}' for r in rel_ids[i:i + 20])))
        for f in fc.get('features', []):
            g = f['geometry']
            polys = [g['coordinates']] if g['type'] == 'Polygon' else g['coordinates'] if g['type'] == 'MultiPolygon' else []
            for poly in polys:
                out['water'].append([[lat, lon] for lon, lat in poly[0]])
                out['water_holes'] += [[[lat, lon] for lon, lat in hole] for hole in poly[1:]]
    return out, len(rel_ids)


def main(names):
    OUT.mkdir(parents=True, exist_ok=True)
    for name in names:
        dest = OUT / f'{name}.json'
        if dest.exists():
            print(f'{name}: already downloaded')
            continue
        try:
            m, nrel = fetch(name)
        except RuntimeError as ex:
            print(f'{name}: gave up ({ex}); run again later', flush=True)
            continue
        dest.write_text(json.dumps(m))
        print(f'{name}: {len(m["paths"])} paths, {len(m["roads"])} roads, {len(m["water"])} water '
              f'({nrel} big lakes via Nominatim), {len(m["water_holes"])} islands', flush=True)
        time.sleep(5)


if __name__ == '__main__':
    main(sys.argv[1:] or list(AREAS))
