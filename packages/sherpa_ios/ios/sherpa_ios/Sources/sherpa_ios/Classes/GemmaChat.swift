import Foundation

#if canImport(LiteRTLM)
import LiteRTLM
#endif

/// Gemma 4 E2B on LiteRT-LM (Metal GPU), the iOS side of what android/.../AiCore.kt does: the
/// engine loads on the first question and is released after 5 idle minutes; one conversation per
/// chat session (follow-ups keep context), capped at 6 turns to keep the KV cache small. Events
/// (llm_loading, llm_ready, llm_first_token, llm_chunk, llm_done, llm_unloaded, error) match Android.
@MainActor
final class GemmaChat {
  static let modelFile = "gemma-4-E2B-it.litertlm"
  private static let idleSeconds: UInt64 = 5 * 60
  private static let maxTurns = 6

  private let emit: ([String: Any]) -> Void
  /// Complete sentences of the answer, for speaking while the rest is still being generated.
  private let onSentence: (String) -> Void
  var modelsDir: URL

  init(modelsDir: URL, emit: @escaping ([String: Any]) -> Void, onSentence: @escaping (String) -> Void) {
    self.modelsDir = modelsDir
    self.emit = emit
    self.onSentence = onSentence
  }

  private var modelPath: String { modelsDir.appendingPathComponent(Self.modelFile).path }

  /// True when this build can run Gemma (Swift Package Manager build) and the model is on the phone.
  var present: Bool {
    #if canImport(LiteRTLM)
    FileManager.default.fileExists(atPath: modelPath)
    #else
    false
    #endif
  }

  func listModels() -> [[String: Any]] {
    let files = (try? FileManager.default.contentsOfDirectory(at: modelsDir, includingPropertiesForKeys: [.fileSizeKey])) ?? []
    return files.filter { $0.pathExtension == "litertlm" }.map { f in
      let size = (try? f.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
      return ["name": f.lastPathComponent, "size": size, "isTpu": false, "recommendedBackend": "GPU"]
    }
  }

  #if canImport(LiteRTLM)
  private var engine: Engine?
  private var hasVision = false
  private var convo: Conversation?
  private var turns = 0
  private var job: Task<Void, Never>?
  private var idle: Task<Void, Never>?

  var loaded: Bool { engine != nil }

  /// Set after the vision encoder failed once: photo questions then go to Gemma as text only.
  private var visionFailed = false

  private func ensureEngine() async throws -> Engine {
    if let engine { return engine }
    emit(["type": "llm_loading"])
    let t0 = Date()
    let cache = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("litertlm")
    try? FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
    // The bundle carries a vision encoder (photo questions). Its GPU delegate won't build on the
    // iPhone 16 ("Failed to modify graph with delegate"), so it runs on the CPU, as in Google's
    // Swift guide; the language model stays on the GPU.
    var e: Engine?
    if !visionFailed {
      do {
        let v = Engine(engineConfig: try EngineConfig(modelPath: modelPath, backend: .gpu, visionBackend: .cpu(), cacheDir: cache.path))
        try await v.initialize()
        e = v
      } catch {
        NSLog("Gemma: vision engine failed (%@), loading text only", String(describing: error))
        visionFailed = true
      }
    }
    hasVision = e != nil
    if e == nil {
      let t = Engine(engineConfig: try EngineConfig(modelPath: modelPath, backend: .gpu, cacheDir: cache.path))
      try await t.initialize()
      e = t
    }
    engine = e
    emit(["type": "llm_ready", "load_ms": Date().timeIntervalSince(t0) * 1000])
    return e!
  }

  private func newConversation(_ engine: Engine, system: String) async throws -> Conversation {
    let config = ConversationConfig(
      systemMessage: Message(system, role: .system),
      samplerConfig: try SamplerConfig(topK: 40, topP: 0.95, temperature: 0.6),
      thinkingConfig: ThinkingConfig(enableThinking: false, thinkingTokenBudget: 0),
      automaticToolCalling: false)
    return try await engine.createConversation(with: config)
  }

  func generate(system: String, prompt: String, speak: Bool, newConversation: Bool, imagePath: String?) {
    if job != nil {
      emit(["type": "error", "message": "busy"])
      return
    }
    idle?.cancel()
    job = Task { [weak self] in
      guard let self else { return }
      defer {
        self.job = nil
        self.scheduleUnload()
      }
      var splitter = SentenceSplitter()
      var chunks = 0, chars = 0
      var firstAt: Date?
      do {
        let engine = try await self.ensureEngine()
        if newConversation || self.convo == nil || self.turns >= Self.maxTurns { self.dropConversation() }
        let conversation: Conversation
        if let c = self.convo {
          conversation = c
        } else {
          do {
            conversation = try await self.newConversation(engine, system: system)
          } catch where self.hasVision {
            // the vision executor is built with the conversation: reload text only and retry
            NSLog("Gemma: conversation with vision failed (%@), reloading text only", String(describing: error))
            self.visionFailed = true
            self.engine = nil
            conversation = try await self.newConversation(try await self.ensureEngine(), system: system)
          }
          self.convo = conversation
        }
        self.turns += 1
        let message: Message
        if let imagePath, !imagePath.isEmpty, self.hasVision, FileManager.default.fileExists(atPath: imagePath) {
          message = Message(of: .imageFile(imagePath), .text(prompt))
        } else {
          message = Message(prompt)
        }
        let sentAt = Date()  // after any model load: TTFT = prefill + first decode step
        do {
          for try await m in conversation.sendMessageStream(message) {
            try Task.checkCancellation()
            let piece = m.toString
            guard !piece.isEmpty else { continue }
            if firstAt == nil {
              firstAt = Date()
              self.emit(["type": "llm_first_token", "ttft_ms": firstAt!.timeIntervalSince(sentAt) * 1000])
            }
            chunks += 1
            chars += piece.count
            self.emit(["type": "llm_chunk", "text": piece])
            if speak { splitter.add(piece).forEach(self.onSentence) }
          }
        } catch {
          self.dropConversation()  // a cancelled or failed generation invalidates the conversation
          throw error
        }
        if speak { splitter.flush().forEach(self.onSentence) }
        self.emit([
          "type": "llm_done", "chunks": chunks, "chars": chars,
          "decode_ms": firstAt.map { Date().timeIntervalSince($0) * 1000 } ?? 0.0,
        ])
      } catch is CancellationError {
        self.emit(["type": "error", "message": "cancelled"])
      } catch {
        NSLog("Gemma: generate failed: %@", String(describing: error))
        self.emit(["type": "error", "message": String(describing: error)])
      }
    }
  }

  func cancel() {
    try? convo?.cancel()
    job?.cancel()
  }

  /// The chat was cleared: the next question starts a fresh conversation.
  func resetConversation() {
    if job == nil { dropConversation() }
  }

  func unload() {
    cancel()
    dropConversation()
    engine = nil
    emit(["type": "llm_unloaded"])
  }

  private func dropConversation() {
    convo = nil
    turns = 0
  }

  private func scheduleUnload() {
    idle?.cancel()
    idle = Task { [weak self] in
      try? await Task.sleep(nanoseconds: Self.idleSeconds * 1_000_000_000)
      guard !Task.isCancelled, let self, self.engine != nil, self.job == nil else { return }
      self.unload()
    }
  }
  #else
  var loaded: Bool { false }
  func generate(system: String, prompt: String, speak: Bool, newConversation: Bool, imagePath: String?) {
    emit(["type": "error", "message": "This build has no LiteRT-LM (build with Swift Package Manager)."])
  }
  func cancel() {}
  func resetConversation() {}
  func unload() {}
  #endif
}

/// Cuts streamed text into sentences so speech can start before the answer is complete.
struct SentenceSplitter {
  private var buf = ""
  private static let maxChars = 300

  mutating func add(_ piece: String) -> [String] {
    buf += piece
    var out: [String] = []
    while let end = boundary() {
      let s = String(buf[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
      buf = String(buf[end...])
      if !s.isEmpty { out.append(s) }
    }
    return out
  }

  mutating func flush() -> [String] {
    let s = buf.trimmingCharacters(in: .whitespacesAndNewlines)
    buf = ""
    return s.isEmpty ? [] : [s]
  }

  /// End of the first sentence: ., ! or ? followed by whitespace, a newline, or a long run of text
  /// cut at its last space.
  private func boundary() -> String.Index? {
    var i = buf.startIndex
    while i < buf.endIndex {
      let c = buf[i]
      let next = buf.index(after: i)
      if c == "\n" { return next }
      if ".!?".contains(c), next < buf.endIndex, buf[next].isWhitespace { return next }
      i = next
    }
    if buf.count > Self.maxChars, let space = buf.lastIndex(of: " ") { return buf.index(after: space) }
    return nil
  }
}
