import Foundation
import Observation

enum TranscriptionProvider: String, CaseIterable, Identifiable, Sendable {
  case onDevice
  case elevenLabs

  var id: String { rawValue }

  var label: String {
    switch self {
    case .onDevice:
      "On this Mac"
    case .elevenLabs:
      "ElevenLabs"
    }
  }

  var detail: String {
    switch self {
    case .onDevice:
      "Private and offline with WhisperKit"
    case .elevenLabs:
      "Cloud transcription with Scribe"
    }
  }

  var credentialAccount: String? {
    switch self {
    case .onDevice:
      nil
    case .elevenLabs:
      "elevenlabs-api-key"
    }
  }

  var usesCloud: Bool {
    self == .elevenLabs
  }
}

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

enum ElevenLabsTranscriptionModel: String, CaseIterable, Identifiable, Sendable {
  case scribeV2

  var id: String { rawValue }

  var label: String {
    switch self {
    case .scribeV2:
      "Scribe v2"
    }
  }

  var detail: String {
    switch self {
    case .scribeV2:
      "Best batch accuracy with language detection and speaker separation"
    }
  }

  var modelIdentifier: String {
    switch self {
    case .scribeV2:
      "scribe_v2"
    }
  }
}

struct TranscriptionConfiguration: Hashable, Sendable {
  let provider: TranscriptionProvider
  let language: TranscriptionLanguagePreference
  let quality: TranscriptionQuality
  let elevenLabsModel: ElevenLabsTranscriptionModel

  init(
    provider: TranscriptionProvider = .onDevice,
    language: TranscriptionLanguagePreference,
    quality: TranscriptionQuality,
    elevenLabsModel: ElevenLabsTranscriptionModel = .scribeV2
  ) {
    self.provider = provider
    self.language = language
    self.quality = quality
    self.elevenLabsModel = elevenLabsModel
  }

  var modelIdentifier: String {
    switch provider {
    case .onDevice:
      quality.modelIdentifier
    case .elevenLabs:
      elevenLabsModel.modelIdentifier
    }
  }

  var modelLabel: String {
    switch provider {
    case .onDevice:
      quality.label
    case .elevenLabs:
      elevenLabsModel.label
    }
  }

  var modelDetail: String {
    switch provider {
    case .onDevice:
      quality.detail
    case .elevenLabs:
      elevenLabsModel.detail
    }
  }
}

@MainActor
@Observable
final class TranscriptionPreferenceStore {
  private(set) var provider: TranscriptionProvider
  private(set) var language: TranscriptionLanguagePreference
  private(set) var quality: TranscriptionQuality
  private(set) var elevenLabsModel: ElevenLabsTranscriptionModel
  private(set) var hasElevenLabsAPIKey: Bool
  private(set) var needsElevenLabsAPIKeyResave: Bool

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let secretStore: any TranscriptionSecretStoring
  @ObservationIgnored private let providerKey = "TranscriptionProvider"
  @ObservationIgnored private let languageKey = "TranscriptionLanguagePreference"
  @ObservationIgnored private let qualityKey = "TranscriptionQuality"
  @ObservationIgnored private let elevenLabsModelKey = "ElevenLabsTranscriptionModel"
  @ObservationIgnored private let elevenLabsCredentialKey = "HasLocalElevenLabsAPIKey"
  @ObservationIgnored private let legacyElevenLabsCredentialKey = "HasElevenLabsAPIKey"

  var configuration: TranscriptionConfiguration {
    TranscriptionConfiguration(
      provider: provider,
      language: language,
      quality: quality,
      elevenLabsModel: elevenLabsModel
    )
  }

  init(
    userDefaults: UserDefaults = .standard,
    secretStore: any TranscriptionSecretStoring
  ) {
    self.userDefaults = userDefaults
    self.secretStore = secretStore
    let storedProvider =
      TranscriptionProvider(
        rawValue: userDefaults.string(forKey: providerKey) ?? ""
      ) ?? .onDevice
    provider = storedProvider
    language =
      TranscriptionLanguagePreference(
        rawValue: userDefaults.string(forKey: languageKey) ?? ""
      ) ?? .automatic
    quality =
      TranscriptionQuality(
        rawValue: userDefaults.string(forKey: qualityKey) ?? ""
      ) ?? .bestAccuracy
    elevenLabsModel =
      ElevenLabsTranscriptionModel(
        rawValue: userDefaults.string(forKey: elevenLabsModelKey) ?? ""
      ) ?? .scribeV2
    let hasLocalCredential = userDefaults.bool(forKey: elevenLabsCredentialKey)
    hasElevenLabsAPIKey = hasLocalCredential
    needsElevenLabsAPIKeyResave =
      !hasLocalCredential && userDefaults.bool(forKey: legacyElevenLabsCredentialKey)
  }

  func setProvider(_ provider: TranscriptionProvider) {
    self.provider = provider
    userDefaults.set(provider.rawValue, forKey: providerKey)
  }

  func setLanguage(_ language: TranscriptionLanguagePreference) {
    self.language = language
    userDefaults.set(language.rawValue, forKey: languageKey)
  }

  func setQuality(_ quality: TranscriptionQuality) {
    self.quality = quality
    userDefaults.set(quality.rawValue, forKey: qualityKey)
  }

  func setElevenLabsModel(_ model: ElevenLabsTranscriptionModel) {
    elevenLabsModel = model
    userDefaults.set(model.rawValue, forKey: elevenLabsModelKey)
  }

  func saveElevenLabsAPIKey(_ apiKey: String) throws {
    try secretStore.saveSecret(apiKey, for: .elevenLabs)
    hasElevenLabsAPIKey = true
    needsElevenLabsAPIKeyResave = false
    userDefaults.set(true, forKey: elevenLabsCredentialKey)
    userDefaults.set(false, forKey: legacyElevenLabsCredentialKey)
  }

  func removeElevenLabsAPIKey() throws {
    try secretStore.removeSecret(for: .elevenLabs)
    hasElevenLabsAPIKey = false
    needsElevenLabsAPIKeyResave = false
    userDefaults.set(false, forKey: elevenLabsCredentialKey)
    userDefaults.set(false, forKey: legacyElevenLabsCredentialKey)
  }

  func markElevenLabsAPIKeyUnavailable() {
    hasElevenLabsAPIKey = false
    userDefaults.set(false, forKey: elevenLabsCredentialKey)
  }
}
