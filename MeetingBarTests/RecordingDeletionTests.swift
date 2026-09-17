import Foundation
import SwiftData
import XCTest

@testable import MeetingBar

@MainActor
final class RecordingDeletionTests: XCTestCase {
  func testDeletingMeetingRemovesItsTranscriptAndAllAudioButKeepsOtherMeetings() throws {
    try withFixture { context, controller, store in
      let target = Recording(
        title: "Delete this fictional meeting", endedAt: .now, status: .ready,
        transcript: "A disposable transcript."
      )
      let retained = Recording(
        title: "Keep this fictional meeting", endedAt: .now, status: .ready,
        transcript: "This transcript must remain."
      )
      let targetID = target.id
      let retainedID = retained.id
      for recording in [target, retained] {
        context.insert(recording)
        recording.audioRelativePath = store.relativeAudioPath(for: recording.id)
        try FileManager.default.createDirectory(
          at: store.directoryURL(for: recording.id), withIntermediateDirectories: true
        )
        for fileName in [
          "audio.wav", "microphone.wav", "system.wav", "playback-balanced-v1.wav",
          "audio.partial.wav", "capture-sources.json",
        ] {
          try Data([0, 1, 2]).write(
            to: store.directoryURL(for: recording.id).appending(path: fileName)
          )
        }
      }
      try context.save()

      try controller.delete(target)

      let remaining = try context.fetch(FetchDescriptor<Recording>())
      XCTAssertEqual(remaining.map(\.id), [retainedID])
      XCTAssertEqual(remaining.first?.transcript, "This transcript must remain.")
      XCTAssertFalse(FileManager.default.fileExists(atPath: store.directoryURL(for: targetID).path))
      XCTAssertEqual(try Data(contentsOf: store.audioURL(for: retainedID)), Data([0, 1, 2]))
    }
  }

  func testDeletingMeetingWithoutAudioStillRemovesItsTranscript() throws {
    try withFixture { context, controller, _ in
      let recording = Recording(
        title: "Old fictional meeting", endedAt: .now, status: .ready,
        transcript: "Transcript with no remaining audio."
      )
      context.insert(recording)
      try context.save()

      try controller.delete(recording)

      XCTAssertEqual(try context.fetchCount(FetchDescriptor<Recording>()), 0)
    }
  }

  private func withFixture(
    _ test: (ModelContext, AppController, RecordingFileStore) throws -> Void
  ) throws {
    let suiteName = "MeetingBar.RecordingDeletionTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let directory = FileManager.default.temporaryDirectory
      .appending(path: suiteName, directoryHint: .isDirectory)
    defer {
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
    let container = try ModelContainer(
      for: Recording.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let store = try RecordingFileStore(rootURL: directory)
    let controller = AppController(
      modelContext: container.mainContext,
      fileStore: store,
      transcriptionSecretStore: EmptyTranscriptionSecretStore(),
      userDefaults: defaults
    )
    try test(container.mainContext, controller, store)
  }
}
