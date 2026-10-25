package app.survival.mappack

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.double
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import kotlin.math.abs
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue
import kotlin.test.fail

class MapPackTest {
    private val pack: MapPack by lazy {
        MapPack.parse(File(System.getProperty("mappack.dir"), "mappack.json").readText())
    }

    /** What the Python pipeline answers; regenerate with scripts/build_android_assets.py. */
    private val parity by lazy {
        Json.parseToJsonElement(javaClass.getResource("/parity.json")!!.readText()).jsonObject
    }

    @Test
    fun `search matches python for every place on the map`() {
        val failures = mutableListOf<String>()
        val searches = parity["searches"]!!.jsonArray
        for (case in searches) {
            val c = case.jsonObject
            val query = c["query"]!!.jsonPrimitive.content
            val hit = pack.search(query).firstOrNull()
            val lat = c["lat"]!!.jsonPrimitive.double
            val lon = c["lon"]!!.jsonPrimitive.double
            if (hit == null || abs(hit.place.location.lat - lat) > 1e-5 || abs(hit.place.location.lon - lon) > 1e-5) {
                failures += "$query: python ${c["label"]} ($lat, $lon), kotlin ${hit?.place?.text} ${hit?.place?.location}"
            }
        }
        if (failures.isNotEmpty()) fail("${failures.size}/${searches.size} differ:\n" + failures.joinToString("\n"))
    }

    @Test
    fun `gps guidance matches python`() {
        val failures = mutableListOf<String>()
        val positions = parity["positions"]!!.jsonArray
        for (case in positions) {
            val c = case.jsonObject
            val at = LatLon(c["lat"]!!.jsonPrimitive.double, c["lon"]!!.jsonPrimitive.double)
            val expected = c["guidance"]!!.jsonArray.map {
                it.jsonObject["text"]!!.jsonPrimitive.content to it.jsonObject["reason"]!!.jsonPrimitive.content
            }
            val actual = pack.guidanceAt(at).map { it.note.text to it.reason }
            if (expected != actual) failures += "$at\n  python $expected\n  kotlin $actual"
        }
        if (failures.isNotEmpty()) fail("${failures.size}/${positions.size} differ:\n" + failures.joinToString("\n"))
    }

    @Test
    fun `page and lat lon round trip`() {
        for (x in listOf(0.0, 300.0, 1165.0)) for (y in listOf(0.0, 600.0, 1233.0)) {
            val back = pack.latLonToPage(pack.pageToLatLon(PagePoint(x, y)))
            assertTrue(abs(back.x - x) < 1e-6 && abs(back.y - y) < 1e-6, "($x, $y) -> $back")
        }
    }

    @Test
    fun `half dome is at the summit`() {
        val best = pack.search("half dome").first()
        assertEquals("Half Dome", best.place.text)
        assertTrue(best.exact && best.place.snapped)
        assertEquals(37.7459, best.place.location.lat, 0.001)
        assertEquals(-119.5332, best.place.location.lon, 0.001)
    }

    @Test
    fun `exact label ranks above road label`() {
        val hits = pack.search("Glacier Point")
        assertEquals("Glacier Point", hits.first().place.text)
        assertTrue(hits.drop(1).any { it.place.text == "Glacier Point Road" })
    }

    @Test
    fun `tioga closures apply between the gates only`() {
        val olmsted = pack.guidanceFor(pack.search("Olmsted Point").first().place).map { it.note.text }
        assertTrue(olmsted.any { it.startsWith("Tioga Road closed") })
        val leeVining = pack.guidanceFor(pack.search("Lee Vining").first().place).map { it.note.text }
        assertFalse(leeVining.any { it.startsWith("Tioga Road closed") })
    }

    @Test
    fun `park wide notes`() {
        assertEquals(3, pack.parkWide.size)
        assertTrue(pack.parkWide.any { it.text.startsWith("Natural areas present hazards") })
    }

    @Test
    fun `image pixels follow page points`() {
        val (px, py) = pack.pageToImagePx(PagePoint(100.0, 200.0))
        assertEquals(100 * pack.pack.image.pxPerPt, px.toDouble(), 0.01)
        assertEquals(200 * pack.pack.image.pxPerPt, py.toDouble(), 0.01)
    }

    @Test
    fun `rejects other formats`() {
        val bad = File(System.getProperty("mappack.dir"), "mappack.json").readText()
            .replace("\"version\":1", "\"version\":99")
        val error = runCatching { MapPack.parse(bad) }.exceptionOrNull()
        assertTrue(error is IllegalArgumentException)
    }
}
