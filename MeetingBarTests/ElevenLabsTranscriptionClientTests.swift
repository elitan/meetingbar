import Foundation
import XCTest

@testable import MeetingBar

final class ElevenLabsTranscriptionClientTests: XCTestCase {
  func testUploadUsesSavedKeyAndSelectedConfiguration() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MeetingBarElevenLabsTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = try makeAudioFile(in: directory)
    let secrets = ClientTestSecretStore(secret: "secure-test-key")
    let responseData = Data(
      """
      {
        "language_code": "sv",
        "language_probability": 0.99,
        "transcription_id": "transcript-123",
        "text": "Hej världen",
        "words": [
          {"text":"Hej", "start":0.0, "end":0.3, "type":"word", "speaker_id":"speaker_0", "logprob":-0.1},
          {"text":" ", "type":"spacing"},
          {"text":"världen", "start":0.4, "end":0.9, "type":"word", "speaker_id":"speaker_0", "logprob":-0.2}
        ]
      }
      """.utf8
    )
    let transport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(data: responseData, statusCode: 200)
    )
    let client = ElevenLabsTranscriptionClient(
      endpoint: URL(string: "https://example.test/v1/speech-to-text")!,
      secretStore: secrets,
      transport: transport,
      temporaryDirectory: directory
    )
    let configuration = TranscriptionConfiguration(
      provider: .elevenLabs,
      language: .swedish,
      quality: .bestAccuracy,
      elevenLabsModel: .scribeV2
    )

    let response = try await client.transcribe(
      audioURL: audioURL,
      configuration: configuration
    )

    XCTAssertEqual(response.text, "Hej världen")
    XCTAssertEqual(response.languageCode, "sv")
    XCTAssertEqual(response.transcriptionID, "transcript-123")
    let uploaded = await transport.capturedUpload()
    let captured = try XCTUnwrap(uploaded)
    XCTAssertEqual(captured.request.value(forHTTPHeaderField: "xi-api-key"), "secure-test-key")
    XCTAssertEqual(captured.request.httpMethod, "POST")
    let body = String(decoding: captured.body, as: UTF8.self)
    XCTAssertTrue(body.contains("name=\"model_id\"\r\n\r\nscribe_v2"))
    XCTAssertTrue(body.contains("name=\"language_code\"\r\n\r\nsv"))
    XCTAssertTrue(body.contains("name=\"diarize\"\r\n\r\ntrue"))
    XCTAssertTrue(body.contains("name=\"timestamps_granularity\"\r\n\r\nword"))
    XCTAssertTrue(body.contains("filename=\"microphone.wav\""))
    XCTAssertFalse(body.contains("secure-test-key"))
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
      .filter { $0.hasSuffix(".multipart") }
    XCTAssertTrue(leftovers.isEmpty)
  }

  func testMissingAPIKeyFailsBeforeUpload() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MeetingBarElevenLabsTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(data: Data(), statusCode: 200)
    )
    let client = ElevenLabsTranscriptionClient(
      secretStore: ClientTestSecretStore(secret: nil),
      transport: transport,
      temporaryDirectory: directory
    )

    do {
      _ = try await client.transcribe(
        audioURL: try makeAudioFile(in: directory),
        configuration: TranscriptionConfiguration(
          provider: .elevenLabs,
          language: .automatic,
          quality: .bestAccuracy
        )
      )
      XCTFail("Expected a missing-key error")
    } catch let error as ElevenLabsTranscriptionError {
      guard case .missingAPIKey = error else {
        XCTFail("Unexpected error: \(error)")
        return
      }
    }
    let upload = await transport.capturedUpload()
    XCTAssertNil(upload)
  }

  func testServiceErrorUsesElevenLabsMessage() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MeetingBarElevenLabsTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let transport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(
        data: Data(
          """
          {"detail":{"status":"invalid_api_key","message":"Invalid API key"}}
          """.utf8
        ),
        statusCode: 401
      )
    )
    let client = ElevenLabsTranscriptionClient(
      secretStore: ClientTestSecretStore(secret: "bad-key"),
      transport: transport,
      temporaryDirectory: directory
    )

    do {
      _ = try await client.transcribe(
        audioURL: try makeAudioFile(in: directory),
        configuration: TranscriptionConfiguration(
          provider: .elevenLabs,
          language: .automatic,
          quality: .bestAccuracy
        )
      )
      XCTFail("Expected a service error")
    } catch {
      XCTAssertTrue(error.localizedDescription.contains("Invalid API key"))
      XCTAssertTrue(error.localizedDescription.contains("401"))
    }
  }

  func testDeleteUsesTranscriptEndpointAndSavedKey() async throws {
    let transport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(data: Data(), statusCode: 200),
      sendResponse: ElevenLabsHTTPResponse(data: Data(), statusCode: 204)
    )
    let client = ElevenLabsTranscriptionClient(
      endpoint: URL(string: "https://example.test/v1/speech-to-text")!,
      secretStore: ClientTestSecretStore(secret: "secure-test-key"),
      transport: transport
    )

    try await client.deleteTranscript(id: "transcript-123")

    let requests = await transport.capturedRequests()
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(request.httpMethod, "DELETE")
    XCTAssertEqual(request.url?.absoluteString, "https://example.test/v1/speech-to-text/transcripts/transcript-123")
    XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "secure-test-key")
  }

  func testCloudAudioPreparerCreatesOneBalancedAlignedMonoFile() throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MeetingBarElevenLabsMixTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let microphoneURL = try makeAudioFile(
      in: directory,
      name: "microphone",
      samples: [Float](repeating: 0.1, count: 16_000)
    )
    let systemURL = try makeAudioFile(
      in: directory,
      name: "system",
      samples: [Float](repeating: 0.1, count: 16_000)
    )
    let originalMicrophoneData = try Data(contentsOf: microphoneURL)
    let originalSystemData = try Data(contentsOf: systemURL)
    let prepared = try XCTUnwrap(
      ElevenLabsAudioPreparer().prepare(
        sources: [
          TranscriptionSource(
            kind: .microphone,
            audioURL: microphoneURL,
            offsetSeconds: 0,
            signal: nil
          ),
          TranscriptionSource(
            kind: .system,
            audioURL: systemURL,
            offsetSeconds: 0.25,
            signal: nil
          ),
        ],
        temporaryDirectory: directory
      )
    )
    defer { prepared.removeTemporaryFiles() }

    XCTAssertEqual(prepared.durationSeconds, 1.25, accuracy: 0.001)
    let samples = try readAllSamples(from: prepared.audioURL)
    XCTAssertEqual(samples.count, 20_000)
    XCTAssertEqual(Double(samples[1_000]) / 32_768, 0.1, accuracy: 0.01)
    XCTAssertEqual(Double(samples[8_000]) / 32_768, sqrt(0.02), accuracy: 0.01)
    XCTAssertEqual(Double(samples[18_000]) / 32_768, 0.1, accuracy: 0.01)
    XCTAssertEqual(try Data(contentsOf: microphoneURL), originalMicrophoneData)
    XCTAssertEqual(try Data(contentsOf: systemURL), originalSystemData)
  }

  @MainActor
  func testQueueUploadsTwoSourcesOnceThenDeletesRemoteTranscript() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MeetingBarElevenLabsQueueTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let microphoneURL = try makeAudioFile(
      in: directory,
      name: "microphone",
      samples: [Float](repeating: 0.1, count: 16_000)
    )
    let systemURL = try makeAudioFile(
      in: directory,
      name: "system",
      samples: [Float](repeating: 0.1, count: 16_000)
    )
    let responseData = Data(
      """
      {
        "language_code": "en",
        "language_probability": 0.99,
        "transcription_id": "transcript-merged",
        "text": "Hello there",
        "words": [
          {"text":"Hello", "start":0.0, "end":0.3, "type":"word", "speaker_id":"speaker_0"},
          {"text":" ", "type":"spacing"},
          {"text":"there", "start":0.4, "end":0.8, "type":"word", "speaker_id":"speaker_0"}
        ]
      }
      """.utf8
    )
    let transport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(data: responseData, statusCode: 200),
      sendResponse: ElevenLabsHTTPResponse(data: Data(), statusCode: 204)
    )
    let completion = expectation(description: "Cloud transcript completes")
    let recorder = CloudQueueEventRecorder(completion: completion)
    let queue = TranscriptionQueue(
      modelsURL: directory.appending(path: "Models", directoryHint: .isDirectory),
      secretStore: ClientTestSecretStore(secret: "secure-test-key"),
      elevenLabsTransport: transport,
      elevenLabsCleanupURL: directory.appending(path: "cleanup.json")
    ) { event in
      recorder.handle(event)
      return true
    }
    let recordingID = UUID()

    await queue.enqueue(
      TranscriptionJob(
        recordingID: recordingID,
        sources: [
          TranscriptionSource(
            kind: .microphone,
            audioURL: microphoneURL,
            offsetSeconds: 0,
            signal: nil
          ),
          TranscriptionSource(
            kind: .system,
            audioURL: systemURL,
            offsetSeconds: 0.25,
            signal: nil
          ),
        ],
        configuration: TranscriptionConfiguration(
          provider: .elevenLabs,
          language: .automatic,
          quality: .bestAccuracy
        )
      )
    )

    await fulfillment(of: [completion], timeout: 3)
    await transport.waitForDeletionRequest()

    let uploads = await transport.capturedUploads()
    let deletionRequests = await transport.capturedRequests()
    XCTAssertEqual(uploads.count, 1)
    XCTAssertEqual(deletionRequests.count, 1)
    XCTAssertEqual(deletionRequests[0].httpMethod, "DELETE")
    XCTAssertTrue(deletionRequests[0].url?.path.hasSuffix("/transcripts/transcript-merged") == true)
    XCTAssertEqual(recorder.completedRecordingID, recordingID)
    XCTAssertEqual(recorder.transcript, "Hello there")
    XCTAssertTrue(recorder.warnings.isEmpty)

    let body = String(decoding: uploads[0].body, as: UTF8.self)
    XCTAssertEqual(body.components(separatedBy: "name=\"file\"").count - 1, 1)
  }

  func testTranscriptCleanupSurvivesFailureAndRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MeetingBarElevenLabsCleanupTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistenceURL = directory.appending(path: "cleanup.json")
    let secrets = ClientTestSecretStore(secret: "secure-test-key")
    let failingTransport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(data: Data(), statusCode: 200),
      sendResponse: ElevenLabsHTTPResponse(
        data: Data(#"{"detail":"temporary failure"}"#.utf8),
        statusCode: 503
      )
    )
    let firstQueue = ElevenLabsTranscriptCleanupQueue(
      client: ElevenLabsTranscriptionClient(
        secretStore: secrets,
        transport: failingTransport
      ),
      persistenceURL: persistenceURL
    )
    let recordingID = UUID()
    try await firstQueue.enqueue(
      transcriptionID: "transcript-retry",
      recordingID: recordingID
    )
    await firstQueue.processPendingNow()
    let unconfirmedRequests = await failingTransport.capturedRequests()
    XCTAssertTrue(unconfirmedRequests.isEmpty)
    try await firstQueue.confirmLocalTranscriptStored(recordingID: recordingID)
    await firstQueue.processPendingNow()
    let firstPending = await firstQueue.pendingDeletions()
    XCTAssertEqual(firstPending.count, 1)

    let successfulTransport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(data: Data(), statusCode: 200),
      sendResponse: ElevenLabsHTTPResponse(data: Data(), statusCode: 204)
    )
    let relaunchedQueue = ElevenLabsTranscriptCleanupQueue(
      client: ElevenLabsTranscriptionClient(
        secretStore: secrets,
        transport: successfulTransport
      ),
      persistenceURL: persistenceURL
    )
    let restoredPending = await relaunchedQueue.pendingDeletions()
    XCTAssertEqual(restoredPending.count, 1)
    await relaunchedQueue.processPendingNow()

    let finalPending = await relaunchedQueue.pendingDeletions()
    let deletionRequests = await successfulTransport.capturedRequests()
    XCTAssertTrue(finalPending.isEmpty)
    XCTAssertEqual(deletionRequests.count, 1)
  }

  func testCleanupReconcilesAStoredTranscriptAfterRelaunch() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(
      path: "MeetingBarElevenLabsReconciliationTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let recordingID = UUID()
    let transport = CapturingElevenLabsTransport(
      response: ElevenLabsHTTPResponse(data: Data(), statusCode: 200),
      sendResponse: ElevenLabsHTTPResponse(data: Data(), statusCode: 204)
    )
    let queue = ElevenLabsTranscriptCleanupQueue(
      client: ElevenLabsTranscriptionClient(
        secretStore: ClientTestSecretStore(secret: "secure-test-key"),
        transport: transport
      ),
      persistenceURL: directory.appending(path: "cleanup.json")
    )
    try await queue.enqueue(
      transcriptionID: "transcript-stored-before-crash",
      recordingID: recordingID
    )
    try await queue.enqueue(
      transcriptionID: "transcript-created-by-retry",
      recordingID: recordingID
    )

    try await queue.reconcileWithLocalRecordings(
      knownRecordingIDs: [recordingID],
      readyRecordingIDs: [recordingID]
    )
    await queue.processPendingNow()

    let pending = await queue.pendingDeletions()
    let requests = await transport.capturedRequests()
    XCTAssertTrue(pending.isEmpty)
    XCTAssertEqual(requests.count, 2)
  }

  func testResponseWordsBecomeTimestampedSpeakerSegments() {
    let response = ElevenLabsTranscriptResponse(
      languageCode: "en",
      languageProbability: 0.98,
      text: "Hello there. Hi back.",
      words: [
        word("Hello", start: 0, end: 0.3, speaker: "speaker_0"),
        word("there.", start: 0.4, end: 0.8, speaker: "speaker_0"),
        word("Hi", start: 1, end: 1.2, speaker: "speaker_1"),
        word("back.", start: 1.3, end: 1.7, speaker: "speaker_1"),
      ],
      transcriptionID: nil
    )
    let source = TranscriptionSource(
      kind: .system,
      audioURL: URL(filePath: "/tmp/system.wav"),
      offsetSeconds: 2.5,
      signal: nil
    )

    let segments = ElevenLabsTranscriptSegmentBuilder.segments(
      from: response,
      source: source,
      durationSeconds: 2
    )

    XCTAssertEqual(segments.count, 2)
    XCTAssertEqual(segments[0].text, "Hello there.")
    XCTAssertEqual(segments[0].start, 2.5, accuracy: 0.001)
    XCTAssertEqual(segments[0].speakerID, 0)
    XCTAssertEqual(segments[1].text, "Hi back.")
    XCTAssertEqual(segments[1].start, 3.5, accuracy: 0.001)
    XCTAssertEqual(segments[1].speakerID, 1)
  }

  private func makeAudioFile(in directory: URL) throws -> URL {
    try makeAudioFile(
      in: directory,
      name: "microphone",
      samples: [Float](repeating: 0.1, count: 1_600)
    )
  }

  private func makeAudioFile(
    in directory: URL,
    name: String,
    samples: [Float]
  ) throws -> URL {
    let finalURL = directory.appending(path: "\(name).wav")
    let writer = try PCM16WAVWriter(
      partialURL: directory.appending(path: "\(name).partial.wav"),
      finalURL: finalURL
    )
    try writer.append(floatSamples: samples)
    _ = try writer.finish()
    return finalURL
  }

  private func readAllSamples(from url: URL) throws -> [Int16] {
    let reader = try PCM16WAVReader(url: url)
    var samples: [Int16] = []
    while let chunk = try reader.readSamples(maxCount: 32_768) {
      samples.append(contentsOf: chunk)
    }
    return samples
  }

  private func word(
    _ text: String,
    start: Double,
    end: Double,
    speaker: String
  ) -> ElevenLabsTranscriptWord {
    ElevenLabsTranscriptWord(
      text: text,
      start: start,
      end: end,
      type: "word",
      speakerID: speaker,
      logProbability: -0.1
    )
  }
}

private actor CapturingElevenLabsTransport: ElevenLabsHTTPTransport {
  struct Upload: @unchecked Sendable {
    let request: URLRequest
    let body: Data
  }

  private let response: ElevenLabsHTTPResponse
  private let sendResponse: ElevenLabsHTTPResponse
  private var uploads: [Upload] = []
  private var requests: [URLRequest] = []
  private var deletionWaiters: [CheckedContinuation<Void, Never>] = []

  init(
    response: ElevenLabsHTTPResponse,
    sendResponse: ElevenLabsHTTPResponse = ElevenLabsHTTPResponse(
      data: Data(),
      statusCode: 200
    )
  ) {
    self.response = response
    self.sendResponse = sendResponse
  }

  func upload(_ request: URLRequest, fromFile bodyURL: URL) async throws
    -> ElevenLabsHTTPResponse
  {
    uploads.append(Upload(request: request, body: try Data(contentsOf: bodyURL)))
    return response
  }

  func capturedUpload() -> Upload? {
    uploads.last
  }

  func capturedUploads() -> [Upload] {
    uploads
  }

  func send(_ request: URLRequest) async throws -> ElevenLabsHTTPResponse {
    requests.append(request)
    let waiters = deletionWaiters
    deletionWaiters.removeAll()
    for waiter in waiters {
      waiter.resume()
    }
    return sendResponse
  }

  func capturedRequests() -> [URLRequest] {
    requests
  }

  func waitForDeletionRequest() async {
    guard requests.isEmpty else {
      return
    }
    await withCheckedContinuation { continuation in
      deletionWaiters.append(continuation)
    }
  }
}

@MainActor
private final class CloudQueueEventRecorder {
  private let completion: XCTestExpectation
  private(set) var completedRecordingID: UUID?
  private(set) var transcript: String?
  private(set) var warnings: [String] = []

  init(completion: XCTestExpectation) {
    self.completion = completion
  }

  func handle(_ event: TranscriptionQueueEvent) {
    switch event {
    case .completed(let id, let transcript, _, _, _, let warnings):
      completedRecordingID = id
      self.transcript = transcript
      self.warnings = warnings
      completion.fulfill()
    case .failed:
      completion.fulfill()
    default:
      break
    }
  }
}

private final class ClientTestSecretStore: TranscriptionSecretStoring, @unchecked Sendable {
  private let value: String?

  init(secret: String?) {
    value = secret
  }

  func secret(for provider: TranscriptionProvider) throws -> String? {
    provider == .elevenLabs ? value : nil
  }

  func saveSecret(_ secret: String, for provider: TranscriptionProvider) throws {}

  func removeSecret(for provider: TranscriptionProvider) throws {}
}
