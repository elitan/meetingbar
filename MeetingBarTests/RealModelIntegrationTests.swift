import Foundation
import FoundationModels
import SpeakerKit
import WhisperKit
import XCTest

@testable import MeetingBar

final class RealModelIntegrationTests: XCTestCase {
  func testDownloadSelectedModel() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MEETINGBAR_DOWNLOAD_MODEL"] == "1" else {
      throw XCTSkip("Set MEETINGBAR_DOWNLOAD_MODEL=1 to download a benchmark model.")
    }
    guard let downloadBase = environment["MEETINGBAR_DOWNLOAD_BASE"] else {
      XCTFail("Set MEETINGBAR_DOWNLOAD_BASE.")
      return
    }
    let modelIdentifier =
      environment["MEETINGBAR_MODEL_IDENTIFIER"]
      ?? TranscriptionQueue.recommendedModelIdentifier
    let progressReporter = ModelDownloadProgressReporter()
    let folder = try await WhisperKit.download(
      variant: modelIdentifier,
      downloadBase: URL(filePath: downloadBase, directoryHint: .isDirectory),
      progressCallback: { progress in
        progressReporter.report(progress.fractionCompleted)
      }
    )
    print("Downloaded model to \(folder.path)")
    XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
  }

  func testPublicSwedishAndEnglishFixturesStayWithinMeasuredWER() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MEETINGBAR_RUN_MODEL_TESTS"] == "1" else {
      throw XCTSkip("Set MEETINGBAR_RUN_MODEL_TESTS=1 to run the public-fixture WER suite.")
    }
    guard let manifestPath = environment["MEETINGBAR_EVALUATION_MANIFEST"],
      let modelPath = environment["MEETINGBAR_MODEL_PATH"]
    else {
      XCTFail("Set MEETINGBAR_EVALUATION_MANIFEST and MEETINGBAR_MODEL_PATH.")
      return
    }

    let modelIdentifier =
      environment["MEETINGBAR_MODEL_IDENTIFIER"]
      ?? TranscriptionQueue.recommendedModelIdentifier
    let usesFixtureLanguage = environment["MEETINGBAR_LANGUAGE_MODE"] == "fixture"
    let printsSegments = environment["MEETINGBAR_PRINT_SEGMENTS"] == "1"
    let manifestURL = URL(filePath: manifestPath)
    let manifest = try JSONDecoder().decode(
      EvaluationFixtureManifest.self,
      from: Data(contentsOf: manifestURL)
    )
    let configuration = WhisperKitConfig(
      model: modelIdentifier,
      modelFolder: modelPath,
      verbose: false,
      prewarm: true,
      load: true,
      download: false
    )
    let whisperKit = try await WhisperKit(configuration)
    let preprocessor = TranscriptionAudioPreprocessor()
    var totalsByLanguage: [String: (edits: Int, words: Int)] = [:]

    for fixture in manifest.fixtures {
      let audioURL = manifestURL.deletingLastPathComponent().appending(path: fixture.audioPath)
      XCTAssertTrue(
        FileManager.default.fileExists(atPath: audioURL.path),
        "Missing fixture: \(fixture.audioPath)"
      )
      let source = TranscriptionSource(
        kind: .microphone,
        audioURL: audioURL,
        offsetSeconds: 0,
        signal: nil
      )
      let prepared = try preprocessor.prepare(source)
      defer {
        if let temporaryURL = prepared.temporaryURL {
          try? FileManager.default.removeItem(at: temporaryURL)
        }
      }
      let results = try await whisperKit.transcribe(
        audioPath: prepared.audioURL.path,
        audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
        decodeOptions: TranscriptionQueue.decodeOptions(
          for: TranscriptionConfiguration(
            language: usesFixtureLanguage
              ? languagePreference(for: fixture.language)
              : .automatic,
            quality: .bestAccuracy
          )
        )
      )
      let segments = TranscriptionPostprocessor.sourceSegments(
        from: results,
        source: source,
        activity: prepared.activity
      )
      let hypothesis = TranscriptionQueue.normalize(segments.map(\.text).joined(separator: " "))
      let measurement = WordErrorRate.measure(
        reference: fixture.reference,
        hypothesis: hypothesis
      )
      let existing = totalsByLanguage[fixture.language] ?? (0, 0)
      totalsByLanguage[fixture.language] = (
        existing.edits + measurement.edits,
        existing.words + measurement.referenceWordCount
      )
      print(
        "WER \(fixture.id) [\(fixture.language)] "
          + String(format: "%.1f%%", measurement.rate * 100)
          + " | hypothesis: \(hypothesis)"
      )
      if printsSegments {
        for segment in results.flatMap(\.segments) {
          print(
            String(
              format: "  %.2f-%.2f logp %.2f noSpeech %.2f | %@",
              segment.start,
              segment.end,
              segment.avgLogprob,
              segment.noSpeechProb,
              segment.text
            )
          )
        }
      }
      if let maximumWER = fixture.maximumWER {
        XCTAssertLessThanOrEqual(
          measurement.rate,
          maximumWER,
          "\(fixture.id) regressed: \(hypothesis)"
        )
      }
    }

    for language in totalsByLanguage.keys.sorted() {
      guard let total = totalsByLanguage[language], total.words > 0 else {
        continue
      }
      let rate = Double(total.edits) / Double(total.words)
      print("Aggregate WER [\(language)]: \(String(format: "%.1f%%", rate * 100))")
      if !usesFixtureLanguage,
        manifest.dataset.hasPrefix("google/fleurs"),
        let maximumWER = maximumAggregateWER(
          modelIdentifier: modelIdentifier,
          language: language
        )
      {
        XCTAssertLessThanOrEqual(
          rate,
          maximumWER,
          "Aggregate \(language) WER regressed for \(modelIdentifier)."
        )
      }
    }
    for language in Set(manifest.fixtures.map(\.language)) {
      XCTAssertNotNil(totalsByLanguage[language])
    }
  }

  func testPublicAMIFixtureDetectsMultipleSpeakers() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MEETINGBAR_RUN_SPEAKER_TESTS"] == "1" else {
      throw XCTSkip("Set MEETINGBAR_RUN_SPEAKER_TESTS=1 to run the public AMI diarization suite.")
    }
    guard let audioPath = environment["MEETINGBAR_SPEAKER_AUDIO_PATH"],
      let downloadBase = environment["MEETINGBAR_SPEAKER_DOWNLOAD_BASE"]
    else {
      XCTFail("Set MEETINGBAR_SPEAKER_AUDIO_PATH and MEETINGBAR_SPEAKER_DOWNLOAD_BASE.")
      return
    }

    let speakerKit = try await SpeakerKit(
      PyannoteConfig(
        downloadBase: downloadBase,
        download: true,
        load: false,
        verbose: false
      )
    )
    let audio = try AudioProcessor.loadAudioAsFloatArray(fromPath: audioPath)
    let diarization = try await speakerKit.diarize(audioArray: audio)

    print("AMI speakers detected: \(diarization.speakerCount)")
    for segment in diarization.segments {
      print(segment)
    }
    XCTAssertGreaterThanOrEqual(diarization.speakerCount, 2)
    XCTAssertLessThanOrEqual(diarization.speakerCount, 4)
    let openingSpeaker = try XCTUnwrap(
      diarization.segments.first(where: { $0.startTime <= 10 && $0.endTime >= 10 })?
        .speaker.speakerId
    )
    let closingSpeaker = try XCTUnwrap(
      diarization.segments.first(where: { $0.startTime <= 45 && $0.endTime >= 45 })?
        .speaker.speakerId
    )
    XCTAssertNotEqual(openingSpeaker, closingSpeaker)
    let handoffDistance = zip(diarization.segments, diarization.segments.dropFirst())
      .filter { pair in pair.0.speaker.speakerId != pair.1.speaker.speakerId }
      .map { pair in abs(Double(pair.0.endTime) - 30.64) }
      .min()
    XCTAssertLessThanOrEqual(try XCTUnwrap(handoffDistance), 2)
    XCTAssertGreaterThan(
      diarization.segments.reduce(0.0) { duration, segment in
        duration + Double(segment.endTime - segment.startTime)
      },
      20
    )
  }

  @MainActor
  func testPublicAMIFixtureProducesSpeakerPrefixedTranscriptEndToEnd() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MEETINGBAR_RUN_PIPELINE_TESTS"] == "1" else {
      throw XCTSkip("Set MEETINGBAR_RUN_PIPELINE_TESTS=1 to run the complete public AMI pipeline.")
    }
    guard let audioPath = environment["MEETINGBAR_PIPELINE_AUDIO_PATH"],
      let modelPath = environment["MEETINGBAR_MODEL_PATH"],
      let modelsRoot = environment["MEETINGBAR_PIPELINE_MODELS_ROOT"]
    else {
      XCTFail(
        "Set MEETINGBAR_PIPELINE_AUDIO_PATH, MEETINGBAR_MODEL_PATH, and MEETINGBAR_PIPELINE_MODELS_ROOT."
      )
      return
    }

    let modelIdentifier =
      environment["MEETINGBAR_MODEL_IDENTIFIER"]
      ?? TranscriptionQuality.compact.modelIdentifier
    let defaultsKey = "WhisperKitModelFolder.\(modelIdentifier)"
    let previousModelPath = UserDefaults.standard.string(forKey: defaultsKey)
    UserDefaults.standard.set(modelPath, forKey: defaultsKey)
    defer {
      if let previousModelPath {
        UserDefaults.standard.set(previousModelPath, forKey: defaultsKey)
      } else {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
      }
    }

    let completion = expectation(description: "Complete transcription with speaker labels")
    let recorder = PipelineEventRecorder(completion: completion)
    let queue = TranscriptionQueue(
      modelsURL: URL(filePath: modelsRoot, directoryHint: .isDirectory)
    ) { event in
      recorder.handle(event)
    }
    let quality: TranscriptionQuality =
      modelIdentifier == TranscriptionQuality.compact.modelIdentifier ? .compact : .bestAccuracy
    await queue.enqueue(
      TranscriptionJob(
        recordingID: UUID(),
        sources: [
          TranscriptionSource(
            kind: .microphone,
            audioURL: URL(filePath: audioPath),
            offsetSeconds: 0,
            signal: nil
          )
        ],
        configuration: TranscriptionConfiguration(language: .automatic, quality: quality)
      )
    )

    await fulfillment(of: [completion], timeout: 180)
    if let failure = recorder.failure {
      XCTFail(failure)
      return
    }
    let transcript = try XCTUnwrap(recorder.transcript)
    let speakerLabels = Set(
      transcript.split(separator: "\n").compactMap { rawLine -> String? in
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard line.hasPrefix("Speaker "), let colon = line.firstIndex(of: ":") else {
          return nil
        }
        return String(line[..<colon])
      }
    )
    print("End-to-end speaker transcript:\n\(transcript)")
    XCTAssertGreaterThanOrEqual(speakerLabels.count, 2)
    XCTAssertTrue(recorder.warnings.isEmpty)
    XCTAssertEqual(recorder.language, "en")
  }

  func testSystemModelGeneratesGroundedSwedishAndEnglishTitles() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MEETINGBAR_RUN_TITLE_TESTS"] == "1" else {
      throw XCTSkip("Set MEETINGBAR_RUN_TITLE_TESTS=1 to run the on-device title suite.")
    }
    guard case .available = SystemLanguageModel.default.availability else {
      throw XCTSkip("The on-device system language model is unavailable on this Mac.")
    }

    let fixtures = [
      (
        language: "sv",
        transcript:
          "Vi gick igenom nästa version av MeetingBar och bestämde att biblioteket ska få automatiska korta titlar. Titlarna ska skapas lokalt efter transkriberingen och manuella namn får aldrig skrivas över."
      ),
      (
        language: "en",
        transcript:
          "We reviewed the MeetingBar library and agreed to add short automatic titles after transcription. Everything should run locally, and a title typed by the user must never be overwritten."
      ),
    ]

    for fixture in fixtures {
      let clock = ContinuousClock()
      let startedAt = clock.now
      let title = await MeetingTitleGenerator.generateTitle(
        transcript: fixture.transcript,
        detectedLanguage: fixture.language
      )
      let elapsed = startedAt.duration(to: clock.now)
      let generatedTitle = try XCTUnwrap(title)
      print("Generated title [\(fixture.language)] in \(elapsed): \(generatedTitle)")
      XCTAssertLessThanOrEqual(generatedTitle.count, MeetingTitleGenerator.maximumTitleCharacters)
      XCTAssertLessThanOrEqual(
        generatedTitle.split(separator: " ").count,
        MeetingTitleGenerator.maximumTitleWords
      )
      XCTAssertFalse(generatedTitle.contains("\n"))
      XCTAssertLessThan(elapsed, .seconds(10))
    }
  }

  private func languagePreference(
    for language: String
  ) -> TranscriptionLanguagePreference {
    language.hasPrefix("sv") ? .swedish : .english
  }

  private func maximumAggregateWER(
    modelIdentifier: String,
    language: String
  ) -> Double? {
    switch (modelIdentifier, language) {
    case (TranscriptionQuality.bestAccuracy.modelIdentifier, "sv_se"):
      0.16
    case (TranscriptionQuality.bestAccuracy.modelIdentifier, "en_us"):
      0.09
    case (TranscriptionQuality.compact.modelIdentifier, "sv_se"):
      0.18
    case (TranscriptionQuality.compact.modelIdentifier, "en_us"):
      0.08
    default:
      nil
    }
  }
}

@MainActor
private final class PipelineEventRecorder {
  private let completion: XCTestExpectation
  private(set) var transcript: String?
  private(set) var language: String?
  private(set) var warnings: [String] = []
  private(set) var failure: String?

  init(completion: XCTestExpectation) {
    self.completion = completion
  }

  func handle(_ event: TranscriptionQueueEvent) {
    switch event {
    case .completed(_, let transcript, let language, _, let warnings):
      self.transcript = transcript
      self.language = language
      self.warnings = warnings
      completion.fulfill()
    case .failed(_, let message):
      failure = message
      completion.fulfill()
    default:
      break
    }
  }
}

private final class ModelDownloadProgressReporter: @unchecked Sendable {
  private let lock = NSLock()
  private var lastReportedPercent = -1

  func report(_ fraction: Double) {
    lock.lock()
    defer { lock.unlock() }
    let percent = Int(fraction * 100)
    guard percent >= lastReportedPercent + 5 else {
      return
    }
    lastReportedPercent = percent
    print("Model download \(percent)%")
  }
}
