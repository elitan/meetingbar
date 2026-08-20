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

  func testBannerPositionUsesVisibleFrameOnCurrentDisplay() {
    let origin = AppBannerPosition.origin(
      panelSize: CGSize(width: 380, height: 148),
      visibleFrame: CGRect(x: 1_728, y: 23, width: 1_920, height: 1_057)
    )

    XCTAssertEqual(origin.x, 3_252)
    XCTAssertEqual(origin.y, 916)
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
