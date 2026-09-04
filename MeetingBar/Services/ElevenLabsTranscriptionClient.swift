import Foundation

struct ElevenLabsHTTPResponse: Sendable {
  let data: Data
  let statusCode: Int
}

protocol ElevenLabsHTTPTransport: Sendable {
  func upload(_ request: URLRequest, fromFile bodyURL: URL) async throws
    -> ElevenLabsHTTPResponse
  func send(_ request: URLRequest) async throws -> ElevenLabsHTTPResponse
}

struct URLSessionElevenLabsHTTPTransport: ElevenLabsHTTPTransport {
  private let session: URLSession

  init(session: URLSession? = nil) {
    self.session = session ?? URLSession(configuration: .ephemeral)
  }

  func upload(_ request: URLRequest, fromFile bodyURL: URL) async throws
    -> ElevenLabsHTTPResponse
  {
    let (data, response) = try await session.upload(for: request, fromFile: bodyURL)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ElevenLabsTranscriptionError.invalidResponse
    }
    return ElevenLabsHTTPResponse(data: data, statusCode: httpResponse.statusCode)
  }

  func send(_ request: URLRequest) async throws -> ElevenLabsHTTPResponse {
    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw ElevenLabsTranscriptionError.invalidResponse
    }
    return ElevenLabsHTTPResponse(data: data, statusCode: httpResponse.statusCode)
  }
}

enum ElevenLabsTranscriptionError: LocalizedError, Sendable {
  case missingAPIKey
  case invalidResponse
  case service(statusCode: Int, message: String)

  var errorDescription: String? {
    switch self {
    case .missingAPIKey:
      "Add an ElevenLabs API key in MeetingBar Settings before using cloud transcription."
    case .invalidResponse:
      "ElevenLabs returned a response MeetingBar could not read."
    case .service(let statusCode, let message):
      "ElevenLabs transcription failed (HTTP \(statusCode)): \(message)"
    }
  }
}

struct ElevenLabsTranscriptResponse: Decodable, Sendable {
  let languageCode: String?
  let languageProbability: Double?
  let text: String
  let words: [ElevenLabsTranscriptWord]
  let transcriptionID: String?

  enum CodingKeys: String, CodingKey {
    case languageCode = "language_code"
    case languageProbability = "language_probability"
    case text
    case words
    case transcriptionID = "transcription_id"
  }
}

struct ElevenLabsTranscriptWord: Decodable, Sendable {
  let text: String
  let start: Double?
  let end: Double?
  let type: String?
  let speakerID: String?
  let logProbability: Double?

  enum CodingKeys: String, CodingKey {
    case text
    case start
    case end
    case type
    case speakerID = "speaker_id"
    case logProbability = "logprob"
  }
}

struct ElevenLabsTranscriptionClient: Sendable {
  private let endpoint: URL
  private let secretStore: any TranscriptionSecretStoring
  private let transport: any ElevenLabsHTTPTransport
  private let temporaryDirectory: URL

  init(
    endpoint: URL = URL(string: "https://api.elevenlabs.io/v1/speech-to-text")!,
    secretStore: any TranscriptionSecretStoring = KeychainTranscriptionSecretStore(),
    transport: any ElevenLabsHTTPTransport = URLSessionElevenLabsHTTPTransport(),
    temporaryDirectory: URL = FileManager.default.temporaryDirectory
  ) {
    self.endpoint = endpoint
    self.secretStore = secretStore
    self.transport = transport
    self.temporaryDirectory = temporaryDirectory
  }

  func ensureConfigured() throws {
    guard let apiKey = try secretStore.secret(for: .elevenLabs), !apiKey.isEmpty else {
      throw ElevenLabsTranscriptionError.missingAPIKey
    }
  }

  func transcribe(
    audioURL: URL,
    configuration: TranscriptionConfiguration
  ) async throws -> ElevenLabsTranscriptResponse {
    guard configuration.provider == .elevenLabs else {
      throw ElevenLabsTranscriptionError.invalidResponse
    }
    guard let apiKey = try secretStore.secret(for: .elevenLabs), !apiKey.isEmpty else {
      throw ElevenLabsTranscriptionError.missingAPIKey
    }

    let boundary = "MeetingBar-\(UUID().uuidString)"
    let bodyURL = temporaryDirectory.appending(
      path: ".meetingbar-elevenlabs-\(UUID().uuidString).multipart"
    )
    defer {
      try? FileManager.default.removeItem(at: bodyURL)
    }
    try MultipartFormFileWriter.write(
      to: bodyURL,
      boundary: boundary,
      fields: requestFields(for: configuration),
      fileField: "file",
      sourceURL: audioURL,
      contentType: "audio/wav"
    )

    var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "POST"
    request.timeoutInterval = 3_600
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue(
      "multipart/form-data; boundary=\(boundary)",
      forHTTPHeaderField: "Content-Type"
    )
    request.setValue("MeetingBar/1", forHTTPHeaderField: "User-Agent")

    let response = try await transport.upload(request, fromFile: bodyURL)
    guard (200..<300).contains(response.statusCode) else {
      throw ElevenLabsTranscriptionError.service(
        statusCode: response.statusCode,
        message: Self.errorMessage(from: response.data)
      )
    }
    do {
      return try JSONDecoder().decode(ElevenLabsTranscriptResponse.self, from: response.data)
    } catch {
      throw ElevenLabsTranscriptionError.invalidResponse
    }
  }

  func deleteTranscript(id: String) async throws {
    guard let apiKey = try secretStore.secret(for: .elevenLabs), !apiKey.isEmpty else {
      throw ElevenLabsTranscriptionError.missingAPIKey
    }
    let deletionURL = endpoint
      .appending(path: "transcripts", directoryHint: .isDirectory)
      .appending(path: id)
    var request = URLRequest(url: deletionURL, cachePolicy: .reloadIgnoringLocalCacheData)
    request.httpMethod = "DELETE"
    request.timeoutInterval = 60
    request.setValue(apiKey, forHTTPHeaderField: "xi-api-key")
    request.setValue("MeetingBar/1", forHTTPHeaderField: "User-Agent")

    let response = try await transport.send(request)
    guard (200..<300).contains(response.statusCode) || response.statusCode == 404 else {
      throw ElevenLabsTranscriptionError.service(
        statusCode: response.statusCode,
        message: Self.errorMessage(from: response.data)
      )
    }
  }

  private func requestFields(
    for configuration: TranscriptionConfiguration
  ) -> [(name: String, value: String)] {
    var fields = [
      (name: "model_id", value: configuration.modelIdentifier),
      (name: "tag_audio_events", value: "false"),
      (name: "diarize", value: "true"),
      (name: "timestamps_granularity", value: "word"),
    ]
    if let languageCode = configuration.language.whisperLanguageCode {
      fields.append((name: "language_code", value: languageCode))
    }
    return fields
  }

  private static func errorMessage(from data: Data) -> String {
    guard
      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
      let detail = object["detail"]
    else {
      return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
        .nonEmpty ?? "Unknown service error"
    }
    if let message = detail as? String {
      return message
    }
    if let detailObject = detail as? [String: Any] {
      if let message = detailObject["message"] as? String {
        return message
      }
      if let status = detailObject["status"] as? String {
        return status
      }
    }
    return "Unknown service error"
  }
}

struct PreparedElevenLabsAudio: Sendable {
  let audioURL: URL
  let durationSeconds: Double
  let transcriptSource: TranscriptionSource
  let temporaryURLs: [URL]

  func removeTemporaryFiles(fileManager: FileManager = .default) {
    for url in temporaryURLs {
      try? fileManager.removeItem(at: url)
    }
  }
}

struct ElevenLabsAudioPreparer: Sendable {
  private let preprocessor = TranscriptionAudioPreprocessor()

  func prepare(
    sources: [TranscriptionSource],
    temporaryDirectory: URL = FileManager.default.temporaryDirectory,
    fileManager: FileManager = .default
  ) throws -> PreparedElevenLabsAudio? {
    var preparedSources: [PreparedTranscriptionAudio] = []
    var temporaryURLs: [URL] = []

    do {
      for source in sources {
        try Task.checkCancellation()
        let prepared = try preprocessor.prepare(source)
        if let temporaryURL = prepared.temporaryURL {
          temporaryURLs.append(temporaryURL)
        }
        if prepared.shouldTranscribe {
          preparedSources.append(prepared)
        }
      }

      guard !preparedSources.isEmpty else {
        for url in temporaryURLs {
          try? fileManager.removeItem(at: url)
        }
        return nil
      }

      let identifier = UUID().uuidString
      let partialURL = temporaryDirectory.appending(
        path: ".meetingbar-elevenlabs-balanced-\(identifier).partial.wav"
      )
      let finalURL = temporaryDirectory.appending(
        path: ".meetingbar-elevenlabs-balanced-\(identifier).wav"
      )
      temporaryURLs.append(contentsOf: [partialURL, finalURL])
      let sampleCount = try AlignedPCM16AudioMixer.write(
        preparedSources: preparedSources,
        partialURL: partialURL,
        finalURL: finalURL,
        fileManager: fileManager
      )
      let durationSeconds = Double(sampleCount) / Double(PCM16WAVWriter.sampleRate)
      return PreparedElevenLabsAudio(
        audioURL: finalURL,
        durationSeconds: durationSeconds,
        transcriptSource: TranscriptionSource(
          kind: .microphone,
          audioURL: finalURL,
          offsetSeconds: 0,
          signal: nil
        ),
        temporaryURLs: temporaryURLs
      )
    } catch {
      for url in temporaryURLs {
        try? fileManager.removeItem(at: url)
      }
      throw error
    }
  }
}

struct ElevenLabsTranscriptDeletion: Codable, Hashable, Sendable {
  let transcriptionID: String
  let recordingID: UUID
  let enqueuedAt: Date
  var attemptCount: Int
  var isReadyForDeletion: Bool

  init(
    transcriptionID: String,
    recordingID: UUID,
    enqueuedAt: Date,
    attemptCount: Int,
    isReadyForDeletion: Bool = false
  ) {
    self.transcriptionID = transcriptionID
    self.recordingID = recordingID
    self.enqueuedAt = enqueuedAt
    self.attemptCount = attemptCount
    self.isReadyForDeletion = isReadyForDeletion
  }

  enum CodingKeys: String, CodingKey {
    case transcriptionID
    case recordingID
    case enqueuedAt
    case attemptCount
    case isReadyForDeletion
  }

  init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    transcriptionID = try container.decode(String.self, forKey: .transcriptionID)
    recordingID = try container.decode(UUID.self, forKey: .recordingID)
    enqueuedAt = try container.decode(Date.self, forKey: .enqueuedAt)
    attemptCount = try container.decode(Int.self, forKey: .attemptCount)
    isReadyForDeletion =
      try container.decodeIfPresent(Bool.self, forKey: .isReadyForDeletion) ?? false
  }
}

actor ElevenLabsTranscriptCleanupQueue {
  private let client: ElevenLabsTranscriptionClient
  private let persistenceURL: URL
  private var pending: [ElevenLabsTranscriptDeletion]
  private var processingTask: Task<Void, Never>?
  private var retryTask: Task<Void, Never>?

  init(client: ElevenLabsTranscriptionClient, persistenceURL: URL) {
    self.client = client
    self.persistenceURL = persistenceURL
    pending = Self.load(from: persistenceURL)
  }

  func enqueue(transcriptionID: String, recordingID: UUID) throws {
    guard !transcriptionID.isEmpty,
      !pending.contains(where: { $0.transcriptionID == transcriptionID })
    else {
      return
    }
    pending.append(
      ElevenLabsTranscriptDeletion(
        transcriptionID: transcriptionID,
        recordingID: recordingID,
        enqueuedAt: .now,
        attemptCount: 0,
        isReadyForDeletion: false
      )
    )
    do {
      try persist()
    } catch {
      pending.removeAll { $0.transcriptionID == transcriptionID }
      throw error
    }
  }

  func confirmLocalTranscriptStored(recordingID: UUID) throws {
    let matchingIndices = pending.indices.filter { pending[$0].recordingID == recordingID }
    guard !matchingIndices.isEmpty else {
      return
    }
    let unconfirmedIndices = matchingIndices.filter { !pending[$0].isReadyForDeletion }
    guard !unconfirmedIndices.isEmpty else {
      resume()
      return
    }

    for index in unconfirmedIndices {
      pending[index].isReadyForDeletion = true
    }
    do {
      try persist()
    } catch {
      for index in unconfirmedIndices {
        pending[index].isReadyForDeletion = false
      }
      throw error
    }
    resume()
  }

  func reconcileWithLocalRecordings(
    knownRecordingIDs: Set<UUID>,
    readyRecordingIDs: Set<UUID>
  ) throws {
    let previous = pending
    var didChange = false
    for index in pending.indices where !pending[index].isReadyForDeletion {
      let recordingID = pending[index].recordingID
      if readyRecordingIDs.contains(recordingID) || !knownRecordingIDs.contains(recordingID) {
        pending[index].isReadyForDeletion = true
        didChange = true
      }
    }

    if didChange {
      do {
        try persist()
      } catch {
        pending = previous
        throw error
      }
    }
    resume()
  }

  func resume() {
    retryTask?.cancel()
    retryTask = nil
    guard processingTask == nil, pending.contains(where: \.isReadyForDeletion) else {
      return
    }
    processingTask = Task { [weak self] in
      await self?.drain(scheduleRetry: true)
      await self?.workerFinished()
    }
  }

  func processPendingNow() async {
    retryTask?.cancel()
    retryTask = nil
    if let processingTask {
      await processingTask.value
      return
    }
    await drain(scheduleRetry: false)
  }

  func pendingDeletions() -> [ElevenLabsTranscriptDeletion] {
    pending
  }

  private func drain(scheduleRetry: Bool) async {
    while let index = pending.firstIndex(where: \.isReadyForDeletion) {
      let next = pending[index]
      do {
        try await client.deleteTranscript(id: next.transcriptionID)
        pending.remove(at: index)
        try? persist()
      } catch {
        pending[index].attemptCount += 1
        try? persist()
        if scheduleRetry {
          scheduleRetryTask(attemptCount: pending[index].attemptCount)
        }
        return
      }
    }
  }

  private func workerFinished() {
    processingTask = nil
    if pending.contains(where: \.isReadyForDeletion), retryTask == nil {
      resume()
    }
  }

  private func scheduleRetryTask(attemptCount: Int) {
    let exponent = min(6, max(0, attemptCount - 1))
    let delaySeconds = min(3_600, 60 * (1 << exponent))
    retryTask?.cancel()
    retryTask = Task { [weak self] in
      try? await Task.sleep(for: .seconds(delaySeconds))
      guard !Task.isCancelled else {
        return
      }
      await self?.retryTimerFired()
    }
  }

  private func retryTimerFired() {
    retryTask = nil
    resume()
  }

  private func persist() throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(pending).write(to: persistenceURL, options: .atomic)
  }

  private static func load(from url: URL) -> [ElevenLabsTranscriptDeletion] {
    guard let data = try? Data(contentsOf: url) else {
      return []
    }
    return (try? JSONDecoder().decode([ElevenLabsTranscriptDeletion].self, from: data)) ?? []
  }
}

enum ElevenLabsTranscriptSegmentBuilder {
  private static let maximumSegmentDuration = 8.0
  private static let maximumWordsPerSegment = 36
  private static let pauseBoundary = 1.5

  static func segments(
    from response: ElevenLabsTranscriptResponse,
    source: TranscriptionSource,
    durationSeconds: Double
  ) -> [SourceTranscriptSegment] {
    var speakerIDs: [String: Int] = [:]
    var output: [SourceTranscriptSegment] = []
    var segment = SegmentAccumulator()

    func flush() {
      guard let completed = segment.makeSegment(
        source: source,
        offsetSeconds: source.offsetSeconds,
        speakerIDs: &speakerIDs
      ) else {
        segment = SegmentAccumulator()
        return
      }
      output.append(completed)
      segment = SegmentAccumulator()
    }

    for token in response.words where token.type != "audio_event" {
      guard let start = token.start, let end = token.end else {
        segment.appendUntimed(token.text)
        continue
      }
      let resolvedSpeaker = token.speakerID ?? segment.speakerID
      let startsNewSegment =
        (!segment.isEmpty && resolvedSpeaker != segment.speakerID)
        || (segment.end.map { start - $0 > pauseBoundary } ?? false)
        || (segment.start.map { start - $0 >= maximumSegmentDuration } ?? false)
        || segment.wordCount >= maximumWordsPerSegment
      if startsNewSegment {
        flush()
      }
      segment.append(
        text: token.text,
        start: start,
        end: end,
        speakerID: resolvedSpeaker,
        logProbability: token.logProbability
      )
    }
    flush()

    if !output.isEmpty {
      return output
    }
    let text = TranscriptionQueue.normalize(response.text)
    guard !text.isEmpty else {
      return []
    }
    return [
      SourceTranscriptSegment(
        source: source.kind,
        start: source.offsetSeconds,
        end: source.offsetSeconds + durationSeconds,
        text: text,
        averageLogProbability: 0,
        noSpeechProbability: 0
      )
    ]
  }

  private struct SegmentAccumulator {
    private(set) var text = ""
    private(set) var start: Double?
    private(set) var end: Double?
    private(set) var speakerID: String?
    private(set) var wordCount = 0
    private var logProbabilityTotal = 0.0
    private var logProbabilityCount = 0

    var isEmpty: Bool {
      text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    mutating func append(
      text tokenText: String,
      start tokenStart: Double,
      end tokenEnd: Double,
      speakerID tokenSpeakerID: String?,
      logProbability: Double?
    ) {
      appendTokenText(tokenText)
      start = min(start ?? tokenStart, tokenStart)
      end = max(end ?? tokenEnd, tokenEnd)
      speakerID = speakerID ?? tokenSpeakerID
      wordCount += 1
      if let logProbability {
        logProbabilityTotal += logProbability
        logProbabilityCount += 1
      }
    }

    mutating func appendUntimed(_ tokenText: String) {
      guard !isEmpty else {
        return
      }
      appendTokenText(tokenText)
    }

    func makeSegment(
      source: TranscriptionSource,
      offsetSeconds: Double,
      speakerIDs: inout [String: Int]
    ) -> SourceTranscriptSegment? {
      let normalized = TranscriptionQueue.normalize(text)
      guard !normalized.isEmpty, let start, let end else {
        return nil
      }
      let numericSpeakerID: Int?
      if let speakerID {
        if let existing = speakerIDs[speakerID] {
          numericSpeakerID = existing
        } else {
          let next = speakerIDs.count
          speakerIDs[speakerID] = next
          numericSpeakerID = next
        }
      } else {
        numericSpeakerID = nil
      }
      return SourceTranscriptSegment(
        source: source.kind,
        start: start + offsetSeconds,
        end: end + offsetSeconds,
        text: normalized,
        averageLogProbability: logProbabilityCount > 0
          ? logProbabilityTotal / Double(logProbabilityCount)
          : 0,
        noSpeechProbability: 0,
        speakerID: numericSpeakerID
      )
    }

    private mutating func appendTokenText(_ tokenText: String) {
      guard !tokenText.isEmpty else {
        return
      }
      if text.isEmpty
        || tokenText.first?.isWhitespace == true
        || text.last?.isWhitespace == true
        || tokenText.first.map({ ".,!?;:)]}".contains($0) }) == true
      {
        text += tokenText
      } else {
        text += " \(tokenText)"
      }
    }
  }
}

private enum MultipartFormFileWriter {
  static func write(
    to destinationURL: URL,
    boundary: String,
    fields: [(name: String, value: String)],
    fileField: String,
    sourceURL: URL,
    contentType: String
  ) throws {
    FileManager.default.createFile(atPath: destinationURL.path, contents: nil)
    let output = try FileHandle(forWritingTo: destinationURL)
    defer { try? output.close() }

    for field in fields {
      try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
      try output.write(
        contentsOf: Data(
          "Content-Disposition: form-data; name=\"\(field.name)\"\r\n\r\n".utf8
        )
      )
      try output.write(contentsOf: Data("\(field.value)\r\n".utf8))
    }

    try output.write(contentsOf: Data("--\(boundary)\r\n".utf8))
    try output.write(
      contentsOf: Data(
        "Content-Disposition: form-data; name=\"\(fileField)\"; filename=\"\(sourceURL.lastPathComponent)\"\r\n"
          .utf8
      )
    )
    try output.write(contentsOf: Data("Content-Type: \(contentType)\r\n\r\n".utf8))

    let input = try FileHandle(forReadingFrom: sourceURL)
    defer { try? input.close() }
    while let chunk = try input.read(upToCount: 1_048_576), !chunk.isEmpty {
      try output.write(contentsOf: chunk)
    }
    try output.write(contentsOf: Data("\r\n--\(boundary)--\r\n".utf8))
  }
}

private extension String {
  var nonEmpty: String? {
    isEmpty ? nil : self
  }
}
