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

  func partialSourceAudioURL(
    for recordingID: UUID,
    kind: CaptureSourceKind
  ) -> URL {
    directoryURL(for: recordingID).appending(path: "\(kind.rawValue).partial.wav")
  }

  func sourceAudioURL(
    for recordingID: UUID,
    kind: CaptureSourceKind
  ) -> URL {
    directoryURL(for: recordingID).appending(path: "\(kind.rawValue).wav")
  }

  func captureManifestURL(for recordingID: UUID) -> URL {
    directoryURL(for: recordingID).appending(path: "capture-sources.json")
  }

  func relativeAudioPath(for recordingID: UUID) -> String {
    "Recordings/\(recordingID.uuidString)/audio.wav"
  }

  func resolve(relativePath: String) -> URL {
    rootURL.appending(path: relativePath)
  }

  func writeCaptureManifest(
    _ manifest: CaptureSourceManifest,
    for recordingID: UUID
  ) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(manifest)
    try data.write(to: captureManifestURL(for: recordingID), options: .atomic)
  }

  func transcriptionSources(
    for recordingID: UUID,
    fallbackAudioURL: URL,
    fileManager: FileManager = .default
  ) -> [TranscriptionSource] {
    let manifestURL = captureManifestURL(for: recordingID)
    if let data = try? Data(contentsOf: manifestURL),
      let manifest = try? JSONDecoder().decode(CaptureSourceManifest.self, from: data),
      manifest.version == CaptureSourceManifest.currentVersion
    {
      let sources = manifest.sources.compactMap { source -> TranscriptionSource? in
        let url = directoryURL(for: recordingID).appending(path: source.fileName)
        guard fileManager.fileExists(atPath: url.path) else {
          return nil
        }
        return TranscriptionSource(
          kind: source.kind,
          audioURL: url,
          offsetSeconds: source.offsetSeconds,
          signal: source.signal
        )
      }
      let availableKinds = Set(sources.map(\.kind))
      if availableKinds == Set(CaptureSourceKind.allCases) {
        return sources
      }
    }

    guard fileManager.fileExists(atPath: fallbackAudioURL.path) else {
      return []
    }
    return [
      TranscriptionSource(
        kind: .microphone,
        audioURL: fallbackAudioURL,
        offsetSeconds: 0,
        signal: nil
      )
    ]
  }

  func recoverSourcePartials(
    for recordingID: UUID,
    fileManager: FileManager = .default
  ) {
    for kind in CaptureSourceKind.allCases {
      let partialURL = partialSourceAudioURL(for: recordingID, kind: kind)
      guard fileManager.fileExists(atPath: partialURL.path) else {
        continue
      }
      let finalURL = sourceAudioURL(for: recordingID, kind: kind)
      _ = try? WAVRepair.repairAndFinalize(
        partialURL: partialURL,
        finalURL: finalURL,
        fileManager: fileManager
      )
    }
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
