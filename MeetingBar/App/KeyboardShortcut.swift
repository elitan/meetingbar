import KeyboardShortcuts

extension KeyboardShortcuts.Name {
  static let toggleMeetingRecording = Self(
    "toggleMeetingRecording",
    initial: .init(.m, modifiers: [.control, .option, .command])
  )
}
