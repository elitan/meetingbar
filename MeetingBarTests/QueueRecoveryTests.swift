import Foundation
import SwiftData
import XCTest
@testable import MeetingBar

@MainActor
final class QueueRecoveryTests: XCTestCase {
  func testAbandonedTranscribingJobReturnsToQueued() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Recording.self, configurations: configuration)
    let context = container.mainContext
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RecordingFileStore(rootURL: directory)
    let recording = Recording(title: "Interrupted", status: .transcribing)
    context.insert(recording)
    try context.save()

    let service = RecordingRecoveryService(modelContext: context, fileStore: store)
    let recovered = try service.resetAbandonedJobs()

    XCTAssertEqual(recovered.map(\.id), [recording.id])
    XCTAssertEqual(recording.status, .queued)
  }

  func testPartialFileRecoveryQueuesRecordingAndKeepsMetadata() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Recording.self, configurations: configuration)
    let context = container.mainContext
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RecordingFileStore(rootURL: directory)
    let recording = Recording(title: "Keep this title")
    context.insert(recording)
    try store.prepareDirectory(for: recording.id)
    var writer: PCM16WAVWriter? = try PCM16WAVWriter(
      partialURL: store.partialAudioURL(for: recording.id),
      finalURL: store.audioURL(for: recording.id)
    )
    try writer?.append(floatSamples: Array(repeating: 0.2, count: 16_000))
    writer = nil
    try context.save()

    let service = RecordingRecoveryService(modelContext: context, fileStore: store)
    let recovered = try service.recoverPartialRecordings()

    XCTAssertEqual(recovered.count, 1)
    XCTAssertEqual(recording.title, "Keep this title")
    XCTAssertEqual(recording.status, .queued)
    XCTAssertEqual(recording.durationSeconds, 1, accuracy: 0.001)
    XCTAssertTrue(recording.wasRecovered)
    XCTAssertNotNil(recording.audioRelativePath)
  }

  func testFinalizedAudioIsRecoveredWhenMetadataUpdateWasInterrupted() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let recording = Recording(title: "Finalized before crash")
    fixture.context.insert(recording)
    try fixture.store.prepareDirectory(for: recording.id)
    let writer = try PCM16WAVWriter(
      partialURL: fixture.store.partialAudioURL(for: recording.id),
      finalURL: fixture.store.audioURL(for: recording.id)
    )
    try writer.append(floatSamples: Array(repeating: 0.1, count: 8_000))
    _ = try writer.finish()
    try fixture.context.save()

    let service = RecordingRecoveryService(
      modelContext: fixture.context,
      fileStore: fixture.store
    )
    let recovered = try service.recoverPartialRecordings()

    XCTAssertEqual(recovered.map(\.id), [recording.id])
    XCTAssertEqual(recording.status, .queued)
    XCTAssertEqual(recording.durationSeconds, 0.5, accuracy: 0.001)
    XCTAssertTrue(recording.wasRecovered)
  }

  func testInterruptedMetadataWithoutAudioIsMarkedFailed() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let recording = Recording(title: "No recoverable audio")
    fixture.context.insert(recording)
    try fixture.context.save()

    let service = RecordingRecoveryService(
      modelContext: fixture.context,
      fileStore: fixture.store
    )
    _ = try service.recoverPartialRecordings()

    XCTAssertEqual(recording.status, .failed)
    XCTAssertNotNil(recording.endedAt)
    XCTAssertNotNil(recording.errorMessage)
  }

  private func makeFixture() throws -> (
    container: ModelContainer,
    context: ModelContext,
    store: RecordingFileStore,
    directory: URL
  ) {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Recording.self, configurations: configuration)
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    return (
      container,
      container.mainContext,
      try RecordingFileStore(rootURL: directory),
      directory
    )
  }
}
