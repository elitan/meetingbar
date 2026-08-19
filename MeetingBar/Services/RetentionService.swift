import Foundation
import SwiftData

struct RetentionCandidate: Sendable {
  let endedAt: Date?
  let status: RecordingStatus
  let hasAudio: Bool
  let audioDeletedAt: Date?
}

@MainActor
final class RetentionService {
  nonisolated static let retentionInterval: TimeInterval = 30 * 24 * 60 * 60

  private let modelContext: ModelContext
  private let fileStore: RecordingFileStore

  init(modelContext: ModelContext, fileStore: RecordingFileStore) {
    self.modelContext = modelContext
    self.fileStore = fileStore
  }

  nonisolated static func isEligible(_ candidate: RetentionCandidate, now: Date) -> Bool {
    guard candidate.status == .ready,
      candidate.hasAudio,
      candidate.audioDeletedAt == nil,
      let endedAt = candidate.endedAt
    else {
      return false
    }
    return now.timeIntervalSince(endedAt) >= retentionInterval
  }

  func run(now: Date = .now, fileManager: FileManager = .default) throws {
    let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
    for recording in recordings {
      let candidate = RetentionCandidate(
        endedAt: recording.endedAt,
        status: recording.status,
        hasAudio: recording.audioRelativePath != nil,
        audioDeletedAt: recording.audioDeletedAt
      )
      guard Self.isEligible(candidate, now: now), recording.audioRelativePath != nil else {
        continue
      }

      try fileStore.deleteRecordingFiles(for: recording.id, fileManager: fileManager)
      recording.audioRelativePath = nil
      recording.audioDeletedAt = now
      recording.updatedAt = now
    }
    try modelContext.save()
  }
}
