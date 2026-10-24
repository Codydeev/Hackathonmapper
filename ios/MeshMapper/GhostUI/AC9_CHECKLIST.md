# AC-9 honest-UI checklist (map screen)

Tick each box on phone A's screen during a build 11 run of the ARCHITECTURE.md §1 story. Before starting, turn on Settings → Position → **GPS check** on all three phones and restart the mesh (Settings → Network → Stop/Start). A box passes only if what you see matches the text. Note the phone, the time and a screenshot for every failure.

Colours: green = GPS trusted · white = GPS not checked · amber = GPS doubted or unconfirmed · red = rejected · sky blue = estimate · grey and dashed = predicted · violet = typed spot.

## 0. Every position has a kind label
- [ ] Every phone on the map has a label pill with its name **and** a kind. The kinds are: GPS trusted / GPS not checked / GPS unconfirmed / GPS degraded / GPS suspect / Bluetooth ±N m / Dead reckoning ±N m / Fused estimate ±N m / Predicted · N s / Typed spot.
- [ ] No phone shows a dot without a label.
- [ ] The status card headline matches this phone's label pill.
- [ ] Tapping any phone opens the explainer. Its "Kind" and "Method" agree with the pill.

## 1. A: trusted GPS (A outdoors, held still)
- [ ] A's dot is **green** only when the card says **GPS TRUSTED**. Every other GPS state is white or amber, never green.
- [ ] The evidence strip under the headline shows one segment per check, and a red segment's name matches a failed check in the explainer.
- [ ] With GPS check **off**, A reads "GPS not checked" in white, and the legend says "GPS not checked", not "GPS trusted".

## 2. B: GPS outage, placed over Bluetooth
- [ ] On B: Simulate → **Outage**. On A's screen, B turns sky blue with the label **"Bluetooth ±N m"** and a 95 % circle around it.
- [ ] B carries a **SIM** badge on A's screen, because B's input is simulated.
- [ ] If B's estimate is ambiguous, A shows **hollow "?" rings at two or more spots** and the label says "one of N spots". There is no filled dot.
- [ ] A dashed white link line joins B to each phone it hears. Stronger links are brighter.
- [ ] If B is placed by motion only, the label says **"Dead reckoning"**, not "Bluetooth".

## 3. C: GPS jump, rejected
- [ ] On C: Simulate → **Jump 400 m**. Within about 3 s, A shows C with a red **"GPS ✕"** chip.
- [ ] A **red ✕** labelled "<C's name> raw GPS" / "rejected" appears about 400 m east, with a dashed red line back to C's shown position.
- [ ] Tapping C on A: the header says **"GPS rejected"**, and "Position from:" names what places C now.
- [ ] The explainer's reasons state what was measured against a limit, e.g. "GPS jumped 4xx m in one step (limit … m)".
- [ ] C no longer anchors B. B's circle may grow, but it is never re-placed from C's rejected fix.
- [ ] On C's own screen: the RAW GPS | GHOSTCORE card shows **REJECTED**, the distance and direction, and **SIM** on the raw side.
- [ ] Nowhere does any screen claim an attack was detected or name an attacker. The engine's own summary may say "not proof of an attack". AC-9 also greps the UI source for the banned word.

## 4. B out of range: predicted, never live
- [ ] B walks away, or on A: Simulate → Peers → B **off**. Within about 10 s, B's marker becomes **hollow, dashed and grey** with **"Predicted · N s"**.
- [ ] The N in "Predicted · N s" counts up every second.
- [ ] B's prediction circle and cloud grow with time.
- [ ] If route guesses appear, they are **dashed grey** lines with **hollow % tags**, and a card headed **PREDICTED** says "B out of reach N s · probably …".
- [ ] Nothing about B looks like a live fix: no solid fill and no green.

## 5. B back, C restored
- [ ] B comes back, or the link is switched on again. Within about 2 s, B's prediction is gone and B is sky blue again.
- [ ] On C: **Restore GPS**. C goes through **unconfirmed** (amber) before **trusted** (green). It never jumps straight to trusted.
- [ ] Simulate → **Stop**: the amber SIMULATED banner disappears on that phone, and its SIM badges go after the next report.

## 6. SIMULATED is always visible
- [ ] While any fault or forced link is active on a phone, that phone shows the **amber striped banner** "SIMULATED INPUT".
- [ ] Every record derived from a simulated input carries a **SIM/SIMULATED** badge. Check the pill, the status card, the compare card and the explainer header.
- [ ] Peer toggles in Simulate → Peers match reality: a link switched off stays shown off until switched on or Stop.

## 7. Readable from 2 m
- [ ] Hold A at arm's length from a second person, about 2 m. They can read the headline, the kind of each phone and the age of the predicted phone.
- [ ] Phones a few metres apart do not stack their labels. Peers' labels sit above their dot, and "You" sits below.

## Known limits (do not count as failures)
- With GPS check on, a still phone indoors may stay **GPS unconfirmed**: nothing independent confirms it. That is honest.
- iOS stops Bluetooth relaying when a phone is locked, so keep all three unlocked and in the foreground.
