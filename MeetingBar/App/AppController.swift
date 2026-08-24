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
  private(set) var speakerModelReadiness: ModelReadiness = .notDownloaded
  private(set) var lastErrorMessage: String?
  private(set) var launchAtLoginEnabled = false
  private(set) var didFinishLaunchRecovery = false
  private(set) var meetingReminderMonitorError: String?

  let capture: AudioCaptureController
  let fileStore: RecordingFileStore
  let meetingReminderPreferences: MeetingReminderPreferenceStore
  let microphonePreferences: MicrophonePreferenceStore
  let transcriptionPreferences: TranscriptionPreferenceStore

  private let modelContext: ModelContext
  private let retentionService: RetentionService
  private let recoveryService: RecordingRecoveryService
  private let bannerPresenter = AppBannerPresenter()
  private let loginItemService = LoginItemService()
  private var meetingTitleQueue: MeetingTitleQueue!
  private var transcriptionQueue: TranscriptionQueue!
  private var onlineMeetingMonitor: OnlineMeetingMonitor!
  private var activeRecordingID: UUID?
  private var retentionTask: Task<Void, Never>?
  private var hasLaunched = false

  var onboardingComplete: Bool {
    UserDefaults.standard.bool(forKey: "DidCompleteOnboarding")
  }

  init(modelContext: ModelContext, fileStore: RecordingFileStore) {
    self.modelContext = modelContext
    self.fileStore = fileStore
    let microphonePreferences = MicrophonePreferenceStore()
    self.microphonePreferences = microphonePreferences
    meetingReminderPreferences = MeetingReminderPreferenceStore()
    transcriptionPreferences = TranscriptionPreferenceStore()
    capture = AudioCaptureController(
      fileStore: fileStore,
      microphonePreferences: microphonePreferences
    )
    retentionService = RetentionService(modelContext: modelContext, fileStore: fileStore)
    recoveryService = RecordingRecoveryService(modelContext: modelContext, fileStore: fileStore)
    transcriptionQueue = TranscriptionQueue(modelsURL: fileStore.modelsURL) { [weak self] event in
      self?.handleTranscriptionEvent(event)
    }
    meetingTitleQueue = MeetingTitleQueue { [weak self] event in
      self?.handleMeetingTitleEvent(event)
    }
    onlineMeetingMonitor = OnlineMeetingMonitor(
      includesBrowsers: meetingReminderPreferences.includesBrowsers
    )
    onlineMeetingMonitor.onMeetingDetected = { [weak self] application in
      self?.handleOnlineMeetingDetected(application)
    }
    onlineMeetingMonitor.onErrorChanged = { [weak self] message in
      self?.meetingReminderMonitorError = message
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
    microphonePreferences.refreshDevices()

    do {
      let recovered = try recoveryService.recoverPartialRecordings()
      _ = try recoveryService.resetAbandonedJobs()
      try retentionService.run()

      let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
      let queued = recordings.filter { $0.status == .queued && $0.audioRelativePath != nil }
      let pendingTranscriptions = recovered + queued
      for recording in pendingTranscriptions {
        guard let relativePath = recording.audioRelativePath else {
          continue
        }
        await transcriptionQueue.enqueue(
          makeTranscriptionJob(
            recordingID: recording.id,
            fallbackAudioURL: fileStore.resolve(relativePath: relativePath)
          )
        )
      }
      for recording in recordings {
        if let titleJob = MeetingTitleJob(recording: recording) {
          await meetingTitleQueue.enqueue(titleJob)
        }
      }
      if pendingTranscriptions.isEmpty {
        await meetingTitleQueue.resumeProcessing()
      }
      didFinishLaunchRecovery = true
      if onboardingComplete {
        Task { [weak self] in
          await self?.prepareModel()
        }
      }
    } catch {
      lastErrorMessage = "Meeting recovery could not finish: \(error.localizedDescription)"
    }

    if onboardingComplete && meetingReminderPreferences.isEnabled {
      onlineMeetingMonitor.start()
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
      try await transcriptionQueue.prepareModel(
        configuration: transcriptionPreferences.configuration
      )
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
    if meetingReminderPreferences.isEnabled {
      onlineMeetingMonitor.start()
    }
  }

  func setMeetingRemindersEnabled(_ enabled: Bool) {
    meetingReminderPreferences.setEnabled(enabled)
    if enabled && onboardingComplete {
      meetingReminderMonitorError = nil
      onlineMeetingMonitor.start()
    } else {
      onlineMeetingMonitor.stop()
      meetingReminderMonitorError = nil
      bannerPresenter.dismiss()
    }
  }

  func setMeetingRemindersIncludeBrowsers(_ includesBrowsers: Bool) {
    meetingReminderPreferences.setIncludesBrowsers(includesBrowsers)
    onlineMeetingMonitor.setIncludesBrowsers(includesBrowsers)
    bannerPresenter.dismiss()
  }

  func showTestMeetingReminder() {
    guard capture.state == .idle else {
      lastErrorMessage = "Stop the current recording before testing a meeting reminder."
      return
    }
    presentMeetingReminder(applicationName: "Test meeting")
  }

  func prioritizeMicrophone(_ microphoneID: String) {
    microphonePreferences.prioritize(microphoneID)
  }

  func moveMicrophoneUp(_ microphoneID: String) {
    microphonePreferences.moveUp(microphoneID)
  }

  func moveMicrophoneDown(_ microphoneID: String) {
    microphonePreferences.moveDown(microphoneID)
  }

  func forgetMicrophone(_ microphoneID: String) {
    microphonePreferences.forget(microphoneID)
  }

  func refreshMicrophones() {
    microphonePreferences.refreshDevices()
  }

  func setTranscriptionLanguage(_ language: TranscriptionLanguagePreference) {
    transcriptionPreferences.setLanguage(language)
  }

  func setTranscriptionQuality(_ quality: TranscriptionQuality) {
    guard quality != transcriptionPreferences.quality else {
      return
    }
    transcriptionPreferences.setQuality(quality)
    modelReadiness = .notDownloaded
    Task { [weak self] in
      await self?.prepareModel()
    }
  }

  func save(_ recording: Recording) {
    recording.updatedAt = .now
    do {
      try modelContext.save()
    } catch {
      lastErrorMessage = "The meeting could not be saved: \(error.localizedDescription)"
    }
  }

  func rename(_ recording: Recording, to title: String) {
    let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedTitle.isEmpty else {
      return
    }
    recording.setManualTitle(trimmedTitle)
    save(recording)
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
        makeTranscriptionJob(recordingID: recording.id, fallbackAudioURL: url)
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

  func copyTranscript(_ recording: Recording) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(recording.transcript, forType: .string)
  }

  func quit() async {
    onlineMeetingMonitor.stop()
    bannerPresenter.dismiss()
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
    bannerPresenter.dismiss()
    let now = Date.now
    let recording = Recording(
      title: "Meeting \(now.formatted(.dateTime.year().month().day().hour().minute()))",
      titleOrigin: .placeholder,
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

  private func startRecordingFromReminder() async {
    guard capture.state == .idle else {
      return
    }
    await startRecording()
  }

  private func handleOnlineMeetingDetected(_ application: OnlineMeetingApplication) {
    meetingReminderMonitorError = nil
    guard meetingReminderPreferences.isEnabled, capture.state == .idle else {
      return
    }
    presentMeetingReminder(applicationName: application.name)
  }

  private func presentMeetingReminder(applicationName: String) {
    bannerPresenter.presentMeetingReminder(applicationName: applicationName) { [weak self] in
      guard let self else {
        return
      }
      Task { @MainActor in
        await self.startRecordingFromReminder()
      }
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
    if let microphone = result.sources.first(where: { $0.kind == .microphone }),
      microphone.signal.isQuietForSpeechRecognition
    {
      recording.captureWarnings.append(
        "The microphone recording was quiet and was raised for transcription. Moving the microphone closer may improve accuracy."
      )
    }
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
    let job = makeTranscriptionJob(
      recordingID: recording.id,
      fallbackAudioURL: fileStore.resolve(relativePath: relativePath)
    )
    Task {
      await transcriptionQueue.enqueue(job)
    }
  }

  private func handleTranscriptionEvent(_ event: TranscriptionQueueEvent) {
    switch event {
    case .modelDownloadProgress(let modelIdentifier, let progress):
      if modelIdentifier == transcriptionPreferences.quality.modelIdentifier {
        modelReadiness = .downloading(progress)
      }
    case .modelReady(let modelIdentifier):
      if modelIdentifier == transcriptionPreferences.quality.modelIdentifier {
        modelReadiness = .ready
      }
    case .speakerModelPreparing:
      speakerModelReadiness = .downloading(0)
    case .speakerModelReady:
      speakerModelReadiness = .ready
    case .speakerModelFailed(let message):
      speakerModelReadiness = .failed(message)
    case .started(let id):
      Task {
        await meetingTitleQueue.pauseProcessing()
      }
      guard let recording = recording(id: id) else {
        return
      }
      recording.status = .transcribing
      recording.errorMessage = nil
      save(recording)
    case .idle:
      Task {
        await meetingTitleQueue.resumeProcessing()
      }
    case .completed(let id, let transcript, let language, let modelIdentifier, let warnings):
      guard let recording = recording(id: id) else {
        return
      }
      recording.transcript = transcript
      recording.detectedLanguage = language
      recording.modelIdentifier = modelIdentifier
      recording.captureWarnings.removeAll {
        $0.hasPrefix("Speaker detection was unavailable for ")
      }
      for warning in warnings where !recording.captureWarnings.contains(warning) {
        recording.captureWarnings.append(warning)
      }
      recording.status = .ready
      recording.errorMessage = nil
      save(recording)
      enqueueTitle(for: recording)
      bannerPresenter.presentInformation(title: "Transcript ready", body: recording.title)
    case .failed(let id, let message):
      guard let recording = recording(id: id) else {
        return
      }
      recording.status = .failed
      recording.errorMessage = message
      save(recording)
      bannerPresenter.presentInformation(
        title: "Transcription failed",
        body: "Open MeetingBar to retry \(recording.title).",
        isError: true
      )
    }
  }

  private func enqueueTitle(for recording: Recording) {
    guard let job = MeetingTitleJob(recording: recording) else {
      return
    }
    Task {
      await meetingTitleQueue.enqueue(job)
    }
  }

  private func handleMeetingTitleEvent(_ event: MeetingTitleQueueEvent) {
    switch event {
    case .completed(let id, let sourceTranscript, let title):
      guard let recording = recording(id: id) else {
        return
      }
      guard recording.applyGeneratedTitle(title, for: sourceTranscript) else {
        return
      }
      save(recording)
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

  private func makeTranscriptionJob(
    recordingID: UUID,
    fallbackAudioURL: URL
  ) -> TranscriptionJob {
    TranscriptionJob(
      recordingID: recordingID,
      sources: fileStore.transcriptionSources(
        for: recordingID,
        fallbackAudioURL: fallbackAudioURL
      ),
      configuration: transcriptionPreferences.configuration
    )
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
