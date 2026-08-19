import Foundation
import XCTest
@testable import MeetingBar

@MainActor
final class MicrophonePreferenceStoreTests: XCTestCase {
  func testPriorityPersistsAcrossAppRestarts() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let provider = StubMicrophoneDeviceProvider(
      microphones: [
        ConnectedMicrophone(id: "built-in", name: "MacBook Pro Microphone"),
        ConnectedMicrophone(id: "rode", name: "RODE NT-USB"),
      ],
      defaultMicrophoneID: "built-in"
    )
    let store = MicrophonePreferenceStore(
      userDefaults: fixture.defaults,
      deviceProvider: provider,
      observesDeviceChanges: false
    )

    store.prioritize("rode")

    let relaunchedStore = MicrophonePreferenceStore(
      userDefaults: fixture.defaults,
      deviceProvider: provider,
      observesDeviceChanges: false
    )
    XCTAssertEqual(relaunchedStore.microphones.map(\.id), ["rode", "built-in"])
    XCTAssertEqual(relaunchedStore.activeMicrophoneID, "rode")
  }

  func testFallsBackAndReturnsToHigherPriorityMicrophoneWhenItReconnects() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let provider = StubMicrophoneDeviceProvider(
      microphones: [
        ConnectedMicrophone(id: "built-in", name: "MacBook Pro Microphone"),
        ConnectedMicrophone(id: "rode", name: "RODE NT-USB"),
      ],
      defaultMicrophoneID: "built-in"
    )
    let store = MicrophonePreferenceStore(
      userDefaults: fixture.defaults,
      deviceProvider: provider,
      observesDeviceChanges: false
    )
    store.prioritize("rode")

    provider.microphones = [
      ConnectedMicrophone(id: "built-in", name: "MacBook Pro Microphone")
    ]
    store.refreshDevices()
    XCTAssertEqual(store.activeMicrophoneID, "built-in")
    XCTAssertEqual(store.microphones.map(\.id), ["rode", "built-in"])
    XCTAssertFalse(store.microphones[0].isConnected)

    provider.microphones.append(ConnectedMicrophone(id: "rode", name: "RODE NT-USB"))
    store.refreshDevices()
    XCTAssertEqual(store.activeMicrophoneID, "rode")
    XCTAssertEqual(store.microphones.map(\.id), ["rode", "built-in"])
  }

  func testRemembersEverySeenMicrophoneUntilUnavailableDeviceIsForgotten() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let provider = StubMicrophoneDeviceProvider(
      microphones: [ConnectedMicrophone(id: "built-in", name: "Built-in")],
      defaultMicrophoneID: "built-in"
    )
    let store = MicrophonePreferenceStore(
      userDefaults: fixture.defaults,
      deviceProvider: provider,
      observesDeviceChanges: false
    )

    provider.microphones.append(ConnectedMicrophone(id: "headset", name: "Headset"))
    store.refreshDevices()
    provider.microphones.removeAll { $0.id == "headset" }
    store.refreshDevices()

    XCTAssertEqual(store.microphones.map(\.id), ["built-in", "headset"])
    XCTAssertEqual(store.unavailableMicrophones.map(\.id), ["headset"])

    store.forget("headset")
    XCTAssertEqual(store.microphones.map(\.id), ["built-in"])
  }

  func testReorderingUnavailableMicrophonePreservesAutomaticReturnPriority() {
    let fixture = makeDefaults()
    defer { fixture.defaults.removePersistentDomain(forName: fixture.suiteName) }
    let provider = StubMicrophoneDeviceProvider(
      microphones: [
        ConnectedMicrophone(id: "built-in", name: "Built-in"),
        ConnectedMicrophone(id: "headset", name: "Headset"),
      ],
      defaultMicrophoneID: "built-in"
    )
    let store = MicrophonePreferenceStore(
      userDefaults: fixture.defaults,
      deviceProvider: provider,
      observesDeviceChanges: false
    )
    provider.microphones.removeAll { $0.id == "headset" }
    store.refreshDevices()

    store.prioritize("headset")
    XCTAssertEqual(store.microphones.map(\.id), ["headset", "built-in"])
    XCTAssertEqual(store.activeMicrophoneID, "built-in")

    provider.microphones.append(ConnectedMicrophone(id: "headset", name: "Headset"))
    store.refreshDevices()
    XCTAssertEqual(store.activeMicrophoneID, "headset")
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

@MainActor
private final class StubMicrophoneDeviceProvider: MicrophoneDeviceProviding {
  var microphones: [ConnectedMicrophone]
  var selectedDefaultMicrophoneID: String?

  init(
    microphones: [ConnectedMicrophone],
    defaultMicrophoneID: String?
  ) {
    self.microphones = microphones
    selectedDefaultMicrophoneID = defaultMicrophoneID
  }

  func connectedMicrophones() -> [ConnectedMicrophone] {
    microphones
  }

  func defaultMicrophoneID() -> String? {
    selectedDefaultMicrophoneID
  }
}
