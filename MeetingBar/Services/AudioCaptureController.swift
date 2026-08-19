import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import Observation
import ScreenCaptureKit

enum CapturePermission: String, Sendable {
  case microphone
  case screenAndSystemAudio
}

enum AudioCaptureError: LocalizedError {
  case permissionDenied(CapturePermission)
  case noMicrophone
  case noDisplay
  case stateConflict
  case streamStopped(String)

  var errorDescription: String? {
    switch self {
    case .permissionDenied(.microphone):
      "Microphone permission is required before recording can start."
    case .permissionDenied(.screenAndSystemAudio):
      "Screen & System Audio Recording permission is required before recording can start."
    case .noMicrophone:
      "MeetingBar could not find a default microphone. Connect or select one before recording."
    case .noDisplay:
      "MeetingBar could not find a display for system-audio capture."
    case .stateConflict:
      "MeetingBar is already starting or stopping a recording."
    case .streamStopped(let message):
      "Audio capture stopped unexpectedly: \(message)"
    }
  }
}

@MainActor
@Observable
final class AudioCaptureController {
  private(set) var state: CaptureState = .idle
  private(set) var levels = CaptureLevels()
  private(set) var elapsedSeconds: TimeInterval = 0
  private(set) var latestWarning: String?
  private(set) var activeMicrophoneID: String?
  private(set) var activeMicrophoneName: String?

  var onWarning: ((String) -> Void)?
  var onFatalFailure: ((Error) -> Void)?

  private let fileStore: RecordingFileStore
  private let microphonePreferences: MicrophonePreferenceStore
  private let sampleQueue = DispatchQueue(label: "me.eliasson.meetingbar.audio-samples")
  private var stateMachine = CaptureStateMachine()
  private var stream: SCStream?
  private var streamConfiguration: SCStreamConfiguration?
  private var streamOutput: CaptureStreamOutput?
  private var streamDelegate: CaptureStreamDelegate?
  private var elapsedTask: Task<Void, Never>?
  private var processActivity: NSObjectProtocol?
  private var activeRecordingID: UUID?
  private var restartCount = 0
  private var restartInProgress = false
  private var normalStopInProgress = false
  private var streamEpoch = 0

  init(
    fileStore: RecordingFileStore,
    microphonePreferences: MicrophonePreferenceStore
  ) {
    self.fileStore = fileStore
    self.microphonePreferences = microphonePreferences
    microphonePreferences.onActiveMicrophoneChanged = { [weak self] microphone in
      guard let self else {
        return
      }
      Task { @MainActor in
        await self.applyPreferredMicrophone(microphone)
      }
    }
  }

  static var hasMicrophonePermission: Bool {
    AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
  }

  static var hasScreenPermission: Bool {
    CGPreflightScreenCaptureAccess()
  }

  static func requestMicrophonePermission() async -> Bool {
    if hasMicrophonePermission {
      return true
    }
    return await AVCaptureDevice.requestAccess(for: .audio)
  }

  static func requestScreenPermission() -> Bool {
    if hasScreenPermission {
      return true
    }
    return CGRequestScreenCaptureAccess()
  }

  func start(recordingID: UUID) async throws -> Date {
    guard state == .idle else {
      throw AudioCaptureError.stateConflict
    }
    try transition(.requestStart)

    do {
      try preflight()
      try fileStore.prepareDirectory(for: recordingID)

      let mixedWriter = try PCM16WAVWriter(
        partialURL: fileStore.partialAudioURL(for: recordingID),
        finalURL: fileStore.audioURL(for: recordingID)
      )
      let microphoneWriter = try TimestampedPCM16WAVWriter(
        kind: .microphone,
        writer: PCM16WAVWriter(
          partialURL: fileStore.partialSourceAudioURL(for: recordingID, kind: .microphone),
          finalURL: fileStore.sourceAudioURL(for: recordingID, kind: .microphone)
        )
      )
      let systemWriter = try TimestampedPCM16WAVWriter(
        kind: .system,
        writer: PCM16WAVWriter(
          partialURL: fileStore.partialSourceAudioURL(for: recordingID, kind: .system),
          finalURL: fileStore.sourceAudioURL(for: recordingID, kind: .system)
        )
      )
      let processor = AudioCaptureProcessor(
        mixedWriter: mixedWriter,
        microphoneWriter: microphoneWriter,
        systemWriter: systemWriter,
        warningHandler: { [weak self] warning in
          self?.publishWarning(warning)
        },
        levelsHandler: { [weak self] levels in
          self?.levels = levels
        }
      )
      let output = CaptureStreamOutput(processor: processor)
      let delegate = CaptureStreamDelegate { [weak self] error in
        guard let self else {
          return
        }
        Task { @MainActor in
          await self.handleUnexpectedStop(error)
        }
      }

      activeRecordingID = recordingID
      streamOutput = output
      streamDelegate = delegate
      restartCount = 0
      normalStopInProgress = false
      streamEpoch += 1
      let epoch = streamEpoch
      try await bringUpStream(output: output, delegate: delegate, epoch: epoch)

      let startedAt = Date.now
      try transition(.didStart(startedAt))
      await applyPreferredMicrophone(microphonePreferences.activeMicrophone)
      beginElapsedTimer(startedAt: startedAt)
      processActivity = ProcessInfo.processInfo.beginActivity(
        options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
        reason: "MeetingBar is recording a meeting"
      )
      return startedAt
    } catch {
      cleanupAfterStop()
      try? transition(.startFailed)
      throw error
    }
  }

  func stop() async throws -> FinalizedCapture {
    guard state.isRecording, let output = streamOutput else {
      throw AudioCaptureError.stateConflict
    }
    try transition(.requestStop)
    normalStopInProgress = true
    streamEpoch += 1

    if let stream {
      do {
        try await stream.stopCapture()
      } catch {
        publishWarning(
          "ScreenCaptureKit reported an error while stopping: \(error.localizedDescription)")
      }
    }

    do {
      let result = try sampleQueue.sync {
        try output.finish()
      }
      if let activeRecordingID {
        do {
          try writeCaptureManifest(result, recordingID: activeRecordingID)
        } catch {
          publishWarning(
            "MeetingBar saved the recording but could not save its separate-track timing. Transcription will use the combined audio."
          )
        }
      }
      cleanupAfterStop()
      try transition(.didStop)
      return result
    } catch {
      cleanupAfterStop()
      try? transition(.didStop)
      throw error
    }
  }

  private func preflight() throws {
    guard Self.hasMicrophonePermission else {
      throw AudioCaptureError.permissionDenied(.microphone)
    }
    guard Self.hasScreenPermission else {
      throw AudioCaptureError.permissionDenied(.screenAndSystemAudio)
    }
    microphonePreferences.refreshDevices()
    guard selectedMicrophoneDevice() != nil else {
      throw AudioCaptureError.noMicrophone
    }
    try fileStore.requireAvailableDiskSpace()
  }

  private func bringUpStream(
    output: CaptureStreamOutput,
    delegate: CaptureStreamDelegate,
    epoch: Int
  ) async throws {
    let content = try await SCShareableContent.excludingDesktopWindows(
      false,
      onScreenWindowsOnly: false
    )
    guard
      let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
        ?? content.displays.first
    else {
      throw AudioCaptureError.noDisplay
    }

    let filter = SCContentFilter(display: display, excludingWindows: [])
    let configuration = SCStreamConfiguration()
    configuration.width = 2
    configuration.height = 2
    configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
    configuration.queueDepth = 3
    configuration.showsCursor = false
    configuration.capturesAudio = true
    configuration.sampleRate = Int(PCM16WAVWriter.sampleRate)
    configuration.channelCount = Int(PCM16WAVWriter.channelCount)
    configuration.excludesCurrentProcessAudio = true
    configuration.captureMicrophone = true
    microphonePreferences.refreshDevices()
    guard let microphone = selectedMicrophoneDevice() else {
      throw AudioCaptureError.noMicrophone
    }
    configuration.microphoneCaptureDeviceID = microphone.uniqueID

    let newStream = SCStream(filter: filter, configuration: configuration, delegate: delegate)
    try newStream.addStreamOutput(output, type: .screen, sampleHandlerQueue: sampleQueue)
    try newStream.addStreamOutput(output, type: .audio, sampleHandlerQueue: sampleQueue)
    try newStream.addStreamOutput(output, type: .microphone, sampleHandlerQueue: sampleQueue)
    try await newStream.startCapture()

    guard epoch == streamEpoch, !normalStopInProgress else {
      try? await newStream.stopCapture()
      return
    }
    stream = newStream
    streamConfiguration = configuration
    activeMicrophoneID = microphone.uniqueID
    activeMicrophoneName = microphone.localizedName
  }

  private func selectedMicrophoneDevice() -> AVCaptureDevice? {
    guard let microphoneID = microphonePreferences.activeMicrophoneID else {
      return nil
    }
    return AVCaptureDevice(uniqueID: microphoneID)
  }

  private func applyPreferredMicrophone(_ microphone: MicrophonePreference?) async {
    guard state.isRecording, let microphone else {
      return
    }
    guard microphone.id != activeMicrophoneID else {
      return
    }
    guard let device = AVCaptureDevice(uniqueID: microphone.id),
      let stream,
      let configuration = streamConfiguration
    else {
      return
    }

    let previousMicrophoneID = activeMicrophoneID
    configuration.microphoneCaptureDeviceID = device.uniqueID
    do {
      try await stream.updateConfiguration(configuration)
      activeMicrophoneID = device.uniqueID
      activeMicrophoneName = device.localizedName
      publishWarning("Microphone switched to \(device.localizedName).")
      if microphone.id != microphonePreferences.activeMicrophoneID {
        await applyPreferredMicrophone(microphonePreferences.activeMicrophone)
      }
    } catch {
      configuration.microphoneCaptureDeviceID = previousMicrophoneID
      publishWarning(
        "MeetingBar could not switch to \(device.localizedName); the current input will continue if available."
      )
    }
  }

  private func handleUnexpectedStop(_ error: Error) async {
    guard state.isRecording, !normalStopInProgress, !restartInProgress,
      let output = streamOutput,
      let delegate = streamDelegate
    else {
      return
    }

    restartInProgress = true
    defer { restartInProgress = false }
    stream = nil
    while restartCount < 3, state.isRecording, !normalStopInProgress {
      restartCount += 1
      publishWarning(
        "Audio capture was interrupted. Restart attempt \(restartCount) of 3 is in progress."
      )
      try? await Task.sleep(for: .milliseconds(400 * restartCount))
      streamEpoch += 1
      let epoch = streamEpoch
      do {
        try await bringUpStream(output: output, delegate: delegate, epoch: epoch)
        if stream != nil {
          publishWarning("Audio capture resumed after an interruption.")
          return
        }
      } catch {
        continue
      }
    }

    let fatalError = AudioCaptureError.streamStopped(error.localizedDescription)
    onFatalFailure?(fatalError)
  }

  private func transition(_ action: CaptureAction) throws {
    try stateMachine.apply(action)
    state = stateMachine.state
  }

  private func publishWarning(_ warning: String) {
    latestWarning = warning
    onWarning?(warning)
  }

  private func writeCaptureManifest(
    _ capture: FinalizedCapture,
    recordingID: UUID
  ) throws {
    let firstPresentationTime = capture.sources.compactMap(\.firstPresentationTimeSeconds).min()
    let records = capture.sources.map { source in
      let offset =
        source.firstPresentationTimeSeconds.map { first in
          max(0, first - (firstPresentationTime ?? first))
        } ?? 0
      return CaptureSourceRecord(
        kind: source.kind,
        fileName: source.audioURL.lastPathComponent,
        offsetSeconds: offset,
        durationSeconds: source.durationSeconds,
        signal: source.signal
      )
    }
    let manifest = CaptureSourceManifest(
      microphoneID: activeMicrophoneID,
      microphoneName: activeMicrophoneName,
      sources: records
    )
    try fileStore.writeCaptureManifest(manifest, for: recordingID)
  }

  private func beginElapsedTimer(startedAt: Date) {
    elapsedTask?.cancel()
    elapsedTask = Task { [weak self] in
      while !Task.isCancelled {
        self?.elapsedSeconds = Date.now.timeIntervalSince(startedAt)
        try? await Task.sleep(for: .milliseconds(200))
      }
    }
  }

  private func cleanupAfterStop() {
    elapsedTask?.cancel()
    elapsedTask = nil
    elapsedSeconds = 0
    levels = CaptureLevels()
    stream = nil
    streamConfiguration = nil
    streamOutput = nil
    streamDelegate = nil
    activeRecordingID = nil
    normalStopInProgress = false
    restartInProgress = false
    activeMicrophoneID = nil
    activeMicrophoneName = nil
    if let processActivity {
      ProcessInfo.processInfo.endActivity(processActivity)
      self.processActivity = nil
    }
  }
}

private final class CaptureStreamOutput: NSObject, SCStreamOutput, @unchecked Sendable {
  private let processor: AudioCaptureProcessor

  init(processor: AudioCaptureProcessor) {
    self.processor = processor
  }

  func stream(
    _ stream: SCStream,
    didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
    of type: SCStreamOutputType
  ) {
    processor.process(sampleBuffer, type: type)
  }

  func finish() throws -> FinalizedCapture {
    try processor.finish()
  }
}

private final class CaptureStreamDelegate: NSObject, SCStreamDelegate, @unchecked Sendable {
  private let didStop: @Sendable (Error) -> Void

  init(didStop: @escaping @Sendable (Error) -> Void) {
    self.didStop = didStop
  }

  func stream(_ stream: SCStream, didStopWithError error: Error) {
    didStop(error)
  }
}
