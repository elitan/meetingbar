import Foundation
import Observation

@MainActor
@Observable
final class RecordingSafetyPreferenceStore {
  private(set) var isEnabled: Bool

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let enabledKey = "RecordingSilenceAutoStopEnabled"

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    if userDefaults.object(forKey: enabledKey) == nil {
      isEnabled = true
    } else {
      isEnabled = userDefaults.bool(forKey: enabledKey)
    }
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    userDefaults.set(enabled, forKey: enabledKey)
  }
}

enum RecordingSilenceAction: Equatable, Sendable {
  case none
  case presentPrompt(secondsRemaining: Int)
  case updatePrompt(secondsRemaining: Int)
  case dismissPrompt
  case stopRecording
}

struct RecordingSilenceMonitor: Sendable {
  static let defaultSilenceDuration: Duration = .seconds(300)
  static let defaultPromptDuration: Duration = .seconds(30)

  // A conservative -50 dBFS RMS threshold avoids treating ordinary microphone noise as speech.
  static let defaultActivityThreshold: Float = 0.003_162_277_6

  private let silenceDuration: Duration
  private let promptDuration: Duration
  private let activityThreshold: Float
  private var isMonitoring = false
  private var lastActivityAt: ContinuousClock.Instant?
  private var promptDeadline: ContinuousClock.Instant?
  private var lastReportedSeconds: Int?

  init(
    silenceDuration: Duration = Self.defaultSilenceDuration,
    promptDuration: Duration = Self.defaultPromptDuration,
    activityThreshold: Float = Self.defaultActivityThreshold
  ) {
    self.silenceDuration = silenceDuration
    self.promptDuration = promptDuration
    self.activityThreshold = activityThreshold
  }

  mutating func start(at now: ContinuousClock.Instant) {
    isMonitoring = true
    lastActivityAt = now
    promptDeadline = nil
    lastReportedSeconds = nil
  }

  mutating func observe(
    levels: CaptureLevels,
    at now: ContinuousClock.Instant
  ) -> RecordingSilenceAction {
    guard isMonitoring, levels.maximum >= activityThreshold else {
      return .none
    }

    lastActivityAt = now
    guard promptDeadline != nil else {
      return .none
    }
    promptDeadline = nil
    lastReportedSeconds = nil
    return .dismissPrompt
  }

  mutating func tick(at now: ContinuousClock.Instant) -> RecordingSilenceAction {
    guard isMonitoring else {
      return .none
    }

    if let promptDeadline {
      if now >= promptDeadline {
        isMonitoring = false
        self.promptDeadline = nil
        lastReportedSeconds = nil
        return .stopRecording
      }

      let secondsRemaining = Self.secondsRemaining(from: now, until: promptDeadline)
      guard secondsRemaining != lastReportedSeconds else {
        return .none
      }
      lastReportedSeconds = secondsRemaining
      return .updatePrompt(secondsRemaining: secondsRemaining)
    }

    guard let lastActivityAt, now - lastActivityAt >= silenceDuration else {
      return .none
    }
    let deadline = now + promptDuration
    promptDeadline = deadline
    let secondsRemaining = Self.secondsRemaining(from: now, until: deadline)
    lastReportedSeconds = secondsRemaining
    return .presentPrompt(secondsRemaining: secondsRemaining)
  }

  mutating func keepRecording(at now: ContinuousClock.Instant) -> RecordingSilenceAction {
    guard isMonitoring else {
      return .none
    }
    lastActivityAt = now
    guard promptDeadline != nil else {
      return .none
    }
    promptDeadline = nil
    lastReportedSeconds = nil
    return .dismissPrompt
  }

  mutating func stop() -> RecordingSilenceAction {
    let hadPrompt = promptDeadline != nil
    isMonitoring = false
    lastActivityAt = nil
    promptDeadline = nil
    lastReportedSeconds = nil
    return hadPrompt ? .dismissPrompt : .none
  }

  private static func secondsRemaining(
    from now: ContinuousClock.Instant,
    until deadline: ContinuousClock.Instant
  ) -> Int {
    let components = now.duration(to: deadline).components
    let seconds = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return max(0, Int(ceil(seconds)))
  }
}

extension CaptureLevels {
  var maximum: Float {
    max(microphone, system)
  }
}
