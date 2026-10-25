# Android port: conventions

The Android app is a line-by-line Kotlin port of the iOS app in `ios/`. iPhones and Android
phones must join the **same mesh** (same GATT service, wire format version 3, same JSON) and
upload through the same HTTP contract (`WEBSITE_PLAN.md`). The Swift sources are the spec;
`app.md` explains the behavior. Do not modify `ios/` or `website/`.

## Layout

| Swift | Kotlin |
|---|---|
| `ios/MeshCore/Sources/MeshCore/X.swift` | `android/meshcore/src/main/kotlin/com/hackathonmapper/meshcore/X.kt` (pure JVM, no Android APIs) |
| `ios/MeshCore/Tests/MeshCoreTests/X.swift` | `android/meshcore/src/test/kotlin/com/hackathonmapper/meshcore/X.kt` (JUnit 4) |
| `ios/MeshMapper/X.swift` | `android/app/src/main/java/com/hackathonmapper/meshmapper/X.kt` |

One Swift file becomes one Kotlin file with the same name. Keep the Swift doc comments
(translated where they name an Apple API) so the two stay diffable.

## Names

Kotlin names equal Swift names: types, properties, functions, enum cases, parameter names.
Code in other files is written against the Swift API, so a renamed member breaks someone
else's file. Argument labels become parameter names (`ingest(_ packet:at:)` becomes
`ingest(packet: MeshPacket, now: Double = currentTime())`). Swift `init` overloads become
constructors or companion `invoke`/factory functions with the same parameter names.

## Types

- `struct` with only `let`s / plain `var`s → `data class`. A struct with `mutating` methods or
  private state → `class`, and **every place Swift relies on value copies** (`var f = filter;
  f.update(…)`, struct stored in a dictionary then mutated, passing a struct and mutating the
  original) needs an explicit `copy()`. This is the most likely porting bug; check each one.
- `enum` with a String raw value → `enum class X(val rawValue: String)` with `@SerialName`.
  Enum with associated values → `sealed class`. Namespace enum (`enum MeshProtocol { static let … }`)
  → `object`. `CaseIterable.allCases` → `entries`.
- `Date` → `Double` seconds since the Unix epoch; `TimeInterval` → `Double` (`Time.kt` has
  `currentTime()`). Monotonic sample times (`CMDeviceMotion.timestamp`) stay seconds as Double.
- `Data` → `ByteArray` (override `equals`/`hashCode` in data classes that hold one).
- `UUID` values on the wire are `String`s. Generate them **uppercase** like Swift's
  `UUID().uuidString`: `UUID.randomUUID().toString().uppercase()`. Compare epochs
  case-insensitively, as `UUID(uuidString:)` does.
- `Int` → `Int` unless the value can exceed 2³¹ (millisecond timestamps), then `Long`.
- `throws` → throw `MeshCoreError` (a `sealed class … : Exception()` with the same cases).
- `Codable` → `@Serializable` with identical JSON keys. Use the shared `MeshJson` instance in
  `Models.kt` (`ignoreUnknownKeys = true`, `explicitNulls = false`, `encodeDefaults = true`), so
  nil optionals are omitted exactly like `JSONEncoder` does.

## Math pitfalls (the signal-map golden replay is exact)

- Swift `x.rounded()` rounds half **away from zero**; Kotlin `round()` rounds half to even and
  `Math.round` rounds half up. Use `swiftRounded()` in `LinearAlgebra.kt`.
- `Int(x)` traps on NaN/∞ in Swift; Kotlin `toInt()` saturates. Keep the Swift guard.
- Swift dictionaries have no order. Where Swift sorts before iterating, sort the same way; where
  it doesn't, the result must not depend on order.
- `reduce(0, +)` over Doubles → `sumOf { }` / `fold(0.0)`.

## App classes (`ObservableObject`)

- `@Published var x` → `var x by mutableStateOf(initial)` (Compose snapshot state), with
  `private set` where Swift has `private(set)`. Collections are replaced, not mutated in place,
  so Compose sees the change. Computed properties stay computed (`val x get() = …`).
- Swift closures `var onX: ((T) -> Void)?` → `var onX: ((T) -> Unit)? = null`.
- All observable state is read and written on the **main thread**, like iOS's main queue. Hop
  Android callbacks (GATT, scan, sensors, location) to main with
  `Handler(Looper.getMainLooper())` before touching state. Background work (HTTP) runs on
  `Dispatchers.IO` and posts results back to main.
- Swift `Timer` → a coroutine loop in a class-owned `CoroutineScope(SupervisorJob() + Dispatchers.Main)`,
  cancelled on stop.
- A class needing Android services takes `context: Context` as its **first** constructor
  parameter (pass the application context), followed by the Swift init parameters.
- `UserDefaults` → `SharedPreferences` named `"meshmapper"` with the same keys.
- `MeshModel` is an `AndroidViewModel`; `MainActivity` gets it with `viewModel()`.

## Bluetooth interop (must match `BluetoothMesh.swift`)

- Service `F7A40001-5AB1-4E90-A989-21B5E52E2210`, characteristic `F7A40002-5AB1-4E90-A989-21B5E52E2210`
  (write with response + notify), CCCD `00002902-0000-1000-8000-00805f9b34fb`.
- Advertise only the 128-bit service UUID (no device name: the 31-byte legacy advertisement
  must fit), connectable, low latency, high TX power.
- As central: scan with a service-UUID filter, `connectGatt(…, TRANSPORT_LE)`, `requestMtu(515)`
  (MTU − 3 = 512, the longest ATT value; iOS sizes its chunks as MTU − 3 with no 512 cap, so a
  larger MTU would let an iPhone send values Android may refuse), discover, enable notifications
  (write the CCCD), then write chunks of at most `min(512, mtu − 3)` bytes
  with `WRITE_TYPE_DEFAULT` (with response), one at a time. Android GATT allows one outstanding
  operation per connection, so queue every GATT op. Always `close()` a disconnected `BluetoothGatt`.
- As peripheral: `BluetoothGattServer`; a CCCD write enabling notifications is the "subscribe"
  that opens an incoming link. Send one notification at a time and continue in
  `onNotificationSent` (iOS's `peripheralManagerIsReady`). Notification chunks fit the
  central's MTU − 3.
- `LinkID` keys are BLE addresses on Android (Core Bluetooth identifiers on iOS); they are
  transport handles only. Mesh identity comes from the Hello.

## Sensors (must feed MeshCore the same numbers as Core Motion)

- Core Motion reports `gravity` and `userAcceleration` in **g** with the opposite sign to
  Android (an iPhone lying face-up reports gravity `(0, 0, −1)`; Android `TYPE_GRAVITY` reports
  `(0, 0, +9.81)`). Convert: `ios = −android / 9.80665` for `TYPE_GRAVITY` and
  `TYPE_LINEAR_ACCELERATION`. `rotationRate` (`TYPE_GYROSCOPE`, rad/s) needs no conversion.
  Device axes are the same on both platforms.
- `CMAltimeter.relativeAltitude` → altitude difference from `TYPE_PRESSURE` via
  `SensorManager.getAltitude`, relative to the first reading.
- Android `Location.accuracy` is a 68 % radius like `horizontalAccuracy`, so the same ×1.62
  conversion to 95 % applies.

## Not on Android

Nearby Interaction (UWB) does not interoperate between iPhones and Android phones. The Android
app keeps the ranging frame models (they are part of wire format 3) but reports UWB as
unsupported and never runs a session; the toggle is shown disabled with that reason. Maps are
drawn with Compose `Canvas` (no Google Maps / Play Services: they need an API key and network).

There is no foreground service: like on iOS the demo assumes the app stays in the foreground.
Unlike iOS, Bluetooth and timers keep running for a while when the app is backgrounded, while
Android throttles background location (fixes go stale and the phone publishes no position).

## Build and test (Windows, Git Bash)

```bash
cd android
export JAVA_HOME=/c/Users/hansosk/.android-toolchain/jdk   # or any JDK 17
./gradlew :meshcore:test            # MeshCore unit tests, incl. the signal-map golden replay
./gradlew :app:assembleDebug        # APK in app/build/outputs/apk/debug/
./gradlew :app:testDebugUnitTest
```

`local.properties` (git-ignored) points `sdk.dir` at the Android SDK.
