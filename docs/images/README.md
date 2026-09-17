# Product screenshot

`meetingbar-transcript.png` is a native AppKit/SwiftUI render of MeetingBar's Graphite transcript and playback view, created by `ProductScreenshotTests.testTranscriptScreenshotWithFictionalMeeting` on macOS 26. It shows the actual `RecordingDetailView` in isolation; the library sidebar and window chrome are outside the image.

All meeting titles, dates, durations, and transcript text are fictional fixtures. The test uses an in-memory SwiftData store, a unique temporary file directory, an isolated preferences suite, and `EmptyTranscriptionSecretStore`. It never calls the application launch/recovery flow, records, plays audio, downloads a model, or starts transcription. The audio control is backed by a silent test fixture solely to render the available-player state.

This is the actual product UI, not an image-generated mockup. Regenerate the test attachment and visually inspect it before replacing the image. Do not substitute a screenshot containing personal meetings or credentials.
