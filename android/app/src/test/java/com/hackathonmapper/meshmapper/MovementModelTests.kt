package com.hackathonmapper.meshmapper

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File
import kotlin.math.abs
import kotlin.math.max

/** The shared ml/export directory, read in place (`repo.root` is set by app/build.gradle.kts). */
internal val mlExport: File
    get() = File(System.getProperty("repo.root") ?: "../..", "ml/export")

internal fun JsonElement.doubles(): List<Double> = jsonArray.map { it.jsonPrimitive.double }

internal fun JsonElement.points(): List<MovementModel.Point> =
    jsonArray.map { it.doubles().let { p -> MovementModel.Point(p[0], p[1]) } }

/**
 * Replays the movement model goldens (predictions of the trained PyTorch models) through the Kotlin
 * runtime, with the tolerances of ml/runtime/test-golden/main.swift (v1, golden.json) and
 * ml/runtime/test-golden-v2/main.swift (v2 with the Hervanta map, golden-v2.json).
 */
class MovementModelTests {
    private fun cases(name: String): List<JsonObject> =
        Json.parseToJsonElement(File(mlExport, name).readText()).jsonArray.map { it.jsonObject }

    private fun model(name: String) = MovementModel(File(mlExport, name).readText())

    /** Worst error over one case, in units of the Swift tolerances. */
    private fun worstError(p: MovementModel.Prediction, c: JsonObject): Double {
        var worst = 0.0
        val weights = c["weights"]!!.doubles()
        val means = c["means"]!!.jsonArray.map { it.doubles() }
        val covs = c["covs"]!!.jsonArray.map { it.doubles() }
        for (k in weights.indices) {
            val got = listOf(p.means[k].x, p.means[k].y)
            val cov = listOf(p.covs[k].xx, p.covs[k].xy, p.covs[k].yy)
            worst = max(worst, abs(p.weights[k] - weights[k]) / 1e-3)
            for (i in 0 until 2) worst = max(worst, abs(got[i] - means[k][i]) / (1e-2 + 1e-4 * abs(means[k][i])))
            for (i in 0 until 3) worst = max(worst, abs(cov[i] - covs[k][i]) / (1e-2 + 1e-3 * abs(covs[k][i])))
        }
        return worst
    }

    /** MapLayer.fromPng needs Android's BitmapFactory; on the JVM the PNG is read with ImageIO. */
    private fun hervantaMap(): MovementModel.MapLayer {
        val meta = MovementModel.jsonFormat.decodeFromString(
            MovementModel.MapLayer.Meta.serializer(),
            File(mlExport, "maps/hervanta.json").readText(),
        )
        // javax.imageio/java.awt aren't on the android.jar compile classpath but exist on the
        // desktop JVM that runs unit tests, so reach them reflectively.
        val image = Class.forName("javax.imageio.ImageIO")
            .getMethod("read", File::class.java)
            .invoke(null, File(mlExport, "maps/hervanta.png"))
        val type = image.javaClass
        val width = type.getMethod("getWidth").invoke(image) as Int
        val height = type.getMethod("getHeight").invoke(image) as Int
        val getRGB = type.getMethod("getRGB", Int::class.javaPrimitiveType, Int::class.javaPrimitiveType)
        assertEquals(meta.width, width)
        assertEquals(meta.height, height)
        val rgb = IntArray(meta.width * meta.height * 3)
        for (row in 0 until meta.height) {
            for (col in 0 until meta.width) {
                val c = getRGB.invoke(image, col, row) as Int
                val i = row * meta.width + col
                rgb[3 * i] = (c shr 16) and 255
                rgb[3 * i + 1] = (c shr 8) and 255
                rgb[3 * i + 2] = c and 255
            }
        }
        return MovementModel.MapLayer(rgb, meta)
    }

    @Test
    fun goldenCasesV1() {
        val model = model("movement-model.json")
        val cases = cases("golden.json")
        assertEquals(24, cases.size)
        var worst = 0.0
        for (c in cases) {
            val p = model.predict(c["hist"]!!.points(), c["acc"]!!.jsonPrimitive.double, c["h"]!!.jsonPrimitive.double)
            worst = max(worst, worstError(p, c))
        }
        assertTrue("worst error $worst of tolerance", worst <= 1)
    }

    @Test
    fun goldenCasesV2WithMap() {
        val model = model("movement-model-v2.json")
        assertTrue(model.usesMap)
        val map = hervantaMap()
        val cases = cases("golden-v2.json")
        assertEquals(24, cases.size)
        var worst = 0.0
        var worstPatch = 0.0
        for (c in cases) {
            val dest = c["destination"]?.takeIf { it != JsonNull }?.doubles()?.let { MovementModel.Point(it[0], it[1]) }
            val prep = model.prepare(c["hist"]!!.points(), c["acc"]!!.jsonPrimitive.double, map, dest)
            val patchSum = model.samplePatch(map, prep.origin, prep.th).fold(0.0) { a, b -> a + b }
            val expected = c["patchSum"]!!.jsonPrimitive.double
            worstPatch = max(worstPatch, abs(patchSum - expected) / (1e-3 + 1e-4 * expected))
            val p = model.predict(prep, c["h"]!!.jsonPrimitive.double)
            worst = max(worst, worstError(p, c))
        }
        assertTrue("worst error $worst of tolerance", worst <= 1)
        assertTrue("worst map patch error $worstPatch of tolerance", worstPatch <= 1)
    }

    /** The app's bundled copy is the exported model (the app reads it without the map, `readsMap`). */
    @Test
    fun bundledModelIsTheExport() {
        val bundled = File(System.getProperty("repo.root") ?: "../..", "android/app/src/main/assets/movement-model-v2.json")
        assertEquals(File(mlExport, "movement-model-v2.json").readText(), bundled.readText())
    }

    @Test
    fun historyAndSampling() {
        val model = model("movement-model-v2.json")
        val track = (0 until 60).map { MovementModel.TrackPoint(100 + 1.3 * it, 1.3 * it, 0.0) }
        val hist = model.history(track, track.last().t)
        assertEquals(31, hist.size)
        assertEquals(track.last().x, hist[30].x, 1e-9)
        assertEquals(track.last().x - 60, hist[0].x, 1e-9)
        val prediction = model.predict(hist, 5.0, 60.0)
        val dots = prediction.sample(4000, SplitMix64(42uL))
        val mx = dots.sumOf { it.x } / dots.size
        val ex = prediction.weights.zip(prediction.means).sumOf { (w, m) -> w * m.x }
        assertTrue("sample mean $mx vs $ex", abs(mx - ex) < 4)
    }
}
