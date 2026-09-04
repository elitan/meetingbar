import SwiftData
import XCTest

@testable import MeetingBar

@MainActor
final class RetentionServiceTests: XCTestCase {
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
