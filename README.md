# MeetingBar

MeetingBar is a private, native macOS menu-bar recorder for in-person meetings and calls. It captures the default microphone and system audio into one local WAV file, then transcribes the recording on-device with WhisperKit.

## Requirements

- Apple Silicon Mac
- macOS 26 or later
- Xcode 26 or later
- XcodeGen

## Build

```sh
xcodegen generate
xcodebuild -project MeetingBar.xcodeproj -scheme MeetingBar -configuration Debug build
```

The first launch walks through recording consent, permissions, the multilingual model download, the global shortcut, and launch at login. The default shortcut is Control–Option–Command–M.

Meeting metadata is stored with SwiftData. Audio and model files remain inside MeetingBar's Application Support container. Completed source audio is removed after 30 days; transcripts remain.

## Release installation

If an Apple Development identity is available, select it in Xcode before archiving. For a local-only build on a Mac without a developer identity, use MeetingBar's stable designated requirement when applying the hardened ad-hoc signature:

```sh
codesign --force --deep --sign - --options runtime \
  --entitlements MeetingBar/Resources/MeetingBar.entitlements \
  --requirements MeetingBar/Resources/MeetingBar.requirements \
  /path/to/MeetingBar.app
```

Then copy `MeetingBar.app` to `/Applications`. Keep the bundle identifier and designated requirement unchanged so macOS can associate future personal builds with the same recording permissions. This local signature is not suitable for distributing the app to other Macs.

## Testing calls

The automated tests cover the capture state machine, hotkey debouncing, mixer alignment/silence/clipping, partial WAV repair, queue recovery, and retention boundaries. Before relying on the app, manually test the permission and hardware scenarios in the product plan, including Zoom, Teams, a browser call, headphones, speakers, device changes, sleep/wake, and force-quit recovery.

Run the fast suite with:

```sh
xcodebuild test \
  -project MeetingBar.xcodeproj \
  -scheme MeetingBar \
  -destination 'platform=macOS,arch=arm64'
```

The real WhisperKit suite is opt-in because it needs the 626 MB model and local audio fixtures named `swedish.wav`, `english.wav`, `silence.wav`, and `long-bilingual.wav`:

```sh
MEETINGBAR_RUN_MODEL_TESTS=1 \
MEETINGBAR_MODEL_PATH=/path/to/large-v3-v20240930_626MB \
MEETINGBAR_AUDIO_FIXTURES=/path/to/fixtures \
xcodebuild test \
  -project MeetingBar.xcodeproj \
  -scheme MeetingBar \
  -destination 'platform=macOS,arch=arm64' \
  -only-testing:MeetingBarTests/RealModelIntegrationTests
```

The real-model suite exercises automatic language detection and incremental VAD loading for Swedish, English, silence, and a long bilingual recording. Its audio remains local.
