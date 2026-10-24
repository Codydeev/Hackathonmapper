# Mesh positioning dashboard

Local, offline-capable dashboard that receives device positions from one iPhone gateway over
LAN Wi-Fi and renders them in 3D. This implements [WEBSITE_PLAN.md](../WEBSITE_PLAN.md).

## Requirements

- Node.js 20+ (tested with Node 24 through `fnm`).
- No internet access is needed after `npm install` and `npm run build`.

## Run

```powershell
cd website
npm install
npm start
```

`npm start` builds the frontend and starts the backend on port `3000` (override with `PORT`).
Open the printed `Local` or `LAN` URL. Enter the `LAN` URL as the gateway server address in the
iPhone app; `localhost` from an iPhone refers to the phone.

Allow inbound TCP `3000` on the laptop's private network profile. Bind address defaults to
`0.0.0.0`; set `HOST` to restrict it.

### Development

```powershell
npm run dev      # Vite on 5173, proxies /api to the backend
npm run server   # backend on 3000 in another terminal
```

## Upload contract

`POST /api/updates`, `Content-Type: application/json`, at most 256 KiB and 100 devices.

```json
{
  "schemaVersion": 1,
  "gatewayId": "phone-gateway",
  "frameId": "demo-room-v1",
  "units": "m",
  "devices": [
    {
      "id": "phone-4",
      "label": "Moving phone",
      "epochId": "8fa55ddd-0a2b-49a5-9c58-8fc90f66a555",
      "sequence": 42,
      "role": "mobile",
      "position": { "x": 2.1, "y": 1.2, "z": 3.4 },
      "positionMode": "3d",
      "accuracyMeters": 1.5,
      "measurementAgeMs": 350
    }
  ]
}
```

Positions are meters with `x` right, `y` up, `z` forward in a fixed frame. `role` is `anchor`,
`mobile`, or `gateway`. `positionMode` is `3d` for estimated height or `floor`, where `y` must be
`0` and the dashboard marks the height as assumed.

Response: `{ "accepted": n, "ignored": n }`. Lower or repeated sequences in the same epoch are
ignored; a new `epochId` restarts the sequence but retired epochs stay retired for the session.
A different `frameId` returns `409` instead of mixing coordinate systems.

## API

| Endpoint | Purpose |
|---|---|
| `GET /api/health` | Gateway connection check |
| `POST /api/updates` | Gateway position batch |
| `GET /api/state` | Full scene snapshot |
| `GET /api/events` | SSE snapshots (full state at most once per second) |
| `POST /api/mode` | `{"mode": "live" \| "simulated" \| "idle"}` |
| `POST /api/simulation` | `running`, `stale`, `gatewayDown`, `reset` |
| `POST /api/reset` | `{"confirm": true, "mode": "live" \| "simulated"}` |

State is in memory only. Restarting the backend clears it. The server has no authentication and
must not be exposed to the internet.

## Verification

```powershell
npm run sample                      # accepted, moving, and duplicate updates
npm run sample -- --duplicate       # duplicate handling only
npm run sample -- --stale           # rejection handling only
npm run typecheck
```

## iPhone gateway notes

- Upload about once per second with `URLSession`; one in-flight request, ~3 s timeout.
- Add `NSLocalNetworkUsageDescription`; allow local development HTTP per the target iOS version.
- Keep the latest unsent update per device when a request fails, retry with capped backoff.
- Other mesh phones need no Wi-Fi upload code; only the gateway does.
