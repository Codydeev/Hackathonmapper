package com.hackathonmapper.meshmapper

import android.content.Context
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowForward
import androidx.compose.material.icons.filled.ArrowDropDown
import androidx.compose.material.icons.filled.LocationOff
import androidx.compose.material.icons.filled.LocationOn
import androidx.compose.material.icons.filled.NorthEast
import androidx.compose.material.icons.filled.PlayCircle
import androidx.compose.material.icons.filled.Sensors
import androidx.compose.material.icons.filled.SensorsOff
import androidx.compose.material.icons.filled.Stop
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Switch
import androidx.compose.material3.SwitchDefaults
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.alpha
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.MeshJson
import com.hackathonmapper.meshcore.Scenario

/**
 * What the simulation panel can do. Every action injects RAW inputs (GNSS fixes, which Bluetooth
 * links are up) into the pipeline; the panel never sets an output. An action this build cannot
 * perform is shown disabled with the reason, not faked.
 */
class VizScenarioControls {
    data class Option(val id: String, val title: String, val summary: String)

    data class Peer(val id: String, val label: String, val linkUp: Boolean)

    enum class GNSSFault {
        jump, drift, outage, restore;

        val title: String
            get() = when (this) {
                jump -> "Jump 400 m"
                drift -> "Slow drift"
                outage -> "Outage"
                restore -> "Restore GPS"
            }

        val detail: String
            get() = when (this) {
                jump -> "fix teleports, claims ±4 m"
                drift -> "pulled east at 1 m/s"
                outage -> "no fixes at all"
                restore -> "clean receiver again"
            }

        /** SF Symbols in the iOS app; the closest Material icon here. */
        val icon: ImageVector
            get() = when (this) {
                jump -> Icons.Filled.NorthEast
                drift -> Icons.AutoMirrored.Filled.ArrowForward
                outage -> Icons.Filled.LocationOff
                restore -> Icons.Filled.LocationOn
            }
    }

    var scenarios: List<Option> = emptyList()
    /**
     * Plays a script as `role` (this phone injects only that role's steps, since faults act on a
     * phone's own sensors); the map gives the device ID of each other role, for link steps.
     */
    var run: ((scenarioId: String, role: String?, roles: Map<String, String>) -> Unit)? = null
    /** Roles a script can be played as ("phone-a", "phone-b", "phone-c"); empty = no choice. */
    var roles: List<String> = emptyList()
    var stop: (() -> Unit)? = null
    var supportedGNSS: Set<GNSSFault> = emptySet()
    var gnss: ((GNSSFault) -> Unit)? = null
    var peers: List<Peer> = emptyList()
    var setPeerLink: ((String, Boolean) -> Unit)? = null
    /** Shown under any disabled section. */
    var unavailableReason = "Needs the GhostCore hub on this build."

    companion object {
        /** "phone-b" -> "B". */
        fun roleName(role: String): String = if (role.startsWith("phone-")) role.drop(6).uppercase() else role
    }
}

/**
 * The GhostCore scenarios bundled at the assets root as S0.json … S6.json (copied from
 * contract/scenarios by the app's Gradle task, like the iOS bundle), sorted by id. GhostCoreHub
 * reads the same files; the map falls back to this only if the hub came up without them.
 */
fun bundledScenarioAssets(context: Context): List<Scenario> {
    val names = try {
        context.assets.list("")?.toList() ?: emptyList()
    } catch (_: Exception) {
        emptyList()
    }
    return names
        .filter { Regex("^S[0-9]+\\.json$").matches(it) }
        .mapNotNull { name ->
            try {
                val text = context.assets.open(name).use { it.readBytes().decodeToString() }
                MeshJson.decodeFromString<Scenario>(text)
            } catch (_: Exception) {
                null
            }
        }
        .sortedBy { it.id }
}

private const val roleKey = "ghostScenarioRole"
private const val roleMapKey = "ghostScenarioRoleMap"

/** The simulation sheet. SwiftUI's `@AppStorage` keys live in the "meshmapper" preferences. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ScenarioPanel(controls: VizScenarioControls, scenario: VizScenarioState?, close: () -> Unit) {
    val context = LocalContext.current
    val defaults = remember { context.getSharedPreferences("meshmapper", Context.MODE_PRIVATE) }
    var role by remember { mutableStateOf(defaults.getString(roleKey, "") ?: "") }
    /** Which nearby phone plays each other role, as "phone-a=<device id>;…". */
    var roleMapText by remember { mutableStateOf(defaults.getString(roleMapKey, "") ?: "") }

    fun setRoleValue(value: String) {
        role = value
        defaults.edit().putString(roleKey, value).apply()
    }

    val roleMap: Map<String, String> = roleMapText.split(";").mapNotNull { pair ->
        val parts = pair.split("=", limit = 2)
        if (parts.size == 2) parts[0] to parts[1] else null
    }.toMap()

    fun setRole(other: String, device: String?) {
        val map = roleMap.toMutableMap()
        if (device == null) map.remove(other) else map[other] = device
        roleMapText = map.entries.sortedBy { it.key }.joinToString(";") { "${it.key}=${it.value}" }
        defaults.edit().putString(roleMapKey, roleMapText).apply()
    }

    Column(Modifier.fillMaxSize().background(Color.Black)) {
        GhostSheetBar("Simulation", close)
        Column(
            Modifier.fillMaxWidth().verticalScroll(rememberScrollState()).padding(GhostTheme.gap4),
            verticalArrangement = Arrangement.spacedBy(GhostTheme.gap4),
        ) {
            // Header
            Column(verticalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
                HazardStripes(Modifier.fillMaxWidth().height(8.dp).clip(CircleShape))
                Text("SIMULATED INPUTS", style = TextStyle(fontSize = 26.sp, fontWeight = FontWeight.Black), color = GhostTheme.simulation)
                Text(
                    "These controls change only what the sensors report: GPS fixes and which Bluetooth peers are on the air. " +
                        "Trust checks, relay, Bluetooth placement and prediction run unchanged, and everything they show is " +
                        "computed live. Injected items carry a SIMULATED badge.",
                    style = GhostTheme.small, color = GhostTheme.text,
                )
            }

            if (scenario != null) ActiveCard(scenario, controls.stop)

            // Scripted scenarios
            PanelSection(
                "Scripted scenarios",
                footer = if (controls.run == null) controls.unavailableReason
                else "Deterministic: the same script replays the same inputs every time.",
            ) {
                if (controls.scenarios.isEmpty()) {
                    Text("No scripts on this build.", style = GhostTheme.small, color = GhostTheme.muted)
                } else if (controls.roles.isNotEmpty()) {
                    LaunchedEffect(controls.roles) { if (role !in controls.roles) setRoleValue(controls.roles[0]) }
                    Text("This phone plays", style = TextStyle(fontSize = 13.sp), color = GhostTheme.muted)
                    SingleChoiceSegmentedButtonRow(Modifier.fillMaxWidth()) {
                        controls.roles.forEachIndexed { i, r ->
                            SegmentedButton(
                                selected = role == r,
                                onClick = { setRoleValue(r) },
                                shape = SegmentedButtonDefaults.itemShape(i, controls.roles.size),
                                icon = {},
                            ) { Text("Phone ${VizScenarioControls.roleName(r)}", maxLines = 1) }
                        }
                    }
                    // Link steps name the other roles; they need to know which nearby phone is which.
                    for (other in controls.roles.filter { it != role }) {
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            Text("Phone ${VizScenarioControls.roleName(other)} is", style = GhostTheme.small, color = GhostTheme.muted)
                            Spacer(Modifier.weight(1f))
                            PeerPicker(
                                current = roleMap[other] ?: "",
                                peers = controls.peers,
                                onPick = { setRole(other, it.ifEmpty { null }) },
                            )
                        }
                    }
                }
                for (option in controls.scenarios) {
                    Row(
                        Modifier
                            .fillMaxWidth()
                            .clickable(enabled = controls.run != null) {
                                controls.run?.invoke(option.id, if (controls.roles.isEmpty()) null else role, roleMap)
                            }
                            .alpha(if (controls.run == null) 0.35f else 1f)
                            .padding(vertical = 2.dp),
                        horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap3),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Icon(Icons.Filled.PlayCircle, contentDescription = null, tint = GhostTheme.simulation, modifier = Modifier.size(32.dp))
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(option.title, style = GhostTheme.body.copy(fontWeight = FontWeight.SemiBold), color = GhostTheme.text)
                            Text(option.summary, style = GhostTheme.small, color = GhostTheme.muted)
                        }
                    }
                }
            }

            // This phone's GPS
            val all = VizScenarioControls.GNSSFault.entries
            PanelSection(
                "This phone's GPS",
                footer = if (controls.supportedGNSS.size < all.size) "Greyed out: ${controls.unavailableReason}" else null,
            ) {
                for (row in all.chunked(2)) {
                    Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
                        for (fault in row) {
                            val enabled = fault in controls.supportedGNSS && controls.gnss != null
                            val color = if (fault == VizScenarioControls.GNSSFault.restore) GhostTheme.confirmed else GhostTheme.simulation
                            Column(
                                Modifier
                                    .weight(1f)
                                    .alpha(if (enabled) 1f else 0.35f)
                                    .clip(RoundedCornerShape(12.dp))
                                    .background(GhostTheme.surfaceRaised)
                                    .clickable(enabled = enabled) { controls.gnss?.invoke(fault) }
                                    .padding(GhostTheme.gap3),
                                verticalArrangement = Arrangement.spacedBy(GhostTheme.gap1),
                            ) {
                                Icon(fault.icon, contentDescription = null, tint = color, modifier = Modifier.size(22.dp))
                                Text(fault.title, style = GhostTheme.small.copy(fontWeight = FontWeight.Bold), color = color)
                                Text(fault.detail, style = TextStyle(fontSize = 12.sp), color = GhostTheme.muted)
                            }
                        }
                    }
                }
            }

            // Peers
            PanelSection(
                "Peers (Bluetooth links)",
                footer = if (controls.setPeerLink == null) controls.unavailableReason
                else "Off = this phone stops hearing that peer, as if it walked out of range.",
            ) {
                if (controls.peers.isEmpty()) {
                    Text("No peers in reach.", style = GhostTheme.small, color = GhostTheme.muted)
                }
                for (peer in controls.peers) {
                    Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
                        Icon(
                            if (peer.linkUp) Icons.Filled.Sensors else Icons.Filled.SensorsOff, contentDescription = null,
                            tint = if (peer.linkUp) GhostTheme.bluetooth else GhostTheme.muted, modifier = Modifier.size(20.dp),
                        )
                        Text(peer.label, style = GhostTheme.body, color = GhostTheme.text, modifier = Modifier.weight(1f))
                        Switch(
                            checked = peer.linkUp,
                            onCheckedChange = { controls.setPeerLink?.invoke(peer.id, it) },
                            enabled = controls.setPeerLink != null,
                            colors = SwitchDefaults.colors(checkedTrackColor = GhostTheme.bluetooth),
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun ActiveCard(scenario: VizScenarioState, stop: (() -> Unit)?) {
    Column(Modifier.fillMaxWidth().ghostCard(), verticalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Text(
                if (scenario.isRunning) "RUNNING" else "FINISHED",
                style = GhostTheme.caption.copy(letterSpacing = GhostTheme.tracking),
                color = if (scenario.isRunning) GhostTheme.simulation else GhostTheme.muted,
            )
            Spacer(Modifier.weight(1f))
            Text(ScenarioPanel.clock(scenario.elapsed), style = GhostTheme.number(17, FontWeight.Bold), color = GhostTheme.text)
        }
        Text(scenario.name, style = GhostTheme.title, color = GhostTheme.text)
        scenario.caption?.let { Text(it, style = GhostTheme.body, color = GhostTheme.simulation) }
        if (stop != null && scenario.isRunning) {
            Button(
                onClick = stop,
                modifier = Modifier.fillMaxWidth(),
                colors = ButtonDefaults.buttonColors(containerColor = GhostTheme.rejected, contentColor = Color.White),
            ) {
                Icon(Icons.Filled.Stop, contentDescription = null, modifier = Modifier.size(18.dp))
                Spacer(Modifier.size(6.dp))
                Text("Stop and restore real inputs")
            }
        }
    }
}

/** SwiftUI's menu-style Picker: the chosen peer's name, a menu of "not set" and every peer. */
@Composable
private fun PeerPicker(current: String, peers: List<VizScenarioControls.Peer>, onPick: (String) -> Unit) {
    var open by remember { mutableStateOf(false) }
    Box {
        TextButton(onClick = { open = true }) {
            Text(peers.firstOrNull { it.id == current }?.label ?: if (current.isEmpty()) "not set" else shortID(current), color = GhostTheme.text)
            Icon(Icons.Filled.ArrowDropDown, contentDescription = null, tint = GhostTheme.text)
        }
        DropdownMenu(expanded = open, onDismissRequest = { open = false }) {
            DropdownMenuItem(text = { Text("not set") }, onClick = { open = false; onPick("") })
            for (peer in peers) {
                DropdownMenuItem(text = { Text(peer.label) }, onClick = { open = false; onPick(peer.id) })
            }
        }
    }
}

@Composable
private fun PanelSection(title: String, footer: String?, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().ghostCard(), verticalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
        Text(title.uppercase(), style = GhostTheme.caption.copy(letterSpacing = GhostTheme.tracking), color = GhostTheme.muted)
        content()
        if (footer != null) Text(footer, style = TextStyle(fontSize = 12.sp), color = GhostTheme.muted)
    }
}

object ScenarioPanel {
    fun clock(seconds: Double): String {
        val s = maxOf(0, if (seconds.isFinite()) seconds.toInt() else 0)
        return vizFormat("%d:%02d", s / 60, s % 60)
    }
}

/** Full-width stripe over the map whenever injected inputs are in play. */
@Composable
fun SimulationBanner(scenario: VizScenarioState?, stop: (() -> Unit)?, modifier: Modifier = Modifier) {
    Box(modifier.fillMaxWidth().clip(RoundedCornerShape(10.dp)).background(GhostTheme.simulation)) {
        Row(
            Modifier.padding(horizontal = GhostTheme.gap3, vertical = 6.dp),
            horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Text(
                "SIMULATED INPUT",
                style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Black, letterSpacing = GhostTheme.tracking),
                color = Color.Black, maxLines = 1,
            )
            if (scenario != null) {
                Text(
                    "· ${scenario.name}", style = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.Bold), color = Color.Black,
                    maxLines = 1, modifier = Modifier.weight(1f, fill = false),
                )
                if (scenario.elapsed > 0) {
                    Text(ScenarioPanel.clock(scenario.elapsed), style = GhostTheme.number(13, FontWeight.Bold), color = Color.Black)
                }
            }
            Spacer(Modifier.weight(1f))
            if (stop != null) {
                Box(
                    Modifier
                        .clip(CircleShape)
                        .background(Color.Black.copy(alpha = 0.75f))
                        .clickable(onClick = stop)
                        .padding(6.dp)
                        .semantics { contentDescription = "Stop simulation" },
                ) {
                    Icon(Icons.Filled.Stop, contentDescription = null, tint = GhostTheme.simulation, modifier = Modifier.size(14.dp))
                }
            }
        }
        HazardStripes(Modifier.align(Alignment.BottomCenter).fillMaxWidth().height(4.dp))
    }
}
