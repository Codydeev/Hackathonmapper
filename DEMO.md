# Demo run sheet

## GhostCore demo: three phones, no laptop (build 11 or later)

Needs the GhostCore map bound to the hub, the GPS check toggle and the scenario player (build 11).
On build 10, use "Phones only" below. ARCHITECTURE.md §1 is the story; §9 lists the field tests behind it.

**Setup (5 min, outdoors with open sky):** same build on all three phones, app on screen, Settings →
GPS check on. Put **A** on a table or tripod and leave it still: GPS is only trusted when something
independent of GPS agrees, and a still phone is the easiest case. **B** and **C** stand 10–20 m from A.
Wait until A shows **GPS trusted** (about 10 s after its first fix). In the scenario player, set roles
A / B / C on the matching phones.

| Time | Do | Say |
|---|---|---|
| 0:00 | Show A: green **GPS trusted ±r95** and its evidence strip | "Every phone shows where it is and how much to believe it." |
| 0:20 | On B: Simulate → **Outage**. B turns blue, "Bluetooth ±N m", with its 95 % circle | "B is placed from its peers' radio: a circle, never a fake dot." |
| 0:50 | On C: Simulate → **Jump 400 m**. On A: C's raw GPS shows as a red cross 400 m away, "rejected", dashed line back. Tap C: summary and evidence | "Physically impossible, so refused, and we say why. We never claim an attack: phone data can only show that GPS disagrees." |
| 1:40 | B walks away (or on B: Peers → A off). B goes grey and dashed, "Predicted · 12 s", the area grows and the age counts | "Nothing measures B now, so we predict, show the age, and never show it as live." |
| 2:20 | B walks back; on C: **Restore GPS**. B turns blue again; C climbs back through unconfirmed to trusted | "Trust is earned back, not switched back." |
| 2:40 | Close | |

Everything an injected fault touches carries a **SIMULATED** badge; that is intended and honest.
Indoors without GNSS: play a scripted scenario (all SIMULATED), not "Pin me": a typed spot is never
"GPS trusted".

**Do not open Settings → Network → Ambient radio (experimental) during the demo:** its scanner shares the radio with the mesh's discovery, and that effect is not measured yet.

**Never say:** "spoofing detected", "accurate to N m" (say "95 % radius"), "works in the background".

**If A never reaches trusted** (no motion data, poor sky): Settings → GPS check off, restart the mesh.
GPS is then shared unchecked ("GPS not checked") and the jump step loses its point: skip it.

## Phones only (Bluetooth, no Wi-Fi, no laptop)

1. Open MeshMapper on every phone and keep it on screen. It starts by itself and opens on the map;
   the gear button opens Settings with the Track, Start, Network, Position and Gateway tabs.
2. One phone needs a position: GPS outdoors, or Position tab → **Fixed spot** indoors. Two or three
   placed phones pin the others down much better than one.
3. On the phone that should "lose GPS": Settings → Start tab → **Simulate losing GPS**.

Every phone's Track tab (in Settings) now shows that phone in orange, placed from Bluetooth, with a circle holding
95 % of the estimate, plus distance and direction from you ("23 m NE"). It walks away out of reach:
it turns grey at its last spot and the circle grows at walking pace. The "Bluetooth distance" list
works even when nobody has GPS (distance only, no direction).

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
- The app has to stay in the foreground. iOS stops Bluetooth relaying when the phone is locked.
- GPS positions use a frame anchored at Tietotalo, so they need to be within 10 km of Hervanta.
