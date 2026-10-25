# Handover: start here

Written 24 October 2026, evening, when Silas stepped off the project. Everything is in this repository;
nothing needed lives only on Silas's Mac. Read this page first, then the documents it points to.

## Same build on every phone

Phones link over Bluetooth only if they all speak the same wire version; a phone on another version is
refused at the Hello.

| Build | Where from | Wire |
|---|---|---|
| TestFlight **12** | commit `b793f3b` | v3 |
| `main` before the UWB distances merge (`b6b378d` and earlier): build **13** from a Mac, or a GitHub Actions build of that commit | cable install, or TestFlight via GitHub Actions | v4 |
| `main` with UWB distances (merged by pull request #13): build **14** from a Mac, or a GitHub Actions build from then on | cable install, or TestFlight via GitHub Actions | v5 |

So every phone runs **the same row. Never a mix.** The build number is shown in TestFlight and in the
app's settings. GitHub Actions numbers its builds 100 + the run number, which says nothing about the wire
version: check which commit the run built. The dashboard's own Bluetooth mesh node speaks the same version
as the head of `main` (`MESH_PROTOCOL_VERSION` in `website/src/meshproto.ts`).

## The one branch

Use `main`. It holds everything: the team's work (signal map, fused tracking, dashboard pages, anchors,
the dashboard as a Bluetooth mesh node with 0.2 s gateway updates), the GhostCore work (contract, GNSS
integrity, positioning, Bluetooth relay, GhostUI map, Kalman prediction), the movement and route models
and the TestFlight setup. `ghostcore/release` and `feature/anchors-live` (via `feature/sim-2s`) are merged.

**Not merged, on purpose:**
- `feature/map-accuracy` and `docs/map-accuracy-review` (UWB direction, map accuracy). The review
  (`docs/history/map-accuracy/REVIEW_VERDICT.md`, now on `main`) says: don't merge the branch as is, port the UWB layer. Its
  phone-to-phone UWB distances were ported as wire v5 (`feature/uwb-v5`) and feed the signal map. Not
  ported: its `MeshLocator`/`LayoutSolver` (a second estimator), hand-held UWB bearings (they assume the
  map's +z is true north, and the rotation convention is unverified) and its map UI.
- `archive/luotsi-gps-check-port`: an exact Swift port of the Luotsi GPS lie detector with golden tests
  against the JavaScript. The app uses GhostCore's own GNSS integrity engine instead; reference only.
- Open review findings in the code merged from `main`, for Oskar, are listed in the message of merge
  commit `d69b798`.

| What | Where | Read |
|---|---|---|
| iPhone app | `ios/` (XcodeGen spec, `MeshCore` package with the tests) | `CLAUDE.md`, `app.md` |
| Laptop dashboard | `website/` (Node 20 or later, any OS) | `WEBSITE_PLAN.md` |
| Movement and route models | `ml/` | `ml/README.md`, demo page `ml/demo/index.html` |
| How it fits together, who owns what | | `ARCHITECTURE.md` (GhostCore contract, sections 5, 7 and 8), `OVERVIEW.md` |
| Demo script | | `DEMO.md` |
| Phone tests | | `ARCHITECTURE.md` section 9, `BLE_MESH_TEST_PROTOCOL.md` |

The first prototype, Luotsi (Bluetooth chain and the GPS lie detector, plain JavaScript in the
browser), stays online at https://luotsi-eight.vercel.app and https://luotsi-eight.vercel.app/detector.html.

## Getting the app on your iPhone

Every phone that should link must run the same build ([see the table](#same-build-on-every-phone)).

Nobody on the team has a Mac, so: **TestFlight installs the app, and GitHub's Macs build it** (below).

**TestFlight (no Mac needed).** The app is "MeshMapperSTUHI" on STUHI's Apple team (`Q485H7YK66`).
1. Silas, or another admin of STUHI's App Store Connect, invites you under Users and Access.
   Accept the email.
2. You are added to the internal testing group, which installs new builds automatically.
3. Install the TestFlight app from the App Store, open the invite and install MeshMapper.

The newest TestFlight build is **12** (uploaded 24 October, 21:16, Release build of `b793f3b`, wire v3).

**No TestFlight invite? Sideload from Windows (free Apple ID).** TestFlight invites need an Admin
of STUHI's App Store Connect. Without one, install the unsigned build that GitHub makes on every push:
1. Install Apple's drivers (the **Apple Devices** app from the Microsoft Store, or iTunes from
   apple.com) and **Sideloadly** (https://sideloadly.io).
2. GitHub → **Actions** → **iOS app** → the newest green run on `main` → **Artifacts** →
   `MeshMapper-build<N>-wire<V>-<commit>`. Unzip it to get the `.ipa`.
3. Plug in the iPhone, unlock it, tap **Trust**. In Sideloadly drag in the `.ipa`, enter your Apple ID
   (a free one works) and press **Start**; enter the two-factor code if asked. If it complains about
   the app ID, tick **Advanced options → Change bundle ID** (for example `com.yourname.meshmapper`);
   the mesh doesn't care about the bundle ID.
4. On the iPhone: Settings → General → **VPN & Device Management** → trust your Apple ID, then
   Settings → Privacy & Security → **Developer Mode** on (the phone restarts).
5. A free Apple ID signs for **7 days**; run Sideloadly again before then. At most 3 sideloaded apps
   per free Apple ID.

Everyone sideloads the **same** `.ipa` (the name shows the build and the wire version). A sideloaded
phone and a TestFlight phone link only if their wire versions match.

**New builds without a Mac (GitHub Actions).** `.github/workflows/ios.yml` runs on GitHub's macOS
machines, free for this public repository:
- Every push and pull request runs the GhostCore gate (`contract/validate.sh`: Swift tests, TypeScript
  checks, an unsigned iOS build). Nobody can compile Swift on Windows, so this green tick is the
  compiler: don't merge red.
- **Actions → iOS app → Run workflow** builds a signed Release and uploads it to TestFlight as build
  100 + the run number (always above the Mac uploads). Testers in the internal group get it
  automatically once Apple has processed it (5 to 15 minutes), so all phones move to the new build
  together. The button appears once the workflow is on `main` (after pull request #12).
- One-time setup before the first upload: an Admin of STUHI's App Store Connect creates a team API key
  with the **Admin** role (Users and Access → Integrations → App Store Connect API), and the repository
  owner adds three secrets under Settings → Secrets and variables → Actions: `ASC_KEY_ID`,
  `ASC_ISSUER_ID` and `ASC_KEY_P8` (the whole text of the downloaded `.p8` file).

**Cable install (Mac with Xcode, an Apple ID on STUHI's team).** Fastest for test phones and the only
way to run a change before it is uploaded. Commands are in `ARCHITECTURE.md` section 8. New phones are
registered automatically by `-allowProvisioningDeviceRegistration`; turn on Developer Mode on the phone.
Cable-installed Debug builds and TestFlight builds replace each other, so turn off automatic updates
in TestFlight on phones you are testing with.

**Uploading from a Mac** (if one turns up) also works: run `contract/validate.sh`, set
`CURRENT_PROJECT_VERSION` in `ios/project.yml` above the last upload (check App Store Connect: GitHub
uploads are numbered 101 and up), then archive and export as in `ARCHITECTURE.md` section 8.

## Running the demo on a laptop

```
cd website
npm run demo
```

It installs dependencies on the first run, builds, starts the backend and opens http://localhost:3000.
Click **Simulated data** for a demo without phones: it includes a phone without GPS placed from
Bluetooth. For live phones, `DEMO.md` explains the gateway phone and the Connect panel's QR code.

## State on 24 October, 21:30

- **Test phones** (Silas's iPhone 16 Pro, Oskar's iPhone 13 Pro, the iPhone 15 "P diddy") run the
  cable-installed **Debug build 12** (`b793f3b`, wire v3). The app was started on all three at
  21:06–21:08. Oskar's iPhone kept dropping off the Mac's USB connection during installs; try another
  cable. Debug 12 and TestFlight 12 are the same code (`b793f3b`), so a phone on TestFlight 12 links
  with the test phones today.
- **Build 13** (head of `ghostcore/release`, wire v4) is not on any phone and not on TestFlight. It
  must go to all phones at once, replacing 12 everywhere.
- **Since then:** `main` gained the dashboard mesh node and wire v5 (UWB distances in
  neighbor reports, build 14). Skip build 13: install a v5 build on every phone in one round.
  UWB distances are on by default, so on its first start each UWB phone (iPhone 11 or newer, not SE)
  asks for Nearby Interaction permission: allow it, or that phone's links use Bluetooth signal
  strength only.
- **Distance tests:** Settings → Track → "Distance methods" shows every distance approach for one
  neighbor; its tape-measure trial scores them against a measured distance and shares the readings as
  CSV. Use it for T2.
- **Feature switches:** Settings → Start → Features turns motion, compass, the main map's placement
  engine and ranges, radio calibration, predictions, likely paths, fast updates and GPS check record
  relaying on and off without a new build (app.md, "Feature switches"). Set every phone the same way
  when comparing, and use "Reset features to defaults" afterwards.
- **Not yet verified on phones:** T1 (each pair linked within 30 s), T4 (a still phone outdoors
  reaching "GPS trusted" with the GPS check on), T2/T3 (distances, forced relay). `ARCHITECTURE.md`
  section 9 and `BLE_MESH_TEST_PROTOCOL.md` have the steps; record results in the protocol's table.
- **GPS check** is off by default. Turn it on in Settings once T4 shows a still phone reaches
  "GPS trusted"; `DEMO.md` explains what to skip if it doesn't.
- **Route model (v3)**: drawn on the map as likely paths with percentages since build 11.
- **Movement model (v2)** runs without the map patch: with the map its 90 % area held the person only
  77–85 % of the time on held-out data (`ml/README.md`).
- **Radio constants** are defaults; the tape-measure calibration (Settings → Bluetooth calibration,
  T2) has not been done.

## About the Claude sessions

Much of this was written by Claude Code sessions on Silas's Mac: a GhostCore integration lead with
agents for GNSS integrity, positioning, Bluetooth relay, the map and Kalman prediction, plus sessions for
the movement model, the dashboard and phone installs. They do not carry over. The repository and these
documents are the state; an agent starting fresh should read `CLAUDE.md`, then `ARCHITECTURE.md`
(ownership in section 5, the merge gate `contract/validate.sh` in section 7) before changing anything.
