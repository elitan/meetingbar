import Foundation

enum CaptureState: Equatable, Sendable {
  case idle
  case starting
  case recording(startedAt: Date)
  case stopping

  var isRecording: Bool {
    if case .recording = self {
      true
    } else {
      false
    }
  }

  var isBusy: Bool {
    self != .idle
  }
}

enum CaptureAction: Equatable, Sendable {
  case requestStart
  case didStart(Date)
  case startFailed
  case requestStop
  case didStop
}

enum CaptureTransitionError: LocalizedError, Equatable {
  case invalidTransition(from: CaptureState, action: CaptureAction)

  var errorDescription: String? {
    "The recording command arrived while MeetingBar was already changing state."
  }
}

struct CaptureStateMachine: Sendable {
  private(set) var state: CaptureState = .idle

  mutating func apply(_ action: CaptureAction) throws {
    switch (state, action) {
    case (.idle, .requestStart):
      state = .starting
    case (.starting, .didStart(let startedAt)):
      state = .recording(startedAt: startedAt)
    case (.starting, .startFailed):
      state = .idle
    case (.recording, .requestStop):
      state = .stopping
    case (.stopping, .didStop):
      state = .idle
    default:
      throw CaptureTransitionError.invalidTransition(from: state, action: action)
    }
  }
}
