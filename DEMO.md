# Demo run sheet

## Phones only (Bluetooth, no Wi-Fi, no laptop)

1. Open MeshMapper on every phone and keep it on screen. It starts by itself and opens on **Track**.
2. One phone needs a position: GPS outdoors, or Position tab → **Fixed spot** indoors. Two or three
   placed phones pin the others down much better than one.
3. On the phone that should "lose GPS": Track tab → **Simulate losing GPS**.

Every phone's Track tab now shows that phone placed from Bluetooth and UWB, plus distance and
direction from you ("23 m NE"). It walks away out of reach: after 5 s it turns grey at its last spot
and one 95 % circle grows at walking pace. The distance list works even when nobody has GPS
("3.42 m UWB · −61 dBm", distance only, no direction).

**UWB ranging is on by default** on iPhone 11 and later (not SE). Allow the Nearby Interaction prompt
on each phone; if someone denies it, that phone still works on Bluetooth alone. Every phone in the
demo needs the same build (protocol v4), or they will not link.

### Track map legend

| On the map | Meaning |
|---|---|
| Marker colour | How the phone is placed: GPS, GPS+UWB, UWB-ranged, Bluetooth estimate, or predicted (lost) |
| Solid line, "3.42 m" | UWB-ranged distance between the two phones |
| Dashed line, "≈ 4 m" | Distance estimated from Bluetooth signal strength |
| Amber line | The drawn length disagrees with the measured distance by more than 1 m or 30 % |
| Dashed ring, "Otter 42 · 4.1 m · direction unknown" | The phone is that far from its neighbour, but the direction is unknown, so no dot is drawn |
| One grey circle | Predicted area for a phone lost for more than 5 s |

Labels on links to your own phone are always shown; tap any other link to see its label. The map
stays centred on your phone; tap the scope button to refit it, or turn on heading-up to rotate with
the compass.

To turn a ring into a dot: bring more placed neighbours into range (three pin a phone down), or use iPhone 11–13 pairs that face each
other (they can measure a bearing).

## With the laptop dashboard

Three or more iPhones with MeshMapper, one laptop. About two minutes to set up.

## 1. Network

Turn on **Personal Hotspot** on the phone that will be the gateway, and join it from the laptop.
The gateway phone and the laptop then always see each other, even where venue Wi-Fi blocks
devices from talking to each other. The other phones need no network at all: they only use Bluetooth.

If the gateway phone can't be on the laptop's network, run `npm run tunnel` on the laptop
(`npm run tunnel:install` gets `cloudflared` first). The Connect panel's QR code then points the phone
at the public URL, which works over mobile data.

## 2. Laptop

```
cd website
npm run demo
```

The first run installs dependencies (needs internet once). The dashboard opens in the browser and
shows a setup checklist until phones appear.

## 3. Phones

- **Every phone:** open MeshMapper. It starts by itself, asks for Bluetooth and Location once, and
  gets a name like "Otter 42" (rename on the Start tab if you like). Keep the app on screen.
- **Gateway phone:** scan the QR code in the dashboard's **Connect** panel with the iPhone **Camera**
  and tap **Open in MeshMapper**. The app fills in the dashboard address. Then turn on
  **Upload as gateway** (Start or Gateway tab). The Start tab then says "Uploading to …".

Phones appear on the dashboard within a few seconds.

## 4. Show the idea

- Phones with GPS (outdoors works best) show **GPS ±m**.
- On one phone, Start tab → **Simulate losing GPS**. It stops sharing GPS, and the dashboard places it
  from the Bluetooth signal of the phones around it: **Bluetooth estimate ±N m · K hops**. Walk with it
  and the estimate follows. Turn the switch off and it snaps back to GPS.
- One Bluetooth neighbour gives a distance, not a direction, so expect a wide circle. Two give two
  candidate spots, and three pin it down. A phone that had GPS before losing it stays well placed.

## Fallbacks

| Problem | Do this |
|---|---|
| QR code won't open the app | Gateway tab: type the dashboard URL shown in the dashboard header |
| Dashboard says simulated | Click **Live data** |
| No phones yet, need to show something | Click **Simulated data**: it includes a "No-GPS phone" placed from Bluetooth |
| Indoors, GPS is poor | Position tab → Source: **Fixed spot** on two phones, then type their coordinates |
| A phone shows "different frame ID" | Set the same Frame ID (`hervanta-v1`) on every phone |

## Honest limits (for the Q&A)

- Bluetooth signal strength is a rough ruler (about ±40 % per hop), and errors grow with every hop.
  The dashboard's ± circle shows this.
- UWB distance is about ±10–30 cm in line of sight. Bodies, pockets and walls make it read long.
  The app calls such positions "UWB-ranged", never "measured".
- Bearings come only from iPhone 11–13, only while the peer is in the UWB field of view, and they
  rely on the compass, which can be 30° or more off indoors and near laptops. Newer iPhones give
  distance only.
- One neighbour gives a distance, not a direction: hence the ring.
- Distances travel in the once-per-second reports, so a moving phone lags 1–3 s on other phones' maps.
- The laptop dashboard does not use the UWB distances yet; it still places phones from Bluetooth.
- The app has to stay in the foreground. iOS stops Bluetooth relaying when the phone is locked.
- GPS positions use a frame anchored at Tietotalo, so they need to be within 10 km of Hervanta.
