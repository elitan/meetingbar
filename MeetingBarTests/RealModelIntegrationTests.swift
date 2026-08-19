import Foundation
import WhisperKit
import XCTest
@testable import MeetingBar

final class RealModelIntegrationTests: XCTestCase {
  func testSwedishEnglishSilenceAndLongFixturesWithRealModel() async throws {
    let environment = ProcessInfo.processInfo.environment
    guard environment["MEETINGBAR_RUN_MODEL_TESTS"] == "1" else {
      throw XCTSkip("Set MEETINGBAR_RUN_MODEL_TESTS=1 to run the 626 MB real-model suite.")
    }
    guard let fixturesPath = environment["MEETINGBAR_AUDIO_FIXTURES"],
      let modelPath = environment["MEETINGBAR_MODEL_PATH"]
    else {
      XCTFail("Set MEETINGBAR_AUDIO_FIXTURES and MEETINGBAR_MODEL_PATH.")
      return
    }

    let configuration = WhisperKitConfig(
      model: TranscriptionQueue.modelIdentifier,
      modelFolder: modelPath,
      verbose: false,
      prewarm: true,
      load: true,
      download: false
    )
    let whisperKit = try await WhisperKit(configuration)
    let fixtureNames = ["swedish.wav", "english.wav", "silence.wav", "long-bilingual.wav"]
    for name in fixtureNames {
      let path = URL(filePath: fixturesPath).appending(path: name).path
      XCTAssertTrue(FileManager.default.fileExists(atPath: path), "Missing fixture: \(name)")
      _ = try await whisperKit.transcribe(
        audioPath: path,
        audioInputOptions: AudioInputOptions(audioLoadingMode: .incremental),
        decodeOptions: DecodingOptions(
          language: nil,
          detectLanguage: true,
          skipSpecialTokens: true,
          chunkingStrategy: .vad
        )
      )
    }
  }
}
