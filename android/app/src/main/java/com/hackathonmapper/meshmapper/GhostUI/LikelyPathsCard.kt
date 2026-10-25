package com.hackathonmapper.meshmapper

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.drawWithContent
import androidx.compose.ui.geometry.CornerRadius
import androidx.compose.ui.graphics.PathEffect
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.text.TextStyle
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp

/**
 * Which way a lost phone probably went, in words, from the route model. Headed PREDICTED with the
 * time since the phone was last placed, so nobody reads it as a live position.
 */
@Composable
fun LikelyPathsCard(phone: VizPhone, paths: VizLikelyPaths, now: Double, modifier: Modifier = Modifier) {
    Column(
        modifier
            .fillMaxWidth()
            .drawWithContent {
                drawContent()
                val radius = GhostTheme.radius.toPx()
                drawRoundRect(
                    GhostTheme.predicted.copy(alpha = 0.6f), cornerRadius = CornerRadius(radius),
                    style = Stroke(1.dp.toPx(), pathEffect = PathEffect.dashPathEffect(floatArrayOf(5.dp.toPx(), 4.dp.toPx()))),
                )
            }
            .ghostCard(),
        verticalArrangement = Arrangement.spacedBy(GhostTheme.gap1),
    ) {
        Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2), verticalAlignment = Alignment.CenterVertically) {
            Text("PREDICTED", style = GhostTheme.caption.copy(letterSpacing = GhostTheme.tracking), color = GhostTheme.predicted)
            Text(
                "${phone.label} out of reach${phone.age(now)?.let { " ${VizPresentation.ageText(it)}" } ?: ""} · probably",
                style = GhostTheme.caption,
                color = GhostTheme.muted,
                maxLines = 1,
                modifier = Modifier.weight(1f),
            )
            if (phone.simulated) SimBadge(compact = true)
        }
        for (option in paths.options.take(3)) {
            Row(horizontalArrangement = Arrangement.spacedBy(GhostTheme.gap2), verticalAlignment = Alignment.CenterVertically) {
                Text(
                    "${vizRound(option.probability * 100)} %",
                    style = GhostTheme.number(17, FontWeight.ExtraBold),
                    color = GhostTheme.text.copy(alpha = (GhostMapContent.pathOpacity(option.rank) + 0.05).toFloat().coerceAtMost(1f)),
                    modifier = Modifier.width(52.dp),
                )
                GhostFitText(option.text, GhostTheme.small, GhostTheme.text, minimumScaleFactor = 0.8f)
            }
        }
        if (paths.offPath >= 0.05) {
            Text(
                "${vizRound(paths.offPath * 100)} % chance they left the paths",
                style = TextStyle(fontSize = 13.sp),
                color = GhostTheme.muted,
            )
        }
    }
}
