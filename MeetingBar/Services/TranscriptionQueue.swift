import Foundation
import SpeakerKit
import WhisperKit

struct TranscriptionJob: Hashable, Sendable {
  let recordingID: UUID
  let sources: [TranscriptionSource]
  let configuration: TranscriptionConfiguration
}

enum TranscriptionQueueEvent: Sendable {
  case modelDownloadProgress(modelIdentifier: String, progress: Double)
  case modelReady(modelIdentifier: String)
  case speakerModelPreparing
  case speakerModelReady
  case speakerModelFailed(String)
  case started(
    recordingID: UUID,
    provider: TranscriptionProvider,
    modelIdentifier: String
  )
  case idle
  case completed(
    recordingID: UUID,
    transcript: String,
    language: String?,
    provider: TranscriptionProvider,
    modelIdentifier: String,
    warnings: [String]
  )
  case failed(recordingID: UUID, message: String)
}

enum TranscriptionQueueError: LocalizedError, Sendable {
  case modelUnavailable(String)
  case audioUnavailable

  var errorDescription: String? {
    switch self {
    case .modelUnavailable(let message):
      "The transcription model is unavailable: \(message)"
    case .audioUnavailable:
      "The source audio is no longer available."
    }
  }
}

actor TranscriptionQueue {
  static let recommendedModelIdentifier = TranscriptionQuality.bestAccuracy.modelIdentifier

  private let modelsURL: URL
  private let eventHandler: @MainActor @Sendable (TranscriptionQueueEvent) -> Bool
  private let elevenLabsClient: ElevenLabsTranscriptionClient
  private let elevenLabsCleanupQueue: ElevenLabsTranscriptCleanupQueue
  private let preprocessor = TranscriptionAudioPreprocessor()
  private let elevenLabsAudioPreparer = ElevenLabsAudioPreparer()
  private var pendingJobs: [TranscriptionJob] = []
  private var knownJobIDs: Set<UUID> = []
  private var processingTask: Task<Void, Never>?
  private var modelPreparationTask: Task<Void, Never>?
  private var loadedModelIdentifier: String?
  private var whisperKit: WhisperKit?
  private var modelPreparationError: TranscriptionQueueError?
  private var speakerKit: SpeakerKit?
  private var speakerPreparationTask: Task<SpeakerKit, Error>?

  init(
    modelsURL: URL,
    secretStore: any TranscriptionSecretStoring = KeychainTranscriptionSecretStore(),
    elevenLabsTransport: any ElevenLabsHTTPTransport = URLSessionElevenLabsHTTPTransport(),
    elevenLabsCleanupURL: URL? = nil,
    eventHandler: @escaping @MainActor @Sendable (TranscriptionQueueEvent) -> Bool
  ) {
    self.modelsURL = modelsURL
    let client = ElevenLabsTranscriptionClient(
      secretStore: secretStore,
      transport: elevenLabsTransport
    )
    elevenLabsClient = client
    elevenLabsCleanupQueue = ElevenLabsTranscriptCleanupQueue(
      client: client,
      persistenceURL: elevenLabsCleanupURL
        ?? modelsURL.deletingLastPathComponent().appending(path: "elevenlabs-cleanup.json")
    )
    self.eventHandler = eventHandler
  }

  func prepareModel(configuration: TranscriptionConfiguration) async throws {
    switch configuration.provider {
    case .onDevice:
      try await prepareModel(identifier: configuration.modelIdentifier)
      _ = try? await prepareSpeakerKit()
    case .elevenLabs:
      try elevenLabsClient.ensureConfigured()
      _ = await eventHandler(.modelReady(modelIdentifier: configuration.modelIdentifier))
    }
  }

  func enqueue(_ job: TranscriptionJob) {
    guard knownJobIDs.insert(job.recordingID).inserted else {
      return
    }
    pendingJobs.append(job)
    beginProcessingIfNeeded()
  }

  func retry(_ job: TranscriptionJob) {
    knownJobIDs.remove(job.recordingID)
    enqueue(job)
  }

  func resumeRemoteCleanup() async {
    await elevenLabsCleanupQueue.resume()
  }

  func reconcileRemoteCleanup(
    knownRecordingIDs: Set<UUID>,
    readyRecordingIDs: Set<UUID>
  ) async {
    try? await elevenLabsCleanupQueue.reconcileWithLocalRecordings(
      knownRecordingIDs: knownRecordingIDs,
      readyRecordingIDs: readyRecordingIDs
    )
  }

  static func decodeOptions(
    for configuration: TranscriptionConfiguration
  ) -> DecodingOptions {
    let language = configuration.language.whisperLanguageCode
    return DecodingOptions(
      task: .transcribe,
      language: language,
      usePrefillPrompt: true,
      detectLanguage: language == nil,
      skipSpecialTokens: true,
      withoutTimestamps: false,
      wordTimestamps: true,
      chunkingStrategy: .vad
    )
  }

  static func normalize(_ transcript: String) -> String {
    transcript
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func prepareModel(identifier: String) async throws {
    if loadedModelIdentifier == identifier, whisperKit != nil {
      return
    }

    if let existingTask = modelPreparationTask {
      await existingTask.value
      if loadedModelIdentifier == identifier, whisperKit != nil {
        return
      }
    }

    modelPreparationError = nil
    let task = Task { [weak self] in
      guard let self else {
        return
      }
      await self.performModelPreparation(identifier: identifier)
    }
    modelPreparationTask = task
    await task.value

    if loadedModelIdentifier == identifier, whisperKit != nil {
      return
    }
    if let modelPreparationError {
      throw modelPreparationError
    }
    throw TranscriptionQueueError.modelUnavailable("The model did not finish loading.")
  }

  private func beginProcessingIfNeeded() {
    guard processingTask == nil else {
      return
    }
    processingTask = Task { [weak self] in
      await self?.processPendingJobs()
    }
  }

  private func processPendingJobs() async {
    while !pendingJobs.isEmpty {
      let job = pendingJobs.removeFirst()
      _ = await eventHandler(
        .started(
          recordingID: job.recordingID,
          provider: job.configuration.provider,
          modelIdentifier: job.configuration.modelIdentifier
        )
      )
      await process(job)
      knownJobIDs.remove(job.recordingID)
    }
    processingTask = nil
    if !pendingJobs.isEmpty {
      beginProcessingIfNeeded()
    } else {
      _ = await eventHandler(.idle)
    }
  }

  private func process(_ job: TranscriptionJob) async {
    do {
      let existingSources = job.sources.filter {
        FileManager.default.fileExists(atPath: $0.audioURL.path)
      }
      guard !existingSources.isEmpty else {
        throw TranscriptionQueueError.audioUnavailable
      }
      try await prepareModel(configuration: job.configuration)
      switch job.configuration.provider {
      case .onDevice:
        try await processOnDevice(job, sources: existingSources)
      case .elevenLabs:
        try await processWithElevenLabs(job, sources: existingSources)
      }
    } catch {
      _ = await eventHandler(
        .failed(recordingID: job.recordingID, message: error.localizedDescription)
      )
    }
  }

  private func processOnDevice(
    _ job: TranscriptionJob,
    sources: [TranscriptionSource]
  ) async throws {
    guard let whisperKit else {
      throw TranscriptionQueueError.modelUnavailable("The model did not finish loading.")
    }

    var segments: [SourceTranscriptSegment] = []
    var languageWeights: [String: Int] = [:]
    var warnings: [String] = []
    for source in sources {
      let prepared = try preprocessor.prepare(source)
      defer {
        if let temporaryURL = prepared.temporaryURL {
          try? FileManager.default.removeItem(at: temporaryURL)
        }
      }
      guard prepared.shouldTranscribe else {
        continue
      }

      let results = try await whisperKit.transcribe(
        audioPath: prepared.audioURL.path,
        audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
        decodeOptions: Self.decodeOptions(for: job.configuration)
      )
      let acceptedSegments = TranscriptionPostprocessor.sourceSegments(
        from: results,
        source: source,
        activity: prepared.activity
      )
      guard !acceptedSegments.isEmpty else {
        continue
      }

      do {
        let speakerKit = try await prepareSpeakerKit()
        let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: prepared.audioURL.path)
        let diarization = try await speakerKit.diarize(audioArray: audio)
        let attributedSegments = TranscriptionPostprocessor.speakerAttributedSourceSegments(
          from: results,
          diarization: diarization,
          acceptedSegments: acceptedSegments,
          source: source,
        )
        if diarization.speakerCount > 0,
          attributedSegments.contains(where: { $0.speakerID != nil })
        {
          segments.append(contentsOf: attributedSegments)
        } else {
          segments.append(contentsOf: acceptedSegments)
          appendSpeakerFallbackWarning(for: source.kind, to: &warnings)
        }
      } catch {
        segments.append(contentsOf: acceptedSegments)
        appendSpeakerFallbackWarning(for: source.kind, to: &warnings)
      }

      for result in results {
        let wordCount = max(1, Self.normalize(result.text).split(separator: " ").count)
        languageWeights[result.language, default: 0] += wordCount
      }
    }
    _ = await complete(
      job,
      segments: segments,
      languageWeights: languageWeights,
      warnings: warnings
    )
  }

  private func processWithElevenLabs(
    _ job: TranscriptionJob,
    sources: [TranscriptionSource]
  ) async throws {
    guard let prepared = try elevenLabsAudioPreparer.prepare(sources: sources) else {
      _ = await complete(job, segments: [], languageWeights: [:], warnings: [])
      return
    }
    defer {
      prepared.removeTemporaryFiles()
    }

    var warnings: [String] = []
    var languageWeights: [String: Int] = [:]
    let response = try await elevenLabsClient.transcribe(
      audioURL: prepared.audioURL,
      configuration: job.configuration
    )
    if let transcriptionID = response.transcriptionID {
      do {
        try await elevenLabsCleanupQueue.enqueue(
          transcriptionID: transcriptionID,
          recordingID: job.recordingID
        )
      } catch {
        warnings.append(
          "MeetingBar could not queue the ElevenLabs transcript for automatic deletion: \(error.localizedDescription)"
        )
      }
    } else {
      warnings.append(
        "ElevenLabs did not return a transcript ID, so MeetingBar could not request automatic deletion."
      )
    }
    let segments = ElevenLabsTranscriptSegmentBuilder.segments(
      from: response,
      source: prepared.transcriptSource,
      durationSeconds: prepared.durationSeconds
    )
    if let language = response.languageCode {
      let wordCount = max(1, Self.normalize(response.text).split(separator: " ").count)
      languageWeights[language, default: 0] += wordCount
    }
    let transcriptWasStored = await complete(
      job,
      segments: segments,
      languageWeights: languageWeights,
      warnings: warnings
    )
    if transcriptWasStored {
      try? await elevenLabsCleanupQueue.confirmLocalTranscriptStored(
        recordingID: job.recordingID
      )
    }
  }

  private func complete(
    _ job: TranscriptionJob,
    segments: [SourceTranscriptSegment],
    languageWeights: [String: Int],
    warnings: [String]
  ) async -> Bool {
    let mergedSegments = TranscriptionPostprocessor.mergeAndDeduplicate(segments)
    let transcript = SpeakerTranscriptFormatter.format(mergedSegments)
    let language =
      job.configuration.language.whisperLanguageCode
      ?? languageWeights.max(by: { $0.value < $1.value })?.key
    return await eventHandler(
      .completed(
        recordingID: job.recordingID,
        transcript: transcript,
        language: language,
        provider: job.configuration.provider,
        modelIdentifier: job.configuration.modelIdentifier,
        warnings: warnings
      )
    )
  }

  private func performModelPreparation(identifier: String) async {
    do {
      let defaultsKey = "WhisperKitModelFolder.\(identifier)"
      let savedPath = UserDefaults.standard.string(forKey: defaultsKey)
      let modelFolder: URL
      if let savedPath, FileManager.default.fileExists(atPath: savedPath) {
        modelFolder = URL(filePath: savedPath, directoryHint: .isDirectory)
      } else {
        let handler = eventHandler
        modelFolder = try await WhisperKit.download(
          variant: identifier,
          downloadBase: modelsURL,
          progressCallback: { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
              handler(.modelDownloadProgress(modelIdentifier: identifier, progress: fraction))
            }
          }
        )
        UserDefaults.standard.set(modelFolder.path, forKey: defaultsKey)
      }

      let configuration = WhisperKitConfig(
        model: identifier,
        modelFolder: modelFolder.path,
        verbose: false,
        prewarm: true,
        load: true,
        download: false
      )
      whisperKit = try await WhisperKit(configuration)
      loadedModelIdentifier = identifier
      modelPreparationError = nil
      modelPreparationTask = nil
      _ = await eventHandler(.modelReady(modelIdentifier: identifier))
    } catch {
      modelPreparationError = .modelUnavailable(error.localizedDescription)
      modelPreparationTask = nil
    }
  }

  private func prepareSpeakerKit() async throws -> SpeakerKit {
    if let speakerKit {
      return speakerKit
    }
    if let speakerPreparationTask {
      return try await speakerPreparationTask.value
    }

    let modelDirectory = modelsURL.appending(
      path: "SpeakerKit",
      directoryHint: .isDirectory
    )
    let configuration = PyannoteConfig(
      downloadBase: modelDirectory.path,
      download: true,
      load: false,
      verbose: false
    )
    _ = await eventHandler(.speakerModelPreparing)
    let task = Task {
      try await SpeakerKit(configuration)
    }
    speakerPreparationTask = task

    do {
      let prepared = try await task.value
      speakerKit = prepared
      speakerPreparationTask = nil
      _ = await eventHandler(.speakerModelReady)
      return prepared
    } catch {
      speakerPreparationTask = nil
      _ = await eventHandler(.speakerModelFailed(error.localizedDescription))
      throw error
    }
  }

  private func appendSpeakerFallbackWarning(
    for source: CaptureSourceKind,
    to warnings: inout [String]
  ) {
    let sourceName = source == .microphone ? "microphone" : "system audio"
    let warning =
      "Speaker detection was unavailable for \(sourceName), so a source-level speaker label was used."
    if !warnings.contains(warning) {
      warnings.append(warning)
    }
  }

}

enum TranscriptionPostprocessor {
  static func sourceSegments(
    from results: [TranscriptionResult],
    source: TranscriptionSource,
    activity: AudioActivityTimeline
  ) -> [SourceTranscriptSegment] {
    var segments: [SourceTranscriptSegment] = []
    for result in results {
      if result.segments.isEmpty {
        let text = TranscriptionQueue.normalize(result.text)
        if !text.isEmpty,
          !isNonSpeechAnnotation(text),
          activity.hasSpeechActivity(from: 0, to: activity.durationSeconds)
        {
          segments.append(
            SourceTranscriptSegment(
              source: source.kind,
              start: source.offsetSeconds,
              end: source.offsetSeconds,
              text: text,
              averageLogProbability: 0,
              noSpeechProbability: 0
            )
          )
        }
        continue
      }

      for segment in result.segments {
        let text = TranscriptionQueue.normalize(segment.text)
        guard !text.isEmpty else {
          continue
        }
        guard !isNonSpeechAnnotation(text) else {
          continue
        }
        guard !(segment.noSpeechProb > 0.75 && segment.avgLogprob < -0.8) else {
          continue
        }
        guard
          activity.hasSpeechActivity(
            from: Double(segment.start),
            to: Double(segment.end)
          )
        else {
          continue
        }
        segments.append(
          SourceTranscriptSegment(
            source: source.kind,
            start: Double(segment.start) + source.offsetSeconds,
            end: Double(segment.end) + source.offsetSeconds,
            text: text,
            averageLogProbability: Double(segment.avgLogprob),
            noSpeechProbability: Double(segment.noSpeechProb)
          )
        )
      }
    }
    return segments
  }

  static func mergeAndDeduplicate(
    _ segments: [SourceTranscriptSegment]
  ) -> [SourceTranscriptSegment] {
    let sorted = segments.sorted(by: segmentOrder)
    var accepted: [SourceTranscriptSegment] = []

    for candidate in sorted {
      let duplicateIndex = accepted.indices.reversed().first { index in
        let existing = accepted[index]
        guard candidate.start - existing.end <= 2 else {
          return false
        }
        let timeIsClose =
          candidate.start <= existing.end + 1.5
          && existing.start <= candidate.end + 1.5
        let threshold = candidate.source == existing.source ? 0.92 : 0.78
        return timeIsClose && textSimilarity(candidate.text, existing.text) >= threshold
      }

      guard let duplicateIndex else {
        accepted.append(candidate)
        continue
      }
      if qualityScore(candidate) > qualityScore(accepted[duplicateIndex]) {
        accepted[duplicateIndex] = candidate
      }
    }

    return accepted.sorted(by: segmentOrder)
  }

  static func speakerAttributedSourceSegments(
    from results: [TranscriptionResult],
    diarization: DiarizationResult,
    acceptedSegments: [SourceTranscriptSegment],
    source: TranscriptionSource
  ) -> [SourceTranscriptSegment] {
    let speakerGroups = diarization.addSpeakerInfo(to: results, strategy: .subsegment)
    var attributed: [SourceTranscriptSegment] = []

    for speakerSegment in speakerGroups.flatMap({ $0 }) {
      let text = TranscriptionQueue.normalize(speakerSegment.text)
      guard !text.isEmpty else {
        continue
      }

      let start = Double(speakerSegment.startTime) + source.offsetSeconds
      let end = Double(speakerSegment.endTime) + source.offsetSeconds
      guard
        let accepted = acceptedSegments.max(by: { left, right in
          overlapDuration(start: start, end: end, with: left)
            < overlapDuration(start: start, end: end, with: right)
        }),
        overlapDuration(start: start, end: end, with: accepted) > 0
      else {
        continue
      }

      attributed.append(
        SourceTranscriptSegment(
          source: source.kind,
          start: start,
          end: end,
          text: text,
          averageLogProbability: accepted.averageLogProbability,
          noSpeechProbability: accepted.noSpeechProbability,
          speakerID: speakerSegment.speaker.speakerId
        )
      )
    }

    for accepted in acceptedSegments
    where !attributed.contains(where: {
      overlapDuration(start: $0.start, end: $0.end, with: accepted) > 0
    }) {
      attributed.append(accepted)
    }

    return attributed.sorted(by: segmentOrder)
  }

  private static func segmentOrder(
    _ left: SourceTranscriptSegment,
    _ right: SourceTranscriptSegment
  ) -> Bool {
    if left.start != right.start {
      return left.start < right.start
    }
    return left.source.transcriptOrder < right.source.transcriptOrder
  }

  private static func qualityScore(_ segment: SourceTranscriptSegment) -> Double {
    let cleanSourceBonus = segment.source == .system ? 0.1 : 0
    return segment.averageLogProbability - segment.noSpeechProbability + cleanSourceBonus
  }

  private static func textSimilarity(_ left: String, _ right: String) -> Double {
    let leftWords = normalizedWords(left)
    let rightWords = normalizedWords(right)
    guard !leftWords.isEmpty, !rightWords.isEmpty else {
      return 0
    }

    var remainingCounts: [String: Int] = [:]
    for word in rightWords {
      remainingCounts[word, default: 0] += 1
    }
    var matches = 0
    for word in leftWords where (remainingCounts[word] ?? 0) > 0 {
      matches += 1
      remainingCounts[word, default: 0] -= 1
    }
    return Double(2 * matches) / Double(leftWords.count + rightWords.count)
  }

  private static func normalizedWords(_ text: String) -> [String] {
    text.lowercased().split { character in
      !character.isLetter && !character.isNumber
    }.map(String.init)
  }

  private static func overlapDuration(
    start: Double,
    end: Double,
    with segment: SourceTranscriptSegment
  ) -> Double {
    max(0, min(end, segment.end) - max(start, segment.start))
  }

  private static func isNonSpeechAnnotation(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let pairs: [(Character, Character)] = [("*", "*"), ("[", "]"), ("(", ")")]
    guard let first = trimmed.first, let last = trimmed.last,
      pairs.contains(where: { $0.0 == first && $0.1 == last })
    else {
      return false
    }
    return normalizedWords(trimmed).count <= 4
  }
}

struct SourceTranscriptSegment: Sendable {
  let source: CaptureSourceKind
  let start: Double
  let end: Double
  let text: String
  let averageLogProbability: Double
  let noSpeechProbability: Double
  let speakerID: Int?

  init(
    source: CaptureSourceKind,
    start: Double,
    end: Double,
    text: String,
    averageLogProbability: Double,
    noSpeechProbability: Double,
    speakerID: Int? = nil
  ) {
    self.source = source
    self.start = start
    self.end = end
    self.text = text
    self.averageLogProbability = averageLogProbability
    self.noSpeechProbability = noSpeechProbability
    self.speakerID = speakerID
  }
}
