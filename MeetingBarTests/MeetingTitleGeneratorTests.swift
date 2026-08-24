import SwiftData
import XCTest

@testable import MeetingBar

@MainActor
final class MeetingTitleGeneratorTests: XCTestCase {
  func testSamplerStripsSpeakerLabelsAndNormalizesWhitespace() {
    let sample = MeetingTitleTranscriptSampler.sample(
      "Speaker 0:  Hello there.\n\nSpeaker 12:\tLet's discuss the launch."
    )

    XCTAssertEqual(sample, "Hello there. Let's discuss the launch.")
  }

  func testSamplerKeepsBeginningMiddleAndEndWithinBound() {
    let transcript =
      "START_TOPIC "
      + String(repeating: "beginning context ", count: 700)
      + "MIDDLE_TOPIC "
      + String(repeating: "ending context ", count: 700)
      + "END_TOPIC"

    let sample = MeetingTitleTranscriptSampler.sample(transcript, maximumCharacters: 900)

    XCTAssertLessThanOrEqual(sample.count, 900)
    XCTAssertTrue(sample.contains("[BEGINNING]"))
    XCTAssertTrue(sample.contains("[MIDDLE]"))
    XCTAssertTrue(sample.contains("[END]"))
    XCTAssertTrue(sample.contains("START_TOPIC"))
    XCTAssertTrue(sample.contains("END_TOPIC"))
  }

  func testLocaleFollowsDetectedSwedishAndEnglish() {
    XCTAssertEqual(MeetingTitleGenerator.localeIdentifier(for: "sv"), "sv_SE")
    XCTAssertEqual(MeetingTitleGenerator.localeIdentifier(for: "sv_se"), "sv_SE")
    XCTAssertEqual(MeetingTitleGenerator.localeIdentifier(for: "Swedish"), "sv_SE")
    XCTAssertEqual(MeetingTitleGenerator.localeIdentifier(for: "en"), "en_US")
    XCTAssertEqual(MeetingTitleGenerator.localeIdentifier(for: "en_us"), "en_US")
  }

  func testSanitizerRemovesFormattingAndCapsWordCount() {
    let title = MeetingTitleGenerator.sanitizedTitle(
      "Titel: “Automatiska mötestitlar för ett lokalt privat bibliotek idag.”\nExtra text",
      sourceTranscript: "Vi pratade om automatiska mötestitlar för ett lokalt privat bibliotek idag."
    )

    XCTAssertEqual(title, "Automatiska mötestitlar för ett lokalt privat bibliotek idag")
    XCTAssertEqual(title?.split(separator: " ").count, 8)
  }

  func testSanitizerRejectsInventedNumbersAndGenericTitles() {
    XCTAssertNil(
      MeetingTitleGenerator.sanitizedTitle(
        "MeetingBar version 2.0",
        sourceTranscript: "We discussed automatic titles for MeetingBar."
      )
    )
    XCTAssertNil(
      MeetingTitleGenerator.sanitizedTitle(
        "Meeting summary",
        sourceTranscript: "We discussed automatic titles for MeetingBar."
      )
    )
    XCTAssertEqual(
      MeetingTitleGenerator.sanitizedTitle(
        "MeetingBar version 2.0",
        sourceTranscript: "We agreed that MeetingBar version 2.0 will include automatic titles."
      ),
      "MeetingBar version 2.0"
    )
  }

  func testManualRenameWinsAgainstLateGeneratedTitle() {
    let transcript = "We reviewed the product launch and the remaining work for next week."
    let recording = Recording(
      title: "Meeting 2026-08-21 09:30",
      titleOrigin: .placeholder,
      status: .ready,
      transcript: transcript
    )
    XCTAssertNotNil(MeetingTitleJob(recording: recording))

    recording.setManualTitle("My launch notes")

    XCTAssertFalse(recording.applyGeneratedTitle("Product launch planning", for: transcript))
    XCTAssertEqual(recording.title, "My launch notes")
    XCTAssertEqual(recording.titleOrigin, .manual)
  }

  func testGeneratedTitleRejectsStaleTranscript() {
    let recording = Recording(
      title: "Meeting 2026-08-21 09:30",
      titleOrigin: .placeholder,
      status: .ready,
      transcript: "The newer transcript discusses microphone priorities."
    )

    XCTAssertFalse(
      recording.applyGeneratedTitle(
        "Old playback discussion",
        for: "The old transcript discusses playback."
      )
    )
    XCTAssertEqual(recording.titleOrigin, .placeholder)
  }

  func testReadyPlaceholderIsRecoveredAsPendingAfterRelaunch() throws {
    let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
    let container = try ModelContainer(for: Recording.self, configurations: configuration)
    let recording = Recording(
      title: "Meeting 2026-08-21 09:30",
      titleOrigin: .placeholder,
      status: .ready,
      transcript: "We discussed microphone priorities and automatic reconnect behavior."
    )
    container.mainContext.insert(recording)
    try container.mainContext.save()

    let fetched = try XCTUnwrap(
      container.mainContext.fetch(FetchDescriptor<Recording>()).first
    )

    XCTAssertEqual(fetched.titleOrigin, .placeholder)
    XCTAssertTrue(fetched.needsGeneratedTitle)
    XCTAssertNotNil(MeetingTitleJob(recording: fetched))
  }

  func testExistingAndExplicitManualTitlesAreNeverEligible() {
    let existing = Recording(
      title: "Customer planning",
      status: .ready,
      transcript: "A transcript from before automatic titles shipped."
    )
    let manual = Recording(
      title: "My notes",
      titleOrigin: .manual,
      status: .ready,
      transcript: "A newly renamed transcript."
    )

    XCTAssertEqual(existing.titleOrigin, .manual)
    XCTAssertFalse(existing.needsGeneratedTitle)
    XCTAssertFalse(manual.needsGeneratedTitle)
  }

  func testShortTranscriptSkipsSystemModel() async {
    let title = await MeetingTitleGenerator.generateTitle(
      transcript: "Hello, can you hear me?",
      detectedLanguage: "en"
    )

    XCTAssertNil(title)
  }

  func testTitleQueueDeduplicatesAndProcessesSerially() async throws {
    let first = Recording(
      title: "Meeting one",
      titleOrigin: .placeholder,
      status: .ready,
      transcript: "First transcript with enough content to represent a completed meeting."
    )
    let second = Recording(
      title: "Meeting two",
      titleOrigin: .placeholder,
      status: .ready,
      transcript: "Second transcript with enough content to represent another completed meeting."
    )
    let firstJob = try XCTUnwrap(MeetingTitleJob(recording: first))
    let secondJob = try XCTUnwrap(MeetingTitleJob(recording: second))
    let completion = expectation(description: "Two unique title jobs complete")
    completion.expectedFulfillmentCount = 2
    let generator = MeetingTitleGenerationProbe()
    let recorder = MeetingTitleEventRecorder(completion: completion)
    let queue = MeetingTitleQueue(
      generateTitle: { transcript, _ in
        await generator.generate(for: transcript)
      },
      eventHandler: { event in
        recorder.handle(event)
      }
    )

    await queue.enqueue(firstJob)
    await queue.enqueue(firstJob)
    await queue.enqueue(secondJob)
    await queue.resumeProcessing()

    await fulfillment(of: [completion], timeout: 2)
    let snapshot = await generator.snapshot()
    XCTAssertEqual(snapshot.callCount, 2)
    XCTAssertEqual(snapshot.maximumConcurrentCalls, 1)
    XCTAssertEqual(recorder.titles.count, 2)
  }
}

private actor MeetingTitleGenerationProbe {
  private var activeCalls = 0
  private var callCount = 0
  private var maximumConcurrentCalls = 0

  func generate(for transcript: String) async -> String? {
    activeCalls += 1
    callCount += 1
    maximumConcurrentCalls = max(maximumConcurrentCalls, activeCalls)
    try? await Task.sleep(for: .milliseconds(30))
    activeCalls -= 1
    return transcript.hasPrefix("First") ? "First title" : "Second title"
  }

  func snapshot() -> (callCount: Int, maximumConcurrentCalls: Int) {
    (callCount, maximumConcurrentCalls)
  }
}

@MainActor
private final class MeetingTitleEventRecorder {
  private let completion: XCTestExpectation
  private(set) var titles: [String] = []

  init(completion: XCTestExpectation) {
    self.completion = completion
  }

  func handle(_ event: MeetingTitleQueueEvent) {
    switch event {
    case .completed(_, _, let title):
      titles.append(title)
      completion.fulfill()
    }
  }
}
