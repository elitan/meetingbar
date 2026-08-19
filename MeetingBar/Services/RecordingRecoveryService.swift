import Foundation
import SwiftData

@MainActor
final class RecordingRecoveryService {
  private let modelContext: ModelContext
  private let fileStore: RecordingFileStore

  init(modelContext: ModelContext, fileStore: RecordingFileStore) {
    self.modelContext = modelContext
    self.fileStore = fileStore
  }

  func recoverPartialRecordings(now: Date = .now) throws -> [Recording] {
    let existing = try modelContext.fetch(FetchDescriptor<Recording>())
    let recordingsByID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
    var recovered: [Recording] = []
    var recoveredIDs: Set<UUID> = []

    for (id, partialURL) in try fileStore.discoverPartialAudio() {
      let finalURL = fileStore.audioURL(for: id)
      do {
        _ = try WAVRepair.repairAndFinalize(partialURL: partialURL, finalURL: finalURL)
        fileStore.recoverSourcePartials(for: id)
      } catch {
        if let recording = recordingsByID[id] {
          recording.status = .failed
          recording.errorMessage =
            "The interrupted audio file could not be recovered: \(error.localizedDescription)"
        }
        continue
      }

      let recording: Recording
      if let savedRecording = recordingsByID[id] {
        recording = savedRecording
      } else {
        let attributes = try FileManager.default.attributesOfItem(atPath: finalURL.path)
        let date = (attributes[.creationDate] as? Date) ?? now
        recording = Recording(
          id: id,
          title: "Recovered meeting",
          startedAt: date,
          createdAt: date
        )
        modelContext.insert(recording)
      }
      try updateRecovered(recording, audioURL: finalURL, now: now)
      recovered.append(recording)
      recoveredIDs.insert(id)
    }

    for (id, finalURL) in try fileStore.discoverFinalAudio() where !recoveredIDs.contains(id) {
      guard let recording = recordingsByID[id],
        recording.endedAt == nil || recording.audioRelativePath == nil
      else {
        continue
      }
      fileStore.recoverSourcePartials(for: id)
      try updateRecovered(recording, audioURL: finalURL, now: now)
      recovered.append(recording)
      recoveredIDs.insert(id)
    }

    for recording in existing where recording.endedAt == nil && !recoveredIDs.contains(recording.id)
    {
      recording.endedAt = now
      recording.status = .failed
      if recording.errorMessage == nil {
        recording.errorMessage = "Recording was interrupted before its audio could be recovered."
      }
      recording.updatedAt = now
    }

    try modelContext.save()
    return recovered
  }

  private func updateRecovered(_ recording: Recording, audioURL: URL, now: Date) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: audioURL.path)
    let fileBytes = (attributes[.size] as? NSNumber)?.doubleValue ?? 44
    let duration = max(0, (fileBytes - 44) / 2 / Double(PCM16WAVWriter.sampleRate))
    recording.endedAt = recording.startedAt.addingTimeInterval(duration)
    recording.durationSeconds = duration
    recording.status = .queued
    recording.audioRelativePath = fileStore.relativeAudioPath(for: recording.id)
    recording.audioExpiresAt = recording.endedAt?.addingTimeInterval(
      RetentionService.retentionInterval)
    recording.wasRecovered = true
    recording.errorMessage = nil
    recording.updatedAt = now
  }

  func resetAbandonedJobs() throws -> [Recording] {
    let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
    let abandoned = recordings.filter { $0.status == .transcribing }
    for recording in abandoned {
      recording.status = .queued
      recording.errorMessage = nil
    }
    try modelContext.save()
    return abandoned
  }
}
