# Vision

People who move as a group lose each other when GNSS stops working: indoors, underground, in a jammed
area, or when a receiver is spoofed and reports a position that is wrong. MeshMapper keeps everyone on
the map without GNSS and without infrastructure. The phones themselves form the network and measure
each other.

The demo that proves it is three iPhones and no laptop
([ARCHITECTURE.md §1](ARCHITECTURE.md#1-the-demo-we-are-building)):
1. One phone with trusted GPS anchors the others.
2. A phone that loses GPS is placed from its peers over Bluetooth.
3. A spoofed phone is refused and stops anchoring anyone.
4. A phone that walks out of range is shown as a prediction that ages.
5. Trust is earned back once GPS is clean again.

## Goals

1. **Nobody drops off the map when GNSS fails.** A phone without a position is placed from the phones
   around it, using Bluetooth signal strength or a UWB distance where both phones have UWB. Reports hop
   across the mesh, so a phone out of the gateway's range still shows up.
2. **Every position is honest about itself.** Each one says where it came from (GPS, UWB, Bluetooth,
   typed, predicted) and gives a 95 % radius. Bluetooth estimates and typed spots are never shown as
   measured coordinates. A prediction never looks live, and an estimate known only by distance is a
   ring, not a dot.
3. **GNSS is checked, not trusted blindly.** A phone's GPS anchors others only when independent
   evidence (its own motion, its peers) agrees. A fix that behaves impossibly is refused, the screen
   says why, and trust is earned back gradually.
4. **It works with nothing but phones.** Bluetooth LE between foreground iPhones, offline. The laptop
   dashboard is optional: one gateway phone uploads to it over Wi-Fi, or through a tunnel when the
   laptop is elsewhere.
5. **One picture everywhere.** The phone's map, its Track tab and the dashboard place phones with the
   same solver (the signal map), so they agree with each other.
6. **Claims are backed by measurements.** Distances, delivery and trust are tested on real phones
   (field tests T1–T4, tape-measure trials) before they are stated as working. Until then a feature is
   "built", not "verified".
7. **Testing on phones is cheap.** Approaches can be compared on the phones without new builds
   (Start → Features, the Track tab's distance methods). Each install round brings one complete,
   CI-tested build to every phone.

## What done looks like

- The five-step demo above runs end to end on three real phones outdoors.
- T1: every pair of phones links within 30 s.
- T2: Bluetooth and UWB distances are measured against a tape at 1, 3, 5 and 10 m, and the radio model
  is calibrated from them.
- T3: a relayed beacon arrives through a middle phone at least 95 % of the time (120 beacons), with a
  median age of at most 3 s and no duplicates.
- T4: a still phone outdoors reaches "GPS trusted" with the GPS check on.

## Non-goals

- **Not Bluetooth SIG Mesh.** The mesh is an app-level relay over GATT connections.
- **No background or locked-screen operation.** Phones keep the app in the foreground. iOS stops
  Bluetooth relaying otherwise.
- **No claim of detecting attacks.** Phone data can show that GPS disagrees with other evidence, not
  that someone is spoofing it.
- **No "accurate to N m" promises.** Accuracy is always given as a 95 % radius, and Bluetooth signal
  strength is a rough range, not a measurement.
- **No dependence on the internet or on fixed infrastructure** (beacons, Wi-Fi positioning) for
  positioning.

## Open questions

- Which filter owns this phone's own position: `PositioningService` or `FusionEngine`
  ([docs/AUDIT.md §1.2](docs/AUDIT.md#12-two-self-positions)).
- How well Bluetooth ranges hold in the field. The radio constants are still defaults until T2 is
  done.

For the state of the work, read [OVERVIEW.md](OVERVIEW.md). For the next steps on the phones, read
[HANDOVER.md](HANDOVER.md).
