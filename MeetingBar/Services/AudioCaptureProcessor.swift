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
}

final class AudioCaptureProcessor {
  private let writer: PCM16WAVWriter
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
    writer: PCM16WAVWriter,
    warningHandler: @escaping @MainActor @Sendable (String) -> Void,
    levelsHandler: @escaping @MainActor @Sendable (CaptureLevels) -> Void
  ) {
    self.writer = writer
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
        let samples = try systemConverter.convert(sampleBuffer)
        levels.system = peakLevel(samples)
        mixer.appendSystem(samples)
        drainSystemIfMicrophoneUnavailable()
      case .microphone:
        let samples = try microphoneConverter.convert(sampleBuffer)
        lastMicrophoneSampleAt = .now
        levels.microphone = peakLevel(samples)
        try writer.append(floatSamples: mixer.mixMicrophone(samples))
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
    try writer.append(floatSamples: mixer.drainSystemTail())
    let audioURL = try writer.finish()
    let duration = Double(writer.sampleCount) / Double(PCM16WAVWriter.sampleRate)
    let result = FinalizedCapture(audioURL: audioURL, durationSeconds: duration)
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
      try writer.append(floatSamples: mixer.drainSystemTail())
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
