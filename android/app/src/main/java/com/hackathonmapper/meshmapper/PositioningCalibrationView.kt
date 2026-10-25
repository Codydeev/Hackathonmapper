package com.hackathonmapper.meshmapper

import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Button
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import com.hackathonmapper.meshcore.Positioning

/**
 * RSSI calibration at marked distances (ARCHITECTURE.md T2): two phones at the same height, a tape
 * measure, one minute per distance. The fit replaces the default path-loss model for that channel
 * on this phone only; it is valid for this pair of phone models and this kind of place.
 *
 * [peers]: peers currently linked, as (id, label). Its navigation title ("RSSI calibration") is set
 * by the link that opens it (`NavigationLinkRow`).
 */
@Composable
fun PositioningCalibrationView(service: PositioningService, peers: List<Pair<String, String>>) {
    var peerId by remember { mutableStateOf("") }
    var channel by remember { mutableStateOf(Positioning.RSSIChannel.connection) }
    var environment by remember { mutableStateOf("outdoors, in hand") }
    var activeDistance by remember { mutableStateOf<Double?>(null) }
    var result by remember { mutableStateOf<Positioning.CalibrationResult?>(null) }
    var error by remember { mutableStateOf<String?>(null) }

    fun label(id: String): String = peers.firstOrNull { it.first == id }?.second ?: id

    fun fit(apply: Boolean) {
        try {
            result = service.finishCalibration(apply = apply)
            error = null
        } catch (e: Positioning.CalibrationError) {
            error = "Not enough to fit: $e"
        } catch (e: Exception) {
            error = "$e"
        }
    }

    Form {
        val session = service.calibration
        if (session != null) {
            FormSection(header = "Recording ${label(session.peerId)}, ${session.channel.rawValue}") {
                for (d in calibrationDistances) {
                    FormRow(padding = PaddingValues(horizontal = 16.dp, vertical = 4.dp)) {
                        Text("${d.toInt()} m", modifier = Modifier.weight(1f))
                        Text(
                            "${samples(session, d)} samples",
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                            style = MaterialTheme.typography.bodyLarge.copy(fontFeatureSettings = "tnum"),
                        )
                        Spacer(Modifier.width(8.dp))
                        if (activeDistance == d) {
                            Button(onClick = {
                                service.calibrationStep(distance = null)
                                activeDistance = null
                            }) { Text("Stop") }
                        } else {
                            TextButton(
                                onClick = {
                                    service.calibrationStep(distance = d, label = environment)
                                    activeDistance = d
                                },
                                enabled = activeDistance == null,
                            ) { Text("Record") }
                        }
                    }
                }
                if (session.isStepComplete) {
                    FormRow { Text("Enough for this distance: stop and move on.", color = Color(0xFF34C759)) }
                }
            }
            FormSection {
                ButtonRow("Fit and use on this phone", enabled = activeDistance == null) { fit(apply = true) }
                ButtonRow("Fit only", enabled = activeDistance == null) { fit(apply = false) }
                ButtonRow("Cancel", destructive = true) {
                    service.cancelCalibration()
                    activeDistance = null
                    result = null
                }
            }
        } else {
            FormSection(header = "Peer and link") {
                PickerRow(
                    "Peer", listOf("") + peers.map { it.first }, peerId,
                    { id -> if (id.isEmpty()) "Choose" else label(id) },
                ) { peerId = it }
                PickerRow(
                    "RSSI", listOf(Positioning.RSSIChannel.connection, Positioning.RSSIChannel.advertisement), channel,
                    { if (it == Positioning.RSSIChannel.connection) "Connection" else "Advertisement" },
                ) { channel = it }
                TextFieldRow("Where and how held", environment, { environment = it })
                ButtonRow("Start calibration", enabled = peerId.isNotEmpty()) {
                    service.beginCalibration(peerId = peerId, channel = channel, peerModel = "", environment = environment)
                    result = null
                    error = null
                }
            }
            FormSection {
                FormRow {
                    FootnoteText("Same height, phones held as they will be carried, nobody between them. One minute per distance.")
                }
            }
        }
        result?.let { fitted ->
            FormSection(header = "Fit") {
                FormRow { Text(fmt("RSSI at 1 m %.1f dBm, exponent %.2f", fitted.model.p0, fitted.model.n)) }
                FormRow { Text(fmt("Spread %.1f dB fast, %.1f dB spot to spot", fitted.model.sigmaFast, fitted.model.sigmaShadow)) }
                FormRow { Text(fmt("Held-out range error %.0f %%", 100 * fitted.leaveOneOutRangeError)) }
                for (warning in fitted.warnings) {
                    FormRow { Text(warning, color = Color(0xFFFF9500)) }
                }
            }
        }
        error?.let { message ->
            FormSection { FormRow { Text(message, color = MaterialTheme.colorScheme.error) } }
        }
    }
}

/** `PositioningCalibrationView.distances`: the marked distances, m. */
private val calibrationDistances: List<Double> = listOf(2.0, 5.0, 10.0, 20.0)

private fun samples(session: Positioning.CalibrationSession, d: Double): Int =
    session.steps.filter { it.distance == d }.sumOf { it.samples.size }
