> **Historical:** part of the review of the unmerged branch `feature/map-accuracy` at `87b2f6c`, not `main` (see [../REVIEW_VERDICT.md](../REVIEW_VERDICT.md) and [docs/AUDIT.md](../../../AUDIT.md)).

# Improving bearing accuracy: research notes

Baseline (app.md, MAP_DESIGN.md R4): bearings come only from UWB direction on iPhone 11–13 (U1), inside the field of view, rotated to north with CMDeviceMotion. Error = 15° ⊕ compass (10/20/35°). U2 phones (iPhone 14 and later) report no direction. An RSSI ring has no direction.

Tags: **[V]** means confirmed by a cited source, **[B]** means my belief or arithmetic that has not been checked on our phones.

## Key insight

A bearing in the map frame always has two parts: the angle in the device or walker frame, plus that frame's rotation to north. Most options below improve only the first part. The compass term (10–35°, worse indoors) dominates. So the biggest gains come from fixing the rotation **without a compass**, using geometry or surveyed mounts.

## Comparison

| # | Option | Expected bearing error | Phones | Extra hardware | Hackathon effort | Main risks |
|---|---|---|---|---|---|---|
| 1 | Cooperative geometry: all pairwise UWB ranges + ≥3 well-spread placed phones | σθ ≈ σpos/baseline: 3 m / 40 m ≈ 4°; 10 m / 20 m ≈ 27° **[B]** | all UWB phones (11+) | none | low–medium (R1–R3 already planned) | collinear or close-together GPS phones; a mirror flip with only 2 placed phones |
| 2 | Surveyed heading for mounted anchors (sight a landmark or a second known point instead of using the compass) | removes the compass term → ~15° (U1 AoA only) **[B]** | U1 anchors | none | very low | the mount gets bumped; operator error |
| 3 | Compass hygiene: calibration gating, field-magnitude check, gyro smoothing, keep away from steel | 35° → 10–20° outdoors; indoors stays unreliable **[B]** | all | none | low | indoor disturbance cannot be fully detected |
| 4 | Synthetic aperture: walking phone, UWB ranges over time + PDR/ARKit track | 3–8° in the walker frame; mirror ambiguity resolved **[B]** | all UWB phones, U2 included | none | medium | needs motion; absolute bearing still needs a compass or geometry; PDR scale/heading drift |
| 5 | NI camera assistance (`isCameraAssistanceEnabled`, `setARSession`, `horizontalAngle`) on U2 | unknown; ~10° + ARKit heading error **[B]** | U2 hand-held, foreground, camera on | none | medium | needs motion and ~10 s convergence; reports of nil direction on U2 **[V]** |
| 6 | UWB AoA accessory anchors (Qorvo QM33120W 2-antenna kit) or cheap used iPhone 11s as mounted anchors | < 5° vendor spec **[V]**; ~5–15° in the field **[B]** | all UWB iPhones range to the anchor | dev kits (~€100–300) or used U1 phones | high (kit firmware); low for used iPhones | NI accessory firmware/protocol work; FoV ±60°; LOS only |
| 7 | BLE 5.1 AoA locators (u-blox XPLR-AOA, nRF52833/nRF5340, Silicon Labs) + CTE tags clipped to phones | 5° mean (vendor) **[V]** | any, via a tag | locators + tags, and a link from locator to mesh | high | iPhones cannot send CTE themselves **[B]**; multipath indoors |
| 8 | RSSI tricks (body-shadow sweep, multi-phone RSSI gradient) | 30–90°, often ambiguous **[B]** | all | none | low | antenna anisotropy and multipath dominate **[V]** |

## Evidence per option

**Camera assistance (5).** Apple documents `isCameraAssistanceEnabled` for both peer and accessory configurations. It fuses ARKit with NI to give distance and direction "in a wider range of conditions", and it is what enables `horizontalAngle` and the vertical-direction estimate **[V]** ([peer](https://developer.apple.com/documentation/nearbyinteraction/ninearbypeerconfiguration/iscameraassistanceenabled), [NINearbyObject](https://developer.apple.com/documentation/nearbyinteraction/ninearbyobject)). Developers report that on iPhone 15 (U2) `direction` stays nil and `horizontalAngle` appears only after about 10 s and only while the phone moves **[V, forum]** ([thread 822522](https://developer.apple.com/forums/thread/822522)). Qorvo staff say that iPhone 14+ has fewer UWB antennas, so direction needs movement **[V, forum]** ([Qorvo](https://forum.qorvo.com/t/dwm3001cdk-aoa-capabilities-and-mcu-integration/24465)).

Implications:
- The app must run in the foreground with the camera on, and the user must pan.
- The session's AR frame needs `.gravityAndHeading` to be north-referenced, which brings the compass back in. A better choice is `.gravity` with a frame rotation solved from geometry (option 1).
- It does not work for mounted anchors.

**Compass (3).** `headingAccuracy` is the system's own error bound, not a measurement **[V]** ([Apple](https://developer.apple.com/documentation/corelocation/clheading/headingaccuracy)). Indoor man-made disturbance is the main error source. Fusing several pedestrians cut magnetometer heading error by 42% **[V]** ([UNSW IPIN 2013](https://cgi.cse.unsw.edu.au/~mahbub/PDF_Publications/IPIN2013_heading.pdf)). ARKit `.gravityAndHeading` still depends on the compass. Developers report misaligned and drifting heading after fast turns **[V, forum]** ([789410](https://developer.apple.com/forums/thread/789410), [739065](https://developer.apple.com/forums/thread/739065)).

Concrete gates **[B]**:
- Use `CMCalibratedMagneticField.accuracy` and `headingAccuracy` ≤ 20°.
- Check that |B| is within about ±15% of the local field (~52 µT in Finland).
- Use a gyro-propagated heading and blend the magnetometer slowly. Freeze it when |B| is anomalous.
- Show a figure-8 calibration prompt.

**Synthetic aperture (4).** Ranges at about 10 Hz with ±10–30 cm noise, collected along a 3–5 m non-straight walk, give the peer's position in the walker's own frame. This resolves the ring and mirror ambiguity, provided the path is not a straight line toward the peer **[B]**. A single UWB anchor fused with PDR corrects both PDR heading and step length, with an error reduction above 80% **[V]** ([IEEE Access 2021](https://doaj.org/article/737e875434ff4dcb8b3867fa8494c5ca)). SALOS notes that pure ranges are ambiguous without multi-antenna hardware, rotation-shadowing or multipath **[V]** ([CEUR 3248](https://ceur-ws.org/Vol-3248/paper30.pdf)).

Using an ARKit world-tracking trajectory (cm-level) instead of step-PDR is far better if the camera is acceptable **[B]**. This is essentially what Apple's camera assistance does internally. To turn the walker frame into north, use geometry: walk past two placed phones and the frame rotation follows. The compass is the fallback.

**Geometry (1).** UWB ranges fix the shape of a connected group only up to translation, rotation and reflection. Two placed phones fix rotation but leave a mirror. Three non-collinear placed phones fix everything **[B, standard multilateration]**. The rotation error is about σpos·√2 / baseline **[B]**. Practical steps:
- Spread GPS phones ≥ 30–50 m apart outdoors, in a triangle.
- Average a stationary phone's GPS for 60 s.
- Mark one or two surveyed points (tape-measured from a corner) as zero-error anchors.

This needs no new hardware and also benefits U2 phones.

**BLE direction finding (7).** CTE needs an antenna array on one side, and it was expected that phones would use AoD. No iOS or Android API was announced as of 2021 **[V]** ([Abalta](https://abaltatech.com/2021/01/microlocation3/)). I found no CoreBluetooth CTE API in 2026 **[B]**. Neither AoA from an iPhone nor AoD into an iPhone works, so this needs a tag per phone plus fixed locators. The XPLR-AOA-1 (nRF52833-based) claims a 5° mean error at 40 Hz **[V]** ([u-blox](https://content.u-blox.com/sites/default/files/XPLR-AOA-1_ProductSummary_UBX-21015378.pdf)).

**UWB AoA anchors (6).** The DWM3001CDK has one antenna, so no AoA. The QM33120W (2 ports) is specified at < 5° AoA **[V]** ([Qorvo QM33120W](https://www.qorvo.com/products/p/QM33120W), [forum](https://forum.qorvo.com/t/dwm3001cdk-aoa-capabilities-and-mcu-integration/24465)). With a surveyed mount there is no compass error. The anchor measures the phone, so this works for U2 phones too **[B]**.

The cheap equivalent is several used iPhone 11–13s as mounted direction anchors with surveyed heading. The existing app design already supports this.

**RSSI (8).** At 2.4 GHz, body shadowing is large, and a rotating phone sees up to 8 dB of channel-dependent swing from orientation alone **[V]** ([IITiS](https://iitis.pl/en/node/3300), [PMC8398681](https://www.ncbi.nlm.nih.gov/pmc/articles/PMC8398681/)). No measured degree-level accuracy was found. Expect at best a front/back (180°) disambiguation hint **[B]**.

## Ranked recommendation

**Quick wins (hours, software only)**
1. **Fix rotation from geometry, not the compass.** Feed every pairwise UWB range into the solver (R1–R3). Require ≥ 3 non-collinear placed phones before calling a group "world". Report σθ from the actual baselines. Add a "survey point" placement (tape-measured, σ 0.2 m). This is the largest gain, and it covers U2 phones.
2. **Survey the heading of mounted U1 anchors** by sighting a known landmark or point. Do not use their compass. Use several anchors facing different ways (already in app.md).
3. **Compass gating and calibration UX.** Use the gates above, drop bearings when σ > 25°, and keep phones more than 1 m from laptops and steel.

**Medium (a day, still no hardware)**
4. **Synthetic aperture walk mode.** On a "find direction" button, the user walks a short L-shaped path. Fuse ARKit (or PDR) displacement with UWB ranges, and emit a bearing plus a mirror resolution. This works on U2 phones.
5. **NI camera assistance on U2 hand-held phones.** Share the app's `ARSession` via `setARSession`, use `.gravity` alignment, and treat `horizontalAngle` as walker-frame data for step 4. Expect intermittent output. Test early on a real iPhone 15.

**Hardware (only if budget and time allow)**
6. **Mounted UWB AoA anchors.** Used iPhone 11s (easy) or Qorvo QM33120W kits (firmware work) with surveyed orientation give the best absolute bearing, about 5–15°.
7. **BLE AoA locators plus per-phone tags.** These are accurate but outside the phone-only mesh concept. Treat them as a stretch goal.
8. **Skip RSSI direction tricks** except as a front/back hint.
