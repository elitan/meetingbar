# MeetingBar

MeetingBar is a private, native macOS menu-bar recorder for in-person meetings and calls. It captures your preferred available microphone and system audio, transcribes entirely on-device with WhisperKit, detects speakers on-device with SpeakerKit, and keeps a searchable local transcript library.

Important meetings can be pinned above the chronological library, and titles can be renamed directly in the left list by double-clicking or using the context menu. When multiple speakers are detected, transcripts are split into turns prefixed with `Speaker 0`, `Speaker 1`, and so on. Single-speaker transcripts remain plain text. Speaker numbers are local to each meeting and assigned by first appearance.

Audio plays directly inside MeetingBar. Playback measures and balances the retained microphone and system tracks independently for every recording, regardless of the connected device, then applies a soft limiter without changing either source file. Transcription uses the same timestamp-aligned tracks so each side can be normalized and recognized independently before the transcript is merged. This avoids volume loss and speaker masking from relying only on the raw mix.

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

The first launch walks through recording consent, permissions, the on-device model downloads, the global shortcut, and launch at login. The default shortcut is Control–Option–Command–M.

Microphones can be selected directly from the menu-bar menu and ordered in Settings. MeetingBar persists each device by its macOS unique identifier, uses the first connected microphone in the priority list, falls back when it disappears, and automatically returns to a higher-priority device when it reconnects. Devices remain remembered while disconnected until explicitly forgotten.

Settings also provides:

- Automatic, Swedish, or English language selection. Automatic is the default and is recommended unless detection chooses the wrong language.
- A full `large-v3` model for best accuracy, or the smaller `large-v3-v20240930_626MB` model.

Before transcription, quiet tracks are raised toward a speech-safe level without changing the retained source recording. A limiter prevents clipping, actual audio activity is checked against Whisper timestamps to reject text invented over silence, and likely microphone echo is removed when the same speech exists on both tracks. SpeakerKit then aligns Pyannote speaker clusters to Whisper's word timestamps. If diarization is unavailable, transcription still succeeds with one fallback speaker label per active source.

Existing recordings with retained audio can be upgraded from the meeting detail view with **Detect Speakers**. This re-runs transcription and speaker detection without changing the source audio.

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

## Accuracy evaluation

Public labeled audio is used as evaluation data, not to train or fine-tune the model. The download scripts make the suite reproducible while `EvaluationFixtures/` stays out of Git:

```sh
python3 scripts/download-evaluation-fixtures.py
python3 scripts/download-ami-evaluation-fixture.py
```

The first script selects five Swedish and five English clips from Google FLEURS. The second extracts two clips from the AMI Meeting Corpus: a 34-second natural-speech WER fixture and a 60-second two-speaker handoff fixture for diarization. Both datasets are CC BY 4.0 and the generated folders include attribution.

Measured on this Mac through MeetingBar's complete preprocessing and postprocessing path:

| Model | FLEURS Swedish | FLEURS English | AMI meeting English |
| --- | ---: | ---: | ---: |
| Full `large-v3` | 9.6% WER | 3.5% WER | 9.3% WER |
| Compact 626 MB | 12.8% WER | 4.4% WER | 8.2% WER |

These are small regression sets, not broad accuracy claims. Their purpose is to catch concrete regressions in quiet-speech handling, incremental loading, multilingual decoding, and silence hallucination filtering.

After the models are downloaded by MeetingBar, run either corpus with:

```sh
scripts/run-model-benchmark.sh \
  large-v3 \
  "/path/to/openai_whisper-large-v3" \
  EvaluationFixtures/FLEURS/manifest.json
```

Use `EvaluationFixtures/AMI/manifest.json` for the meeting excerpt.

Run the same AMI excerpt through the real SpeakerKit pipeline with:

```sh
scripts/run-speaker-benchmark.sh "/path/to/MeetingBar/Models/SpeakerKit"
```

The complete Whisper-to-SpeakerKit alignment can be exercised with both downloaded model locations:

```sh
scripts/run-pipeline-benchmark.sh \
  large-v3-v20240930_626MB \
  "/path/to/openai_whisper-large-v3-v20240930_626MB" \
  "/path/to/MeetingBar/Models"
```

## Testing calls

The automated tests cover the capture state machine, hotkey debouncing, microphone priority persistence and reconnect fallback, mixer alignment/silence/clipping, partial WAV repair, queue recovery, and retention boundaries. Before relying on the app, manually test the permission and hardware scenarios in the product plan, including Zoom, Teams, a browser call, headphones, speakers, device changes, sleep/wake, and force-quit recovery.

Run the fast suite with:

```sh
xcodebuild test \
  -project MeetingBar.xcodeproj \
  -scheme MeetingBar \
  -destination 'platform=macOS,arch=arm64'
```

The opt-in real-model suite uses the same normalization, incremental VAD loading, activity filtering, and transcript normalization as the app. Generated fixtures and all personal recordings remain local.
