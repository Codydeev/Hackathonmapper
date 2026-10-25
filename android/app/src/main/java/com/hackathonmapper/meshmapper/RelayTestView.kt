package com.hackathonmapper.meshmapper

import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.hackathonmapper.meshcore.BeaconStats
import com.hackathonmapper.meshcore.RSSIStatistics
import com.hackathonmapper.meshcore.RelayEnvelope
import com.hackathonmapper.meshcore.RelayReceiptInfo

/**
 * Test console for the Bluetooth relay: send messages, see routes, ages and receipts, exclude
 * phones to force multi-hop, and export the event log as evidence (BLE_MESH_TEST_PROTOCOL.md).
 *
 * Its navigation title ("Relay test") is set by the link that opens it (`NavigationLinkRow`).
 */
@Composable
fun RelayTestView(bluetooth: BluetoothMesh, label: String? = null) {
    val relay = bluetooth.relay
    val log = bluetooth.eventLog
    val context = LocalContext.current

    var destination by remember { mutableStateOf("") }
    var text by remember { mutableStateOf("") }
    var ttlMinutes by remember { mutableIntStateOf(10) }
    var hops by remember { mutableIntStateOf(6) }
    var pings by remember { mutableIntStateOf(0) }
    var sendError by remember { mutableStateOf<String?>(null) }
    var exported by remember { mutableStateOf<String?>(null) }
    var beaconHops by remember { mutableIntStateOf(2) }
    var saveMessage by remember { mutableStateOf<String?>(null) }
    // A long log is too big for a share intent: it is saved as a file the user picks instead.
    val saveLog = rememberLauncherForActivityResult(ActivityResultContracts.CreateDocument("application/x-ndjson")) { uri ->
        val content = exported
        if (uri != null && content != null) {
            saveMessage = if (saveText(context, uri, content)) "Log saved" else "Could not save the log"
        }
    }
    // TimelineView(.periodic(by: 1)): ages and times refresh every second.
    rememberNow()

    val peerIds = relay.knownPeers.keys.sortedBy { relay.name(it) }

    Form {
        // Status
        FormSection(footer = "Foreground only: keep the app open and the screen on. Android may stop Bluetooth relaying in the background.") {
            LabeledContent("This phone", relay.selfId?.let { MeshEventLog.short(it) } ?: "–")
            LabeledContent("Relay", if (relay.isRunning) "running" else "stopped (start the mesh)")
            FormRow { FootnoteText(bluetooth.status) }
            bluetooth.lastError?.let { FormRow { FootnoteText(it, MaterialTheme.colorScheme.error) } }
        }

        if (bluetooth.blockedDeviceIds.isNotEmpty()) {
            FormSection {
                FormRow {
                    Icon(Icons.Filled.Warning, contentDescription = null, tint = orange, modifier = Modifier.size(18.dp))
                    Spacer(Modifier.width(8.dp))
                    Text(
                        "Test filter on: ignoring ${bluetooth.blockedDeviceIds.size} phone(s). Turn it off before the demo.",
                        color = orange,
                    )
                }
            }
        }

        // Linked now
        FormSection(header = "Linked now (${bluetooth.neighbors.size})") {
            if (bluetooth.neighbors.isEmpty()) SecondaryRow("No linked phones")
            for (neighbor in bluetooth.neighbors) {
                FormRow {
                    Column(Modifier.weight(1f)) {
                        Text(relay.name(neighbor.deviceId))
                        Text(
                            MeshEventLog.short(neighbor.deviceId) +
                                if (relay.relayNeighbors.contains(neighbor.deviceId)) " · relay" else " · no relay yet",
                            style = captionMono, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text("link " + rssi(neighbor.connectionRSSI), style = captionDigits)
                        Text("adv " + rssi(neighbor.advertisementRSSI), style = captionDigits)
                    }
                }
            }
        }

        // Beacon
        FormSection(
            header = "T3 relay test (AC-3)",
            footer = "Sender: P1. Receiver: P3, with the test filter set so P1 and P3 can't link directly. Pass: at least 95 % received over 120 beacons, route = the middle phone only, median age at most 3 s, no duplicates.",
        ) {
            StepperRow("Beacon hops: $beaconHops", beaconHops, 1..RelayEnvelope.maxHops, enabled = relay.beaconRun == null) {
                beaconHops = it
            }
            ToggleRow("Send 1 Hz beacon", relay.beaconRun != null, enabled = relay.isRunning) { on ->
                if (on) relay.startBeacon(hops = beaconHops) else relay.stopBeacon()
            }
            relay.beaconRun?.let { run ->
                FormRow {
                    Text("Sending run $run", style = calloutDigits, modifier = Modifier.weight(1f))
                    Text("${relay.beaconsSent} sent", style = calloutDigits, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
            for (origin in relay.beaconStats.keys.sorted()) {
                relay.beaconStats[origin]?.let { BeaconRow(relay, it) }
            }
            if (relay.beaconStats.isNotEmpty()) {
                ButtonRow("Reset received statistics") { relay.resetBeaconStats() }
            }
        }

        // Compose
        FormSection(
            header = "Send",
            footer = "A message for one phone is carried by every phone that hears it until it is delivered (receipt), expires (TTL) or runs out of hops. 0 hops reaches direct neighbors only.",
        ) {
            PickerRow(
                "To", listOf("") + peerIds, destination,
                { if (it.isEmpty()) "Everyone (broadcast)" else relay.name(it) },
            ) { destination = it }
            TextFieldRow("Message", text, { text = it })
            StepperRow("Hops: $hops", hops, 0..RelayEnvelope.maxHops) { hops = it }
            PickerRow("TTL", listOf(1, 5, 10, 15), ttlMinutes, { "$it min" }) { ttlMinutes = it }
            ButtonRow("Send", enabled = relay.isRunning) {
                sendError = relay.send(
                    "text", if (text.isEmpty()) "test" else text, destination.ifEmpty { null }, ttlMinutes * 60_000, hops,
                )
                if (sendError == null) text = ""
            }
            ButtonRow("Ping", enabled = relay.isRunning) {
                pings += 1
                sendError = relay.send(
                    "ping", "ping $pings from ${label ?: "phone"}", destination.ifEmpty { null }, ttlMinutes * 60_000, hops,
                )
            }
            sendError?.let { FormRow { FootnoteText(it, MaterialTheme.colorScheme.error) } }
        }

        // Sent
        FormSection(header = "Sent (${relay.sent.size})") {
            for (message in relay.sent.take(20)) {
                MessageRow {
                    Text(message.envelope.body, maxLines = 2, overflow = TextOverflow.Ellipsis)
                    Text(
                        "${MeshEventLog.short(message.id)} · to ${message.envelope.destinationId?.let { relay.name(it) } ?: "everyone"} · ${timeText(message.sentAt)}",
                        style = captionMono, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        deliveryStatus(relay, message), style = caption,
                        color = if (message.receipt == null) MaterialTheme.colorScheme.onSurfaceVariant else green,
                    )
                }
            }
        }

        // Received
        FormSection(header = "Received (${relay.received.size})") {
            for (message in relay.received.take(30)) {
                val envelope = message.delivery.envelope
                MessageRow {
                    Text(envelope.body, maxLines = 3, overflow = TextOverflow.Ellipsis)
                    Text(relay.route(envelope), style = caption)
                    Text(
                        "${message.delivery.hops} hop(s) · age ≥ ${seconds(envelope.ageMs)} · ${envelope.hopsRemaining} hops left · ${MeshEventLog.short(envelope.messageId)}",
                        style = captionMono, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    Text(
                        "arrived ${timeText(message.arrivedAt)}" + originClock(envelope),
                        style = caption2, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        // Filter
        FormSection(
            header = "Test filter (A–B–C)",
            footer = "Refuses Bluetooth links to the chosen phones so a message must hop through another phone. Set it on both phones of the pair. Cleared when the app restarts.",
        ) {
            if (peerIds.isEmpty()) SecondaryRow("No other phones seen yet")
            for (id in peerIds) {
                ToggleRow("Ignore ${relay.name(id)}", bluetooth.blockedDeviceIds.contains(id)) { blocked ->
                    bluetooth.blockedDeviceIds = if (blocked) bluetooth.blockedDeviceIds + id else bluetooth.blockedDeviceIds - id
                }
            }
        }

        // Counters
        val s = relay.statistics
        FormSection(header = "Counters") {
            CounterRow("Originated / accepted", "${s.originated} / ${s.accepted}")
            CounterRow("Delivered here", "${s.delivered}")
            CounterRow("Copies sent", "${s.sent}")
            CounterRow("Duplicates / loops", "${s.duplicates} / ${s.loops}")
            CounterRow("Expired / hop-limited", "${s.expired} / ${s.hopLimited}")
            CounterRow("Stored now / evicted / cleared", "${relay.storedCount} / ${s.evicted} / ${s.cleared}")
            CounterRow("Invalid", "${s.invalid}")
        }

        // GhostCore records
        val r = relay.recordStatistics
        FormSection(
            header = "GhostCore records",
            footer = "Positions, GNSS assessments and predictions from the pipeline (frame type 7).",
        ) {
            CounterRow("Published / accepted", "${r.published} / ${r.accepted}")
            CounterRow("Copies sent", "${r.sent}")
            CounterRow("Duplicates / loops", "${r.duplicates} / ${r.loops}")
            CounterRow("Out of order / stale / expired", "${r.outOfOrder} / ${r.stale} / ${r.expired}")
            CounterRow("Invalid", "${r.invalid}")
            for (origin in relay.recordRoutes.keys.sorted()) {
                val path = relay.recordRoutes[origin] ?: emptyList()
                FormRow {
                    Text(
                        "${relay.name(origin)}: " + if (path.isEmpty()) "direct" else "via " + path.joinToString(" → ") { relay.name(it) },
                        style = caption,
                    )
                }
            }
        }

        // Event log
        FormSection(header = "Event log", footer = "Export after every hardware test and attach it to the results table.") {
            for (entry in log.recent.reversed()) {
                MessageRow {
                    Text(entry.detail, style = caption)
                    Text(
                        "${timeText(entry.wallClock)} · ${entry.category}",
                        style = caption2.copy(fontFamily = captionMono.fontFamily),
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
            ButtonRow("Prepare log for sharing") {
                exported = log.export(deviceId = relay.selfId, label = label)
                saveMessage = null
            }
            exported?.let { content ->
                ButtonRow("Share log (${log.entries.size} events)") {
                    if (content.length <= maxSharedChars) {
                        shareText(context, content, "MeshMapper relay log")
                    } else {
                        saveLog.launch("meshmapper-log-${relay.selfId?.let { MeshEventLog.short(it) } ?: "phone"}.jsonl")
                    }
                }
            }
            saveMessage?.let { FormRow { FootnoteText(it) } }
            ButtonRow("Clear log", destructive = true) {
                log.clear()
                exported = null
                saveMessage = null
            }
        }
    }
}

/** Above this the log is saved as a file: a share intent carries its text through Binder (~1 MB). */
private const val maxSharedChars = 200_000

private val orange = Color(0xFFFF9500)
private val green = Color(0xFF34C759)

private val captionDigits: TextStyle @Composable get() = caption.copy(fontFeatureSettings = "tnum")
private val calloutDigits: TextStyle @Composable get() = MaterialTheme.typography.bodyMedium.copy(fontFeatureSettings = "tnum")
private val caption2: TextStyle @Composable get() = MaterialTheme.typography.labelSmall

/** A Form row holding a VStack(alignment: .leading, spacing: 2). */
@Composable
private fun MessageRow(content: @Composable ColumnScope.() -> Unit) {
    FormRow {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp), content = content)
    }
}

/** LabeledContent in a section with `.font(.callout.monospacedDigit())`. */
@Composable
private fun CounterRow(label: String, value: String) {
    FormRow {
        Text(label, style = calloutDigits, modifier = Modifier.padding(end = 12.dp))
        Text(
            value, style = calloutDigits, modifier = Modifier.weight(1f),
            textAlign = TextAlign.End, color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

@Composable
private fun BeaconRow(relay: MeshRelay, stats: BeaconStats) {
    MessageRow {
        Text("From ${relay.name(stats.originId)} · run ${stats.run}", style = captionDigits)
        Text(
            "received ${stats.received} of ${stats.expected} (${percent(stats.deliveryRatio)}) · seq ${stats.firstSequence ?: 0}–${stats.lastSequence ?: 0}",
            style = captionDigits,
        )
        Text(
            "median age ${stats.medianAgeMs?.let(::seconds) ?: "–"} · p95 ${stats.ageMs(percentile = 95.0)?.let(::seconds) ?: "–"} · max ${stats.agesMs.maxOrNull()?.let(::seconds) ?: "–"}",
            style = captionDigits,
        )
        for (key in stats.routes.keys.sorted()) {
            val relays = if (key.isEmpty()) "direct" else key.split(" > ").joinToString(" → ") { relay.name(it) }
            Text("via $relays: ${stats.routes[key] ?: 0}", style = captionDigits)
        }
        Text(
            "duplicates delivered: ${stats.duplicates}", style = captionDigits,
            color = if (stats.duplicates == 0) MaterialTheme.colorScheme.onSurfaceVariant else Color.Red,
        )
    }
}

// MARK: Formatting

private fun deliveryStatus(relay: MeshRelay, message: MeshRelay.SentMessage): String {
    if (message.envelope.destinationId == null) return "Broadcast: no receipts"
    val receipt = message.receipt ?: return "Waiting for a receipt"
    val info = RelayReceiptInfo.decode(body = receipt.envelope.body)
    val route = info?.let { (listOf(relay.selfId ?: "") + it.path + listOf(receipt.envelope.originId)).joinToString(" → ") { id -> relay.name(id) } } ?: "?"
    return "Delivered: $route, age ≥ ${info?.let { seconds(it.ageMs) } ?: "?"}"
}

private fun originClock(envelope: RelayEnvelope): String {
    val createdAt = envelope.createdAt ?: return ""
    return " · origin clock ${timeText(createdAt / 1000)} (not synced)"
}

private fun percent(ratio: Double?): String = ratio?.let { fmt("%.1f %%", it * 100) } ?: "–"

private fun seconds(ms: Int): String = fmt("%.1f s", ms / 1000.0)

private fun rssi(statistics: RSSIStatistics?): String {
    val smoothed = statistics?.smoothed ?: return "–"
    val deviation = statistics.standardDeviation?.let { fmt(" ±%.0f", it) } ?: ""
    return fmt("%.0f dBm", smoothed) + deviation
}
