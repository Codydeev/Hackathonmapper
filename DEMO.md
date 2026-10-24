# Demo run sheet

Three or more iPhones with MeshMapper, one laptop. About two minutes to set up.

## 1. Network

Turn on **Personal Hotspot** on the phone that will be the gateway, and join it from the laptop.
The gateway phone and the laptop then always see each other, even where venue Wi-Fi blocks
devices from talking to each other. The other phones need no network at all: they only use Bluetooth.

If the gateway phone can't be on the laptop's network, run `npm run tunnel` on the laptop
(needs `cloudflared`). The pairing QR code then also offers an internet code that works over mobile data.

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
- **Gateway phone:** on the dashboard click **Pair a gateway phone**. Scan the code with the iPhone
  **Camera** and tap **Open in MeshMapper**. The Start tab then says "Uploading to …".

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
