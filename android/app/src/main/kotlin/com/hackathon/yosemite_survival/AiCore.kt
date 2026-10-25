package com.hackathon.yosemite_survival

import android.content.Context
import android.os.Bundle
import android.speech.tts.TextToSpeech
import android.speech.tts.UtteranceProgressListener
import android.util.Log
import com.google.ai.edge.litertlm.Content
import com.google.ai.edge.litertlm.Contents
import com.google.ai.edge.litertlm.Message
import com.hackathon.yosemite_survival.asr.LiteRtTranscriber
import com.hackathon.yosemite_survival.laya.LayaEngine
import com.hackathon.yosemite_survival.laya.LayaJson
import com.hackathon.yosemite_survival.llm.ChatEngine
import com.hackathon.yosemite_survival.loop.MicSource
import com.hackathon.yosemite_survival.loop.SentenceSplitter
import com.hackathon.yosemite_survival.loop.SentenceStream
import com.hackathon.yosemite_survival.loop.SpeechPlayer
import com.hackathon.yosemite_survival.tts.LiteRtSpeaker
import java.io.File
import java.util.Locale
import java.util.UUID
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext

/**
 * Owns the on-device models: Zipformer (speech to text), Laya (router), Gemma (LLM, loaded
 * lazily) and TTS (KittenTTS or System TTS). Every public call is a suspend function; events go to [emit].
 */
class AiCore(private val context: Context, private val emit: (Map<String, Any?>) -> Unit) {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private val llmLock = Mutex()
  private lateinit var modelsDir: File

  private var asr: LiteRtTranscriber? = null
  private var laya: LayaEngine? = null
  private var tts: LiteRtSpeaker? = null
  private var player: SpeechPlayer? = null
  private var systemTts: TextToSpeech? = null
  private var systemTtsReady = false
  private var ttsEngineMode = "kitten" // "kitten" or "system"
  private var ttsVoice: String? = null
  private var ttsSpeed = 1.0f

  private var chat: ChatEngine? = null
  private var chatIdleJob: Job? = null
  private var selectedModelFile: String = GEMMA_GPU_FILE
  private var selectedBackend: String = "AUTO"

  private var micJob: Job? = null
  private var micSamples = FloatArray(0)
  private var micCount = 0

  private var generateJob: Job? = null
  private var speakJob: Job? = null
  private val speechQueue = Channel<String>(Channel.UNLIMITED)

  init {
    initSystemTts()
  }

  private fun initSystemTts() {
    systemTts = TextToSpeech(context) { status ->
      if (status == TextToSpeech.SUCCESS) {
        systemTtsReady = true
        if (!ttsVoice.isNullOrBlank()) {
          val match = systemTts?.voices?.firstOrNull { it.name == ttsVoice }
          if (match != null) systemTts?.voice = match else systemTts?.language = Locale.US
        } else {
          systemTts?.language = Locale.US
        }
        systemTts?.setSpeechRate(ttsSpeed)
        systemTts?.setOnUtteranceProgressListener(object : UtteranceProgressListener() {
          override fun onStart(utteranceId: String?) {
            emit(mapOf("type" to "tts_start"))
          }

          override fun onDone(utteranceId: String?) {
            emit(mapOf("type" to "tts_done"))
          }

          @Deprecated("Deprecated in Java")
          override fun onError(utteranceId: String?) {
            emit(mapOf("type" to "error", "message" to "System TTS error"))
          }
        })
        Log.i(TAG, "System TextToSpeech initialized successfully (voice: ${systemTts?.voice?.name}, rate: $ttsSpeed)")
      } else {
        Log.w(TAG, "System TextToSpeech initialization failed with code $status")
      }
    }
  }

  /** Loads the always-on models. Gemma is not loaded here. */
  suspend fun init(dir: String): Map<String, Any?> = withContext(Dispatchers.Default) {
    modelsDir = File(dir)
    val tpuModel = File(modelsDir, GEMMA_TPU_FILE)
    if (tpuModel.exists() && selectedModelFile == GEMMA_GPU_FILE) {
      selectedModelFile = GEMMA_TPU_FILE
      selectedBackend = "NPU"
      Log.i(TAG, "Found TPU model on disk, defaulting to $GEMMA_TPU_FILE on NPU")
    }

    val status = linkedMapOf<String, Any?>()
    status["zipformer"] =
      runCatching {
          asr =
            asr
              ?: LiteRtTranscriber.open(
                File(modelsDir, "zipformer_ctc_fp16.tflite"),
                File(modelsDir, "tokens.txt"),
              )
        }
        .onFailure { Log.e(TAG, "zipformer", it); status["zipformerError"] = it.message }
        .isSuccess
    status["laya"] =
      runCatching {
          if (laya == null) {
            laya = LayaEngine(File(modelsDir, "laya_ml")).also {
              it.initialize(LayaEngine.Backend.GPU)
            }
          }
        }
        .onFailure { Log.e(TAG, "laya", it); status["layaError"] = it.message }
        .isSuccess
    status["kitten"] =
      runCatching {
          if (tts == null) {
            val symbols = { context.assets.open("symbols.json").bufferedReader().use { it.readText() } }
            val s = LiteRtSpeaker.open({ name -> File(modelsDir, "kitten/$name") }, symbols)
            tts = s
            player = SpeechPlayer(s.sampleRate)
            startSpeechWorker()
          }
        }
        .onFailure { Log.e(TAG, "kitten", it); status["kittenError"] = it.message }
        .isSuccess
    status["gemmaPresent"] = File(modelsDir, selectedModelFile).exists()
    status["selectedModel"] = selectedModelFile
    status["selectedBackend"] = selectedBackend
    status["voices"] = tts?.voices ?: LiteRtSpeaker.VOICES
    status
  }

  // ---- Speech to text (push to talk) ----

  fun startListening() {
    if (micJob?.isActive == true) return
    stopSpeaking()
    micSamples = FloatArray(MAX_SAMPLES)
    micCount = 0
    micJob =
      scope.launch(Dispatchers.IO) {
        MicSource().chunks().collect { chunk ->
          val n = minOf(chunk.size, MAX_SAMPLES - micCount)
          if (n > 0) {
            System.arraycopy(chunk, 0, micSamples, micCount, n)
            micCount += n
          }
        }
      }
    emit(mapOf("type" to "listening"))
  }

  /** Returns `{text, stt_ms, audio_ms}`. */
  suspend fun stopListening(): Map<String, Any> =
    withContext(Dispatchers.Default) {
      micJob?.cancelAndJoin()
      micJob = null
      emit(mapOf("type" to "transcribing"))
      val samples = synchronized(this@AiCore) { micSamples.copyOf(micCount) }
      val audioMs = samples.size * 1000 / SAMPLE_RATE
      if (samples.size < MIN_SAMPLES) {
        emit(mapOf("type" to "idle"))
        return@withContext mapOf("text" to "", "stt_ms" to 0.0, "audio_ms" to audioMs)
      }
      val engine = asr ?: error("speech recognition is not loaded")
      val t = engine.transcribe(samples)
      val text = normalizeTranscript(t.text)
      emit(mapOf("type" to "transcript", "text" to text))
      mapOf("text" to text, "stt_ms" to t.timing.totalMs, "audio_ms" to audioMs)
    }

  // ---- Laya router ----

  /** [questionsJson]: `{id: {type, instructions, criteria}}`. Returns `{id: answer}` as JSON. */
  suspend fun classify(text: String, questionsJson: String): String = withContext(Dispatchers.Default) {
    val engine = laya ?: error("router is not loaded")
    val questions = LayaJson.asObject(LayaJson.parse(questionsJson))
    val answers = linkedMapOf<String, Any?>()
    val textTokens = engine.countTokens(text)
    for ((id, q) in questions) {
      answers[id] =
        runCatching {
            val r = engine.answer(text, LayaJson.asObject(q), LayaEngine.Backend.GPU, questionId = id)
            // seq_tokens = whole prompt; when it hits the 256 window the question was cut
            r.answer + mapOf("seq_tokens" to r.sequence.ids.size, "text_tokens" to textTokens)
          }
          .getOrElse { mapOf("error" to (it.message ?: it.javaClass.simpleName)) }
    }
    LayaJson.stringify(answers)
  }

  // ---- Gemma ----

  suspend fun setModel(filename: String, backend: String) {
    llmLock.withLock {
      if (selectedModelFile != filename || selectedBackend != backend) {
        dropConversation()
        chat?.closeAndJoin()
        chat = null
        selectedModelFile = filename
        selectedBackend = backend
        emit(mapOf("type" to "llm_unloaded"))
        Log.i(TAG, "Switched model to $filename on backend $backend")
      }
    }
  }

  fun listAvailableModels(): List<Map<String, Any>> {
    if (!::modelsDir.isInitialized || !modelsDir.isDirectory) return emptyList()
    val files = modelsDir.listFiles { _, name -> name.endsWith(".litertlm") } ?: emptyArray()
    return files.map { f ->
      val isTpu = f.name.contains("Tensor", ignoreCase = true) || f.name.contains("G5", ignoreCase = true)
      mapOf(
        "name" to f.name,
        "size" to f.length(),
        "isTpu" to isTpu,
        "recommendedBackend" to if (isTpu) "NPU" else "GPU",
      )
    }
  }

  private suspend fun ensureChat(): ChatEngine =
    llmLock.withLock {
      chat?.let { return it }
      emit(mapOf("type" to "llm_loading"))
      
      var file = File(modelsDir, selectedModelFile)
      var backend = selectedBackend
      
      // If the selected model doesn't exist, try falling back to the standard GPU model
      if (!file.exists()) {
        val gpuModel = File(modelsDir, GEMMA_GPU_FILE)
        if (gpuModel.exists()) {
          file = gpuModel
          backend = "GPU"
          selectedModelFile = GEMMA_GPU_FILE
          selectedBackend = "GPU"
        } else {
          error("Model file does not exist: ${file.absolutePath}")
        }
      }

      val t0 = System.nanoTime()
      val engine = try {
        ChatEngine.open(
          modelFile = file,
          cacheDir = File(context.cacheDir, "litertlm"),
          backendType = backend,
          nativeLibraryDir = context.applicationInfo.nativeLibraryDir,
        )
      } catch (t: Throwable) {
        // If NPU initialization failed on the TPU bundle, fallback to the GPU model file if available
        val gpuModel = File(modelsDir, GEMMA_GPU_FILE)
        if (file.name != GEMMA_GPU_FILE && gpuModel.exists()) {
          Log.w(TAG, "Model ${file.name} failed ($t). Falling back to $GEMMA_GPU_FILE on GPU...")
          selectedModelFile = GEMMA_GPU_FILE
          selectedBackend = "GPU"
          ChatEngine.open(
            modelFile = gpuModel,
            cacheDir = File(context.cacheDir, "litertlm"),
            backendType = "GPU",
            nativeLibraryDir = context.applicationInfo.nativeLibraryDir,
          )
        } else {
          throw t
        }
      }
      chat = engine
      emit(mapOf("type" to "llm_ready", "load_ms" to (System.nanoTime() - t0) / 1e6))
      engine
    }

  /** One Gemma conversation per chat session (follow-ups keep context), capped to keep the KV cache small. */
  private var convo: ChatEngine.ChatConversation? = null
  private var convoTurns = 0

  private suspend fun dropConversation() {
    convo?.let { runCatching { it.closeAndJoin() } }
    convo = null
    convoTurns = 0
  }

  /** Called when the chat is cleared: the next question starts a fresh conversation. */
  fun resetConversation() {
    scope.launch { if (generateJob?.isActive != true) dropConversation() }
  }

  fun generate(
    system: String,
    prompt: String,
    speak: Boolean,
    newConversation: Boolean = false,
    imagePath: String? = null,
  ) {
    if (generateJob?.isActive == true) {
      emit(mapOf("type" to "error", "message" to "busy"))
      return
    }
    chatIdleJob?.cancel()
    generateJob =
      scope.launch {
        val splitter = SentenceStream(LiteRtSpeaker.MAX_CHARS)
        var chunks = 0
        var chars = 0
        var firstAt = 0L
        try {
          val engine = ensureChat()
          val hasImage = !imagePath.isNullOrEmpty() && File(imagePath).exists()
          if (newConversation || hasImage || convo == null || convoTurns >= MAX_CONVO_TURNS) dropConversation()
          val conversation = convo ?: engine.createConversation(system, emptyList()).also { convo = it }
          convoTurns++
          val sentAt = System.nanoTime() // after any model load: TTFT = prefill + first decode step
          val userMessage = if (hasImage) {
            Message.user(Contents.of(Content.ImageFile(imagePath!!), Content.Text(prompt)))
          } else {
            Message.user(prompt)
          }
          try {
            conversation.send(userMessage, thinking = false).collect { m ->
              val piece = m.contents.contents.filterIsInstance<Content.Text>().joinToString("") { it.text }
              if (piece.isNotEmpty()) {
                if (chunks == 0) {
                  firstAt = System.nanoTime()
                  emit(mapOf("type" to "llm_first_token", "ttft_ms" to (firstAt - sentAt) / 1e6))
                }
                chunks++
                chars += piece.length
                emit(mapOf("type" to "llm_chunk", "text" to piece))
                if (speak) {
                  if (ttsEngineMode == "system") {
                    splitter.add(piece).forEach { speak(it) }
                  } else {
                    splitter.add(piece).forEach { speechQueue.trySend(it) }
                  }
                }
              }
            }
          } catch (e: Exception) {
            dropConversation() // a cancelled or failed generation invalidates the conversation
            throw e
          }
          if (speak) {
            if (ttsEngineMode == "system") {
              splitter.flush().forEach { speak(it) }
            } else {
              splitter.flush().forEach { speechQueue.trySend(it) }
            }
          }
          val now = System.nanoTime()
          emit(
            mapOf(
              "type" to "llm_done",
              "chunks" to chunks,
              "chars" to chars,
              "decode_ms" to if (firstAt == 0L) 0.0 else (now - firstAt) / 1e6,
            )
          )
        } catch (e: Exception) {
          Log.e(TAG, "generate", e)
          emit(mapOf("type" to "error", "message" to (e.message ?: e.javaClass.simpleName)))
        } finally {
          scheduleChatUnload()
        }
      }
  }

  fun cancelGenerate() {
    generateJob?.cancel()
  }

  private fun scheduleChatUnload() {
    chatIdleJob?.cancel()
    chatIdleJob =
      scope.launch {
        delay(LLM_IDLE_MS)
        unloadLlm()
      }
  }

  suspend fun unloadLlm() {
    dropConversation()
    llmLock.withLock {
      chat?.closeAndJoin()
      chat = null
    }
    emit(mapOf("type" to "llm_unloaded"))
  }

  fun llmLoaded(): Boolean = chat != null

  // ---- Text to speech ----

  fun setTtsEngine(engine: String) {
    ttsEngineMode = if (engine.lowercase() == "system") "system" else "kitten"
    stopSpeaking()
  }

  fun setTtsVoice(voice: String?) {
    ttsVoice = voice
    if (systemTtsReady && !voice.isNullOrBlank()) {
      val match = systemTts?.voices?.firstOrNull { it.name == voice }
      if (match != null) {
        systemTts?.voice = match
        Log.i(TAG, "Applied system TTS voice: ${match.name} (${match.locale})")
      } else {
        Log.w(TAG, "Could not find system voice matching '$voice'")
      }
    }
  }

  fun setTtsSpeed(speed: Float) {
    ttsSpeed = speed.coerceIn(0.5f, 2.0f)
    systemTts?.setSpeechRate(ttsSpeed)
  }

  fun setVoice(name: String?, newSpeed: Float) {
    ttsVoice = name
    ttsSpeed = newSpeed
  }

  fun metrics(): Map<String, Any?> {
    val bm = context.getSystemService(Context.BATTERY_SERVICE) as android.os.BatteryManager
    val intent = context.registerReceiver(null, android.content.IntentFilter(android.content.Intent.ACTION_BATTERY_CHANGED))
    val mem = android.os.Debug.MemoryInfo().also { android.os.Debug.getMemoryInfo(it) }
    return mapOf(
      "battery_pct" to bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY),
      "current_ua" to bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CURRENT_NOW),
      "voltage_mv" to intent?.getIntExtra(android.os.BatteryManager.EXTRA_VOLTAGE, -1),
      "temp_c" to (intent?.getIntExtra(android.os.BatteryManager.EXTRA_TEMPERATURE, 0) ?: 0) / 10.0,
      "charging" to bm.isCharging,
      "pss_mb" to mem.totalPss / 1024.0,
      "cpu_ms" to android.os.Process.getElapsedCpuTime(),
      "llm_loaded" to llmLoaded(),
    )
  }

  fun listTtsVoices(): Map<String, List<String>> {
    val kittenVoices = LiteRtSpeaker.VOICES
    val systemVoices = if (systemTtsReady) {
      systemTts?.voices?.map { it.name } ?: emptyList()
    } else emptyList()
    return mapOf(
      "kitten" to kittenVoices,
      "system" to systemVoices,
    )
  }

  /** When the last [speak] was requested; the first audio after it reports the latency once. */
  @Volatile private var speakRequestedAt = 0L

  /** Bumped by [stopSpeaking]: a sentence synthesized under an older generation is dropped. */
  @Volatile private var speechGen = 0

  fun speak(text: String) {
    val clean = stripForSpeech(text)
    if (clean.isBlank()) return
    speakRequestedAt = System.nanoTime()

    if (ttsEngineMode == "system" && systemTtsReady) {
      val params = Bundle()
      val utteranceId = UUID.randomUUID().toString()
      systemTts?.speak(clean, TextToSpeech.QUEUE_ADD, params, utteranceId)
    } else {
      SentenceSplitter.split(clean).forEach { speechQueue.trySend(it) }
    }
  }

  fun stopSpeaking() {
    speechGen++
    while (speechQueue.tryReceive().isSuccess) {}
    player?.stop()
    if (systemTtsReady) {
      systemTts?.stop()
    }
    emit(mapOf("type" to "tts_done"))
  }

  private fun startSpeechWorker() {
    speakJob?.cancel()
    speakJob =
      scope.launch {
        for (sentence in speechQueue) {
          val s = tts ?: continue
          val p = player ?: continue
          val clean = stripForSpeech(sentence)
          if (clean.isBlank()) continue
          val gen = speechGen
          try {
            emit(mapOf("type" to "tts_start", "text" to clean))
            val audio = s.synthesize(clean.take(LiteRtSpeaker.MAX_CHARS), ttsVoice, ttsSpeed)
            if (gen != speechGen) continue // stopped while synthesizing
            val asked = speakRequestedAt
            if (asked != 0L) {
              speakRequestedAt = 0L
              emit(mapOf("type" to "tts_first_audio", "ms" to (System.nanoTime() - asked) / 1e6))
            }
            p.play(audio.samples)
            if (speechQueue.isEmpty && gen == speechGen) {
              p.drain()
              emit(mapOf("type" to "tts_done"))
            }
          } catch (e: Exception) {
            Log.e(TAG, "speak", e)
            emit(mapOf("type" to "error", "message" to "tts: ${e.message}"))
          }
        }
      }
  }

  fun trimMemory() {
    scope.launch { if (generateJob?.isActive != true) unloadLlm() }
  }

  companion object {
    private const val TAG = "SurvivalAi"
    const val GEMMA_GPU_FILE = "gemma-4-E2B-it.litertlm"
    const val GEMMA_TPU_FILE = "gemma-4-E2B-it_Google_Tensor_G5.litertlm"
    private const val SAMPLE_RATE = 16000
    private const val MAX_SAMPLES = SAMPLE_RATE * 16 // Zipformer's 16 s window
    private const val MIN_SAMPLES = SAMPLE_RATE / 4
    private const val LLM_IDLE_MS = 5 * 60 * 1000L
    private const val MAX_CONVO_TURNS = 6

    fun normalizeTranscript(text: String): String {
      val t = text.trim().lowercase()
      return if (t.isEmpty()) t else t.replaceFirstChar { it.uppercase() }
    }

    fun stripForSpeech(text: String): String =
      text
        .replace(Regex("[*_#`>|]"), "")
        .replace(Regex("\\[(.*?)]\\(.*?\\)"), "$1")
        .replace(Regex("\\s+"), " ")
        .trim()
  }
}
