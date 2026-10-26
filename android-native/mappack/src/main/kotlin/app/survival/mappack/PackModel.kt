package app.survival.mappack

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * The JSON written by `python -m geopdf_locator.export` (format "geopdf-mappack", version 1).
 * Page coordinates are PDF points with a top-left origin; multiply by [ImageInfo.pxPerPt] to
 * get pixels in the exported map image.
 */
@Serializable
data class PackJson(
    val format: String,
    val version: Int,
    val source: SourceInfo,
    val page: PageInfo,
    val image: ImageInfo,
    val georef: GeorefInfo,
    @SerialName("guidance_params") val guidanceParams: GuidanceParams,
    val labels: List<LabelJson>,
    val notes: List<NoteJson>,
    val paths: List<List<List<Double>>>,
)

@Serializable
data class SourceInfo(val title: String, val file: String? = null, val sha256: String? = null, val page: Int = 0)

@Serializable
data class PageInfo(val width: Double, val height: Double)

@Serializable
data class ImageInfo(
    val file: String,
    val width: Int,
    val height: Int,
    @SerialName("px_per_pt") val pxPerPt: Double,
)

@Serializable
data class GeorefInfo(
    val projection: String,
    @SerialName("earth_radius_m") val earthRadiusM: Double,
    /** 3x2 affine: [x, y, 1] * M = Web Mercator metres. */
    @SerialName("page_to_mercator") val pageToMercator: List<List<Double>>,
    @SerialName("mercator_to_page") val mercatorToPage: List<List<Double>>,
)

@Serializable
data class GuidanceParams(
    @SerialName("km_per_pt") val kmPerPt: Double,
    @SerialName("corridor_km") val corridorKm: Double,
    @SerialName("nearby_km") val nearbyKm: Double,
    @SerialName("feature_label_distance_pt") val featureLabelDistancePt: Double,
)

@Serializable
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
    @SerialName("via_leader") val viaLeader: Boolean,
    val area: Boolean,
    val guidance: List<AdvisoryJson>,
)

@Serializable
data class AdvisoryJson(
    val note: Int,
    val reason: String,
    @SerialName("distance_km") val distanceKm: Double? = null,
)

@Serializable
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

@Serializable
data class NotePathJson(val path: Int, val section: List<Double>? = null)
