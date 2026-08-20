import AppKit
import CoreAudio
import Foundation

struct ActiveAudioInputProcess: Hashable, Sendable {
  let processID: pid_t
  let bundleID: String
}

protocol AudioInputProcessProviding: Sendable {
  func activeInputProcesses() throws -> [ActiveAudioInputProcess]
}

struct CoreAudioInputProcessProvider: AudioInputProcessProviding {
  func activeInputProcesses() throws -> [ActiveAudioInputProcess] {
    let processes = try AudioHardwareSystem.shared.processes
    var activeProcesses: [ActiveAudioInputProcess] = []

    for process in processes {
      do {
        guard try process.isRunningInput else {
          continue
        }
        let processID = try process.pid
        let bundleID =
          try process.bundleID
          ?? NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
        guard let bundleID, !bundleID.isEmpty else {
          continue
        }
        activeProcesses.append(
          ActiveAudioInputProcess(processID: processID, bundleID: bundleID)
        )
      } catch {
        // Audio clients can disappear while the HAL process list is being read.
        continue
      }
    }

    return activeProcesses
  }
}

struct OnlineMeetingApplication: Hashable, Identifiable, Sendable {
  let id: String
  let name: String
  let isBrowser: Bool
}

enum OnlineMeetingApplicationCatalog {
  static func applications(
    for processes: [ActiveAudioInputProcess],
    includesBrowsers: Bool
  ) -> Set<OnlineMeetingApplication> {
    let applications = Set(
      processes.compactMap { process in
        application(forBundleID: process.bundleID, includesBrowsers: includesBrowsers)
      }
    )
    let nativeApplications = applications.filter { !$0.isBrowser }
    return nativeApplications.isEmpty ? applications : Set(nativeApplications)
  }

  static func application(
    forBundleID bundleID: String,
    includesBrowsers: Bool
  ) -> OnlineMeetingApplication? {
    let normalizedBundleID = bundleID.lowercased()

    if matches(normalizedBundleID, roots: ["us.zoom.xos", "us.zoom.cpthost"]) {
      return OnlineMeetingApplication(id: "zoom", name: "Zoom", isBrowser: false)
    }

    if matches(normalizedBundleID, roots: ["com.microsoft.teams2", "com.microsoft.teams"]) {
      return OnlineMeetingApplication(
        id: "microsoft-teams",
        name: "Microsoft Teams",
        isBrowser: false
      )
    }

    guard includesBrowsers else {
      return nil
    }

    let browsers: [(root: String, id: String, name: String)] = [
      ("com.apple.safari", "safari", "Safari"),
      ("com.brave.browser", "brave", "Brave"),
      ("com.google.chrome", "chrome", "Google Chrome"),
      ("com.microsoft.edgemac", "edge", "Microsoft Edge"),
      ("org.mozilla.firefox", "firefox", "Firefox"),
      ("company.thebrowser.browser", "arc", "Arc"),
      ("com.vivaldi.vivaldi", "vivaldi", "Vivaldi"),
      ("com.operasoftware.opera", "opera", "Opera"),
    ]
    guard let browser = browsers.first(where: { matches(normalizedBundleID, roots: [$0.root]) })
    else {
      return nil
    }
    return OnlineMeetingApplication(id: browser.id, name: browser.name, isBrowser: true)
  }

  private static func matches(_ bundleID: String, roots: [String]) -> Bool {
    roots.contains { root in
      bundleID == root || bundleID.hasPrefix("\(root).")
    }
  }
}

struct OnlineMeetingReminderStateMachine {
  private struct Session: Sendable {
    let firstSeenAt: Date
    var lastSeenAt: Date
    var hasPrompted: Bool
  }

  private let activationDelay: TimeInterval
  private let resetDelay: TimeInterval
  private var sessions: [String: Session] = [:]

  init(activationDelay: TimeInterval = 1.5, resetDelay: TimeInterval = 30) {
    self.activationDelay = activationDelay
    self.resetDelay = resetDelay
  }

  mutating func update(
    activeApplications: Set<OnlineMeetingApplication>,
    now: Date
  ) -> [OnlineMeetingApplication] {
    var activeByID: [String: OnlineMeetingApplication] = [:]
    for application in activeApplications {
      activeByID[application.id] = application
    }

    let staleSessionIDs = sessions.compactMap { entry -> String? in
      let (id, session) = entry
      guard activeByID[id] == nil, now.timeIntervalSince(session.lastSeenAt) >= resetDelay else {
        return nil
      }
      return id
    }
    for id in staleSessionIDs {
      sessions.removeValue(forKey: id)
    }

    var applicationsToPrompt: [OnlineMeetingApplication] = []
    for application in activeByID.values.sorted(by: { $0.id < $1.id }) {
      var session =
        sessions[application.id]
        ?? Session(firstSeenAt: now, lastSeenAt: now, hasPrompted: false)
      session.lastSeenAt = now
      if !session.hasPrompted,
        now.timeIntervalSince(session.firstSeenAt) >= activationDelay
      {
        session.hasPrompted = true
        applicationsToPrompt.append(application)
      }
      sessions[application.id] = session
    }

    return applicationsToPrompt
  }

  mutating func reset() {
    sessions.removeAll()
  }
}

@MainActor
final class OnlineMeetingMonitor {
  var onMeetingDetected: ((OnlineMeetingApplication) -> Void)?
  var onErrorChanged: ((String?) -> Void)?

  private enum Snapshot: Sendable {
    case success([ActiveAudioInputProcess])
    case failure(String)
  }

  private let processProvider: AudioInputProcessProviding
  private let pollInterval: Duration
  private var includesBrowsers: Bool
  private var stateMachine: OnlineMeetingReminderStateMachine
  private var pollingTask: Task<Void, Never>?
  private var lastReportedFailure: String?

  init(
    processProvider: AudioInputProcessProviding = CoreAudioInputProcessProvider(),
    includesBrowsers: Bool,
    pollInterval: Duration = .milliseconds(500),
    stateMachine: OnlineMeetingReminderStateMachine = OnlineMeetingReminderStateMachine()
  ) {
    self.processProvider = processProvider
    self.includesBrowsers = includesBrowsers
    self.pollInterval = pollInterval
    self.stateMachine = stateMachine
  }

  func start() {
    guard pollingTask == nil else {
      return
    }
    stateMachine.reset()
    pollingTask = Task { [weak self] in
      while !Task.isCancelled {
        guard let self else {
          return
        }
        await self.poll()
        try? await Task.sleep(for: self.pollInterval)
      }
    }
  }

  func stop() {
    pollingTask?.cancel()
    pollingTask = nil
    stateMachine.reset()
    lastReportedFailure = nil
  }

  func setIncludesBrowsers(_ includesBrowsers: Bool) {
    guard self.includesBrowsers != includesBrowsers else {
      return
    }
    self.includesBrowsers = includesBrowsers
    stateMachine.reset()
  }

  private func poll() async {
    let processProvider = processProvider
    let snapshot = await Task.detached(priority: .utility) {
      do {
        return Snapshot.success(try processProvider.activeInputProcesses())
      } catch {
        return Snapshot.failure(error.localizedDescription)
      }
    }.value

    switch snapshot {
    case .success(let processes):
      if lastReportedFailure != nil {
        onErrorChanged?(nil)
      }
      lastReportedFailure = nil
      let applications = OnlineMeetingApplicationCatalog.applications(
        for: processes,
        includesBrowsers: includesBrowsers
      )
      for application in stateMachine.update(activeApplications: applications, now: .now) {
        onMeetingDetected?(application)
      }
    case .failure(let message):
      guard message != lastReportedFailure else {
        return
      }
      lastReportedFailure = message
      onErrorChanged?(message)
    }
  }
}
