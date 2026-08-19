import Carbon.HIToolbox
import KeyboardShortcuts
import SwiftUI

struct MeetingShortcutRecorder: View {
  var body: some View {
    KeyboardShortcuts.Recorder("", name: .toggleMeetingRecording)
      .shortcutValidation { shortcut in
        GlobalShortcutConflictValidator.validate(shortcut)
      }
      .keyboardShortcutsConflictPolicy(
        .init(menuItem: .block, systemShortcut: .block, disallowed: .block)
      )
  }
}

@MainActor
private enum GlobalShortcutConflictValidator {
  static func validate(
    _ shortcut: KeyboardShortcuts.Shortcut
  ) -> KeyboardShortcuts.ValidationResult {
    if KeyboardShortcuts.Name.toggleMeetingRecording.shortcut == shortcut {
      return .allow
    }

    var hotKeyReference: EventHotKeyRef?
    let status = RegisterEventHotKey(
      UInt32(shortcut.carbonKeyCode),
      UInt32(shortcut.carbonModifiers),
      EventHotKeyID(signature: 0x4D425652, id: 1),
      GetEventDispatcherTarget(),
      0,
      &hotKeyReference
    )
    guard status == noErr, let hotKeyReference else {
      return .disallow(reason: "That shortcut is already used by another app.")
    }

    UnregisterEventHotKey(hotKeyReference)
    return .allow
  }
}

