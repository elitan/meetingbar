import SwiftUI

enum MeetingBarTheme {
  static let accent = Color(red: 0.36, green: 0.34, blue: 0.98)
  static let accentBright = Color(red: 0.47, green: 0.42, blue: 1.00)
  static let coral = Color(red: 1.00, green: 0.31, blue: 0.38)
  static let mint = Color(red: 0.16, green: 0.74, blue: 0.61)
  static let amber = Color(red: 0.96, green: 0.64, blue: 0.18)

  static var accentGradient: LinearGradient {
    LinearGradient(
      colors: [accentBright, accent],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  static var recordingGradient: LinearGradient {
    LinearGradient(
      colors: [Color(red: 1.00, green: 0.40, blue: 0.39), coral],
      startPoint: .topLeading,
      endPoint: .bottomTrailing
    )
  }

  static var subtleBorder: Color {
    Color.primary.opacity(0.10)
  }

  static var quietFill: Color {
    Color.primary.opacity(0.055)
  }
}

struct MeetingBarBackdrop: View {
  var body: some View {
    ZStack {
      Color(nsColor: .windowBackgroundColor)

      RadialGradient(
        colors: [MeetingBarTheme.accent.opacity(0.13), .clear],
        center: .topLeading,
        startRadius: 0,
        endRadius: 520
      )

      RadialGradient(
        colors: [MeetingBarTheme.coral.opacity(0.055), .clear],
        center: .bottomTrailing,
        startRadius: 0,
        endRadius: 440
      )
    }
    .ignoresSafeArea()
  }
}

struct MeetingBarLogo: View {
  var size: CGFloat = 34

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: size * 0.30, style: .continuous)
        .fill(MeetingBarTheme.accentGradient)
      Image(systemName: "waveform")
        .font(.system(size: size * 0.43, weight: .bold))
        .foregroundStyle(.white)
    }
    .frame(width: size, height: size)
    .shadow(color: MeetingBarTheme.accent.opacity(0.24), radius: 10, y: 4)
    .accessibilityHidden(true)
  }
}

struct MeetingBarCard<Content: View>: View {
  var padding: CGFloat = 18
  var cornerRadius: CGFloat = 18
  @ViewBuilder let content: Content

  init(
    padding: CGFloat = 18,
    cornerRadius: CGFloat = 18,
    @ViewBuilder content: () -> Content
  ) {
    self.padding = padding
    self.cornerRadius = cornerRadius
    self.content = content()
  }

  var body: some View {
    content
      .padding(padding)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
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
      .background(color.opacity(0.13), in: RoundedRectangle(cornerRadius: size * 0.30, style: .continuous))
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
    .padding(.horizontal, 9)
    .padding(.vertical, 5)
    .background(tone.color.opacity(0.11), in: Capsule())
    .overlay {
      Capsule()
        .stroke(tone.color.opacity(0.16), lineWidth: 1)
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
  var isRecording = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.headline)
      .foregroundStyle(.white)
      .padding(.horizontal, 16)
      .padding(.vertical, 11)
      .frame(maxWidth: .infinity)
      .background(
        isRecording ? MeetingBarTheme.recordingGradient : MeetingBarTheme.accentGradient,
        in: RoundedRectangle(cornerRadius: 12, style: .continuous)
      )
      .scaleEffect(configuration.isPressed ? 0.98 : 1)
      .opacity(configuration.isPressed ? 0.88 : 1)
      .shadow(
        color: (isRecording ? MeetingBarTheme.coral : MeetingBarTheme.accent).opacity(0.20),
        radius: 10,
        y: 4
      )
      .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
  }
}

extension View {
  func meetingBarWindowTint() -> some View {
    tint(MeetingBarTheme.accent)
  }
}
