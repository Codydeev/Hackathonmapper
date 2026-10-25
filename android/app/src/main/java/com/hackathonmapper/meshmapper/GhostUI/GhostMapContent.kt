package com.hackathonmapper.meshmapper

import androidx.compose.foundation.layout.Box
import androidx.compose.runtime.Composable
import androidx.compose.runtime.key
import androidx.compose.ui.Modifier
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.StrokeCap
import androidx.compose.ui.graphics.StrokeJoin
import androidx.compose.ui.graphics.drawscope.DrawScope
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.layout.layout
import com.hackathonmapper.meshcore.FloorPoint
import com.hackathonmapper.meshcore.IntegrityAssessment
import com.hackathonmapper.meshcore.PositionEstimate
import kotlin.math.hypot
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Everything GhostCore draws on the map, bottom to top: Bluetooth links, relay routes, uncertainty
 * (circles, candidate rings, particle and prediction clouds), raw GPS the trust checks refused, and
 * the phones themselves.
 *
 * MapKit's `MapContent` becomes two layers on Android: [draw] paints the overlays (polylines and
 * circles, sized in metres) on the map's Canvas, and [Annotations] places the markers, tags and
 * refused-fix crosses as composables centred on their points, above the Canvas like MapKit's
 * annotations. `screen` maps a point of the shared frame (metres, x east, z north) to the canvas.
 */
class GhostMapContent(
    val scene: VizScene,
    val selectedId: String?,
    val onSelect: (String) -> Unit,
) {
    // MARK: - Overlays

    fun draw(scope: DrawScope, screen: (FloorPoint) -> Offset, metersPerPixel: Double) {
        with(scope) {
            for (link in scene.links) {
                val a = scene.drawnPoint(link.a) ?: continue
                val b = scene.drawnPoint(link.b) ?: continue
                polyline(
                    listOf(screen(a), screen(b)), Color.White.copy(alpha = linkOpacity(link.rssi).toFloat()), 1.5f,
                    dash = floatArrayOf(3f, 5f),
                )
            }

            for (route in scene.routes.filter { it.relays.isNotEmpty() }) {
                val hops = (listOf(route.origin) + route.relays + listOf(scene.selfId)).mapNotNull { scene.drawnPoint(it)?.let(screen) }
                if (hops.size >= 2) {
                    polyline(hops, GhostTheme.route.copy(alpha = 0.85f), 3f, dash = floatArrayOf(10f, 6f), round = true)
                }
            }

            for (phone in scene.phones) uncertainty(phone, screen, metersPerPixel)
            for (phone in scene.phones) likelyPaths(phone, screen)
            for (phone in scene.phones) rawFixGhost(phone, screen, metersPerPixel)
        }
    }

    private fun DrawScope.uncertainty(phone: VizPhone, screen: (FloorPoint) -> Offset, mpp: Double) {
        val tint = GhostMarker.color(VizPresentation.of(phone, scene).tint)
        val prediction = phone.prediction
        val point = phone.point
        if (phone.kind == PositionEstimate.Kind.predicted && prediction != null) {
            for (p in prediction.cloud.take(80)) {
                drawCircle(GhostTheme.predicted.copy(alpha = 0.55f), meters(1.3, mpp), screen(p))
            }
            val r95 = prediction.r95
            if (r95 != null && r95 > 0) {
                circle(screen(prediction.center), meters(r95, mpp), GhostTheme.predicted.copy(alpha = 0.08f),
                    GhostTheme.predicted.copy(alpha = 0.8f), 1.5f, floatArrayOf(6f, 5f))
            }
        } else if (phone.ambiguous && phone.candidates.isNotEmpty()) {
            // An estimate that cannot pick between spots: one ring per candidate, no single dot.
            for (p in phone.candidates) {
                circle(screen(p), meters(max(phone.r95 ?: 8.0, 4.0) / 2, mpp), tint.copy(alpha = 0.10f),
                    tint.copy(alpha = 0.9f), 2f, floatArrayOf(4f, 4f))
            }
        } else if (point != null) {
            for (p in phone.cloud) drawCircle(tint.copy(alpha = 0.45f), meters(0.9, mpp), screen(p))
            val r95 = phone.r95
            if (r95 != null && r95 > 0) {
                circle(screen(point), meters(r95, mpp), tint.copy(alpha = 0.12f), tint.copy(alpha = 0.85f), 1.5f, null)
            }
        }
    }

    /**
     * Route-model guesses for a predicted phone: each route dashed and grey (a prediction, so it
     * never looks live), more opaque the likelier it is, over the 10-90 % stretch they have probably
     * covered, with a percentage where they probably are by now (the tag is an annotation).
     */
    private fun DrawScope.likelyPaths(phone: VizPhone, screen: (FloorPoint) -> Offset) {
        val paths = phone.likelyPaths ?: return
        for (option in paths.options) {
            val strength = pathOpacity(option.rank).toFloat()
            val band = option.band.map(screen)
            if (band.size >= 2) {
                polyline(band, GhostTheme.predicted.copy(alpha = 0.28f * strength), 14f, round = true)
            }
            val line = option.line.map(screen)
            if (line.size >= 2) {
                polyline(line, GhostTheme.unchecked.copy(alpha = strength), if (option.rank == 0) 3f else 2f,
                    dash = floatArrayOf(8f, 6f), round = true)
            }
        }
    }

    /**
     * The raw GPS fix the trust checks judged, when it was refused or doubted and lies away from
     * where GhostCore puts the phone: a red ghost with a dashed line back to the estimate (the cross
     * itself is an annotation).
     */
    private fun DrawScope.rawFixGhost(phone: VizPhone, screen: (FloorPoint) -> Offset, mpp: Double) {
        val integrity = phone.integrity ?: return
        val fix = refusedFix(phone) ?: return
        val tint = if (integrity.status == IntegrityAssessment.Status.rejected) GhostTheme.rejected else GhostTheme.suspect
        val shown = scene.drawnPoint(phone.id)
        if (shown != null && hypot(shown.x - fix.point.x, shown.z - fix.point.z) > 3) {
            polyline(listOf(screen(fix.point), screen(shown)), tint.copy(alpha = 0.9f), 2f, dash = floatArrayOf(2f, 6f))
        }
        circle(screen(fix.point), meters(max(fix.claimedR95, 2.0), mpp), tint.copy(alpha = 0.10f), tint.copy(alpha = 0.7f), 1f,
            floatArrayOf(3f, 3f))
    }

    private fun refusedFix(phone: VizPhone): VizRawFix? {
        val integrity = phone.integrity ?: return null
        val refused = integrity.status == IntegrityAssessment.Status.rejected ||
            integrity.status == IntegrityAssessment.Status.suspect || integrity.status == IntegrityAssessment.Status.degraded
        return if (refused) integrity.evaluatedFix else null
    }

    // MARK: - Annotations

    /** Markers, route tags and refused-fix crosses; `project` is read at layout time, so panning only re-places them. */
    @Composable
    fun Annotations(project: (FloorPoint) -> Offset?) {
        for (phone in scene.phones) {
            val paths = phone.likelyPaths ?: continue
            for (option in paths.options) {
                val here = option.here ?: continue
                key("path", phone.id, option.rank) {
                    Box(Modifier.centeredAt { project(here) }) {
                        PathTag(option.probability, option.rank, phone.simulated) { onSelect(phone.id) }
                    }
                }
            }
        }

        for (phone in scene.phones) {
            val integrity = phone.integrity ?: continue
            val fix = refusedFix(phone) ?: continue
            key("raw", phone.id) {
                Box(Modifier.centeredAt { project(fix.point) }) {
                    RawFixMarker(
                        label = if (phone.isSelf) "Raw GPS" else "${phone.label} raw GPS",
                        status = integrity.status, simulated = fix.simulated,
                    ) { onSelect(phone.id) }
                }
            }
        }

        for (phone in scene.phones) {
            val presentation = VizPresentation.of(phone, scene)
            if (phone.kind == PositionEstimate.Kind.estimated && phone.ambiguous && phone.candidates.isNotEmpty()) {
                // Ambiguous: a hollow ring at every candidate spot and no single dot; one label.
                phone.candidates.forEachIndexed { i, p ->
                    key("phone", phone.id, i) {
                        Box(Modifier.centeredAt { project(p) }) {
                            GhostMarker(
                                phone, presentation, selected = phone.id == selectedId, now = scene.now,
                                candidate = true, showsLabel = i == 0,
                            ) { onSelect(phone.id) }
                        }
                    }
                }
            } else {
                val point = scene.drawnPoint(phone.id) ?: continue
                key("phone", phone.id) {
                    Box(Modifier.centeredAt { project(point) }) {
                        GhostMarker(
                            phone, presentation, selected = phone.id == selectedId, now = scene.now,
                            candidate = phone.ambiguous,
                        ) { onSelect(phone.id) }
                    }
                }
            }
        }
    }

    companion object {
        fun pathOpacity(rank: Int): Double = listOf(0.95, 0.7, 0.5, 0.35)[rank.coerceIn(0, 3)]

        /** Stronger links draw brighter: -55 dBm and up fully, fading out by -95 dBm. */
        fun linkOpacity(rssi: Double): Double = 0.25 + 0.6 * minOf(1.0, maxOf(0.0, (rssi + 95) / 40))
    }
}

// MARK: - Geometry

/** A length in metres on the canvas, at least a hairline so tiny dots stay visible zoomed out. */
private fun DrawScope.meters(m: Double, mpp: Double): Float = max((m / mpp).toFloat(), 0.75f * density)

/** A polyline with widths and dashes in dp, like MapKit's `StrokeStyle` in points. */
private fun DrawScope.polyline(points: List<Offset>, color: Color, width: Float, dash: FloatArray? = null, round: Boolean = false) {
    if (points.size < 2) return
    val path = Path().apply {
        moveTo(points[0].x, points[0].y)
        for (p in points.drop(1)) lineTo(p.x, p.y)
    }
    drawPath(
        path, color,
        style = Stroke(
            width = width * density,
            cap = if (round) StrokeCap.Round else StrokeCap.Butt,
            join = if (round) StrokeJoin.Round else StrokeJoin.Miter,
            pathEffect = dash?.let { PathEffect.dashPathEffect(FloatArray(it.size) { i -> it[i] * density }) },
        ),
    )
}

/** MapKit's `MapCircle` with a fill and a (dashed) stroke. */
private fun DrawScope.circle(center: Offset, radius: Float, fill: Color, stroke: Color, width: Float, dash: FloatArray?) {
    drawCircle(fill, radius, center)
    drawCircle(
        stroke, radius, center,
        style = Stroke(width * density, pathEffect = dash?.let { PathEffect.dashPathEffect(FloatArray(it.size) { i -> it[i] * density }) }),
    )
}

/** Places the content centred on `position` (read at layout time); hidden while it is null. */
internal fun Modifier.centeredAt(position: () -> Offset?): Modifier = layout { measurable, constraints ->
    val placeable = measurable.measure(constraints.copy(minWidth = 0, minHeight = 0))
    layout(placeable.width, placeable.height) {
        val p = position() ?: return@layout
        placeable.place((p.x - placeable.width / 2f).roundToInt(), (p.y - placeable.height / 2f).roundToInt())
    }
}
