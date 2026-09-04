import Foundation
import XCTest

@testable import MeetingBar

@MainActor
final class TranscriptionPreferenceStoreTests: XCTestCase {
  func testDefaultsToBestAccuracyAndAutomaticLanguage() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

    let store = TranscriptionPreferenceStore(
      userDefaults: fixture.defaults,
      secretStore: InMemoryTranscriptionSecretStore()
    )

    XCTAssertEqual(store.provider, .onDevice)
    XCTAssertEqual(store.quality, .bestAccuracy)
    XCTAssertEqual(store.language, .automatic)
    XCTAssertFalse(store.hasElevenLabsAPIKey)
  }

  func testInitializationNeverReadsKeychainBeforeTheAppIsReady() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    fixture.defaults.set(
      TranscriptionProvider.elevenLabs.rawValue,
      forKey: "TranscriptionProvider"
    )
    let secrets = TranscriptionSecretStoreSpy()

    let store = TranscriptionPreferenceStore(
      userDefaults: fixture.defaults,
      secretStore: secrets
    )

    XCTAssertTrue(store.hasElevenLabsAPIKey)
    XCTAssertEqual(secrets.readCount, 0)
  }

  func testProviderLanguageAndModelsPersistAcrossRelaunch() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let secrets = InMemoryTranscriptionSecretStore()
    let store = TranscriptionPreferenceStore(
      userDefaults: fixture.defaults,
      secretStore: secrets
    )
    store.setProvider(.elevenLabs)
    store.setLanguage(.swedish)
    store.setQuality(.compact)
    store.setElevenLabsModel(.scribeV2)
    try? store.saveElevenLabsAPIKey("test-secret")

    let relaunched = TranscriptionPreferenceStore(
      userDefaults: fixture.defaults,
      secretStore: secrets
    )

    XCTAssertEqual(relaunched.provider, .elevenLabs)
    XCTAssertEqual(relaunched.language, .swedish)
    XCTAssertEqual(relaunched.quality, .compact)
    XCTAssertEqual(relaunched.elevenLabsModel, .scribeV2)
    XCTAssertEqual(relaunched.configuration.modelIdentifier, "scribe_v2")
    XCTAssertTrue(relaunched.hasElevenLabsAPIKey)
    XCTAssertFalse(fixture.defaults.dictionaryRepresentation().values.contains { value in
      (value as? String) == "test-secret"
    })
  }

  func testEachProviderKeepsItsOwnModelSelection() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let store = TranscriptionPreferenceStore(
      userDefaults: fixture.defaults,
      secretStore: InMemoryTranscriptionSecretStore()
    )

    store.setQuality(.compact)
    XCTAssertEqual(store.configuration.modelIdentifier, "large-v3-v20240930_626MB")

    store.setProvider(.elevenLabs)
    XCTAssertEqual(store.configuration.modelIdentifier, "scribe_v2")

    store.setProvider(.onDevice)
    XCTAssertEqual(store.configuration.modelIdentifier, "large-v3-v20240930_626MB")
  }

  func testRemovingCloudKeyUpdatesCredentialState() throws {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let store = TranscriptionPreferenceStore(
      userDefaults: fixture.defaults,
      secretStore: InMemoryTranscriptionSecretStore()
    )

    try store.saveElevenLabsAPIKey("secret")
    XCTAssertTrue(store.hasElevenLabsAPIKey)

    try store.removeElevenLabsAPIKey()
    XCTAssertFalse(store.hasElevenLabsAPIKey)
  }

  private func makeDefaults() -> (defaults: UserDefaults, suiteName: String) {
    let suiteName = "MeetingBarTests.\(UUID().uuidString)"
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      fatalError("Could not create isolated test defaults")
    }
    defaults.removePersistentDomain(forName: suiteName)
    return (defaults, suiteName)
  }
}

private final class InMemoryTranscriptionSecretStore: TranscriptionSecretStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var secrets: [TranscriptionProvider: String] = [:]

  func secret(for provider: TranscriptionProvider) throws -> String? {
    lock.withLock { secrets[provider] }
  }

  func saveSecret(_ secret: String, for provider: TranscriptionProvider) throws {
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw TranscriptionCredentialError.emptySecret
    }
    lock.withLock {
      secrets[provider] = trimmed
    }
  }

  func removeSecret(for provider: TranscriptionProvider) throws {
    lock.withLock {
      secrets.removeValue(forKey: provider)
    }
  }
}

private final class TranscriptionSecretStoreSpy: TranscriptionSecretStoring,
  @unchecked Sendable
{
  private let lock = NSLock()
  private var reads = 0

  var readCount: Int {
    lock.withLock { reads }
  }

  func secret(for provider: TranscriptionProvider) throws -> String? {
    lock.withLock {
      reads += 1
    }
    return nil
  }

  func saveSecret(_ secret: String, for provider: TranscriptionProvider) throws {}

  func removeSecret(for provider: TranscriptionProvider) throws {}
}
