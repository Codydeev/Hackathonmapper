package com.hackathonmapper.meshmapper

import androidx.compose.foundation.layout.Column
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.outlined.Delete
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.LocalLifecycleOwner
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleEventObserver
import com.hackathonmapper.meshcore.FingerprintMatch
import com.hackathonmapper.meshcore.FingerprintMatcher
import com.hackathonmapper.meshcore.PositionEstimate
import com.hackathonmapper.meshcore.RadioFingerprint
import com.hackathonmapper.meshcore.SpotPositionSource
import kotlin.math.max

/**
 * Experimental: record what a spot sounds like over Bluetooth, and later ask which recorded spot
 * this sounds like. Nothing here feeds positioning or the GPS check, the devices heard are
 * observations only, and the recorded spots stay on this phone (docs/AMBIENT_RADIO.md).
 *
 * The Swift view's nested types and statics live in the [AmbientRadioView] object; the screen is
 * the [AmbientRadioView] composable. Its navigation title ("Ambient radio") is set by the link
 * that opens it (`NavigationLinkRow`).
 */
object AmbientRadioView {
    /** Where this phone is, when that is known well enough to record a spot. */
    data class Spot(
        val x: Double,
        val z: Double,
        val r95: Double,
        val source: SpotPositionSource,
    )

    const val recordSeconds: Double = 20.0
    const val compareSeconds: Double = 15.0

    /**
     * The phone's own position, if a spot may be recorded there: a declared spot, or its GPS when
     * the GPS check trusts it (or is off, which is recorded as unchecked). Bluetooth estimates and
     * predictions are too rough to label a spot with.
     */
    fun knownSpot(phone: GhostPhone?): Spot? {
        if (phone == null || !phone.isSelf) return null
        val selected = phone.selected ?: return null
        val position = selected.position ?: return null
        val r95 = selected.uncertainty.r95
        return when {
            selected.kind == PositionEstimate.Kind.declared ->
                Spot(position.x, position.z, r95, SpotPositionSource.declared)
            selected.kind == PositionEstimate.Kind.measured && selected.method == PositionEstimate.Method.gnss &&
                phone.integrity == null && !phone.gnssUnconfirmed ->
                Spot(position.x, position.z, r95, SpotPositionSource.gnssUnchecked)
            selected.kind == PositionEstimate.Kind.measured && selected.method == PositionEstimate.Method.gnss &&
                phone.integrity?.mayAnchorOthers == true ->
                Spot(position.x, position.z, r95, SpotPositionSource.gnss)
            else -> null
        }
    }

    internal fun describe(source: SpotPositionSource): String = when (source) {
        SpotPositionSource.declared -> "pinned spot"
        SpotPositionSource.gnss -> "checked GPS"
        SpotPositionSource.gnssUnchecked -> "GPS, not checked"
    }

    internal fun percent(value: Double): String = "${swiftRoundedInt(value * 100)} %"

    internal fun age(time: Double, now: Double): String {
        val minutes = ((now - time) / 60).toInt()
        return if (minutes < 1) "just now" else if (minutes < 120) "$minutes min ago" else "${minutes / 60} h ago"
    }
}

/**
 * [selfPhone]: this phone as GhostCore shows it.
 */
@Composable
fun AmbientRadioView(deviceId: String, frameId: String, selfPhone: () -> GhostPhone?) {
    val context = LocalContext.current
    // @StateObject: one scanner and store for as long as the screen is open.
    val scanner = remember { AmbientRadioScanner(context.applicationContext) }
    val store = remember { FingerprintStore(context.applicationContext) }
    var label by remember { mutableStateOf("") }
    var message by remember { mutableStateOf<String?>(null) }
    var match by remember { mutableStateOf<FingerprintMatch?>(null) }
    val now = rememberNow()

    // .onDisappear and scenePhase != .active: stop listening.
    val lifecycleOwner = LocalLifecycleOwner.current
    DisposableEffect(lifecycleOwner) {
        val observer = LifecycleEventObserver { _, event ->
            if (event == Lifecycle.Event.ON_PAUSE) scanner.stop()
        }
        lifecycleOwner.lifecycle.addObserver(observer)
        onDispose {
            lifecycleOwner.lifecycle.removeObserver(observer)
            scanner.stop()
        }
    }

    val listened = scanner.startedAt?.let { max(0.0, now - it) } ?: 0.0
    val spot = AmbientRadioView.knownSpot(selfPhone())
    val fingerprints = store.database.fingerprints

    fun record(spot: AmbientRadioView.Spot?) {
        if (spot == null) return
        val name = label.trim()
        val outcome = RadioFingerprint.record(
            scanner.snapshot(seconds = AmbientRadioView.recordSeconds), label = name, frameId = frameId,
            x = spot.x, z = spot.z, positionSource = spot.source, positionR95 = spot.r95, recordedBy = deviceId,
        )
        message = when (outcome) {
            is RadioFingerprint.RecordResult.success -> {
                val fingerprint = outcome.fingerprint
                store.add(fingerprint)
                label = ""
                "Recorded \"${fingerprint.label}\": ${fingerprint.emitters.count { it.emitter.isIdentity }} steady devices, ${fingerprint.unsteadyCount} left out as unsteady."
            }
            is RadioFingerprint.RecordResult.failure -> when (outcome.problem) {
                RadioFingerprint.Problem.tooShort -> "Listen for at least ${AmbientRadioView.recordSeconds.toInt()} s first."
                RadioFingerprint.Problem.tooFewSteadyDevices -> "Too few steady devices here to tell this spot apart. Nothing was recorded."
                RadioFingerprint.Problem.invalidPosition -> "This phone's position is not usable for a spot."
            }
        }
    }

    fun compare() {
        match = FingerprintMatcher().match(
            scanner.snapshot(seconds = AmbientRadioView.compareSeconds), store.database, frameId = frameId, deviceId = deviceId,
        )
    }

    Form {
        FormSection {
            FormRow {
                FootnoteText("Experimental. Listens to the Bluetooth devices around you (beacons, TVs, other people's phones) and remembers what a spot sounds like. Those devices are not GhostCore phones: they relay nothing and say nothing about where they are. Nothing here feeds positioning or the GPS check, and recorded spots stay on this phone.")
            }
        }
        FormSection(header = "Listen") {
            ToggleRow("Listen to nearby Bluetooth", scanner.startedAt != null) { on ->
                if (on) scanner.start() else scanner.stop()
            }
            LabeledContent("Devices heard", "${scanner.devicesHeard}")
            LabeledContent("Listening for", "${listened.toInt()} s")
            if (scanner.bluetoothState in listOf(BluetoothState.unauthorized, BluetoothState.poweredOff, BluetoothState.unsupported)) {
                FormRow { Text("Bluetooth is off or not allowed for this app.", color = MaterialTheme.colorScheme.error) }
            }
            FormRow { FootnoteText("Listening shares the radio with the mesh's own discovery. Switch it off before a demo.") }
        }
        FormSection(header = "Record this spot") {
            if (spot != null) {
                LabeledContent("Position", "±${swiftRoundedInt(spot.r95)} m, ${AmbientRadioView.describe(spot.source)}")
            } else {
                SecondaryRow("Record only where this phone's position is known: a pinned spot, or GPS that is not flagged.")
            }
            TextFieldRow("Name, e.g. Main door", label, { label = it })
            ButtonRow(
                "Record the last ${AmbientRadioView.recordSeconds.toInt()} s here",
                enabled = spot != null && listened >= AmbientRadioView.recordSeconds && label.trim().isNotEmpty(),
            ) { record(spot) }
            FormRow { FootnoteText("Stand still while it listens. Phones and earbuds change their Bluetooth address about every 15 minutes, so a spot is best recorded where fixed devices (beacons, TVs, printers) can be heard.") }
        }
        FormSection(header = "Which spot does this sound like?") {
            ButtonRow(
                "Compare the last ${AmbientRadioView.compareSeconds.toInt()} s",
                enabled = listened >= AmbientRadioView.compareSeconds && fingerprints.isNotEmpty(),
            ) { compare() }
            match?.let { found ->
                FormRow { Text(found.summary) }
                for (candidate in found.candidates) {
                    LabeledContent(
                        candidate.label,
                        "${AmbientRadioView.percent(candidate.posterior)}, ${candidate.commonDevices} devices in common",
                    )
                }
                LabeledContent("Somewhere not recorded", AmbientRadioView.percent(found.elsewhere))
            }
        }
        message?.let { text ->
            FormSection { FormRow { Text(text) } }
        }
        FormSection(header = "Recorded spots (${fingerprints.size})") {
            for (fingerprint in fingerprints) {
                // Swift's swipe-to-delete (.onDelete) is a delete button here.
                FormRow {
                    Column(Modifier.weight(1f)) {
                        Text(fingerprint.label)
                        Text(
                            "${fingerprint.emitters.count { it.emitter.isIdentity }} steady devices · ${AmbientRadioView.describe(fingerprint.positionSource)} · ${AmbientRadioView.age(fingerprint.recordedAt, now)}",
                            style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    IconButton(onClick = { store.remove(id = fingerprint.id) }) {
                        Icon(Icons.Outlined.Delete, contentDescription = "Delete", tint = MaterialTheme.colorScheme.error)
                    }
                }
            }
            if (fingerprints.isNotEmpty()) {
                ButtonRow("Delete all spots", destructive = true) { store.removeAll() }
            }
        }
    }
}
