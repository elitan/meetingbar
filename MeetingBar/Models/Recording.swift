import Foundation
import SwiftData

enum RecordingStatus: String, Codable, CaseIterable, Sendable {
  case queued
  case transcribing
  case ready
  case failed

  var label: String {
    switch self {
    case .queued:
      "Queued"
    case .transcribing:
      "Transcribing"
    case .ready:
      "Ready"
    case .failed:
      "Failed"
    }
  }
}

@Model
final class Recording {
  @Attribute(.unique) var id: UUID
  var title: String
  var isPinned: Bool = false
  var startedAt: Date
  var endedAt: Date?
  var durationSeconds: Double
  var statusRawValue: String
  var transcript: String
  var detectedLanguage: String?
  var modelIdentifier: String?
  var captureWarnings: [String]
  var audioRelativePath: String?
  var audioExpiresAt: Date?
  var audioDeletedAt: Date?
  var wasRecovered: Bool
  var errorMessage: String?
  var createdAt: Date
  var updatedAt: Date

  init(
    id: UUID = UUID(),
    title: String,
    isPinned: Bool = false,
    startedAt: Date = .now,
    endedAt: Date? = nil,
    durationSeconds: Double = 0,
    status: RecordingStatus = .queued,
    transcript: String = "",
    detectedLanguage: String? = nil,
    modelIdentifier: String? = nil,
    captureWarnings: [String] = [],
    audioRelativePath: String? = nil,
    audioExpiresAt: Date? = nil,
    audioDeletedAt: Date? = nil,
    wasRecovered: Bool = false,
    errorMessage: String? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.title = title
    self.isPinned = isPinned
    self.startedAt = startedAt
    self.endedAt = endedAt
    self.durationSeconds = durationSeconds
    self.statusRawValue = status.rawValue
    self.transcript = transcript
    self.detectedLanguage = detectedLanguage
    self.modelIdentifier = modelIdentifier
    self.captureWarnings = captureWarnings
    self.audioRelativePath = audioRelativePath
    self.audioExpiresAt = audioExpiresAt
    self.audioDeletedAt = audioDeletedAt
    self.wasRecovered = wasRecovered
    self.errorMessage = errorMessage
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  var status: RecordingStatus {
    get { RecordingStatus(rawValue: statusRawValue) ?? .failed }
    set {
      statusRawValue = newValue.rawValue
      updatedAt = .now
    }
  }

  var isCapturing: Bool {
    endedAt == nil && audioRelativePath == nil
  }
}
