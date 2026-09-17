import AppKit
import Combine
import SwiftUI

@MainActor
final class AppBannerPresenter {
  enum ContinuationKind {
    case silence
    case onlineMeetingEnded
  }

  private enum Priority: Int {
    case information
    case meetingReminder
    case recordingContinuation
  }

  private var panel: NSPanel?
  private var currentPriority: Priority?
  private var contentModel: AppBannerContent?
  private var dismissTask: Task<Void, Never>?
  private var countdownTask: Task<Void, Never>?
  private var automaticPrimaryAction = false
  private var onPrimaryAction: (() -> Void)?
  private var onSecondaryAction: (() -> Void)?
  private var presentationID = UUID()
  private(set) var countdown: RecordingPromptCountdown?
  private(set) var continuationKind: ContinuationKind?

  func presentMeetingReminder(
    applicationName: String,
    isPreview: Bool = false,
    onStartRecording: @escaping () -> Void,
    onCancel: (() -> Void)? = nil
  ) {
    present(
      title: isPreview ? "Preview: record this meeting?" : "Record this meeting?",
      body: isPreview
        ? "This is a preview. No audio will be recorded."
        : "\(applicationName) is using your microphone. Choose Not Now to skip recording.",
      symbolName: "waveform.circle.fill",
      primaryActionTitle: RecordingPromptCountdown.Action.startRecording.buttonTitle,
      secondaryActionTitle: "Not Now",
      secondaryActionIsDestructive: false,
      priority: .meetingReminder,
      placement: .center,
      duration: nil,
      countdown: RecordingPromptCountdown(
        action: .startRecording,
        totalSeconds: RecordingPromptCountdown.startDurationSeconds
      ),
      automaticPrimaryAction: true,
      onPrimaryAction: onStartRecording,
      onSecondaryAction: onCancel
    )
  }

  func dismissMeetingReminder() {
    guard currentPriority == .meetingReminder else { return }
    dismiss()
  }

  func presentRecordingSilenceReminder(
    secondsRemaining: Int,
    onKeepRecording: @escaping () -> Void,
    onStopRecording: @escaping () -> Void
  ) {
    present(
      title: "Still recording?",
      body: "No microphone or system audio for five minutes.",
      symbolName: "timer",
      primaryActionTitle: RecordingPromptCountdown.Action.stopRecording.buttonTitle,
      secondaryActionTitle: "Keep Recording",
      secondaryActionIsDestructive: false,
      priority: .recordingContinuation,
      placement: .center,
      duration: nil,
      countdown: RecordingPromptCountdown(
        action: .stopRecording, totalSeconds: 30, secondsRemaining: secondsRemaining
      ),
      continuationKind: .silence,
      onPrimaryAction: onStopRecording,
      onSecondaryAction: onKeepRecording
    )
  }

  func updateRecordingSilenceReminder(secondsRemaining: Int) {
    guard continuationKind == .silence else {
      return
    }
    synchronizeCountdown(secondsRemaining: secondsRemaining)
  }

  func presentOnlineMeetingEndedReminder(
    applicationName: String,
    secondsRemaining: Int,
    onKeepRecording: @escaping () -> Void,
    onStopRecording: @escaping () -> Void
  ) {
    present(
      title: "Call ended?",
      body: "\(applicationName) stopped using your microphone.",
      symbolName: "mic.slash.fill",
      primaryActionTitle: RecordingPromptCountdown.Action.stopRecording.buttonTitle,
      secondaryActionTitle: "Keep Recording",
      secondaryActionIsDestructive: false,
      priority: .recordingContinuation,
      placement: .center,
      duration: nil,
      countdown: RecordingPromptCountdown(
        action: .stopRecording, totalSeconds: 30, secondsRemaining: secondsRemaining
      ),
      continuationKind: .onlineMeetingEnded,
      onPrimaryAction: onStopRecording,
      onSecondaryAction: onKeepRecording
    )
  }

  func updateOnlineMeetingEndedReminder(
    secondsRemaining: Int
  ) {
    guard continuationKind == .onlineMeetingEnded else {
      return
    }
    synchronizeCountdown(secondsRemaining: secondsRemaining)
  }

  func dismissRecordingContinuationReminder(kind: ContinuationKind? = nil) {
    guard currentPriority == .recordingContinuation,
      kind == nil || kind == continuationKind
    else {
      return
    }
    dismiss()
  }

  func presentInformation(title: String, body: String, isError: Bool = false) {
    present(
      title: title,
      body: body,
      symbolName: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
      primaryActionTitle: nil,
      secondaryActionTitle: "Dismiss",
      secondaryActionIsDestructive: false,
      priority: .information,
      placement: .topTrailing,
      duration: .seconds(10),
      onPrimaryAction: nil,
      onSecondaryAction: nil
    )
  }

  func dismiss() {
    presentationID = UUID()
    dismissTask?.cancel()
    dismissTask = nil
    countdownTask?.cancel()
    countdownTask = nil
    countdown = nil
    automaticPrimaryAction = false
    onPrimaryAction = nil
    onSecondaryAction = nil
    continuationKind = nil
    panel?.orderOut(nil)
    panel?.close()
    panel = nil
    currentPriority = nil
    contentModel = nil
  }

  func performPrimaryAction() {
    let action = onPrimaryAction
    dismiss()
    action?()
  }

  func performSecondaryAction() {
    let action = onSecondaryAction
    dismiss()
    action?()
  }

  func advanceCountdown(at now: ContinuousClock.Instant) {
    guard let countdown else { return }
    contentModel?.countdown = countdown.display(at: now)
    if now >= countdown.deadline, automaticPrimaryAction {
      performPrimaryAction()
    }
  }

  private func synchronizeCountdown(secondsRemaining: Int) {
    guard let countdown else { return }
    // The recording monitors own stop deadlines. Correct drift after a delayed tick.
    self.countdown = RecordingPromptCountdown(
      action: countdown.action,
      totalSeconds: countdown.totalSeconds,
      secondsRemaining: secondsRemaining
    )
    advanceCountdown(at: .now)
  }

  private func present(
    title: String,
    body: String,
    symbolName: String,
    primaryActionTitle: String?,
    secondaryActionTitle: String,
    secondaryActionIsDestructive: Bool,
    priority: Priority,
    placement: AppBannerPlacement,
    duration: Duration?,
    countdown: RecordingPromptCountdown? = nil,
    automaticPrimaryAction: Bool = false,
    continuationKind: ContinuationKind? = nil,
    onPrimaryAction: (() -> Void)?,
    onSecondaryAction: (() -> Void)?
  ) {
    guard currentPriority == nil || priority.rawValue >= (currentPriority?.rawValue ?? 0) else {
      return
    }

    dismiss()
    currentPriority = priority
    presentationID = UUID()
    let currentPresentationID = presentationID
    self.countdown = countdown
    self.automaticPrimaryAction = automaticPrimaryAction
    self.continuationKind = continuationKind
    self.onPrimaryAction = onPrimaryAction
    self.onSecondaryAction = onSecondaryAction
    let contentModel = AppBannerContent(message: body, countdown: countdown?.display(at: .now))
    self.contentModel = contentModel

    let contentView = AppBannerView(
      title: title,
      content: contentModel,
      symbolName: symbolName,
      primaryActionTitle: primaryActionTitle,
      secondaryActionTitle: secondaryActionTitle,
      secondaryActionIsDestructive: secondaryActionIsDestructive,
      onSecondaryAction: { [weak self] in
        guard self?.presentationID == currentPresentationID else { return }
        self?.performSecondaryAction()
      },
      onPrimaryAction: { [weak self] in
        guard self?.presentationID == currentPresentationID else { return }
        self?.performPrimaryAction()
      }
    )
    .frame(width: 420)
    .fixedSize(horizontal: false, vertical: true)

    let hostingView = NSHostingView(rootView: contentView)
    hostingView.sizingOptions = [.intrinsicContentSize]
    hostingView.layoutSubtreeIfNeeded()
    let panelSize = CGSize(
      width: 420,
      height: max(126, ceil(hostingView.fittingSize.height))
    )
    hostingView.sizingOptions = []
    hostingView.frame = CGRect(origin: .zero, size: panelSize)
    hostingView.autoresizingMask = [.width, .height]

    let panel = ActionableBannerPanel(
      contentRect: CGRect(origin: .zero, size: panelSize),
      styleMask: [.borderless, .nonactivatingPanel],
      backing: .buffered,
      defer: false
    )
    panel.title = title
    panel.isFloatingPanel = true
    panel.becomesKeyOnlyIfNeeded = true
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
    panel.animationBehavior = .utilityWindow
    panel.isOpaque = false
    panel.backgroundColor = .clear
    panel.hasShadow = true
    panel.contentView = hostingView
    panel.setContentSize(panelSize)

    let screen =
      NSScreen.screens.first {
        NSMouseInRect(NSEvent.mouseLocation, $0.frame, false)
      } ?? NSScreen.main
    if let visibleFrame = screen?.visibleFrame {
      panel.setFrameOrigin(
        AppBannerPosition.origin(
          panelSize: panelSize,
          visibleFrame: visibleFrame,
          placement: placement
        )
      )
    }

    self.panel = panel
    panel.orderFrontRegardless()

    if countdown != nil {
      countdownTask = Task { [weak self] in
        while !Task.isCancelled {
          try? await Task.sleep(for: .milliseconds(100))
          guard !Task.isCancelled, self?.presentationID == currentPresentationID else { return }
          self?.advanceCountdown(at: .now)
        }
      }
    }

    if let duration {
      dismissTask = Task { [weak self] in
        try? await Task.sleep(for: duration)
        guard !Task.isCancelled, self?.presentationID == currentPresentationID else {
          return
        }
        self?.dismiss()
      }
    }
  }
}

enum AppBannerPlacement {
  case center
  case topTrailing
}

enum AppBannerPosition {
  static func origin(
    panelSize: CGSize,
    visibleFrame: CGRect,
    placement: AppBannerPlacement,
    margin: CGFloat = 16
  ) -> CGPoint {
    switch placement {
    case .center:
      CGPoint(
        x: visibleFrame.midX - panelSize.width / 2,
        y: visibleFrame.midY - panelSize.height / 2
      )
    case .topTrailing:
      CGPoint(
        x: visibleFrame.maxX - panelSize.width - margin,
        y: visibleFrame.maxY - panelSize.height - margin
      )
    }
  }
}

private final class ActionableBannerPanel: NSPanel {
  override var canBecomeKey: Bool {
    true
  }

  override var canBecomeMain: Bool {
    false
  }
}

@MainActor
private final class AppBannerContent: ObservableObject {
  let message: String
  @Published var countdown: RecordingPromptCountdownDisplay?

  init(message: String, countdown: RecordingPromptCountdownDisplay?) {
    self.message = message
    self.countdown = countdown
  }
}

private struct AppBannerView: View {
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  let title: String
  @ObservedObject var content: AppBannerContent
  let symbolName: String
  let primaryActionTitle: String?
  let secondaryActionTitle: String
  let secondaryActionIsDestructive: Bool
  let onSecondaryAction: () -> Void
  let onPrimaryAction: () -> Void

  private var symbolColor: Color {
    if symbolName.contains("exclamationmark")
      || symbolName.contains("timer")
      || symbolName.contains("mic.slash")
    {
      return MeetingBarTheme.amber
    }
    if symbolName.contains("checkmark") {
      return MeetingBarTheme.mint
    }
    return MeetingBarTheme.accent
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 13) {
      HStack(alignment: .top, spacing: 13) {
        MeetingBarIconTile(
          symbol: symbolName,
          color: symbolColor,
          size: 40
        )
        VStack(alignment: .leading, spacing: 4) {
          Text(title)
            .font(.headline)
          Text(content.message)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .lineSpacing(1)
            .fixedSize(horizontal: false, vertical: true)
        }
        Spacer(minLength: 0)
      }

      if let countdown = content.countdown {
        VStack(alignment: .leading, spacing: 8) {
          Text(countdown.message)
            .font(.subheadline.weight(.semibold))
            .monospacedDigit()
          GeometryReader { geometry in
            Capsule()
              .fill(MeetingBarTheme.accent.opacity(0.14))
              .overlay(alignment: .leading) {
                Capsule()
                  .fill(MeetingBarTheme.accentGradient)
                  .frame(width: geometry.size.width * countdown.fractionRemaining)
              }
          }
          .frame(height: 4)
          .animation(
            reduceMotion ? nil : .linear(duration: 0.1),
            value: countdown.fractionRemaining
          )
          .accessibilityHidden(true)
        }
        .accessibilityElement(children: .combine)
      }

      HStack(spacing: 8) {
        Spacer()
        Button(secondaryActionTitle, action: onSecondaryAction)
          .buttonStyle(
            AppBannerSecondaryButtonStyle(isDestructive: secondaryActionIsDestructive)
          )
          .keyboardShortcut(.cancelAction)
        if let primaryActionTitle {
          Button(primaryActionTitle, action: onPrimaryAction)
            .buttonStyle(AppBannerPrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
        }
      }
    }
    .padding(16)
    .padding(.top, 2)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.thickMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    .overlay(alignment: .top) {
      LinearGradient(
        colors: [MeetingBarTheme.accent.opacity(0.80), MeetingBarTheme.coral.opacity(0.58)],
        startPoint: .leading,
        endPoint: .trailing
      )
      .frame(height: 2)
      .clipShape(
        UnevenRoundedRectangle(
          topLeadingRadius: 18,
          topTrailingRadius: 18
        )
      )
    }
    .overlay {
      RoundedRectangle(cornerRadius: 18, style: .continuous)
        .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
    }
    .padding(1)
  }
}

private struct AppBannerPrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(.white)
      .padding(.horizontal, 15)
      .frame(height: 34)
      .background(MeetingBarTheme.accentGradient, in: RoundedRectangle(cornerRadius: 10))
      .opacity(configuration.isPressed ? 0.84 : 1)
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
  }
}

private struct AppBannerSecondaryButtonStyle: ButtonStyle {
  let isDestructive: Bool

  func makeBody(configuration: Configuration) -> some View {
    let color = isDestructive ? MeetingBarTheme.coral : Color.secondary
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(color)
      .padding(.horizontal, 14)
      .frame(height: 34)
      .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
      .overlay {
        RoundedRectangle(cornerRadius: 10)
          .stroke(color.opacity(0.14), lineWidth: 1)
      }
      .opacity(configuration.isPressed ? 0.72 : 1)
  }
}
