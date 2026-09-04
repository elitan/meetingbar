import Foundation

enum OnlineMeetingEndAction: Equatable, Sendable {
  case none
  case presentPrompt(applicationName: String, secondsRemaining: Int)
  case updatePrompt(applicationName: String, secondsRemaining: Int)
  case dismissPrompt
  case stopRecording(applicationName: String)
}

struct OnlineMeetingEndMonitor: Sendable {
  static let defaultInactivityDuration: Duration = .seconds(60)
  static let defaultPromptDuration: Duration = .seconds(30)

  private let inactivityDuration: Duration
  private let promptDuration: Duration
  private var isMonitoring = false
  private var hasObservedMeetingActivity = false
  private var applicationName = "Online meeting"
  private var inactivityStartedAt: ContinuousClock.Instant?
  private var promptDeadline: ContinuousClock.Instant?
  private var lastReportedSeconds: Int?

  init(
    inactivityDuration: Duration = Self.defaultInactivityDuration,
    promptDuration: Duration = Self.defaultPromptDuration
  ) {
    self.inactivityDuration = inactivityDuration
    self.promptDuration = promptDuration
  }

  mutating func start(activeApplications: Set<OnlineMeetingApplication>) {
    isMonitoring = true
    hasObservedMeetingActivity = !activeApplications.isEmpty
    if !activeApplications.isEmpty {
      applicationName = Self.displayName(for: activeApplications)
    }
    inactivityStartedAt = nil
    promptDeadline = nil
    lastReportedSeconds = nil
  }

  mutating func observe(
    activeApplications: Set<OnlineMeetingApplication>,
    at now: ContinuousClock.Instant
  ) -> OnlineMeetingEndAction {
    guard isMonitoring else {
      return .none
    }

    if !activeApplications.isEmpty {
      let hadPrompt = promptDeadline != nil
      hasObservedMeetingActivity = true
      applicationName = Self.displayName(for: activeApplications)
      inactivityStartedAt = nil
      promptDeadline = nil
      lastReportedSeconds = nil
      return hadPrompt ? .dismissPrompt : .none
    }

    guard hasObservedMeetingActivity, inactivityStartedAt == nil else {
      return .none
    }
    inactivityStartedAt = now
    return .none
  }

  mutating func tick(at now: ContinuousClock.Instant) -> OnlineMeetingEndAction {
    guard isMonitoring else {
      return .none
    }

    if let promptDeadline {
      if now >= promptDeadline {
        isMonitoring = false
        self.promptDeadline = nil
        lastReportedSeconds = nil
        return .stopRecording(applicationName: applicationName)
      }

      let secondsRemaining = Self.secondsRemaining(from: now, until: promptDeadline)
      guard secondsRemaining != lastReportedSeconds else {
        return .none
      }
      lastReportedSeconds = secondsRemaining
      return .updatePrompt(
        applicationName: applicationName,
        secondsRemaining: secondsRemaining
      )
    }

    guard let inactivityStartedAt, now - inactivityStartedAt >= inactivityDuration else {
      return .none
    }
    let deadline = now + promptDuration
    promptDeadline = deadline
    let secondsRemaining = Self.secondsRemaining(from: now, until: deadline)
    lastReportedSeconds = secondsRemaining
    return .presentPrompt(
      applicationName: applicationName,
      secondsRemaining: secondsRemaining
    )
  }

  mutating func keepRecording() -> OnlineMeetingEndAction {
    guard isMonitoring else {
      return .none
    }
    let hadPrompt = promptDeadline != nil
    hasObservedMeetingActivity = false
    inactivityStartedAt = nil
    promptDeadline = nil
    lastReportedSeconds = nil
    return hadPrompt ? .dismissPrompt : .none
  }

  mutating func stop() -> OnlineMeetingEndAction {
    let hadPrompt = promptDeadline != nil
    isMonitoring = false
    hasObservedMeetingActivity = false
    inactivityStartedAt = nil
    promptDeadline = nil
    lastReportedSeconds = nil
    return hadPrompt ? .dismissPrompt : .none
  }

  private static func displayName(
    for applications: Set<OnlineMeetingApplication>
  ) -> String {
    applications.map(\.name).sorted().joined(separator: " and ")
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
