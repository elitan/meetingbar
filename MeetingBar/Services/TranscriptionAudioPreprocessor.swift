import Foundation

enum TranscriptionAudioPreprocessorError: LocalizedError {
  case unsupportedWAV

  var errorDescription: String? {
    switch self {
    case .unsupportedWAV:
      "MeetingBar can only normalize its 16 kHz mono PCM recordings."
    }
  }
}

struct PreparedTranscriptionAudio: Sendable {
  let source: TranscriptionSource
  let audioURL: URL
  let signal: AudioSignalSummary
  let activity: AudioActivityTimeline
  let appliedGainDB: Double
  let temporaryURL: URL?

  var shouldTranscribe: Bool {
    !signal.isEffectivelySilent
  }
}

struct TranscriptionAudioPreprocessor: Sendable {
  private static let targetSpeechDBFS = -20.0
  private static let maximumGainDB = 18.0

  static func recommendedGainDB(for signal: AudioSignalSummary) -> Double {
    min(
      maximumGainDB,
      max(0, targetSpeechDBFS - signal.speechRMSDBFS)
    )
  }

  func prepare(_ source: TranscriptionSource) throws -> PreparedTranscriptionAudio {
    let analysis = try analyzeDetails(url: source.audioURL)
    let signal = analysis.summary
    guard !signal.isEffectivelySilent else {
      return PreparedTranscriptionAudio(
        source: source,
        audioURL: source.audioURL,
        signal: signal,
        activity: analysis.activity,
        appliedGainDB: 0,
        temporaryURL: nil
      )
    }

    let gainDB = Self.recommendedGainDB(for: signal)
    guard gainDB >= 1 else {
      return PreparedTranscriptionAudio(
        source: source,
        audioURL: source.audioURL,
        signal: signal,
        activity: analysis.activity,
        appliedGainDB: 0,
        temporaryURL: nil
      )
    }

    let identifier = UUID().uuidString
    let directory = source.audioURL.deletingLastPathComponent()
    let partialURL = directory.appending(
      path: ".transcription-\(source.kind.rawValue)-\(identifier).partial.wav"
    )
    let finalURL = directory.appending(
      path: ".transcription-\(source.kind.rawValue)-\(identifier).wav"
    )

    do {
      let reader = try PCM16WAVReader(url: source.audioURL)
      let writer = try PCM16WAVWriter(partialURL: partialURL, finalURL: finalURL)
      let gain = Float(pow(10, gainDB / 20))
      while let samples = try reader.readSamples(maxCount: 32_768) {
        let normalized = samples.map { sample -> Int16 in
          let floatSample = Float(sample) / 32_768 * gain
          let limited = min(0.98, max(-0.98, floatSample))
          return Int16((limited * Float(Int16.max)).rounded())
        }
        try writer.append(pcm16Samples: normalized)
      }
      _ = try writer.finish()
      return PreparedTranscriptionAudio(
        source: source,
        audioURL: finalURL,
        signal: signal,
        activity: analysis.activity,
        appliedGainDB: gainDB,
        temporaryURL: finalURL
      )
    } catch {
      try? FileManager.default.removeItem(at: partialURL)
      try? FileManager.default.removeItem(at: finalURL)
      throw error
    }
  }

  func analyze(url: URL) throws -> AudioSignalSummary {
    try analyzeDetails(url: url).summary
  }

  private func analyzeDetails(url: URL) throws -> AudioSignalAnalysis {
    let reader = try PCM16WAVReader(url: url)
    var analyzer = AudioSignalAnalyzer()
    while let samples = try reader.readSamples(maxCount: 32_768) {
      let floats = samples.map { Float($0) / 32_768 }
      analyzer.append(floats)
    }
    return analyzer.analysis()
  }
}

final class PCM16WAVReader {
  private let fileHandle: FileHandle
  private var remainingDataBytes: UInt64 = 0

  init(url: URL) throws {
    fileHandle = try FileHandle(forReadingFrom: url)
    do {
      try locateAudioData()
    } catch {
      try? fileHandle.close()
      throw error
    }
  }

  deinit {
    try? fileHandle.close()
  }

  func readSamples(maxCount: Int) throws -> [Int16]? {
    guard remainingDataBytes >= 2 else {
      return nil
    }
    let requestedBytes = min(UInt64(maxCount * 2), remainingDataBytes)
    let data = try fileHandle.read(upToCount: Int(requestedBytes)) ?? Data()
    guard !data.isEmpty else {
      remainingDataBytes = 0
      return nil
    }
    let evenByteCount = data.count - (data.count % 2)
    var samples = [Int16](repeating: 0, count: evenByteCount / 2)
    _ = samples.withUnsafeMutableBytes { destination in
      data.copyBytes(to: destination, count: evenByteCount)
    }
    remainingDataBytes -= UInt64(evenByteCount)
    return samples.map(Int16.init(littleEndian:))
  }

  private func locateAudioData() throws {
    let riffHeader = try fileHandle.read(upToCount: 12) ?? Data()
    guard riffHeader.count == 12,
      String(data: riffHeader[0..<4], encoding: .ascii) == "RIFF",
      String(data: riffHeader[8..<12], encoding: .ascii) == "WAVE"
    else {
      throw TranscriptionAudioPreprocessorError.unsupportedWAV
    }

    var foundCompatibleFormat = false
    while true {
      let chunkHeader = try fileHandle.read(upToCount: 8) ?? Data()
      guard chunkHeader.count == 8,
        let chunkSize = chunkHeader.uint32LittleEndian(at: 4),
        let chunkName = String(data: chunkHeader[0..<4], encoding: .ascii)
      else {
        throw TranscriptionAudioPreprocessorError.unsupportedWAV
      }

      if chunkName == "fmt " {
        guard chunkSize >= 16, chunkSize <= 1_048_576 else {
          throw TranscriptionAudioPreprocessorError.unsupportedWAV
        }
        let format = try fileHandle.read(upToCount: Int(chunkSize)) ?? Data()
        guard format.count == Int(chunkSize),
          format.uint16LittleEndian(at: 0) == 1,
          format.uint16LittleEndian(at: 2) == PCM16WAVWriter.channelCount,
          format.uint32LittleEndian(at: 4) == PCM16WAVWriter.sampleRate,
          format.uint16LittleEndian(at: 14) == PCM16WAVWriter.bitsPerSample
        else {
          throw TranscriptionAudioPreprocessorError.unsupportedWAV
        }
        foundCompatibleFormat = true
        try skipPaddingIfNeeded(after: chunkSize)
      } else if chunkName == "data" {
        guard foundCompatibleFormat else {
          throw TranscriptionAudioPreprocessorError.unsupportedWAV
        }
        remainingDataBytes = UInt64(chunkSize)
        return
      } else {
        let currentOffset = try fileHandle.offset()
        try fileHandle.seek(
          toOffset: currentOffset + UInt64(chunkSize) + UInt64(chunkSize % 2)
        )
      }
    }
  }

  private func skipPaddingIfNeeded(after chunkSize: UInt32) throws {
    guard chunkSize % 2 != 0 else {
      return
    }
    let currentOffset = try fileHandle.offset()
    try fileHandle.seek(toOffset: currentOffset + 1)
  }
}

enum AlignedPCM16AudioMixer {
  static let chunkSize = 32_768

  @discardableResult
  static func write(
    preparedSources: [PreparedTranscriptionAudio],
    partialURL: URL,
    finalURL: URL,
    fileManager: FileManager = .default
  ) throws -> UInt64 {
    precondition(!preparedSources.isEmpty)
    try? fileManager.removeItem(at: partialURL)

    do {
      let tracks = try preparedSources.map(AlignedPCM16TrackReader.init)
      let writer = try PCM16WAVWriter(
        partialURL: partialURL,
        finalURL: finalURL,
        fileManager: fileManager
      )
      while true {
        try Task.checkCancellation()
        let chunks = try tracks.map { try $0.read(maxCount: chunkSize) }
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
      let sampleCount = writer.sampleCount
      _ = try writer.finish(fileManager: fileManager)
      return sampleCount
    } catch {
      try? fileManager.removeItem(at: partialURL)
      throw error
    }
  }

  private static func softLimit(_ sample: Float) -> Float {
    let magnitude = abs(sample)
    guard magnitude > 0.85 else {
      return sample
    }
    let compressed = 0.85 + 0.13 * (1 - exp(-(magnitude - 0.85) / 0.13))
    return sample.sign == .minus ? -compressed : compressed
  }
}

final class AlignedPCM16TrackReader {
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

  func read(maxCount: Int) throws -> AlignedPCM16TrackChunk {
    guard !exhausted || remainingOffsetSamples > 0 else {
      return AlignedPCM16TrackChunk(samples: [], validSampleCount: 0)
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

    return AlignedPCM16TrackChunk(samples: samples, validSampleCount: samples.count)
  }
}

struct AlignedPCM16TrackChunk {
  let samples: [Float]
  let validSampleCount: Int
}

extension Data {
  fileprivate func uint16LittleEndian(at offset: Int) -> UInt16? {
    guard offset >= 0, offset + 2 <= count else {
      return nil
    }
    return withUnsafeBytes { bytes in
      UInt16(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt16.self))
    }
  }

  fileprivate func uint32LittleEndian(at offset: Int) -> UInt32? {
    guard offset >= 0, offset + 4 <= count else {
      return nil
    }
    return withUnsafeBytes { bytes in
      UInt32(littleEndian: bytes.loadUnaligned(fromByteOffset: offset, as: UInt32.self))
    }
  }
}
