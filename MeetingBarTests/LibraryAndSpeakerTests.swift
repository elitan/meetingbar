import SwiftData
import XCTest

@testable import MeetingBar

@MainActor
final class LibraryAndSpeakerTests: XCTestCase {
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
