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
  private static let chunkSize = 32_768

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
    try? fileManager.removeItem(at: partialURL)

    do {
      let tracks = try preparedSources.map(PlaybackTrackReader.init)
      let writer = try PCM16WAVWriter(partialURL: partialURL, finalURL: outputURL)
      while true {
        try Task.checkCancellation()
        let chunks = try tracks.map { try $0.read(maxCount: Self.chunkSize) }
        let validSampleCount = chunks.map(\.validSampleCount).max() ?? 0
        guard validSampleCount > 0 else {
          break
        }

        var mixed = [Float](repeating: 0, count: validSampleCount)
        for index in 0..<validSampleCount {
          var sum: Float = 0
          var activeTrackCount = 0
          for chunk in chunks where index < chunk.samples.count {
            let sample = chunk.samples[index]
            sum += sample
            if abs(sample) > 0.000_001 {
              activeTrackCount += 1
            }
          }
          if activeTrackCount > 1 {
            sum /= sqrt(Float(activeTrackCount))
          }
          mixed[index] = softLimit(sum)
        }
        try writer.append(floatSamples: mixed)
      }
      _ = try writer.finish(fileManager: fileManager)
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw error
    }

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

  private func softLimit(_ sample: Float) -> Float {
    let magnitude = abs(sample)
    guard magnitude > 0.85 else {
      return sample
    }
    let compressed = 0.85 + 0.13 * (1 - exp(-(magnitude - 0.85) / 0.13))
    return sample.sign == .minus ? -compressed : compressed
  }
}

private final class PlaybackTrackReader {
  private let reader: PCM16WAVReader
  private var remainingOffsetSamples: Int
  private var exhausted = false

  init(prepared: PreparedTranscriptionAudio) throws {
    reader = try PCM16WAVReader(url: prepared.audioURL)
    remainingOffsetSamples = max(
      0,
      Int((prepared.source.offsetSeconds * Double(PCM16WAVWriter.sampleRate)).rounded())
    )
  }

  func read(maxCount: Int) throws -> PlaybackTrackChunk {
    guard !exhausted || remainingOffsetSamples > 0 else {
      return PlaybackTrackChunk(samples: [], validSampleCount: 0)
    }

    let leadingSilenceCount = min(remainingOffsetSamples, maxCount)
    remainingOffsetSamples -= leadingSilenceCount
    var samples = [Float](repeating: 0, count: leadingSilenceCount)

    if samples.count < maxCount, !exhausted {
      let requestedCount = maxCount - samples.count
      if let sourceSamples = try reader.readSamples(maxCount: requestedCount) {
        samples.append(contentsOf: sourceSamples.map { Float($0) / 32_768 })
      } else {
        exhausted = true
      }
    }

    return PlaybackTrackChunk(samples: samples, validSampleCount: samples.count)
  }
}

private struct PlaybackTrackChunk {
  let samples: [Float]
  let validSampleCount: Int
}
