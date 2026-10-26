package app.survival.demo

import android.annotation.SuppressLint
import android.content.Context
import android.database.sqlite.SQLiteDatabase
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import androidx.webkit.WebViewAssetLoader
import app.survival.mappack.LatLon
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File

private const val TAG = "Map3D"
private const val ORIGIN = "https://appassets.androidplatform.net"

/**
 * The offline tilesets for the 3D view, MBTiles shipped in the app's assets: the park map ("pdf")
 * and elevation ("terrain") are required, aerial imagery ("imagery") is optional. SQLite can't
 * open a file inside the APK, so each is copied to app storage once (again only if the bundled
 * file changes size).
 */
class TileStore private constructor(private val dbs: Map<String, SQLiteDatabase>) {
    fun tile(name: String, z: Int, x: Int, y: Int): ByteArray? {
        val db = dbs[name] ?: return null
        db.rawQuery(
            "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
            arrayOf(z.toString(), x.toString(), ((1 shl z) - 1 - y).toString()),  // MBTiles rows are TMS
        ).use { c -> return if (c.moveToFirst()) c.getBlob(0) else null }
    }

    fun has(name: String) = name in dbs

    fun metadata(name: String, key: String): String? =
        dbs[name]?.rawQuery("SELECT value FROM metadata WHERE name=?", arrayOf(key))?.use { c ->
            if (c.moveToFirst()) c.getString(0) else null
        }

    companion object {
        /** null when a required tileset isn't bundled (run scripts/build_android_assets.py --tiles --terrain). */
        fun open(context: Context, mapDir: String, required: Map<String, String>,
                 optional: Map<String, String> = emptyMap()): TileStore? {
            val dbs = mutableMapOf<String, SQLiteDatabase>()
            for ((name, file) in required + optional) {
                val db = openBundled(context, "$mapDir/$file", file)
                if (db != null) dbs[name] = db else if (name in required) return null
            }
            return TileStore(dbs)
        }

        private fun openBundled(context: Context, asset: String, file: String): SQLiteDatabase? {
            val target = File(context.noBackupFilesDir, "tiles/$file")
            val size = runCatching { context.assets.openFd(asset).use { it.length } }.getOrNull()
            if (!target.exists() || (size != null && size != target.length())) {
                target.parentFile?.mkdirs()
                runCatching {
                    context.assets.open(asset).use { input -> target.outputStream().use { input.copyTo(it) } }
                }.onFailure { Log.w(TAG, "missing tileset $asset"); return null }
            }
            return SQLiteDatabase.openDatabase(target.path, null, SQLiteDatabase.OPEN_READONLY)
        }
    }
}

/**
 * Serves the bundled 3D page (assets/map3d) and tiles at /tiles/<name>/z/x/y.<ext> to the
 * WebView, all from the app: no network.
 */
private fun assetLoader(context: Context, store: TileStore): WebViewAssetLoader =
    WebViewAssetLoader.Builder()
        .addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context))
        .addPathHandler("/tiles/") { path ->
            val m = Regex("""^(\w+)/(\d+)/(\d+)/(\d+)\.(\w+)$""").find(path) ?: return@addPathHandler null
            val (name, z, x, y, ext) = m.destructured
            val data = store.tile(name, z.toInt(), x.toInt(), y.toInt())
            val mime = if (ext == "png") "image/png" else "image/jpeg"
            if (data == null) {
                WebResourceResponse(mime, null, 404, "Not Found", emptyMap(), ByteArrayInputStream(ByteArray(0)))
            } else {
                WebResourceResponse(mime, null, ByteArrayInputStream(data))
            }
        }
        .build()

/** Events from the page: "webgl: 2", "loaded", "unsupported", "error: …". */
private class PageEvents(private val listener: (String) -> Unit) {
    private val main = Handler(Looper.getMainLooper())

    // Called by the page on a WebView thread; hand over to the main thread for Compose state.
    @JavascriptInterface
    fun onEvent(message: String) {
        Log.i(TAG, message)
        main.post { listener(message) }
    }
}

/**
 * 3D map: aerial imagery (or the park map) draped over terrain, in MapLibre GL in a WebView
 * using the phone's GPU through WebGL.
 * [place] gets a red pin and the camera flies to it; [me] is shown as a blue dot.
 */
@SuppressLint("SetJavaScriptEnabled")
@Composable
fun Map3D(store: TileStore, place: Pair<LatLon, String>?, me: LatLon?, modifier: Modifier = Modifier,
          onStatus: (String) -> Unit = {}) {
    val context = LocalContext.current
    var loaded by remember { mutableStateOf(false) }
    val webView = remember {
        // debug builds only: lets chrome://inspect (or adb + DevTools) look inside the page
        if (context.applicationInfo.flags and android.content.pm.ApplicationInfo.FLAG_DEBUGGABLE != 0) {
            WebView.setWebContentsDebuggingEnabled(true)
        }
        WebView(context).apply {
            // With AndroidView's default WRAP_CONTENT the page viewport takes its content height,
            // so the map's CSS height: 100% would be 0.
            layoutParams = android.view.ViewGroup.LayoutParams(
                android.view.ViewGroup.LayoutParams.MATCH_PARENT, android.view.ViewGroup.LayoutParams.MATCH_PARENT)
            settings.javaScriptEnabled = true
            settings.allowFileAccess = false
            settings.allowContentAccess = false
            addJavascriptInterface(PageEvents { msg ->
                if (msg == "loaded") loaded = true
                onStatus(msg)
            }, "Host")
            val loader = assetLoader(context, store)
            webViewClient = object : WebViewClient() {
                override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest) =
                    loader.shouldInterceptRequest(request.url)
            }
            val pdfMax = store.metadata("pdf", "maxzoom") ?: "13"
            val demMax = store.metadata("terrain", "maxzoom") ?: "11"
            val imgMax = if (store.has("imagery")) store.metadata("imagery", "maxzoom") ?: "13" else "0"
            val bounds = store.metadata("pdf", "bounds") ?: ""
            loadUrl("$ORIGIN/assets/map3d/index.html?tiles=/tiles&pdfMax=$pdfMax&demMax=$demMax&imgMax=$imgMax&bounds=$bounds")
        }
    }
    DisposableEffect(Unit) { onDispose { webView.destroy() } }  // frees the GL context when leaving 3D

    LaunchedEffect(loaded, place) {
        if (loaded && place != null) {
            val (ll, name) = place
            webView.evaluateJavascript("showPlace(${ll.lat}, ${ll.lon}, ${JSONObject.quote(name)})", null)
        }
    }
    LaunchedEffect(loaded, me) {
        if (loaded && me != null) webView.evaluateJavascript("showMe(${me.lat}, ${me.lon})", null)
    }
    AndroidView(factory = { webView }, modifier = modifier)
}
