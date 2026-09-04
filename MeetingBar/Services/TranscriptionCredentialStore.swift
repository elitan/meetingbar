import Foundation

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
  case invalidStoredSecret

  var errorDescription: String? {
    switch self {
    case .unsupportedProvider:
      "This transcription provider does not use an API key."
    case .emptySecret:
      "Enter an API key before saving."
    case .invalidStoredSecret:
      "The locally stored API key could not be read. Save it again in Settings."
    }
  }
}

struct LocalTranscriptionSecretStore: TranscriptionSecretStoring {
  private let directoryURL: URL

  init(rootURL: URL) {
    directoryURL = rootURL.appending(path: "Credentials", directoryHint: .isDirectory)
  }

  func secret(for provider: TranscriptionProvider) throws -> String? {
    guard let credentialFileName = provider.credentialAccount else {
      return nil
    }
    let fileURL = credentialURL(fileName: credentialFileName)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return nil
    }
    let data = try Data(contentsOf: fileURL)
    guard let value = String(data: data, encoding: .utf8), !value.isEmpty else {
      throw TranscriptionCredentialError.invalidStoredSecret
    }
    return value
  }

  func saveSecret(_ secret: String, for provider: TranscriptionProvider) throws {
    guard let credentialFileName = provider.credentialAccount else {
      throw TranscriptionCredentialError.unsupportedProvider
    }
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw TranscriptionCredentialError.emptySecret
    }
    let fileManager = FileManager.default
    try ensurePrivateDirectory(fileManager: fileManager)
    let fileURL = credentialURL(fileName: credentialFileName)
    try Data(trimmed.utf8).write(to: fileURL, options: .atomic)
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o600))],
      ofItemAtPath: fileURL.path
    )
    try excludeFromBackup(fileURL)
  }

  func removeSecret(for provider: TranscriptionProvider) throws {
    guard let credentialFileName = provider.credentialAccount else {
      throw TranscriptionCredentialError.unsupportedProvider
    }
    let fileURL = credentialURL(fileName: credentialFileName)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return
    }
    try FileManager.default.removeItem(at: fileURL)
  }

  private func credentialURL(fileName: String) -> URL {
    directoryURL.appending(path: fileName)
  }

  private func ensurePrivateDirectory(fileManager: FileManager) throws {
    try fileManager.createDirectory(
      at: directoryURL,
      withIntermediateDirectories: true,
      attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
    )
    try fileManager.setAttributes(
      [.posixPermissions: NSNumber(value: Int16(0o700))],
      ofItemAtPath: directoryURL.path
    )
    try excludeFromBackup(directoryURL)
  }

  private func excludeFromBackup(_ url: URL) throws {
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    var mutableURL = url
    try mutableURL.setResourceValues(values)
  }
}
