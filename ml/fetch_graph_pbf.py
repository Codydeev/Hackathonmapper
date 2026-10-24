"""Cut the walkable path network of every area out of the local OpenStreetMap
extract, with node ids and tags, for the route model's graph.

    python ml/fetch_graph_pbf.py [areas...]

Saves ml/data/graph_raw/<area>.json: {"ways": [{"id", "nodes", "xy", "hw",
"name", "sac", "route"}]}, positions in the area's metre frame (geo.py).
"route" marks ways that belong to a hiking or walking route relation.
"""

import json
import sys
import time
from pathlib import Path

import osmium

from fetch_map import PAD_LAT, PAD_LON, PATHS, ROADS
from fetch_map_pbf import PBF
from fetch_osm import AREAS
from geo import to_xy

OUT = Path(__file__).parent / 'data' / 'graph_raw'
FAST = {'motorway', 'motorway_link', 'trunk', 'trunk_link', 'primary', 'primary_link'}
WALKABLE = (PATHS | ROADS) - FAST - {'corridor'}
FOOT_OK = {'yes', 'designated', 'permissive'}


def walkable(tags):
    if tags.get('highway') not in WALKABLE or tags.get('foot') == 'no':
        return False
    return tags.get('access') not in ('no', 'private') or tags.get('foot') in FOOT_OK


def main(names):
    boxes = {n: (AREAS[n][1] - PAD_LAT, AREAS[n][0] - PAD_LON, AREAS[n][3] + PAD_LAT, AREAS[n][2] + PAD_LON) for n in names}
    ways = {n: [] for n in names}
    route_ways = set()
    fp = (osmium.FileProcessor(str(PBF))
          .with_locations()
          .with_filter(osmium.filter.EntityFilter(osmium.osm.WAY | osmium.osm.RELATION))
          .with_filter(osmium.filter.KeyFilter('highway', 'route')))
    t0 = time.time()
    for obj in fp:
        if obj.is_relation():
            if obj.tags.get('route') in ('hiking', 'foot', 'walking'):
                route_ways.update(m.ref for m in obj.members if m.type == 'w')
            continue
        if not walkable(obj.tags):
            continue
        try:
            pts = [(nd.lat, nd.lon, nd.ref) for nd in obj.nodes]
        except osmium.InvalidLocationError:
            continue
        if len(pts) < 2:
            continue
        lats, lons = [p[0] for p in pts], [p[1] for p in pts]
        for n, (s, w, nn, e) in boxes.items():
            if min(lats) <= nn and max(lats) >= s and min(lons) <= e and max(lons) >= w:
                ways[n].append({'id': obj.id, 'nodes': [p[2] for p in pts], 'll': [[p[0], p[1]] for p in pts],
                                'hw': obj.tags.get('highway'), 'name': obj.tags.get('name'),
                                'sac': obj.tags.get('sac_scale')})
    OUT.mkdir(parents=True, exist_ok=True)
    for n, ws in ways.items():
        for w in ws:
            xy = to_xy(*zip(*w.pop('ll')), n)
            w['xy'] = [[round(float(x), 1), round(float(y), 1)] for x, y in xy]
            w['route'] = w['id'] in route_ways
        (OUT / f'{n}.json').write_text(json.dumps({'ways': ws}))
        print(f'{n}: {len(ws)} walkable ways, {sum(w["route"] for w in ws)} on hiking routes')
    print(f'{time.time() - t0:.0f} s')


if __name__ == '__main__':
    main(sys.argv[1:] or list(AREAS))
