package app.survival.demo

import android.Manifest
import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.BitmapFactory
import android.location.Location
import android.location.LocationManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.isSystemInDarkTheme
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.safeDrawingPadding
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.darkColorScheme
import androidx.compose.material3.lightColorScheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.produceState
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.ExperimentalComposeUiApi
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.ImageBitmap
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import app.survival.mappack.LatLon
import app.survival.mappack.MapPack
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

private const val MAP_DIR = "maps/yosemite"

class MainActivity : ComponentActivity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        setContent {
            MaterialTheme(colorScheme = if (isSystemInDarkTheme()) darkColorScheme() else lightColorScheme()) {
                Surface(Modifier.fillMaxSize()) { App() }
            }
        }
    }
}

/** The map pack, its image and (when bundled) the 3D tilesets, loaded once off the main thread. */
class LoadedMap(val pack: MapPack, val image: ImageBitmap, val tiles: TileStore?)

private suspend fun loadMap(context: Context): LoadedMap = withContext(Dispatchers.IO) {
    val pack = context.assets.open("$MAP_DIR/mappack.json").bufferedReader().use { MapPack.parse(it.readText()) }
    val options = BitmapFactory.Options().apply { inPreferredConfig = android.graphics.Bitmap.Config.RGB_565 }
    val bitmap = context.assets.open("$MAP_DIR/${pack.pack.image.file}").use { BitmapFactory.decodeStream(it, null, options) }
        ?: error("cannot decode map image")
    val tiles = TileStore.open(context, MAP_DIR, mapOf("pdf" to "yosemite.mbtiles", "terrain" to "yosemite-terrain.mbtiles"))
    LoadedMap(pack, bitmap.asImageBitmap(), tiles)
}

@OptIn(ExperimentalComposeUiApi::class)
@Composable
private fun App() {
    val context = LocalContext.current
    val map by produceState<LoadedMap?>(null) { value = loadMap(context) }
    var myLocation by remember { mutableStateOf<LatLon?>(null) }
    var locationError by remember { mutableStateOf<String?>(null) }

    val permissionLauncher = rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { granted ->
        if (granted.values.any { it }) {
            requestLocation(context, onFix = { myLocation = it; locationError = null }, onError = { locationError = it })
        } else {
            locationError = "Location permission denied"
        }
    }
    val locate = {
        if (hasLocationPermission(context)) {
            requestLocation(context, onFix = { myLocation = it; locationError = null }, onError = { locationError = it })
        } else {
            permissionLauncher.launch(arrayOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION))
        }
    }

    Box(Modifier.fillMaxSize().safeDrawingPadding().semantics { testTagsAsResourceId = true }) {
        val loaded = map
        if (loaded == null) {
            Column(Modifier.align(Alignment.Center), horizontalAlignment = Alignment.CenterHorizontally) {
                CircularProgressIndicator()
                Text("Loading map…", Modifier.padding(top = 12.dp))
            }
        } else {
            MapScreen(loaded, myLocation, locationError, onLocate = locate, modifier = Modifier.fillMaxWidth())
        }
    }
}

private fun hasLocationPermission(context: Context) =
    listOf(Manifest.permission.ACCESS_FINE_LOCATION, Manifest.permission.ACCESS_COARSE_LOCATION).any {
        ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
    }

@SuppressLint("MissingPermission") // callers check hasLocationPermission first
private fun requestLocation(context: Context, onFix: (LatLon) -> Unit, onError: (String) -> Unit) {
    val lm = context.getSystemService(LocationManager::class.java)
    val provider = when {
        lm.isProviderEnabled(LocationManager.GPS_PROVIDER) -> LocationManager.GPS_PROVIDER
        Build.VERSION.SDK_INT >= Build.VERSION_CODES.S && lm.isProviderEnabled(LocationManager.FUSED_PROVIDER) -> LocationManager.FUSED_PROVIDER
        lm.isProviderEnabled(LocationManager.NETWORK_PROVIDER) -> LocationManager.NETWORK_PROVIDER
        else -> return onError("Location is turned off")
    }
    val deliver = { location: Location? ->
        if (location != null) onFix(LatLon(location.latitude, location.longitude)) else onError("No location fix yet")
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
        lm.getCurrentLocation(provider, null, ContextCompat.getMainExecutor(context)) { deliver(it) }
    } else {
        deliver(lm.getLastKnownLocation(provider))
    }
}
