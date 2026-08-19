import Foundation
import Observation

enum TranscriptionLanguagePreference: String, CaseIterable, Identifiable, Sendable {
  case automatic
  case swedish
  case english

  var id: String { rawValue }

  var label: String {
    switch self {
    case .automatic:
      "Automatic (Swedish and English)"
    case .swedish:
      "Swedish"
    case .english:
      "English"
    }
  }

  var whisperLanguageCode: String? {
    switch self {
    case .automatic:
      nil
    case .swedish:
      "sv"
    case .english:
      "en"
    }
  }
}

enum TranscriptionQuality: String, CaseIterable, Identifiable, Sendable {
  case bestAccuracy
  case compact

  var id: String { rawValue }

  var label: String {
    switch self {
    case .bestAccuracy:
      "Best accuracy"
    case .compact:
      "Compact"
    }
  }

  var detail: String {
    switch self {
    case .bestAccuracy:
      "Full multilingual Whisper large-v3 · about 3.1 GB"
    case .compact:
      "Compressed multilingual large-v3 · about 626 MB"
    }
  }

  var modelIdentifier: String {
    switch self {
    case .bestAccuracy:
      "large-v3"
    case .compact:
      "large-v3-v20240930_626MB"
    }
  }
}

struct TranscriptionConfiguration: Hashable, Sendable {
  let language: TranscriptionLanguagePreference
  let quality: TranscriptionQuality

  var modelIdentifier: String {
    quality.modelIdentifier
  }
}

@MainActor
@Observable
final class TranscriptionPreferenceStore {
  private(set) var language: TranscriptionLanguagePreference
  private(set) var quality: TranscriptionQuality

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let languageKey = "TranscriptionLanguagePreference"
  @ObservationIgnored private let qualityKey = "TranscriptionQuality"

  var configuration: TranscriptionConfiguration {
    TranscriptionConfiguration(language: language, quality: quality)
  }

  init(userDefaults: UserDefaults = .standard) {
    self.userDefaults = userDefaults
    language =
      TranscriptionLanguagePreference(
        rawValue: userDefaults.string(forKey: languageKey) ?? ""
      ) ?? .automatic
    quality =
      TranscriptionQuality(
        rawValue: userDefaults.string(forKey: qualityKey) ?? ""
      ) ?? .bestAccuracy
  }

  func setLanguage(_ language: TranscriptionLanguagePreference) {
    self.language = language
    userDefaults.set(language.rawValue, forKey: languageKey)
  }

  func setQuality(_ quality: TranscriptionQuality) {
    self.quality = quality
    userDefaults.set(quality.rawValue, forKey: qualityKey)
  }
}
