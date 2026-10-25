# Mesh positioning dashboard

Local, offline-capable dashboard that receives device positions from an iPhone gateway (or from its
own Web Bluetooth mesh node) and shows them in 3D, on a 2D map (the same scene from above) and on Network, Positions and
Gateway pages. [WEBSITE_PLAN.md](../WEBSITE_PLAN.md) is the full description: the upload contract,
every endpoint, the access rules and the views. This page is how to run it.

## Requirements

- Node.js 20+ (tested with Node 24).
- No internet access is needed after `npm install` and `npm run build`, except for the optional
  OpenStreetMap background and `npm run tunnel`.

## Run

```powershell
cd website
npm run demo     # first time: installs, builds, starts and opens http://localhost:3000
npm start        # afterwards
```

`npm start` builds the frontend and starts the backend on port `3000` (override with `PORT`), plus
the protected tunnel listener on `127.0.0.1:3001` (`PUBLIC_PORT`, `0` disables it). Open the printed
`Local` or `LAN` URL. Enter the `LAN` URL as the gateway server address in the iPhone app, or scan
the QR code in the dashboard's Connect panel; `localhost` from an iPhone refers to the phone.

Allow inbound TCP `3000` on the laptop's private network profile. Bind address defaults to
`0.0.0.0`; set `HOST` to restrict it. The LAN server answers IP addresses, `localhost` and local
names only; add another host name with `TRUSTED_HOSTS`.

To reach the dashboard from anywhere, `npm run tunnel` publishes the protected listener through a
Cloudflare tunnel (WEBSITE_PLAN.md, "Public access").

### Development

```powershell
npm run dev      # Vite on 5173, proxies /api to the backend
npm run server   # backend on 3000 in another terminal
```

## Verification

There is no test runner. These are the checks (all also run by `contract/validate.sh` in CI, except
`sample`, which needs a running server; use a spare `PORT` if :3000 is in use):

```powershell
npm run typecheck                   # src, server, shared, scripts
npm run signalmap:check             # the signal-map solver; -- --write-golden updates the Swift golden file
npm run check:mesh                  # the dashboard's port of the app's BLE wire format, and its version
npm run check:ghostcore             # the GhostCore contract mirror against contract/fixtures
npm run sample                      # accepted, moving, and duplicate updates (frame hervanta-v1)
npm run sample -- --duplicate       # duplicate handling only
npm run sample -- --stale           # rejection handling only
npm run sample -- --frame=demo-room-v1
```

State is in memory: restarting the backend clears it, except operator pins in the live scene
(`.anchors.json`). The LAN server has no authentication and must not be exposed to the internet;
only the protected listener may sit behind a tunnel.
