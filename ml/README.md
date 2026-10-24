# Movement model: where did they go when Bluetooth lost them?

When a phone drops out of Bluetooth range of every other phone, the mesh has
nothing new to say about it, and the map freezes the dot where it was last
heard. This small model replaces the frozen dot with a **cloud that keeps
moving and grows**: it predicts where the person is likely to be any number of
seconds later (2 s to 3 min). That cloud is the area a search team should look
in, and when the phone is heard again it is where the mesh should expect it.

The model (v2) reads three things the phone already has when the link drops:

1. **How they moved**: the last 60 s of positions (speed, turns, stops).
2. **The map around them**: paths, roads and lakes from OpenStreetMap, as a
   48 x 48 patch (480 m) rotated to the walking direction. It sees forks
   ahead, roads to the side and water in the way.
3. **Their plan**, if known: the direction and distance to where they were
   heading (a navigation target, a trailhead, a hut).

It runs on the phone with no internet: 88,980 numbers, **about 1 ms per
prediction** in plain Swift, no Core ML. The same files run in the browser.
Try it: `demo/index.html` (also published as an interactive page).

## Results

Trained on ~110 h of public GPS walks from eight Finnish areas (Nuuksio,
Sipoonkorpi, Repovesi, Seitseminen, Helvetinjärvi, Kauppi, Pyynikki,
Keskuspuisto). Tested on the **Hervanta forest, which the model never saw**
(14 h of real walking, 6,905 test cases).

"90% area" is the area a search team must cover to find the person 9 times out
of 10 in Hervanta. Every method is held to exactly that hit rate, so smaller is
better. The second number is the median distance between the single best
guess and where the person really was. The simple guesses ("stand still",
"same velocity") were tuned on the same training walks.

**History from the Bluetooth mesh (±15 m)**, the case this model is for:

| Time since lost | Model v2 (map) | v1 (history only) | Best simple guess |
|---|---|---|---|
| 30 s | **0.72 ha**, 24 m | 0.95 ha, 28 m | 1.06 ha, 29 m |
| 1 min | **1.85 ha**, 37 m | 2.34 ha, 44 m | 2.83 ha, 47 m |
| 2 min | **5.41 ha**, 64 m | 6.56 ha, 73 m | 8.37 ha, 85 m |
| 3 min | **10.9 ha**, 89 m | 12.1 ha, 100 m | 16.3 ha, 121 m |

With a mesh-quality history the map cuts the search area by **18–24% compared
with v1** up to 2 minutes (10% at 3 minutes), and by about a third compared
with the best simple guess. The noisier the history, the more the map helps:
a ±15 m track does not say which of two parallel paths someone is on, and the
map does.

**History from the phone's own GPS (±4 m):** the map helps less (4–8% less
area than v1 from 1 minute on; 4.09 vs 4.45 ha at 2 minutes) because a clean
track already shows which path the person is on. Here v2 also has a worse
log-likelihood than v1: it is sometimes confidently wrong when people leave
the mapped paths.

**Told where they were going** (the same model, on the 82% of test walks whose
end was known):

| Time since lost | Mesh history: without → with destination | Clean GPS history: without → with |
|---|---|---|
| 1 min | 1.82 → **1.65 ha** (37.6 → 35.5 m) | 1.10 → **1.01 ha** |
| 2 min | 5.21 → **4.55 ha** (65.8 → 58.8 m) | 3.95 → **3.54 ha** |
| 3 min | 10.5 → **8.87 ha** (91.8 → 80.4 m) | 8.37 → **7.23 ha** (80.5 → 72.5 m) |

A destination matters more the longer the person has been gone: 8–13% less
area at 1–2 minutes, 14–15% at 3 minutes. All numbers are in
[`results/metrics-v2.json`](results/metrics-v2.json) (`area90_exact`, `err50`).

**Limits, worth saying in the pitch:**
- In training, "destination" is where each walk really ended. That stands in
  for a target set in the app; real plans change, so treat it as a best case.
- The walks come from people who recorded their hikes, not from people who
  were lost. Lost people tend to follow trails, streams and other lines in the
  terrain.
- On a phone you have to fix the 90% line in advance. Lines set on the
  training forests held the person 77–85% of the time in Hervanta for v2 with
  mesh history (v1: 83–87%): the map makes the model sharper, and a little
  overconfident in a forest it has not seen. A deployment would widen the line
  or calibrate per region.

v1 figures: ![A real walk](results/walk.png) ![Search area by time](results/search-area.png)

## Which map

- **For the model: OpenStreetMap**, bundled in the app as a small image per
  region (Hervanta: 957 x 862 px, 668 kB, `export/maps/`). It works offline,
  which matters because when GPS is jammed in a forest, mobile data is often
  gone too. OpenStreetMap's licence (ODbL) allows this with attribution.
- **For people to look at: Apple Maps (MapKit)** in the iPhone app, free and
  native, with the predicted cloud drawn on top (`toLatLon` converts back).
- **Not Google Maps**: its terms forbid using its map data to train models or
  derive data from it, it needs an API key with billing, and it cannot be
  bundled offline.

## What the phone should keep doing

The model can only use what the phone recorded before the link dropped:

- Keep its own track at about 1 Hz (positions and their accuracy), the last 60 s
  at least. Without GPS that is the mesh estimate with its `accuracyMeters`.
- If the person set a destination, include it in the mesh position report
  (an optional `destination` in the same frame), so the phones that lose them
  know where they were heading.
- Ship the map image for the region the group is in, before going out.

## Using it

Positions are metres. With the map they must be in the map's frame:
`toXY(lat, lon)` converts GPS coordinates, `toLatLon` converts back. Without a
map any flat frame works (the demo room's x/z), and the model behaves like v1.
`accuracy` is how far off the history positions may be: about 5 m for a
phone's own GPS, the mesh's `accuracyMeters` for a lost phone.

### iPhone (Swift)

Add `runtime/MovementModel.swift`, `export/movement-model-v2.json`,
`export/maps/hervanta.png` and `export/maps/hervanta.json` to the Xcode target.

```swift
let model = try MovementModel(json: Data(contentsOf: Bundle.main.url(forResource: "movement-model-v2", withExtension: "json")!))
let map = try MovementModel.MapLayer(png: Data(contentsOf: Bundle.main.url(forResource: "hervanta", withExtension: "png")!),
                                     meta: Data(contentsOf: Bundle.main.url(forResource: "hervanta", withExtension: "json")!))

// When the link drops: this person's last reports, oldest first.
let track = reports.map { r -> MovementModel.TrackPoint in
    let p = map.toXY(lat: r.latitude, lon: r.longitude)
    return MovementModel.TrackPoint(t: r.time, x: p.x, y: p.y)
}
let hist = model.history(track: track, now: track.last!.t)
let goal = destination.map { map.toXY(lat: $0.latitude, lon: $0.longitude) }
let prep = model.prepare(history: hist, accuracy: lastAccuracy ?? 15, map: map, destination: goal)   // ~1 ms, once

// Then every second while they are missing:
let pred = model.predict(prepared: prep, horizon: now - track.last!.t)
let dots = pred.sample(300).map { map.toLatLon($0) }      // MapKit annotations or an overlay
```

### Dashboard / web (JavaScript or TypeScript)

```js
import { createMovementModel, createMapLayer, historyFromTrack, toXY, toLatLon } from './movement-model.js';
const model = createMovementModel(await (await fetch('/movement-model-v2.json')).json());
const meta = await (await fetch('/maps/hervanta.json')).json();
const img = await createImageBitmap(await (await fetch('/maps/hervanta.png')).blob());
const g = new OffscreenCanvas(meta.width, meta.height).getContext('2d');
g.drawImage(img, 0, 0);
const map = createMapLayer(g.getImageData(0, 0, meta.width, meta.height).data, meta, 4);

const track = reports.map((r) => { const [x, y] = toXY(r.lat, r.lon, meta); return { t: r.time, x, y }; });
const prep = model.prepare(historyFromTrack(track, track.at(-1).t, model.spec), accuracy, { map, destination });
const pred = model.predictPrepared(prep, secondsSinceHeard);
for (const [x, y] of model.sample(pred, 300)) drawDot(toLatLon(x, y, meta));
```

Past 3 minutes the model clamps to 3 minutes.

## How it works

- **Walks** (`fetch_osm.py`, `prepare.py`): public, timestamped GPS traces from
  the OpenStreetMap API for nine Finnish areas. Cut at gaps, GPS spikes
  dropped, resampled to 1 s, anything moving faster than 2.6 m/s for 30 s
  (bikes, cars, runners) removed with a minute of margin, stops kept. ~126 h
  of walking, 14 h of it the Hervanta test set. Each moment also records where
  that walk ended (the destination stand-in).
- **Map** (`fetch_map_pbf.py`, `rasterize.py`): paths, roads and lakes cut from
  the Geofabrik Finland extract with pyosmium (lakes assembled with their
  islands), drawn at 8 m per pixel in each area's metre frame (`geo.py`).
  (`fetch_map.py` does the same through the Overpass API, which was too
  overloaded to rely on.)
- **Model** (`model2.py`): v1's history features, the destination (direction,
  log distance, a flag), a map flag, and the map patch through 4 convolution
  layers into 64 numbers; then 3 x 128 layers to a mixture of 6 Gaussian blobs
  scaled by how far a walker can get in `h` seconds.
- **Training** (`train2.py`): the history is corrupted the way the mesh would
  corrupt it (correlated error up to 25 m), randomly rotated and mirrored,
  sometimes shortened; the map patch and destination go through the same
  transform. The destination is shown half the time and the map is hidden 10%
  of the time, so the model also works without them. 30,000 steps of 512, about
  15 min on the laptop's GPU.
- **Checks**: `export/golden-v2.json` holds 24 cases predicted by PyTorch on
  the Hervanta map; the JS and Swift runtimes match them, including reading
  the map patch (`test-golden-v2.mjs`, `test-golden-v2/main.swift`). v1 still
  loads and passes `golden.json`.

## Reproduce

```sh
python3.12 -m venv .venv && .venv/bin/pip install -r ml/requirements.txt
.venv/bin/python ml/fetch_osm.py           # walks, ~10-30 min, polite to the OSM API
.venv/bin/python ml/prepare.py
curl -L -o ml/data/finland.osm.pbf https://download.geofabrik.de/europe/finland-latest.osm.pbf
.venv/bin/python ml/fetch_map_pbf.py && .venv/bin/python ml/rasterize.py
cd ml
STEPS=30000 ../.venv/bin/python train.py && ../.venv/bin/python export.py     # v1 (v2 compares against it)
STEPS=30000 ../.venv/bin/python train2.py && cp runs/v2-latest/metrics.json results/metrics-v2.json
../.venv/bin/python export2.py && ../.venv/bin/python demo/build.py
node runtime/test-golden-v2.mjs
swiftc -O runtime/MovementModel.swift runtime/test-golden-v2/main.swift -o /tmp/mm-test-v2 && /tmp/mm-test-v2 export
```

Walks: public GPS traces © OpenStreetMap contributors. Map data ©
OpenStreetMap contributors, ODbL.
