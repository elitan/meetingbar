import AppKit
import SwiftData
import XCTest

@testable import MeetingBar

@MainActor
final class TranscriptCopyTests: XCTestCase {
  func testCopyReportsSuccessAndReplacesClipboardWithTheExactTranscript() throws {
    let suiteName = "MeetingBar.TranscriptCopyTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    let directory = FileManager.default.temporaryDirectory
      .appending(path: suiteName, directoryHint: .isDirectory)
    let pasteboard = NSPasteboard.withUniqueName()
    defer {
      pasteboard.releaseGlobally()
      defaults.removePersistentDomain(forName: suiteName)
      try? FileManager.default.removeItem(at: directory)
    }
    let container = try ModelContainer(
      for: Recording.self,
      configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )
    let controller = AppController(
      modelContext: container.mainContext,
      fileStore: try RecordingFileStore(rootURL: directory),
      transcriptionSecretStore: EmptyTranscriptionSecretStore(),
      userDefaults: defaults
    )
    let recording = Recording(
      title: "Fictional meeting", endedAt: .now, status: .ready,
      transcript: "Speaker 0: Hej, hur är läget?\n\nSpeaker 1: Great, thanks!"
    )
    XCTAssertTrue(pasteboard.setString("Old clipboard content", forType: .string))

    XCTAssertTrue(controller.copyTranscript(recording, to: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), recording.transcript)

    recording.transcript = "Updated transcript."
    XCTAssertTrue(controller.copyTranscript(recording, to: pasteboard))
    XCTAssertEqual(pasteboard.string(forType: .string), "Updated transcript.")
  }
}
