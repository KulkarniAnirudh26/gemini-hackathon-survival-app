package com.hackathon.yosemite_survival

import android.content.Context
import android.util.Log
import com.google.ai.edge.litertlm.Content
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
 * lazily) and KittenTTS (speech). Every public call is a suspend function; events go to [emit].
 */
class AiCore(private val context: Context, private val emit: (Map<String, Any?>) -> Unit) {
  private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Default)
  private val llmLock = Mutex()
  private lateinit var modelsDir: File

  private var asr: LiteRtTranscriber? = null
  private var laya: LayaEngine? = null
  private var tts: LiteRtSpeaker? = null
  private var player: SpeechPlayer? = null
  private var chat: ChatEngine? = null
  private var chatIdleJob: Job? = null

  private var micJob: Job? = null
  private var micSamples = FloatArray(0)
  private var micCount = 0

  private var generateJob: Job? = null
  private var speakJob: Job? = null
  private val speechQueue = Channel<String>(Channel.UNLIMITED)

  /** Loads the always-on models. Gemma is not loaded here. */
  suspend fun init(dir: String): Map<String, Any?> = withContext(Dispatchers.Default) {
    modelsDir = File(dir)
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
    status["gemmaPresent"] = File(modelsDir, GEMMA_FILE).exists()
    status["voices"] = voices()
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
  }

  suspend fun stopListening(): String {
    micJob?.cancelAndJoin()
    micJob = null
    val pcm = micSamples.copyOf(micCount)
    if (pcm.size < MIN_SAMPLES) return ""
    val engine = asr ?: error("speech recognition is not loaded")
    return normalizeTranscript(engine.transcribe(pcm).text)
  }

  // ---- Laya router ----

  /** [questionsJson]: `{id: {type, instructions, criteria}}`. Returns `{id: answer}` as JSON. */
  suspend fun classify(text: String, questionsJson: String): String = withContext(Dispatchers.Default) {
    val engine = laya ?: error("router is not loaded")
    val questions = LayaJson.asObject(LayaJson.parse(questionsJson))
    val answers = linkedMapOf<String, Any?>()
    for ((id, q) in questions) {
      answers[id] =
        runCatching {
            engine.answer(text, LayaJson.asObject(q), LayaEngine.Backend.GPU, questionId = id).answer
          }
          .getOrElse { mapOf("error" to (it.message ?: it.javaClass.simpleName)) }
    }
    LayaJson.stringify(answers)
  }

  // ---- Gemma ----

  private suspend fun ensureChat(): ChatEngine =
    llmLock.withLock {
      chat?.let { return it }
      emit(mapOf("type" to "llm_loading"))
      val engine = ChatEngine.open(File(modelsDir, GEMMA_FILE), File(context.cacheDir, "litertlm"))
      chat = engine
      emit(mapOf("type" to "llm_ready"))
      engine
    }

  fun generate(system: String, prompt: String, speak: Boolean) {
    if (generateJob?.isActive == true) {
      emit(mapOf("type" to "error", "message" to "busy"))
      return
    }
    chatIdleJob?.cancel()
    generateJob =
      scope.launch {
        val splitter = SentenceStream(LiteRtSpeaker.MAX_CHARS)
        try {
          val engine = ensureChat()
          val conversation = engine.createConversation(system, emptyList())
          try {
            conversation.send(Message.user(prompt), thinking = false).collect { m ->
              val piece = m.contents.contents.filterIsInstance<Content.Text>().joinToString("") { it.text }
              if (piece.isNotEmpty()) {
                emit(mapOf("type" to "llm_chunk", "text" to piece))
                if (speak) splitter.add(piece).forEach { speechQueue.trySend(it) }
              }
            }
          } finally {
            conversation.closeAndJoin()
          }
          if (speak) splitter.flush().forEach { speechQueue.trySend(it) }
          emit(mapOf("type" to "llm_done"))
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
    llmLock.withLock {
      chat?.closeAndJoin()
      chat = null
    }
    emit(mapOf("type" to "llm_unloaded"))
  }

  fun llmLoaded(): Boolean = chat != null

  // ---- Text to speech ----

  fun speak(text: String) {
    SentenceSplitter.split(stripForSpeech(text)).forEach { speechQueue.trySend(it) }
  }

  /** Bumped by [stopSpeaking]: a sentence synthesized under an older generation is dropped. */
  @Volatile private var speechGen = 0

  /** Calm defaults: a warm voice, a little slower than the publisher's pace. */
  @Volatile var voice: String? = null
  @Volatile var speed: Float = 0.85f

  fun voices(): List<String> = tts?.voices ?: emptyList()

  fun setVoice(name: String?, newSpeed: Float) {
    voice = name?.takeIf { it in voices() }
    speed = newSpeed.coerceIn(0.6f, 1.3f)
  }

  fun stopSpeaking() {
    speechGen++
    while (speechQueue.tryReceive().isSuccess) {}
    player?.stop()
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
            val audio = s.synthesize(clean.take(LiteRtSpeaker.MAX_CHARS), voice, speed)
            if (gen != speechGen) continue // stopped while synthesizing
            p.play(audio.samples)
            // a short breath between sentences: slower, calmer delivery
            if (gen == speechGen) p.play(FloatArray(s.sampleRate * SENTENCE_PAUSE_MS / 1000))
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
    const val GEMMA_FILE = "gemma-4-E2B-it.litertlm"
    private const val SAMPLE_RATE = 16000
    private const val MAX_SAMPLES = SAMPLE_RATE * 16 // Zipformer's 16 s window
    private const val MIN_SAMPLES = SAMPLE_RATE / 4
    private const val LLM_IDLE_MS = 5 * 60 * 1000L
    private const val SENTENCE_PAUSE_MS = 280

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
