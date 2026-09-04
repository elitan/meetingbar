import Foundation

enum PlaybackAudioProcessorError: LocalizedError {
  case noAudioSources

  var errorDescription: String? {
    switch self {
    case .noAudioSources:
      "No retained audio is available for playback."
    }
  }
}

struct PreparedPlaybackAudio: Sendable {
  let audioURL: URL
  let microphoneGainDB: Double?
  let systemGainDB: Double?

  var enhancementDescription: String? {
    let gains = [
      gainDescription(name: "microphone", gainDB: microphoneGainDB),
      gainDescription(name: "system audio", gainDB: systemGainDB),
    ].compactMap { $0 }

    guard !gains.isEmpty else {
      return nil
    }
    return "Balanced playback: " + gains.joined(separator: ", ")
  }

  private func gainDescription(name: String, gainDB: Double?) -> String? {
    guard let gainDB, gainDB >= 1 else {
      return nil
    }
    return "\(name) +\(Int(gainDB.rounded())) dB"
  }
}

struct PlaybackAudioProcessor: Sendable {
  private static let fileName = "playback-balanced-v1.wav"
  private static let partialFileName = "playback-balanced-v1.partial.wav"

  func prepare(
    recordingID: UUID,
    fallbackAudioURL: URL,
    fileStore: RecordingFileStore,
    fileManager: FileManager = .default
  ) throws -> PreparedPlaybackAudio {
    let sources = fileStore.transcriptionSources(
      for: recordingID,
      fallbackAudioURL: fallbackAudioURL,
      fileManager: fileManager
    )
    guard !sources.isEmpty else {
      throw PlaybackAudioProcessorError.noAudioSources
    }

    let directory = fileStore.directoryURL(for: recordingID)
    let outputURL = directory.appending(path: Self.fileName)
    if isCurrent(outputURL: outputURL, sources: sources, fileManager: fileManager) {
      return PreparedPlaybackAudio(
        audioURL: outputURL,
        microphoneGainDB: cachedGain(for: .microphone, sources: sources),
        systemGainDB: cachedGain(for: .system, sources: sources)
      )
    }

    let preprocessor = TranscriptionAudioPreprocessor()
    var preparedSources: [PreparedTranscriptionAudio] = []
    defer {
      for prepared in preparedSources {
        if let temporaryURL = prepared.temporaryURL {
          try? fileManager.removeItem(at: temporaryURL)
        }
      }
    }

    for source in sources {
      try Task.checkCancellation()
      let prepared = try preprocessor.prepare(source)
      if prepared.shouldTranscribe {
        preparedSources.append(prepared)
      } else if let temporaryURL = prepared.temporaryURL {
        try? fileManager.removeItem(at: temporaryURL)
      }
    }

    guard !preparedSources.isEmpty else {
      return PreparedPlaybackAudio(
        audioURL: fallbackAudioURL,
        microphoneGainDB: nil,
        systemGainDB: nil
      )
    }

    let partialURL = directory.appending(path: Self.partialFileName)
    try AlignedPCM16AudioMixer.write(
      preparedSources: preparedSources,
      partialURL: partialURL,
      finalURL: outputURL,
      fileManager: fileManager
    )

    return PreparedPlaybackAudio(
      audioURL: outputURL,
      microphoneGainDB: preparedSources.first(where: { $0.source.kind == .microphone })?
        .appliedGainDB,
      systemGainDB: preparedSources.first(where: { $0.source.kind == .system })?.appliedGainDB
    )
  }

  private func isCurrent(
    outputURL: URL,
    sources: [TranscriptionSource],
    fileManager: FileManager
  ) -> Bool {
    guard
      let outputDate = try? outputURL.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
    else {
      return false
    }

    return sources.allSatisfy { source in
      guard fileManager.fileExists(atPath: source.audioURL.path) else {
        return false
      }
      let sourceDate = try? source.audioURL.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      return sourceDate.map { $0 <= outputDate } ?? false
    }
  }

  private func cachedGain(
    for kind: CaptureSourceKind,
    sources: [TranscriptionSource]
  ) -> Double? {
    guard let signal = sources.first(where: { $0.kind == kind })?.signal,
      !signal.isEffectivelySilent
    else {
      return nil
    }
    return TranscriptionAudioPreprocessor.recommendedGainDB(for: signal)
  }

}
