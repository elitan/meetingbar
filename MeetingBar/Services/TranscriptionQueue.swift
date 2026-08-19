import Foundation
import WhisperKit

struct TranscriptionJob: Hashable, Sendable {
  let recordingID: UUID
  let audioURL: URL
}

enum TranscriptionQueueEvent: Sendable {
  case modelDownloadProgress(Double)
  case modelReady
  case started(UUID)
  case completed(recordingID: UUID, transcript: String, language: String?, modelIdentifier: String)
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
  static let modelIdentifier = "large-v3-v20240930_626MB"

  private let modelsURL: URL
  private let eventHandler: @MainActor @Sendable (TranscriptionQueueEvent) -> Void
  private var pendingJobs: [TranscriptionJob] = []
  private var knownJobIDs: Set<UUID> = []
  private var processingTask: Task<Void, Never>?
  private var modelPreparationTask: Task<Void, Never>?
  private var whisperKit: WhisperKit?
  private var modelPreparationError: TranscriptionQueueError?

  init(
    modelsURL: URL,
    eventHandler: @escaping @MainActor @Sendable (TranscriptionQueueEvent) -> Void
  ) {
    self.modelsURL = modelsURL
    self.eventHandler = eventHandler
  }

  func prepareModel() async throws {
    if whisperKit != nil {
      return
    }
    if modelPreparationTask == nil {
      modelPreparationError = nil
      modelPreparationTask = Task { [weak self] in
        await self?.performModelPreparation()
      }
    }
    await modelPreparationTask?.value
    if let modelPreparationError {
      throw modelPreparationError
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
      await eventHandler(.started(job.recordingID))
      await process(job)
      knownJobIDs.remove(job.recordingID)
    }
    processingTask = nil
    if !pendingJobs.isEmpty {
      beginProcessingIfNeeded()
    }
  }

  private func process(_ job: TranscriptionJob) async {
    do {
      guard FileManager.default.fileExists(atPath: job.audioURL.path) else {
        throw TranscriptionQueueError.audioUnavailable
      }
      try await prepareModel()
      guard let whisperKit else {
        throw TranscriptionQueueError.modelUnavailable("The model did not finish loading.")
      }

      let results = try await whisperKit.transcribe(
        audioPath: job.audioURL.path,
        audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
        decodeOptions: DecodingOptions(
          task: .transcribe,
          language: nil,
          usePrefillPrompt: true,
          detectLanguage: true,
          skipSpecialTokens: true,
          withoutTimestamps: false,
          chunkingStrategy: .vad
        )
      )
      let transcript = Self.normalize(results.map(\.text).joined(separator: " "))
      await eventHandler(
        .completed(
          recordingID: job.recordingID,
          transcript: transcript,
          language: results.first?.language,
          modelIdentifier: Self.modelIdentifier
        )
      )
    } catch {
      await eventHandler(.failed(recordingID: job.recordingID, message: error.localizedDescription))
    }
  }

  private func performModelPreparation() async {
    do {
      let defaultsKey = "WhisperKitModelFolder.\(Self.modelIdentifier)"
      let savedPath = UserDefaults.standard.string(forKey: defaultsKey)
      let modelFolder: URL
      if let savedPath, FileManager.default.fileExists(atPath: savedPath) {
        modelFolder = URL(filePath: savedPath, directoryHint: .isDirectory)
      } else {
        let handler = eventHandler
        modelFolder = try await WhisperKit.download(
          variant: Self.modelIdentifier,
          downloadBase: modelsURL,
          progressCallback: { progress in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
              handler(.modelDownloadProgress(fraction))
            }
          }
        )
        UserDefaults.standard.set(modelFolder.path, forKey: defaultsKey)
      }

      let configuration = WhisperKitConfig(
        model: Self.modelIdentifier,
        modelFolder: modelFolder.path,
        verbose: false,
        prewarm: true,
        load: true,
        download: false
      )
      whisperKit = try await WhisperKit(configuration)
      await eventHandler(.modelReady)
    } catch {
      modelPreparationError = .modelUnavailable(error.localizedDescription)
      modelPreparationTask = nil
    }
  }

  private static func normalize(_ transcript: String) -> String {
    transcript
      .split(whereSeparator: \Character.isWhitespace)
      .joined(separator: " ")
      .trimmingCharacters(in: .whitespacesAndNewlines)
  }
}
