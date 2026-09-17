import AppKit
import XCTest

@testable import MeetingBar

@MainActor
final class RecordingPromptCountdownTests: XCTestCase {
  func testStartCountdownHasFifteenSecondsAndShrinksToZero() {
    let start = ContinuousClock.now
    let countdown = RecordingPromptCountdown(
      action: .startRecording,
      totalSeconds: RecordingPromptCountdown.startDurationSeconds,
      now: start
    )

    XCTAssertEqual(countdown.display(at: start).secondsRemaining, 15)
    XCTAssertEqual(countdown.display(at: start).fractionRemaining, 1)
    XCTAssertEqual(countdown.display(at: start + .milliseconds(7500)).fractionRemaining, 0.5)
    XCTAssertEqual(countdown.display(at: start + .milliseconds(14999)).secondsRemaining, 1)
    XCTAssertEqual(countdown.display(at: start + .seconds(15)).secondsRemaining, 0)
    XCTAssertEqual(countdown.display(at: start + .seconds(60)).fractionRemaining, 0)
    XCTAssertEqual(countdown.display(at: start - .seconds(1)).fractionRemaining, 1)
  }

  func testStopCountdownUsesFullDurationAfterAnUpdate() {
    let now = ContinuousClock.now
    let countdown = RecordingPromptCountdown(
      action: .stopRecording, totalSeconds: 30, secondsRemaining: 15, now: now
    )
    XCTAssertEqual(countdown.display(at: now).fractionRemaining, 0.5)
    XCTAssertEqual(
      countdown.display(at: now).message, "Recording stops automatically in 15 seconds.")
    XCTAssertEqual(
      countdown.display(at: now + .seconds(14)).message,
      "Recording stops automatically in 1 second."
    )
  }

  func testStartPerformsExactlyOnceAtDeadline() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var starts = 0
    presenter.presentMeetingReminder(applicationName: "Zoom", onStartRecording: { starts += 1 })
    let deadline = try XCTUnwrap(presenter.countdown?.deadline)

    presenter.advanceCountdown(at: deadline - .milliseconds(1))
    XCTAssertEqual(starts, 0)
    presenter.advanceCountdown(at: deadline)
    presenter.advanceCountdown(at: deadline + .seconds(1))
    presenter.performPrimaryAction()
    XCTAssertEqual(starts, 1)
    XCTAssertNil(presenter.countdown)
  }

  func testStartNowDoesNotFireAgainAtDeadline() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var starts = 0
    presenter.presentMeetingReminder(applicationName: "Zoom", onStartRecording: { starts += 1 })
    let deadline = try XCTUnwrap(presenter.countdown?.deadline)
    presenter.performPrimaryAction()
    presenter.advanceCountdown(at: deadline)
    XCTAssertEqual(starts, 1)
  }

  func testNotNowCancelsAutomaticStart() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var starts = 0
    var cancellations = 0
    presenter.presentMeetingReminder(
      applicationName: "Zoom",
      onStartRecording: { starts += 1 },
      onCancel: { cancellations += 1 }
    )
    let deadline = try XCTUnwrap(presenter.countdown?.deadline)
    presenter.performSecondaryAction()
    presenter.advanceCountdown(at: deadline)
    XCTAssertEqual(starts, 0)
    XCTAssertEqual(cancellations, 1)
    XCTAssertNil(presenter.countdown)
  }

  func testDismissOnCallExitOrSettingsChangeCancelsAutomaticStart() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var starts = 0
    presenter.presentMeetingReminder(applicationName: "Teams", onStartRecording: { starts += 1 })
    let deadline = try XCTUnwrap(presenter.countdown?.deadline)
    presenter.dismissMeetingReminder()
    presenter.advanceCountdown(at: deadline)
    XCTAssertEqual(starts, 0)
  }

  func testReplacingPromptCannotRunOldAction() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var oldStarts = 0
    var newStarts = 0
    presenter.presentMeetingReminder(applicationName: "Zoom", onStartRecording: { oldStarts += 1 })
    presenter.presentMeetingReminder(applicationName: "Teams", onStartRecording: { newStarts += 1 })
    presenter.advanceCountdown(at: try XCTUnwrap(presenter.countdown?.deadline))
    XCTAssertEqual(oldStarts, 0)
    XCTAssertEqual(newStarts, 1)
  }

  func testInformationDoesNotInterruptPendingStart() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var starts = 0
    presenter.presentMeetingReminder(applicationName: "Zoom", onStartRecording: { starts += 1 })
    presenter.presentInformation(title: "Transcript ready", body: "Done")
    presenter.advanceCountdown(at: try XCTUnwrap(presenter.countdown?.deadline))
    XCTAssertEqual(starts, 1)
  }

  func testCallEndedDefaultActionStopsAndSecondaryKeepsRecording() {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var stops = 0
    var keeps = 0
    for usePrimary in [true, false] {
      presenter.presentOnlineMeetingEndedReminder(
        applicationName: "Zoom", secondsRemaining: 30,
        onKeepRecording: { keeps += 1 }, onStopRecording: { stops += 1 }
      )
      XCTAssertEqual(presenter.countdown?.action.buttonTitle, "Stop Now")
      if usePrimary {
        presenter.performPrimaryAction()
      } else {
        presenter.performSecondaryAction()
      }
    }
    XCTAssertEqual(stops, 1)
    XCTAssertEqual(keeps, 1)
  }

  func testStopTimerRemainsOwnedByMonitorAndCannotStopTwice() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    var stops = 0
    presenter.presentOnlineMeetingEndedReminder(
      applicationName: "Zoom", secondsRemaining: 30,
      onKeepRecording: {}, onStopRecording: { stops += 1 }
    )
    presenter.advanceCountdown(at: try XCTUnwrap(presenter.countdown?.deadline))
    XCTAssertEqual(stops, 0)
    presenter.performPrimaryAction()
    presenter.performPrimaryAction()
    XCTAssertEqual(stops, 1)
  }

  func testSilenceCannotUpdateOrDismissCallEndedPrompt() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    presenter.presentOnlineMeetingEndedReminder(
      applicationName: "Microsoft Teams", secondsRemaining: 30,
      onKeepRecording: {}, onStopRecording: {}
    )
    let deadline = try XCTUnwrap(presenter.countdown?.deadline)
    presenter.updateRecordingSilenceReminder(secondsRemaining: 1)
    presenter.dismissRecordingContinuationReminder(kind: .silence)
    XCTAssertEqual(presenter.continuationKind, .onlineMeetingEnded)
    XCTAssertEqual(presenter.countdown?.deadline, deadline)
    presenter.dismissRecordingContinuationReminder(kind: .onlineMeetingEnded)
    XCTAssertNil(presenter.countdown)
  }

  func testCountdownPanelsStayCompactAndDoNotResizeWhileCounting() throws {
    let presenter = AppBannerPresenter()
    defer { presenter.dismiss() }
    presenter.presentMeetingReminder(applicationName: "Microsoft Teams", onStartRecording: {})
    try checkLayout(presenter, title: "Record this meeting?", attachmentName: "Start countdown")
    presenter.presentOnlineMeetingEndedReminder(
      applicationName: "Microsoft Teams", secondsRemaining: 30,
      onKeepRecording: {}, onStopRecording: {}
    )
    try checkLayout(presenter, title: "Call ended?", attachmentName: "Stop countdown")
    presenter.presentRecordingSilenceReminder(
      secondsRemaining: 30, onKeepRecording: {}, onStopRecording: {}
    )
    try checkLayout(presenter, title: "Still recording?", attachmentName: "Silence countdown")
  }

  private func checkLayout(
    _ presenter: AppBannerPresenter, title: String, attachmentName: String
  ) throws {
    let panel = try XCTUnwrap(NSApp.windows.first { $0.title == title && $0.isVisible })
    let frame = panel.frame
    XCTAssertEqual(frame.width, 420)
    XCTAssertGreaterThan(frame.height, 150)
    XCTAssertLessThan(frame.height, 280)
    let view = try XCTUnwrap(panel.contentView)
    view.layoutSubtreeIfNeeded()
    if let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
      view.cacheDisplay(in: view.bounds, to: bitmap)
      let image = NSImage(size: view.bounds.size)
      image.addRepresentation(bitmap)
      let attachment = XCTAttachment(image: image)
      attachment.name = attachmentName
      attachment.lifetime = .keepAlways
      add(attachment)
    }
    presenter.advanceCountdown(at: try XCTUnwrap(presenter.countdown?.deadline) - .seconds(1))
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(panel.frame, frame)
  }
}
