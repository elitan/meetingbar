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

private enum RecordingStopReason {
  case manual
  case promptConfirmed
  case silenceTimeout
  case onlineMeetingEnded(applicationName: String)

  var confirmation: (title: String, body: String)? {
    switch self {
    case .manual:
      nil
    case .promptConfirmed:
      (
        title: "Recording stopped",
        body: "MeetingBar saved the recording and started transcription."
      )
    case .silenceTimeout:
      (
        title: "Recording stopped automatically",
        body: "MeetingBar saved the recording after five minutes of silence and started transcription."
      )
    case .onlineMeetingEnded(let applicationName):
      (
        title: "Recording stopped automatically",
        body: "MeetingBar saved the recording after \(applicationName) stopped using the microphone and started transcription."
      )
    }
  }
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
  let recordingSafetyPreferences: RecordingSafetyPreferenceStore
  let transcriptionPreferences: TranscriptionPreferenceStore

  private let modelContext: ModelContext
  private let audioPreservationService: AudioPreservationService
  private let recoveryService: RecordingRecoveryService
  private let bannerPresenter = AppBannerPresenter()
  private let loginItemService = LoginItemService()
  private var meetingTitleQueue: MeetingTitleQueue!
  private var transcriptionQueue: TranscriptionQueue!
  private var onlineMeetingMonitor: OnlineMeetingMonitor!
  private var onlineMeetingEndMonitor = OnlineMeetingEndMonitor()
  private var recordingSilenceMonitor = RecordingSilenceMonitor()
  private var activeRecordingID: UUID?
  private var onlineMeetingEndTask: Task<Void, Never>?
  private var recordingSilenceTask: Task<Void, Never>?
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
    recordingSafetyPreferences = RecordingSafetyPreferenceStore()
    let transcriptionSecretStore = KeychainTranscriptionSecretStore()
    transcriptionPreferences = TranscriptionPreferenceStore(secretStore: transcriptionSecretStore)
    capture = AudioCaptureController(
      fileStore: fileStore,
      microphonePreferences: microphonePreferences
    )
    audioPreservationService = AudioPreservationService(modelContext: modelContext)
    recoveryService = RecordingRecoveryService(modelContext: modelContext, fileStore: fileStore)
    transcriptionQueue = TranscriptionQueue(
      modelsURL: fileStore.modelsURL,
      secretStore: transcriptionSecretStore
    ) { [weak self] event in
      self?.handleTranscriptionEvent(event) ?? false
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
    onlineMeetingMonitor.onActiveApplicationsChanged = { [weak self] applications in
      self?.observeOnlineMeetingApplications(applications)
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
    capture.onLevelsChanged = { [weak self] levels in
      self?.observeRecordingLevels(levels)
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
      try audioPreservationService.clearLegacyExpiryDates()

      let recordings = try modelContext.fetch(FetchDescriptor<Recording>())
      await transcriptionQueue.reconcileRemoteCleanup(
        knownRecordingIDs: Set(recordings.map(\.id)),
        readyRecordingIDs: Set(recordings.filter { $0.status == .ready }.map(\.id))
      )
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

    refreshOnlineMeetingMonitoring()
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
    modelReadiness = .downloading(0)
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
    refreshOnlineMeetingMonitoring()
  }

  func setMeetingRemindersEnabled(_ enabled: Bool) {
    meetingReminderPreferences.setEnabled(enabled)
    if enabled {
      meetingReminderMonitorError = nil
    } else {
      meetingReminderMonitorError = nil
      if capture.state == .idle {
        bannerPresenter.dismiss()
      }
    }
    refreshOnlineMeetingMonitoring()
  }

  func setMeetingRemindersIncludeBrowsers(_ includesBrowsers: Bool) {
    meetingReminderPreferences.setIncludesBrowsers(includesBrowsers)
    onlineMeetingMonitor.setIncludesBrowsers(includesBrowsers)
    if capture.state.isRecording, recordingSafetyPreferences.isEnabled {
      beginOnlineMeetingEndMonitoring()
    } else {
      bannerPresenter.dismiss()
    }
  }

  func setRecordingSafetyEnabled(_ enabled: Bool) {
    recordingSafetyPreferences.setEnabled(enabled)
    if capture.state.isRecording {
      if enabled {
        refreshOnlineMeetingMonitoring()
        beginRecordingSafetyMonitoring()
      } else {
        endRecordingSafetyMonitoring()
        refreshOnlineMeetingMonitoring()
      }
    } else {
      refreshOnlineMeetingMonitoring()
    }
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

  func setTranscriptionProvider(_ provider: TranscriptionProvider) {
    guard provider != transcriptionPreferences.provider else {
      return
    }
    transcriptionPreferences.setProvider(provider)
    if provider == .elevenLabs, !transcriptionPreferences.hasElevenLabsAPIKey {
      modelReadiness = .failed(ElevenLabsTranscriptionError.missingAPIKey.localizedDescription)
      return
    }
    modelReadiness = .notDownloaded
    Task { [weak self] in
      await self?.prepareModel()
    }
  }

  func setTranscriptionQuality(_ quality: TranscriptionQuality) {
    guard quality != transcriptionPreferences.quality else {
      return
    }
    transcriptionPreferences.setQuality(quality)
    guard transcriptionPreferences.provider == .onDevice else {
      return
    }
    modelReadiness = .notDownloaded
    Task { [weak self] in
      await self?.prepareModel()
    }
  }

  func setElevenLabsTranscriptionModel(_ model: ElevenLabsTranscriptionModel) {
    guard model != transcriptionPreferences.elevenLabsModel else {
      return
    }
    transcriptionPreferences.setElevenLabsModel(model)
    guard transcriptionPreferences.provider == .elevenLabs else {
      return
    }
    modelReadiness = .notDownloaded
    Task { [weak self] in
      await self?.prepareModel()
    }
  }

  func saveElevenLabsAPIKey(_ apiKey: String) throws {
    do {
      try transcriptionPreferences.saveElevenLabsAPIKey(apiKey)
      if transcriptionPreferences.provider == .elevenLabs {
        modelReadiness = .notDownloaded
        Task { [weak self] in
          guard let self else {
            return
          }
          await self.transcriptionQueue.resumeRemoteCleanup()
          await self.prepareModel()
        }
      }
    } catch {
      lastErrorMessage = error.localizedDescription
      throw error
    }
  }

  func removeElevenLabsAPIKey() throws {
    do {
      try transcriptionPreferences.removeElevenLabsAPIKey()
      if transcriptionPreferences.provider == .elevenLabs {
        modelReadiness = .failed(
          ElevenLabsTranscriptionError.missingAPIKey.localizedDescription
        )
      }
    } catch {
      lastErrorMessage = error.localizedDescription
      throw error
    }
  }

  @discardableResult
  func save(_ recording: Recording) -> Bool {
    recording.updatedAt = .now
    do {
      try modelContext.save()
      return true
    } catch {
      lastErrorMessage = "The meeting could not be saved: \(error.localizedDescription)"
      return false
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
    if capture.state.isRecording {
      await stopRecording()
    }
    onlineMeetingMonitor.stop()
    bannerPresenter.dismiss()
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
      refreshOnlineMeetingMonitoring()
      beginRecordingSafetyMonitoring()
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

  private func stopRecording(reason: RecordingStopReason = .manual) async {
    endRecordingSafetyMonitoring()
    guard let recordingID = activeRecordingID, let recording = recording(id: recordingID) else {
      lastErrorMessage = "MeetingBar lost track of the active recording."
      return
    }

    do {
      let result = try await capture.stop()
      finish(recording, result: result)
      activeRecordingID = nil
      refreshOnlineMeetingMonitoring()
      playStopTone()
      enqueue(recording)
      if let confirmation = reason.confirmation {
        bannerPresenter.presentInformation(
          title: confirmation.title,
          body: confirmation.body
        )
      }
    } catch {
      recording.status = .failed
      recording.errorMessage = error.localizedDescription
      recording.endedAt = .now
      save(recording)
      activeRecordingID = nil
      refreshOnlineMeetingMonitoring()
      lastErrorMessage = error.localizedDescription
    }
  }

  private func finish(_ recording: Recording, result: FinalizedCapture) {
    let endedAt = Date.now
    recording.endedAt = endedAt
    recording.durationSeconds = result.durationSeconds
    recording.status = .queued
    recording.audioRelativePath = fileStore.relativeAudioPath(for: recording.id)
    recording.audioExpiresAt = nil
    recording.audioDeletedAt = nil
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

  private func refreshOnlineMeetingMonitoring() {
    let isNeededForRecordingSafety =
      recordingSafetyPreferences.isEnabled && capture.state.isRecording
    let isNeededForReminders = onboardingComplete && meetingReminderPreferences.isEnabled
    if isNeededForReminders || isNeededForRecordingSafety {
      onlineMeetingMonitor.start()
    } else {
      onlineMeetingMonitor.stop()
    }
  }

  private func beginRecordingSafetyMonitoring() {
    guard recordingSafetyPreferences.isEnabled, capture.state.isRecording else {
      return
    }
    beginRecordingSilenceMonitoring()
    beginOnlineMeetingEndMonitoring()
  }

  private func endRecordingSafetyMonitoring() {
    endRecordingSilenceMonitoring()
    endOnlineMeetingEndMonitoring()
  }

  private func beginOnlineMeetingEndMonitoring() {
    endOnlineMeetingEndMonitoring()
    guard recordingSafetyPreferences.isEnabled, capture.state.isRecording else {
      return
    }

    onlineMeetingEndMonitor.start(
      activeApplications: onlineMeetingMonitor.activeApplications
    )
    onlineMeetingEndTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self, self.capture.state.isRecording else {
          return
        }
        let action = self.onlineMeetingEndMonitor.tick(at: ContinuousClock.now)
        self.handleOnlineMeetingEndAction(action)
      }
    }
  }

  private func endOnlineMeetingEndMonitoring() {
    onlineMeetingEndTask?.cancel()
    onlineMeetingEndTask = nil
    _ = onlineMeetingEndMonitor.stop()
    bannerPresenter.dismissRecordingContinuationReminder()
  }

  private func observeOnlineMeetingApplications(
    _ applications: Set<OnlineMeetingApplication>
  ) {
    let action = onlineMeetingEndMonitor.observe(
      activeApplications: applications,
      at: ContinuousClock.now
    )
    handleOnlineMeetingEndAction(action)
  }

  private func handleOnlineMeetingEndAction(_ action: OnlineMeetingEndAction) {
    switch action {
    case .none:
      return
    case .presentPrompt(let applicationName, let secondsRemaining):
      bannerPresenter.presentOnlineMeetingEndedReminder(
        applicationName: applicationName,
        secondsRemaining: secondsRemaining,
        onKeepRecording: { [weak self] in
          self?.keepRecordingAfterOnlineMeetingEndedPrompt()
        },
        onStopRecording: { [weak self] in
          self?.stopRecordingFromOnlineMeetingEndedPrompt()
        }
      )
    case .updatePrompt(let applicationName, let secondsRemaining):
      bannerPresenter.updateOnlineMeetingEndedReminder(
        applicationName: applicationName,
        secondsRemaining: secondsRemaining
      )
    case .dismissPrompt:
      bannerPresenter.dismissRecordingContinuationReminder()
    case .stopRecording(let applicationName):
      onlineMeetingEndTask?.cancel()
      onlineMeetingEndTask = nil
      bannerPresenter.dismissRecordingContinuationReminder()
      Task { [weak self] in
        await self?.stopRecording(reason: .onlineMeetingEnded(applicationName: applicationName))
      }
    }
  }

  private func keepRecordingAfterOnlineMeetingEndedPrompt() {
    let action = onlineMeetingEndMonitor.keepRecording()
    handleOnlineMeetingEndAction(action)
  }

  private func stopRecordingFromOnlineMeetingEndedPrompt() {
    onlineMeetingEndTask?.cancel()
    onlineMeetingEndTask = nil
    _ = onlineMeetingEndMonitor.stop()
    Task { [weak self] in
      await self?.stopRecording(reason: .promptConfirmed)
    }
  }

  private func beginRecordingSilenceMonitoring() {
    endRecordingSilenceMonitoring()
    guard recordingSafetyPreferences.isEnabled, capture.state.isRecording else {
      return
    }

    recordingSilenceMonitor.start(at: ContinuousClock.now)
    recordingSilenceTask = Task { [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(for: .seconds(1))
        guard !Task.isCancelled, let self, self.capture.state.isRecording else {
          return
        }
        let action = self.recordingSilenceMonitor.tick(at: ContinuousClock.now)
        self.handleRecordingSilenceAction(action)
      }
    }
  }

  private func endRecordingSilenceMonitoring() {
    recordingSilenceTask?.cancel()
    recordingSilenceTask = nil
    _ = recordingSilenceMonitor.stop()
    bannerPresenter.dismissRecordingContinuationReminder()
  }

  private func observeRecordingLevels(_ levels: CaptureLevels) {
    let action = recordingSilenceMonitor.observe(levels: levels, at: ContinuousClock.now)
    handleRecordingSilenceAction(action)
  }

  private func handleRecordingSilenceAction(_ action: RecordingSilenceAction) {
    switch action {
    case .none:
      return
    case .presentPrompt(let secondsRemaining):
      bannerPresenter.presentRecordingSilenceReminder(
        secondsRemaining: secondsRemaining,
        onKeepRecording: { [weak self] in
          self?.keepRecordingAfterSilencePrompt()
        },
        onStopRecording: { [weak self] in
          self?.stopRecordingFromSilencePrompt()
        }
      )
    case .updatePrompt(let secondsRemaining):
      bannerPresenter.updateRecordingSilenceReminder(secondsRemaining: secondsRemaining)
    case .dismissPrompt:
      bannerPresenter.dismissRecordingContinuationReminder()
    case .stopRecording:
      recordingSilenceTask?.cancel()
      recordingSilenceTask = nil
      bannerPresenter.dismissRecordingContinuationReminder()
      Task { [weak self] in
        await self?.stopRecording(reason: .silenceTimeout)
      }
    }
  }

  private func keepRecordingAfterSilencePrompt() {
    let action = recordingSilenceMonitor.keepRecording(at: ContinuousClock.now)
    handleRecordingSilenceAction(action)
  }

  private func stopRecordingFromSilencePrompt() {
    recordingSilenceTask?.cancel()
    recordingSilenceTask = nil
    _ = recordingSilenceMonitor.stop()
    Task { [weak self] in
      await self?.stopRecording(reason: .promptConfirmed)
    }
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

  private func handleTranscriptionEvent(_ event: TranscriptionQueueEvent) -> Bool {
    switch event {
    case .modelDownloadProgress(let modelIdentifier, let progress):
      if modelIdentifier == transcriptionPreferences.configuration.modelIdentifier {
        modelReadiness = .downloading(progress)
      }
      return true
    case .modelReady(let modelIdentifier):
      if modelIdentifier == transcriptionPreferences.configuration.modelIdentifier {
        modelReadiness = .ready
      }
      return true
    case .speakerModelPreparing:
      speakerModelReadiness = .downloading(0)
      return true
    case .speakerModelReady:
      speakerModelReadiness = .ready
      return true
    case .speakerModelFailed(let message):
      speakerModelReadiness = .failed(message)
      return true
    case .started(let id, let provider, let modelIdentifier):
      Task {
        await meetingTitleQueue.pauseProcessing()
      }
      guard let recording = recording(id: id) else {
        return false
      }
      recording.status = .transcribing
      recording.transcriptionProvider = provider
      recording.modelIdentifier = modelIdentifier
      recording.errorMessage = nil
      return save(recording)
    case .idle:
      Task {
        await meetingTitleQueue.resumeProcessing()
      }
      return true
    case .completed(
      let id,
      let transcript,
      let language,
      let provider,
      let modelIdentifier,
      let warnings
    ):
      guard let recording = recording(id: id) else {
        return false
      }
      recording.transcript = transcript
      recording.detectedLanguage = language
      recording.transcriptionProvider = provider
      recording.modelIdentifier = modelIdentifier
      recording.captureWarnings.removeAll {
        $0.hasPrefix("Speaker detection was unavailable for ")
      }
      for warning in warnings where !recording.captureWarnings.contains(warning) {
        recording.captureWarnings.append(warning)
      }
      recording.status = .ready
      recording.errorMessage = nil
      let wasSaved = save(recording)
      enqueueTitle(for: recording)
      bannerPresenter.presentInformation(title: "Transcript ready", body: recording.title)
      return wasSaved
    case .failed(let id, let message):
      guard let recording = recording(id: id) else {
        return false
      }
      recording.status = .failed
      recording.errorMessage = message
      let wasSaved = save(recording)
      bannerPresenter.presentInformation(
        title: "Transcription failed",
        body: "Open MeetingBar to retry \(recording.title).",
        isError: true
      )
      return wasSaved
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
