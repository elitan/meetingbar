import Foundation
import Observation
import SwiftData

enum MeetingRetentionPolicy {
  static let allowedDays = 1...3650

  static func isExpired(_ recording: Recording, days: Int, now: Date) -> Bool {
    guard allowedDays.contains(days), let endedAt = recording.endedAt,
      recording.status != .transcribing
    else { return false }
    return endedAt.addingTimeInterval(Double(days) * 86_400) <= now
  }
}

@MainActor
@Observable
final class MeetingRetentionPreferences {
  private(set) var isEnabled: Bool
  private(set) var days: Int
  @ObservationIgnored private let defaults: UserDefaults

  init(userDefaults: UserDefaults = .standard) {
    defaults = userDefaults
    let storedDays = userDefaults.integer(forKey: "MeetingRetentionDays")
    let valid = MeetingRetentionPolicy.allowedDays.contains(storedDays)
    days = valid ? storedDays : 30
    // Invalid persisted settings must never silently enable destructive cleanup.
    isEnabled = valid && userDefaults.bool(forKey: "MeetingRetentionEnabled")
  }

  func update(enabled: Bool, days: Int) {
    guard MeetingRetentionPolicy.allowedDays.contains(days) else { return }
    self.days = days
    isEnabled = enabled
    defaults.set(days, forKey: "MeetingRetentionDays")
    defaults.set(enabled, forKey: "MeetingRetentionEnabled")
  }
}

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
