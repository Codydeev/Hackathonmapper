# GNSS integrity (trust engine)

Owner: GNSS integrity (GhostCore). Code: `ios/MeshCore/Sources/MeshCore/GNSSIntegrity.swift` (engine and
contract adapter), `GNSSFaultInjection.swift` (synthetic fault harness). Tests:
`ios/MeshCore/Tests/MeshCoreTests/GNSSIntegrityTests.swift`, `GNSSFaultHarnessTests.swift`.

## What it does, and what it does not claim

Every second the engine answers one question about this phone's GNSS: can this fix be believed now,
how much, and why. It produces an `IntegrityAssessment` (contract, ARCHITECTURE.md §4) with a status,
a trust score and interval, reason codes, per-check evidence, a minimum detectable offset and a one-line
summary.

- **Anomaly detection, not spoofing detection.** A fix that fails these checks can come from multipath,
  a receiver fault, jamming, a wrong inertial or peer input, or spoofing. Phone data cannot tell them
  apart, so the engine lists possible causes (`GNSSPossibleCause`, spoofing only ever one of several),
  `spoofingConfirmed` is always false, and no status, reason or summary says "spoofed". Anomalies end
  their UI line with "not proof of an attack".
- **Independent evidence only.** Peers placed by their own GNSS share its errors: one spoofer, one jammer
  or one ionosphere covers the whole group (common mode). Their agreement never verifies a fix; it can
  only object to it. Only evidence that does not depend on any GNSS receiver can make a fix `trusted`:
  inertial motion, a surveyed beacon, or a position estimate with `provenance.gnssDependent == false`.
- **No radio.** Faults are injected into the fixes the app hands to the engine. Nothing transmits, and
  nothing needs a GNSS simulator (ARCHITECTURE.md §10).

## Checks

All inputs share one clock (seconds) and the frame's floor plane (x east, z north, metres). A check
returns a score from 1 (consistent) to 0 (full objection), or nothing when it has no data. Residual
checks normalise by the combined 1-sigma and start doubting at 3.5 σ, reach "suspect" at 4.55 σ and
object fully at 7 σ.

| Check | Family | Independent of GNSS | Catches | Suspect when | Reason codes |
|---|---|---|---|---|---|
| freshness | quality | – | fixes that stop or arrive late | older than ~5.75 s; unavailable after 30 s | staleFix |
| accuracy | quality | – | jamming, obstruction; accuracy the fixes keep exceeding | reported 68 % radius > ~30 m (LocationSource's limit); unusable > 100 m; scatter > 2.5× stated | degradedAccuracy, accuracyInconsistent |
| timing | anomaly | – | replayed or reordered data | timestamp goes back, or > 2 s in the future | timestampInconsistent |
| speed | anomaly | – | teleports, fake tracks | speed beyond position noise > 8.75 m/s (pedestrian max 7 m/s), or Doppler speed above it | impossibleSpeed |
| acceleration | anomaly | – | velocity changes no person makes | > 4 m/s² beyond noise (Doppler velocity when reported, else three fixes) | impossibleAcceleration |
| jump | anomaly | – | sudden offsets, and offsets that persist after one | fix vs. the last accepted fix carried forward by inertial motion (or loosened 0.5 m/s without it), minus heading/step-length bias | positionJump |
| inertial | anomaly | yes (relative) | drift, frozen output, replays, common-mode errors | GNSS displacement vs. inertial displacement over 5, 15, 30, 60, 120 and 300 s windows, after allowing a 10° heading and 8 % step-length bias | inertialDisagreement, slowDrift (long windows only) |
| peerProximity | anomaly | no | this phone's GNSS far from peers that hear it | farther than the RSSI distance bound (2.5 σ weaker signal, capped at 92 m) + 3.5 σ of both positions; median of ≥ 3 peers, so one bad peer cannot condemn a fix | peerDisagreement |
| anchorProximity | anomaly | yes (absolute) | the same against surveyed beacons | as above | independentEvidenceDisagreement |
| positionEvidence | anomaly | if `gnssDependent == false` | this phone placed another way (Bluetooth, UWB, landmark) | 4.55 σ apart | independentEvidenceDisagreement or peerDisagreement |

A rejected fix never enters the reference, so after a jump or drift is caught the comparison stays
anchored to the last good fix plus inertial motion, and a persistent offset keeps being flagged until
the heading-bias allowance of the dead-reckoned leg covers it.

## From checks to a status

1. Anomaly trust = the lowest anomaly score (one confident objection is enough). It drops at once and
   climbs back at 0.1 per second (Luotsi's rule), so recovery is never instant.
2. Status, first match wins:
   - `unavailable`: no fix, fix older than 30 s, invalid, or accuracy beyond 100 m.
   - `rejected`: a timestamp regression, anomaly trust < 0.4, or any anomaly check ≤ 0.2.
   - `suspect`: anomaly trust < 0.75; once flagged it stays suspect until trust passes 0.85 (no flapping).
   - `degraded`: no anomaly, but freshness or accuracy below 0.75.
   - `insufficientEvidence`: no anomaly, but (a) no GNSS-independent check agrees, (b) the independent
     checks could miss an offset larger than `alertLimit` (50 m), or (c) **continuity was lost**: GNSS
     came back after an anomaly or outage while our own reference had loosened beyond 20 m (1 σ), so a
     real return cannot be told from a new offset (the jam-then-spoof opening). (c) clears only when
     absolute independent evidence (beacon, independent position) agrees.
   - `trusted`: none of the above. Per the contract it is the only status that may anchor others.
3. Reasons: the reason of every check below 0.75, plus `recovering` (anomaly status with no objecting
   check), and for `insufficientEvidence` one of `insufficientEvidence` / `continuityLost` and
   `peerEvidenceNotIndependent` when only GNSS-placed peers agree.

## Uncertainty

- **Trust interval** (`uncertainty.lower/upper`): upper = trust score. Lower = 0 with no independent
  check (nothing rules out a slow or common-mode error), half the score with only relative (inertial) or
  only absolute (beacon, independent position) evidence, the score with both. A coverage heuristic.
- **`minimumDetectableOffsetMeters`**: the smallest offset the active independent checks would flag now,
  worst direction. Absolute evidence bounds the whole offset; inertial motion only an offset built up
  within its longest window (that is what a slow drift has to beat). `nil` = unbounded: with GNSS-only
  checks a slow or common-mode error of any size could pass.
- `minimumDetectableDriftRate` (engine only): drift slower than this never leaves the inertial
  tolerance. Synthetic: about 0.07 m/s for a phone lying still, about 0.3 m/s walking straight with the
  10° heading allowance.
- `recommendedSigma` (engine) / `GNSSIntegrityMonitor.displayR95`: what to draw around a usable fix:
  1×, 1.5× (insufficient evidence), 2× (degraded), 4× (suspect) the fix's sigma, plus 1.5 m per second
  of fix age.

## Integration (contract)

`GNSSIntegrityMonitor` is the adapter the pipeline uses (ARCHITECTURE.md §6). Per one-second step, in
this order:

```swift
let monitor = GNSSIntegrityMonitor(subjectId: me, frameId: "hervanta-v1")   // options: .pedestrian / .vehicle
monitor.ingest(motion: m)                                   // every MotionObservation, in order
monitor.ingest(peer: obs, peerPosition: est, peerStatus: s) // a peer heard directly + its latest position
monitor.ingest(ownEstimate: est)                            // this phone placed without its own GNSS
let record = newFix.map { monitor.assess(fix: $0, now: now) } ?? monitor.assess(now: now)
monitor.displayR95                                          // radius for "GPS (unchecked)" / trusted display
```

It also has `ingest(fix:)` and `assess(subjectId:evidence:now:)`, the pipeline's
`GhostIntegrityEngine` protocol, so conformance is one line.

- Raw fix: `PositionEstimate` kind measured, method gnss; `r95` is turned back into iOS's 68 % radius.
  `evaluatedFix` is the fix judged, rejected ones included; `unavailable` carries none.
- Motion: `MotionObservation` displacement over its interval; its `displacementR95` sets the random
  error; `stationary` with no displacement counts as zero motion.
- Peers: a peer whose own status is suspect or rejected, whose estimate contains this phone in its
  provenance (circular), or that is only a prediction, is skipped. `gnssDependent` decides independence.
- Own estimates: skipped when ambiguous (a ring) or when built from this phone's own GNSS, which would
  judge the fix by itself. That means a used `gnss` input naming this phone, an unnamed `gnss` input in
  an estimate this phone produced (how the positioning engine records its own fix), or an estimate
  that depends on GNSS with no other phone involved. The jump and inertial checks already cover "last
  good fix plus motion". The rest are worded by origin: "this phone's own position estimate" (no
  peers, independent of GNSS → `independentEvidenceDisagreement`), "the peer-based position estimate"
  (GNSS-placed peers → `peerDisagreement`, not independent), or "the independent position estimate".
- Output: `algorithm "gnss-integrity@1"`, source fusion, `maxAge 5 s`, `gnssDependent true`, and
  `simulated` when the fix or any input within the last 330 s was simulated. Every record passes
  `IntegrityAssessment.validate()` (tested over nine scenarios).

Without motion data a GPS phone can never be `trusted`, so it never anchors; the pipeline therefore
wires this engine only together with the positioning agent's motion source. A phone lying still is
trusted 100 % of the time; walking straight, only about a third of the time (see the trade-off below).

## The fault harness

`GNSSSimulatedWorld(scenario:seed:)` builds one world per scenario and seed:

- a walker turning every 20–80 s at 1.2–1.5 m/s with occasional pauses (or a phone lying still);
- GNSS with Gauss-Markov error (2.5 m per axis, 45 s) plus white noise, accuracy reported honestly;
  in `.urban`, 5 m error plus multipath bursts: every ~150 s the fix steps 10–35 m aside for 8–25 s while
  reported accuracy grows by only a third;
- dead reckoning with a fixed heading bias (±4°), a heading random walk (±2°), step-length error (±3 %)
  and noise; zero motion with `stationary` while paused;
- three peers walking 8–35 m away with their own GNSS, heard with the outdoor radio model's
  probability and RSSI noise; surveyed beacons 15 m beside the route where requested.

Faults (`GNSSFault`) transform this phone's fixes from a start time, optionally until an end, and with
`commonMode` the peers' fixes too: `jump`, `fakeTrack`, `acceleration`, `slowDrift`, `frozenPosition`,
`delayed`, `dropout`, `jamming`, `replay`. `GNSSScenario.library` holds the scenarios below, including
ARCHITECTURE.md S2–S4 (`jump400`, `drift1`, `recovery`). The same world is replayed through each
detector configuration: GNSS only; + peers (GNSS-placed); + peers + beacons; + inertial; full.
`contractInputs(second:)` gives the same world as contract records, for the pipeline's scenario runner.

Metrics per run: detection delay and offset at detection (first `suspect`/`rejected` for faults that
misplace the phone, first non-trusted status for outage faults); clean-data alarms (seconds, episodes,
rejected seconds, and seconds in which GPS really was > 20 m off) before any fault; trusted share of
clean seconds; **misleading seconds** during a fault (a usable fix off by more than 30 m and more than
3.5× its recommended sigma) and how many of those were marked `trusted`; the largest error left
undetected.

Run:

```sh
cd ios/MeshCore
swift test --filter GNSS                     # unit tests and acceptance checks (10 seeds), ~10 s
GNSS_REPORT=/tmp/gnss.md swift test --filter GNSSFaultHarnessTests/testComparisonReport   # full table, ~45 s
```

## Results

**All numbers are synthetic** (the harness above, seeds 1–10), not field accuracy. Field tests T4, T6
and T7 (ARCHITECTURE.md §9) have not been run.

### Acceptance criteria (ARCHITECTURE.md §11)

| Criterion | Threshold | Synthetic result |
|---|---|---|
| AC-5, S2 jump 400 m | flagged within 3 s in 10/10 | 10/10 at 0 s, every detector configuration |
| AC-6, S3 drift 1 m/s at 90° | flagged before 50 m in ≥ 9/10, or honest bound | with motion: 10/10, median 24 s / 25 m (max 28 s); without motion: never flagged, and the bound is `nil` (unbounded) throughout, which is honest |
| AC-7, open-sky clean | 0 rejected, ≤ 1 suspect episode per 10 min | 0 alarms: walking and still, 10 × 15 min each, all five configurations (89,100 configuration-seconds), and 0 in the pre-fault part of every fault run |
| S4, offset removed | passes recovering / insufficient evidence before trusted | trust climbs 0.1/s, so ≥ 5 s of suspect + `recovering` first (tested on 10 seeds) |

### The integration lead's scenarios through `GhostCorePipeline`

`GNSSIntegrityTests.testContractScenariosWithThisEngine` runs `contract/scenarios/S0–S6.json` through
`ScenarioWorld` (the app's pipeline, three phones, seeded) with this engine as the integrity engine.
Without an engine these expectations are PENDING; with it (synthetic):

| Expectation | Result |
|---|---|
| S0-a: A's GPS never suspect or rejected on clean data (AC-7) | pass, 561 of 561 s |
| S2-a: C's 400 m jump flagged within 3 s (AC-5) | pass, 0 s |
| S2-b: B's estimate never anchored by C's GPS after detection | pass, 87 of 87 s |
| S2-c: A never shows C's jumped GPS as measured | pass |
| S3-a: C's 1 m/s drift flagged before 50 m (AC-6) | pass, 9 s after onset |
| S4-a: no re-trust within 4 s of the restore | pass |
| S4-b: trusted again within 60 s of the restore | pass, 10 s |

### Detection by evidence available (median delay / offset at detection, 10 seeds)

| Scenario | GNSS only | + GNSS-placed peers | + inertial | full |
|---|---|---|---|---|
| S2 jump 400 m | 0 s | 0 s | 0 s | 0 s |
| S3 drift 1 m/s | missed 10/10 | 69 s / 71 m | 24 s / 25 m | 24 s / 25 m |
| slow drift 0.5 m/s, walking | missed | 123 s / 61 m | 59 s / 30 m | 59 s / 30 m |
| slow drift 0.5 m/s, still | missed | 123 s / 61 m | 28 s / 17 m | 28 s / 17 m |
| slow drift 0.2 m/s | missed | 254 s / 52 m | 7/10, 239 s / 48 m | 10/10, 234 s / 52 m |
| very slow drift 0.05 m/s | missed | missed | missed | missed |
| common-mode drift 0.5 m/s | missed | **missed** (peers drift too) | 59 s / 30 m | 59 s / 30 m |
| common-mode drift, beacon passed at 600 s | missed | missed; + beacons: 302 s / 152 m | 59 s / 30 m | 59 s / 30 m |
| frozen position | missed | 9/10, 56 s / 63 m | 15 s / 21 m | 15 s / 21 m |
| fake track 15 m/s | 0 s | 0 s | 0 s | 0 s |
| acceleration 8 m/s² | 1 s | 1 s | 1 s | 1 s |
| replay 30 s old | 0 s | 0 s | 0 s | 0 s |
| jam 30 s, then 200 m offset | 0 s | 0 s | 0 s | 0 s |
| jamming / dropout / fixes 15 s late | 3 s / 5 s / 0 s (degraded) | same | same | same |

What happens after detection differs more than detection itself: with GNSS only, a 1 km teleport is
taken back after ~10 minutes (the reference has loosened enough), as `insufficientEvidence` with
`continuityLost`, never `trusted`. GNSS-placed peers hold the rejection as long as they are heard, unless
the error is common mode.

### False alarms

| Clean data, 10 × 15 min | GNSS only | + inertial / full |
|---|---|---|
| open sky, walking | 0 | 0 |
| open sky, still | 0 | 0 |
| urban multipath, walking | 16 episodes (1.1 per 10 min), 14 s rejected | 29 episodes (2.0 per 10 min), 28 s rejected; GPS really > 20 m off in 157 of 222 flagged s |
| urban multipath, still | 15 episodes (1.0 per 10 min) | 62 episodes (4.2 per 10 min), 69 s rejected; GPS really > 20 m off in 269 of 485 flagged s |

The urban model is deliberately harsh: a 35 m step with a reported accuracy of ~10 m is an
inconsistency, and on a phone lying still it is caught. Most of those flags are GPS really being wrong,
reported as an anomaly with multipath among the causes. Real urban behaviour is unmeasured.

### The `trusted` bound (`Options.alertLimit`)

`trusted` requires the independent checks to be able to catch an offset of `alertLimit` metres. Walking
straight with a 10° compass-bias tolerance, the 300 s inertial window can only promise about 90 m, so
the phone reads `insufficientEvidence` ("GPS agrees with steps, but a slow drift up to 90 m could pass
unseen"). The price of raising the bound is time spent `trusted` while more than 30 m off:

| alertLimit | Trusted share, clean walk | clean still | Trusted while > 30 m off: drift 0.2 m/s | drift 0.05 m/s | replay 30 s |
|---|---|---|---|---|---|
| 30 m | 8 % | 100 % | 0 s | 0 s | 0 s |
| **50 m (default)** | 35 % | 100 % | 58 s | 0 s | 65 s |
| 75 m | 68 % | 100 % | 680 s | 269 s | 327 s |
| 100 m | 100 % | 100 % | 1,344 s | 553 s | 336 s |

(10 seeds; fault runs 600–900 s.)

## Limitations

- **Synthetic only.** Noise models, multipath and radio are ours; field tests (T4, T6, T7) are pending.
- **Slow drift below the inertial tolerance is invisible** to relative sensors: about 0.07 m/s still and
  0.3 m/s walking straight with a 10° heading allowance. Only absolute evidence (a surveyed beacon, UWB to
  a fixed anchor, a landmark) catches it. Heading calibration would tighten this but lets a slow drag
  calibrate itself in, so it is not done.
- **Replay with a lag** looks like the true path delayed; while walking straight at constant speed it
  is consistent with the steps and only turns and pauses expose it.
- **Trust on first use.** The first accepted fix is assumed right; an attack already running at start-up
  is only caught by peers, beacons or independent positions.
- **Peer bounds are coarse.** RSSI is a bound (about 3× the RSSI distance, at most 92 m), not a range;
  peers catch only offsets larger than that.
- **Pedestrian profile.** `maxSpeed` 7 m/s and 4 m/s² flag a bus or car; use `Options.vehicle`.
- **No phone run yet.** The engine is not wired into the app; ARCHITECTURE.md §6 wires it together
  with the positioning agent's motion source.

## Appendix: full comparison (synthetic, seeds 1–10)

| Scenario | Detector | Detected | Delay median / max | Offset at detection | Clean-data alarms: s / episodes / rejected s / s with GPS really > 20 m off, of clean s | Trusted share (clean) | Misleading s (of them trusted) | Max undetected error |
|---|---|---|---|---|---|---|---|---|
| clean walk | GNSS only | – | – | – | 0 / 0 / 0 / 0 of 8910 | 0 % | – | – |
| clean walk | + peers | – | – | – | 0 / 0 / 0 / 0 of 8910 | 0 % | – | – |
| clean walk | + peers + beacons | – | – | – | 0 / 0 / 0 / 0 of 8910 | 0 % | – | – |
| clean walk | + inertial | – | – | – | 0 / 0 / 0 / 0 of 8910 | 35 % | – | – |
| clean walk | full | – | – | – | 0 / 0 / 0 / 0 of 8910 | 35 % | – | – |
| clean, phone still | GNSS only | – | – | – | 0 / 0 / 0 / 0 of 8910 | 0 % | – | – |
| clean, phone still | + peers | – | – | – | 0 / 0 / 0 / 0 of 8910 | 0 % | – | – |
| clean, phone still | + peers + beacons | – | – | – | 0 / 0 / 0 / 0 of 8910 | 0 % | – | – |
| clean, phone still | + inertial | – | – | – | 0 / 0 / 0 / 0 of 8910 | 100 % | – | – |
| clean, phone still | full | – | – | – | 0 / 0 / 0 / 0 of 8910 | 100 % | – | – |
| clean walk, urban multipath | GNSS only | – | – | – | 107 / 16 / 14 / 6 of 8910 | 0 % | – | – |
| clean walk, urban multipath | + peers | – | – | – | 107 / 16 / 14 / 6 of 8910 | 0 % | – | – |
| clean walk, urban multipath | + peers + beacons | – | – | – | 107 / 16 / 14 / 6 of 8910 | 0 % | – | – |
| clean walk, urban multipath | + inertial | – | – | – | 222 / 29 / 28 / 157 of 8910 | 13 % | – | – |
| clean walk, urban multipath | full | – | – | – | 222 / 29 / 28 / 157 of 8910 | 13 % | – | – |
| clean, still, urban multipath | GNSS only | – | – | – | 59 / 15 / 1 / 11 of 8910 | 0 % | – | – |
| clean, still, urban multipath | + peers | – | – | – | 59 / 15 / 1 / 11 of 8910 | 0 % | – | – |
| clean, still, urban multipath | + peers + beacons | – | – | – | 59 / 15 / 1 / 11 of 8910 | 0 % | – | – |
| clean, still, urban multipath | + inertial | – | – | – | 485 / 62 / 69 / 269 of 8910 | 95 % | – | – |
| clean, still, urban multipath | full | – | – | – | 485 / 62 / 69 / 269 of 8910 | 95 % | – | – |
| S2 jump 400 m | GNSS only | 10/10 | 0 s / 0 s | 401 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 1815 (0) | 410 m |
| S2 jump 400 m | + peers | 10/10 | 0 s / 0 s | 401 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| S2 jump 400 m | + peers + beacons | 10/10 | 0 s / 0 s | 401 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| S2 jump 400 m | + inertial | 10/10 | 0 s / 0 s | 401 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| S2 jump 400 m | full | 10/10 | 0 s / 0 s | 401 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| S3 drift 1 m/s | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 3312 (0) | 366 m |
| S3 drift 1 m/s | + peers | 10/10 | 69 s / 126 s | 71 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 533 (0) | 131 m |
| S3 drift 1 m/s | + peers + beacons | 10/10 | 69 s / 126 s | 71 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 533 (0) | 131 m |
| S3 drift 1 m/s | + inertial | 10/10 | 24 s / 28 s | 25 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 28 m |
| S3 drift 1 m/s | full | 10/10 | 24 s / 28 s | 25 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 28 m |
| S4 drift removed | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 302 (0) | 65 m |
| S4 drift removed | + peers | 2/10 | 47 s / 47 s | 47 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 284 (0) | 65 m |
| S4 drift removed | + peers + beacons | 2/10 | 47 s / 47 s | 47 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 284 (0) | 65 m |
| S4 drift removed | + inertial | 10/10 | 24 s / 28 s | 25 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 28 m |
| S4 drift removed | full | 10/10 | 24 s / 28 s | 25 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 28 m |
| teleport 1 km | GNSS only | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 160 (0) | 995 m |
| teleport 1 km | + peers | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| teleport 1 km | + peers + beacons | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| teleport 1 km | + inertial | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| teleport 1 km | full | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| jump 50 m | GNSS only | 10/10 | 0 s / 0 s | 51 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 3392 (0) | 58 m |
| jump 50 m | + peers | 10/10 | 0 s / 0 s | 51 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 3107 (0) | 58 m |
| jump 50 m | + peers + beacons | 10/10 | 0 s / 0 s | 51 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 3107 (0) | 58 m |
| jump 50 m | + inertial | 10/10 | 0 s / 0 s | 51 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 1195 (0) | 58 m |
| jump 50 m | full | 10/10 | 0 s / 0 s | 51 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 1101 (0) | 58 m |
| fake track 15 m/s | GNSS only | 10/10 | 0 s / 0 s | 4 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| fake track 15 m/s | + peers | 10/10 | 0 s / 0 s | 4 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| fake track 15 m/s | + peers + beacons | 10/10 | 0 s / 0 s | 4 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| fake track 15 m/s | + inertial | 10/10 | 0 s / 0 s | 4 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| fake track 15 m/s | full | 10/10 | 0 s / 0 s | 4 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| acceleration 8 m/s² | GNSS only | 10/10 | 1 s / 1 s | 7 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 5 m |
| acceleration 8 m/s² | + peers | 10/10 | 1 s / 1 s | 7 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 5 m |
| acceleration 8 m/s² | + peers + beacons | 10/10 | 1 s / 1 s | 7 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 5 m |
| acceleration 8 m/s² | + inertial | 10/10 | 1 s / 1 s | 7 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 5 m |
| acceleration 8 m/s² | full | 10/10 | 1 s / 1 s | 7 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 5 m |
| slow drift 0.5 m/s | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 6026 (0) | 334 m |
| slow drift 0.5 m/s | + peers | 10/10 | 123 s / 185 s | 61 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 945 (0) | 119 m |
| slow drift 0.5 m/s | + peers + beacons | 10/10 | 123 s / 185 s | 61 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 945 (0) | 119 m |
| slow drift 0.5 m/s | + inertial | 10/10 | 59 s / 109 s | 30 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 152 (9) | 52 m |
| slow drift 0.5 m/s | full | 10/10 | 59 s / 109 s | 30 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 148 (9) | 52 m |
| slow drift 0.2 m/s | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 5070 (0) | 138 m |
| slow drift 0.2 m/s | + peers | 10/10 | 254 s / 418 s | 52 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 1827 (0) | 107 m |
| slow drift 0.2 m/s | + peers + beacons | 10/10 | 254 s / 418 s | 52 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 1827 (0) | 107 m |
| slow drift 0.2 m/s | + inertial | 7/10 | 239 s / 387 s | 48 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 3194 (63) | 138 m |
| slow drift 0.2 m/s | full | 10/10 | 234 s / 335 s | 52 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 1357 (58) | 107 m |
| very slow drift 0.05 m/s | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 553 (0) | 40 m |
| very slow drift 0.05 m/s | + peers | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 553 (0) | 40 m |
| very slow drift 0.05 m/s | + peers + beacons | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 553 (0) | 40 m |
| very slow drift 0.05 m/s | + inertial | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 100 % | 553 (0) | 40 m |
| very slow drift 0.05 m/s | full | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 100 % | 553 (0) | 40 m |
| slow drift 0.5 m/s, phone still | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 6026 (0) | 334 m |
| slow drift 0.5 m/s, phone still | + peers | 10/10 | 123 s / 185 s | 61 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 945 (0) | 119 m |
| slow drift 0.5 m/s, phone still | + peers + beacons | 10/10 | 123 s / 185 s | 61 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 945 (0) | 119 m |
| slow drift 0.5 m/s, phone still | + inertial | 10/10 | 28 s / 38 s | 17 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 20 m |
| slow drift 0.5 m/s, phone still | full | 10/10 | 28 s / 38 s | 17 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 20 m |
| frozen position | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 913 (0) | 155 m |
| frozen position | + peers | 9/10 | 56 s / 108 s | 63 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 439 (0) | 110 m |
| frozen position | + peers + beacons | 9/10 | 56 s / 108 s | 63 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 439 (0) | 110 m |
| frozen position | + inertial | 10/10 | 15 s / 57 s | 21 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 26 m |
| frozen position | full | 10/10 | 15 s / 57 s | 21 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 26 m |
| replay 30 s old | GNSS only | 10/10 | 0 s / 0 s | 39 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 2654 (0) | 52 m |
| replay 30 s old | + peers | 10/10 | 0 s / 0 s | 39 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 2619 (0) | 52 m |
| replay 30 s old | + peers + beacons | 10/10 | 0 s / 0 s | 39 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 2619 (0) | 52 m |
| replay 30 s old | + inertial | 10/10 | 0 s / 0 s | 39 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 895 (65) | 46 m |
| replay 30 s old | full | 10/10 | 0 s / 0 s | 39 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 881 (65) | 46 m |
| fixes 15 s late | GNSS only | 10/10 | 0 s / 0 s | 19 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 28 m |
| fixes 15 s late | + peers | 10/10 | 0 s / 0 s | 19 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 28 m |
| fixes 15 s late | + peers + beacons | 10/10 | 0 s / 0 s | 19 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 28 m |
| fixes 15 s late | + inertial | 10/10 | 0 s / 0 s | 19 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 28 m |
| fixes 15 s late | full | 10/10 | 0 s / 0 s | 19 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 28 m |
| dropout 60 s | GNSS only | 10/10 | 5 s / 5 s | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| dropout 60 s | + peers | 10/10 | 5 s / 5 s | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| dropout 60 s | + peers + beacons | 10/10 | 5 s / 5 s | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| dropout 60 s | + inertial | 10/10 | 5 s / 5 s | – | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| dropout 60 s | full | 10/10 | 5 s / 5 s | – | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| jamming 60 s | GNSS only | 10/10 | 3 s / 3 s | 15 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 88 m |
| jamming 60 s | + peers | 10/10 | 3 s / 3 s | 15 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 88 m |
| jamming 60 s | + peers + beacons | 10/10 | 3 s / 3 s | 15 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 88 m |
| jamming 60 s | + inertial | 10/10 | 3 s / 3 s | 15 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 88 m |
| jamming 60 s | full | 10/10 | 3 s / 3 s | 15 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 88 m |
| jam 30 s, then 200 m offset | GNSS only | 10/10 | 0 s / 0 s | 199 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 2615 (0) | 206 m |
| jam 30 s, then 200 m offset | + peers | 10/10 | 0 s / 0 s | 199 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| jam 30 s, then 200 m offset | + peers + beacons | 10/10 | 0 s / 0 s | 199 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 0 (0) | 0 m |
| jam 30 s, then 200 m offset | + inertial | 10/10 | 0 s / 0 s | 199 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| jam 30 s, then 200 m offset | full | 10/10 | 0 s / 0 s | 199 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| common-mode jump 1 km | GNSS only | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 160 (0) | 995 m |
| common-mode jump 1 km | + peers | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 160 (0) | 995 m |
| common-mode jump 1 km | + peers + beacons | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 160 (0) | 995 m |
| common-mode jump 1 km | + inertial | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| common-mode jump 1 km | full | 10/10 | 0 s / 0 s | 991 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 0 (0) | 0 m |
| common-mode drift 0.5 m/s | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 6026 (0) | 334 m |
| common-mode drift 0.5 m/s | + peers | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 6026 (0) | 334 m |
| common-mode drift 0.5 m/s | + peers + beacons | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 6026 (0) | 334 m |
| common-mode drift 0.5 m/s | + inertial | 10/10 | 59 s / 109 s | 30 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 152 (9) | 52 m |
| common-mode drift 0.5 m/s | full | 10/10 | 59 s / 109 s | 30 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 152 (9) | 52 m |
| common-mode drift 0.5 m/s, anchor at 600 s | GNSS only | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 6026 (0) | 334 m |
| common-mode drift 0.5 m/s, anchor at 600 s | + peers | 0/10 | – / – | – | 0 / 0 / 0 / 0 of 2300 | 0 % | 6026 (0) | 334 m |
| common-mode drift 0.5 m/s, anchor at 600 s | + peers + beacons | 10/10 | 302 s / 316 s | 152 m | 0 / 0 / 0 / 0 of 2300 | 0 % | 4586 (0) | 334 m |
| common-mode drift 0.5 m/s, anchor at 600 s | + inertial | 10/10 | 59 s / 109 s | 30 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 152 (9) | 52 m |
| common-mode drift 0.5 m/s, anchor at 600 s | full | 10/10 | 59 s / 109 s | 30 m | 0 / 0 / 0 / 0 of 2300 | 100 % | 152 (9) | 52 m |

| alertLimit | Trusted share, clean walk | Trusted share, clean still | Trusted while > 30 m off: drift 0.2 m/s | drift 0.05 m/s | replay 30 s |
|---|---|---|---|---|---|
| 30 m | 8 % | 100 % | 0 s | 0 s | 0 s |
| 50 m | 35 % | 100 % | 58 s | 0 s | 65 s |
| 75 m | 68 % | 100 % | 680 s | 269 s | 327 s |
| 100 m | 100 % | 100 % | 1344 s | 553 s | 336 s |
| 150 m | 100 % | 100 % | 1344 s | 553 s | 336 s |
| 1000 m | 100 % | 100 % | 1344 s | 553 s | 336 s |
