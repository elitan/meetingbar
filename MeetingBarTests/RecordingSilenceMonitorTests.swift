import XCTest

@testable import MeetingBar

@MainActor
final class RecordingSilenceMonitorTests: XCTestCase {
  func testPromptsAfterFiveMinutesAndStopsAfterCountdown() {
    var monitor = RecordingSilenceMonitor()
    let start = ContinuousClock.now
    monitor.start(at: start)

    XCTAssertEqual(monitor.tick(at: start + .seconds(299)), .none)
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(300)),
      .presentPrompt(secondsRemaining: 30)
    )
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(301)),
      .updatePrompt(secondsRemaining: 29)
    )
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(329)),
      .updatePrompt(secondsRemaining: 1)
    )
    XCTAssertEqual(monitor.tick(at: start + .seconds(330)), .stopRecording)
    XCTAssertEqual(monitor.tick(at: start + .seconds(331)), .none)
  }

  func testEitherAudioSourceResetsTheSilenceTimer() {
    let activeLevel = RecordingSilenceMonitor.defaultActivityThreshold * 2
    let start = ContinuousClock.now
    var microphoneMonitor = RecordingSilenceMonitor()
    microphoneMonitor.start(at: start)

    XCTAssertEqual(
      microphoneMonitor.observe(
        levels: CaptureLevels(microphone: activeLevel, system: 0),
        at: start + .seconds(299)
      ),
      .none
    )
    XCTAssertEqual(microphoneMonitor.tick(at: start + .seconds(300)), .none)
    XCTAssertEqual(
      microphoneMonitor.tick(at: start + .seconds(599)),
      .presentPrompt(secondsRemaining: 30)
    )

    var systemMonitor = RecordingSilenceMonitor()
    systemMonitor.start(at: start)
    _ = systemMonitor.observe(
      levels: CaptureLevels(microphone: 0, system: activeLevel),
      at: start + .seconds(299)
    )
    XCTAssertEqual(systemMonitor.tick(at: start + .seconds(300)), .none)
    XCTAssertEqual(
      systemMonitor.tick(at: start + .seconds(599)),
      .presentPrompt(secondsRemaining: 30)
    )
  }

  func testAudioDuringCountdownDismissesAndRestartsFullSilenceWindow() {
    var monitor = RecordingSilenceMonitor()
    let start = ContinuousClock.now
    monitor.start(at: start)
    _ = monitor.tick(at: start + .seconds(300))

    XCTAssertEqual(
      monitor.observe(
        levels: CaptureLevels(
          microphone: 0,
          system: RecordingSilenceMonitor.defaultActivityThreshold * 2
        ),
        at: start + .seconds(310)
      ),
      .dismissPrompt
    )
    XCTAssertEqual(monitor.tick(at: start + .seconds(609)), .none)
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(610)),
      .presentPrompt(secondsRemaining: 30)
    )
  }

  func testKeepRecordingRestartsFullSilenceWindow() {
    var monitor = RecordingSilenceMonitor()
    let start = ContinuousClock.now
    monitor.start(at: start)
    _ = monitor.tick(at: start + .seconds(300))

    XCTAssertEqual(
      monitor.keepRecording(at: start + .seconds(305)),
      .dismissPrompt
    )
    XCTAssertEqual(monitor.tick(at: start + .seconds(604)), .none)
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(605)),
      .presentPrompt(secondsRemaining: 30)
    )
  }

  func testNoiseBelowThresholdDoesNotResetSilenceTimer() {
    var monitor = RecordingSilenceMonitor()
    let start = ContinuousClock.now
    monitor.start(at: start)

    XCTAssertEqual(
      monitor.observe(
        levels: CaptureLevels(
          microphone: RecordingSilenceMonitor.defaultActivityThreshold * 0.9,
          system: 0
        ),
        at: start + .seconds(299)
      ),
      .none
    )
    XCTAssertEqual(
      monitor.tick(at: start + .seconds(300)),
      .presentPrompt(secondsRemaining: 30)
    )
  }

  func testPreferenceDefaultsOnAndPersists() {
    let (defaults, suiteName) = makeDefaults()
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let initial = RecordingSafetyPreferenceStore(userDefaults: defaults)
    XCTAssertTrue(initial.isEnabled)

    initial.setEnabled(false)
    let restored = RecordingSafetyPreferenceStore(userDefaults: defaults)
    XCTAssertFalse(restored.isEnabled)
  }

  func testCountdownMessageUsesSingularAndPluralSeconds() {
    XCTAssertTrue(
      RecordingSilenceBannerText.message(secondsRemaining: 30).hasSuffix("30 seconds.")
    )
    XCTAssertTrue(
      RecordingSilenceBannerText.message(secondsRemaining: 1).hasSuffix("1 second.")
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
