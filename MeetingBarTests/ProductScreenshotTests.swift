import AppKit
import SwiftData
import SwiftUI
import XCTest

@testable import MeetingBar

/// Renders the real meeting detail with fictional content, never the user's database or credentials.
@MainActor
final class ProductScreenshotTests: XCTestCase {
  func testTranscriptScreenshotWithFictionalMeeting() async throws {
    let suiteName = "MeetingBar.ProductScreenshot.\(UUID().uuidString)"
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
    let fileStore = try RecordingFileStore(rootURL: directory)
    let controller = AppController(
      modelContext: container.mainContext,
      fileStore: fileStore,
      transcriptionSecretStore: EmptyTranscriptionSecretStore(),
      userDefaults: defaults
    )
    XCTAssertEqual(controller.transcriptionPreferences.provider, .onDevice)
    XCTAssertFalse(controller.transcriptionPreferences.hasElevenLabsAPIKey)
    XCTAssertFalse(controller.onboardingComplete)

    let startedAt = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-09-17T08:30:00Z"))
    let recording = Recording(
      title: "Product launch review",
      isPinned: true,
      startedAt: startedAt,
      endedAt: startedAt.addingTimeInterval(1_920),
      durationSeconds: 1_920,
      status: .ready,
      transcript: Self.transcript,
      detectedLanguage: "en",
      transcriptionProvider: .onDevice,
      modelIdentifier: TranscriptionQuality.bestAccuracy.modelIdentifier
    )
    try FileManager.default.createDirectory(
      at: fileStore.directoryURL(for: recording.id), withIntermediateDirectories: true
    )
    // A silent fixture enables the actual player UI; no audio is captured or played.
    let writer = try PCM16WAVWriter(
      partialURL: fileStore.partialAudioURL(for: recording.id),
      finalURL: fileStore.audioURL(for: recording.id)
    )
    try writer.append(floatSamples: [0])
    _ = try writer.finish()
    recording.audioRelativePath = fileStore.relativeAudioPath(for: recording.id)
    container.mainContext.insert(recording)
    try container.mainContext.save()

    let size = NSSize(width: 900, height: 720)
    let view = NSHostingView(
      rootView: ZStack {
        MeetingBarBackdrop()
        RecordingDetailView(recording: recording, controller: controller)
      }
      .meetingBarWindowTint()
      .modelContainer(container)
      .environment(\.locale, Locale(identifier: "en_GB"))
      .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
      .frame(width: size.width, height: size.height)
    )
    let window = NSWindow(
      contentRect: NSRect(origin: .zero, size: size),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered,
      defer: false
    )
    window.title = "MeetingBar"
    window.titlebarAppearsTransparent = true
    window.appearance = NSAppearance(named: .darkAqua)
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.center()
    window.makeKeyAndOrderFront(nil)
    defer { window.close() }

    // Allow the native view to finish its first layout before capturing the test attachment.
    try await Task.sleep(for: .milliseconds(250))
    view.layoutSubtreeIfNeeded()
    XCTAssertEqual(view.bounds.size, size)
    XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<Recording>()), 1)
    XCTAssertEqual(controller.capture.state, .idle)

    let frameView = view
    let bitmap = try XCTUnwrap(frameView.bitmapImageRepForCachingDisplay(in: frameView.bounds))
    frameView.cacheDisplay(in: frameView.bounds, to: bitmap)
    let image = NSImage(size: frameView.bounds.size)
    image.addRepresentation(bitmap)
    let attachment = XCTAttachment(image: image)
    attachment.name = "MeetingBar Transcript - fictional demo"
    attachment.lifetime = .keepAlways
    add(attachment)
  }

  private static let transcript = """
    Speaker 0: Let's keep the launch focused on the recording experience. People should be able to start a meeting in one click and find the conversation again later.

    Speaker 1: Agreed. The library feels much calmer now. I especially like having the audio controls available while reading the transcript.

    Speaker 0: For the website, let's show the product first. A short explanation and one clear screenshot will say more than a long list of features.

    Speaker 1: I'll update the onboarding copy this week. We should make the countdown clear, so people always know when recording will start or stop.

    Speaker 0: Great. Let's review the final details on Friday and invite a small group to try it before the wider launch.
    """
}
