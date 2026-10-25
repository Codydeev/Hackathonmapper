package com.hackathonmapper.meshmapper

import androidx.compose.foundation.background
import androidx.compose.foundation.border
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Cancel
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.SwapHoriz
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.PositionEstimate
import java.util.Locale
import kotlin.math.PI
import kotlin.math.atan2
import kotlin.math.hypot
import kotlin.math.max

/** Raw GPS next to the GhostCore estimate for one phone, with how far apart they are. */
@Composable
fun CompareCard(phone: VizPhone, scene: VizScene, modifier: Modifier = Modifier) {
    val fix = phone.comparedFix ?: return
    val status = phone.integrity?.status
    val shown = VizPresentation.of(phone, scene)
    val estimate = scene.drawnPoint(phone.id)
    val apart = estimate?.let { hypot(it.x - fix.point.x, it.z - fix.point.z) }
    Row(modifier.fillMaxWidth().ghostCard(), horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap3), verticalAlignment = Alignment.Top) {
        CompareColumn(
            title = "RAW GPS", value = "claims ±${vizRound(fix.claimedR95)} m",
            verdict = CompareCard.verdict(status), tint = CompareCard.tint(status),
            age = max(0.0, scene.now - fix.observedAt), simulated = fix.simulated, modifier = Modifier.weight(1f),
        )
        val middle = apart?.let { if (it > max(fix.claimedR95, phone.r95 ?: 0.0)) GhostTheme.rejected else GhostTheme.muted } ?: GhostTheme.muted
        Column(Modifier.widthIn(min = 64.dp), horizontalAlignment = Alignment.CenterHorizontally, verticalArrangement = Arrangement.spacedBy(2.dp)) {
            Icon(Icons.Filled.SwapHoriz, contentDescription = null, tint = middle, modifier = Modifier.size(16.dp))
            if (apart != null) {
                Text("${vizRound(apart)} m", style = GhostTheme.number(20, FontWeight.ExtraBold), color = middle)
                if (apart >= 10 && estimate != null) {
                    Text(CompareCard.direction(estimate, fix.point), style = GhostTheme.caption, color = middle)
                }
            }
        }
        CompareColumn(
            title = "GHOSTCORE", value = shown.title,
            verdict = if (phone.kind == PositionEstimate.Kind.unavailable) "NO POSITION" else if (shown.live) "IN USE" else "NOT LIVE",
            tint = GhostMarker.color(shown.tint), age = phone.age(scene.now), simulated = phone.simulated, modifier = Modifier.weight(1f),
        )
    }
}

@Composable
private fun CompareColumn(title: String, value: String, verdict: String, tint: Color, age: Double?, simulated: Boolean, modifier: Modifier) {
    Column(modifier, verticalArrangement = Arrangement.spacedBy(2.dp)) {
        Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1), verticalAlignment = Alignment.CenterVertically) {
            Text(title, style = GhostTheme.caption.copy(letterSpacing = GhostTheme.tracking), color = GhostTheme.muted, maxLines = 1)
            if (simulated) SimBadge(compact = true)
        }
        Text(verdict, style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.ExtraBold), color = tint)
        GhostFitText(value, GhostTheme.number(14, FontWeight.SemiBold), GhostTheme.text)
        Text(age?.let { "${VizPresentation.ageText(it)} old" } ?: "—", style = GhostTheme.number(13), color = GhostTheme.muted)
    }
}

object CompareCard {
    /** null = no trust verdict exists for this fix. */
    fun verdict(status: VizIntegrityStatus?): String = when (status) {
        IntegrityAssessment.Status.trusted -> "TRUSTED"
        IntegrityAssessment.Status.degraded -> "DEGRADED"
        IntegrityAssessment.Status.suspect -> "SUSPECT"
        IntegrityAssessment.Status.rejected -> "REJECTED"
        IntegrityAssessment.Status.insufficientEvidence -> "UNCONFIRMED"
        IntegrityAssessment.Status.unavailable -> "NO FIX"
        null -> "NOT CHECKED"
    }

    fun tint(status: VizIntegrityStatus?): Color = when (status) {
        IntegrityAssessment.Status.trusted -> GhostTheme.confirmed
        IntegrityAssessment.Status.degraded, IntegrityAssessment.Status.suspect,
        IntegrityAssessment.Status.insufficientEvidence -> GhostTheme.suspect
        IntegrityAssessment.Status.rejected -> GhostTheme.rejected
        IntegrityAssessment.Status.unavailable, null -> GhostTheme.muted
    }

    /** Compass direction of `b` seen from `a` (x east, z north). */
    fun direction(a: FloorPoint, b: FloorPoint): String {
        val degrees = ((atan2(b.x - a.x, b.z - a.z) * 180 / PI + 360) % 360)
        val names = listOf("N", "NE", "E", "SE", "S", "SW", "W", "NW")
        return names[((degrees + 22.5) / 45).toInt() % 8]
    }
}

/**
 * Everything known about one phone: verdict, why, the evidence and where its position comes from.
 * Shown in a bottom sheet; the header row stands in for SwiftUI's navigation bar with "Done".
 */
@Composable
fun TrustExplainer(phoneId: String, scene: VizScene, close: () -> Unit) {
    val phone = scene.phone(phoneId)
    Column(Modifier.fillMaxSize().background(Color.Black)) {
        GhostSheetBar(phone?.label ?: "Phone", close)
        Column(Modifier.fillMaxWidth().verticalScroll(rememberScrollState())) {
            if (phone != null) {
                ExplainerContent(phone, scene)
            } else {
                Text(
                    "This phone is no longer in reach.",
                    style = GhostTheme.body, color = GhostTheme.muted, modifier = Modifier.padding(GhostTheme.gap6),
                )
            }
        }
    }
}

@Composable
private fun ExplainerContent(phone: VizPhone, scene: VizScene) {
    val shown = VizPresentation.of(phone, scene)
    val status = phone.integrity?.status
    // GPS refused and something else (or nothing) places the phone: lead with the refusal.
    val refused = phone.kind != PositionEstimate.Kind.measured &&
        (status == IntegrityAssessment.Status.rejected || status == IntegrityAssessment.Status.suspect)
    val headline = if (refused) (if (status == IntegrityAssessment.Status.rejected) "GPS rejected" else "GPS suspect") else shown.title
    val headlineTint = if (refused) {
        if (status == IntegrityAssessment.Status.rejected) GhostTheme.rejected else GhostTheme.suspect
    } else {
        GhostMarker.color(shown.tint)
    }
    Column(Modifier.padding(GhostTheme.gap4), verticalArrangement = Arrangement.spacedBy(GhostTheme.gap4)) {
        Column(verticalArrangement = Arrangement.spacedBy(GhostTheme.gap1)) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                GhostFitText(headline, GhostTheme.headline, headlineTint, Modifier.weight(1f, fill = false), minimumScaleFactor = 0.6f)
                Spacer(Modifier.weight(1f))
                if (phone.simulated || phone.integrity?.simulated == true || phone.prediction?.simulated == true) SimBadge()
            }
            if (refused) {
                Text("Position from: ${shown.title}", style = GhostTheme.body, color = GhostMarker.color(shown.tint))
            } else {
                shown.detail?.let { Text(it, style = GhostTheme.body, color = GhostTheme.text) }
            }
        }

        CompareCard(phone, scene)

        ExplainerSection("Why") {
            val integrity = phone.integrity
            integrity?.summary?.let {
                Text(it, style = GhostTheme.body.copy(fontWeight = FontWeight.SemiBold), color = GhostTheme.text)
            }
            if (integrity != null && integrity.reasons.isNotEmpty()) {
                for (reason in integrity.reasons) {
                    Row(horizontalArrangement = Arrangement.spacedBy(6.dp)) {
                        Icon(Icons.Filled.Warning, contentDescription = null, tint = GhostTheme.text, modifier = Modifier.size(18.dp).padding(top = 2.dp))
                        Text(reason.text, style = GhostTheme.body, color = GhostTheme.text)
                    }
                }
            } else if (integrity != null && integrity.status == IntegrityAssessment.Status.trusted) {
                Text("Every check passed.", style = GhostTheme.body, color = GhostTheme.text)
            } else if (phone.method != PositionEstimate.Method.gnss && integrity == null) {
                Text("No GPS to judge: this phone is placed by ${phone.method.title}.", style = GhostTheme.body, color = GhostTheme.text)
            } else {
                Text(
                    if (scene.integrityConnected) {
                        "No trust verdict for this fix yet."
                    } else {
                        "Trust checks are not connected on this build; GPS is shown as not checked."
                    },
                    style = GhostTheme.body, color = GhostTheme.muted,
                )
            }
        }

        val evidence = phone.integrity?.evidence
        if (!evidence.isNullOrEmpty()) {
            ExplainerSection("Evidence") {
                val integrity = phone.integrity
                integrity?.trustScore?.let { score ->
                    Row(verticalAlignment = Alignment.CenterVertically) {
                        Text("Trust score", style = GhostTheme.small, color = GhostTheme.muted)
                        Spacer(Modifier.weight(1f))
                        Text(
                            TrustExplainer.scoreText(score, integrity.trustLower),
                            style = GhostTheme.number(17, FontWeight.Bold), color = EvidenceStrip.color(score),
                        )
                    }
                }
                if (integrity != null) {
                    Text(
                        TrustExplainer.offsetText(integrity.minimumDetectableOffset),
                        style = GhostTheme.small,
                        color = if (integrity.minimumDetectableOffset == null) GhostTheme.suspect else GhostTheme.text,
                    )
                }
                for (item in evidence) EvidenceRow(item)
            }
        }

        phone.likelyPaths?.let { paths ->
            ExplainerSection("Likely paths (prediction)") {
                for (option in paths.options) {
                    Row {
                        Text(
                            "${vizRound(option.probability * 100)} %", style = GhostTheme.number(15, FontWeight.Bold),
                            color = GhostTheme.text, modifier = Modifier.width(48.dp),
                        )
                        Text(option.text, style = GhostTheme.small, color = GhostTheme.text)
                    }
                }
                if (paths.offPath >= 0.01) {
                    Text("${vizRound(paths.offPath * 100)} % chance they left the paths", style = TextStyle(fontSize = 13.sp), color = GhostTheme.muted)
                }
                Text(
                    "From the route model trained on walking tracks around Hervanta; it walks the bundled path graph from the last placed spot.",
                    style = TextStyle(fontSize = 13.sp), color = GhostTheme.muted,
                )
            }
        }

        if (phone.inputs.isNotEmpty()) {
            ExplainerSection("Inputs") {
                for (item in phone.inputs) {
                    Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
                        Icon(
                            if (item.used) Icons.Filled.CheckCircle else Icons.Filled.Cancel, contentDescription = null,
                            tint = if (item.used) GhostTheme.confirmed else GhostTheme.rejected, modifier = Modifier.size(18.dp),
                        )
                        Column(Modifier.weight(1f), verticalArrangement = Arrangement.spacedBy(2.dp)) {
                            Text(
                                TrustExplainer.inputTitle(item, scene),
                                style = GhostTheme.small.copy(fontWeight = FontWeight.SemiBold), color = GhostTheme.text,
                            )
                            item.reason?.let { reason ->
                                Text(
                                    (if (item.used) "" else "not used: ") + VizReason.sentence(reason, null),
                                    style = TextStyle(fontSize = 13.sp), color = GhostTheme.muted,
                                )
                            }
                        }
                        item.age?.let { Text(VizPresentation.ageText(it), style = GhostTheme.number(13), color = GhostTheme.muted) }
                    }
                }
            }
        }

        ExplainerSection("Where the position comes from") {
            Fact("Kind", phone.kind.rawValue)
            Fact("Method", phone.method.title)
            phone.r95?.let { Fact("95% radius", "±${vizRound(it)} m") }
            if (phone.ambiguous) Fact("Ambiguous", "${max(phone.candidates.size, 2)} candidate spots")
            phone.age(scene.now)?.let { Fact("Last measured", "${VizPresentation.ageText(it)} ago") }
            phone.hops?.let { Fact("From GPS", VizPresentation.hopText(it)) }
            scene.routes.firstOrNull { it.origin == phone.id }?.let { Fact("Report travelled", TrustExplainer.routeText(it, scene)) }
            phone.prediction?.let { prediction ->
                Fact("Predicting for", VizPresentation.ageText(prediction.horizon))
                prediction.r95?.let { Fact("Predicted radius", "±${vizRound(it)} m") }
            }
        }

        Text(TrustExplainer.honesty, style = TextStyle(fontSize = 13.sp), color = GhostTheme.muted)
    }
}

@Composable
private fun EvidenceRow(item: VizEvidence) {
    Column(verticalArrangement = Arrangement.spacedBy(GhostTheme.gap1)) {
        Row(verticalAlignment = Alignment.CenterVertically, horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1)) {
            Text(
                EvidenceStrip.shortName(item.check).replaceFirstChar { it.titlecase(Locale.US) }
                    .split(" ").joinToString(" ") { w -> w.replaceFirstChar { it.titlecase(Locale.US) } },
                style = GhostTheme.small.copy(fontWeight = FontWeight.SemiBold), color = GhostTheme.text,
            )
            if (!item.independent) {
                Text(
                    "uses GPS",
                    style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.SemiBold), color = GhostTheme.muted,
                    modifier = Modifier.border(1.dp, GhostTheme.border, RoundedCornerShape(4.dp)).padding(horizontal = 4.dp),
                )
            }
            Spacer(Modifier.weight(1f))
            Text(TrustExplainer.measure(item), style = GhostTheme.number(15), color = GhostTheme.muted)
        }
        Box(Modifier.fillMaxWidth().height(6.dp).background(GhostTheme.surfaceRaised, CircleShape)) {
            Box(
                Modifier
                    .fillMaxWidth(item.score.coerceIn(0.03, 1.0).toFloat())
                    .height(6.dp)
                    .background(EvidenceStrip.color(item.score), CircleShape),
            )
        }
    }
}

@Composable
private fun ExplainerSection(title: String, content: @Composable ColumnScope.() -> Unit) {
    Column(Modifier.fillMaxWidth().ghostCard(), verticalArrangement = Arrangement.spacedBy(GhostTheme.gap2)) {
        Text(title.uppercase(), style = GhostTheme.caption.copy(letterSpacing = GhostTheme.tracking), color = GhostTheme.muted)
        content()
    }
}

@Composable
private fun Fact(name: String, value: String) {
    Row {
        Text(name, style = GhostTheme.number(15), color = GhostTheme.muted)
        Spacer(Modifier.weight(1f).widthIn(min = GhostTheme.gap2))
        Text(value, style = GhostTheme.number(15), color = GhostTheme.text, textAlign = TextAlign.End)
    }
}

/** A sheet's top bar: the title centred and "Done" on the right, like SwiftUI's inline navigation bar. */
@Composable
internal fun GhostSheetBar(title: String, close: () -> Unit) {
    Box(Modifier.fillMaxWidth().padding(horizontal = GhostTheme.gap2, vertical = GhostTheme.gap1)) {
        Text(
            title,
            style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold),
            color = GhostTheme.text,
            maxLines = 1,
            modifier = Modifier.align(Alignment.Center).padding(horizontal = 72.dp),
        )
        TextButton(onClick = close, modifier = Modifier.align(Alignment.CenterEnd)) {
            Text("Done", style = TextStyle(fontSize = 17.sp, fontWeight = FontWeight.SemiBold), color = GhostTheme.bluetooth)
        }
    }
}

object TrustExplainer {
    fun inputTitle(item: VizInput, scene: VizScene): String {
        val who = item.deviceId?.let { if (it == scene.selfId) "This phone" else (scene.phone(it)?.label ?: shortID(it)) }
        val what = if (item.source == "gnss") "GPS" else item.source.replaceFirstChar { it.titlecase(Locale.US) }
        return listOfNotNull(who, what).joinToString(" · ")
    }

    fun scoreText(score: Double, lower: Double?): String {
        val upper = vizRound(score * 100)
        if (lower == null || lower >= score - 0.005) return "$upper / 100"
        return "${vizRound(lower * 100)}–$upper / 100"
    }

    /** The honest bound: how far GPS could move this phone before any independent check would notice. */
    fun offsetText(meters: Double?): String {
        if (meters == null) return "No independent check active: a slow GPS offset would go unnoticed."
        return "GPS could move this phone by up to ${vizRound(meters)} m unnoticed."
    }

    fun routeText(route: VizRoute, scene: VizScene): String {
        val names = (listOf(route.origin) + route.relays).map { scene.phone(it)?.label ?: it.take(6) }
        return (names + listOf("you")).joinToString(" → ")
    }

    fun measure(item: VizEvidence): String {
        fun number(v: Double): String = if (v >= 100) "${vizRound(v)}" else vizFormat("%.1f", v)
        val unit = if (item.unit.isEmpty()) "" else " ${item.unit}"
        val o = item.observed
        val t = item.threshold
        return when {
            o != null && t != null -> "${number(o)}$unit vs limit ${number(t)}$unit"
            o != null -> "${number(o)}$unit"
            t != null -> "limit ${number(t)}$unit"
            else -> "—"
        }
    }

    const val honesty = "Estimates (Bluetooth, dead reckoning, fused) and predictions are computed, not measured, and carry their 95% radius. " +
        "Predicted positions are model output and grey out with age. Items marked SIMULATED come from injected raw " +
        "inputs; the pipeline's response to them is computed live."
}
