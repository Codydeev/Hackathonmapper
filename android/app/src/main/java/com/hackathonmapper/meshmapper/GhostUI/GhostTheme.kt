package com.hackathonmapper.meshmapper

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.border
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.Path
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.TextUnit
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import androidx.compose.ui.unit.takeOrElse

// Design tokens for the GhostCore map. Every colour, size and gap in GhostUI comes from here.
//
// The map is dark and muted so the position colours carry the meaning from two metres away:
//   confirmed  green   GPS that passed the trust checks
//   unchecked  white   GPS with no trust verdict (never shown green)
//   bluetooth  sky     placed from Bluetooth peers (always drawn with its ±r95 circle)
//   predicted  grey    nothing measured right now; dashed, with an age, never looks live
//   rejected   red     raw GPS the trust engine refused
//   suspect    amber   GPS in use with doubts, or checks still running
//   declared   violet  a spot someone typed or pinned
// Signature: the evidence strip, one segment per integrity check, under the verdict headline.
object GhostTheme {
    val surface = Color(0.07f, 0.08f, 0.10f).copy(alpha = 0.92f)
    val surfaceRaised = Color(0.12f, 0.13f, 0.16f)
    val border = Color.White.copy(alpha = 0.10f)
    val text = Color(0.95f, 0.96f, 0.97f)
    val muted = Color(0.62f, 0.65f, 0.70f)

    val confirmed = Color(0.24f, 0.86f, 0.52f)
    val unchecked = Color(0.88f, 0.90f, 0.93f)
    val bluetooth = Color(0.31f, 0.76f, 0.97f)
    val predicted = Color(0.56f, 0.59f, 0.64f)
    val rejected = Color(1.00f, 0.35f, 0.37f)
    val suspect = Color(1.00f, 0.69f, 0.13f)
    val declared = Color(0.72f, 0.58f, 0.96f)
    val route = Color(0.98f, 0.84f, 0.40f)
    val simulation = Color(1.00f, 0.69f, 0.13f)

    // 4 pt rhythm.
    val gap1 = 4.dp
    val gap2 = 8.dp
    val gap3 = 12.dp
    val gap4 = 16.dp
    val gap6 = 24.dp
    val radius = 16.dp

    // Type scale: 13 / 15 / 17 / 22 / 30. Numbers are monospaced so they do not jitter each second.
    val caption = TextStyle(fontSize = 13.sp, fontWeight = FontWeight.SemiBold)
    val small = TextStyle(fontSize = 15.sp)
    val body = TextStyle(fontSize = 17.sp)
    val title = TextStyle(fontSize = 22.sp, fontWeight = FontWeight.Bold)
    val headline = TextStyle(fontSize = 30.sp, fontWeight = FontWeight.ExtraBold)
    fun number(size: Int, weight: FontWeight = FontWeight.SemiBold): TextStyle =
        TextStyle(fontSize = size.sp, fontWeight = weight, fontFeatureSettings = "tnum")

    /** SwiftUI's `.tracking(0.8)` on the uppercase captions. */
    val tracking: TextUnit = 0.8.sp
}

/** Card surface used by every panel on the map (SwiftUI `.ghostCard()`). */
fun Modifier.ghostCard(): Modifier {
    val shape = RoundedCornerShape(GhostTheme.radius)
    return this
        .background(GhostTheme.surface, shape)
        .border(1.dp, GhostTheme.border, shape)
        .padding(GhostTheme.gap4)
}

/** Diagonal amber/black stripes: marks anything driven by injected (simulated) inputs. */
@Composable
fun HazardStripes(modifier: Modifier = Modifier) {
    Canvas(modifier.background(GhostTheme.simulation)) {
        val step = 14.dp.toPx()
        val h = size.height
        var x = -h
        while (x < size.width) {
            val path = Path().apply {
                moveTo(x, h)
                lineTo(x + h, 0f)
                lineTo(x + h + step / 2, 0f)
                lineTo(x + step / 2, h)
                close()
            }
            drawPath(path, Color.Black.copy(alpha = 0.55f))
            x += step
        }
    }
}

/**
 * One line of text that shrinks down to `minimumScaleFactor` of its size before it overflows,
 * like SwiftUI's `.lineLimit(1).minimumScaleFactor(…)`.
 */
@Composable
fun GhostFitText(
    text: String,
    style: TextStyle,
    color: Color,
    modifier: Modifier = Modifier,
    minimumScaleFactor: Float = 0.7f,
) {
    var scale by remember(text, style) { mutableFloatStateOf(1f) }
    var ready by remember(text, style) { mutableFloatStateOf(0f) }
    val base = style.fontSize.takeOrElse { 17.sp }
    Text(
        text,
        style = style.copy(fontSize = base * scale),
        color = color,
        maxLines = 1,
        softWrap = false,
        overflow = TextOverflow.Ellipsis,
        modifier = modifier.drawWithContent { if (ready > 0f) drawContent() },
        onTextLayout = { layout ->
            if (layout.hasVisualOverflow && scale > minimumScaleFactor) {
                scale = (scale - 0.05f).coerceAtLeast(minimumScaleFactor)
            } else {
                ready = 1f
            }
        },
    )
}
