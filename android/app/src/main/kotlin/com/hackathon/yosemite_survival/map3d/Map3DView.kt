package com.hackathon.yosemite_survival.map3d

import android.annotation.SuppressLint
import android.content.Context
import android.content.pm.ApplicationInfo
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.view.View
import android.view.ViewGroup
import android.webkit.JavascriptInterface
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.webkit.WebViewAssetLoader
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.StandardMessageCodec
import io.flutter.plugin.platform.PlatformView
import io.flutter.plugin.platform.PlatformViewFactory
import org.json.JSONArray
import org.json.JSONObject

// Adapted from PR #5 (Chengjiang Long), app/survival/demo/Map3D.kt: the same offline MapLibre page
// in a WebView, hosted as a Flutter platform view instead of a Compose view. The park map and
// terrain tiles are plain assets (tool/build_*3d.py), so no MBTiles / SQLite is needed.

private const val TAG = "Map3D"
private const val ORIGIN = "https://appassets.androidplatform.net"

/** Registered in MainActivity as "sherpa/map3d"; creation params: {bounds: "w,s,e,n"}. */
class Map3DViewFactory(private val messenger: BinaryMessenger) : PlatformViewFactory(StandardMessageCodec.INSTANCE) {
  override fun create(context: Context, viewId: Int, args: Any?): PlatformView {
    @Suppress("UNCHECKED_CAST")
    val params = args as? Map<String, Any?> ?: emptyMap()
    return Map3DView(context, MethodChannel(messenger, "sherpa/map3d/$viewId"), params["bounds"] as? String)
  }
}

/**
 * Terrain-draped 3D park map (MapLibre GL in a WebView, on the phone's GPU through WebGL).
 * Dart -> page: showMe, showTrack, showRoute, showPlace, centreOnMe.
 * Page -> Dart: "event" with "webgl: 2" | "loaded" | "unsupported" | "error: …".
 */
@SuppressLint("SetJavaScriptEnabled")
class Map3DView(context: Context, private val channel: MethodChannel, bounds: String?) : PlatformView {
  private val main = Handler(Looper.getMainLooper())
  private var loaded = false
  private val pending = mutableListOf<String>() // calls made before the page finished loading

  private val webView: WebView =
    WebView(context).apply {
      // debug builds only: lets chrome://inspect look inside the page
      if (context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0) WebView.setWebContentsDebuggingEnabled(true)
      // the page's CSS height: 100% needs a sized viewport
      layoutParams = ViewGroup.LayoutParams(ViewGroup.LayoutParams.MATCH_PARENT, ViewGroup.LayoutParams.MATCH_PARENT)
      settings.javaScriptEnabled = true
      settings.allowFileAccess = false
      settings.allowContentAccess = false
      addJavascriptInterface(PageEvents(), "Host")
      // serves the APK's assets: the page, MapLibre, and the park-map and terrain tiles
      val loader = WebViewAssetLoader.Builder().addPathHandler("/assets/", WebViewAssetLoader.AssetsPathHandler(context)).build()
      webViewClient =
        object : WebViewClient() {
          override fun shouldInterceptRequest(view: WebView, request: WebResourceRequest) =
            loader.shouldInterceptRequest(request.url)
        }
      val b = bounds?.let { "&bounds=$it" } ?: ""
      loadUrl("$ORIGIN/assets/map3d/index.html?v=1$b")
    }

  init {
    channel.setMethodCallHandler { call, result ->
      val js =
        when (call.method) {
          "showMe" ->
            "showMe(${call.argument<Double>("lat")}, ${call.argument<Double>("lon")}, ${call.argument<Boolean>("pinned") == true})"
          "showPlace" ->
            "showPlace(${call.argument<Double>("lat")}, ${call.argument<Double>("lon")}, ${JSONObject.quote(call.argument<String>("name") ?: "")})"
          "showTrack" -> "showTrack(${lonLat(call.argument<List<Double>>("points"))})"
          "showRoute" ->
            "showRoute(${lonLat(call.argument<List<Double>>("points"))}, ${JSONObject.quote(call.argument<String>("name") ?: "")})"
          "centreOnMe" -> "centreOnMe()"
          else -> null
        }
      if (js == null) {
        result.notImplemented()
      } else {
        run(js)
        result.success(null)
      }
    }
  }

  /** flat [lat, lon, lat, lon, ...] from Dart -> [[lon, lat], ...] for MapLibre */
  private fun lonLat(flat: List<Double>?): String {
    val out = JSONArray()
    if (flat != null) {
      var i = 0
      while (i + 1 < flat.size) {
        out.put(JSONArray().put(flat[i + 1]).put(flat[i]))
        i += 2
      }
    }
    return out.toString()
  }

  private fun run(js: String) {
    if (loaded) webView.evaluateJavascript(js, null) else pending += js
  }

  private inner class PageEvents {
    // called by the page on a WebView thread; hand over to the main thread
    @JavascriptInterface
    fun onEvent(message: String) {
      Log.i(TAG, message)
      main.post {
        if (message == "loaded") {
          loaded = true
          pending.forEach { webView.evaluateJavascript(it, null) }
          pending.clear()
        }
        channel.invokeMethod("event", message)
      }
    }
  }

  override fun getView(): View = webView

  override fun dispose() {
    channel.setMethodCallHandler(null)
    webView.destroy() // frees the GL context when leaving 3D
  }
}
