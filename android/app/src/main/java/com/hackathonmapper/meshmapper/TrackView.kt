package com.hackathonmapper.meshmapper

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.background
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableDoubleStateOf
import androidx.compose.runtime.saveable.rememberSaveable
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextMeasurer
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.drawText
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.rememberTextMeasurer
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.DistanceMethod
import com.hackathonmapper.meshcore.DistanceTrial
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.SignalRanges
import com.hackathonmapper.meshcore.RadioModel
import com.hackathonmapper.meshcore.SignalFrame
import com.hackathonmapper.meshcore.SignalNode
import kotlin.math.atan2
import kotlin.math.ceil
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.min

/**
 * Where the other phones are, worked out on this phone from Bluetooth alone: no Wi-Fi, laptop or
 * map tiles. The signal map lays phones out so that their distances are the measured Bluetooth
 * ranges; phones with GPS (or a typed spot) anchor it in the world when there are enough of them.
 */
@Composable
fun TrackView(model: MeshModel) {
    val tracker = model.tracker
    val bluetooth = model.bluetooth
    val distanceLab = model.distanceLab
    val now = rememberNow()
    Form {
        FormSection(
            header = "Signal map",
            footer = "Laid out from measured ranges: lines are links, labelled with the measured distance, and the map keeps those distances. Dashed rings: only the distance is known, not the direction. \"Ranges from\" picks which distances this tab uses, to compare them; the dashboard always uses UWB where a pair measured it and Bluetooth otherwise, and so does the main map unless Features → Ranges says otherwise.",
        ) {
            // Picker("Ranges from", …).pickerStyle(.segmented): the segments only, as on iOS.
            SegmentedPickerRow(SignalRanges.entries, tracker.rangeSource, { it.title }) { tracker.rangeSource = it }
            val me = tracker.me?.signal
            if (me != null && me.placed) {
                SignalRadarView(tracker.phones, tracker.links, me, Modifier.fillMaxWidth().height(320.dp))
                FormRow { FootnoteText(frameText(me)) }
            } else {
                SecondaryRow("No Bluetooth links yet. The signal map appears as soon as this phone hears another mapping phone.")
            }
            FormRow { Text(selfText(tracker), style = MaterialTheme.typography.bodyMedium) }
        }

        FormSection(header = "Phones") {
            val others = tracker.phones.filter { !it.isSelf }
            if (others.isEmpty()) SecondaryRow("No other phones heard yet")
            for (phone in others) {
                TrackRow(phone, relation(model, phone), now)
            }
        }

        FormSection(
            header = "Bluetooth distance (no GPS needed)",
            footer = "Straight from signal strength, so distance only, no direction, and rough beyond a few meters: bodies, walls and pockets weaken the signal. ${radioText(tracker.radio)}",
        ) {
            if (bluetooth.neighbors.isEmpty()) SecondaryRow("No linked phones")
            for (neighbor in bluetooth.neighbors) {
                LabeledContent(neighbor.label ?: shortID(neighbor.deviceId), directDistance(model, neighbor))
            }
        }

        DistanceLabSections(distanceLab, bluetooth.neighbors)

        FormSection(
            header = "Demo",
            footer = "This phone stops sharing its GPS; every other phone then places it from Bluetooth.",
        ) {
            ToggleRow("Simulate losing GPS", model.simulateGPSLoss, enabled = model.positionChoice != PositionChoice.manual) {
                model.simulateGPSLoss = it
            }
        }
    }
}

private fun frameText(me: SignalNode): String = when (me.frame) {
    SignalFrame.world -> "North is up: placed phones anchor this map in the world."
    SignalFrame.pinned -> "One placed phone: distances are real, but the map may be turned or mirrored."
    SignalFrame.relative -> "No placed phone: distances are real, but the map may be turned or mirrored."
}

private fun radioText(radio: RadioModel): String {
    val calibrated = radio != RadioModel.standard
    return fmt(
        "Radio model: %.0f dBm at 1 m, exponent %.2f%s.", radio.p0, radio.n,
        if (calibrated) ", calibrated from placed phones" else "",
    )
}

private fun selfText(tracker: BluetoothTracker): String {
    val me = tracker.me ?: return "This phone: starting…"
    val state = me.state
    return when {
        state is TrackedPhone.State.placed && state.source == PositionSource.gps -> "This phone: GPS ±${meters(me.radius ?: 0.0)}"
        state is TrackedPhone.State.placed && state.source == PositionSource.uwb -> "This phone: UWB ±${meters(me.radius ?: 0.0)}"
        state is TrackedPhone.State.placed && state.source == PositionSource.fused ->
            "This phone: motion + anchors ±${meters(me.radius ?: 0.0)}"
        state is TrackedPhone.State.placed -> "This phone: fixed spot"
        state == TrackedPhone.State.estimated && me.ambiguous -> "This phone: placed from Bluetooth, direction from the others unknown"
        state == TrackedPhone.State.estimated -> "This phone: placed from Bluetooth ±${meters(me.radius ?: 0.0)}"
        state == TrackedPhone.State.lastSeen -> "This phone: no fix right now, last spot ${meters(me.radius ?: 0.0)} wide"
        else -> "This phone: not linked to a placed phone yet"
    }
}

/**
 * The measured range when the phones hear each other; otherwise the distance across the signal
 * map; a compass direction only when the map is anchored and both spots are known.
 */
private fun relation(model: MeshModel, phone: TrackedPhone): String? {
    val tracker = model.tracker
    tracker.link(model.deviceID, phone.id)?.let { link ->
        return if (link.uwb == null) "${meters(link.measured)} · Bluetooth" else "${fmt("%.2f m", link.measured)} · UWB"
    }
    val mine = tracker.me?.signal
    val theirs = phone.signal
    if (mine == null || theirs == null || !mine.placed || !theirs.placed || mine.component != theirs.component) {
        // Not connected through the mesh: only the world positions relate them.
        val from = tracker.me?.point ?: return null
        val to = phone.point ?: return null
        val spread = (tracker.me?.radius ?: 0.0) + (phone.radius ?: 0.0)
        return "~${meters(hypot(to.x - from.x, to.z - from.z))} on map, ±${meters(spread)}"
    }
    val dx = theirs.x - mine.x
    val dz = theirs.z - mine.z
    val distance = "~${meters(hypot(dx, dz))} via mesh"
    if (mine.frame != SignalFrame.world || phone.ambiguous || tracker.me?.ambiguous != false) return distance
    val bearing = (atan2(dx, dz) * 180 / Math.PI + 360).rem(360.0)
    val compass = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")[((bearing + 22.5) / 45).toInt() % 8]
    return "$distance $compass"
}

private fun directDistance(model: MeshModel, neighbor: MeshNeighbor): String {
    val rssi = (neighbor.connectionRSSI ?: neighbor.advertisementRSSI)?.smoothed ?: return "no signal reading yet"
    val radio = model.tracker.radio
    val near = radio.distance(rssi + radio.sigma)
    val far = radio.distance(rssi - radio.sigma)
    val link = model.tracker.link(model.deviceID, neighbor.deviceId)
    val onMap = link?.let { " · map ${meters(it.layout)}" } ?: ""
    link?.uwb?.let { uwb ->
        return "${fmt("%.2f m", uwb)} UWB · ${swiftRoundedInt(rssi)} dBm$onMap"
    }
    return "≈ ${meters(radio.distance(rssi))} (${meters(near)}–${meters(far)}) · ${swiftRoundedInt(rssi)} dBm$onMap"
}

/**
 * Every distance method's reading of the link to one linked neighbor, side by side, and a
 * tape-measure trial that scores them (`DistanceLabModel`).
 */
@Composable
fun DistanceLabSections(lab: DistanceLabModel, neighbors: List<MeshNeighbor>) {
    val context = LocalContext.current
    var trueDistance by rememberSaveable { mutableDoubleStateOf(3.0) }

    fun name(id: String): String = neighbors.firstOrNull { it.deviceId == id }?.label ?: shortID(id)

    FormSection(header = "Distance methods", footer = methodsFooter(lab)) {
        if (neighbors.isEmpty()) {
            SecondaryRow("No linked phones")
        } else {
            PickerRow(
                "Neighbor", neighbors.map { it.deviceId }, lab.peerId ?: "", { name(it) },
                enabled = lab.trial == null,
            ) { lab.peerId = it }
            for (method in DistanceMethod.entries) {
                LabeledContent(method.title, valueText(lab, method))
            }
        }
    }

    FormSection(
        header = "Tape-measure trial",
        footer = "Hold this phone and the chosen neighbor at a measured distance, start, keep still for 30 s or more, stop. Per method: bias (+ reads long), mean error, and how often its 95 % range held the true distance.",
    ) {
        NumberRow(
            "True distance (m)", trueDistance, { trueDistance = it },
            enabled = lab.trial == null, placeholder = "m", maxFractionDigits = 2,
        )
        val trial = lab.trial
        if (trial != null) {
            ButtonRow("Stop trial (${trial.samples.size} s recorded)") { lab.stopTrial() }
            TrialScores(trial)
        } else {
            ButtonRow("Start trial", enabled = lab.peerId != null && trueDistance > 0) {
                lab.startTrial(trueDistance = trueDistance, peerLabel = name(lab.peerId ?: ""))
            }
            val finished = lab.finished
            if (finished != null) {
                FormRow {
                    Text(
                        "Last trial: ${name(finished.peerId)} at ${fmt("%.2f m", finished.trueDistance)}, ${finished.samples.size} s",
                        style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                TrialScores(finished)
                // ShareLink(item: finished.csv()): the system share sheet with the CSV text.
                FormRow(modifier = Modifier.clickable { shareText(context, finished.csv(), "Distance trial (CSV)") }) {
                    Icon(Icons.Filled.Share, contentDescription = null, tint = MaterialTheme.colorScheme.primary, modifier = Modifier.size(20.dp))
                    Spacer(Modifier.width(10.dp))
                    Text("Share readings (CSV)", color = MaterialTheme.colorScheme.primary)
                }
            }
        }
    }
}

@Composable
private fun TrialScores(trial: DistanceTrial) {
    val scores = trial.scores
    if (scores.isEmpty()) SecondaryRow("No readings yet")
    for (score in scores) {
        LabeledContent(score.method.title, scoreText(score))
    }
}

private fun valueText(lab: DistanceLabModel, method: DistanceMethod): String {
    val reading = lab.readings.firstOrNull { it.method == method } ?: return "—"
    val precise = method == DistanceMethod.uwb || method == DistanceMethod.signalMap
    val value = if (precise) fmt("%.2f m", reading.meters) else meters(reading.meters)
    val low = reading.low ?: return value
    val high = reading.high ?: return value
    return "$value (${meters(low)}–${meters(high)})"
}

private fun scoreText(score: DistanceTrial.Score): String {
    val coverage = score.coverage?.let { fmt(" · in range %.0f %%", it * 100) } ?: ""
    return fmt("%+.2f m bias · %.2f m error", score.bias, score.meanAbsoluteError) + coverage
}

private fun methodsFooter(lab: DistanceLabModel): String {
    val radio = lab.calibratedRadio
    return "UWB: Nearby Interaction (both phones iPhone 11 or newer, not SE). Signal map: what the map draws, every link and position solved together. " +
        fmt("RSSI calibrated: both ends' signal through the model fitted from UWB and placed phones (%.0f dBm at 1 m, n %.2f). ", radio.p0, radio.n) +
        "RSSI default: this phone's signal, -59 dBm at 1 m, n 2.5. Median filter: GhostCore's 4 s median of raw readings, outliers removed. GPS: both phones' GPS, outdoors. Ranges in brackets hold 95 %."
}

fun meters(value: Double): String {
    if (value >= 1000) return fmt("%.1f km", value / 1000)
    // Short Bluetooth ranges are good to about a meter; show one decimal below 10 m.
    if (value < 10) return fmt("%.1f m", value)
    return "${swiftRoundedInt(value)} m"
}

@Composable
fun TrackRow(phone: TrackedPhone, relation: String?, now: Double) {
    FormRow {
        Spacer(Modifier.size(10.dp).background(TrackStyle.color(phone.state), CircleShape))
        Spacer(Modifier.width(10.dp))
        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Text(phone.label, style = headline)
            Text(trackDetail(phone, now), style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        if (relation != null) {
            Text(
                relation,
                style = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum"),
                textAlign = TextAlign.End,
                modifier = Modifier.padding(start = 8.dp),
            )
        }
    }
}

private fun trackDetail(phone: TrackedPhone, now: Double): String {
    val moved = if (phone.reported != null) " · moved to fit its Bluetooth links" else ""
    val state = phone.state
    return when (state) {
        is TrackedPhone.State.placed -> when (state.source) {
            PositionSource.gps -> "GPS ±${meters(phone.radius ?: 0.0)}$moved"
            PositionSource.uwb -> "UWB ±${meters(phone.radius ?: 0.0)}$moved"
            PositionSource.fused -> "Motion + anchors ±${meters(phone.radius ?: 0.0)}$moved"
            else -> "Fixed spot$moved"
        }
        TrackedPhone.State.estimated -> {
            val hops = phone.hops?.let { " · $it hop${if (it == 1) "" else "s"}" } ?: ""
            val ring = phone.ring
            if (ring != null) "Bluetooth: ${meters(ring.radius)} from a placed phone, direction unknown$hops"
            else "Bluetooth ±${meters(phone.radius ?: 0.0)}$hops"
        }
        TrackedPhone.State.lastSeen ->
            "Out of reach ${ageText(phone.since, now)} · within ${meters(phone.radius ?: 0.0)} of last spot"
        TrackedPhone.State.unplaced ->
            if (phone.signal?.placed == true) "On the signal map only: no placed phone in its group" else "No links yet"
    }
}

object TrackStyle {
    val green = Color(0xFF34C759)
    val orange = Color(0xFFFF9500)
    val gray = Color(0xFF8E8E93)
    val blue = Color(0xFF007AFF)

    fun color(state: TrackedPhone.State): Color = when (state) {
        is TrackedPhone.State.placed -> green
        TrackedPhone.State.estimated -> orange
        TrackedPhone.State.lastSeen, TrackedPhone.State.unplaced -> gray
    }
}

/**
 * The signal map around this phone: every phone in its connected group at its layout position,
 * so distances on screen are the measured Bluetooth ranges. North is up only in a world-anchored
 * map; otherwise the orientation is arbitrary (but stable from second to second).
 */
@Composable
fun SignalRadarView(phones: List<TrackedPhone>, links: List<TrackedLink>, me: SignalNode, modifier: Modifier = Modifier) {
    val measurer = rememberTextMeasurer()
    val secondary = MaterialTheme.colorScheme.onSurfaceVariant
    val primary = MaterialTheme.colorScheme.onSurface
    val caption2 = TextStyle(fontSize = 11.sp, color = secondary)
    Canvas(modifier.clipToBounds()) {
        val group = phones.filter { it.signal?.placed == true && it.signal.component == me.component }
        val layout = group.associate { it.id to FloorPoint(it.signal!!.x, it.signal.z) }
        val extent = layout.values.fold(3.0) { acc, p -> max(acc, hypot(p.x - me.x, p.z - me.z) + 1) }
        val step = listOf(0.5, 1.0, 2.0, 5.0, 10.0, 20.0, 50.0, 100.0, 200.0, 500.0).firstOrNull { extent / it <= 4 } ?: 1000.0
        val rings = max(1, ceil(extent / step).toInt())
        val scale = (min(size.width, size.height) / 2 - 20.dp.toPx()) / (rings * step)
        val mid = Offset(size.width / 2, size.height / 2)
        fun screen(p: FloorPoint) = Offset((mid.x + (p.x - me.x) * scale).toFloat(), (mid.y - (p.z - me.z) * scale).toFloat())

        for (i in 1..rings) {
            val r = (i * step * scale).toFloat()
            drawCircle(secondary.copy(alpha = 0.2f), r, mid, style = Stroke(1.dp.toPx()))
            drawLabel(
                measurer, meters(i * step), caption2,
                Offset(mid.x + r * 0.71f + 2.dp.toPx(), mid.y - r * 0.71f - 7.dp.toPx()), leading = true,
            )
        }
        if (me.frame == SignalFrame.world) {
            drawLabel(measurer, "N", TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Bold, color = secondary), Offset(mid.x, 10.dp.toPx()))
        }

        for (link in links) {
            val a = layout[link.a] ?: continue
            val b = layout[link.b] ?: continue
            drawLine(secondary.copy(alpha = 0.5f), screen(a), screen(b), strokeWidth = 1.dp.toPx())
            val middle = screen(FloorPoint((a.x + b.x) / 2, (a.z + b.z) / 2))
            drawLabel(
                measurer, meters(link.measured), caption2.copy(fontFeatureSettings = "tnum"),
                Offset(middle.x, middle.y - 7.dp.toPx()),
            )
        }

        for (phone in group) {
            val signal = phone.signal ?: continue
            val p = layout[phone.id] ?: continue
            val color = if (phone.isSelf) TrackStyle.blue else TrackStyle.color(phone.state)
            val center = signal.ringCenter?.let { layout[it] }
            val radius = signal.ringRadius
            if (center != null && radius != null) {
                // Distance known, direction not: the phone is somewhere on this ring.
                drawCircle(
                    color.copy(alpha = 0.6f), (radius * scale).toFloat(), screen(center),
                    style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))),
                )
                drawCircle(color, 5.dp.toPx(), screen(p), style = Stroke(1.5.dp.toPx()))
            } else {
                drawCircle(color, (if (phone.isSelf) 6 else 5).dp.toPx(), screen(p))
            }
            drawLabel(
                measurer, if (phone.isSelf) "You" else phone.label,
                TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold, color = primary),
                Offset(screen(p).x, screen(p).y - 13.dp.toPx()),
            )
        }
    }
}

/** Draws text centered on `at` (SwiftUI `context.draw(Text, at:)`), or starting at it with `leading`. */
internal fun DrawScope.drawLabel(measurer: TextMeasurer, text: String, style: TextStyle, at: Offset, leading: Boolean = false) {
    val layout = measurer.measure(text, style, maxLines = 1)
    val x = if (leading) at.x else at.x - layout.size.width / 2f
    drawText(layout, topLeft = Offset(x, at.y - layout.size.height / 2f))
}
