import CoreMedia
import Foundation
import ScreenCaptureKit

struct CaptureLevels: Sendable {
  var microphone: Float = 0
  var system: Float = 0
}

struct FinalizedCapture: Sendable {
  let audioURL: URL
  let durationSeconds: Double
  let sources: [FinalizedCaptureSource]
}

final class AudioCaptureProcessor {
  private let mixedWriter: PCM16WAVWriter
  private var microphoneWriter: TimestampedPCM16WAVWriter?
  private var systemWriter: TimestampedPCM16WAVWriter?
  private let microphoneConverter = AudioSampleConverter()
  private let systemConverter = AudioSampleConverter()
  private let warningHandler: @MainActor @Sendable (String) -> Void
  private let levelsHandler: @MainActor @Sendable (CaptureLevels) -> Void
  private var mixer = AudioMixer()
  private var levels = CaptureLevels()
  private var warnedKeys: Set<String> = []
  private var firstSystemSampleAt: ContinuousClock.Instant?
  private var lastMicrophoneSampleAt: ContinuousClock.Instant?
  private var isFinished = false
  private var finalizedCapture: FinalizedCapture?

  init(
    mixedWriter: PCM16WAVWriter,
    microphoneWriter: TimestampedPCM16WAVWriter,
    systemWriter: TimestampedPCM16WAVWriter,
    warningHandler: @escaping @MainActor @Sendable (String) -> Void,
    levelsHandler: @escaping @MainActor @Sendable (CaptureLevels) -> Void
  ) {
    self.mixedWriter = mixedWriter
    self.microphoneWriter = microphoneWriter
    self.systemWriter = systemWriter
    self.warningHandler = warningHandler
    self.levelsHandler = levelsHandler
  }

  func process(_ sampleBuffer: CMSampleBuffer, type: SCStreamOutputType) {
    guard !isFinished else {
      return
    }

    do {
      switch type {
      case .audio:
        let converted = try systemConverter.convert(sampleBuffer)
        appendSource(converted, to: &systemWriter, kind: .system)
        levels.system = peakLevel(converted.samples)
        mixer.appendSystem(converted.samples)
        drainSystemIfMicrophoneUnavailable()
      case .microphone:
        let converted = try microphoneConverter.convert(sampleBuffer)
        appendSource(converted, to: &microphoneWriter, kind: .microphone)
        lastMicrophoneSampleAt = .now
        levels.microphone = peakLevel(converted.samples)
        try mixedWriter.append(floatSamples: mixer.mixMicrophone(converted.samples))
      case .screen:
        return
      @unknown default:
        return
      }
      let currentLevels = levels
      let handler = levelsHandler
      Task { @MainActor in
        handler(currentLevels)
      }
    } catch {
      warnOnce(
        key: "conversion-\(type.rawValue)",
        message: "An audio input stopped producing usable samples: \(error.localizedDescription)"
      )
    }
  }

  func finish() throws -> FinalizedCapture {
    if let finalizedCapture {
      return finalizedCapture
    }
    isFinished = true
    try mixedWriter.append(floatSamples: mixer.drainSystemTail())
    let audioURL = try mixedWriter.finish()
    var sources: [FinalizedCaptureSource] = []
    finishSource(&microphoneWriter, into: &sources)
    finishSource(&systemWriter, into: &sources)

    let mixedDuration = Double(mixedWriter.sampleCount) / Double(PCM16WAVWriter.sampleRate)
    let firstPresentationTime = sources.compactMap(\.firstPresentationTimeSeconds).min()
    let sourceDuration =
      sources.map { source in
        let offset =
          source.firstPresentationTimeSeconds.map { first in
            max(0, first - (firstPresentationTime ?? first))
          } ?? 0
        return offset + source.durationSeconds
      }.max() ?? 0
    let result = FinalizedCapture(
      audioURL: audioURL,
      durationSeconds: max(mixedDuration, sourceDuration),
      sources: sources
    )
    finalizedCapture = result
    return result
  }

  private func drainSystemIfMicrophoneUnavailable() {
    let now = ContinuousClock.now
    if firstSystemSampleAt == nil {
      firstSystemSampleAt = now
    }

    let reference = lastMicrophoneSampleAt ?? firstSystemSampleAt
    guard let reference, now - reference >= .seconds(1) else {
      return
    }

    do {
      try mixedWriter.append(floatSamples: mixer.drainSystemTail())
      warnOnce(
        key: "microphone-missing",
        message: "Microphone samples stopped arriving. MeetingBar continued with system audio."
      )
    } catch {
      warnOnce(key: "writer", message: "MeetingBar could not write an audio buffer.")
    }
  }

  private func peakLevel(_ samples: [Float]) -> Float {
    samples.reduce(0) { current, sample in
      max(current, abs(sample))
    }
  }

  private func appendSource(
    _ converted: ConvertedAudioBuffer,
    to writer: inout TimestampedPCM16WAVWriter?,
    kind: CaptureSourceKind
  ) {
    guard let activeWriter = writer else {
      return
    }
    do {
      try activeWriter.append(
        samples: converted.samples,
        presentationTimeSeconds: converted.presentationTimeSeconds
      )
    } catch {
      writer = nil
      warnOnce(
        key: "source-writer-\(kind.rawValue)",
        message:
          "MeetingBar could not keep the separate \(kind.rawValue) track. The combined recording will continue."
      )
    }
  }

  private func finishSource(
    _ writer: inout TimestampedPCM16WAVWriter?,
    into sources: inout [FinalizedCaptureSource]
  ) {
    guard let activeWriter = writer else {
      return
    }
    do {
      let source = try activeWriter.finish()
      if source.durationSeconds > 0 {
        sources.append(source)
      }
    } catch {
      warnOnce(
        key: "source-finalize-\(activeWriter.kind.rawValue)",
        message:
          "MeetingBar could not finalize the separate \(activeWriter.kind.rawValue) track. Transcription will use the combined recording."
      )
    }
    writer = nil
  }

  private func warnOnce(key: String, message: String) {
    guard warnedKeys.insert(key).inserted else {
      return
    }
    let handler = warningHandler
    Task { @MainActor in
      handler(message)
    }
  }
}
