import AVFoundation
import Flutter

/// The `survival/ai` channel on iOS: Gemma 4 E2B on LiteRT-LM (GemmaChat), Apple's on-device
/// speech recognition for the mic (SpeechInput), and the system voice for speech. The Laya router
/// runs on Android only, so questions take the app's rule-based routing here. Events match the
/// Android side (android/.../AiCore.kt).
@MainActor
final class AiCore: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var sink: FlutterEventSink?
  private var voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice(language: "en-US")
  private var rate: Float = AVSpeechUtteranceDefaultSpeechRate
  /// Utterances queued or playing: tts_start on the first, tts_done when the last one ends.
  private var pending = 0
  private let speech = SpeechInput()
  private lazy var gemma = GemmaChat(
    modelsDir: Self.defaultModelsDir,
    emit: { [weak self] in self?.emit($0) },
    onSentence: { [weak self] in self?.speak($0) })

  /// Documents/models: copy gemma-4-E2B-it.litertlm here (Files app, or `devicectl device copy to`).
  private static var defaultModelsDir: URL {
    let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("models")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  override init() {
    super.init()
    synth.delegate = self
    if let q = ProcessInfo.processInfo.environment["SHERPA_SELFTEST"] { selfTest(q) }
  }

  /// Developer check, run from the Mac with
  /// `devicectl device process launch --environment-variables '{"SHERPA_SELFTEST": "<question>"}'`:
  /// asks Gemma [question] once and writes every event to Documents/selftest.log.
  private var selfTestLog: FileHandle?

  private func selfTest(_ question: String) {
    let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("selftest.log")
    FileManager.default.createFile(atPath: url.path, contents: nil)
    selfTestLog = try? FileHandle(forWritingTo: url)
    log(["type": "selftest", "gemmaPresent": gemma.present, "question": question])
    gemma.generate(system: "You are a concise Yosemite hiking safety assistant.", prompt: question,
                   speak: false, newConversation: true, imagePath: nil)
  }

  private func log(_ event: [String: Any]) {
    guard let selfTestLog else { return }
    var e = event
    e["t"] = Date().timeIntervalSince1970
    if let d = try? JSONSerialization.data(withJSONObject: e) {
      selfTestLog.write(d + Data("\n".utf8))
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  private func emit(_ event: [String: Any]) {
    log(event)
    sink?(event)
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "modelsDir":
      result(Self.defaultModelsDir.path)
    case "init":
      if let dir = args?["modelsDir"] as? String { gemma.modelsDir = URL(fileURLWithPath: dir) }
      NSLog("Gemma: model %@ in %@", gemma.present ? "found" : "missing", gemma.modelsDir.path)
      result(["zipformer": speech.available, "laya": false, "kitten": false, "gemmaPresent": gemma.present,
              "voices": AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.map { $0.name }])
    case "requestMic":
      Task { result(await speech.requestAccess()) }
    case "startListening":
      synth.stopSpeaking(at: .immediate)
      do {
        try speech.start()
        emit(["type": "listening"])
        result(nil)
      } catch {
        result(FlutterError(code: "AI_ERROR", message: error.localizedDescription, details: nil))
      }
    case "stopListening":
      emit(["type": "transcribing"])
      Task {
        let (text, audioMs, sttMs) = await speech.stop()
        emit(text.isEmpty ? ["type": "idle"] : ["type": "transcript", "text": text])
        result(["text": text, "stt_ms": sttMs, "audio_ms": audioMs])
      }
    case "status":
      result(["llmLoaded": gemma.loaded])
    case "metrics", "launchFlags":
      result([String: Any]())
    case "listModels":
      result(gemma.listModels())
    case "listTtsVoices":
      result(["kitten": [String](), "system": AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.map { $0.name }])
    case "generate":
      gemma.generate(
        system: args?["system"] as? String ?? "",
        prompt: args?["prompt"] as? String ?? "",
        speak: args?["speak"] as? Bool ?? true,
        newConversation: args?["newConversation"] as? Bool ?? false,
        imagePath: args?["imagePath"] as? String)
      result(nil)
    case "cancelGenerate":
      gemma.cancel()
      result(nil)
    case "resetConversation":
      gemma.resetConversation()
      result(nil)
    case "unloadLlm":
      gemma.unload()
      result(nil)
    case "speak":
      speak(args?["text"] as? String ?? "")
      result(nil)
    case "stopSpeaking":
      synth.stopSpeaking(at: .immediate)
      result(nil)
    case "setVoice", "setTtsVoice", "setTtsSpeed", "setTtsEngine":
      if let name = args?["voice"] as? String,
         let v = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name }) { voice = v }
      if let speed = (args?["speed"] as? Double) {
        rate = AVSpeechUtteranceDefaultSpeechRate * Float(speed)
      }
      result(nil)
    case "setModel":
      result(nil)  // one model (GPU) on iOS
    default:
      // classify: the Laya router runs on Android only
      result(FlutterError(code: "AI_ERROR", message: "\(call.method) isn't available on iOS.", details: nil))
    }
  }

  private func speak(_ text: String) {
    guard !text.isEmpty else { return }
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    try? AVAudioSession.sharedInstance().setActive(true)
    let u = AVSpeechUtterance(string: text)
    u.voice = voice
    u.rate = rate
    synth.speak(u)
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    Task { @MainActor in
      pending += 1
      if pending == 1 { emit(["type": "tts_start"]) }
    }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    Task { @MainActor in utteranceEnded() }
  }

  nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    Task { @MainActor in utteranceEnded() }
  }

  private func utteranceEnded() {
    pending = max(0, pending - 1)
    // more sentences may still be queued behind this one
    if pending == 0 && !synth.isSpeaking { emit(["type": "tts_done"]) }
  }
}
