import AppKit
import Foundation
import KeyboardShortcuts
import Observation
import SwiftData

enum ModelReadiness: Equatable, Sendable {
  case notDownloaded
  case downloading(Double)
  case ready
  case failed(String)
}

@MainActor
@Observable
final class AppController {
  private(set) var modelReadiness: ModelReadiness = .notDownloaded
  private(set) var lastErrorMessage: String?
  private(set) var launchAtLoginEnabled = false
  private(set) var didFinishLaunchRecovery = false

  let capture: AudioCaptureController
  let fileStore: RecordingFileStore

  private let modelContext: ModelContext
  private let retentionService: RetentionService
  private let recoveryService: RecordingRecoveryService
  private let notificationService = NotificationService()
  private let loginItemService = LoginItemService()
  private var transcriptionQueue: TranscriptionQueue!
  private var activeRecordingID: UUID?
  private var retentionTask: Task<Void, Never>?
  private var hasLaunched = false

  var onboardingComplete: Bool {
    UserDefaults.standard.bool(forKey: "DidCompleteOnboarding")
  }

  init(modelContext: ModelContext, fileStore: RecordingFileStore) {
    self.modelContext = modelContext
    self.fileStore = fileStore
    capture = AudioCaptureController(fileStore: fileStore)
    retentionService = RetentionService(modelContext: modelContext, fileStore: fileStore)
    recoveryService = RecordingRecoveryService(modelContext: modelContext, fileStore: fileStore)
    transcriptionQueue = TranscriptionQueue(modelsURL: fileStore.modelsURL) { [weak self] event in
      self?.handleTranscriptionEvent(event)
    }

    capture.onWarning = { [weak self] warning in
      self?.recordCaptureWarning(warning)
    }
    capture.onFatalFailure = { [weak self] error in
      guard let self else {
        return
      }
      Task { @MainActor in
        await self.stopAfterCaptureFailure(error)
      }
    }
    KeyboardShortcuts.onKeyUp(for: .toggleMeetingRecording) { [weak self] in
      guard let self else {
        return
      }
      Task { @MainActor in
        await self.toggleRecording()
      }
    }
  }

  convenience init(modelContext: ModelContext) throws {
    try self.init(modelContext: modelContext, fileStore: RecordingFileStore())
  }

  func launch() async {
    guard !hasLaunched else {
      return
    }
    hasLaunched = true
    launchAtLoginEnabled = loginItemService.isEnabled

    do {
      let recovered = try recoveryService.recoverPartialRecordings()
      _ = try recoveryService.resetAbandonedJobs()
      try retentionService.run()

      let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
      let queued = recordings.filter { $0.status == .queued && $0.audioRelativePath != nil }
      for recording in recovered + queued where recording.audioRelativePath != nil {
        enqueue(recording)
      }
      didFinishLaunchRecovery = true
    } catch {
      lastErrorMessage = "Meeting recovery could not finish: \(error.localizedDescription)"
    }

    retentionTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(86_400))
        guard let self else {
          return
        }
        do {
          try self.retentionService.run()
        } catch {
          self.lastErrorMessage = "Audio retention could not finish: \(error.localizedDescription)"
        }
      }
    }
  }

  func toggleRecording() async {
    switch capture.state {
    case .idle:
      await startRecording()
    case .recording:
      await stopRecording()
    case .starting, .stopping:
      return
    }
  }

  func prepareModel() async {
    do {
      try await transcriptionQueue.prepareModel()
    } catch {
      modelReadiness = .failed(error.localizedDescription)
      lastErrorMessage = error.localizedDescription
    }
  }

  func requestMicrophonePermission() async -> Bool {
    await AudioCaptureController.requestMicrophonePermission()
  }

  func requestScreenPermission() -> Bool {
    AudioCaptureController.requestScreenPermission()
  }

  func requestNotificationPermission() async -> Bool {
    await notificationService.requestAuthorization()
  }

  func setLaunchAtLogin(_ enabled: Bool) -> Bool {
    do {
      try loginItemService.setEnabled(enabled)
      launchAtLoginEnabled = loginItemService.isEnabled
      return launchAtLoginEnabled == enabled
    } catch {
      launchAtLoginEnabled = loginItemService.isEnabled
      lastErrorMessage = "Launch at login could not be changed: \(error.localizedDescription)"
      return false
    }
  }

  func completeOnboarding() {
    UserDefaults.standard.set(true, forKey: "DidCompleteOnboarding")
  }

  func save(_ recording: Recording) {
    recording.updatedAt = .now
    do {
      try modelContext.save()
    } catch {
      lastErrorMessage = "The meeting could not be saved: \(error.localizedDescription)"
    }
  }

  func retry(_ recording: Recording) {
    guard let relativePath = recording.audioRelativePath else {
      lastErrorMessage = "The source audio has already been deleted."
      return
    }
    let url = fileStore.resolve(relativePath: relativePath)
    guard FileManager.default.fileExists(atPath: url.path) else {
      lastErrorMessage = "The source audio file is missing."
      return
    }

    recording.status = .queued
    recording.errorMessage = nil
    save(recording)
    Task {
      await transcriptionQueue.retry(
        TranscriptionJob(recordingID: recording.id, audioURL: url)
      )
    }
  }

  func delete(_ recording: Recording) throws {
    guard recording.id != activeRecordingID else {
      throw AudioCaptureError.stateConflict
    }
    try fileStore.deleteRecordingFiles(for: recording.id)
    modelContext.delete(recording)
    try modelContext.save()
  }

  func audioURL(for recording: Recording) -> URL? {
    guard let relativePath = recording.audioRelativePath else {
      return nil
    }
    let url = fileStore.resolve(relativePath: relativePath)
    return FileManager.default.fileExists(atPath: url.path) ? url : nil
  }

  func revealAudio(for recording: Recording) {
    guard let url = audioURL(for: recording) else {
      return
    }
    NSWorkspace.shared.activateFileViewerSelecting([url])
  }

  func playAudio(for recording: Recording) {
    guard let url = audioURL(for: recording) else {
      return
    }
    NSWorkspace.shared.open(url)
  }

  func copyTranscript(_ recording: Recording) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(recording.transcript, forType: .string)
  }

  func quit() async {
    if capture.state.isRecording {
      await stopRecording()
    }
    NSApplication.shared.terminate(nil)
  }

  func clearError() {
    lastErrorMessage = nil
  }

  private func startRecording() async {
    lastErrorMessage = nil
    let now = Date.now
    let recording = Recording(
      title: "Meeting \(now.formatted(.dateTime.year().month().day().hour().minute()))",
      startedAt: now
    )
    modelContext.insert(recording)
    activeRecordingID = recording.id

    do {
      try modelContext.save()
      let startedAt = try await capture.start(recordingID: recording.id)
      recording.startedAt = startedAt
      recording.updatedAt = startedAt
      try modelContext.save()
      playStartTone()
    } catch {
      activeRecordingID = nil
      try? fileStore.deleteRecordingFiles(for: recording.id)
      modelContext.delete(recording)
      try? modelContext.save()
      lastErrorMessage = error.localizedDescription
    }
  }

  private func stopRecording() async {
    guard let recordingID = activeRecordingID, let recording = recording(id: recordingID) else {
      lastErrorMessage = "MeetingBar lost track of the active recording."
      return
    }

    do {
      let result = try await capture.stop()
      finish(recording, result: result)
      activeRecordingID = nil
      playStopTone()
      enqueue(recording)
    } catch {
      recording.status = .failed
      recording.errorMessage = error.localizedDescription
      recording.endedAt = .now
      save(recording)
      activeRecordingID = nil
      lastErrorMessage = error.localizedDescription
    }
  }

  private func finish(_ recording: Recording, result: FinalizedCapture) {
    let endedAt = Date.now
    recording.endedAt = endedAt
    recording.durationSeconds = result.durationSeconds
    recording.status = .queued
    recording.audioRelativePath = fileStore.relativeAudioPath(for: recording.id)
    recording.audioExpiresAt = endedAt.addingTimeInterval(RetentionService.retentionInterval)
    recording.errorMessage = nil
    save(recording)
  }

  private func stopAfterCaptureFailure(_ error: Error) async {
    recordCaptureWarning(error.localizedDescription)
    await stopRecording()
  }

  private func enqueue(_ recording: Recording) {
    guard let relativePath = recording.audioRelativePath else {
      return
    }
    let job = TranscriptionJob(
      recordingID: recording.id,
      audioURL: fileStore.resolve(relativePath: relativePath)
    )
    Task {
      await transcriptionQueue.enqueue(job)
    }
  }

  private func handleTranscriptionEvent(_ event: TranscriptionQueueEvent) {
    switch event {
    case .modelDownloadProgress(let progress):
      modelReadiness = .downloading(progress)
    case .modelReady:
      modelReadiness = .ready
    case .started(let id):
      guard let recording = recording(id: id) else {
        return
      }
      recording.status = .transcribing
      recording.errorMessage = nil
      save(recording)
    case .completed(let id, let transcript, let language, let modelIdentifier):
      guard let recording = recording(id: id) else {
        return
      }
      recording.transcript = transcript
      recording.detectedLanguage = language
      recording.modelIdentifier = modelIdentifier
      recording.status = .ready
      recording.errorMessage = nil
      save(recording)
      let title = recording.title
      Task {
        await notificationService.notifyTranscriptionReady(title: title)
      }
    case .failed(let id, let message):
      guard let recording = recording(id: id) else {
        return
      }
      recording.status = .failed
      recording.errorMessage = message
      save(recording)
      let title = recording.title
      Task {
        await notificationService.notifyTranscriptionFailed(title: title)
      }
    }
  }

  private func recording(id: UUID) -> Recording? {
    let descriptor = FetchDescriptor<Recording>(
      predicate: #Predicate { recording in
        recording.id == id
      }
    )
    return try? modelContext.fetch(descriptor).first
  }

  private func recordCaptureWarning(_ warning: String) {
    guard let activeRecordingID, let recording = recording(id: activeRecordingID) else {
      return
    }
    recording.captureWarnings.append(warning)
    save(recording)
  }

  private func playStartTone() {
    NSSound(named: NSSound.Name("Tink"))?.play()
  }

  private func playStopTone() {
    NSSound(named: NSSound.Name("Pop"))?.play()
  }
}
