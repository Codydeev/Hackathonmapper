# Handover: start here

Written 24 October 2026, evening, when Silas stepped off the project. Everything is in this repository;
nothing needed lives only on Silas's Mac. Read this page first, then the documents it points to.

## Same build on every phone

Phones link over Bluetooth only if they all speak the same wire version; a phone on another version is
refused at the Hello.

| Build | Where from | Wire |
|---|---|---|
| TestFlight **12** | commit `b793f3b` | v3 |
| Anything built from the head of `ghostcore/release` (it includes the team's `main`): build **13** from a Mac, or **101 and up** from GitHub | cable install, or TestFlight via GitHub Actions | v4 |

So the team runs **either TestFlight 12 on every phone, or a cable build of the release head on every
phone. Never a mix.** The build number is shown in TestFlight and in the app's settings.

## The one branch

Use `main`. The pull request **ghostcore/release → main** brings everything into it: the team's main
(Oskar's signal map, fused tracking, dashboard pages, anchors), the GhostCore work (contract, GNSS
integrity, positioning, Bluetooth relay, GhostUI map, Kalman prediction), the movement and route models
and the TestFlight setup. `ghostcore/release` already contains every commit on `main`, so the merge has
no conflicts. Until it is merged, use `ghostcore/release`.

Merging that pull request moves `main` to wire v4 (see above); the team decides when.

**Not merged yet:**
- Cody's `feature/map-accuracy` (UWB direction, map accuracy). Its review on `docs/map-accuracy-review`
  (`docs/REVIEW_VERDICT.md`) says: do not merge the branch as is, port the UWB layer onto `main`. It
  also calls itself wire v4 with a different format from the release's v4, so once rebased it needs v5.
- Oskar's `feature/anchors-live` after pull request #10 (the dashboard as a Bluetooth mesh node,
  0.2 s gateway updates): still in progress, and its browser node speaks v3.
- Open review findings in the code merged from `main`, for Oskar, are listed in the message of merge
  commit `d69b798`.
- `archive/luotsi-gps-check-port`: an exact Swift port of the Luotsi GPS lie detector with golden tests
  against the JavaScript. The app uses GhostCore's own GNSS integrity engine instead; reference only.

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
