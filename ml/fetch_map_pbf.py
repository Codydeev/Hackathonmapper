"""Cut every area's map out of a local OpenStreetMap extract, in one pass.
Same output as fetch_map.py, without depending on a busy public server.

    curl -L -o ml/data/finland.osm.pbf https://download.geofabrik.de/europe/finland-latest.osm.pbf
    python ml/fetch_map_pbf.py [areas...]

Lakes are assembled from their multipolygons by osmium, islands included.
"""

import json
import sys
import time
from pathlib import Path

import osmium

from fetch_map import OUT, PAD_LAT, PAD_LON, PATHS, ROADS
from fetch_osm import AREAS

PBF = Path(__file__).parent / 'data' / 'finland.osm.pbf'


def main(names):
    boxes = {n: (AREAS[n][1] - PAD_LAT, AREAS[n][0] - PAD_LON, AREAS[n][3] + PAD_LAT, AREAS[n][2] + PAD_LON) for n in names}
    out = {n: {'paths': [], 'roads': [], 'water': [], 'water_holes': []} for n in names}

    def hits(coords):
        lats = [c[0] for c in coords]
        lons = [c[1] for c in coords]
        lo_lat, hi_lat, lo_lon, hi_lon = min(lats), max(lats), min(lons), max(lons)
        return [n for n, (s, w, nn, e) in boxes.items() if lo_lat <= nn and hi_lat >= s and lo_lon <= e and hi_lon >= w]

    fp = (osmium.FileProcessor(str(PBF))
          .with_locations()
          .with_areas(osmium.filter.TagFilter(('natural', 'water'), ('waterway', 'riverbank')))
          .with_filter(osmium.filter.EntityFilter(osmium.osm.WAY | osmium.osm.AREA))
          .with_filter(osmium.filter.KeyFilter('highway', 'natural', 'waterway')))
    t0, n = time.time(), 0
    for obj in fp:
        n += 1
        if n % 2_000_000 == 0:
            print(f'  {n:,} objects, {time.time() - t0:.0f} s', flush=True)
        if obj.is_way():
            hw = obj.tags.get('highway')
            kind = 'paths' if hw in PATHS else 'roads' if hw in ROADS else None
            if kind is None:
                continue
            try:
                coords = [(nd.lat, nd.lon) for nd in obj.nodes]
            except osmium.InvalidLocationError:
                continue
            if len(coords) < 2:
                continue
            for area in hits(coords):
                out[area][kind].append([[round(a, 7), round(b, 7)] for a, b in coords])
        elif obj.is_area():
            if obj.tags.get('natural') != 'water' and obj.tags.get('waterway') != 'riverbank':
                continue   # wetland, wood and other natural areas are not water
            for outer in obj.outer_rings():
                ring = [(nd.lat, nd.lon) for nd in outer]
                areas = hits(ring)
                if not areas:
                    continue
                holes = [[(nd.lat, nd.lon) for nd in inner] for inner in obj.inner_rings(outer)]
                for area in areas:
                    out[area]['water'].append([[round(a, 7), round(b, 7)] for a, b in ring])
                    out[area]['water_holes'] += [[[round(a, 7), round(b, 7)] for a, b in h] for h in holes]
    OUT.mkdir(parents=True, exist_ok=True)
    for name, m in out.items():
        (OUT / f'{name}.json').write_text(json.dumps(m))
        print(f'{name}: {len(m["paths"])} paths, {len(m["roads"])} roads, {len(m["water"])} lakes, '
              f'{len(m["water_holes"])} islands')
    print(f'{n:,} objects in {time.time() - t0:.0f} s')


if __name__ == '__main__':
    main(sys.argv[1:] or list(AREAS))
