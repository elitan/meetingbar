import Foundation
import Observation

@MainActor
@Observable
final class MeetingReminderPreferenceStore {
  private(set) var isEnabled: Bool
  private(set) var includesBrowsers: Bool

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let enabledKey = "OnlineMeetingRemindersEnabled"
  @ObservationIgnored private let includesBrowsersKey = "OnlineMeetingRemindersIncludeBrowsers"

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    isEnabled = Self.bool(forKey: enabledKey, defaultValue: true, in: userDefaults)
    includesBrowsers = Self.bool(
      forKey: includesBrowsersKey,
      defaultValue: true,
      in: userDefaults
    )
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    userDefaults.set(enabled, forKey: enabledKey)
  }

  func setIncludesBrowsers(_ includesBrowsers: Bool) {
    self.includesBrowsers = includesBrowsers
    userDefaults.set(includesBrowsers, forKey: includesBrowsersKey)
  }

  private static func bool(
    forKey key: String,
    defaultValue: Bool,
    in userDefaults: UserDefaults
  ) -> Bool {
    guard userDefaults.object(forKey: key) != nil else {
      return defaultValue
    }
    return userDefaults.bool(forKey: key)
  }
}
