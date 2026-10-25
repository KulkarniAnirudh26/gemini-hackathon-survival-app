package com.hackathon.yosemite_survival.map3d

import java.text.Normalizer
import java.util.Locale
import kotlin.math.PI
import kotlin.math.atan
import kotlin.math.exp
import kotlin.math.hypot
import kotlin.math.ln
import kotlin.math.max
import kotlin.math.min
import kotlin.math.sqrt
import kotlin.math.tan

data class LatLon(val lat: Double, val lon: Double)

/** A point on the map page, in PDF points from the top-left corner. */
data class PagePoint(val x: Double, val y: Double)

enum class Severity { WARNING, INFO }

data class Note(
    val id: Int,
    val text: String,
    val severity: Severity,
    val parkWide: Boolean,
    /** Road or trail the note is about, e.g. "Tioga Road". */
    val feature: String?,
    /** "east" in "closed east of this point". */
    val direction: String?,
    /** Where the note points on the map; null for park-wide notes. */
    val anchor: LatLon?,
)

data class Advisory(val note: Note, val reason: String, val distanceKm: Double?)

data class Place(
    val text: String,
    val location: LatLon,
    /** Where the location was taken from on the page (the map symbol, or the label centre). */
    val page: PagePoint,
    val labelBox: List<Double>,
    val fontSize: Double,
    /** Anchored to a map symbol rather than the label's centre. */
    val snapped: Boolean,
    val viaLeader: Boolean,
    /** All-caps area name ("TUOLUMNE MEADOWS"): the location is the area's label centre. */
    val area: Boolean,
    internal val norm: String,
    internal val guidance: List<AdvisoryJson>,
)

data class PlaceHit(val place: Place, val exact: Boolean, val score: Double)

/**
 * Offline place search and safety guidance for one map, loaded from a map pack exported by the
 * Python `geopdf_locator.export` tool. Copied from android-native/mappack (where it is
 * parity-tested against the Python pipeline); only JSON loading differs (org.json here).
 */
class MapPack(val pack: PackJson) {
    val notes: List<Note> = pack.notes.mapIndexed { i, n ->
        Note(
            id = i,
            text = n.text,
            severity = if (n.severity == "warning") Severity.WARNING else Severity.INFO,
            parkWide = n.scope == "park",
            feature = n.feature,
            direction = n.direction,
            anchor = if (n.lat != null && n.lon != null) LatLon(n.lat, n.lon) else null,
        )
    }

    val places: List<Place> = pack.labels.map { lb ->
        Place(lb.text, LatLon(lb.lat, lb.lon), PagePoint(lb.x, lb.y), lb.bbox, lb.size, lb.snapped,
            lb.viaLeader, lb.area, lb.norm, lb.guidance)
    }

    /** Guidance printed for the whole park (permits, hazards, road-conditions phone number). */
    val parkWide: List<Note> get() = notes.filter { it.parkWide }

    private val paths: List<Polyline> = pack.paths.map { pts -> Polyline(pts.map { PagePoint(it[0], it[1]) }) }
    private val radius = pack.georef.earthRadiusM

    init {
        require(pack.format == "geopdf-mappack") { "not a map pack: ${pack.format}" }
        require(pack.version == SUPPORTED_VERSION) { "unsupported map pack version ${pack.version}" }
        require(pack.georef.projection == "EPSG:3857") { "unsupported projection ${pack.georef.projection}" }
    }

    // -- coordinates ------------------------------------------------------------------------

    fun pageToLatLon(p: PagePoint): LatLon {
        val (mx, my) = affine(pack.georef.pageToMercator, p.x, p.y)
        return LatLon(Math.toDegrees(2 * atan(exp(my / radius)) - PI / 2), Math.toDegrees(mx / radius))
    }

    fun latLonToPage(ll: LatLon): PagePoint {
        val mx = radius * Math.toRadians(ll.lon)
        val my = radius * ln(tan(PI / 4 + Math.toRadians(ll.lat) / 2))
        val (x, y) = affine(pack.georef.mercatorToPage, mx, my)
        return PagePoint(x, y)
    }

    /** Pixel position in the exported map image, for drawing markers. */
    fun pageToImagePx(p: PagePoint): Pair<Float, Float> =
        (p.x * pack.image.pxPerPt).toFloat() to (p.y * pack.image.pxPerPt).toFloat()

    fun isOnMap(ll: LatLon): Boolean {
        val p = latLonToPage(ll)
        return p.x in 0.0..pack.page.width && p.y in 0.0..pack.page.height
    }

    // -- search ----------------------------------------------------------------------------

    /**
     * Places whose label contains [query], best first: labels that are exactly the query,
     * anchored to a map symbol (especially via a leader line), and in larger type rank higher.
     * Same ranking as the Python `GeoPdfMap.locate`.
     */
    fun search(query: String, limit: Int = 20): List<PlaceHit> {
        val q = normalize(query)
        if (q.isEmpty()) return emptyList()
        return places.asSequence()
            .filter { q in it.norm }
            .map { p ->
                val exact = p.norm == q
                val score = 4.0 * exact.toInt() + 2.0 * p.snapped.toInt() + 0.5 * p.viaLeader.toInt() + 0.25 * p.fontSize
                PlaceHit(p, exact, score)
            }
            // ties (a name printed more than once) go top to bottom, then left to right, as in Python
            .sortedWith(compareByDescending<PlaceHit> { it.score }.thenBy { it.place.page.y }.thenBy { it.place.page.x })
            .take(limit)
            .toList()
    }

    // -- guidance --------------------------------------------------------------------------

    /** Local guidance that applies at a place (precomputed when the pack was built). */
    fun guidanceFor(place: Place): List<Advisory> =
        place.guidance.map { Advisory(notes[it.note], it.reason, it.distanceKm) }

    /**
     * Local guidance that applies at a GPS position, most relevant first: closures on the road
     * the position is on (only inside the closed stretch), notes along that road, then notes
     * printed nearby. Park-wide notes are in [parkWide]. Same rules as Python `Guidance.for_point`.
     */
    fun guidanceAt(position: LatLon): List<Advisory> {
        val xy = latLonToPage(position)
        val params = pack.guidanceParams
        val corridorPt = params.corridorKm / params.kmPerPt
        val out = mutableListOf<Advisory>()
        for ((i, nj) in pack.notes.withIndex()) {
            val note = notes[i]
            if (note.parkWide) continue
            var matched = false
            for (ref in nj.paths) {
                val (dist, s) = paths[ref.path].project(xy)
                if (dist > corridorPt) continue
                if (note.direction != null) {
                    val section = ref.section
                    if (section != null && s >= section[0] && s <= section[1]) {
                        out += Advisory(note, "on ${note.feature}, ${note.direction} of the marked point", dist * params.kmPerPt)
                        matched = true
                    }
                } else {
                    out += Advisory(note, "along ${note.feature}", dist * params.kmPerPt)
                    matched = true
                }
                break
            }
            if (!matched && !(nj.paths.isNotEmpty() && note.direction != null) && nj.x != null && nj.y != null) {
                val km = hypot(xy.x - nj.x, xy.y - nj.y) * params.kmPerPt
                if (km <= params.nearbyKm) {
                    out += Advisory(note, "nearby (${String.format(Locale.US, "%.1f", km)} km)", km)
                }
            }
        }
        val ranked = out.sortedWith(
            compareBy<Advisory>(
                { if (it.reason.startsWith("on ") || it.reason.startsWith("along ")) 1 else 2 },
                { it.note.severity != Severity.WARNING },
                { it.distanceKm ?: 0.0 },
            )
        )
        // the same note is often printed more than once along a road; keep the most relevant copy
        return ranked.distinctBy { it.note.text }
    }

    companion object {
        const val SUPPORTED_VERSION = 1
        fun parse(jsonText: String): MapPack = MapPack(PackJson.parse(jsonText))

        /** Same normalisation as the Python side: accents and ligatures split, then [a-z0-9] only. */
        fun normalize(text: String): String =
            Normalizer.normalize(text, Normalizer.Form.NFKD).lowercase(Locale.ROOT).replace(NON_ALNUM, "")

        private val NON_ALNUM = Regex("[^a-z0-9]")

        private fun affine(m: List<List<Double>>, x: Double, y: Double): Pair<Double, Double> =
            (x * m[0][0] + y * m[1][0] + m[2][0]) to (x * m[0][1] + y * m[1][1] + m[2][1])

        private fun Boolean.toInt() = if (this) 1 else 0
    }
}

/** A road or trail line in page coordinates, with arc-length positions. */
internal class Polyline(private val points: List<PagePoint>) {
    private val cumulative = DoubleArray(points.size).also { c ->
        for (i in 1 until points.size) c[i] = c[i - 1] + hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y)
    }

    /** (distance from p to the line, arc-length position of the closest point). */
    fun project(p: PagePoint): Pair<Double, Double> {
        var bestD = Double.POSITIVE_INFINITY
        var bestS = 0.0
        for (i in 0 until points.size - 1) {
            val a = points[i]
            val b = points[i + 1]
            val dx = b.x - a.x
            val dy = b.y - a.y
            val seg2 = dx * dx + dy * dy
            val t = if (seg2 == 0.0) 0.0 else min(1.0, max(0.0, ((p.x - a.x) * dx + (p.y - a.y) * dy) / seg2))
            val d = hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
            if (d < bestD) {
                bestD = d
                bestS = cumulative[i] + t * sqrt(seg2)
            }
        }
        return bestD to bestS
    }
}
