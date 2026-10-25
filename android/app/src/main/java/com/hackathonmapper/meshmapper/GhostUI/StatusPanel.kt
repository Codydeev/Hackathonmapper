package com.hackathonmapper.meshmapper

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Movie
import androidx.compose.material.icons.filled.TouchApp
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.semantics.clearAndSetSemantics
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.PositionEstimate

/** Shown in the status card until the tracker has this phone (SwiftUI's `(title:, detail:)` tuple). */
data class StatusFallback(val title: String, val detail: String)

/**
 * The top card: this phone's verdict in one word-sized headline, why in one sentence, and where
 * its position comes from right now. Built to be read from two metres away.
 *
 * `problem` (Android only) is a missing-permission line from MeshModel, shown in red under the
 * verdict: Android can revoke Bluetooth or location at runtime.
 */
@Composable
fun StatusPanel(
    scene: VizScene,
    name: String,
    fallback: StatusFallback?,
    hint: String?,
    modifier: Modifier = Modifier,
    problem: String? = null,
) {
    Column(modifier.fillMaxWidth().ghostCard(), verticalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
        Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2), verticalAlignment = Alignment.CenterVertically) {
            Text(
                name.uppercase(),
                style = GhostTheme.caption.copy(letterSpacing = GhostTheme.tracking),
                color = GhostTheme.muted,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            val me = scene.me
            val age = me?.age(scene.now)
            if (me != null && age != null && (me.kind == PositionEstimate.Kind.predicted || age >= 5)) {
                Text(
                    "${VizPresentation.ageText(age)} old",
                    style = GhostTheme.number(13, FontWeight.Bold),
                    color = if (me.kind == PositionEstimate.Kind.predicted) GhostTheme.predicted else GhostTheme.muted,
                )
            }
            if (scene.anySimulated) SimBadge()
        }

        val me = scene.me
        if (me != null) {
            Verdict(me, scene)
        } else if (fallback != null) {
            Text(fallback.title, style = GhostTheme.title, color = GhostTheme.muted)
            if (fallback.detail.isNotEmpty()) {
                Text(fallback.detail, style = GhostTheme.small, color = GhostTheme.text)
            }
        }

        if (problem != null) {
            Text(problem, style = GhostTheme.small.copy(fontWeight = FontWeight.SemiBold), color = GhostTheme.rejected)
        }
        scene.scenario?.caption?.let { caption ->
            GhostLabel(caption, Icons.Filled.Movie, GhostTheme.small.copy(fontWeight = FontWeight.SemiBold), GhostTheme.simulation)
        }
        if (hint != null) {
            GhostLabel(hint, Icons.Filled.TouchApp, GhostTheme.small.copy(fontWeight = FontWeight.SemiBold), GhostTheme.suspect)
        }
    }
}

@Composable
private fun Verdict(me: VizPhone, scene: VizScene) {
    val shown = VizPresentation.of(me, scene)
    val integrity = me.integrity
    val gpsRefused = integrity?.status in listOf(
        IntegrityAssessment.Status.rejected, IntegrityAssessment.Status.suspect, IntegrityAssessment.Status.degraded,
    )
    if (gpsRefused && me.kind != PositionEstimate.Kind.measured && integrity != null) {
        // GPS was refused and something else places this phone: lead with the refusal.
        val rejected = integrity.status == IntegrityAssessment.Status.rejected
        Text(
            if (rejected) "GPS REJECTED" else "GPS IN DOUBT",
            style = GhostTheme.headline,
            color = if (rejected) GhostTheme.rejected else GhostTheme.suspect,
        )
        integrity.headline?.let {
            Text(it, style = GhostTheme.body.copy(fontWeight = FontWeight.SemiBold), color = GhostTheme.text)
        }
        SourceLine(me, shown, scene)
    } else {
        GhostFitText(shown.title.uppercase(), GhostTheme.headline, GhostMarker.color(shown.tint), minimumScaleFactor = 0.6f)
        StatusPanel.detailLine(me, shown, scene)?.let {
            Text(it, style = GhostTheme.body.copy(fontWeight = FontWeight.SemiBold), color = GhostTheme.text)
        }
    }
    val evidence = me.integrity?.evidence
    if (!evidence.isNullOrEmpty()) EvidenceStrip(evidence)
}

@Composable
private fun SourceLine(me: VizPhone, shown: VizPresentation, scene: VizScene) {
    val style = GhostTheme.number(15, FontWeight.SemiBold)
    Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1)) {
        Text("Position from:", style = style, color = GhostTheme.muted, maxLines = 1)
        GhostFitText(
            if (me.kind == PositionEstimate.Kind.unavailable) "nothing yet: no trusted GPS, no peer in reach" else shown.title,
            style, GhostMarker.color(shown.tint), Modifier.weight(1f, fill = false),
        )
        val age = me.age(scene.now)
        if (me.kind == PositionEstimate.Kind.predicted && age != null) {
            Text("· ${VizPresentation.ageText(age)}", style = style, color = GhostTheme.muted, maxLines = 1)
        }
    }
}

object StatusPanel {
    fun detailLine(me: VizPhone, shown: VizPresentation, scene: VizScene): String? = when (me.kind) {
        PositionEstimate.Kind.estimated -> {
            val via = if (me.method.isBluetooth) strongestPlacedPeer(me.id, scene)?.let { "via $it" } else null
            listOfNotNull(via, me.hops?.let { VizPresentation.hopText(it) }).joinToString(" · ")
        }
        PositionEstimate.Kind.predicted -> {
            val r = me.prediction?.r95?.let { "±${vizRound(it)} m and growing" } ?: "movement model cloud"
            listOfNotNull(shown.detail, r).joinToString(" · ")
        }
        else -> shown.detail
    }

    /** The live, placed peer with the strongest link to `id`: who this phone is located from. */
    fun strongestPlacedPeer(id: String, scene: VizScene): String? {
        val placed = scene.phones.filter {
            it.kind == PositionEstimate.Kind.measured || it.kind == PositionEstimate.Kind.declared ||
                it.kind == PositionEstimate.Kind.estimated
        }.map { it.id }.toSet()
        val link = scene.links
            .filter { (it.a == id && it.b in placed) || (it.b == id && it.a in placed) }
            .maxByOrNull { it.rssi } ?: return null
        return scene.phone(if (link.a == id) link.b else link.a)?.label
    }
}

/** One segment per integrity check, coloured by its score: the lie-detector strip. */
@Composable
fun EvidenceStrip(evidence: List<VizEvidence>) {
    val description = evidence.joinToString(", ") { "${EvidenceStrip.shortName(it.check)} ${(it.score * 100).toInt()}%" }
    Row(
        Modifier.fillMaxWidth().clearAndSetSemantics { contentDescription = description },
        horizontalArrangement = Arrangement.spacedBy(3.dp),
        verticalAlignment = Alignment.Top,
    ) {
        for (item in evidence) {
            Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                Box(Modifier.fillMaxWidth().height(6.dp).background(EvidenceStrip.color(item.score), RoundedCornerShape(2.dp)))
                GhostFitText(
                    EvidenceStrip.shortName(item.check),
                    TextStyle(fontSize = 10.sp, fontWeight = FontWeight.SemiBold),
                    GhostTheme.muted,
                )
            }
        }
    }
}

object EvidenceStrip {
    fun color(score: Double): Color =
        if (score >= 0.7) GhostTheme.confirmed else if (score >= 0.4) GhostTheme.suspect else GhostTheme.rejected

    private val known = mapOf(
        "freshness" to "age", "accuracy" to "accuracy", "timing" to "timing", "speed" to "speed",
        "acceleration" to "accel", "jump" to "jump", "inertial" to "motion", "peerProximity" to "peers",
        "anchorProximity" to "anchor", "positionEvidence" to "position",
    )

    /** Contract check names ("peerProximity") to one short word; keeps the strip one line on a phone. */
    fun shortName(check: String): String {
        known[check]?.let { return it }
        return check.replace(Regex("([a-z])([A-Z])"), "$1 $2").lowercase()
    }
}

/** Colour key, one line above the controls. */
@Composable
fun GhostLegend(
    /** Without trust checks no GPS is ever trusted, so the key shows what is on the map instead. */
    integrityConnected: Boolean,
) {
    val style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.SemiBold, color = GhostTheme.text)
    Row(
        Modifier
            .background(GhostTheme.surface, CircleShape)
            .padding(horizontal = GhostTheme.gap3, vertical = 6.dp),
        horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap3),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        if (integrityConnected) {
            LegendItem(GhostTheme.confirmed, "GPS trusted", filled = true, style)
        } else {
            LegendItem(GhostTheme.unchecked, "GPS not checked", filled = true, style)
        }
        LegendItem(GhostTheme.bluetooth, "Estimate", filled = true, style)
        LegendItem(GhostTheme.predicted, "Predicted", filled = false, style)
        Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1), verticalAlignment = Alignment.CenterVertically) {
            Icon(Icons.Filled.Close, contentDescription = null, tint = GhostTheme.rejected, modifier = Modifier.size(12.dp))
            Text("Rejected", style = style, maxLines = 1)
        }
        Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1), verticalAlignment = Alignment.CenterVertically) {
            Box(Modifier.width(12.dp).height(3.dp).background(GhostTheme.route))
            Text("Relay", style = style, maxLines = 1)
        }
    }
}

@Composable
private fun LegendItem(color: Color, text: String, filled: Boolean, style: TextStyle) {
    Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1), verticalAlignment = Alignment.CenterVertically) {
        Canvas(Modifier.size(9.dp)) {
            if (filled) {
                drawCircle(color)
            } else {
                drawCircle(
                    color, size.minDimension / 2 - 0.75.dp.toPx(),
                    style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(2.dp.toPx(), 2.dp.toPx()))),
                )
            }
        }
        Text(text, style = style, maxLines = 1)
    }
}

/** SwiftUI `Label(text, systemImage:)`: an icon and a line of text in one colour. */
@Composable
internal fun GhostLabel(text: String, icon: ImageVector, style: TextStyle, color: Color, modifier: Modifier = Modifier) {
    Row(modifier, horizontalArrangement = Arrangement.spacedBy(6.dp), verticalAlignment = Alignment.CenterVertically) {
        Icon(icon, contentDescription = null, tint = color, modifier = Modifier.size(18.dp))
        Text(text, style = style, color = color)
    }
}

