import Foundation

enum CaptureSourceKind: String, Codable, CaseIterable, Sendable {
  case microphone
  case system

  var transcriptOrder: Int {
    switch self {
    case .microphone:
      0
    case .system:
      1
    }
  }
}

struct AudioSignalSummary: Codable, Hashable, Sendable {
  let durationSeconds: Double
  let peakDBFS: Double
  let overallRMSDBFS: Double
  let speechRMSDBFS: Double
  let activeFrameFraction: Double

  var isEffectivelySilent: Bool {
    durationSeconds < 0.25 || (peakDBFS < -60 && speechRMSDBFS < -65)
  }

  var isQuietForSpeechRecognition: Bool {
    !isEffectivelySilent && speechRMSDBFS < -35
  }
}

struct CaptureSourceRecord: Codable, Equatable, Sendable {
  let kind: CaptureSourceKind
  let fileName: String
  let offsetSeconds: Double
  let durationSeconds: Double
  let signal: AudioSignalSummary
}

struct CaptureSourceManifest: Codable, Equatable, Sendable {
  static let currentVersion = 1

  let version: Int
  let microphoneID: String?
  let microphoneName: String?
  let sources: [CaptureSourceRecord]

  init(
    microphoneID: String?,
    microphoneName: String?,
    sources: [CaptureSourceRecord]
  ) {
    version = Self.currentVersion
    self.microphoneID = microphoneID
    self.microphoneName = microphoneName
    self.sources = sources
  }
}

struct TranscriptionSource: Hashable, Sendable {
  let kind: CaptureSourceKind
  let audioURL: URL
  let offsetSeconds: Double
  let signal: AudioSignalSummary?
}

struct FinalizedCaptureSource: Sendable {
  let kind: CaptureSourceKind
  let audioURL: URL
  let firstPresentationTimeSeconds: Double?
  let durationSeconds: Double
  let signal: AudioSignalSummary
}
