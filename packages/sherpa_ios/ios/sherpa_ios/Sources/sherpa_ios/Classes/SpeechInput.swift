import AVFoundation
import Speech

/// Hold-to-talk speech to text with Apple's on-device recognizer (no network), in place of the
/// Zipformer model the Android side runs. start() records from the mic; stop() ends the audio and
/// returns the final transcript, like AiCore.stopListening on Android.
@MainActor
final class SpeechInput {
  private let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
  private let audio = AVAudioEngine()
  private var request: SFSpeechAudioBufferRecognitionRequest?
  private var task: SFSpeechRecognitionTask?
  private var latest = ""
  private var final: CheckedContinuation<String, Never>?
  private var startedAt = Date()

  /// On-device recognition is available for English on this phone.
  var available: Bool { recognizer?.supportsOnDeviceRecognition == true }

  /// Asks for microphone and speech recognition access; true when both are granted.
  func requestAccess() async -> Bool {
    let speech = await withCheckedContinuation { c in
      SFSpeechRecognizer.requestAuthorization { c.resume(returning: $0 == .authorized) }
    }
    let mic = await withCheckedContinuation { c in
      AVAudioSession.sharedInstance().requestRecordPermission { c.resume(returning: $0) }
    }
    return speech && mic
  }

  func start() throws {
    guard let recognizer, available else { throw SpeechError("On-device speech recognition isn't available.") }
    guard SFSpeechRecognizer.authorizationStatus() == .authorized,
          AVAudioSession.sharedInstance().recordPermission == .granted else {
      throw SpeechError("Allow Microphone and Speech Recognition for Sherpa in Settings to talk to it.")
    }
    cancel()
    let session = AVAudioSession.sharedInstance()
    try session.setCategory(.playAndRecord, mode: .measurement, options: [.duckOthers, .defaultToSpeaker])
    try session.setActive(true, options: .notifyOthersOnDeactivation)
    // installTap raises an Objective-C exception (which Swift can't catch) on a format with no
    // channels or rate, as the input reports while the mic is unavailable.
    let input = audio.inputNode
    let format = input.inputFormat(forBus: 0)
    guard format.sampleRate > 0, format.channelCount > 0 else {
      throw SpeechError("The microphone isn't available right now.")
    }

    let req = SFSpeechAudioBufferRecognitionRequest()
    req.requiresOnDeviceRecognition = true
    req.shouldReportPartialResults = true
    request = req
    latest = ""
    task = recognizer.recognitionTask(with: req) { [weak self] result, error in
      let text = result?.bestTranscription.formattedString
      let done = result?.isFinal == true || error != nil
      Task { @MainActor in
        guard let self else { return }
        if let text { self.latest = text }
        if done { self.finish() }
      }
    }
    input.removeTap(onBus: 0)
    input.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
      req.append(buffer)
    }
    audio.prepare()
    try audio.start()
    startedAt = Date()
  }

  /// Stops recording and waits (up to 3 s) for the final transcript. Returns (text, audio ms, stt ms).
  func stop() async -> (String, Double, Double) {
    let audioMs = Date().timeIntervalSince(startedAt) * 1000
    guard request != nil else { return ("", 0, 0) }
    stopAudio()
    request?.endAudio()
    let t0 = Date()
    let text = await withCheckedContinuation { (c: CheckedContinuation<String, Never>) in
      final = c
      Task { @MainActor [weak self] in
        try? await Task.sleep(nanoseconds: 3_000_000_000)
        self?.finish()  // the recognizer never sent a final result: use the last partial one
      }
    }
    task = nil
    request = nil
    try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
    return (text, audioMs, Date().timeIntervalSince(t0) * 1000)
  }

  func cancel() {
    stopAudio()
    task?.cancel()
    task = nil
    request = nil
    finish()
  }

  private func finish() {
    final?.resume(returning: latest)
    final = nil
  }

  private func stopAudio() {
    if audio.isRunning { audio.stop() }
    audio.inputNode.removeTap(onBus: 0)
  }
}

struct SpeechError: LocalizedError {
  let errorDescription: String?
  init(_ message: String) { errorDescription = message }
}
