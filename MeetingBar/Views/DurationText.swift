import Foundation

enum DurationText {
  static func string(seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded(.down)))
    let hours = totalSeconds / 3_600
    let minutes = (totalSeconds % 3_600) / 60
    let seconds = totalSeconds % 60
    if hours > 0 {
      return String(format: "%d:%02d:%02d", hours, minutes, seconds)
    }
    return String(format: "%02d:%02d", minutes, seconds)
  }

  /// Short, glanceable length for lists: "45 sec", "32 min", "1 h 5 min".
  static func compact(seconds: TimeInterval) -> String {
    let totalSeconds = max(0, Int(seconds.rounded(.down)))
    if totalSeconds < 60 {
      return "\(totalSeconds) sec"
    }
    let totalMinutes = totalSeconds / 60
    let hours = totalMinutes / 60
    let minutes = totalMinutes % 60
    if hours == 0 {
      return "\(minutes) min"
    }
    return minutes == 0 ? "\(hours) h" : "\(hours) h \(minutes) min"
  }
}

enum MeetingDateText {
  /// "Today, 10:30", "Yesterday, 10:30", "17 Sep, 10:30", or "17 Sep 2025, 10:30" in older years.
  static func string(
    for date: Date,
    now: Date = .now,
    calendar: Calendar = .current,
    locale: Locale = .current
  ) -> String {
    var timeStyle = Date.FormatStyle(locale: locale).hour().minute()
    timeStyle.timeZone = calendar.timeZone
    let time = date.formatted(timeStyle)

    if calendar.isDate(date, inSameDayAs: now) {
      return "Today, \(time)"
    }
    if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
      calendar.isDate(date, inSameDayAs: yesterday)
    {
      return "Yesterday, \(time)"
    }

    var dayStyle = Date.FormatStyle(locale: locale).month(.abbreviated).day()
    if !calendar.isDate(date, equalTo: now, toGranularity: .year) {
      dayStyle = dayStyle.year()
    }
    dayStyle.timeZone = calendar.timeZone
    return "\(date.formatted(dayStyle)), \(time)"
  }
}
