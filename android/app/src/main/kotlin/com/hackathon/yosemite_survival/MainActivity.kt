package com.hackathon.yosemite_survival

import android.Manifest
import android.content.ComponentCallbacks2
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
  private val main = Handler(Looper.getMainLooper())
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private var sink: EventChannel.EventSink? = null
  private lateinit var ai: AiCore

  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    val messenger = flutterEngine.dartExecutor.binaryMessenger
    ai = AiCore(applicationContext) { event -> main.post { sink?.success(event) } }

    EventChannel(messenger, "survival/ai/events")
      .setStreamHandler(
        object : EventChannel.StreamHandler {
          override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
            sink = events
          }

          override fun onCancel(arguments: Any?) {
            sink = null
          }
        }
      )

    MethodChannel(messenger, "survival/ai").setMethodCallHandler { call, result ->
      scope.launch {
        try {
          when (call.method) {
            "requestMic" -> result.success(requestMic())
            "modelsDir" -> result.success(getExternalFilesDir(null)?.resolve("models")?.absolutePath)
            "init" -> result.success(ai.init(call.argument<String>("modelsDir")!!))
            "startListening" -> { ai.startListening(); result.success(null) }
            "stopListening" -> result.success(ai.stopListening())
            "classify" ->
              result.success(ai.classify(call.argument<String>("text")!!, call.argument<String>("questions")!!))
            "generate" -> {
              ai.generate(
                call.argument<String>("system")!!,
                call.argument<String>("prompt")!!,
                call.argument<Boolean>("speak") ?: true,
              )
              result.success(null)
            }
            "cancelGenerate" -> { ai.cancelGenerate(); result.success(null) }
            "speak" -> { ai.speak(call.argument<String>("text")!!); result.success(null) }
            "stopSpeaking" -> { ai.stopSpeaking(); result.success(null) }
            "unloadLlm" -> { ai.unloadLlm(); result.success(null) }
            "status" -> result.success(mapOf("llmLoaded" to ai.llmLoaded()))
            else -> result.notImplemented()
          }
        } catch (e: Throwable) {
          result.error("AI_ERROR", e.message ?: e.javaClass.simpleName, null)
        }
      }
    }
  }

  private var micGranted: kotlinx.coroutines.CompletableDeferred<Boolean>? = null

  private suspend fun requestMic(): Boolean {
    if (checkSelfPermission(Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) return true
    val waiter = kotlinx.coroutines.CompletableDeferred<Boolean>().also { micGranted = it }
    requestPermissions(arrayOf(Manifest.permission.RECORD_AUDIO), MIC_REQUEST)
    return waiter.await()
  }

  override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
    super.onRequestPermissionsResult(requestCode, permissions, grantResults)
    if (requestCode == MIC_REQUEST) {
      micGranted?.complete(grantResults.firstOrNull() == PackageManager.PERMISSION_GRANTED)
      micGranted = null
    }
  }

  override fun onTrimMemory(level: Int) {
    super.onTrimMemory(level)
    if (level >= ComponentCallbacks2.TRIM_MEMORY_BACKGROUND && ::ai.isInitialized) ai.trimMemory()
  }

  companion object {
    private const val MIC_REQUEST = 7
  }
}
