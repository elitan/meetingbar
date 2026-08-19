import XCTest
@testable import MeetingBar

final class RetentionServiceTests: XCTestCase {
  private let now = Date(timeIntervalSince1970: 10_000_000)

  func testReadyAudioIsNotEligibleJustBeforeThirtyDays() {
    XCTAssertFalse(
      RetentionService.isEligible(
        candidate(endedAt: now.addingTimeInterval(-RetentionService.retentionInterval + 1)),
        now: now
      )
    )
  }

  func testReadyAudioIsEligibleAtExactlyThirtyDays() {
    XCTAssertTrue(
      RetentionService.isEligible(
        candidate(endedAt: now.addingTimeInterval(-RetentionService.retentionInterval)),
        now: now
      )
    )
  }

  func testReadyAudioIsEligibleAfterThirtyDays() {
    XCTAssertTrue(
      RetentionService.isEligible(
        candidate(endedAt: now.addingTimeInterval(-RetentionService.retentionInterval - 1)),
        now: now
      )
    )
  }

  func testQueuedAndFailedAudioAreNeverEligible() {
    for status in [RecordingStatus.queued, .failed, .transcribing] {
      XCTAssertFalse(
        RetentionService.isEligible(
          RetentionCandidate(
            endedAt: now.addingTimeInterval(-RetentionService.retentionInterval * 2),
            status: status,
            hasAudio: true,
            audioDeletedAt: nil
          ),
          now: now
        )
      )
    }
  }

  func testMissingOrAlreadyDeletedAudioIsNotEligible() {
    XCTAssertFalse(
      RetentionService.isEligible(
        RetentionCandidate(endedAt: .distantPast, status: .ready, hasAudio: false, audioDeletedAt: nil),
        now: now
      )
    )
    XCTAssertFalse(
      RetentionService.isEligible(
        RetentionCandidate(endedAt: .distantPast, status: .ready, hasAudio: true, audioDeletedAt: now),
        now: now
      )
    )
  }

  private func candidate(endedAt: Date) -> RetentionCandidate {
    RetentionCandidate(
      endedAt: endedAt,
      status: .ready,
      hasAudio: true,
      audioDeletedAt: nil
    )
  }
}
