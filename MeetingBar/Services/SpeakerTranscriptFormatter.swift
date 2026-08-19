import Foundation

enum SpeakerTranscriptFormatter {
  private enum SpeakerIdentity: Hashable {
    case detected(source: CaptureSourceKind, speakerID: Int)
    case sourceFallback(CaptureSourceKind)
  }

  static func format(_ segments: [SourceTranscriptSegment]) -> String {
    let orderedSegments = segments.sorted(by: segmentOrder)
    let firstDetectedSpeakerBySource = firstDetectedSpeakers(in: orderedSegments)
    var lastDetectedSpeakerBySource: [CaptureSourceKind: SpeakerIdentity] = [:]
    var displayIDBySpeaker: [SpeakerIdentity: Int] = [:]
    var turns: [(speakerID: Int, text: String)] = []

    for segment in orderedSegments {
      let text = TranscriptionQueue.normalize(segment.text)
      guard !text.isEmpty else {
        continue
      }

      let identity: SpeakerIdentity
      if let localSpeakerID = segment.speakerID {
        identity = .detected(source: segment.source, speakerID: localSpeakerID)
        lastDetectedSpeakerBySource[segment.source] = identity
      } else {
        identity =
          lastDetectedSpeakerBySource[segment.source]
          ?? firstDetectedSpeakerBySource[segment.source]
          ?? .sourceFallback(segment.source)
      }

      let displayID: Int
      if let existingID = displayIDBySpeaker[identity] {
        displayID = existingID
      } else {
        displayID = displayIDBySpeaker.count
        displayIDBySpeaker[identity] = displayID
      }

      if let lastIndex = turns.indices.last, turns[lastIndex].speakerID == displayID {
        turns[lastIndex].text = TranscriptionQueue.normalize("\(turns[lastIndex].text) \(text)")
      } else {
        turns.append((speakerID: displayID, text: text))
      }
    }

    guard displayIDBySpeaker.count > 1 else {
      return TranscriptionQueue.normalize(turns.map(\.text).joined(separator: " "))
    }

    return turns
      .map { "Speaker \($0.speakerID): \($0.text)" }
      .joined(separator: "\n\n")
  }

  static func containsSpeakerLabels(_ transcript: String) -> Bool {
    transcript.split(separator: "\n").contains { rawLine in
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix("Speaker "), let colon = line.firstIndex(of: ":") else {
        return false
      }
      let numberStart = line.index(line.startIndex, offsetBy: "Speaker ".count)
      return Int(line[numberStart..<colon]) != nil
    }
  }

  private static func firstDetectedSpeakers(
    in segments: [SourceTranscriptSegment]
  ) -> [CaptureSourceKind: SpeakerIdentity] {
    var speakers: [CaptureSourceKind: SpeakerIdentity] = [:]
    for segment in segments {
      guard speakers[segment.source] == nil, let speakerID = segment.speakerID else {
        continue
      }
      speakers[segment.source] = .detected(source: segment.source, speakerID: speakerID)
    }
    return speakers
  }

  private static func segmentOrder(
    _ left: SourceTranscriptSegment,
    _ right: SourceTranscriptSegment
  ) -> Bool {
    if left.start != right.start {
      return left.start < right.start
    }
    return left.source.transcriptOrder < right.source.transcriptOrder
  }
}
