#if canImport(EventKit)
  import EventKit
  import EventModels
  import Foundation
  import ReminderKitBridge

  /// Applies only the explicitly requested scheduling changes. No persistence here.
  struct ReminderSchedule {
    struct Recurrence: Decodable {
      let frequency: String
      let interval: Int?
      let endDate: String?
    }

    var recurrence: String?
    var clearRecurrence = false
    var earlyReminder: Int?
    var clearEarlyReminder = false
    var urgent: Bool?

    func apply(to reminder: EKReminder) throws {
      guard !(clearRecurrence && recurrence != nil),
        !(clearEarlyReminder && earlyReminder != nil)
      else { throw EventCLIError.invalidInput("Choose either a value or its clear flag.") }
      if let earlyReminder, earlyReminder < 1 || earlyReminder > Int(Int32.max) {
        throw EventCLIError.invalidInput("Early reminder must be a positive number of minutes.")
      }

      var newRule: EKRecurrenceRule?
      if let recurrence {
        let data = Data(recurrence.utf8)
        let spec: Recurrence
        do { spec = try JSONDecoder().decode(Recurrence.self, from: data) } catch {
          throw EventCLIError.invalidInput("Invalid recurrence JSON: \(error.localizedDescription)")
        }
        let frequency: EKRecurrenceFrequency
        switch spec.frequency {
        case "daily": frequency = .daily
        case "weekly": frequency = .weekly
        case "monthly": frequency = .monthly
        case "yearly": frequency = .yearly
        default: throw EventCLIError.invalidInput("Unsupported recurrence frequency.")
        }
        let interval = spec.interval ?? 1
        guard interval > 0, interval <= Int(Int32.max) else {
          throw EventCLIError.invalidInput("Recurrence interval must be a positive integer.")
        }
        guard let components = reminder.dueDateComponents,
          let due = resolvedDate(components)
        else { throw EventCLIError.invalidInput("Recurrence requires a due date.") }
        var end: EKRecurrenceEnd?
        if let input = spec.endDate {
          // A date-only end includes the entire final day in the reminder's zone.
          var calendar = Calendar(identifier: .gregorian)
          calendar.timeZone = components.timeZone ?? .current
          let date: Date
          if input.count == 10 {
            let formatter = DateFormatter()
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyy-MM-dd"
            formatter.isLenient = false
            guard let day = formatter.date(from: input), formatter.string(from: day) == input,
              let next = calendar.date(byAdding: .day, value: 1, to: day)
            else { throw EventCLIError.invalidInput("Invalid recurrence end date.") }
            date = next.addingTimeInterval(-1)
          } else {
            date = try Date.validated(dateTimeString: input)
          }
          guard date >= due else {
            throw EventCLIError.invalidInput("Recurrence end must not precede the due date.")
          }
          end = EKRecurrenceEnd(end: date)
        }
        newRule = EKRecurrenceRule(recurrenceWith: frequency, interval: interval, end: end)
      }
      if earlyReminder != nil || urgent == true {
        guard let due = reminder.dueDateComponents, due.hour != nil,
          due.minute != nil, resolvedDate(due) != nil
        else {
          throw EventCLIError.invalidInput(
            "Early reminder and Urgent require a due date with a time.")
        }
      }
      // Validate first, then mutate. Unknown/absolute and location alarms are preserved.
      if clearRecurrence || newRule != nil {
        for rule in reminder.recurrenceRules ?? [] { reminder.removeRecurrenceRule(rule) }
        if let newRule { reminder.addRecurrenceRule(newRule) }
      }
    }

    func checkNativeSupport() throws {
      if (earlyReminder != nil || clearEarlyReminder) && !ReminderKitEarlyReminderAvailable() {
        throw EventCLIError.invalidInput(
          "Native Early Reminder requires ReminderKit support on this Mac.")
      }
      if urgent != nil && !ReminderKitUrgentAvailable() {
        throw EventCLIError.invalidInput("Native Urgent requires ReminderKit support on this Mac.")
      }
    }

    func applyNativeChanges(to identifier: String) throws {
      if earlyReminder != nil || clearEarlyReminder,
        let error = ReminderKitSetEarlyReminder(identifier, earlyReminder ?? 0, clearEarlyReminder)
      {
        throw EventCLIError.invalidInput(
          "Reminder \(identifier) was saved, but native Early Reminder failed: \(error). Read that ID before retrying."
        )
      }
      if let urgent, let error = ReminderKitSetUrgent(identifier, urgent) {
        throw EventCLIError.invalidInput(
          "Reminder \(identifier) was saved, but native Urgent failed: \(error). Read that ID before retrying."
        )
      }
    }

    private func resolvedDate(_ components: DateComponents) -> Date? {
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = components.timeZone ?? .current
      return calendar.date(from: components)
    }
  }
#endif
