package com.hackathon.yosemite_survival.map3d

import org.json.JSONArray
import org.json.JSONObject

/**
 * The JSON written by `python -m geopdf_locator.export` (format "geopdf-mappack", version 1).
 * Same model as android-native/mappack, read with org.json instead of kotlinx.serialization.
 * Page coordinates are PDF points with a top-left origin; multiply by [ImageInfo.pxPerPt] to
 * get pixels in the exported map image.
 */
data class PackJson(
    val format: String,
    val version: Int,
    val source: SourceInfo,
    val page: PageInfo,
    val image: ImageInfo,
    val georef: GeorefInfo,
    val guidanceParams: GuidanceParams,
    val labels: List<LabelJson>,
    val notes: List<NoteJson>,
    val paths: List<List<List<Double>>>,
) {
    companion object {
        /** Reads the map pack JSON with Android's built-in org.json (unknown keys are ignored). */
        fun parse(text: String): PackJson {
            val o = JSONObject(text)
            val src = o.getJSONObject("source")
            val page = o.getJSONObject("page")
            val img = o.getJSONObject("image")
            val geo = o.getJSONObject("georef")
            val gp = o.getJSONObject("guidance_params")
            return PackJson(
                format = o.getString("format"),
                version = o.getInt("version"),
                source = SourceInfo(src.getString("title"), src.optStringOrNull("file"), src.optStringOrNull("sha256"), src.optInt("page")),
                page = PageInfo(page.getDouble("width"), page.getDouble("height")),
                image = ImageInfo(img.getString("file"), img.getInt("width"), img.getInt("height"), img.getDouble("px_per_pt")),
                georef = GeorefInfo(geo.getString("projection"), geo.getDouble("earth_radius_m"),
                    geo.getJSONArray("page_to_mercator").matrix(), geo.getJSONArray("mercator_to_page").matrix()),
                guidanceParams = GuidanceParams(gp.getDouble("km_per_pt"), gp.getDouble("corridor_km"),
                    gp.getDouble("nearby_km"), gp.getDouble("feature_label_distance_pt")),
                labels = o.getJSONArray("labels").objects().map { lb ->
                    LabelJson(lb.getString("text"), lb.getString("norm"), lb.getDouble("lat"), lb.getDouble("lon"),
                        lb.getDouble("x"), lb.getDouble("y"), lb.getJSONArray("bbox").doubles(), lb.getDouble("size"),
                        lb.getBoolean("snapped"), lb.getBoolean("via_leader"), lb.getBoolean("area"),
                        lb.getJSONArray("guidance").objects().map { a ->
                            AdvisoryJson(a.getInt("note"), a.getString("reason"), a.optDoubleOrNull("distance_km"))
                        })
                },
                notes = o.getJSONArray("notes").objects().map { n ->
                    NoteJson(n.getString("text"), n.getString("severity"), n.getString("scope"), n.optStringOrNull("feature"),
                        n.optStringOrNull("direction"), n.getJSONArray("bbox").doubles(), n.optDoubleOrNull("x"),
                        n.optDoubleOrNull("y"), n.optDoubleOrNull("lat"), n.optDoubleOrNull("lon"),
                        n.optJSONArray("paths")?.objects()?.map { p ->
                            NotePathJson(p.getInt("path"), p.optJSONArray("section")?.doubles())
                        } ?: emptyList())
                },
                paths = o.getJSONArray("paths").let { a -> (0 until a.length()).map { a.getJSONArray(it).matrix() } },
            )
        }

        private fun JSONArray.objects() = (0 until length()).map { getJSONObject(it) }
        private fun JSONArray.doubles() = (0 until length()).map { getDouble(it) }
        private fun JSONArray.matrix() = (0 until length()).map { getJSONArray(it).doubles() }
        private fun JSONObject.optStringOrNull(k: String) = if (isNull(k)) null else optString(k, null)
        private fun JSONObject.optDoubleOrNull(k: String) = if (isNull(k)) null else optDouble(k).takeUnless { it.isNaN() }
    }
}

data class SourceInfo(val title: String, val file: String? = null, val sha256: String? = null, val page: Int = 0)

data class PageInfo(val width: Double, val height: Double)

data class ImageInfo(
    val file: String,
    val width: Int,
    val height: Int,
    val pxPerPt: Double,
)

data class GeorefInfo(
    val projection: String,
    val earthRadiusM: Double,
    /** 3x2 affine: [x, y, 1] * M = Web Mercator metres. */
    val pageToMercator: List<List<Double>>,
    val mercatorToPage: List<List<Double>>,
)

data class GuidanceParams(
    val kmPerPt: Double,
    val corridorKm: Double,
    val nearbyKm: Double,
    val featureLabelDistancePt: Double,
)

data class LabelJson(
    val text: String,
    val norm: String,
    val lat: Double,
    val lon: Double,
    val x: Double,
    val y: Double,
    val bbox: List<Double>,
    val size: Double,
    val snapped: Boolean,
    val viaLeader: Boolean,
    val area: Boolean,
    val guidance: List<AdvisoryJson>,
)

data class AdvisoryJson(
    val note: Int,
    val reason: String,
    val distanceKm: Double? = null,
)

data class NoteJson(
    val text: String,
    val severity: String,
    val scope: String,
    val feature: String? = null,
    val direction: String? = null,
    val bbox: List<Double>,
    val x: Double? = null,
    val y: Double? = null,
    val lat: Double? = null,
    val lon: Double? = null,
    val paths: List<NotePathJson> = emptyList(),
)

data class NotePathJson(val path: Int, val section: List<Double>? = null)
