# Review 1: BLE transport and wire format v4

Reviewed: `git diff 27760d0..origin/feature/map-accuracy` (87b2f6c). Note: the local checkout is `main`, not the feature branch, so line numbers below are for `origin/feature/map-accuracy`. `BluetoothMesh.swift`, `Framing.swift` and `MeshStore.swift` are unchanged by this feature. The wire change is confined to `NeighborObservation`, `MeshProtocol.version`, and `RangingToken.uwbDirection`.

## Verdict: B

The wire change is small, well-bounded and correctly reasoned. The version bump is justified, because relays decode and re-encode packets, so a v3 relay would silently strip the new fields. Validation is symmetric. The origin clamps and rounds values before `validate()` sees them, so a phone cannot produce a report that a v4 relay drops. The dashboard is unaffected because `parseNeighbors` ignores unknown keys. Size limits hold with a wide margin. The main costs are on the radio: each neighbor entry roughly doubles in size, on a transport that already uses write-with-response, one ATT write at a time. On top of that, a UWB token-retry loop can hold a session slot forever and keep sending token frames. Neither issue breaks a 3–5 phone demo. Both get worse as the mesh grows.

## Findings (by severity)

**1. MEDIUM: larger reports reduce mesh capacity (LIKELY)**
- Location: `Models.swift:56-90`, sent through `BluetoothMesh.swift:517-525`.
- Problem: one neighbor entry grows from 68 to 133 bytes of JSON. The key names alone (`uwbDistanceM`, `uwbBearingDeg`, `uwbBearingErrorDeg`) are about 50 bytes per neighbor. Measured with realistic packets:

  | Neighbors | v3 size | v4 size | Increase |
  |---|---|---|---|
  | 3 | 587 B | 782 B | +33 % |
  | 8 (with a 4-hop path) | 1087 B | 1607 B | +48 % |

  Central-to-peripheral traffic is chunked to `maximumWriteValueLength(.withoutResponse)` (typically 182 B) and sent with response, one chunk in flight. That is roughly 2 connection intervals per chunk, about 3–6 KB/s. Each link has to carry about one report per origin per second, plus the 5 s `sync()` rebroadcast (`MeshModel.swift:389`).
- Failure scenario: with 6–8 phones on UWB, the write direction of a link saturates. `LinkOutbox` coalescing keeps the queue bounded, but reports (and their UWB distances) arrive 2–5 s late or get skipped. The layout solver then fuses stale ranges, and the 1–3 s lag stated in app.md is optimistic.
- Fix, cheapest first:
  - Short `CodingKeys` for the three fields (for example `ud`/`ub`/`ue`; the dashboard ignores them anyway).
  - Omit `uwbBearingErrorDeg` when it equals the default (25°).
  - Pre-existing transport fix with the bigger payoff: write `.withoutResponse` paced by `canSendWriteWithoutResponse` / `peripheralIsReady(toSendWriteWithoutResponse:)`.

**2. MEDIUM: progress timeout is defeated by token resends (LIKELY)**
- Location: `UWBRanging.swift:155` together with `:134-136`.
- Problem: `receive(token:)` sets `progressAt = now` on every token, including an unchanged one. `reconcile` resends the token every 5 s while there is no reading.
- Failure scenario: two phones select each other, but Nearby Interaction never measures (pocket, body blocking, or the peer's session was refused by `activeSessionsLimitExceeded` before the budget shrank). Each side refreshes the other's `progressAt` every 5 s, so the 20 s `progressTimeout` never fires. The slot is held indefinitely. A better candidate never gets it, and a ~0.6 KB token frame goes each way every 5 s on that link.
- Fix: in `receive(token:)`, set `progressAt` only when `changed || isNewSession`. Better still, require a measurement within `progressTimeout` once the peer token is known.

**3. LOW: v3 and v4 phones split the mesh (CERTAIN, by design)**
- Problem: a v3 phone and a v4 phone refuse each other at the Hello. The central retries after 60 s, and that repeats forever.
- Failure scenario: a mixed TestFlight fleet (builds 6 and 7) splits into islands with no shared positions. The only sign is `lastError`.
- Fix: process, not code. Show the protocol version on the Network tab and add "all phones on build 7" to the DEMO.md checklist.
- Related: the lenient `uwbDirection` decode only helps v3 senders, and they never get past the Hello, so it is unreachable. It is harmless.

**4. LOW: `uwbDirection` is sent but never read (CERTAIN)**
- Location: `Ranging.swift:13`, `MeshModel.swift:591`.
- Problem: no receiver consumes the field. It is dead wire data.
- Fix: use it (for example, prefer direction-capable peers in `UWBSessionPolicy`) or drop it.

**5. LOW: no UWB measurement age on the wire (LIKELY)**
- Location: `MeshModel.swift:563`.
- Problem: `ageMs` is the BLE last-heard age, not the UWB reading's age. A reading up to 2 s old is sent as if fresh, and relay delay adds to that.
- Failure scenario: receivers cannot down-weight stale ranges for a walking phone.
- Fix: add an optional `uwbAgeMs`, or tighten `maxAge` to about 1 s.

**6. LOW: website contract does not document the new fields (CERTAIN)**
- Location: `website/shared/contract.ts:60-64`.
- Problem: the `NeighborObservation` type lacks the UWB fields. Compatibility relies on `validate.ts:66-96` ignoring unknown keys, which is correct today. But one invalid device rejects the whole batch, so a future strict validator would silently break every gateway upload.
- Fix: add the optional fields to the TypeScript type, with a "not validated, ignored" comment, and add a UWB-carrying device to `npm run sample`.

## Done well

- The version bump is well reasoned: re-encoding relays would otherwise strip fields silently. It is documented in `Models.swift` and app.md, and covered by `testVersion3PacketsAreRejected`.
- The origin side is defensive. `withUWB` filters non-finite and out-of-range values and clamps the error to 1–180. The init rounds values and normalizes 359.6° to 0°. `isValidUWB` enforces "bearing only with distance" and "error only with bearing", and it also checks raw decoded input that bypasses the init (tested).
- Size: `testFullNeighborListWithUWBFitsOnePacket` covers 16 UWB neighbors, an 8-entry path, 64-character frame IDs and a 40-character label, all under 4096 bytes. In practice `BluetoothMesh.maxNeighbors = 8` caps a report at about 1.6 KB. Gateway batches (≤100 devices) stay far below the 256 KiB limit.
- Ranging tokens use a separate outbox key, stay link-local, are accepted only from ready links and only from selected peers. UWB stays off the mesh's critical path: a denied permission falls back to RSSI and closes all sessions.
- UWB readings are attached only to BLE-ready neighbors, so the rule that neighbors come only from the Hello still holds.

## Verify on phones

1. Log `maximumWriteValueLength(.withoutResponse)` and `maximumUpdateValueLength` for iPhone-to-iPhone links. Is it 182 or 512+? That decides how serious finding 1 is.
2. With 6 or more phones, UWB on and then off: compare the age of reports from 2–3 hops away and the rate of `diagnostics.relayed` and `diagnostics.duplicate`.
3. The gateway upload returns 200 with UWB fields present. The JSON shows `"uwbDistanceM":3.42`, not `3.4199999999999999`.
4. A mixed v3/v4 pair shows the "mesh protocol 3 … Update all phones" error and recovers once both phones run build 7.
5. Pocket one phone of a selected pair for more than 30 s. Does the session close after about 20 s (finding 2) or stay in place?
6. Run 5 or more UWB phones to exceed `activeSessionsLimitExceeded`. Confirm the budget shrinks and the refused peers stop exchanging tokens.
