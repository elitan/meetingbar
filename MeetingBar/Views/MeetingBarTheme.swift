import SwiftUI

enum MeetingBarTheme {
  static let canvas = Color(red: 0.055, green: 0.060, blue: 0.065)
  static let sidebar = Color(red: 0.080, green: 0.085, blue: 0.090)
  static let surface = Color(red: 0.105, green: 0.110, blue: 0.118)
  static let selection = Color(red: 0.155, green: 0.163, blue: 0.175)
  static let accent = Color(white: 0.90)
  static let text = Color(white: 0.94)
  static let controlTint = Color(red: 0.38, green: 0.40, blue: 0.43)
  static let coral = Color(red: 1.00, green: 0.39, blue: 0.42)
  static let mint = Color(red: 0.43, green: 0.76, blue: 0.61)
  static let amber = Color(red: 0.92, green: 0.71, blue: 0.40)

  static var subtleBorder: Color {
    Color.white.opacity(0.10)
  }

  static var quietFill: Color {
    Color.white.opacity(0.045)
  }
}

struct MeetingBarBackdrop: View {
  var body: some View {
    MeetingBarTheme.canvas.ignoresSafeArea()
  }
}

struct MeetingBarLogo: View {
  var size: CGFloat = 34

  var body: some View {
    Image(systemName: "waveform")
      .font(.system(size: size * 0.72, weight: .medium))
      .foregroundStyle(MeetingBarTheme.text)
      .frame(width: size, height: size)
      .accessibilityHidden(true)
  }
}

struct MeetingBarCard<Content: View>: View {
  var padding: CGFloat = 18
  var cornerRadius: CGFloat = 10
  @ViewBuilder let content: Content

  init(
    padding: CGFloat = 18,
    cornerRadius: CGFloat = 10,
    @ViewBuilder content: () -> Content
  ) {
    self.padding = padding
    self.cornerRadius = cornerRadius
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .background(
        MeetingBarTheme.surface,
        in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
          .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
      }
  }
}

struct MeetingBarIconTile: View {
  let symbol: String
  var color: Color = MeetingBarTheme.accent
  var size: CGFloat = 38

  var body: some View {
    Image(systemName: symbol)
      .font(.system(size: size * 0.40, weight: .semibold))
      .symbolRenderingMode(.hierarchical)
      .foregroundStyle(color)
      .frame(width: size, height: size)
      .background(
        color.opacity(0.07), in: RoundedRectangle(cornerRadius: size * 0.23, style: .continuous)
      )
      .accessibilityHidden(true)
  }
}

enum MeetingBarStatusTone {
  case accent
  case recording
  case success
  case warning
  case neutral

  var color: Color {
    switch self {
    case .accent:
      MeetingBarTheme.accent
    case .recording:
      MeetingBarTheme.coral
    case .success:
      MeetingBarTheme.mint
    case .warning:
      MeetingBarTheme.amber
    case .neutral:
      .secondary
    }
  }
}

struct MeetingBarPill: View {
  let text: String
  var symbol: String?
  var tone: MeetingBarStatusTone = .neutral

  var body: some View {
    HStack(spacing: 5) {
      if let symbol {
        Image(systemName: symbol)
      }
      Text(text)
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(tone.color)
    .padding(.horizontal, 7)
    .padding(.vertical, 4)
    .background(tone.color.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    .overlay {
      RoundedRectangle(cornerRadius: 6)
        .stroke(tone.color.opacity(0.12), lineWidth: 1)
    }
  }
}

struct MeetingBarSectionHeader: View {
  let title: String
  var detail: String?

  var body: some View {
    HStack(alignment: .firstTextBaseline) {
      Text(title)
        .font(.title3.weight(.semibold))
      Spacer()
      if let detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.tertiary)
      }
    }
  }
}

struct MeetingBarAudioMeter: View {
  let microphoneLevel: Float
  let systemLevel: Float
  var barCount = 22
  var color: Color = MeetingBarTheme.coral

  private var normalizedLevel: Double {
    let level = max(microphoneLevel, systemLevel)
    guard level > 0 else {
      return 0
    }
    let decibels = 20 * log10(Double(level))
    return min(1, max(0, (decibels + 58) / 50))
  }

  var body: some View {
    GeometryReader { proxy in
      let spacing: CGFloat = 3
      let width = max(2, (proxy.size.width - CGFloat(barCount - 1) * spacing) / CGFloat(barCount))
      HStack(alignment: .center, spacing: spacing) {
        ForEach(0..<barCount, id: \.self) { index in
          let position = Double(index) / Double(max(1, barCount - 1))
          let envelope = 0.42 + 0.58 * abs(sin(position * .pi * 2.4 + 0.7))
          let height = max(3, proxy.size.height * normalizedLevel * envelope)
          Capsule()
            .fill(indexIsActive(index) ? color : Color.primary.opacity(0.10))
            .frame(width: width, height: height)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .accessibilityElement(children: .ignore)
    .accessibilityLabel("Audio level")
    .accessibilityValue(normalizedLevel > 0.05 ? "Active" : "Quiet")
  }

  private func indexIsActive(_ index: Int) -> Bool {
    Double(index + 1) / Double(barCount) <= normalizedLevel
  }
}

struct MeetingBarPrimaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  var isRecording = false
  var fillsWidth = true

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.semibold))
      .foregroundStyle(MeetingBarTheme.canvas)
      .padding(.horizontal, 14)
      .padding(.vertical, fillsWidth ? 11 : 8)
      .frame(maxWidth: fillsWidth ? .infinity : nil)
      .background(
        isRecording ? MeetingBarTheme.coral : MeetingBarTheme.accent,
        in: RoundedRectangle(cornerRadius: 8, style: .continuous)
      )
      .opacity(!isEnabled ? 0.40 : configuration.isPressed ? 0.78 : 1)
  }
}

struct MeetingBarSecondaryButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.subheadline.weight(.medium))
      .foregroundStyle(MeetingBarTheme.text)
      .padding(.horizontal, 10)
      .padding(.vertical, 6)
      .background(MeetingBarTheme.quietFill, in: RoundedRectangle(cornerRadius: 6))
      .overlay {
        RoundedRectangle(cornerRadius: 6)
          .stroke(MeetingBarTheme.subtleBorder, lineWidth: 1)
      }
      .opacity(!isEnabled ? 0.40 : configuration.isPressed ? 0.70 : 1)
  }
}

extension View {
  func meetingBarWindowTint() -> some View {
    tint(MeetingBarTheme.controlTint)
      .foregroundStyle(MeetingBarTheme.text)
      .preferredColorScheme(.dark)
      .environment(\.colorScheme, .dark)
  }
}
