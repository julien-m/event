#if canImport(EventKit)
  import EventKit
  import EventModels
  import Foundation

  /// An explicit mutation of one absolute, non-location alarm. No positional ID is invented.
  struct TemporalReminderAlarm: Decodable {
    let action: String
    let at: String?
    let target: String?

    /// Strict whole-second RFC3339 instant, UTC range [2001,2100). No local-zone fallback.
    static func instant(_ text: String) throws -> Date {
      let pattern = #"^20\d{2}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.000)?(Z|[+-]\d{2}:\d{2})$"#
      guard text.range(of: pattern, options: .regularExpression) != nil,
        !text.hasSuffix("-00:00")
      else { throw EventCLIError.invalidInput("invalid_temporal_alarm_instant") }
      let offsetText = String(text.suffix(6))
      if !text.hasSuffix("Z") {
        guard let hours = Int(offsetText.dropFirst().prefix(2)),
          let minutes = Int(offsetText.suffix(2)), hours <= 14, minutes <= 59,
          hours != 14 || minutes == 0
        else { throw EventCLIError.invalidInput("invalid_temporal_alarm_offset") }
      }
      let formatter = DateFormatter()
      formatter.locale = Locale(identifier: "en_US_POSIX")
      formatter.calendar = Calendar(identifier: .gregorian)
      formatter.dateFormat =
        text.contains(".000") ? "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX" : "yyyy-MM-dd'T'HH:mm:ssXXXXX"
      formatter.isLenient = false
      guard let date = formatter.date(from: text) else {
        throw EventCLIError.invalidInput("invalid_temporal_alarm_instant")
      }
      // Roundtrip in the supplied offset catches calendar correction and invalid seconds.
      let zone: TimeZone?
      if text.hasSuffix("Z") {
        zone = TimeZone(secondsFromGMT: 0)
      } else {
        let hours = Int(offsetText.dropFirst().prefix(2)) ?? 0
        let minutes = Int(offsetText.suffix(2)) ?? 0
        zone = TimeZone(
          secondsFromGMT: (offsetText.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60))
      }
      formatter.timeZone = zone
      guard String(formatter.string(from: date).prefix(19)) == String(text.prefix(19)),
        date.timeIntervalSince1970 >= 978_307_200,
        date.timeIntervalSince1970 < 4_102_444_800
      else { throw EventCLIError.invalidInput("invalid_temporal_alarm_range") }
      return date
    }

    /// A targeted alarm write may set a timed due/start value using the same explicit-offset contract.
    static func dateComponents(_ text: String) throws -> DateComponents {
      let date = try instant(text)
      guard date.timeIntervalSince1970.truncatingRemainder(dividingBy: 60) == 0 else {
        throw EventCLIError.invalidInput("invalid_temporal_alarm_due_precision")
      }
      let offset = String(text.suffix(6))
      let hours = text.hasSuffix("Z") ? 0 : (Int(offset.dropFirst().prefix(2)) ?? 0)
      let minutes = text.hasSuffix("Z") ? 0 : (Int(offset.suffix(2)) ?? 0)
      let seconds = (offset.first == "-" ? -1 : 1) * (hours * 3600 + minutes * 60)
      guard let zone = TimeZone(secondsFromGMT: seconds) else {
        throw EventCLIError.invalidInput("invalid_temporal_alarm_offset")
      }
      return DateComponentsBuilder.build(from: date, timeZone: zone)
    }

    static func decode(_ json: String) throws -> Self {
      do {
        guard
          let dictionary = try JSONSerialization.jsonObject(with: Data(json.utf8))
            as? [String: Any],
          let action = dictionary["action"] as? String,
          let keys = [
            "add": Set(["action", "at"]), "replace": Set(["action", "target", "at"]),
            "clear": Set(["action", "target"]),
          ][action],
          Set(dictionary.keys) == keys
        else { throw EventCLIError.invalidInput("invalid_temporal_alarm_shape") }
        return try JSONDecoder().decode(Self.self, from: Data(json.utf8))
      } catch { throw EventCLIError.invalidInput("invalid_temporal_alarm_shape") }
    }

    /// Selection is independent of array position; duplicate native observations are rejected.
    static func selectedTarget(in alarms: [EKAlarm], date: Date) throws -> EKAlarm {
      let matches = alarms.filter { $0.structuredLocation == nil && $0.absoluteDate == date }
      guard matches.count == 1 else {
        throw EventCLIError.invalidInput(
          matches.isEmpty ? "temporal_alarm_target_missing" : "temporal_alarm_target_ambiguous")
      }
      return matches[0]
    }

    /// Validates the complete selection before changing any alarm; the caller owns save.
    func apply(to reminder: EKReminder, now: Date) throws {
      guard ["add", "replace", "clear"].contains(action),
        action == "add" ? target == nil : target != nil,
        action == "clear" ? at == nil : at != nil
      else { throw EventCLIError.invalidInput("invalid_temporal_alarm_shape") }
      let targetDate = try target.map(Self.instant)
      let newDate = try at.map(Self.instant)
      if let newDate, newDate <= now {
        throw EventCLIError.invalidInput("temporal_alarm_past")
      }
      let alarms = reminder.alarms ?? []
      let matches = try targetDate.map { [try Self.selectedTarget(in: alarms, date: $0)] } ?? []
      let remaining = alarms.filter { alarm in
        !(alarm.structuredLocation == nil && targetDate != nil && alarm.absoluteDate == targetDate)
      }
      if let newDate,
        remaining.contains(where: { $0.structuredLocation == nil && $0.absoluteDate == newDate })
      {
        throw EventCLIError.invalidInput("temporal_alarm_duplicate")
      }
      for alarm in matches { reminder.removeAlarm(alarm) }
      if let newDate { reminder.addAlarm(EKAlarm(absoluteDate: newDate)) }
    }
  }
#endif
