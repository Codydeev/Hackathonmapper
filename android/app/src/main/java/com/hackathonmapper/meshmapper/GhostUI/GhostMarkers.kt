package com.hackathonmapper.meshmapper

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.clickable
import androidx.compose.foundation.interaction.MutableInteractionSource
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Close
import androidx.compose.material3.Icon
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawBehind
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.Layout
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.Constraints
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.PositionEstimate

/**
 * A phone on the map: a dot whose fill says how it is placed, and a label with its honest kind.
 * Predicted phones are hollow, dashed and grey with their age, so they never pass for live.
 *
 * The composable's own size is the dot plus a 10 dp touch margin (SwiftUI's
 * `.contentShape(Circle().inset(by: -10))`), so the map centres it on the phone's point; the
 * label hangs outside it.
 */
@Composable
fun GhostMarker(
    phone: VizPhone,
    presentation: VizPresentation,
    selected: Boolean,
    now: Double,
    /** One spot of an ambiguous estimate: a hollow ring, never a filled dot. */
    candidate: Boolean = false,
    showsLabel: Boolean = true,
    onTap: () -> Unit = {},
) {
    val size: Dp = if (phone.isSelf) 26.dp else 18.dp
    val tint = GhostMarker.color(presentation.tint)
    val description = "${phone.label}, ${presentation.title}${presentation.detail?.let { ", $it" } ?: ""}"
    // This phone's label sits below its dot and everyone else's above, so two phones a few
    // metres apart do not stack their labels.
    GhostAnchoredLayout(
        anchor = {
            Box(
                Modifier
                    .size(size + 20.dp)
                    .clickable(remember { MutableInteractionSource() }, indication = null, onClick = onTap)
                    .semantics { contentDescription = description },
                contentAlignment = Alignment.Center,
            ) {
                Canvas(Modifier.size(size + 12.dp)) {
                    val r = size.toPx() / 2
                    // SwiftUI .shadow(color: .black.opacity(0.5), radius: 3)
                    drawCircle(Color.Black.copy(alpha = 0.35f), r + 2.dp.toPx(), center.copy(y = center.y + 1.dp.toPx()))
                    if (selected) {
                        drawCircle(GhostTheme.text, (size + 12.dp).toPx() / 2 - 1.dp.toPx(), style = Stroke(2.dp.toPx()))
                    }
                    when {
                        candidate -> {
                            drawCircle(GhostTheme.surface.copy(alpha = 0.6f), r)
                            drawCircle(
                                tint, r - 1.25.dp.toPx(),
                                style = Stroke(2.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(4.dp.toPx(), 3.dp.toPx()))),
                            )
                        }
                        presentation.live -> {
                            drawCircle(tint, r)
                            drawCircle(Color.White, r, style = Stroke((if (phone.isSelf) 3 else 2).dp.toPx()))
                        }
                        else -> {
                            drawCircle(GhostTheme.surface, r)
                            drawCircle(
                                tint, r - 1.25.dp.toPx(),
                                style = Stroke(2.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 3.dp.toPx()))),
                            )
                        }
                    }
                }
                if (candidate) {
                    Text("?", style = TextStyle(fontSize = (size.value * 0.6f).sp, fontWeight = FontWeight.Black), color = tint)
                }
            }
        },
        label = if (showsLabel) {
            { GhostMarkerLabel(phone, presentation, now) }
        } else {
            null
        },
        // Below the dot for this phone, above it for everyone else, 6 dp clear of the dot.
        labelTop = { anchorHeight, labelHeight, px ->
            val dotRadius = size.value / 2 * px
            if (phone.isSelf) anchorHeight / 2 + dotRadius + 6 * px else anchorHeight / 2 - dotRadius - 6 * px - labelHeight
        },
    )
}

@Composable
private fun GhostMarkerLabel(phone: VizPhone, presentation: VizPresentation, now: Double) {
    val tint = GhostMarker.color(presentation.tint)
    val shape = RoundedCornerShape(8.dp)
    Column(
        Modifier
            .background(GhostTheme.surface, shape)
            .border(1.dp, tint.copy(alpha = 0.5f), shape)
            .padding(horizontal = GhostTheme.gap2, vertical = GhostTheme.gap1),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.spacedBy(1.dp),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1), verticalAlignment = Alignment.CenterVertically) {
            Text(
                phone.label,
                style = TextStyle(fontSize = (if (phone.isSelf) 15 else 13).sp, fontWeight = FontWeight.Bold),
                color = GhostTheme.text,
                maxLines = 1,
            )
            if (phone.integrity?.status == IntegrityAssessment.Status.rejected && phone.kind != PositionEstimate.Kind.measured) {
                StatusChip("GPS ✕", GhostTheme.rejected)
            }
            if (phone.simulated || phone.integrity?.simulated == true || phone.prediction?.simulated == true) {
                SimBadge(compact = true)
            }
        }
        Text(GhostMarker.shortTitle(phone, presentation, now), style = GhostTheme.number(12, FontWeight.SemiBold), color = tint, maxLines = 1)
    }
}

object GhostMarker {
    /** The marker label stays short; the full sentence lives on the status card and explainer. */
    fun shortTitle(phone: VizPhone, presentation: VizPresentation, now: Double): String = when (phone.kind) {
        PositionEstimate.Kind.predicted ->
            "Predicted · ${phone.age(now)?.let { VizPresentation.ageText(it) } ?: "?"}"
        PositionEstimate.Kind.estimated -> {
            val r = phone.r95?.let { " ±${vizRound(it)} m" } ?: ""
            val what = if (phone.method.isBluetooth) "Bluetooth" else phone.method.estimateTitle
            if (phone.ambiguous) "$what · one of ${maxOf(phone.candidates.size, 2)} spots" else "$what$r"
        }
        else -> presentation.title
    }

    fun color(tint: VizPresentation.VizTint): Color = when (tint) {
        VizPresentation.VizTint.confirmed -> GhostTheme.confirmed
        VizPresentation.VizTint.unchecked -> GhostTheme.unchecked
        VizPresentation.VizTint.bluetooth -> GhostTheme.bluetooth
        VizPresentation.VizTint.predicted -> GhostTheme.predicted
        VizPresentation.VizTint.rejected -> GhostTheme.rejected
        VizPresentation.VizTint.suspect -> GhostTheme.suspect
        VizPresentation.VizTint.declared -> GhostTheme.declared
        VizPresentation.VizTint.unknown -> GhostTheme.muted
    }
}

/** The raw GPS fix that was refused or doubted: a red cross where the receiver claimed to be. */
@Composable
fun RawFixMarker(label: String, status: VizIntegrityStatus, simulated: Boolean, onTap: () -> Unit = {}) {
    val tint = if (status == IntegrityAssessment.Status.rejected) GhostTheme.rejected else GhostTheme.suspect
    val verdict = if (status == IntegrityAssessment.Status.rejected) "rejected" else "in doubt"
    GhostAnchoredLayout(
        anchor = {
            Box(
                Modifier
                    .size(26.dp)
                    .background(GhostTheme.surface, CircleShape)
                    .border(2.dp, tint, CircleShape)
                    .clickable(remember { MutableInteractionSource() }, indication = null, onClick = onTap)
                    .semantics { contentDescription = "$label, $verdict" },
                contentAlignment = Alignment.Center,
            ) {
                Icon(Icons.Filled.Close, contentDescription = null, tint = tint, modifier = Modifier.size(16.dp))
            }
        },
        label = {
            Column(
                Modifier
                    .background(GhostTheme.surface, RoundedCornerShape(6.dp))
                    .padding(horizontal = 6.dp, vertical = 2.dp),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(1.dp),
            ) {
                Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1), verticalAlignment = Alignment.CenterVertically) {
                    Text(label, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.Bold), color = tint, maxLines = 1)
                    if (simulated) SimBadge(compact = true)
                }
                Text(verdict, style = TextStyle(fontSize = 12.sp, fontWeight = FontWeight.ExtraBold), color = tint)
            }
        },
        // SwiftUI: overlay(alignment: .top) offset 30 pt from the cross's top.
        labelTop = { _, _, px -> 30 * px },
    )
}

/**
 * "65 %" where a lost phone has probably got to along one route: hollow and dashed like every
 * predicted thing on the map.
 */
@Composable
fun PathTag(probability: Double, rank: Int, simulated: Boolean, onTap: () -> Unit = {}) {
    val percent = vizRound(probability * 100)
    Row(
        Modifier
            .clickable(remember { MutableInteractionSource() }, indication = null, onClick = onTap)
            .semantics { contentDescription = "Predicted route, $percent percent" }
            .drawBehind {
                val radius = CornerRadius(size.height / 2)
                drawRoundRect(GhostTheme.surface, cornerRadius = radius)
                drawRoundRect(
                    GhostTheme.predicted, cornerRadius = radius,
                    style = Stroke(1.5.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(3.dp.toPx(), 2.dp.toPx()))),
                )
            }
            .padding(horizontal = 7.dp, vertical = 3.dp),
        horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap1),
        verticalAlignment = Alignment.CenterVertically,
    ) {
        val color = GhostTheme.text.copy(alpha = (GhostMapContent.pathOpacity(rank) + 0.05).toFloat().coerceAtMost(1f))
        Text("$percent %", style = GhostTheme.number(13, FontWeight.ExtraBold), color = color)
        if (simulated) SimBadge(compact = true)
    }
}

@Composable
fun StatusChip(text: String, tint: Color) {
    Text(
        text,
        style = TextStyle(fontSize = 11.sp, fontWeight = FontWeight.ExtraBold),
        color = Color.Black,
        maxLines = 1,
        modifier = Modifier
            .background(tint, RoundedCornerShape(4.dp))
            .padding(horizontal = 5.dp, vertical = 1.dp),
    )
}

/** Marks a record that came from injected inputs. */
@Composable
fun SimBadge(compact: Boolean = false) {
    Text(
        if (compact) "SIM" else "SIMULATED",
        style = TextStyle(fontSize = (if (compact) 10 else 12).sp, fontWeight = FontWeight.Black, letterSpacing = 0.5.sp),
        color = Color.Black,
        maxLines = 1,
        modifier = Modifier
            .background(GhostTheme.simulation, RoundedCornerShape(4.dp))
            .padding(horizontal = (if (compact) 4 else 6).dp, vertical = 1.dp)
            .semantics { contentDescription = "Simulated input" },
    )
}

/**
 * An annotation whose size is its anchor (so the map centres the anchor on the point) with an
 * optional label centred horizontally and placed at `labelTop` (px from the anchor's top), drawn
 * outside the anchor's bounds like a SwiftUI overlay with an offset.
 */
@Composable
internal fun GhostAnchoredLayout(
    anchor: @Composable () -> Unit,
    label: (@Composable () -> Unit)?,
    labelTop: (anchorHeight: Float, labelHeight: Float, px: Float) -> Float,
) {
    Layout(content = {
        anchor()
        label?.invoke()
    }) { measurables, constraints ->
        val loose = Constraints()
        val a = measurables[0].measure(constraints.copy(minWidth = 0, minHeight = 0))
        val l = measurables.getOrNull(1)?.measure(loose)
        layout(a.width, a.height) {
            l?.place(
                (a.width - l.width) / 2,
                labelTop(a.height.toFloat(), l.height.toFloat(), density).toInt(),
            )
            a.place(0, 0)
        }
    }
}
