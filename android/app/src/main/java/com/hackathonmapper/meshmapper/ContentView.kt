package com.hackathonmapper.meshmapper

import androidx.activity.compose.BackHandler
import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.text.BasicTextField
import androidx.compose.foundation.text.KeyboardActions
import androidx.compose.foundation.text.KeyboardOptions
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.GpsFixed
import androidx.compose.material.icons.filled.Hub
import androidx.compose.material.icons.filled.Upload
import androidx.compose.material.icons.filled.WarningAmber
import androidx.compose.material.icons.filled.WifiTethering
import androidx.compose.material.icons.outlined.NearMe
import androidx.compose.material3.Button
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.focus.onFocusChanged
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.SolidColor
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.layout.layout
import androidx.compose.ui.text.SpanStyle
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.buildAnnotatedString
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.input.KeyboardCapitalization
import androidx.compose.ui.text.input.ImeAction
import androidx.compose.ui.text.input.KeyboardType
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.withStyle
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.hackathonmapper.meshcore.AnchorRange
import com.hackathonmapper.meshcore.GeoFrame
import com.hackathonmapper.meshcore.PositionFilter
import com.hackathonmapper.meshcore.PositionSource
import com.hackathonmapper.meshcore.RSSIStatistics
import com.hackathonmapper.meshcore.SignalMap
import com.hackathonmapper.meshcore.currentTime
import kotlinx.coroutines.delay
import java.text.NumberFormat
import java.util.Locale
import kotlin.math.ceil
import kotlin.math.floor
import kotlin.math.max
import kotlin.math.sqrt

/** One map for everyone; the detailed screens live behind the settings button. */
@Composable
fun ContentView(model: MeshModel) {
    Box(Modifier.fillMaxSize()) {
        PhoneMapView(model)
        // SwiftUI's `.sheet`: the settings slide up over the map; back closes them.
        AnimatedVisibility(
            visible = model.showingSettings,
            enter = slideInVertically { it },
            exit = slideOutVertically { it },
        ) {
            SettingsView(model)
        }
    }
    BackHandler(enabled = model.showingSettings) { model.showingSettings = false }
}

private data class TabItem(val tab: AppTab, val title: String, val icon: ImageVector, val navigationTitle: String)

private val tabs = listOf(
    TabItem(AppTab.track, "Track", Icons.Filled.GpsFixed, "Track"),
    TabItem(AppTab.start, "Start", Icons.Filled.WifiTethering, "MeshMapper"),
    TabItem(AppTab.network, "Network", Icons.Filled.Hub, "Network"),
    TabItem(AppTab.position, "Position", Icons.Outlined.NearMe, "Position"),
    TabItem(AppTab.gateway, "Gateway", Icons.Filled.Upload, "Gateway"),
)

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsView(model: MeshModel) {
    val current = tabs.first { it.tab == model.selectedTab }
    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            TopAppBar(
                title = { Text(current.navigationTitle, fontWeight = FontWeight.Bold) },
                actions = {
                    Button(onClick = { model.showingSettings = false }, modifier = Modifier.padding(end = 8.dp)) {
                        Text("Done")
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(containerColor = MaterialTheme.colorScheme.background),
            )
        },
        bottomBar = {
            NavigationBar {
                for (item in tabs) {
                    NavigationBarItem(
                        selected = model.selectedTab == item.tab,
                        onClick = { model.selectedTab = item.tab },
                        icon = { Icon(item.icon, contentDescription = null) },
                        label = { Text(item.title) },
                    )
                }
            }
        },
    ) { padding ->
        Box(Modifier.padding(padding).fillMaxSize()) {
            when (model.selectedTab) {
                AppTab.track -> TrackView(model)
                AppTab.start -> StartView(model)
                AppTab.network -> NetworkView(model)
                AppTab.position -> PositionView(model)
                AppTab.gateway -> GatewayView(model)
            }
        }
    }
}

/**
 * The one screen most people need: the mesh starts by itself, so this only shows whether the
 * phone is linked, where its position comes from, and how to make it the gateway.
 */
@Composable
fun StartView(model: MeshModel) {
    val bluetooth = model.bluetooth
    val gateway = model.gateway
    val now = rememberNow()
    Form {
        FormSection(footer = "This is how the phone appears on the dashboard.") {
            TextFieldRow(
                placeholder = "Name",
                value = model.label,
                onValueChange = { model.label = it },
                textStyle = MaterialTheme.typography.titleLarge.copy(fontWeight = FontWeight.SemiBold),
            )
        }

        FormSection(header = "Status") {
            model.permissionProblem?.let { problem ->
                FormRow { Text(problem, color = MaterialTheme.colorScheme.error, style = MaterialTheme.typography.bodyMedium) }
                ButtonRow("Allow") { model.onRequestPermissions?.invoke() }
            }
            StatusRow("Bluetooth", Icons.Filled.Hub, bluetoothText(model), ok = bluetooth.neighbors.isNotEmpty())
            StatusRow("Position", Icons.Outlined.NearMe, positionText(model), ok = model.lastSource != PositionSource.none)
            StatusRow(
                "Gateway", Icons.Filled.Upload, gatewayText(model, now),
                ok = gateway.enabled && gateway.lastError == null,
            )
            if (!model.isRunning) {
                ButtonRow("Start the mesh", enabled = model.permissionProblem == null) { model.start() }
            }
        }

        FormSection(
            header = "Demo",
            footer = "This phone stops sharing its GPS, and the dashboard places it from its Bluetooth links instead. Turn it off to share GPS again.",
        ) {
            ToggleRow(
                "Simulate losing GPS", model.simulateGPSLoss,
                enabled = model.positionChoice != PositionChoice.manual,
            ) { model.simulateGPSLoss = it }
        }

        FormSection(
            header = "Gateway (one phone only)",
            footer = "The gateway uploads every phone's position to the laptop. Other phones need no network.",
        ) {
            FormRow {
                Text(
                    buildAnnotatedString {
                        append("Scan the gateway QR code in the dashboard's ")
                        withStyle(SpanStyle(fontWeight = FontWeight.Bold)) { append("Connect") }
                        append(" panel with this phone's camera, then turn on uploading here.")
                    },
                )
            }
            ToggleRow(
                "Upload as gateway", gateway.enabled,
                enabled = model.serverURL.trim().isNotEmpty(),
            ) { model.setGateway(it) }
        }
    }
}

private fun bluetoothText(model: MeshModel): String {
    if (!model.isRunning) return "Mesh stopped"
    val count = model.bluetooth.neighbors.size
    return if (count == 0) "Looking for nearby phones…" else "Linked to $count phone${if (count == 1) "" else "s"}"
}

private fun positionText(model: MeshModel): String {
    if (model.lastSource == PositionSource.uwb) return "UWB fix from an anchor"
    if (model.lastSource == PositionSource.fused) return "Motion + BLE anchors"
    if (model.positionChoice == PositionChoice.manual && !(model.uwbEnabled && model.role != DeviceRole.anchor)) {
        return "Fixed spot (typed on the Position tab)"
    }
    if (model.simulateGPSLoss) return "GPS lost (simulated): placed from Bluetooth"
    if (model.location.isDenied) return "Location not allowed: placed from Bluetooth"
    model.gpsPosition?.let { return "GPS ±${swiftRoundedInt(it.accuracy)} m" }
    return "No GPS fix yet: placed from Bluetooth"
}

private fun gatewayText(model: MeshModel, now: Double): String {
    val gateway = model.gateway
    if (!gateway.enabled) return "Not the gateway"
    gateway.lastError?.let { return it }
    val host = ConnectLink.host(GatewayClient.normalizedOrigin(model.serverURL)) ?: model.serverURL
    return "Uploading to $host · ${ageText(gateway.lastSuccess, now)}"
}

@Composable
private fun StatusRow(title: String, icon: ImageVector, text: String, ok: Boolean) {
    val tint = if (ok) Color(0xFF34C759) else MaterialTheme.colorScheme.onSurfaceVariant
    FormRow {
        Icon(icon, contentDescription = null, tint = tint, modifier = Modifier.size(20.dp))
        Spacer(Modifier.width(10.dp))
        Text(title, color = tint, modifier = Modifier.padding(end = 12.dp))
        Text(
            text,
            modifier = Modifier.weight(1f),
            textAlign = TextAlign.End,
            color = if (ok) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant,
        )
    }
}

fun shortID(id: String): String = id.take(8)

fun ageText(since: Double?, now: Double): String {
    if (since == null) return "never"
    val seconds = max(0, (now - since).toInt())
    return if (seconds < 60) "${seconds}s ago" else "${seconds / 60}m ago"
}

@Composable
fun NetworkView(model: MeshModel) {
    val bluetooth = model.bluetooth
    val now = rememberNow()
    Form {
        FormSection(
            header = "This phone",
            footerContent = if (model.isRunning) {
                {
                    Row(verticalAlignment = Alignment.Top) {
                        Icon(
                            Icons.Filled.WarningAmber, contentDescription = null, modifier = Modifier.size(16.dp),
                            tint = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Spacer(Modifier.width(6.dp))
                        FooterText("Demo mode: keep this app in the foreground. Relaying stops when the phone is locked or the app is backgrounded.")
                    }
                }
            } else {
                null
            },
        ) {
            TextFieldRow("Label", model.label, { model.label = it })
            LabeledContent("Device ID", shortID(model.deviceID))
            TextFieldRow(
                "Frame ID", model.frameID, { model.frameID = it },
                enabled = !model.isRunning,
                keyboardOptions = KeyboardOptions(capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false),
            )
            ToggleRow("Mesh running", model.isRunning, enabled = model.permissionProblem == null) {
                if (it) model.start() else model.stop()
            }
            ToggleRow("Keep screen awake", model.keepAwake) { model.keepAwake = it }
            FormRow { FootnoteText(bluetooth.status) }
            (model.lastError ?: bluetooth.lastError ?: model.permissionProblem)?.let { error ->
                FormRow { FootnoteText(error, MaterialTheme.colorScheme.error) }
            }
        }

        FormSection(
            header = "Neighbors (${bluetooth.neighbors.size} linked, ${bluetooth.pendingLinks} connecting)",
            footer = "RSSI shows link quality (smoothed ± deviation, samples), not distance. Bluetooth radio identifiers are for debugging only.",
        ) {
            if (bluetooth.neighbors.isEmpty()) SecondaryRow("No linked mapping phones")
            for (neighbor in bluetooth.neighbors) {
                FormRow {
                    Column(Modifier.weight(1f)) {
                        Text(neighbor.label ?: shortID(neighbor.deviceId))
                        Text(
                            "${shortID(neighbor.deviceId)} · ${linkDirection(neighbor.outgoing, neighbor.incoming)}",
                            style = captionMono, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                    Column(horizontalAlignment = Alignment.End) {
                        Text("Link " + rssiText(neighbor.connectionRSSI), style = caption)
                        Text("Adv " + rssiText(neighbor.advertisementRSSI), style = caption)
                        Text("heard " + ageText(neighbor.lastHeard, now), style = caption)
                    }
                }
            }
            DisclosureRow("Bluetooth radios seen (${bluetooth.peers.size})") {
                for (peer in bluetooth.peers.values.sortedByDescending { it.lastSeen }) {
                    FormRow {
                        Text(shortID(peer.id.toString()), style = captionMono, modifier = Modifier.weight(1f))
                        Text(
                            "${rssiText(peer.rssi)} · ${ageText(peer.lastSeen, now)}",
                            style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                    }
                }
            }
        }

        FormSection(
            header = "Direct links reported (${model.directNeighbors.size})",
            footer = "Sent with this phone's position so the dashboard can draw the mesh. Only phones linked after a successful handshake are listed.",
        ) {
            if (model.directNeighbors.isEmpty()) SecondaryRow("No ready links yet")
            for (neighbor in model.directNeighbors) {
                FormRow {
                    Text(
                        model.devices.firstOrNull { it.id == neighbor.id }?.update?.label ?: shortID(neighbor.id),
                        modifier = Modifier.weight(1f),
                    )
                    Text(
                        neighbor.rssi?.let { "$it dBm" } ?: "RSSI unknown",
                        style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }
        }

        FormSection(header = "Known devices (${model.devices.size})") {
            if (model.devices.isEmpty()) SecondaryRow("No position reports yet")
            for (device in model.devices) {
                DeviceRow(device, route(model, device), now)
            }
        }

        FormSection(header = "Diagnostics") {
            LabeledContent("Received", "${model.diagnostics.received}")
            LabeledContent("Accepted", "${model.diagnostics.accepted}")
            LabeledContent("Relayed", "${model.diagnostics.relayed}")
            LabeledContent("Duplicate / old", "${model.diagnostics.duplicate}")
            LabeledContent("Rejected", "${model.diagnostics.rejected}")
        }
    }
}

private fun route(model: MeshModel, device: KnownDevice): String {
    val path = device.path ?: return "This phone"
    // Self-reported by each relay: useful for diagnostics, not proof of the route.
    return if (path.isEmpty()) "Direct" else "via " + path.joinToString(" → ") { model.displayName(it) }
}

private fun linkDirection(outgoing: Boolean, incoming: Boolean): String = when {
    outgoing && incoming -> "both directions"
    outgoing -> "outgoing"
    else -> "incoming"
}

private fun rssiText(stats: RSSIStatistics?): String {
    val smoothed = stats?.smoothed ?: return "–"
    val deviation = stats.standardDeviation?.let { fmt(" ±%.0f", it) } ?: ""
    return "${swiftRoundedInt(smoothed)}$deviation dBm (${stats.sampleCount})"
}

@Composable
fun DeviceRow(device: KnownDevice, route: String, now: Double) {
    val update = device.update
    val p = update.position
    FormRow {
        Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(update.label ?: shortID(update.id), style = headline)
                Spacer(Modifier.width(8.dp))
                Text(update.role, style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
                Spacer(Modifier.weight(1f))
                Text(ageText(device.receivedAt, now), style = caption)
            }
            Text(fmt("x %.2f  y %.2f  z %.2f m", p.x, p.y, p.z), style = captionMono)
            Text(
                "$route · seq ${update.sequence}${if (update.positionMode == "floor") " · height assumed" else ""}",
                style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant,
            )
        }
    }
}

@Composable
fun PositionView(model: MeshModel) {
    val usesUWBFix = model.uwbEnabled && model.role != DeviceRole.anchor
    val (axisX, axisZ) = GeoFrame.axisNames(model.frameID)
    Form {
        FormSection(
            footer = if (usesUWBFix) {
                "Published coordinates come from a UWB anchor; without a fresh fix, GPS or no position. The manual coordinates below are not used while UWB positioning is on."
            } else {
                when (model.positionChoice) {
                    PositionChoice.gps ->
                        "GPS fixes better than ±${LocationSource.maxAccuracyMeters.toInt()} m are shared in meters $axisX (x) and $axisZ (z) of the frame origin, with a 95 % accuracy radius. Without one, the phone reports no position and the dashboard places it from Bluetooth."
                    PositionChoice.manual ->
                        "Manual / demo coordinates in meters: x $axisX, y up, z $axisZ. They are not measured positions."
                    PositionChoice.fused ->
                        "Estimated from steps and turns (accelerometer, gyro) corrected by RSSI to linked anchor phones. Accuracy is the filter's own 95 % estimate, typically a few meters indoors. Until tracking starts: GPS or no position."
                }
            },
        ) {
            PickerRow("Role", DeviceRole.entries, model.role, { it.rawValue.replaceFirstChar { c -> c.uppercase() } }) {
                model.role = it
            }
            if (usesUWBFix) {
                LabeledContent("Source", "UWB fix from an anchor")
            } else {
                PickerRow("Source", PositionChoice.entries, model.positionChoice, { it.title }) { model.positionChoice = it }
            }
            LabeledContent("Frame", model.frameID)
        }

        UWBSection(model)

        FormSection(header = if (model.positionChoice == PositionChoice.fused) "Start point" else "Coordinates") {
            PickerRow(
                "Height", listOf("floor", "3d"), model.positionMode,
                { if (it == "floor") "Floor (assumed)" else if (model.positionChoice == PositionChoice.fused) "Barometer 3D" else "Estimated 3D" },
            ) { model.positionMode = it }
            NumberRow("x ($axisX)", model.manualX, { model.manualX = it })
            NumberRow("y (up)", model.manualY, { model.manualY = it }, enabled = model.positionMode != "floor")
            NumberRow("z ($axisZ)", model.manualZ, { model.manualZ = it })
            if (model.positionChoice != PositionChoice.fused) {
                ToggleRow("Accuracy known", model.accuracyKnown) { model.accuracyKnown = it }
                if (model.accuracyKnown) {
                    NumberRow("Accuracy, 95 % (m)", model.accuracyMeters, { model.accuracyMeters = it })
                } else {
                    LabeledContent("Accuracy", "Unknown")
                }
            }
        }

        if (model.positionChoice == PositionChoice.fused) {
            FusionSections(model, model.fusionStatus)
        }

        FormSection(footer = if (!model.isRunning) "Start the mesh on the Network tab first." else null) {
            ToggleRow("Publish every second", model.isPublishing, enabled = model.isRunning) { model.setPublishing(it) }
            LabeledContent("Last sequence", model.lastSequence?.toString() ?: "–")
            model.lastError?.let { FormRow { FootnoteText(it, MaterialTheme.colorScheme.error) } }
        }
    }
}

@Composable
private fun UWBSection(model: MeshModel) {
    val uwb = model.uwb
    val now = rememberNow()
    FormSection(
        header = "UWB positioning",
        footer = if (!UWBRanging.supportsDistance) {
            "${UWBRanging.unsupportedReason} Android phones take part in the mesh with GPS, typed spots or motion + BLE anchors."
        } else if (model.role == DeviceRole.anchor) {
            "Mount this phone upright with the screen facing you and enter the direction its back faces, measured on the floor plan from +z towards +x (0 = ${GeoFrame.forwardName(model.frameID)}, 90 = +x). Its manual coordinates are the known anchor position. Phones are measured only inside a cone behind it, up to about 8 m."
        } else {
            "A mounted anchor with known coordinates measures this phone's distance and direction over UWB. Needs iPhone 11 or newer (not SE) on both sides and line of sight."
        },
    ) {
        ToggleRow(
            "UWB positioning", model.uwbEnabled,
            enabled = model.isRunning && UWBRanging.supportsDistance,
        ) { model.setUWB(it) }
        LabeledContent(
            "This phone",
            if (UWBRanging.supportsDirection) "Distance + direction" else if (UWBRanging.supportsDistance) "Distance only" else "No UWB",
        )
        if (model.role == DeviceRole.anchor) {
            if (UWBRanging.supportsDistance) NumberRow("Back faces (°)", model.anchorHeading, { model.anchorHeading = it })
            if (model.uwbEnabled) {
                if (uwb.measurements.isEmpty()) SecondaryRow("Measuring no phones yet")
                for (id in uwb.measurements.keys.sorted()) {
                    val measurement = uwb.measurements[id] ?: continue
                    FormRow {
                        Text(model.displayName(id), modifier = Modifier.weight(1f))
                        Text(measurementText(measurement, now), style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
                    }
                }
            }
        } else if (model.uwbEnabled) {
            val current = model.currentFix
            if (current != null) {
                val p = current.fix.position
                LabeledContent("Fix from", model.displayName(current.fix.anchorId))
                FormRow {
                    Text(
                        fmt("x %.2f  z %.2f m · ±%.2f m · %.1f m away", p.x, p.z, current.fix.accuracyMeters, current.fix.distanceMeters),
                        style = captionMono,
                    )
                }
                FormRow {
                    Text("updated " + ageText(current.receivedAt, now), style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            } else {
                FormRow {
                    FootnoteText(
                        "No fresh fix: not publishing. Face the anchor's back within about 8 m, in line of sight.",
                        Color(0xFFFF9500),
                    )
                }
            }
        }
        uwb.lastError?.let { FormRow { FootnoteText(it, MaterialTheme.colorScheme.error) } }
    }
}

private fun measurementText(measurement: UWBMeasurement, now: Double): String {
    val distance = measurement.distance?.let { fmt("%.2f m", it) } ?: "no distance"
    return "$distance · ${if (measurement.direction == null) "no direction" else "direction ✓"} · ${ageText(measurement.updatedAt, now)}"
}

/** Tracking controls and what motion filtering does to each anchor's BLE range. */
@Composable
fun FusionSections(model: MeshModel, status: FusionStatus) {
    /** The frame's +z direction: dead reckoning's heading is aligned to it. */
    val forward = GeoFrame.forwardName(model.frameID)
    val running = model.isRunning
    FormSection(
        header = "Tracking",
        footer = "Hold the phone in front of you the same way while walking. Heading is relative, so face $forward when starting or re-aligning.",
    ) {
        if (status.tracking) {
            ButtonRow("Re-align heading (facing $forward now)", enabled = running) { model.alignHeading() }
            MenuRow(
                "I'm next to an anchor…",
                items = model.anchors.map { anchor -> (anchor.label ?: shortID(anchor.id)) to { model.markNear(anchor.id) } },
                enabled = running && model.anchors.isNotEmpty(),
            )
            ButtonRow("Stop tracking", enabled = running, destructive = true) { model.stopTracking() }
        } else {
            ButtonRow("Start here, facing $forward", enabled = running) { model.startTracking() }
            ButtonRow("Start at RSSI fix, facing $forward", enabled = running && status.fix != null) { model.startTrackingFromFix() }
        }
    }

    FormSection(header = "Estimate") {
        val x = status.x
        val z = status.z
        if (x != null && z != null) {
            LabeledContent("Position", fmt("x %.2f  z %.2f m", x, z))
            LabeledContent("Accuracy (95 %)", status.accuracy?.let { fmt("±%.1f m", it) } ?: "Unknown")
        } else {
            SecondaryRow("Not tracking")
        }
        LabeledContent("Heading", fmt("%.0f° (gyro offset %+.0f°)", status.headingDegrees, status.headingOffsetDegrees))
        LabeledContent("Steps", fmt("%d · %.1f m · %s", status.steps, status.walked, if (status.walking) "walking" else "still"))
        LabeledContent("Radio offset", status.receiverOffsetDB?.let { fmt("%+.1f dB", it) } ?: "–")
        LabeledContent(
            "Path loss",
            fmt(
                "n %.2f · %.0f dBm at 1 m · %d anchor links",
                status.calibration.model.exponent, status.calibration.model.referenceRSSI, status.calibration.linkCount,
            ),
        )
        LabeledContent("RSSI updates", "${status.accepted} used · ${status.rejected} rejected · ${status.recoveries} resets")
    }

    FormSection(
        header = "Anchor ranges",
        footer = "RSSI range after motion filtering, then the range from the fused position. Standing still averages RSSI; jumps the steps can't explain are dropped.",
    ) {
        if (status.ranges.isEmpty()) SecondaryRow("No linked anchors with recent RSSI")
        for (range in status.ranges) {
            FormRow {
                Column(Modifier.fillMaxWidth(), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                    Row {
                        Text(model.displayName(range.anchorId), modifier = Modifier.weight(1f))
                        Text(rangeText(range), style = captionMono)
                    }
                    Text(detailText(range), style = caption, color = MaterialTheme.colorScheme.onSurfaceVariant)
                }
            }
        }
    }

    FormSection(header = "RSSI-only fix", footer = "For comparison and to start tracking. It is never published on its own.") {
        val fix = status.fix
        if (fix != null) {
            LabeledContent("Position", fmt("x %.2f  z %.2f m", fix.x, fix.z))
            LabeledContent(
                "Accuracy (95 %)",
                fmt(
                    "±%.1f m · %d anchors · %.1f dB residual",
                    fix.accuracy * SignalMap.r95PerSigma / sqrt(2.0), fix.anchorCount, fix.residualDB,
                ),
            )
        } else {
            SecondaryRow("Needs RSSI from three or more anchors")
        }
    }
}

private fun rangeText(range: AnchorRange): String {
    val fused = range.fusedDistance?.let { fmt(" → %.1f m", it) } ?: ""
    return fmt("%.1f m", range.rssiDistance) + fused
}

private fun detailText(range: AnchorRange): String {
    val parts = mutableListOf(fmt("±%.1f dB", range.sigmaDB))
    parts.add(if (range.stillSamples > 0) "${range.stillSamples} still samples averaged" else "walking")
    if (range.droppedSamples > 0) parts.add("${range.droppedSamples} jumps dropped")
    when (range.lastResult) {
        PositionFilter.UpdateResult.accepted -> parts.add("used")
        PositionFilter.UpdateResult.rejected -> parts.add("rejected")
        PositionFilter.UpdateResult.skipped -> parts.add("skipped")
        null -> {}
    }
    return parts.joinToString(" · ")
}

@Composable
fun GatewayView(model: MeshModel) {
    val gateway = model.gateway
    val now = rememberNow()
    Form {
        FormSection(
            header = "Laptop dashboard",
            footer = "Easiest: scan the gateway QR code from the dashboard's Connect panel or from `npm run tunnel` with the camera app; it fills in both fields. Over the internet (any network, including mobile data) use the https URL and token; on the laptop's Wi-Fi the LAN URL works without a token. localhost refers to this phone, not the laptop.",
        ) {
            TextFieldRow(
                "https://….trycloudflare.com or http://192.168.1.20:3000", model.serverURL, { model.serverURL = it },
                enabled = !gateway.enabled,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Uri,
                ),
            )
            TextFieldRow(
                "Gateway token (internet only)", model.gatewayToken, { model.gatewayToken = it },
                enabled = !gateway.enabled,
                keyboardOptions = KeyboardOptions(
                    capitalization = KeyboardCapitalization.None, autoCorrectEnabled = false, keyboardType = KeyboardType.Password,
                ),
                visualTransformation = PasswordVisualTransformation(),
            )
            ButtonRow("Check connection") { model.checkGatewayConnection() }
            LabeledContent("Status", gateway.connectionStatus)
        }

        FormSection(header = "Upload") {
            ToggleRow("Upload as gateway", gateway.enabled) { model.setGateway(it) }
            LabeledContent("Last success", ageText(gateway.lastSuccess, now))
            LabeledContent("Pending devices", "${gateway.pendingCount}")
            LabeledContent("Accepted / ignored", "${gateway.acceptedCount} / ${gateway.ignoredCount}")
            (gateway.lastError ?: model.lastError)?.let { FormRow { FootnoteText(it, MaterialTheme.colorScheme.error) } }
        }
    }
}

// MARK: - Form building blocks (SwiftUI Form / Section / LabeledContent look-alikes)

internal val caption: TextStyle @Composable get() = MaterialTheme.typography.bodySmall
internal val captionMono: TextStyle @Composable get() = MaterialTheme.typography.bodySmall.copy(fontFamily = FontFamily.Monospace)
internal val headline: TextStyle @Composable get() = MaterialTheme.typography.bodyLarge.copy(fontWeight = FontWeight.SemiBold)

/** `String(format:)`, which always uses '.' as the decimal separator. */
internal fun fmt(format: String, vararg args: Any?): String = String.format(Locale.US, format, *args)

/** `Int(x.rounded())`: rounds half away from zero; non-finite values become 0 instead of trapping. */
internal fun swiftRoundedInt(x: Double): Int =
    if (!x.isFinite()) 0 else (if (x >= 0) floor(x + 0.5) else ceil(x - 0.5)).toInt()

/** TimelineView(.periodic(by: 1)): the current time, refreshed every second. */
@Composable
internal fun rememberNow(): Double {
    val now by produceState(currentTime()) {
        while (true) {
            delay(1000)
            value = currentTime()
        }
    }
    return now
}

/** A grouped Form: scrolling sections on the grouped background. */
@Composable
internal fun Form(content: @Composable ColumnScope.() -> Unit) {
    Column(
        Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .verticalScroll(rememberScrollState())
            .imePadding()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        content = content,
    )
}

/** A Form Section: header, rounded group of rows with separators, footer. */
@Composable
internal fun FormSection(
    header: String? = null,
    footer: String? = null,
    footerContent: (@Composable () -> Unit)? = null,
    content: @Composable ColumnScope.() -> Unit,
) {
    Column(Modifier.fillMaxWidth().padding(bottom = 24.dp)) {
        if (header != null) {
            Text(
                header.uppercase(),
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.padding(start = 16.dp, end = 16.dp, bottom = 6.dp),
            )
        }
        val shape = RoundedCornerShape(10.dp)
        Column(
            Modifier
                .fillMaxWidth()
                .clip(shape)
                .background(MaterialTheme.colorScheme.surfaceContainerLowest)
                // Every row draws a separator above itself; shifting the group up by one pixel
                // hides the first one, like the separators between Form rows.
                .layout { measurable, constraints ->
                    val placeable = measurable.measure(constraints)
                    val height = max(0, placeable.height - 1)
                    layout(placeable.width, height) { placeable.place(0, -1) }
                },
            content = content,
        )
        if (footer != null || footerContent != null) {
            Box(Modifier.padding(start = 16.dp, end = 16.dp, top = 6.dp)) {
                if (footerContent != null) footerContent() else FooterText(footer!!)
            }
        }
    }
}

@Composable
internal fun FooterText(text: String) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
}

@Composable
internal fun FootnoteText(text: String, color: Color = MaterialTheme.colorScheme.onSurfaceVariant) {
    Text(text, style = MaterialTheme.typography.bodySmall, color = color)
}

/** One Form row, with the separator above it. */
@Composable
internal fun FormRow(
    modifier: Modifier = Modifier,
    padding: PaddingValues = PaddingValues(horizontal = 16.dp, vertical = 11.dp),
    content: @Composable androidx.compose.foundation.layout.RowScope.() -> Unit,
) {
    Column(Modifier.fillMaxWidth()) {
        HorizontalDivider(Modifier.padding(start = 16.dp), thickness = Dp.Hairline, color = MaterialTheme.colorScheme.outlineVariant)
        Row(
            modifier.fillMaxWidth().heightIn(min = 44.dp).padding(padding),
            verticalAlignment = Alignment.CenterVertically,
            content = content,
        )
    }
}

@Composable
internal fun SecondaryRow(text: String) {
    FormRow { Text(text, color = MaterialTheme.colorScheme.onSurfaceVariant) }
}

@Composable
internal fun LabeledContent(label: String, value: String) {
    FormRow {
        Text(label, modifier = Modifier.padding(end = 12.dp))
        Text(value, modifier = Modifier.weight(1f), textAlign = TextAlign.End, color = MaterialTheme.colorScheme.onSurfaceVariant)
    }
}

@Composable
internal fun ToggleRow(label: String, checked: Boolean, enabled: Boolean = true, onCheckedChange: (Boolean) -> Unit) {
    FormRow(
        modifier = Modifier.alpha(if (enabled) 1f else 0.5f),
        padding = PaddingValues(horizontal = 16.dp, vertical = 4.dp),
    ) {
        Text(label, modifier = Modifier.weight(1f))
        Switch(checked = checked, onCheckedChange = onCheckedChange, enabled = enabled)
    }
}

@Composable
internal fun ButtonRow(title: String, enabled: Boolean = true, destructive: Boolean = false, onClick: () -> Unit) {
    val color = if (destructive) MaterialTheme.colorScheme.error else MaterialTheme.colorScheme.primary
    FormRow(modifier = Modifier.clickable(enabled = enabled, onClick = onClick)) {
        Text(title, color = if (enabled) color else MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.6f))
    }
}

/** SwiftUI `Menu`: a button row that opens a list of actions. */
@Composable
internal fun MenuRow(title: String, items: List<Pair<String, () -> Unit>>, enabled: Boolean = true) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        ButtonRow(title, enabled = enabled) { expanded = true }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            for ((label, action) in items) {
                DropdownMenuItem(text = { Text(label) }, onClick = { expanded = false; action() })
            }
        }
    }
}

/** A Form `Picker` in its default menu style: the label, the current choice, a menu of choices. */
@Composable
internal fun <T> PickerRow(
    label: String,
    options: List<T>,
    selected: T,
    title: (T) -> String,
    enabled: Boolean = true,
    onSelect: (T) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    Box {
        FormRow(modifier = Modifier.clickable(enabled = enabled) { expanded = true }) {
            Text(label, modifier = Modifier.weight(1f))
            Text(title(selected), color = MaterialTheme.colorScheme.onSurfaceVariant)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = MaterialTheme.colorScheme.onSurfaceVariant)
        }
        DropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }, modifier = Modifier.align(Alignment.TopEnd)) {
            for (option in options) {
                DropdownMenuItem(
                    text = { Text(title(option), fontWeight = if (option == selected) FontWeight.SemiBold else FontWeight.Normal) },
                    onClick = { expanded = false; onSelect(option) },
                )
            }
        }
    }
}

/** A Form `DisclosureGroup`. */
@Composable
internal fun DisclosureRow(title: String, content: @Composable () -> Unit) {
    var expanded by remember { mutableStateOf(false) }
    FormRow(modifier = Modifier.clickable { expanded = !expanded }) {
        Text(title, style = MaterialTheme.typography.bodyMedium, modifier = Modifier.weight(1f))
        Icon(
            if (expanded) Icons.Filled.ExpandMore else Icons.Filled.ChevronRight,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
        )
    }
    if (expanded) content()
}

/** A Form `TextField`: borderless, with the placeholder shown while empty. */
@Composable
internal fun TextFieldRow(
    placeholder: String,
    value: String,
    onValueChange: (String) -> Unit,
    enabled: Boolean = true,
    keyboardOptions: KeyboardOptions = KeyboardOptions.Default,
    visualTransformation: VisualTransformation = VisualTransformation.None,
    textStyle: TextStyle = MaterialTheme.typography.bodyLarge,
    textAlign: TextAlign = TextAlign.Start,
    modifier: Modifier = Modifier,
) {
    val color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
    FormRow {
        InlineTextField(placeholder, value, onValueChange, enabled, keyboardOptions, visualTransformation, textStyle.copy(color = color, textAlign = textAlign), modifier.weight(1f))
    }
}

@Composable
private fun InlineTextField(
    placeholder: String,
    value: String,
    onValueChange: (String) -> Unit,
    enabled: Boolean,
    keyboardOptions: KeyboardOptions,
    visualTransformation: VisualTransformation,
    textStyle: TextStyle,
    modifier: Modifier,
    keyboardActions: KeyboardActions = KeyboardActions.Default,
) {
    BasicTextField(
        value = value,
        onValueChange = onValueChange,
        enabled = enabled,
        singleLine = true,
        keyboardOptions = keyboardOptions,
        keyboardActions = keyboardActions,
        visualTransformation = visualTransformation,
        textStyle = textStyle,
        cursorBrush = SolidColor(MaterialTheme.colorScheme.primary),
        modifier = modifier,
        decorationBox = { inner ->
            Box(contentAlignment = if (textStyle.textAlign == TextAlign.End) Alignment.CenterEnd else Alignment.CenterStart) {
                if (value.isEmpty()) {
                    Text(
                        placeholder,
                        style = textStyle.copy(color = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.7f)),
                        maxLines = 1,
                    )
                }
                inner()
            }
        },
    )
}

/** Up to three decimals in the phone's locale, like `.number.precision(.fractionLength(0...3))`. */
private fun formatNumber(value: Double): String = NumberFormat.getNumberInstance().apply {
    maximumFractionDigits = 3
    minimumFractionDigits = 0
    isGroupingUsed = false
}.format(value)

/** Accepts either decimal separator; nil for anything that is not a finite number. */
internal fun parseNumber(text: String): Double? =
    text.trim().replace(',', '.').replace('−', '-').toDoubleOrNull()?.takeIf { it.isFinite() }

/**
 * `coordinateField`: a labeled number field. Like SwiftUI's `TextField(value:format:)` it commits
 * when editing ends (Done on the keyboard or leaving the field), not on every keystroke; text that
 * is not a number, or an empty field, reverts to the current value.
 */
@Composable
internal fun NumberRow(title: String, value: Double, onValue: (Double) -> Unit, enabled: Boolean = true) {
    var text by remember { mutableStateOf(formatNumber(value)) }
    var focused by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current
    // Follows changes made elsewhere (a pin on the map) unless the user is typing here.
    LaunchedEffect(value) {
        if (!focused) text = formatNumber(value)
    }

    fun commit() {
        val parsed = parseNumber(text)
        if (parsed != null && parsed != value) onValue(parsed)
        text = formatNumber(parsed ?: value)
    }

    val color = if (enabled) MaterialTheme.colorScheme.onSurface else MaterialTheme.colorScheme.onSurfaceVariant
    FormRow(modifier = Modifier.alpha(if (enabled) 1f else 0.6f)) {
        Text(title, modifier = Modifier.padding(end = 12.dp))
        InlineTextField(
            placeholder = title,
            value = text,
            onValueChange = { text = it },
            enabled = enabled,
            // iOS uses .numbersAndPunctuation: a text keyboard, so '-' is always there (many
            // Android number pads hide it). parseNumber() validates what is typed.
            keyboardOptions = KeyboardOptions(
                keyboardType = KeyboardType.Ascii, autoCorrectEnabled = false, imeAction = ImeAction.Done,
            ),
            keyboardActions = KeyboardActions(onDone = { focusManager.clearFocus() }),
            visualTransformation = VisualTransformation.None,
            textStyle = MaterialTheme.typography.bodyLarge.copy(color = color, textAlign = TextAlign.End),
            modifier = Modifier
                .weight(1f)
                .onFocusChanged { state ->
                    if (focused && !state.isFocused) commit()
                    focused = state.isFocused
                },
        )
    }
}
