import AVFoundation
import Foundation
import Observation

struct ConnectedMicrophone: Equatable, Sendable {
  let id: String
  let name: String
}

struct MicrophonePreference: Equatable, Identifiable, Sendable {
  let id: String
  let name: String
  let lastSeenAt: Date
  let isConnected: Bool
}

@MainActor
protocol MicrophoneDeviceProviding: AnyObject {
  func connectedMicrophones() -> [ConnectedMicrophone]
  func defaultMicrophoneID() -> String?
}

@MainActor
final class SystemMicrophoneDeviceProvider: MicrophoneDeviceProviding {
  private let discoverySession = AVCaptureDevice.DiscoverySession(
    deviceTypes: [.microphone],
    mediaType: .audio,
    position: .unspecified
  )

  func connectedMicrophones() -> [ConnectedMicrophone] {
    discoverySession.devices.map { device in
      ConnectedMicrophone(id: device.uniqueID, name: device.localizedName)
    }
  }

  func defaultMicrophoneID() -> String? {
    AVCaptureDevice.default(for: .audio)?.uniqueID
  }
}

@MainActor
@Observable
final class MicrophonePreferenceStore {
  private(set) var microphones: [MicrophonePreference] = []
  private(set) var activeMicrophoneID: String?

  @ObservationIgnored
  var onActiveMicrophoneChanged: ((MicrophonePreference?) -> Void)?

  @ObservationIgnored private let userDefaults: UserDefaults
  @ObservationIgnored private let deviceProvider: MicrophoneDeviceProviding
  @ObservationIgnored private let defaultsKey = "MicrophonePriority"
  @ObservationIgnored private let notificationObserverBag = NotificationObserverBag()

  var activeMicrophone: MicrophonePreference? {
    guard let activeMicrophoneID else {
      return nil
    }
    return microphones.first { $0.id == activeMicrophoneID }
  }

  var connectedMicrophones: [MicrophonePreference] {
    microphones.filter(\.isConnected)
  }

  var unavailableMicrophones: [MicrophonePreference] {
    microphones.filter { !$0.isConnected }
  }

  init(
    userDefaults: UserDefaults = .standard,
    deviceProvider: MicrophoneDeviceProviding? = nil,
    observesDeviceChanges: Bool = true
  ) {
    self.userDefaults = userDefaults
    self.deviceProvider = deviceProvider ?? SystemMicrophoneDeviceProvider()
    microphones = Self.loadPreferences(from: userDefaults, key: defaultsKey)
    refreshDevices()

    if observesDeviceChanges {
      observeDeviceChanges()
    }
  }

  func refreshDevices(now: Date = .now) {
    let oldActiveMicrophoneID = activeMicrophoneID
    let connected = deviceProvider.connectedMicrophones()
    let defaultMicrophoneID = deviceProvider.defaultMicrophoneID()
    var connectedByID: [String: ConnectedMicrophone] = [:]
    for microphone in connected {
      connectedByID[microphone.id] = microphone
    }

    var reconciled: [MicrophonePreference] = []
    for remembered in microphones {
      if let current = connectedByID.removeValue(forKey: remembered.id) {
        reconciled.append(
          MicrophonePreference(
            id: current.id,
            name: current.name,
            lastSeenAt: now,
            isConnected: true
          )
        )
      } else {
        reconciled.append(
          MicrophonePreference(
            id: remembered.id,
            name: remembered.name,
            lastSeenAt: remembered.lastSeenAt,
            isConnected: false
          )
        )
      }
    }

    let newlyConnected = connectedByID.values.sorted { left, right in
      if left.id == defaultMicrophoneID, right.id != defaultMicrophoneID {
        return true
      }
      if right.id == defaultMicrophoneID, left.id != defaultMicrophoneID {
        return false
      }
      return left.name.localizedStandardCompare(right.name) == .orderedAscending
    }
    reconciled.append(
      contentsOf: newlyConnected.map { microphone in
        MicrophonePreference(
          id: microphone.id,
          name: microphone.name,
          lastSeenAt: now,
          isConnected: true
        )
      }
    )

    microphones = reconciled
    activeMicrophoneID = microphones.first(where: \.isConnected)?.id
    persist()
    notifyIfActiveMicrophoneChanged(from: oldActiveMicrophoneID)
  }

  func prioritize(_ microphoneID: String) {
    guard let index = microphones.firstIndex(where: { $0.id == microphoneID }) else {
      return
    }
    let oldActiveMicrophoneID = activeMicrophoneID
    let microphone = microphones.remove(at: index)
    microphones.insert(microphone, at: 0)
    activeMicrophoneID = microphones.first(where: \.isConnected)?.id
    persist()
    notifyIfActiveMicrophoneChanged(from: oldActiveMicrophoneID)
  }

  func moveUp(_ microphoneID: String) {
    guard let index = microphones.firstIndex(where: { $0.id == microphoneID }), index > 0 else {
      return
    }
    move(from: index, to: index - 1)
  }

  func moveDown(_ microphoneID: String) {
    guard let index = microphones.firstIndex(where: { $0.id == microphoneID }),
      index < microphones.count - 1
    else {
      return
    }
    move(from: index, to: index + 1)
  }

  func forget(_ microphoneID: String) {
    guard let index = microphones.firstIndex(where: { $0.id == microphoneID }),
      !microphones[index].isConnected
    else {
      return
    }
    microphones.remove(at: index)
    persist()
  }

  private func move(from sourceIndex: Int, to destinationIndex: Int) {
    let oldActiveMicrophoneID = activeMicrophoneID
    let microphone = microphones.remove(at: sourceIndex)
    microphones.insert(microphone, at: destinationIndex)
    activeMicrophoneID = microphones.first(where: \.isConnected)?.id
    persist()
    notifyIfActiveMicrophoneChanged(from: oldActiveMicrophoneID)
  }

  private func observeDeviceChanges() {
    let center = NotificationCenter.default
    let names: [Notification.Name] = [
      AVCaptureDevice.wasConnectedNotification,
      AVCaptureDevice.wasDisconnectedNotification,
    ]
    notificationObserverBag.observers = names.map { name in
      center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
        Task { @MainActor [weak self] in
          self?.refreshDevices()
        }
      }
    }
  }

  private func notifyIfActiveMicrophoneChanged(from oldMicrophoneID: String?) {
    guard oldMicrophoneID != activeMicrophoneID else {
      return
    }
    onActiveMicrophoneChanged?(activeMicrophone)
  }

  private func persist() {
    let stored = microphones.map { microphone in
      StoredMicrophone(
        id: microphone.id,
        name: microphone.name,
        lastSeenAt: microphone.lastSeenAt
      )
    }
    guard let data = try? JSONEncoder().encode(stored) else {
      return
    }
    userDefaults.set(data, forKey: defaultsKey)
  }

  private static func loadPreferences(
    from userDefaults: UserDefaults,
    key: String
  ) -> [MicrophonePreference] {
    guard let data = userDefaults.data(forKey: key),
      let stored = try? JSONDecoder().decode([StoredMicrophone].self, from: data)
    else {
      return []
    }
    return stored.map { microphone in
      MicrophonePreference(
        id: microphone.id,
        name: microphone.name,
        lastSeenAt: microphone.lastSeenAt,
        isConnected: false
      )
    }
  }
}

private struct StoredMicrophone: Codable {
  let id: String
  let name: String
  let lastSeenAt: Date
}

private final class NotificationObserverBag: @unchecked Sendable {
  var observers: [NSObjectProtocol] = []

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }
}
