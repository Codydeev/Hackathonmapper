# Hackathonmapper: Technical Overview

As of 24 October 2026. Exported from the team's Claude doc so it can be read without Claude.

## Summary

The dashboard side of MeshMapper is built and checked on Windows. The iPhone side has every planned feature written, but its newest code (PRs #6, #7 and #9, from `feature/positioning-plan`) has never been compiled. The last build that ran on phones was TestFlight build 6.

The system: foreground iPhones relay position reports to each other over Bluetooth LE. One gateway phone uploads the newest reports over HTTP to a laptop, which serves a live 3D dashboard. No GNSS or internet is needed during a demo.

| Area | Size | State on 2026-10-24 |
| --- | --- | --- |
| Dashboard and backend (`website/`) | ~5,300 lines of TypeScript | Typechecks; signal-map check passes; runs live, in simulation, and publicly through a Cloudflare tunnel |
| iOS app (`ios/`) | ~5,700 lines of Swift + ~1,100 lines of tests | Wire format v3, gateway upload, GPS, manual, fused and UWB position sources, on-phone signal map. Not compiled since the duplicate `Vector3` fix |
| Positioning | One shared estimator, the signal map, in TypeScript and Swift | Kept in step by 8 golden cases; the motion fusion filter is checked only in simulated walks |
| Movement model (`ml/`) | Python training, JSON weights, Swift and JS runtimes | v2 model ships in the app; the v3 route model sits on an unmerged branch |

The main gaps: no Swift compile or test run since the positioning merge; no radio behaviour verified on phones (both review documents are code readings); radio constants are defaults, not measurements; and the v3 route model still sits on an unmerged branch.

## System architecture

A position report travels one way: from its origin phone, hop by hop over Bluetooth, to the gateway phone, over HTTP to the laptop, and over SSE to every open browser. Browser controls (mode, reset, simulation) go back to the backend as ordinary `POST` requests.

![System architecture: mesh phones and the gateway phone, the laptop backend, and the browser dashboard](docs/overview-architecture.png)

The gateway reaches the laptop on the same LAN or hotspot (port 3000, no authentication), or from anywhere through the Cloudflare tunnel (port 3001, secret required). Both paths end in the same validation and merge code. The signal map runs in two places on the same reports: on the laptop for the dashboard, and on each phone for its own map, which needs no network.

## How phones and the laptop talk

Phones and the laptop follow two agreements, and both sides check them.

- **Phone to phone (Bluetooth):** each phone sends its own position about once a second and passes on what it hears from others, up to 5 hops. Every report keeps its sender's identity and counter, so old or repeated reports are ignored everywhere. All phones must run the same app version; an older build is refused.
- **Gateway to laptop (HTTP):** the gateway uploads the newest report for each phone about once a second. The laptop rejects anything malformed or from a different map frame. The app checks the same limits first, so one bad report cannot block the rest. If an upload fails, the gateway retries with only the latest reports.

## Laptop backend

The backend is a small Node server that keeps everything in memory, so a restart clears the scene.

- It accepts uploads, ignores duplicates and old reports, and keeps live and simulated data apart.
- Once a second it places the phones with the signal map (see Positioning) and pushes the result to every open browser.
- A built-in simulation provides fake phones and a fake outdoor site for demos without hardware, including a phone going stale and a gateway dropping out.
- On the local network it is open. For access from anywhere, `npm run tunnel` publishes it through Cloudflare, behind a secret token for the gateway and a key for browsers, and prints QR codes to connect.

## Dashboard

The dashboard runs in any browser and updates live. It has five views: a 3D scene of the phones and their Bluetooth links, a map of the simulated field site, and Network, Positions and Gateway pages that mirror the app's tabs.

- Links are drawn only when phones report them; a link only one side reports is dashed.
- Phones without a position of their own are placed from Bluetooth, with a circle showing the uncertainty.
- Since PR #10, an operator can pin a phone as an anchor at a known spot. An optional OpenStreetMap background is the one feature that needs internet.

## Positioning

The laptop and every phone place phones the same way, with one method called the signal map. Each phone's own position comes from one of these sources:

| Source | Typical accuracy | Tried on phones |
| --- | --- | --- |
| GPS | 5 to 30 m, weak indoors | Yes |
| Typed-in spot | As good as the tap | Yes |
| Motion + Bluetooth anchors (fused) | About 1 to 2 m in simulation | No |
| UWB from a mounted anchor phone | About 0.5 m at 3 m | No |
| None | Placed from Bluetooth by the signal map | Yes, on the laptop |

The signal map arranges phones so that the distances between them match their Bluetooth distances, and it uses reported positions where they exist. In one test case, the error in an anchor-to-phone distance dropped from 11.4 m (GPS alone) to 0.11 m. The phone version and the laptop version are checked against each other with shared test cases.

Phones and the laptop turn signal strength into distance with the same radio model. It is rough: a measured 2 m can really be anywhere from 1.3 to 3.2 m. The live constants are still defaults: the tape-measure calibration session has not happened.

When Bluetooth loses a phone entirely, a small machine-learning model predicts where the person has probably gone, drawn as a growing area. It was trained on public hiking tracks and cuts the search area by about a third compared with simple guesses. A newer version is on an unmerged branch.

## iOS app

The app starts by itself and shows one map with this phone and every phone the mesh reaches. A settings sheet holds five tabs: Track, Start, Network, Position and Gateway. Any phone becomes the gateway by scanning a QR code from the dashboard.

Most of the logic lives in a separate Swift package with 63 unit tests, so it can be tested without phones. The last version that was built and installed is TestFlight build 6. Everything since (motion fusion, the new app views and the signal map) has not been compiled yet, because only one team member has a Mac.

## Testing

Every check that runs on Windows passed on 2026-10-24. Anything that needs the Mac or real phones has not run since build 6.

| Check | Result |
| --- | --- |
| Website type check | Pass |
| Signal-map test cases | 8 of 8 pass |
| Server tests on a spare port | Pass |
| Swift unit tests and app build (Mac) | Not run since build 6 |
| Fusion, UWB and the signal map on phones | Never run |

To run the dashboard, use `npm run demo` the first time or `npm start` after that, then open http://localhost:3000.

## Branch state, risks and next steps

The largest risk is one big uncompiled iOS change: 26 files and about 4,400 added lines under `ios/` since build 6. That code also moves the wire format from version 2 to 3, so build 6 phones and new phones will refuse each other.

### Branches

| Branch | State | Holds |
| --- | --- | --- |
| `main` (7908db0) | Base | PRs #1 to #10 |
| `feature/positioning-plan` (da15211) | Merged in PR #9 | The signal map replaces both particle filters, on the server and on the phone; the CLAUDE.md rules for Mac builds |
| `feature/anchors-live` (54d1f42) | Merged in PR #10 | Anchor pins from the dashboard, framing on anchors, the mirrored 3D view fixed, compass coordinates, optional OpenStreetMap background, tunnel watchdog, `nodemon` without the type check |
| `feature/anchors`, `fix/tunnel-watchdog` | Contained in PR #10 | Earlier steps of `feature/anchors-live` |
| `origin/movement-model` (61aa6a5) | 2 commits not merged | Route model v3, with a Swift port and golden tests |

### Risks

| Risk | Effect | Mitigation |
| --- | --- | --- |
| ~4,400 lines of Swift never compiled | The next Mac session may hit several errors at once | Windows checks are done; the Mac owner pastes the full output so it is fixed in one pass |
| Wire format v2 on build 6 phones, v3 in the code | Mixed phones refuse each other at the Hello | Install the new build on every phone in the same round |
| Radio constants are defaults | Ranges and the map carry an unknown bias | Tape-measure session: RSSI at 1, 2, 3, 5, 8, 12 and 20 m, indoors and outdoors |
| Fusion and UWB checked only in simulation or not at all | Accuracy claims unproven | Keep them off the demo's critical path until a walk test is done |
| Quick tunnel URL changes when `cloudflared` restarts | The gateway keeps uploading to a dead URL | The watchdog prints a warning; rescan the QR code, or use a named tunnel |
| LAN `GET /api/connect` returns the gateway token to anyone on the LAN | A LAN user could upload through the public URL | Acceptable on a trusted LAN; use a team-controlled hotspot |
| Simulation skips `validateBatch` | A simulator bug could put data on screen that a real upload could not | Low impact; route simulated batches through the validator if it matters |
| Foreground only; GPS frame valid within 10 km of Hervanta | Locked phones stop relaying; GPS elsewhere is rejected | Demo-mode keep-awake; add a frame origin for another site |

### Next steps

- [x] Commit or drop the working-tree changes. The CLAUDE.md section was committed (da15211). The tunnel and `nodemon` changes were dropped because PR #10 carries the identical files.
- [x] Merge `feature/positioning-plan` (PR #9), then `feature/anchors-live` (PR #10), into `main`. The merge result passed typecheck, the signal-map check, a production build and a smoke test of anchor pins first.
- [ ] Decide whether the v3 route model joins this Mac round, so the phones are installed once.
- [ ] In one Mac session: run `swift test` in `ios/MeshCore`, then `xcodegen`, an app build and TestFlight build 7 for every phone.
- [ ] On the phones: three phones on a tape-measured triangle (the positioning review's bench test), the radio calibration session, and one fused walk among four anchors.
