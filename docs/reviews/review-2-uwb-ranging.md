# Review 2: UWB ranging over the BLE mesh

Reviewed `origin/feature/map-accuracy` @ 87b2f6c. Note: the local checkout is `main` (7908db0), not the feature branch, so `27760d0..HEAD` does not contain this work. I read the files with `git show` and did not change the checkout.

## Verdict: B−

The handshake itself is sound. Crossed tokens converge, lost tokens are resent, a peer restart is caught by comparing tokens, stale readings are cleared on timeout and on suspension, and a reading is published only while it is at most 2 s old. I found no deadlock, no unbounded resend and no case of a timed-out session's distance being published as fresh. The weak part is the selection policy, which is a session-level design problem. "Both ends usually choose each other" does not hold once a phone has more neighbors than its budget, because top-k is not a mutual relation. The policy also cannot tell a peer that will never answer (no UWB, ranging off, permission denied) from a slow one, and the hold works only as a minimum hold, with no hysteresis. With 5 or fewer phones, and the budget at 4, none of this is triggered. With denser groups, or with mixed iPhone models, expect periodic session churn.

## Findings (by severity)

**1. MEDIUM: peers that never answer get a slot again every 80 s and can displace working sessions.** `UWBRanging.swift:126-129`, `MeshModel.swift:536-557`.
- Problem: `rangingCandidates` does not filter for UWB capability, although MAP_DESIGN says candidates are "UWB-capable". A neighbor whose `uwb.isActive` is false never answers, because `receiveRanging` returns before `peerAnswered` (`MeshModel.swift:605`). That covers an iPhone SE or XR, UWB ranging switched off, and Nearby Interaction permission denied.
- Failure: that neighbor holds a slot for 20 s and is then cooled down for 60 s. When the cooldown ends it ranks by RSSI again, and it outranks any held session that has been measuring for more than 20 s. A working session is torn down every ~80 s.
- Fix: put a "UWB available" flag in the link Hello, or have the peer reply with a decline frame. Add an exponential backoff to `silentCooldown`.
- Confidence: LIKELY (CERTAIN in the code, LIKELY on mixed hardware).

**2. MEDIUM: selection is not mutual, so one-sided sessions churn in dense clusters.** `UWBSessionPolicy.swift:40-60`, `MeshModel.swift:610`.
- Problem: each end takes its top `budget` from its own neighbor set. A's top 4 can include B while B's top 4 excludes A. B then silently ignores A's token. A waits 20 s, cools down for 60 s and tries again, and while doing so it may displace a session that was measuring.
- Failure: 6 or more phones in one room, or any phone whose budget has shrunk. The average-RSSI symmetry does not help, because the two ends rank different candidate sets.
- Fix: accept an unselected token when a slot is free (`peers.count < sessionBudget`). Or let the lower ID propose and the peer accept or decline explicitly. Add hysteresis, for example letting a measuring session keep its slot unless a newcomer is more than 6 dB stronger.
- Confidence: LIKELY.

**3. MEDIUM: the progress timeout never fires for a pair that swapped tokens but never measures.** `UWBRanging.swift:134-136, 155`.
- Problem: while there is no reading, both ends resend their token every 5 s. `receive` sets `progressAt = now` on every token, even when the token has not changed.
- Failure: the peer is in BLE range but out of UWB range, or blocked by a wall (NLOS). Both slots stay occupied for as long as the BLE link lives, and `silentCooldown` never hands the slot to the next candidate. This contradicts the comment at :29 ("no measurement for this long is closed").
- Fix: refresh `progressAt` only when the token changed or a distance was measured. Alternatively, keep a separate `measuredAt` deadline, for example 20 s after the swap.
- Confidence: CERTAIN about the code. The impact is LIKELY outdoors.

**4. LOW-MEDIUM: the budget only ever shrinks.** `UWBRanging.swift:262-264`.
- Problem: `stop()` does not reset `sessionBudget`, and nothing raises it again. Apple says the concurrent-session limit is dynamic and depends on system resources ([Apple forum](https://developer.apple.com/forums/thread/652180), [NIError](https://developer.apple.com/documentation/nearbyinteraction/nierror/code.md)).
- Failure: churn from findings 1 and 2 calls `remove()`, which invalidates a session and opens another one right away. If iOS has not yet freed the old slot, the refusal permanently lowers the budget by 1. Over a long demo the budget can fall to 1.
- Fix: raise the budget by 1 after N minutes without a refusal, and reset it in `stop()`.
- Confidence: UNSURE that teardown is asynchronous. The ratchet itself is CERTAIN.

**5. LOW: permission denial sticks until the app restarts.** `UWBRanging.swift:52, 259`.
- Problem: `start()` and `stop()` never clear `permissionDenied`, so after the user allows Nearby Interaction in Settings, toggling ranging does nothing. The message says to allow it in Settings, but it does not say to relaunch.
- Fix: clear the flag on `stop()`, or when the app becomes active.
- Confidence: CERTAIN.

**6. LOW: `RangingToken.uwbDirection` is sent but never read.** `MeshModel.swift:591`. There is no consumer for it, which is harmless dead protocol surface. Either use it (for example to weight bearings) or note that it is reserved. Confidence: CERTAIN.

**7. LOW: the token change check compares archived bytes.** `UWBRanging.swift:153`. If `NSKeyedArchiver` output for the same token is not byte-stable, every resend counts as "changed". That re-runs the session and sends a reply, which ping-pongs once per BLE round trip. The outbox coalesces it, so the rate stays bounded. Fix: compare the unarchived `NIDiscoveryToken` objects with `isEqual`. Confidence: UNSURE (probably byte-stable).

**8. LOW: a phone gets a high anchor rank even when it sends no fixes.** `MeshModel.swift:590`. `isAnchor` is set from the role and the hardware, not from `uwbEnabled`. An anchor phone with fixes switched off still takes rank class 0 on every target. Confidence: CERTAIN, minor.

## Done well

- The token exchange does not deadlock. Crossed tokens converge after one duplicate. A `peerAnswered` call clears the silence, so a peer that comes back recovers within about 5 s instead of 60 s.
- The `didRemove` and suspension handling follows Apple's sample: run the same configuration again after `.timeout`, wait for a new token after `.peerEnded`, and run again when the suspension ends. Readings are cleared on removal, on suspension and on invalidation.
- Callbacks from an old session are matched by object identity (`===`), so a replaced session cannot leak distances into the new one.
- `withUWB` takes only readings at most 2 s old, finite and within the contract limit. A held bearing keeps its original timestamp and expires after 1 s.
- The `"rangingToken"` outbox key coalesces token resends per link, so the queue cannot grow without bound.
- The policy is a pure function with sound tests covering class ordering, ties, the hold and budget shrinking.

## Verify on phones

1. Six or more UWB phones in one room. Watch the per-link "measuring" time and the session count over 5 minutes, looking for teardowns every ~80 s.
2. Add an iPhone SE, or one phone with ranging off. Check whether the other phones' working sessions drop periodically.
3. Move two phones about 20 m apart outdoors, or through a wall, keeping BLE connected. Check whether their slots are ever released.
4. Deny Nearby Interaction, then allow it in Settings without relaunching the app.
5. Force churn and watch `uwbSessionBudget`. If it ever drops, log the active count at the moment iOS refused.
6. Lock the screen for 30 s and unlock. Check how fast distances come back on every link.
