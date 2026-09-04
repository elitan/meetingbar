import Foundation
import Security

protocol TranscriptionSecretStoring: Sendable {
  func secret(for provider: TranscriptionProvider) throws -> String?
  func saveSecret(_ secret: String, for provider: TranscriptionProvider) throws
  func removeSecret(for provider: TranscriptionProvider) throws
}

struct EmptyTranscriptionSecretStore: TranscriptionSecretStoring {
  func secret(for provider: TranscriptionProvider) throws -> String? {
    nil
  }

  func saveSecret(_ secret: String, for provider: TranscriptionProvider) throws {}

  func removeSecret(for provider: TranscriptionProvider) throws {}
}

enum TranscriptionCredentialError: LocalizedError, Sendable {
  case unsupportedProvider
  case emptySecret
  case keychain(OSStatus)

  var errorDescription: String? {
    switch self {
    case .unsupportedProvider:
      "This transcription provider does not use an API key."
    case .emptySecret:
      "Enter an API key before saving."
    case .keychain(let status):
      if let message = SecCopyErrorMessageString(status, nil) as String? {
        "The API key could not be stored in Keychain: \(message)"
      } else {
        "The API key could not be stored in Keychain (\(status))."
      }
    }
  }
}

struct KeychainTranscriptionSecretStore: TranscriptionSecretStoring {
  private let service = "me.eliasson.meetingbar.transcription"

  func secret(for provider: TranscriptionProvider) throws -> String? {
    guard let account = provider.credentialAccount else {
      return nil
    }
    var query = baseQuery(account: account)
    query[kSecReturnData as String] = true
    query[kSecMatchLimit as String] = kSecMatchLimitOne

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecItemNotFound {
      return nil
    }
    guard status == errSecSuccess else {
      throw TranscriptionCredentialError.keychain(status)
    }
    guard let data = item as? Data, let value = String(data: data, encoding: .utf8) else {
      throw TranscriptionCredentialError.keychain(errSecDecode)
    }
    return value
  }

  func saveSecret(_ secret: String, for provider: TranscriptionProvider) throws {
    guard let account = provider.credentialAccount else {
      throw TranscriptionCredentialError.unsupportedProvider
    }
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw TranscriptionCredentialError.emptySecret
    }
    let data = Data(trimmed.utf8)
    let query = baseQuery(account: account)
    let attributes = [kSecValueData as String: data]
    let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
    if updateStatus == errSecSuccess {
      return
    }
    guard updateStatus == errSecItemNotFound else {
      throw TranscriptionCredentialError.keychain(updateStatus)
    }

    var newItem = query
    newItem[kSecValueData as String] = data
    newItem[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    let addStatus = SecItemAdd(newItem as CFDictionary, nil)
    guard addStatus == errSecSuccess else {
      throw TranscriptionCredentialError.keychain(addStatus)
    }
  }

  func removeSecret(for provider: TranscriptionProvider) throws {
    guard let account = provider.credentialAccount else {
      throw TranscriptionCredentialError.unsupportedProvider
    }
    let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
    guard status == errSecSuccess || status == errSecItemNotFound else {
      throw TranscriptionCredentialError.keychain(status)
    }
  }

  private func baseQuery(account: String) -> [String: Any] {
    [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
  }
}
