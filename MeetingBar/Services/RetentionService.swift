import Foundation
import SwiftData

@MainActor
final class AudioPreservationService {
  private let modelContext: ModelContext

  init(modelContext: ModelContext) {
    self.modelContext = modelContext
  }

  @discardableResult
  func clearLegacyExpiryDates(now: Date = .now) throws -> Int {
    let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
    let scheduled = recordings.filter { $0.audioExpiresAt != nil }
    for recording in scheduled {
      recording.audioExpiresAt = nil
      recording.updatedAt = now
    }
    if !scheduled.isEmpty {
      try modelContext.save()
    }
    return scheduled.count
  }
}
