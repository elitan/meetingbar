import Foundation
import XCTest

@testable import MeetingBar

@MainActor
final class TranscriptionPreferenceStoreTests: XCTestCase {
  func testDefaultsToBestAccuracyAndAutomaticLanguage() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }

    let store = TranscriptionPreferenceStore(userDefaults: fixture.defaults)

    XCTAssertEqual(store.quality, .bestAccuracy)
    XCTAssertEqual(store.language, .automatic)
  }

  func testLanguageAndQualityPersistAcrossRelaunch() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let store = TranscriptionPreferenceStore(userDefaults: fixture.defaults)
    store.setLanguage(.swedish)
    store.setQuality(.compact)

    let relaunched = TranscriptionPreferenceStore(userDefaults: fixture.defaults)

    XCTAssertEqual(relaunched.language, .swedish)
    XCTAssertEqual(relaunched.quality, .compact)
    XCTAssertEqual(relaunched.configuration.modelIdentifier, "large-v3-v20240930_626MB")
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
