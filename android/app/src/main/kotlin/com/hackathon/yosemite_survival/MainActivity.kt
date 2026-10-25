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
import com.hackathon.yosemite_survival.map3d.Map3dActivity
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch

class MainActivity : FlutterActivity() {
  private val main = Handler(Looper.getMainLooper())
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
  private var sink: EventChannel.EventSink? = null
  private lateinit var ai: AiCore
  private var map3dResult: MethodChannel.Result? = null

  @Deprecated("Activity result API") // startActivityForResult is what FlutterActivity offers
  override fun onActivityResult(requestCode: Int, resultCode: Int, data: android.content.Intent?) {
    super.onActivityResult(requestCode, resultCode, data)
    if (requestCode == MAP3D_REQUEST) {
      map3dResult?.success(resultCode == RESULT_OK && data?.getBooleanExtra(Map3dActivity.RESULT_HOME, false) == true)
      map3dResult = null
    }
  }

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

    // 3D MAP chip on the home screen: offline terrain + aerial imagery (map3d/Map3dActivity)
    MethodChannel(messenger, "survival/map3d").setMethodCallHandler { call, result ->
      when (call.method) {
        "available" -> result.success(Map3dActivity.available(this))
        "open" -> {
          // answered when the 3D map closes: true if the user tapped "Home"
          map3dResult?.success(false)
          map3dResult = result
          startActivityForResult(
            Map3dActivity.intent(this, call.argument<Double>("lat"), call.argument<Double>("lon")), MAP3D_REQUEST)
        }
        else -> result.notImplemented()
      }
    }

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
                call.argument<Boolean>("newConversation") ?: false,
              )
              result.success(null)
            }
            "resetConversation" -> { ai.resetConversation(); result.success(null) }
            "cancelGenerate" -> { ai.cancelGenerate(); result.success(null) }
            "speak" -> { ai.speak(call.argument<String>("text")!!); result.success(null) }
            "stopSpeaking" -> { ai.stopSpeaking(); result.success(null) }
            "setVoice" -> {
              ai.setVoice(call.argument<String>("voice"), (call.argument<Double>("speed") ?: 0.85).toFloat())
              result.success(null)
            }
            "unloadLlm" -> { ai.unloadLlm(); result.success(null) }
            "status" -> result.success(mapOf("llmLoaded" to ai.llmLoaded()))
            "metrics" -> result.success(ai.metrics())
            // adb shell am start -n com.hackathon.yosemite_survival/.MainActivity --ez calibrate true
            "launchFlags" -> result.success(mapOf("calibrate" to (intent?.getBooleanExtra("calibrate", false) ?: false)))
            "listModels" -> result.success(ai.listAvailableModels())
            "setModel" -> {
              val model = call.argument<String>("model")!!
              val backend = call.argument<String>("backend") ?: "AUTO"
              ai.setModel(model, backend)
              result.success(null)
            }
            "setTtsEngine" -> {
              val engine = call.argument<String>("engine") ?: "kitten"
              ai.setTtsEngine(engine)
              result.success(null)
            }
            "setTtsVoice" -> {
              val voice = call.argument<String>("voice")
              ai.setTtsVoice(voice)
              result.success(null)
            }
            "setTtsSpeed" -> {
              val speed = (call.argument<Double>("speed") ?: 1.0).toFloat()
              ai.setTtsSpeed(speed)
              result.success(null)
            }
            "listTtsVoices" -> result.success(ai.listTtsVoices())
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

private const val MAP3D_REQUEST = 3301
