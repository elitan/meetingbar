import SwiftUI

struct TranscriptCopyButton: View {
  let copy: () -> Bool
  @State private var copyResult: Bool?
  @State private var copyAttempt = 0

  var body: some View {
    Button {
      copyResult = copy()
      copyAttempt += 1
    } label: {
      // Reserve all label sizes so feedback never moves the neighboring controls.
      ZStack {
        Label("Copy", systemImage: "doc.on.doc")
          .opacity(copyResult == nil ? 1 : 0)
        Label("Copied", systemImage: "checkmark")
          .foregroundStyle(MeetingBarTheme.mint)
          .opacity(copyResult == true ? 1 : 0)
        Label("Copy failed", systemImage: "exclamationmark.triangle")
          .foregroundStyle(MeetingBarTheme.amber)
          .opacity(copyResult == false ? 1 : 0)
      }
      .fixedSize()
    }
    .buttonStyle(.borderless)
    .controlSize(.small)
    .accessibilityLabel(feedbackDescription)
    .help(feedbackDescription)
    .task(id: copyAttempt) {
      guard copyResult != nil else { return }
      do {
        try await Task.sleep(for: .seconds(2))
      } catch {
        return
      }
      copyResult = nil
    }
  }

  private var feedbackDescription: String {
    switch copyResult {
    case true:
      "Transcript copied to clipboard"
    case false:
      "Could not copy transcript. Try again."
    default:
      "Copy transcript"
    }
  }
}
