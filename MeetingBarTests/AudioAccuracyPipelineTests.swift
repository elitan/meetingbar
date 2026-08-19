import Foundation
import XCTest

@testable import MeetingBar

final class AudioAccuracyPipelineTests: XCTestCase {
  func testSignalAnalyzerDistinguishesSilenceQuietAndHealthySpeechLevels() {
    var silenceAnalyzer = AudioSignalAnalyzer()
    silenceAnalyzer.append([Float](repeating: 0, count: 16_000))
    XCTAssertTrue(silenceAnalyzer.summary().isEffectivelySilent)

    var quietAnalyzer = AudioSignalAnalyzer()
    quietAnalyzer.append([Float](repeating: 0.01, count: 16_000))
    let quiet = quietAnalyzer.summary()
    XCTAssertTrue(quiet.isQuietForSpeechRecognition)
    XCTAssertEqual(quiet.speechRMSDBFS, -40, accuracy: 0.1)

    var healthyAnalyzer = AudioSignalAnalyzer()
    healthyAnalyzer.append([Float](repeating: 0.1, count: 16_000))
    let healthy = healthyAnalyzer.summary()
    XCTAssertFalse(healthy.isQuietForSpeechRecognition)
    XCTAssertEqual(healthy.speechRMSDBFS, -20, accuracy: 0.1)
    XCTAssertTrue(healthyAnalyzer.analysis().activity.hasSpeechActivity(from: 0, to: 1))
  }

  func testAutomaticGainAdaptsToEveryRecordedInputLevel() {
    func signal(at speechRMSDBFS: Double) -> AudioSignalSummary {
      AudioSignalSummary(
        durationSeconds: 10,
        peakDBFS: min(-1, speechRMSDBFS + 12),
        overallRMSDBFS: speechRMSDBFS - 3,
        speechRMSDBFS: speechRMSDBFS,
        activeFrameFraction: 0.5
      )
    }

    XCTAssertEqual(
      TranscriptionAudioPreprocessor.recommendedGainDB(for: signal(at: -50)),
      18,
      accuracy: 0.1
    )
    XCTAssertEqual(
      TranscriptionAudioPreprocessor.recommendedGainDB(for: signal(at: -38)),
      18,
      accuracy: 0.1
    )
    XCTAssertEqual(
      TranscriptionAudioPreprocessor.recommendedGainDB(for: signal(at: -30)),
      10,
      accuracy: 0.1
    )
    XCTAssertEqual(
      TranscriptionAudioPreprocessor.recommendedGainDB(for: signal(at: -24)),
      4,
      accuracy: 0.1
    )
    XCTAssertEqual(
      TranscriptionAudioPreprocessor.recommendedGainDB(for: signal(at: -20)),
      0,
      accuracy: 0.1
    )
    XCTAssertEqual(
      TranscriptionAudioPreprocessor.recommendedGainDB(for: signal(at: -10)),
      0,
      accuracy: 0.1
    )
  }

  func testActivityTimelineRejectsSilentTailButKeepsSpeech() {
    var analyzer = AudioSignalAnalyzer()
    analyzer.append([Float](repeating: 0.1, count: 8_000))
    analyzer.append([Float](repeating: 0, count: 8_000))
    let timeline = analyzer.analysis().activity

    XCTAssertTrue(timeline.hasSpeechActivity(from: 0, to: 0.5))
    XCTAssertFalse(timeline.hasSpeechActivity(from: 0.5, to: 1))
  }

  func testActivityTimelineTreatsConstantQuietSpeechAsActive() {
    var analyzer = AudioSignalAnalyzer()
    analyzer.append([Float](repeating: 0.01, count: 16_000))
    let timeline = analyzer.analysis().activity

    XCTAssertTrue(timeline.hasSpeechActivity(from: 0, to: 1))
  }

  func testActivityTimelineKeepsVeryQuietSpeechWithAUsablePeak() {
    var analyzer = AudioSignalAnalyzer()
    let samples = (0..<16_000).map { index in
      Float(sin(Double(index) * 0.1) * 0.0012)
    }
    analyzer.append(samples)
    let analysis = analyzer.analysis()

    XCTAssertFalse(analysis.summary.isEffectivelySilent)
    XCTAssertTrue(analysis.activity.hasSpeechActivity(from: 0, to: 1))
  }

  func testTimestampedWriterInsertsSilenceForMissingSourceTime() throws {
    let fixture = try makeWriterFixture()
    defer { try? FileManager.default.removeItem(at: fixture.directory) }
    let writer = TimestampedPCM16WAVWriter(kind: .microphone, writer: fixture.writer)

    try writer.append(samples: [Float](repeating: 0.1, count: 160), presentationTimeSeconds: 100)
    try writer.append(samples: [Float](repeating: 0.1, count: 160), presentationTimeSeconds: 100.02)
    let result = try writer.finish()

    XCTAssertEqual(result.durationSeconds, 0.03, accuracy: 0.0001)
    XCTAssertEqual(result.firstPresentationTimeSeconds, 100)
  }

  func testQuietAudioIsRaisedForTranscriptionWithoutChangingSource() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appending(path: "microphone.wav")
    let writer = try PCM16WAVWriter(
      partialURL: directory.appending(path: "microphone.partial.wav"),
      finalURL: sourceURL
    )
    try writer.append(floatSamples: [Float](repeating: 0.01, count: 16_000))
    _ = try writer.finish()
    let originalData = try Data(contentsOf: sourceURL)
    let source = TranscriptionSource(
      kind: .microphone,
      audioURL: sourceURL,
      offsetSeconds: 0,
      signal: nil
    )

    let preprocessor = TranscriptionAudioPreprocessor()
    let prepared = try preprocessor.prepare(source)
    defer {
      if let temporaryURL = prepared.temporaryURL {
        try? FileManager.default.removeItem(at: temporaryURL)
      }
    }

    XCTAssertTrue(prepared.shouldTranscribe)
    XCTAssertEqual(prepared.appliedGainDB, 18, accuracy: 0.1)
    XCTAssertNotNil(prepared.temporaryURL)
    XCTAssertEqual(try Data(contentsOf: sourceURL), originalData)
    let normalizedSignal = try preprocessor.analyze(url: prepared.audioURL)
    XCTAssertEqual(normalizedSignal.speechRMSDBFS, -22, accuracy: 0.5)
  }

  func testDigitalSilenceIsSkippedWithoutCreatingDerivedAudio() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appending(path: "system.wav")
    let writer = try PCM16WAVWriter(
      partialURL: directory.appending(path: "system.partial.wav"),
      finalURL: sourceURL
    )
    try writer.append(floatSamples: [Float](repeating: 0, count: 16_000))
    _ = try writer.finish()

    let prepared = try TranscriptionAudioPreprocessor().prepare(
      TranscriptionSource(
        kind: .system,
        audioURL: sourceURL,
        offsetSeconds: 0,
        signal: nil
      )
    )

    XCTAssertFalse(prepared.shouldTranscribe)
    XCTAssertNil(prepared.temporaryURL)
  }

  func testPreprocessorReadsWAVWithMetadataChunk() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let canonicalURL = directory.appending(path: "canonical.wav")
    let writer = try PCM16WAVWriter(
      partialURL: directory.appending(path: "canonical.partial.wav"),
      finalURL: canonicalURL
    )
    try writer.append(floatSamples: [Float](repeating: 0.1, count: 16_000))
    _ = try writer.finish()

    var canonical = try Data(contentsOf: canonicalURL)
    let audioData = canonical.subdata(in: 44..<canonical.count)
    canonical.removeSubrange(36..<canonical.count)
    canonical.replaceUInt32LittleEndian(at: 4, with: UInt32(36 + 12 + audioData.count))
    canonical.append(Data("JUNK".utf8))
    canonical.appendUInt32LittleEndian(4)
    canonical.append(Data("test".utf8))
    canonical.append(Data("data".utf8))
    canonical.appendUInt32LittleEndian(UInt32(audioData.count))
    canonical.append(audioData)
    let metadataURL = directory.appending(path: "metadata.wav")
    try canonical.write(to: metadataURL)

    let signal = try TranscriptionAudioPreprocessor().analyze(url: metadataURL)
    XCTAssertEqual(signal.durationSeconds, 1, accuracy: 0.001)
    XCTAssertEqual(signal.speechRMSDBFS, -20, accuracy: 0.1)
  }

  func testCaptureManifestSelectsSeparateSourcesAndFallsBackForLegacyAudio() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RecordingFileStore(rootURL: directory)
    let id = UUID()
    try store.prepareDirectory(for: id)
    let fallbackURL = store.audioURL(for: id)
    try Data().write(to: fallbackURL)
    let microphoneURL = store.sourceAudioURL(for: id, kind: .microphone)
    try Data().write(to: microphoneURL)
    let signal = AudioSignalSummary(
      durationSeconds: 2,
      peakDBFS: -10,
      overallRMSDBFS: -25,
      speechRMSDBFS: -20,
      activeFrameFraction: 0.5
    )
    try store.writeCaptureManifest(
      CaptureSourceManifest(
        microphoneID: "preferred",
        microphoneName: "Preferred mic",
        sources: [
          CaptureSourceRecord(
            kind: .microphone,
            fileName: microphoneURL.lastPathComponent,
            offsetSeconds: 0.15,
            durationSeconds: 2,
            signal: signal
          )
        ]
      ),
      for: id
    )

    let incompleteSources = store.transcriptionSources(for: id, fallbackAudioURL: fallbackURL)
    XCTAssertEqual(incompleteSources.map(\.audioURL), [fallbackURL])

    let systemURL = store.sourceAudioURL(for: id, kind: .system)
    try Data().write(to: systemURL)
    try store.writeCaptureManifest(
      CaptureSourceManifest(
        microphoneID: "preferred",
        microphoneName: "Preferred mic",
        sources: [
          CaptureSourceRecord(
            kind: .microphone,
            fileName: microphoneURL.lastPathComponent,
            offsetSeconds: 0.15,
            durationSeconds: 2,
            signal: signal
          ),
          CaptureSourceRecord(
            kind: .system,
            fileName: systemURL.lastPathComponent,
            offsetSeconds: 0,
            durationSeconds: 2,
            signal: signal
          ),
        ]
      ),
      for: id
    )

    let sources = store.transcriptionSources(for: id, fallbackAudioURL: fallbackURL)
    XCTAssertEqual(sources.count, 2)
    XCTAssertEqual(sources.first(where: { $0.kind == .microphone })?.audioURL, microphoneURL)
    XCTAssertEqual(sources.first(where: { $0.kind == .microphone })?.offsetSeconds, 0.15)

    try FileManager.default.removeItem(at: store.captureManifestURL(for: id))
    let legacySources = store.transcriptionSources(for: id, fallbackAudioURL: fallbackURL)
    XCTAssertEqual(legacySources.map(\.audioURL), [fallbackURL])
  }

  func testPostprocessorRemovesCrossSourceEchoButKeepsDistinctOverlappingSpeech() {
    let microphone = SourceTranscriptSegment(
      source: .microphone,
      start: 4,
      end: 6,
      text: "We should ship the new version tomorrow",
      averageLogProbability: -0.3,
      noSpeechProbability: 0
    )
    let systemEcho = SourceTranscriptSegment(
      source: .system,
      start: 4.1,
      end: 6.1,
      text: "we should ship the new version tomorrow",
      averageLogProbability: -0.1,
      noSpeechProbability: 0
    )
    let otherSpeaker = SourceTranscriptSegment(
      source: .microphone,
      start: 4.2,
      end: 5,
      text: "Yes tomorrow works",
      averageLogProbability: -0.2,
      noSpeechProbability: 0
    )

    let merged = TranscriptionPostprocessor.mergeAndDeduplicate([
      microphone,
      systemEcho,
      otherSpeaker,
    ])

    XCTAssertEqual(merged.count, 2)
    XCTAssertTrue(merged.contains(where: { $0.source == .system }))
    XCTAssertTrue(merged.contains(where: { $0.text == otherSpeaker.text }))
  }

  func testPostprocessorDoesNotDropAContainedButLongerUtterance() {
    let short = SourceTranscriptSegment(
      source: .microphone,
      start: 10,
      end: 10.5,
      text: "Yes",
      averageLogProbability: -0.1,
      noSpeechProbability: 0
    )
    let longer = SourceTranscriptSegment(
      source: .system,
      start: 10,
      end: 11,
      text: "Yes I completely agree",
      averageLogProbability: -0.1,
      noSpeechProbability: 0
    )

    let merged = TranscriptionPostprocessor.mergeAndDeduplicate([short, longer])

    XCTAssertEqual(merged.count, 2)
  }

  @MainActor
  func testInAppPlaybackLoadsRetainedWAV() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let audioURL = directory.appending(path: "audio.wav")
    let writer = try PCM16WAVWriter(
      partialURL: directory.appending(path: "audio.partial.wav"),
      finalURL: audioURL
    )
    let samples = (0..<16_000).map { index in
      Float(sin(Double(index) * 0.1) * 0.1)
    }
    try writer.append(floatSamples: samples)
    _ = try writer.finish()

    let playback = AudioPlaybackController()
    playback.prepare(url: audioURL)

    XCTAssertNil(playback.errorMessage)
    XCTAssertEqual(playback.duration, 1, accuracy: 0.01)
    playback.unload()
  }

  func testPlaybackBalancesQuietMicrophoneWithoutChangingRawSources() throws {
    let directory = try makeTemporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = try RecordingFileStore(rootURL: directory)
    let recordingID = UUID()
    try store.prepareDirectory(for: recordingID)

    let microphoneURL = store.sourceAudioURL(for: recordingID, kind: .microphone)
    let microphoneWriter = try PCM16WAVWriter(
      partialURL: store.partialSourceAudioURL(for: recordingID, kind: .microphone),
      finalURL: microphoneURL
    )
    try microphoneWriter.append(floatSamples: [Float](repeating: 0.01, count: 16_000))
    _ = try microphoneWriter.finish()
    let originalMicrophoneData = try Data(contentsOf: microphoneURL)

    let systemURL = store.sourceAudioURL(for: recordingID, kind: .system)
    let systemWriter = try PCM16WAVWriter(
      partialURL: store.partialSourceAudioURL(for: recordingID, kind: .system),
      finalURL: systemURL
    )
    try systemWriter.append(floatSamples: [Float](repeating: 0, count: 16_000))
    _ = try systemWriter.finish()

    let microphoneSignal = AudioSignalSummary(
      durationSeconds: 1,
      peakDBFS: -40,
      overallRMSDBFS: -40,
      speechRMSDBFS: -40,
      activeFrameFraction: 1
    )
    let silentSignal = AudioSignalSummary(
      durationSeconds: 1,
      peakDBFS: -120,
      overallRMSDBFS: -120,
      speechRMSDBFS: -120,
      activeFrameFraction: 0
    )
    try store.writeCaptureManifest(
      CaptureSourceManifest(
        microphoneID: "studio-microphone",
        microphoneName: "Studio microphone",
        sources: [
          CaptureSourceRecord(
            kind: .microphone,
            fileName: microphoneURL.lastPathComponent,
            offsetSeconds: 0,
            durationSeconds: 1,
            signal: microphoneSignal
          ),
          CaptureSourceRecord(
            kind: .system,
            fileName: systemURL.lastPathComponent,
            offsetSeconds: 0,
            durationSeconds: 1,
            signal: silentSignal
          ),
        ]
      ),
      for: recordingID
    )

    let prepared = try PlaybackAudioProcessor().prepare(
      recordingID: recordingID,
      fallbackAudioURL: microphoneURL,
      fileStore: store
    )

    XCTAssertEqual(try XCTUnwrap(prepared.microphoneGainDB), 18, accuracy: 0.1)
    XCTAssertNil(prepared.systemGainDB)
    XCTAssertEqual(try Data(contentsOf: microphoneURL), originalMicrophoneData)
    let playbackSignal = try TranscriptionAudioPreprocessor().analyze(url: prepared.audioURL)
    XCTAssertEqual(playbackSignal.speechRMSDBFS, -22, accuracy: 0.5)
    XCTAssertEqual(prepared.enhancementDescription, "Balanced playback: microphone +18 dB")
  }

  private func makeWriterFixture() throws -> (
    directory: URL,
    writer: PCM16WAVWriter
  ) {
    let directory = try makeTemporaryDirectory()
    return (
      directory,
      try PCM16WAVWriter(
        partialURL: directory.appending(path: "audio.partial.wav"),
        finalURL: directory.appending(path: "audio.wav")
      )
    )
  }

  private func makeTemporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

extension Data {
  fileprivate mutating func appendUInt32LittleEndian(_ value: UInt32) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
  }

  fileprivate mutating func replaceUInt32LittleEndian(at offset: Int, with value: UInt32) {
    var littleEndian = value.littleEndian
    Swift.withUnsafeBytes(of: &littleEndian) { bytes in
      replaceSubrange(offset..<(offset + 4), with: bytes)
    }
  }
}
