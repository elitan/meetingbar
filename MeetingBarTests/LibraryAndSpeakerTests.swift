import SwiftData
import XCTest

@testable import MeetingBar

@MainActor
final class LibraryAndSpeakerTests: XCTestCase {
  func testSettingsSidebarShowsGeneralFirst() {
    XCTAssertEqual(SettingsSection.allCases, [.general, .capture, .transcription])
  }

  func testProductionLaunchDoesNotUseTheTestRuntime() {
    XCTAssertFalse(MeetingBarRuntime.isRunningTests(environment: [:]))
  }

  func testXCTestHostUsesTheIsolatedRuntime() {
    XCTAssertTrue(
      MeetingBarRuntime.isRunningTests(
        environment: ["XCTestConfigurationFilePath": "/tmp/MeetingBarTests.xctestconfiguration"]
      )
    )
  }

  func testApplicationBecomesAccessoryOnlyAfterLastPrimaryWindowCloses() {
    XCTAssertFalse(
      MeetingBarApplicationPresentation.shouldBecomeAccessory(primaryWindowCount: 2)
    )
    XCTAssertFalse(
      MeetingBarApplicationPresentation.shouldBecomeAccessory(primaryWindowCount: 1)
    )
    XCTAssertTrue(
      MeetingBarApplicationPresentation.shouldBecomeAccessory(primaryWindowCount: 0)
    )
  }

  func testUnifiedNavigationMovesBetweenLibraryAndSettings() {
    let navigation = MeetingBarNavigation()

    XCTAssertEqual(navigation.workspace, .library)
    XCTAssertEqual(navigation.settingsSection, .capture)

    navigation.showSettings(.transcription)

    XCTAssertEqual(navigation.workspace, .settings)
    XCTAssertEqual(navigation.settingsSection, .transcription)

    navigation.showLibrary()

    XCTAssertEqual(navigation.workspace, .library)
    XCTAssertEqual(navigation.settingsSection, .transcription)
  }

  func testOpeningSettingsWithoutASectionPreservesTheLastSettingsPage() {
    let navigation = MeetingBarNavigation()
    navigation.showSettings(.general)
    navigation.showLibrary()

    navigation.showSettings()

    XCTAssertEqual(navigation.workspace, .settings)
    XCTAssertEqual(navigation.settingsSection, .general)
  }

  func testPinnedStateIsStoredWithRecording() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Recording.self, configurations: configuration)
    let recording = Recording(title: "Important meeting", isPinned: true)
    container.mainContext.insert(recording)
    try container.mainContext.save()

    let fetched = try container.mainContext.fetch(FetchDescriptor<Recording>())

    XCTAssertEqual(fetched.count, 1)
    XCTAssertTrue(fetched[0].isPinned)
  }

  func testRecordingKeepsCloudTranscriptionProvenance() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Recording.self, configurations: configuration)
    let recording = Recording(
      title: "Cloud meeting",
      transcriptionProvider: .elevenLabs,
      modelIdentifier: ElevenLabsTranscriptionModel.scribeV2.modelIdentifier
    )
    container.mainContext.insert(recording)
    try container.mainContext.save()

    let fetched = try XCTUnwrap(
      container.mainContext.fetch(FetchDescriptor<Recording>()).first
    )

    XCTAssertEqual(fetched.transcriptionProvider, .elevenLabs)
    XCTAssertEqual(fetched.transcriptionEngineLabel, "ElevenLabs · Scribe v2")
  }

  func testOldRecordingModelWithoutProviderIsTreatedAsOnDevice() {
    let recording = Recording(
      title: "Existing meeting",
      modelIdentifier: TranscriptionQuality.bestAccuracy.modelIdentifier
    )

    XCTAssertEqual(recording.transcriptionProvider, .onDevice)
    XCTAssertEqual(recording.transcriptionEngineLabel, "On this Mac · Best accuracy")
  }

  func testSpeakerFormatterNumbersSpeakersByFirstAppearance() {
    let transcript = SpeakerTranscriptFormatter.format([
      segment(source: .system, start: 0, text: "Hello", speakerID: 7),
      segment(source: .microphone, start: 1, text: "Hi", speakerID: 2),
      segment(source: .system, start: 2, text: "Let's review the agenda", speakerID: 7),
    ])

    XCTAssertEqual(
      transcript,
      "Speaker 0: Hello\n\nSpeaker 1: Hi\n\nSpeaker 0: Let's review the agenda"
    )
  }

  func testSpeakerFormatterCoalescesConsecutiveTurns() {
    let transcript = SpeakerTranscriptFormatter.format([
      segment(source: .microphone, start: 0, text: "Good", speakerID: 4),
      segment(source: .microphone, start: 1, text: "morning", speakerID: 4),
      segment(source: .system, start: 2, text: "Good morning", speakerID: 0),
    ])

    XCTAssertEqual(transcript, "Speaker 0: Good morning\n\nSpeaker 1: Good morning")
  }

  func testSpeakerFormatterFallsBackToOneSpeakerPerSource() {
    let transcript = SpeakerTranscriptFormatter.format([
      segment(source: .microphone, start: 0, text: "My side"),
      segment(source: .system, start: 1, text: "Remote side"),
      segment(source: .microphone, start: 2, text: "My reply"),
    ])

    XCTAssertEqual(
      transcript,
      "Speaker 0: My side\n\nSpeaker 1: Remote side\n\nSpeaker 0: My reply"
    )
  }

  func testSpeakerFormatterOmitsLabelForSingleDetectedSpeaker() {
    let transcript = SpeakerTranscriptFormatter.format([
      segment(source: .microphone, start: 0, text: "This is", speakerID: 4),
      segment(source: .microphone, start: 1, text: "one speaker", speakerID: 4),
    ])

    XCTAssertEqual(transcript, "This is one speaker")
    XCTAssertFalse(SpeakerTranscriptFormatter.containsSpeakerLabels(transcript))
  }

  func testLeadingUnmatchedSpeechUsesFirstDetectedSpeakerForThatSource() {
    let transcript = SpeakerTranscriptFormatter.format([
      segment(source: .microphone, start: 0, text: "Before detection"),
      segment(source: .microphone, start: 1, text: "After detection", speakerID: 3),
    ])

    XCTAssertEqual(transcript, "Before detection After detection")
  }

  func testSpeakerLabelDetectionRejectsOrdinaryTranscriptText() {
    XCTAssertTrue(
      SpeakerTranscriptFormatter.containsSpeakerLabels("Speaker 0: Welcome to the meeting")
    )
    XCTAssertFalse(
      SpeakerTranscriptFormatter.containsSpeakerLabels("We discussed Speaker 0 during the meeting")
    )
  }

  private func segment(
    source: CaptureSourceKind,
    start: Double,
    text: String,
    speakerID: Int? = nil
  ) -> SourceTranscriptSegment {
    SourceTranscriptSegment(
      source: source,
      start: start,
      end: start + 0.8,
      text: text,
      averageLogProbability: -0.1,
      noSpeechProbability: 0,
      speakerID: speakerID
    )
  }
}

@MainActor
final class LibraryPresentationTests: XCTestCase {
  private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
  }()
  private let locale = Locale(identifier: "en_US")
  private let now = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!

  private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
  }

  func testCompactDurationIsGlanceable() {
    XCTAssertEqual(DurationText.compact(seconds: 42), "42 sec")
    XCTAssertEqual(DurationText.compact(seconds: 1_920), "32 min")
    XCTAssertEqual(DurationText.compact(seconds: 3_600), "1 h")
    XCTAssertEqual(DurationText.compact(seconds: 3_900), "1 h 5 min")
  }

  func testMeetingDatesReadRelativeToToday() {
    func text(_ iso: String) -> String {
      MeetingDateText.string(for: date(iso), now: now, calendar: calendar, locale: locale)
    }
    XCTAssertTrue(text("2026-10-13T08:30:00Z").hasPrefix("Today, "))
    XCTAssertTrue(text("2026-10-12T16:05:00Z").hasPrefix("Yesterday, "))

    let thisYear = text("2026-09-17T08:30:00Z")
    XCTAssertTrue(thisYear.hasPrefix("Sep 17, "), thisYear)
    XCTAssertFalse(thisYear.contains("2026"))
    XCTAssertTrue(text("2025-09-17T08:30:00Z").contains("2025"))
  }

  func testLibraryGroupsPinnedThenByRecency() {
    let recordings = [
      ("2026-10-13T11:00:00Z", false),
      ("2026-10-12T09:00:00Z", false),
      ("2026-10-12T08:00:00Z", false),
      ("2026-10-09T09:00:00Z", false),
      ("2026-09-20T09:00:00Z", true),
      ("2026-09-20T08:00:00Z", false),
      ("2026-03-01T09:00:00Z", false),
      ("2025-12-01T09:00:00Z", false),
    ].map { Recording(title: $0.0, isPinned: $0.1, startedAt: date($0.0)) }

    let sections = LibraryGrouping.sections(
      for: recordings, now: now, calendar: calendar, locale: locale)

    XCTAssertEqual(
      sections.map(\.title),
      [
        "Pinned", "Today", "Yesterday", "Previous 7 Days", "Previous 30 Days", "March",
        "December 2025",
      ])
    XCTAssertEqual(sections.map(\.recordings.count), [1, 1, 2, 1, 1, 1, 1])
    // A pinned meeting is listed once, in Pinned.
    XCTAssertEqual(sections.flatMap(\.recordings).count, recordings.count)
  }

  func testSearchSnippetShowsContextWithoutSpeakerLabels() throws {
    let transcript = """
      Speaker 0: We should keep the launch focused on recording and ship on Friday afternoon.

      Speaker 1: Agreed, Friday works for the whole team.
      """
    let snippet = try XCTUnwrap(
      TranscriptSearch.snippet(in: transcript, matching: "friday", radius: 12))
    XCTAssertTrue(snippet.localizedCaseInsensitiveContains("friday"))
    XCTAssertFalse(snippet.contains("Speaker"))
    XCTAssertTrue(snippet.hasPrefix("…"))
    XCTAssertTrue(snippet.hasSuffix("…"))
    XCTAssertNil(TranscriptSearch.snippet(in: transcript, matching: "budget"))
  }

  func testHighlightMarksEveryMatch() {
    var emphasis = AttributeContainer()
    emphasis.inlinePresentationIntent = .stronglyEmphasized
    let highlighted = TranscriptSearch.highlighted(
      "Ship on Friday, or friday at the latest.", matching: "FRIDAY", with: emphasis)
    let matches = highlighted.runs.filter { $0.inlinePresentationIntent == .stronglyEmphasized }
    XCTAssertEqual(matches.map { String(highlighted[$0.range].characters) }, ["Friday", "friday"])
  }

  func testPlaybackRateSurvivesAcrossMeetings() {
    let playback = AudioPlaybackController()
    playback.rate = 1.5
    playback.unload()
    XCTAssertEqual(playback.rate, 1.5)
  }
}
