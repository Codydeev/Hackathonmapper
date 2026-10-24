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

Trained on public GPS walks from Nuuksio, Sipoonkorpi, Seitseminen,
Helvetinjärvi, Kauppi and Pyynikki. Tested on the **Hervanta forest, which the
model never saw** (14 h of real walking, 6,905 test cases). It is compared with
two simple guesses, both tuned on the same training data so the comparison is
fair:

- **Stand still**: they are somewhere around where they were last heard.
- **Same velocity**: they kept walking the way they were going.

"90% area" is the area a search team must cover to find the person 9 times out
of 10. Every method's 90% line is calibrated the same way, on validation
walks, so all of them make the same promise and smaller is simply better.

| History the phone had | Time since lost | Model | Same velocity | Stand still |
|---|---|---|---|---|
| Clean GPS | 1 min | **0.7 ha**, 26 m typical error | 1.1 ha, 32 m | 1.8 ha, 46 m |
| Clean GPS | 2 min | **3.1 ha**, 54 m | 4.4 ha, 63 m | 6.2 ha, 86 m |
| Clean GPS | 3 min | **7.2 ha**, 81 m | 10.6 ha, 97 m | 12.6 ha, 122 m |
| Bluetooth mesh (±15 m) | 1 min | **1.8 ha**, 44 m | 2.6 ha, 54 m | 2.2 ha, 47 m |
| Bluetooth mesh (±15 m) | 2 min | **5.2 ha**, 73 m | 8.4 ha, 93 m | 6.6 ha, 85 m |
| Bluetooth mesh (±15 m) | 3 min | **10.2 ha**, 100 m | 17.9 ha, 135 m | 13.0 ha, 121 m |

The model needs **21–33% less search area** than the best simple guess at 2–3
minutes, and is ahead at every horizon in both settings. All numbers are in
[`results/metrics.json`](results/metrics.json).

**Honest caveats, worth saying in the pitch:**
- In the new forest, the "90%" areas of *every* method held the person 81–86%
  of the time, not 90%: walkers in Hervanta are a bit less predictable than in
  the training areas. The model is no worse at this than the baselines.
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
  Finnish hiking areas (`fetch_osm.py` lists them; the current model uses
  seven). Traces are cut at gaps, GPS spikes are
  dropped, everything is resampled to 1 s, and anything moving faster than
  2.6 m/s for 30 s (bikes, cars, runners) is removed with a minute of margin.
  Stops inside walks are kept (`prepare.py`). Result: ~110 h of walking.
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
