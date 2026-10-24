# Movement model: where did they go when Bluetooth lost them?

When a phone drops out of Bluetooth range of every other phone, the mesh has
nothing new to say about it, and the map freezes the dot where it was last
heard. This small model replaces the frozen dot with a **cloud that keeps
moving and grows**: given the person's last 60 s of positions, it predicts
where they are likely to be any number of seconds later (2 s to 3 min). That
cloud is the area a search team should look in, and when the phone is heard
again it is where the mesh should expect it.

It runs on the phone: about 46,000 numbers, **0.05 ms per prediction**, plain
Swift with no Core ML or other dependencies. The same model runs in the
browser for the dashboard.

## Results

Trained on ~110 h of public GPS walks from Nuuksio, Sipoonkorpi, Repovesi,
Seitseminen, Helvetinjärvi, Kauppi, Pyynikki and Keskuspuisto. Tested on the
**Hervanta forest, which the model never saw** (14 h of real walking, 6,905
test cases). It is compared with two simple guesses, both tuned on the same
training data so the comparison is fair:

- **Stand still**: they are somewhere around where they were last heard.
- **Same velocity**: they kept walking the way they were going.

"90% area" is the area a search team must cover to find the person 9 times out
of 10 in Hervanta. Every method is held to exactly that hit rate, so smaller
is simply better. The second number is the typical (median) distance between
the single best guess and where the person really was.

| History the phone had | Time since lost | Model | Same velocity | Stand still |
|---|---|---|---|---|
| Clean GPS | 1 min | **1.1 ha**, 26 m | 2.0 ha, 32 m | 2.7 ha, 46 m |
| Clean GPS | 2 min | **4.5 ha**, 53 m | 7.4 ha, 63 m | 8.1 ha, 86 m |
| Clean GPS | 3 min | **9.0 ha**, 80 m | 15.8 ha, 97 m | 16.2 ha, 122 m |
| Bluetooth mesh (±15 m) | 1 min | **2.3 ha**, 44 m | 3.3 ha, 54 m | 2.8 ha, 47 m |
| Bluetooth mesh (±15 m) | 2 min | **6.6 ha**, 73 m | 10.8 ha, 93 m | 8.4 ha, 85 m |
| Bluetooth mesh (±15 m) | 3 min | **12.1 ha**, 100 m | 22.8 ha, 135 m | 16.3 ha, 121 m |

From one minute on, the model needs **39–43% less search area** than the best
simple guess with a clean history, and **17–26% less** with a mesh-quality
history. At 10 s with a ±15 m history it only ties "stand still": the walk is
lost in the noise. All numbers are in
[`results/metrics.json`](results/metrics.json) (`area90_exact`).

**Honest caveats, worth saying in the pitch:**
- On a phone you have to fix the 90% line in advance. Lines set on the
  training forests held the person only 77–88% of the time in Hervanta, for
  every method (`cover90`): walkers there are a bit less predictable. A real
  deployment would widen the line or calibrate per region.
- The walks are from people who uploaded their hikes, not from people who were
  lost. Lost people behave differently (search-and-rescue statistics, such as
  Koester's *Lost Person Behavior*, show they follow trails and linear
  features). The next step is to give the model the trail map.
- The model only knows how people move, not where the paths are. With the
  OpenStreetMap trail network as an extra input, the cloud should follow
  paths instead of spreading into the forest.

![A real walk](results/walk.png)
![Search area by time](results/search-area.png)

## Using it

Positions are metres in any flat frame; the prediction comes back in the same
frame. In the iPhone app's shared frame, use `x` and `z` (the floor plane) as
the model's x and y. Orientation and handedness do not matter: the model works
relative to the walking direction and was trained mirrored.

`accuracy` is how far off the history positions may be: about 5 m for a
phone's own GPS, or the mesh's `accuracyMeters` for a lost phone. A worse
accuracy gives a wider cloud.

Only 30 s of history? It still works (it was trained with shortened
histories), but 60 s is better: the website contract keeps 30 s of trail
(`MAX_TRAIL_AGE_MS`), so raising it to 60 s helps.

### iPhone (Swift)

Add `runtime/MovementModel.swift` and `export/movement-model.json` to the
Xcode target.

```swift
let model = try MovementModel(json: Data(contentsOf: Bundle.main.url(forResource: "movement-model", withExtension: "json")!))

// reports: this device's last accepted positions, oldest first (seconds, metres)
let track = reports.map { MovementModel.TrackPoint(t: $0.time, x: $0.position.x, y: $0.position.z) }
let hist = model.history(track: track, now: track.last!.t)
let secondsSinceHeard = now - track.last!.t
let pred = model.predict(history: hist, accuracy: lastAccuracy ?? 15, horizon: secondsSinceHeard)
let cloud = pred.sample(300)            // points to draw, x/z
let p = pred.density(.init(x, z))       // how likely a spot is, per m²
```

### Dashboard / web (JavaScript or TypeScript)

```js
import { createMovementModel, historyFromTrack } from './movement-model.js';
const model = createMovementModel(await (await fetch('/movement-model.json')).json());

// For a DeviceSnapshot that has gone stale:
const track = device.trail.map((p) => ({ t: p.at / 1000, x: p.x, y: p.z }));
const last = track.at(-1).t;
const hist = historyFromTrack(track, last, model.spec);
const pred = model.predict(hist, device.accuracyMeters ?? 15, Date.now() / 1000 - last);
for (const [x, z] of model.sample(pred, 300)) drawDot(x, 0, z);
```

Grow `h` with the time since the device was last heard; past 3 minutes the
model clamps to 3 minutes, so keep growing the cloud yourself (or call it
again from the predicted centre) if you need longer.

## How it works

- **Data**: public, timestamped GPS traces from the OpenStreetMap API for
  nine Finnish hiking areas (`fetch_osm.py` lists them; all are
  used). Traces are cut at gaps, GPS spikes are
  dropped, everything is resampled to 1 s, and anything moving faster than
  2.6 m/s for 30 s (bikes, cars, runners) is removed with a minute of margin.
  Stops inside walks are kept (`prepare.py`). Result: ~126 h of walking, 14 h of it the Hervanta test set.
- **Input**: the last 60 s every 2 s, rotated so the walking direction is
  +x, plus the horizon, the position accuracy, and whether a walking direction
  exists at all.
- **Output**: a mixture of 6 Gaussian blobs (so it can say "probably kept
  going, maybe turned back, maybe stopped"), scaled by how far a walker can get
  in `h` seconds.
- **Training** (`train.py`): the history is corrupted the way the mesh would
  corrupt it (correlated position error up to 25 m, plus the matching
  accuracy input), randomly rotated and mirrored, sometimes shortened. A
  3-layer, 128-wide network trained for 30,000 steps (~70 s on a laptop CPU).
- **Checks**: `export/golden.json` holds 24 cases predicted by PyTorch; the JS
  and Swift ports both match them.

## Reproduce

```sh
python3.12 -m venv .venv && .venv/bin/pip install -r ml/requirements.txt
.venv/bin/python ml/fetch_osm.py        # ~10-30 min, polite to the OSM API
.venv/bin/python ml/prepare.py
cd ml && STEPS=30000 ../.venv/bin/python train.py && ../.venv/bin/python export.py && ../.venv/bin/python figures.py
node runtime/test-golden.mjs
swiftc -O runtime/MovementModel.swift runtime/test-golden/main.swift -o /tmp/mm-test && /tmp/mm-test export
```

Training data: public GPS traces © OpenStreetMap contributors.
