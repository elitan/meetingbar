import Foundation
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
