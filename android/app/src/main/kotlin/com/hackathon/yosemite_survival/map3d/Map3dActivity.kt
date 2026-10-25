package com.hackathon.yosemite_survival.map3d

import android.annotation.SuppressLint
import android.app.Activity
import android.content.Context
import android.content.Intent
import android.content.pm.ApplicationInfo
import android.database.sqlite.SQLiteDatabase
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.text.Editable
import android.text.TextWatcher
import android.util.Log
import android.util.TypedValue
import android.view.Gravity
import android.view.View
import android.view.ViewGroup.LayoutParams.MATCH_PARENT
import android.view.ViewGroup.LayoutParams.WRAP_CONTENT
import android.view.inputmethod.EditorInfo
import android.view.inputmethod.InputMethodManager
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebResourceResponse
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Button
import android.widget.EditText
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.ScrollView
import android.widget.TextView
import androidx.webkit.WebViewAssetLoader
import org.json.JSONObject
import java.io.ByteArrayInputStream
import java.io.File
import java.util.Locale

private const val TAG = "Map3D"
private const val ORIGIN = "https://appassets.androidplatform.net"
// Flutter assets (pubspec.yaml), shared with iOS; inside the APK they live under flutter_assets/
private const val MAP_DIR = "flutter_assets/assets/maps/yosemite"
private const val PAGE = "flutter_assets/assets/map3d/index.html"
private val REQUIRED = mapOf("pdf" to "yosemite.mbtiles", "terrain" to "yosemite-terrain.mbtiles")
private val OPTIONAL = mapOf("imagery" to "yosemite-imagery.mbtiles")

// SHERPA palette (lib/ui/theme.dart)
private val INK = Color.parseColor("#142019")
private val INK_MUTED = Color.parseColor("#485B4F")
private val CARD = Color.WHITE
private val PAPER = Color.parseColor("#F4F7F4")
private val CLAY = Color.parseColor("#D94819")
private val WATER = Color.parseColor("#1F6FA8")
private val LINE = Color.parseColor("#D9E0D9")

/**
 * Offline 3D map of Yosemite: aerial imagery (or the printed NPS park map) draped over real
 * terrain, in MapLibre GL running in a WebView on the phone's GPU. The page (Flutter assets/map3d) and
 * every tile are served from the app by WebViewAssetLoader, so it works with no network and no
 * INTERNET permission. Under the map, a search box finds a place on the NPS park map, flies there
 * and lists the map's safety guidance for that spot (or for the GPS position).
 *
 * Opened from the 3D MAP button on the Flutter home screen; "‹ Home" returns to the dashboard.
 */
class Map3dActivity : Activity() {
  private var webView: WebView? = null
  private var pageLoaded = false
  private val pending = mutableListOf<String>()  // JS calls queued until the page has loaded
  private val main = Handler(Looper.getMainLooper())
  private var pack: MapPack? = null

  private lateinit var title: TextView
  private lateinit var subtitle: TextView
  private lateinit var results: LinearLayout
  private lateinit var guidance: LinearLayout
  private lateinit var search: EditText

  @SuppressLint("SetJavaScriptEnabled")
  override fun onCreate(savedInstanceState: Bundle?) {
    super.onCreate(savedInstanceState)
    val store = TileStore.open(this) ?: return finish()
    pack = runCatching {
      assets.open("$MAP_DIR/mappack.json").bufferedReader().use { MapPack.parse(it.readText()) }
    }.onFailure { Log.w(TAG, "no map pack: search and guidance disabled", it) }.getOrNull()
    val lat = intent.getDoubleExtra(EXTRA_LAT, Double.NaN)
    val lon = intent.getDoubleExtra(EXTRA_LON, Double.NaN)
    val me = if (lat.isNaN() || lon.isNaN()) null else LatLon(lat, lon)

    if (applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) {
      WebView.setWebContentsDebuggingEnabled(true)
    }
    val web = WebView(this).apply {
      settings.javaScriptEnabled = true
      settings.allowFileAccess = false
      settings.allowContentAccess = false
      val loader = assetLoader(context, store)
      webViewClient = object : WebViewClient() {
        override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest) =
          loader.shouldInterceptRequest(request.url)
      }
      addJavascriptInterface(object {
        @JavascriptInterface
        fun onEvent(message: String) {
          Log.i(TAG, message)
          if (message == "loaded") main.post { pageLoaded = true; pending.forEach { js(it) }; pending.clear() }
        }
      }, "Host")
      val imgMax = if (store.has("imagery")) store.metadata("imagery", "maxzoom") ?: "13" else "0"
      loadUrl("$ORIGIN/assets/$PAGE?tiles=/tiles" +
        "&pdfMax=${store.metadata("pdf", "maxzoom") ?: "13"}" +
        "&demMax=${store.metadata("terrain", "maxzoom") ?: "11"}" +
        "&imgMax=$imgMax&bounds=${store.metadata("pdf", "bounds") ?: ""}")
    }
    webView = web

    val home = Button(this).apply {
      text = "‹  Home"
      isAllCaps = false
      setTextColor(CARD)
      textSize = 15f
      typeface = Typeface.DEFAULT_BOLD
      background = pill(INK)
      setPadding(dp(16), dp(6), dp(18), dp(6))
      minHeight = 0; minimumHeight = 0
      contentDescription = "Back to the home screen"
      setOnClickListener { setResult(RESULT_OK, Intent().putExtra(RESULT_HOME, true)); finish() }
    }
    val mapArea = FrameLayout(this).apply {
      addView(web, FrameLayout.LayoutParams(MATCH_PARENT, MATCH_PARENT))
      addView(home, FrameLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT, Gravity.TOP or Gravity.START).apply {
        setMargins(dp(12), dp(12), 0, 0)
      })
    }

    val panel = buildPanel(me)
    val root = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setBackgroundColor(PAPER)
      addView(mapArea, LinearLayout.LayoutParams(MATCH_PARENT, 0, 1f))
      addView(panel, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT))
      // Android 15+ draws edge-to-edge: keep the map and the panel clear of the system bars
      setOnApplyWindowInsetsListener { v, insets ->
        @Suppress("DEPRECATION")
        v.setPadding(insets.systemWindowInsetLeft, insets.systemWindowInsetTop,
                     insets.systemWindowInsetRight, maxOf(insets.systemWindowInsetBottom, 0))
        insets
      }
    }
    setContentView(root)
    if (me != null) showMe(me) else showIntro()
  }

  override fun onDestroy() {
    webView?.destroy()  // frees the GL context
    webView = null
    super.onDestroy()
  }

  // -- panel under the map ---------------------------------------------------------------------

  private fun buildPanel(me: LatLon?): View {
    search = EditText(this).apply {
      hint = "Search a place, e.g. Half Dome"
      isSingleLine = true
      imeOptions = EditorInfo.IME_ACTION_SEARCH
      textSize = 16f
      setTextColor(INK)
      setHintTextColor(INK_MUTED)
      background = box(CARD, LINE)
      setPadding(dp(14), dp(10), dp(14), dp(10))
      contentDescription = "Search a place"
      isEnabled = pack != null
      addTextChangedListener(object : TextWatcher {
        override fun afterTextChanged(s: Editable?) = updateResults(s?.toString().orEmpty())
        override fun beforeTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
        override fun onTextChanged(s: CharSequence?, a: Int, b: Int, c: Int) {}
      })
      setOnEditorActionListener { _, _, _ ->
        pack?.search(text.toString(), limit = 1)?.firstOrNull()?.let { choose(it.place) }
        true
      }
    }
    val myLocation = Button(this).apply {
      text = "◎  My location"
      isAllCaps = false
      setTextColor(INK)
      textSize = 14f
      background = pill(CARD, INK)
      setPadding(dp(14), dp(6), dp(14), dp(6))
      minHeight = 0; minimumHeight = 0
      contentDescription = "Guidance for my location"
      isEnabled = me != null && pack != null
      alpha = if (isEnabled) 1f else 0.4f
      setOnClickListener { me?.let { showMe(it) } }
    }
    val searchRow = LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      gravity = Gravity.CENTER_VERTICAL
      addView(search, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f))
      addView(myLocation, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT).apply { leftMargin = dp(8) })
    }
    results = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL; visibility = View.GONE; background = box(CARD, LINE) }
    title = TextView(this).apply { textSize = 18f; setTextColor(INK); typeface = Typeface.DEFAULT_BOLD }
    subtitle = TextView(this).apply { textSize = 13f; setTextColor(INK_MUTED) }
    guidance = LinearLayout(this).apply { orientation = LinearLayout.VERTICAL }
    val details = ScrollView(this).apply {
      addView(LinearLayout(context).apply {
        orientation = LinearLayout.VERTICAL
        addView(title)
        addView(subtitle)
        addView(guidance, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(8) })
      })
    }
    return LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      setBackgroundColor(PAPER)
      setPadding(dp(14), dp(12), dp(14), dp(10))
      addView(searchRow)
      addView(results, LinearLayout.LayoutParams(MATCH_PARENT, WRAP_CONTENT).apply { topMargin = dp(6) })
      addView(details, LinearLayout.LayoutParams(MATCH_PARENT, dp(220)).apply { topMargin = dp(10) })
    }
  }

  private fun updateResults(query: String) {
    results.removeAllViews()
    val hits = if (query.trim().length >= 2) pack?.search(query, limit = 5).orEmpty() else emptyList()
    results.visibility = if (hits.isEmpty()) View.GONE else View.VISIBLE
    for (hit in hits) {
      results.addView(TextView(this).apply {
        text = "${hit.place.text}\n${formatLatLon(hit.place.location)}"
        textSize = 15f
        setTextColor(INK)
        if (hit.exact) typeface = Typeface.DEFAULT_BOLD
        setPadding(dp(14), dp(8), dp(14), dp(8))
        contentDescription = "Result: ${hit.place.text}"
        setOnClickListener { choose(hit.place) }
      })
    }
  }

  private fun choose(place: Place) {
    val p = pack ?: return
    search.setText(place.text)
    search.setSelection(place.text.length)
    results.visibility = View.GONE
    hideKeyboard()
    js("showPlace(${place.location.lat}, ${place.location.lon}, ${JSONObject.quote(place.text)})")
    show(place.text, formatLatLon(place.location), p.guidanceFor(place))
  }

  private fun showMe(me: LatLon) {
    val p = pack
    js("showMe(${me.lat}, ${me.lon})")
    if (p == null) return show("Your location", formatLatLon(me), emptyList())
    val where = formatLatLon(me) + if (p.isOnMap(me)) "" else " · outside the park map"
    show("Your location", where, p.guidanceAt(me))
  }

  private fun showIntro() = show(
    "Yosemite National Park",
    if (pack != null) "Search a place to see it in 3D with the park map's guidance" else "Place search isn't available",
    emptyList(),
  )

  /** Title, coordinates and the guidance list, park-wide notes last. */
  private fun show(heading: String, where: String, local: List<Advisory>) {
    title.text = heading
    subtitle.text = where
    guidance.removeAllViews()
    if (pack != null && heading != "Yosemite National Park" && local.isEmpty()) {
      guidance.addView(TextView(this).apply {
        text = "No map notes for this spot."
        textSize = 14f
        setTextColor(INK_MUTED)
      })
    }
    local.forEach { guidance.addView(advisoryRow(it.note, it.reason)) }
    pack?.parkWide?.forEach { guidance.addView(advisoryRow(it, "park-wide")) }
  }

  private fun advisoryRow(note: Note, reason: String): View {
    val warning = note.severity == Severity.WARNING
    val badge = TextView(this).apply {
      text = if (warning) "WARNING" else "INFO"
      textSize = 11f
      typeface = Typeface.DEFAULT_BOLD
      setTextColor(CARD)
      background = box(if (warning) CLAY else WATER, null, radius = 4f)
      setPadding(dp(6), dp(2), dp(6), dp(2))
    }
    val body = LinearLayout(this).apply {
      orientation = LinearLayout.VERTICAL
      addView(TextView(context).apply { text = note.text; textSize = 14f; setTextColor(INK) })
      addView(TextView(context).apply { text = reason; textSize = 12f; setTextColor(INK_MUTED) })
    }
    return LinearLayout(this).apply {
      orientation = LinearLayout.HORIZONTAL
      setPadding(0, dp(6), 0, dp(6))
      addView(badge, LinearLayout.LayoutParams(WRAP_CONTENT, WRAP_CONTENT))
      addView(body, LinearLayout.LayoutParams(0, WRAP_CONTENT, 1f).apply { leftMargin = dp(10) })
    }
  }

  // -- helpers ---------------------------------------------------------------------------------

  private fun js(code: String) {
    if (pageLoaded) webView?.evaluateJavascript(code, null) else pending += code
  }

  private fun hideKeyboard() {
    getSystemService(InputMethodManager::class.java)?.hideSoftInputFromWindow(search.windowToken, 0)
    search.clearFocus()
  }

  private fun dp(v: Int) = TypedValue.applyDimension(TypedValue.COMPLEX_UNIT_DIP, v.toFloat(), resources.displayMetrics).toInt()

  private fun pill(fill: Int, stroke: Int? = null) = box(fill, stroke, radius = 999f)

  private fun box(fill: Int, stroke: Int?, radius: Float = 10f) = GradientDrawable().apply {
    setColor(fill)
    cornerRadius = radius * resources.displayMetrics.density
    if (stroke != null) setStroke(dp(1), stroke)
  }

  private fun formatLatLon(ll: LatLon) = String.format(Locale.US, "%.5f, %.5f", ll.lat, ll.lon)

  companion object {
    const val EXTRA_LAT = "lat"
    const val EXTRA_LON = "lon"
    /** Result extra: true when the user tapped "‹ Home" (go to the home dashboard). */
    const val RESULT_HOME = "home"

    /** True when the 3D tilesets are bundled (scripts/build_android_assets.py --tiles --terrain). */
    fun available(context: Context): Boolean = REQUIRED.values.all { assetExists(context, "$MAP_DIR/$it") }

    fun intent(context: Context, lat: Double?, lon: Double?): Intent =
      Intent(context, Map3dActivity::class.java).apply {
        if (lat != null && lon != null) {
          putExtra(EXTRA_LAT, lat)
          putExtra(EXTRA_LON, lon)
        }
      }

    private fun assetExists(context: Context, path: String) =
      runCatching { context.assets.open(path).close() }.isSuccess
  }
}

/**
 * The 3D tilesets as MBTiles in the app's assets: park map ("pdf") and elevation ("terrain") are
 * required, aerial imagery ("imagery") optional. SQLite can't open a file inside the APK, so each
 * is copied to app storage once (again only if the bundled file changes size).
 */
private class TileStore(private val dbs: Map<String, SQLiteDatabase>) {
  fun has(name: String) = name in dbs

  fun tile(name: String, z: Int, x: Int, y: Int): ByteArray? {
    val db = dbs[name] ?: return null
    db.rawQuery(
      "SELECT tile_data FROM tiles WHERE zoom_level=? AND tile_column=? AND tile_row=?",
      arrayOf(z.toString(), x.toString(), ((1 shl z) - 1 - y).toString()),  // MBTiles rows are TMS
    ).use { c -> return if (c.moveToFirst()) c.getBlob(0) else null }
  }

  fun metadata(name: String, key: String): String? =
    dbs[name]?.rawQuery("SELECT value FROM metadata WHERE name=?", arrayOf(key))?.use { c ->
      if (c.moveToFirst()) c.getString(0) else null
    }

  companion object {
    fun open(context: Context): TileStore? {
      val dbs = mutableMapOf<String, SQLiteDatabase>()
      for ((name, file) in REQUIRED + OPTIONAL) {
        val db = openBundled(context, file)
        if (db != null) dbs[name] = db else if (name in REQUIRED) return null
      }
      return TileStore(dbs)
    }

    private fun openBundled(context: Context, file: String): SQLiteDatabase? {
      val asset = "$MAP_DIR/$file"
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

/** Serves assets/map3d and /tiles/<name>/z/x/y.<ext> from the MBTiles, all inside the app. */
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
