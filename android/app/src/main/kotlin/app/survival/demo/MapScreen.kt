package app.survival.demo

import androidx.compose.foundation.Canvas
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.heightIn
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.itemsIndexed
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.SmallFloatingActionButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clipToBounds
import androidx.compose.ui.geometry.Offset
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.drawscope.Stroke
import androidx.compose.ui.graphics.drawscope.withTransform
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalDensity
import androidx.compose.ui.platform.LocalFocusManager
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import app.survival.mappack.Advisory
import app.survival.mappack.LatLon
import app.survival.mappack.Place
import app.survival.mappack.Severity
import java.util.Locale

private val WarningRed = Color(0xFFC62828)
private val InfoBlue = Color(0xFF1565C0)
private val MeBlue = Color(0xFF1E88E5)

/** What the bottom panel is showing: a searched place, or the user's own position. */
private sealed interface Focus {
    data class AtPlace(val place: Place) : Focus
    data class AtMe(val position: LatLon) : Focus
}

@Composable
fun MapScreen(
    map: LoadedMap,
    myLocation: LatLon?,
    locationError: String?,
    onLocate: () -> Unit,
    modifier: Modifier = Modifier,
) {
    val pack = map.pack
    var query by remember { mutableStateOf("") }
    var focus by remember { mutableStateOf<Focus?>(null) }
    var showResults by remember { mutableStateOf(false) }
    val focusManager = LocalFocusManager.current

    LaunchedEffect(myLocation) { myLocation?.let { focus = Focus.AtMe(it) } }

    val results = remember(query) { if (query.length >= 2) pack.search(query, limit = 8) else emptyList() }
    val markerPx = when (val f = focus) {
        is Focus.AtPlace -> pack.pageToImagePx(f.place.page)
        is Focus.AtMe -> null
        null -> null
    }
    val mePx = myLocation?.takeIf { pack.isOnMap(it) }?.let { pack.pageToImagePx(pack.latLonToPage(it)) }

    Column(modifier.fillMaxSize()) {
        OutlinedTextField(
            value = query,
            onValueChange = { query = it; showResults = true },
            label = { Text("Search a place on the map") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth().padding(horizontal = 12.dp, vertical = 8.dp).testTag("search"),
        )
        Box(Modifier.weight(1f).fillMaxWidth()) {
            ZoomableMap(
                map = map,
                marker = markerPx?.let { Offset(it.first, it.second) },
                me = mePx?.let { Offset(it.first, it.second) },
                focusPoint = (markerPx ?: mePx)?.let { Offset(it.first, it.second) },
                modifier = Modifier.fillMaxSize(),
            )
            if (showResults && results.isNotEmpty()) {
                Surface(
                    shape = RoundedCornerShape(8.dp),
                    tonalElevation = 4.dp,
                    shadowElevation = 4.dp,
                    modifier = Modifier.padding(horizontal = 12.dp).fillMaxWidth().align(Alignment.TopCenter),
                ) {
                    LazyColumn(Modifier.heightIn(max = 320.dp)) {
                        itemsIndexed(results) { i, hit ->
                            Column(
                                Modifier.fillMaxWidth()
                                    .clickable {
                                        focus = Focus.AtPlace(hit.place)
                                        query = hit.place.text
                                        showResults = false
                                        focusManager.clearFocus()
                                    }
                                    .padding(horizontal = 16.dp, vertical = 10.dp)
                                    .testTag("result-$i"),
                            ) {
                                Text(hit.place.text, fontWeight = if (hit.exact) FontWeight.SemiBold else FontWeight.Normal)
                                Text(formatLatLon(hit.place.location), style = MaterialTheme.typography.bodySmall)
                            }
                            if (i < results.lastIndex) HorizontalDivider()
                        }
                    }
                }
            }
            SmallFloatingActionButton(
                onClick = onLocate,
                modifier = Modifier.align(Alignment.BottomEnd).padding(12.dp).testTag("locate")
                    .semantics { contentDescription = "Show guidance for my location" },
            ) { Text("◎", style = MaterialTheme.typography.titleLarge) }
        }
        GuidancePanel(map, focus, locationError)
    }
}

@Composable
private fun ZoomableMap(map: LoadedMap, marker: Offset?, me: Offset?, focusPoint: Offset?, modifier: Modifier) {
    BoxWithConstraints(modifier.clipToBounds().background(Color(0xFFE8E6DF))) {
        val density = LocalDensity.current
        val w = with(density) { maxWidth.toPx() }
        val h = with(density) { maxHeight.toPx() }
        val fit = minOf(w / map.image.width, h / map.image.height)
        var scale by remember { mutableFloatStateOf(fit) }
        var offset by remember { mutableStateOf(Offset.Zero) }
        // Centre on the selected place, zoomed in enough to read the labels around it, or show
        // the whole map. Re-run when the viewport changes size (keyboard, panel growing).
        LaunchedEffect(focusPoint, w, h) {
            if (focusPoint != null) {
                scale = maxOf(scale, fit * 4)
                offset = Offset(w / 2 - focusPoint.x * scale, h / 2 - focusPoint.y * scale)
            } else {
                scale = fit
                offset = Offset((w - map.image.width * fit) / 2, (h - map.image.height * fit) / 2)
            }
        }
        Canvas(
            Modifier.fillMaxSize()
                .testTag("map")
                .pointerInput(fit) {
                    detectTransformGestures { centroid, pan, zoom, _ ->
                        val newScale = (scale * zoom).coerceIn(fit, fit * 10)
                        offset = (offset - centroid) * (newScale / scale) + centroid + pan
                        scale = newScale
                    }
                },
        ) {
            withTransform({
                translate(offset.x, offset.y)
                scale(scale, scale, pivot = Offset.Zero)
            }) {
                drawImage(map.image)
                val unit = 1f / scale  // keep markers the same size on screen at any zoom
                me?.let {
                    drawCircle(MeBlue.copy(alpha = 0.2f), radius = 40 * unit, center = it)
                    drawCircle(Color.White, radius = 17 * unit, center = it)
                    drawCircle(MeBlue, radius = 12 * unit, center = it)
                }
                marker?.let {
                    drawCircle(Color.White, radius = 30 * unit, center = it, style = Stroke(11 * unit))
                    drawCircle(WarningRed, radius = 30 * unit, center = it, style = Stroke(6 * unit))
                    drawCircle(WarningRed, radius = 6 * unit, center = it)
                }
            }
        }
    }
}

@Composable
private fun GuidancePanel(map: LoadedMap, focus: Focus?, locationError: String?) {
    val pack = map.pack
    var showParkWide by remember { mutableStateOf(false) }
    val (title, subtitle, advisories) = when (focus) {
        is Focus.AtPlace -> Triple(focus.place.text, formatLatLon(focus.place.location), pack.guidanceFor(focus.place))
        is Focus.AtMe -> Triple(
            "Your location",
            formatLatLon(focus.position) + if (pack.isOnMap(focus.position)) "" else " · outside this map",
            pack.guidanceAt(focus.position),
        )
        null -> Triple("Yosemite National Park", "Search a place or tap ◎ for guidance where you are", emptyList())
    }
    Surface(tonalElevation = 2.dp, modifier = Modifier.fillMaxWidth().testTag("guidance")) {
        LazyColumn(Modifier.heightIn(max = 300.dp).padding(horizontal = 16.dp, vertical = 10.dp),
            verticalArrangement = Arrangement.spacedBy(8.dp)) {
            item {
                Text(title, style = MaterialTheme.typography.titleMedium, modifier = Modifier.testTag("panel-title"))
                Text(subtitle, style = MaterialTheme.typography.bodySmall)
                locationError?.let { Text(it, color = WarningRed, style = MaterialTheme.typography.bodySmall) }
            }
            if (focus != null && advisories.isEmpty()) {
                item { Text("No map notes for this spot.", style = MaterialTheme.typography.bodyMedium) }
            }
            itemsIndexed(advisories) { i, a -> AdvisoryRow(a, Modifier.testTag("advisory-$i")) }
            item {
                TextButton(onClick = { showParkWide = !showParkWide }) {
                    Text(if (showParkWide) "Hide park-wide guidance" else "Park-wide guidance (${pack.parkWide.size})")
                }
            }
            if (showParkWide) {
                itemsIndexed(pack.parkWide) { _, note ->
                    AdvisoryRow(Advisory(note, "park-wide", null))
                }
            }
        }
    }
}

@Composable
private fun AdvisoryRow(a: Advisory, modifier: Modifier = Modifier) {
    val warning = a.note.severity == Severity.WARNING
    Row(modifier.fillMaxWidth(), horizontalArrangement = Arrangement.spacedBy(10.dp)) {
        Text(
            if (warning) "WARNING" else "INFO",
            color = Color.White,
            style = MaterialTheme.typography.labelSmall,
            modifier = Modifier.background(if (warning) WarningRed else InfoBlue, RoundedCornerShape(4.dp))
                .padding(horizontal = 6.dp, vertical = 2.dp),
        )
        Column(Modifier.weight(1f)) {
            Text(a.note.text, style = MaterialTheme.typography.bodyMedium)
            Text(a.reason, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onSurfaceVariant)
        }
    }
}

private fun formatLatLon(ll: LatLon) = String.format(Locale.US, "%.5f, %.5f", ll.lat, ll.lon)
