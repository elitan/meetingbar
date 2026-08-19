import Foundation

enum RecordingFileStoreError: LocalizedError {
  case insufficientDiskSpace(availableBytes: Int64)

  var errorDescription: String? {
    switch self {
    case .insufficientDiskSpace(let availableBytes):
      let available = ByteCountFormatter.string(fromByteCount: availableBytes, countStyle: .file)
      return "MeetingBar needs at least 1 GB of free space. Only \(available) is available."
    }
  }
}

struct RecordingFileStore: Sendable {
  static let minimumFreeBytes: Int64 = 1_000_000_000

  let rootURL: URL

  init(fileManager: FileManager = .default) throws {
    let applicationSupport = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    rootURL = applicationSupport.appending(path: "MeetingBar", directoryHint: .isDirectory)
    try Self.createDirectories(at: rootURL, fileManager: fileManager)
  }

  init(rootURL: URL, fileManager: FileManager = .default) throws {
    self.rootURL = rootURL
    try Self.createDirectories(at: rootURL, fileManager: fileManager)
  }

  var recordingsURL: URL {
    rootURL.appending(path: "Recordings", directoryHint: .isDirectory)
  }

  var modelsURL: URL {
    rootURL.appending(path: "Models", directoryHint: .isDirectory)
  }

  func directoryURL(for recordingID: UUID) -> URL {
    recordingsURL.appending(path: recordingID.uuidString, directoryHint: .isDirectory)
  }

  func partialAudioURL(for recordingID: UUID) -> URL {
    directoryURL(for: recordingID).appending(path: "audio.partial.wav")
  }

  func audioURL(for recordingID: UUID) -> URL {
    directoryURL(for: recordingID).appending(path: "audio.wav")
  }

  func relativeAudioPath(for recordingID: UUID) -> String {
    "Recordings/\(recordingID.uuidString)/audio.wav"
  }

  func resolve(relativePath: String) -> URL {
    rootURL.appending(path: relativePath)
  }

  func prepareDirectory(for recordingID: UUID, fileManager: FileManager = .default) throws {
    try fileManager.createDirectory(
      at: directoryURL(for: recordingID),
      withIntermediateDirectories: true
    )
  }

  func requireAvailableDiskSpace(fileManager: FileManager = .default) throws {
    let values = try rootURL.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let available = values.volumeAvailableCapacityForImportantUsage ?? 0
    guard available >= Self.minimumFreeBytes else {
      throw RecordingFileStoreError.insufficientDiskSpace(availableBytes: available)
    }
  }

  func discoverPartialAudio(fileManager: FileManager = .default) throws -> [(UUID, URL)] {
    try discoverAudio(named: "audio.partial.wav", fileManager: fileManager)
  }

  func discoverFinalAudio(fileManager: FileManager = .default) throws -> [(UUID, URL)] {
    try discoverAudio(named: "audio.wav", fileManager: fileManager)
  }

  private func discoverAudio(
    named fileName: String,
    fileManager: FileManager
  ) throws -> [(UUID, URL)] {
    let directories = try fileManager.contentsOfDirectory(
      at: recordingsURL,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    )

    return directories.compactMap { directory in
      guard let id = UUID(uuidString: directory.lastPathComponent) else {
        return nil
      }
      let audioURL = directory.appending(path: fileName)
      guard fileManager.fileExists(atPath: audioURL.path) else {
        return nil
      }
      return (id, audioURL)
    }
  }

  func deleteRecordingFiles(for recordingID: UUID, fileManager: FileManager = .default) throws {
    let directory = directoryURL(for: recordingID)
    guard fileManager.fileExists(atPath: directory.path) else {
      return
    }
    try fileManager.removeItem(at: directory)
  }

  private static func createDirectories(at rootURL: URL, fileManager: FileManager) throws {
    try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
    try fileManager.createDirectory(
      at: rootURL.appending(path: "Recordings", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
    try fileManager.createDirectory(
      at: rootURL.appending(path: "Models", directoryHint: .isDirectory),
      withIntermediateDirectories: true
    )
  }
}
