import XCTest

@testable import MeetingBar

@MainActor
final class OnlineMeetingReminderTests: XCTestCase {
  func testRecognizesNativeZoomAndTeamsProcesses() {
    XCTAssertEqual(
      application(bundleID: "us.zoom.xos")?.name,
      "Zoom"
    )
    XCTAssertEqual(
      application(bundleID: "us.zoom.CptHost.helper")?.name,
      "Zoom"
    )
    XCTAssertEqual(
      application(bundleID: "com.microsoft.teams2")?.name,
      "Microsoft Teams"
    )
    XCTAssertEqual(
      application(bundleID: "com.microsoft.teams2.helper")?.name,
      "Microsoft Teams"
    )
  }

  func testRecognizesBrowserHelpersOnlyWhenEnabled() {
    XCTAssertEqual(
      application(bundleID: "com.brave.Browser.helper")?.name,
      "Brave"
    )
    XCTAssertNil(
      OnlineMeetingApplicationCatalog.application(
        forBundleID: "com.brave.Browser.helper",
        includesBrowsers: false
      )
    )
  }

  func testRejectsUnrelatedMicrophoneProcesses() {
    XCTAssertNil(application(bundleID: "com.apple.VoiceMemos"))
    XCTAssertNil(application(bundleID: "me.eliasson.meetingbar"))
  }

  func testNativeApplicationSuppressesConcurrentBrowserMatch() {
    let applications = OnlineMeetingApplicationCatalog.applications(
      for: [
        ActiveAudioInputProcess(processID: 1, bundleID: "us.zoom.xos"),
        ActiveAudioInputProcess(processID: 2, bundleID: "com.brave.Browser.helper"),
      ],
      includesBrowsers: true
    )

    XCTAssertEqual(applications.map(\.name), ["Zoom"])
  }

  func testPromptsAfterDefaultOnePointFiveSecondActivationDelayOnlyOnce() throws {
    var stateMachine = OnlineMeetingReminderStateMachine(
      resetDelay: 30
    )
    let zoom = try XCTUnwrap(application(bundleID: "us.zoom.xos"))
    let start = Date(timeIntervalSince1970: 1_000)

    XCTAssertTrue(
      stateMachine.update(activeApplications: [zoom], now: start).isEmpty
    )
    XCTAssertTrue(
      stateMachine.update(
        activeApplications: [zoom],
        now: start.addingTimeInterval(1.4)
      ).isEmpty
    )
    XCTAssertEqual(
      stateMachine.update(
        activeApplications: [zoom],
        now: start.addingTimeInterval(1.5)
      ),
      [zoom]
    )
    XCTAssertTrue(
      stateMachine.update(
        activeApplications: [zoom],
        now: start.addingTimeInterval(20)
      ).isEmpty
    )
  }

  func testBriefMicrophoneGapDoesNotRepeatPrompt() throws {
    var stateMachine = OnlineMeetingReminderStateMachine(
      activationDelay: 1.5,
      resetDelay: 30
    )
    let teams = try XCTUnwrap(application(bundleID: "com.microsoft.teams2"))
    let start = Date(timeIntervalSince1970: 2_000)

    _ = stateMachine.update(activeApplications: [teams], now: start)
    XCTAssertEqual(
      stateMachine.update(
        activeApplications: [teams],
        now: start.addingTimeInterval(1.5)
      ),
      [teams]
    )
    XCTAssertTrue(
      stateMachine.update(
        activeApplications: [],
        now: start.addingTimeInterval(15)
      ).isEmpty
    )
    XCTAssertTrue(
      stateMachine.update(
        activeApplications: [teams],
        now: start.addingTimeInterval(20)
      ).isEmpty
    )
  }

  func testNewSessionCanPromptAfterResetDelay() throws {
    var stateMachine = OnlineMeetingReminderStateMachine(
      activationDelay: 1.5,
      resetDelay: 30
    )
    let zoom = try XCTUnwrap(application(bundleID: "us.zoom.xos"))
    let start = Date(timeIntervalSince1970: 3_000)

    _ = stateMachine.update(activeApplications: [zoom], now: start)
    _ = stateMachine.update(activeApplications: [zoom], now: start.addingTimeInterval(1.5))
    _ = stateMachine.update(activeApplications: [], now: start.addingTimeInterval(31.5))
    XCTAssertTrue(
      stateMachine.update(
        activeApplications: [zoom],
        now: start.addingTimeInterval(32)
      ).isEmpty
    )
    XCTAssertEqual(
      stateMachine.update(
        activeApplications: [zoom],
        now: start.addingTimeInterval(33.5)
      ),
      [zoom]
    )
  }

  func testMeetingEndPromptsAfterOneMinuteAndStopsAfterCountdown() throws {
    var monitor = OnlineMeetingEndMonitor()
    let zoom = try XCTUnwrap(application(bundleID: "us.zoom.xos"))
    let start = ContinuousClock.now
    monitor.start(activeApplications: [zoom])

    XCTAssertEqual(
      monitor.observe(activeApplications: [], at: start + .seconds(10)),
      .none
    )
    XCTAssertEqual(monitor.tick(at: start + .seconds(69)), .none)
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(70)),
      .presentPrompt(applicationName: "Zoom", secondsRemaining: 30)
    )
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(71)),
      .updatePrompt(applicationName: "Zoom", secondsRemaining: 29)
    )
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(100)),
      .stopRecording(applicationName: "Zoom")
    )
  }

  func testMeetingResumingDismissesCountdownAndStartsANewEndWindow() throws {
    var monitor = OnlineMeetingEndMonitor()
    let teams = try XCTUnwrap(application(bundleID: "com.microsoft.teams2"))
    let start = ContinuousClock.now
    monitor.start(activeApplications: [teams])
    _ = monitor.observe(activeApplications: [], at: start)
    _ = monitor.tick(at: start + .seconds(60))

    XCTAssertEqual(
      monitor.observe(activeApplications: [teams], at: start + .seconds(65)),
      .dismissPrompt
    )
    _ = monitor.observe(activeApplications: [], at: start + .seconds(70))
    XCTAssertEqual(monitor.tick(at: start + .seconds(129)), .none)
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(130)),
      .presentPrompt(applicationName: "Microsoft Teams", secondsRemaining: 30)
    )
  }

  func testKeepRecordingSuppressesRepeatUntilAnotherMeetingSession() throws {
    var monitor = OnlineMeetingEndMonitor()
    let zoom = try XCTUnwrap(application(bundleID: "us.zoom.xos"))
    let start = ContinuousClock.now
    monitor.start(activeApplications: [zoom])
    _ = monitor.observe(activeApplications: [], at: start)
    _ = monitor.tick(at: start + .seconds(60))

    XCTAssertEqual(monitor.keepRecording(), .dismissPrompt)
    XCTAssertEqual(monitor.tick(at: start + .seconds(600)), .none)
    XCTAssertEqual(
      monitor.observe(activeApplications: [], at: start + .seconds(601)),
      .none
    )

    _ = monitor.observe(activeApplications: [zoom], at: start + .seconds(602))
    _ = monitor.observe(activeApplications: [], at: start + .seconds(603))
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(663)),
      .presentPrompt(applicationName: "Zoom", secondsRemaining: 30)
    )
  }

  func testManualRecordingWithoutMeetingActivityDoesNotArmCallEndedPrompt() {
    var monitor = OnlineMeetingEndMonitor()
    let start = ContinuousClock.now
    monitor.start(activeApplications: [])

    XCTAssertEqual(
      monitor.observe(activeApplications: [], at: start + .seconds(10)),
      .none
    )
    XCTAssertEqual(monitor.tick(at: start + .seconds(600)), .none)
  }

  func testMeetingEndedBannerUsesApplicationNameAndCountdownGrammar() {
    XCTAssertTrue(
      OnlineMeetingEndedBannerText.message(
        applicationName: "Zoom",
        secondsRemaining: 30
      ).contains("Zoom")
    )
    XCTAssertTrue(
      OnlineMeetingEndedBannerText.message(
        applicationName: "Zoom",
        secondsRemaining: 1
      ).hasSuffix("1 second.")
    )
  }

  func testPreferencesDefaultOnAndPersist() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = MeetingReminderPreferenceStore(userDefaults: defaults)
    XCTAssertTrue(initial.isEnabled)
    XCTAssertTrue(initial.includesBrowsers)

    initial.setEnabled(false)
    initial.setIncludesBrowsers(false)
    let restored = MeetingReminderPreferenceStore(userDefaults: defaults)
    XCTAssertFalse(restored.isEnabled)
    XCTAssertFalse(restored.includesBrowsers)
  }

  func testCoreAudioProcessSnapshotCanBeRead() throws {
    _ = try CoreAudioInputProcessProvider().activeInputProcesses()
  }

  func testInformationalBannerPositionUsesTopTrailingVisibleFrame() {
    let origin = AppBannerPosition.origin(
      panelSize: CGSize(width: 380, height: 148),
      visibleFrame: CGRect(x: 1_728, y: 23, width: 1_920, height: 1_057),
      placement: .topTrailing
    )

    XCTAssertEqual(origin.x, 3_252)
    XCTAssertEqual(origin.y, 916)
  }

  func testMeetingReminderPositionUsesCenterOfVisibleFrame() {
    let origin = AppBannerPosition.origin(
      panelSize: CGSize(width: 380, height: 148),
      visibleFrame: CGRect(x: 1_728, y: 23, width: 1_920, height: 1_057),
      placement: .center
    )

    XCTAssertEqual(origin.x, 2_498)
    XCTAssertEqual(origin.y, 477.5)
  }

  private func application(bundleID: String) -> OnlineMeetingApplication? {
    OnlineMeetingApplicationCatalog.application(
      forBundleID: bundleID,
      includesBrowsers: true
    )
  }

  private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "MeetingBarTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Could not create isolated user defaults")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}
