import AVFoundation
import Flutter

/// The `survival/ai` channel on iOS. The on-device models (Zipformer, Laya, Gemma, KittenTTS)
/// run on Android only for now, so this reports them as missing; the app then answers from
/// templates, the trail data and the guide. Answers are spoken with the system voice, with the
/// same tts_start / tts_done events the Android side sends.
final class AiFallback: NSObject, FlutterStreamHandler, AVSpeechSynthesizerDelegate {
  private let synth = AVSpeechSynthesizer()
  private var sink: FlutterEventSink?
  private var voice: AVSpeechSynthesisVoice? = AVSpeechSynthesisVoice(language: "en-US")
  private var rate: Float = AVSpeechUtteranceDefaultSpeechRate

  override init() {
    super.init()
    synth.delegate = self
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    return nil
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any]
    switch call.method {
    case "modelsDir":
      let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
      let dir = docs.appendingPathComponent("models")
      try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      result(dir.path)
    case "init":
      result(["zipformer": false, "laya": false, "kitten": false, "gemmaPresent": false,
              "voices": AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }.map { $0.name }])
    case "requestMic":
      result(false)  // no on-device speech recognition on iOS yet: typing and the quick buttons work
    case "status":
      result(["llmLoaded": false])
    case "metrics", "launchFlags":
      result([String: Any]())
    case "listModels", "listTtsVoices":
      result([Any]())
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
    case "resetConversation", "cancelGenerate", "unloadLlm", "setModel":
      result(nil)
    default:
      // stopListening, classify, generate: need the on-device models
      result(FlutterError(code: "AI_ERROR", message: "The on-device AI models aren't available on iOS yet.", details: nil))
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

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    sink?(["type": "tts_start"])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    sink?(["type": "tts_done"])
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    sink?(["type": "tts_done"])
  }
}
