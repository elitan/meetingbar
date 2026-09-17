import Foundation

struct RecordingPromptCountdown: Sendable {
  enum Action: Equatable, Sendable {
    case startRecording
    case stopRecording

    var buttonTitle: String {
      switch self {
      case .startRecording: "Start Now"
      case .stopRecording: "Stop Now"
      }
    }
  }

  static let startDurationSeconds = 15

  let action: Action
  let totalSeconds: Int
  let deadline: ContinuousClock.Instant

  init(
    action: Action,
    totalSeconds: Int,
    secondsRemaining: Int? = nil,
    now: ContinuousClock.Instant = .now
  ) {
    self.action = action
    self.totalSeconds = max(1, totalSeconds)
    deadline = now + .seconds(max(0, secondsRemaining ?? totalSeconds))
  }

  func display(at now: ContinuousClock.Instant) -> RecordingPromptCountdownDisplay {
    let components = now.duration(to: deadline).components
    let remaining = Double(components.seconds) + Double(components.attoseconds) / 1e18
    return RecordingPromptCountdownDisplay(
      action: action,
      secondsRemaining: max(0, Int(ceil(remaining))),
      fractionRemaining: min(1, max(0, remaining / Double(totalSeconds)))
    )
  }
}

struct RecordingPromptCountdownDisplay: Equatable {
  let action: RecordingPromptCountdown.Action
  let secondsRemaining: Int
  let fractionRemaining: Double

  var message: String {
    let verb = action == .startRecording ? "starts" : "stops"
    let unit = secondsRemaining == 1 ? "second" : "seconds"
    return "Recording \(verb) automatically in \(secondsRemaining) \(unit)."
  }
}
