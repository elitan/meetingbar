import SwiftData
import XCTest

@testable import MeetingBar

@MainActor
final class RetentionServiceTests: XCTestCase {
  func testRetentionBoundaryAndProtectedWork() {
    let end = Date(timeIntervalSince1970: 1_000)
    let cutoff = end.addingTimeInterval(30 * 86_400)
    for status in RecordingStatus.allCases {
      let recording = Recording(title: "Fixture", isPinned: true, endedAt: end, status: status)
      XCTAssertFalse(
        MeetingRetentionPolicy.isExpired(recording, days: 30, now: cutoff.addingTimeInterval(-1)))
      XCTAssertEqual(
        MeetingRetentionPolicy.isExpired(recording, days: 30, now: cutoff), status != .transcribing)
      XCTAssertEqual(
        MeetingRetentionPolicy.isExpired(recording, days: 30, now: cutoff.addingTimeInterval(1)),
        status != .transcribing)
      XCTAssertFalse(MeetingRetentionPolicy.isExpired(recording, days: 0, now: cutoff))
      recording.endedAt = nil
      XCTAssertFalse(MeetingRetentionPolicy.isExpired(recording, days: 30, now: cutoff))
    }
  }

  func testPreferencesDefaultOffPersistAndRejectInvalidLimits() throws {
    let suite = "MeetingBar.RetentionTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let preferences = MeetingRetentionPreferences(userDefaults: defaults)
    XCTAssertFalse(preferences.isEnabled)
    XCTAssertEqual(preferences.days, 30)
    preferences.update(enabled: true, days: 45)
    let reloaded = MeetingRetentionPreferences(userDefaults: defaults)
    XCTAssertTrue(reloaded.isEnabled)
    XCTAssertEqual(reloaded.days, 45)
    reloaded.update(enabled: true, days: -1)
    XCTAssertEqual(reloaded.days, 45)
    defaults.set(0, forKey: "MeetingRetentionDays")
    XCTAssertFalse(MeetingRetentionPreferences(userDefaults: defaults).isEnabled)
  }

  func testLegacyExpiryDatesAreClearedWithoutChangingRetainedAudio() throws {
    let container = try makeContainer()
    let context = container.mainContext
    let audioDeletedAt = Date(timeIntervalSince1970: 1_000)
    let recordingWithAudio = Recording(
      title: "Retained audio",
      status: .ready,
      transcript: "Keep both the transcript and its audio.",
      audioRelativePath: "Recordings/retained/audio.wav",
      audioExpiresAt: .distantPast
    )
    let historicalRecording = Recording(
      title: "Previously deleted audio",
      status: .ready,
      transcript: "Only this older transcript remains.",
      audioRelativePath: nil,
      audioExpiresAt: .distantPast,
      audioDeletedAt: audioDeletedAt
    )
    context.insert(recordingWithAudio)
    context.insert(historicalRecording)
    try context.save()

    let changedCount = try AudioPreservationService(modelContext: context)
      .clearLegacyExpiryDates(now: Date(timeIntervalSince1970: 2_000))

    XCTAssertEqual(changedCount, 2)
    XCTAssertNil(recordingWithAudio.audioExpiresAt)
    XCTAssertEqual(recordingWithAudio.audioRelativePath, "Recordings/retained/audio.wav")
    XCTAssertNil(recordingWithAudio.audioDeletedAt)
    XCTAssertNil(historicalRecording.audioExpiresAt)
    XCTAssertNil(historicalRecording.audioRelativePath)
    XCTAssertEqual(historicalRecording.audioDeletedAt, audioDeletedAt)
  }

  func testPreservationMigrationIsIdempotent() throws {
    let container = try makeContainer()
    let context = container.mainContext
    let recording = Recording(
      title: "Already preserved",
      status: .ready,
      transcript: "Nothing needs changing.",
      audioRelativePath: "Recordings/preserved/audio.wav"
    )
    context.insert(recording)
    try context.save()
    let service = AudioPreservationService(modelContext: context)

    XCTAssertEqual(try service.clearLegacyExpiryDates(), 0)
    XCTAssertEqual(try service.clearLegacyExpiryDates(), 0)
    XCTAssertEqual(recording.audioRelativePath, "Recordings/preserved/audio.wav")
  }

  private func makeContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    return try ModelContainer(for: Recording.self, configurations: configuration)
  }
}
