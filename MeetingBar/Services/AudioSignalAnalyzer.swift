import Foundation

struct AudioActivityTimeline: Sendable {
  let frameDurationSeconds: Double
  let frameLevelsDBFS: [Double]
  let activityThresholdDBFS: Double

  var durationSeconds: Double {
    Double(frameLevelsDBFS.count) * frameDurationSeconds
  }

  func hasSpeechActivity(from startSeconds: Double, to endSeconds: Double) -> Bool {
    guard !frameLevelsDBFS.isEmpty, endSeconds > startSeconds else {
      return true
    }
    let lowerIndex = max(0, Int(floor(startSeconds / frameDurationSeconds)))
    let upperIndex = min(
      frameLevelsDBFS.count,
      Int(ceil(endSeconds / frameDurationSeconds))
    )
    guard lowerIndex < upperIndex else {
      return true
    }
    let levels = frameLevelsDBFS[lowerIndex..<upperIndex]
    let activeCount = levels.count(where: { $0 >= activityThresholdDBFS })
    let minimumActiveFrames = max(1, Int(ceil(Double(levels.count) * 0.08)))
    return activeCount >= minimumActiveFrames
  }
}

struct AudioSignalAnalysis: Sendable {
  let summary: AudioSignalSummary
  let activity: AudioActivityTimeline
}

struct AudioSignalAnalyzer: Sendable {
  private static let frameLength = Int(PCM16WAVWriter.sampleRate / 10)

  private var sampleCount = 0
  private var sumOfSquares = 0.0
  private var peak: Float = 0
  private var frameSampleCount = 0
  private var frameSumOfSquares = 0.0
  private var frameLevelsDBFS: [Double] = []

  mutating func append(_ samples: [Float]) {
    for sample in samples {
      let absolute = abs(sample)
      peak = max(peak, absolute)
      let square = Double(sample) * Double(sample)
      sumOfSquares += square
      sampleCount += 1
      frameSumOfSquares += square
      frameSampleCount += 1

      if frameSampleCount == Self.frameLength {
        appendCompletedFrame()
      }
    }
  }

  mutating func summary() -> AudioSignalSummary {
    analysis().summary
  }

  mutating func analysis() -> AudioSignalAnalysis {
    if frameSampleCount > 0 {
      appendCompletedFrame()
    }

    let duration = Double(sampleCount) / Double(PCM16WAVWriter.sampleRate)
    let overallRMS = sampleCount > 0 ? sqrt(sumOfSquares / Double(sampleCount)) : 0
    let sortedLevels = frameLevelsDBFS.sorted()
    let noiseFloor = percentile(sortedLevels, fraction: 0.2)
    let highLevel = percentile(sortedLevels, fraction: 0.95)
    let activityThreshold =
      highLevel < -90
      ? -55
      : min(highLevel - 6, max(-55, noiseFloor + 10))
    let activeLevels = sortedLevels.filter { $0 >= activityThreshold }
    let speechLevel =
      activeLevels.isEmpty
      ? percentile(sortedLevels, fraction: 0.95)
      : percentile(activeLevels, fraction: 0.5)
    let activeFraction =
      sortedLevels.isEmpty
      ? 0
      : Double(activeLevels.count) / Double(sortedLevels.count)

    let summary = AudioSignalSummary(
      durationSeconds: duration,
      peakDBFS: decibels(amplitude: Double(peak)),
      overallRMSDBFS: decibels(amplitude: overallRMS),
      speechRMSDBFS: speechLevel,
      activeFrameFraction: activeFraction
    )
    return AudioSignalAnalysis(
      summary: summary,
      activity: AudioActivityTimeline(
        frameDurationSeconds: Double(Self.frameLength) / Double(PCM16WAVWriter.sampleRate),
        frameLevelsDBFS: frameLevelsDBFS,
        activityThresholdDBFS: activityThreshold
      )
    )
  }

  private mutating func appendCompletedFrame() {
    guard frameSampleCount > 0 else {
      return
    }
    let rms = sqrt(frameSumOfSquares / Double(frameSampleCount))
    frameLevelsDBFS.append(decibels(amplitude: rms))
    frameSampleCount = 0
    frameSumOfSquares = 0
  }

  private func percentile(_ values: [Double], fraction: Double) -> Double {
    guard !values.isEmpty else {
      return -120
    }
    let index = Int((Double(values.count - 1) * fraction).rounded())
    return values[min(values.count - 1, max(0, index))]
  }

  private func decibels(amplitude: Double) -> Double {
    guard amplitude > 0 else {
      return -120
    }
    return max(-120, 20 * log10(amplitude))
  }
}

final class TimestampedPCM16WAVWriter {
  private static let maximumInsertedGapSeconds = 5.0

  let kind: CaptureSourceKind
  private let writer: PCM16WAVWriter
  private var analyzer = AudioSignalAnalyzer()
  private var nextPresentationTimeSeconds: Double?
  private(set) var firstPresentationTimeSeconds: Double?

  init(kind: CaptureSourceKind, writer: PCM16WAVWriter) {
    self.kind = kind
    self.writer = writer
  }

  func append(samples: [Float], presentationTimeSeconds: Double?) throws {
    guard !samples.isEmpty else {
      return
    }

    var samplesToWrite = samples
    if let presentationTimeSeconds, presentationTimeSeconds.isFinite {
      if firstPresentationTimeSeconds == nil {
        firstPresentationTimeSeconds = presentationTimeSeconds
      }

      if let expectedTime = nextPresentationTimeSeconds {
        let deltaSeconds = presentationTimeSeconds - expectedTime
        if deltaSeconds > 0 {
          let insertedSeconds = min(deltaSeconds, Self.maximumInsertedGapSeconds)
          let silenceCount = Int(
            (insertedSeconds * Double(PCM16WAVWriter.sampleRate)).rounded()
          )
          try appendSilence(sampleCount: silenceCount)
        } else if deltaSeconds < 0 {
          let overlapCount = Int(
            (-deltaSeconds * Double(PCM16WAVWriter.sampleRate)).rounded()
          )
          if overlapCount < samplesToWrite.count {
            samplesToWrite.removeFirst(overlapCount)
          } else if -deltaSeconds <= Self.maximumInsertedGapSeconds {
            samplesToWrite.removeAll(keepingCapacity: false)
          }
        }
      }

      nextPresentationTimeSeconds =
        presentationTimeSeconds
        + Double(samples.count) / Double(PCM16WAVWriter.sampleRate)
    }

    guard !samplesToWrite.isEmpty else {
      return
    }
    try writer.append(floatSamples: samplesToWrite)
    analyzer.append(samplesToWrite)
  }

  func finish() throws -> FinalizedCaptureSource {
    let url = try writer.finish()
    let signal = analyzer.summary()
    return FinalizedCaptureSource(
      kind: kind,
      audioURL: url,
      firstPresentationTimeSeconds: firstPresentationTimeSeconds,
      durationSeconds: Double(writer.sampleCount) / Double(PCM16WAVWriter.sampleRate),
      signal: signal
    )
  }

  private func appendSilence(sampleCount: Int) throws {
    guard sampleCount > 0 else {
      return
    }
    let chunkSize = Int(PCM16WAVWriter.sampleRate)
    var remaining = sampleCount
    while remaining > 0 {
      let count = min(remaining, chunkSize)
      let silence = [Float](repeating: 0, count: count)
      try writer.append(floatSamples: silence)
      analyzer.append(silence)
      remaining -= count
    }
  }
}
