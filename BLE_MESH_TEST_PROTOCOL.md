# Bluetooth mesh: three-iPhone test protocol

Step-by-step procedures for the Bluetooth part of the field tests in [ARCHITECTURE.md](ARCHITECTURE.md):
**T1, T2, T3 and T11** (section 9) and acceptance criterion **AC-3** (section 11). Pass thresholds for
those IDs live in ARCHITECTURE.md and are not repeated here. The **R tests** below cover relay
features those IDs don't: receipts, store-and-forward, duplicates, TTL, hop limits and permissions.
Their pass criteria are defined here.

> **Status 2026-10-24: nothing in this document has been run on an iPhone.** Multi-hop relaying,
> store-and-forward and duplicate suppression pass unit tests on a simulated network (`swift test`:
> `RelayEngineTests`, `RecordRelayTests`). Hardware results go in the [results table](#results). Until
> T3 and R3 pass there, say "works in simulation", never "works".

## What is under test

All traffic uses Core Bluetooth GATT links between foreground iPhones, wire format v3. Each link
starts with a Hello carrying the app device ID, and frames are typed:

| Frame | Carries | Relay rule |
|---|---|---|
| 1 Hello | Device ID, label, frame ID | Link-local |
| 2 Position (`MeshPacket`) | Each phone's latest report | Latest per origin by epoch + sequence; resent to new links |
| 3, 4 UWB | Ranging token / fix | Link-local |
| 5 Relay message (`RelayEnvelope`) | Text, pings, T3 beacons, receipts | Every message delivered once per phone; stored and handed to phones that link later until TTL, receipt or hop limit |
| 6 Relay summary | IDs a phone has seen | Link-local; on link-ready and every 10 s |
| 7 GhostCore record (`RelayMessage`) | Positions, GNSS assessments, predictions, peer observations | State: latest per origin and type, stored for late links. Observations: once, never stored |

The guarantees the tests check:

- **Message IDs:** set by the origin and never changed. Each phone remembers IDs for 20 minutes
  (records: 10), longer than any TTL, so it delivers each message once.
- **TTL:** an age that each phone adds its hold time to, measured on its own monotonic clock
  (`CLOCK_MONOTONIC`, which keeps counting while the phone sleeps). Wall clocks are never
  compared. The age leaves out link queue and air time, so it is a **lower bound**.
- **Hops:** `hopsRemaining` plus `path`. A copy whose path already contains the phone is dropped,
  and so is a phone's own message coming back.
- **Timestamps:** `createdAt`/`timestamp` is the origin's wall clock, shown for reading only and
  marked "not synced".
- **Reconnect:** a failed outgoing link retries after 5, 10, 20, 40, then 60 s, plus up to 2 s of
  jitter. A link that stays ready for 30 s resets the count. Link setup must finish within 10 s.

## iOS and Core Bluetooth limits that shape the tests

- **Foreground only.** The app declares no Bluetooth background modes (an integration decision; see
  ARCHITECTURE.md section 12). A backgrounded or locked phone is suspended within seconds: it stops
  scanning, advertising and relaying. T11 records what actually happens to its links.
- **Permission.** iOS asks once (`NSBluetoothAlwaysUsageDescription`). If the user denies it, the
  app shows "Bluetooth permission denied. Allow it in Settings > Privacy & Security > Bluetooth"
  (R7).
- **Identity.** Advertisements carry only the service UUID (plus the name, in the foreground). Core
  Bluetooth identifiers differ per observer and rotate, so a phone's app device ID is known only
  after a Hello. Phones seen only by advertisement appear without a device ID.
- **Links.** The app keeps at most 8 logical neighbors (its own budget, not an iOS limit) and one
  link per neighbor: when two phones link both ways, the higher device ID closes its outgoing one.
  Write chunks are sized to one ATT write; the size is logged when each link becomes ready.
- **RSSI.** Connection RSSI (`readRSSI`, 1 Hz) exists only on the side that is central. The
  advertisement RSSI rate is irregular. iPhones don't advertise TX power, and 127 means
  unavailable. RSSI is link quality; nothing here converts it to a distance.
- **Why not MultipeerConnectivity.** It is foreground-only too, gives no RSSI, hides which radio
  and route it uses, and caps a session at 8 peers. Core Bluetooth gives RSSI and explicit,
  inspectable links, which the relay and positioning both need.

## Tools on the phone

Settings (gear) → **Network** → **Relay test (store-and-forward)**:

- **Linked now**: ready neighbors, link and advertisement RSSI, and whether each runs the relay.
- **T3 relay test**: 1 Hz numbered beacon (sender), and live delivery %, routes, median/p95 age
  and duplicate count per sending phone (receiver).
- **Send**: a message to everyone or one phone, with hops and TTL. Sent messages show their receipt
  route; received messages show route, hops, age and origin clock.
- **Test filter (A–B–C)**: makes this phone refuse links to chosen phones. Not persisted; a
  restart clears it, and a banner shows while it is on. It masks links; it does **not** take
  phones out of radio range.
- **Counters** for relay messages and GhostCore records.
- **Event log**: link ready/closed (with reason, retry delay and time ready), Hello refusals,
  radio state, observation rates every 10 s (`obs`), every beacon and record sent and received.
  **Prepare log for sharing** → **Share** exports JSON lines with a header (device ID, label,
  model, iOS, build, wire version).

`tools/ble-mesh/t3_check.py` computes AC-3 from P1's and P3's exported logs: delivery against what
P1 actually sent, identity (message ID per sequence, origin), routes, ages and duplicates. It was
checked on synthetic logs only.

## Before every session

1. **Same build on all three phones.** It must contain this branch's relay work and the two
   integration hooks: the `default:` case in `MeshModel.receiveRanging`, and the Relay test link in
   `NetworkView`. Check `CFBundleVersion` per ARCHITECTURE.md section 8. Mixed builds are not
   tested; v2 builds refuse v3 at the Hello.
2. On each phone: **Network** tab → Label `P1`, `P2`, `P3` (as in ARCHITECTURE.md section 9), the
   same Frame ID, Mesh running on, Keep screen awake on. iOS Settings → Display & Brightness →
   Auto-Lock → Never for the session. Bluetooth on in iOS Settings.
3. On each phone: Relay test → Event log → **Clear log**. Confirm no Test filter banner.
4. Note date, time, place, weather, phone cases, and how the phones are held (hand, pocket, table).
   RSSI changes a lot with each.
5. After each test: on every phone involved, **Prepare log for sharing** → **Share** → AirDrop to
   the Mac. Save as `contract/field-results/<date>-<test>-<P#>.jsonl` and write
   `contract/field-results/<date>-<test>.md` as ARCHITECTURE.md section 9 describes. Then fill in the
   [results table](#results).

## T1 Install and handshake

1. Install the build on P1–P3 (ARCHITECTURE.md section 8) and confirm equal `CFBundleVersion`.
2. Put the phones within 3 m of each other. Open the app on all three within 10 s of each other
   and start a stopwatch.
3. On each phone open Relay test. Wait until **Linked now** lists the other two phones, each
   tagged `relay`. Note the time.
4. Export the three logs.

Record from the logs: per pair, `link ready … after X s, chunk N B`; any `refused` or `closed` lines
and their reasons; which phone is central (`ready out`) for each pair. A chunk size under 182 B, or
a link closing with a write error, points to the MTU issue in BLUETOOTH_REVIEW.md, issue 1.

Pass: ARCHITECTURE.md T1.

## T2 Peer observations

Only P1 and P2. Turn P3's app off or take P3 more than 50 m away.

1. Mark 2, 5, 10 and 20 m on the ground with a tape measure, in the open, away from walls and
   metal.
2. Hold both phones at chest height, screens up, tops pointing at each other. Same posture
   throughout.
3. At each distance: hold still for 60 s and note the start time. Walk to the next mark (about
   10 s).
4. Export both logs.

Evidence: `obs` lines every 10 s per peer and channel, in the form `10 s: <peer> connection ready:
N snapshots with samples, M raw, smoothed X dBm, sd Y dB`. N ≥ 8 per 10 s means at least 0.8 Hz.
Only the central side of the pair has a `connection` channel, so for each direction note which
channels exist.

Calibration table for the positioning engine, one row per distance and direction (P1 hears P2, P2
hears P1): median smoothed RSSI, sd, snapshot rate per channel.

Pass: ARCHITECTURE.md T2.

## T3 Forced relay A→B→C (AC-3)

Setup: P1, P2 and P3 in a line, 5–10 m apart, P2 in the middle. All three can hear each other by
radio; the test filter forces the route through P2.

1. Start from T1's state: all three linked.
2. On **P1**: Relay test → Test filter → turn on **Ignore P3**. On **P3**: turn on **Ignore P1**.
   Set it on both ends.
3. Wait 15 s, then check **Linked now**: P1 lists only P2, P3 lists only P2, P2 lists both. If
   P1 and P3 still list each other, **stop**: the filter failed. Export the logs and report a bug.
4. On P3: if beacon statistics are shown, tap **Reset received statistics**.
5. On P1: set **Beacon hops** to 2 and turn on **Send 1 Hz beacon**. Start a stopwatch.
6. After 2 min 10 s, turn the beacon off on P1 and note `sent N`.
7. On P3, screenshot the T3 panel: received of expected, routes, median/p95/max age, duplicates.
8. Export the logs from all three phones. Take P2's device ID from its log header and run:

   ```
   python3 tools/ble-mesh/t3_check.py <P1 log> <P3 log> --middle <P2 device ID>
   ```

   The script prints each check and `AC-3: PASS` or `FAIL`. Copy its output into the result file.
9. **Records variant**, once `GhostCorePipeline` sends this phone's records: keep the same filter,
   let the pipeline run at least 2 minutes, export the logs, and run the script with
   `--records position`. This measures AC-3 on the reports themselves.
10. Turn the filters off on P1 and P3 (or restart the apps) and confirm all three phones link again.

Pass: ARCHITECTURE.md T3 and AC-3. Identity is checked by message ID per sequence and origin
device ID.

**Optional T3-SF**, store-and-forward under the same mask. During a separate beacon run, P3 walks
out of P2's range until P2's log shows the link closed, waits 20 s, and walks back. Beacons sent
meanwhile should arrive late through P2's store, with ages up to the gap. Record delivery and
maximum age, but don't count this run toward AC-3.

## T11 Robustness

Run each part with all three phones linked and no filter. Export all three logs after each part.

1. **Bluetooth off and on.** On P2: iOS Settings → Bluetooth off, wait 10 s, then on. P2 should
   show a Bluetooth status message while off. The logs show `radio … poweredOff/on`, link closes on
   P1 and P3, and `link ready` again. Time from Bluetooth on to both links ready: ≤ 30 s. Repeat
   with the Control Center button and record what happens. On recent iOS it disconnects without
   powering off, so its behavior may differ.
2. **Background and back.** On P2, go to the Home Screen, wait 30 s, and reopen the app. Then
   repeat with the screen locked for 30 s. Expected: P2 is suspended and stops relaying. Record
   whether P1 and P3 log the links closing, and the time from reopening to both links ready
   (≤ 30 s).
3. **App restart.** Force-quit P1 and relaunch it. Expected: P1 starts a new epoch. On P2 and P3,
   P1's position sequence restarts and never jumps back to old values (Network tab, Known devices),
   and P1's relay statistics start from zero. Time to links ready: ≤ 30 s.
4. **Walk away and back.** P3 walks away until P2's log shows `closed … retry in X s`, stays out
   30 s, and returns. Record the time from P3 stopping beside P2 to `link ready`. Expected: within
   the current backoff (5–62 s), usually under 10 s after the first failure.
5. **30-minute run.** All three linked, P1's beacon on, an occasional message by hand. Pass: no
   crash, the apps still respond, links are up at the end. Count `closed` lines per pair.

Pass: ARCHITECTURE.md T11.

## R tests: relay messages

Pass criteria for R1–R8 are defined here. Use **Send** on the Relay test screen.

**R1 Direct message and receipt.** P1 and P2 linked. On P1, send `hello R1` to P2 (hops 6, TTL
10 min). Pass: P2 lists it once with route `P1 → this phone` and 1 hop. Within 5 s, P1's Sent list
shows `Delivered: this phone → P2`.

**R2 Multi-hop message and receipt.** T3 filter on (P1 ignores P3 and the reverse). On P1, send
`hello R2` to P3. Pass: P3 lists it once with route `P1 → P2 → this phone` and 2 hops. P1 shows
`Delivered: this phone → P2 → P3`. P2 does not list it, and P2's `cleared` counter goes up by 1
when the receipt passes.

**R3 Store-and-forward carry.** P3 at least 50 m away, out of range (its Linked now shows nobody).
P1 and P2 together.
1. On P1, send `hello R3` to P3, TTL 15 min. P2's **Stored now** goes up by 1, and P1 shows
   `Waiting for a receipt`.
2. P2 walks to P3. P1 stays where it is and does not follow.
3. Pass: within 30 s of P2 and P3 linking, P3 lists `hello R3` with route `P1 → P2 → this phone` and
   an age at least the walking time. P2's Stored now goes back down after the receipt.
4. P2 walks back to P1. Pass: P1 shows `Delivered` within 30 s of P1 and P2 linking.

**R4 Duplicate suppression.** All three linked in a triangle, no filter. On P1, send 20 pings to
Everyone, about one a second. Pass: P2 and P3 each list exactly 20. At least one of them shows
`duplicates` > 0, because the same copy also arrived through the other phone. No ping is listed
twice.

**R5 TTL expiry.** P3 out of range, as in R3. On P1, send to P3 with TTL 1 min. Wait 70 s with P2
beside P1, then bring P2 to P3. Pass: P2's `expired` goes up and its Stored now drops to 0 before
the walk; P3 receives nothing.

**R6 Hop limit.** T3 filter on. On P1, send to Everyone with hops 0. Pass: P2 lists it; P3 does
not. Then repeat with hops 1: P3 lists it with route via P2.

**R7 Permission denied.** On P3: iOS Settings → Privacy & Security → Bluetooth → MeshMapper off,
then return to the app. Pass: the status reads "Bluetooth permission denied …" and nothing crashes.
Turn permission back on and return to the app. Pass: links ready within 30 s (relaunch the app if
iOS requires it; record whether it did).

**R8 Real range (recommended before claiming range extension).** Outdoors, place P1 and P3 far
enough apart that, with **no filter**, neither lists the other in Linked now for 60 s (try about
80–150 m; note the distance). Put P2 in between, where it lists both. Then run T3's beacon steps
5–8 without any filter. This proves a message reached a phone out of the sender's radio range.
T3 alone proves routing, not range.

## Results

| Test | Date | Build | Phones | Result | Evidence |
|---|---|---|---|---|---|
| T1 Install and handshake | | | | not run | |
| T2 Peer observations | | | | not run | |
| T3 Forced relay, beacons (AC-3) | | | | not run | |
| T3 Forced relay, records (AC-3) | | | | not run | |
| T3-SF Store-and-forward under mask | | | | not run | |
| T11.1 Bluetooth off/on | | | | not run | |
| T11.2 Background and lock | | | | not run | |
| T11.3 App restart | | | | not run | |
| T11.4 Walk away and back | | | | not run | |
| T11.5 30-minute run | | | | not run | |
| R1 Direct message and receipt | | | | not run | |
| R2 Multi-hop message and receipt | | | | not run | |
| R3 Store-and-forward carry | | | | not run | |
| R4 Duplicate suppression | | | | not run | |
| R5 TTL expiry | | | | not run | |
| R6 Hop limit | | | | not run | |
| R7 Permission denied | | | | not run | |
| R8 Real range | | | | not run | |

## Known limits

- Ages are lower bounds: they leave out time spent in link queues and on the air.
- The test filter masks links between phones that can hear each other. Only R8 shows range
  extension.
- There is no authentication. Any phone running the app on the same frame can send and relay.
  This is acceptable for the demo; say so if asked.
- State is in memory. A relay's stored messages survive backgrounding only while iOS keeps the app
  alive, and are lost when the app is terminated.
- Foreground only. A phone in a pocket with the screen locked does not relay.
