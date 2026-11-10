#if canImport(EventKit)
  import EventKit
  import XCTest
  @testable import event

  final class ReminderScheduleTests: XCTestCase {
    private func makeReminder() -> EKReminder {
      let reminder = EKReminder(eventStore: EKEventStore())
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = TimeZone(identifier: "Europe/Paris")!
      let due = calendar.date(byAdding: .day, value: 10, to: Date())!
      reminder.dueDateComponents = calendar.dateComponents(
        [.calendar, .timeZone, .year, .month, .day, .hour, .minute, .second], from: due)
      return reminder
    }

    func testSupportedRecurrencesAndEarlyAlert() throws {
      for (name, frequency) in [
        ("daily", EKRecurrenceFrequency.daily), ("weekly", .weekly),
        ("monthly", .monthly), ("yearly", .yearly),
      ] {
        let reminder = makeReminder()
        try ReminderSchedule(
          recurrence: "{\"frequency\":\"\(name)\",\"interval\":2}", earlyReminder: 45
        ).apply(to: reminder)
        XCTAssertEqual(reminder.recurrenceRules?.first?.frequency, frequency)
        XCTAssertEqual(reminder.recurrenceRules?.first?.interval, 2)
        XCTAssertTrue(reminder.alarms?.isEmpty ?? true)
      }
    }

    func testClearPreservesDueAbsoluteAndLocationAlerts() throws {
      let reminder = makeReminder()
      let absoluteDate = Date().addingTimeInterval(300)
      reminder.addAlarm(EKAlarm(absoluteDate: absoluteDate))
      let storedAbsoluteDate = reminder.alarms!.first!.absoluteDate
      reminder.addAlarm(EKAlarm(relativeOffset: 0))
      let location = EKAlarm()
      location.structuredLocation = EKStructuredLocation(title: "Home")
      location.proximity = .enter
      reminder.addAlarm(location)
      try ReminderSchedule(recurrence: "{\"frequency\":\"monthly\"}", earlyReminder: 30).apply(
        to: reminder)
      try ReminderSchedule(clearRecurrence: true, clearEarlyReminder: true).apply(to: reminder)
      XCTAssertTrue(reminder.recurrenceRules?.isEmpty ?? true)
      XCTAssertEqual(reminder.alarms?.count, 3)
      XCTAssertTrue(reminder.alarms!.contains { $0.absoluteDate == storedAbsoluteDate })
      XCTAssertTrue(reminder.alarms!.contains { $0.structuredLocation != nil })
      XCTAssertTrue(
        reminder.alarms!.contains {
          $0.absoluteDate == nil && $0.structuredLocation == nil && $0.relativeOffset == 0
        })
    }

    func testOmittedSchedulingPreservesExistingRulesAndAlerts() throws {
      let reminder = makeReminder()
      try ReminderSchedule(recurrence: "{\"frequency\":\"weekly\"}", earlyReminder: 15).apply(
        to: reminder)
      try ReminderSchedule().apply(to: reminder)
      XCTAssertEqual(reminder.recurrenceRules?.first?.frequency, .weekly)
      XCTAssertTrue(reminder.alarms?.isEmpty ?? true)
    }

    func testInvalidInputsDoNotChangeExistingSchedule() throws {
      for json in [
        "{}", "{\"frequency\":\"hourly\"}", "{\"frequency\":\"daily\",\"interval\":0}",
        "{\"frequency\":\"daily\",\"endDate\":\"2000-01-01\"}",
      ] {
        let reminder = makeReminder()
        reminder.addAlarm(EKAlarm(relativeOffset: -600))
        XCTAssertThrowsError(
          try ReminderSchedule(recurrence: json, earlyReminder: 40).apply(to: reminder))
        XCTAssertEqual(reminder.alarms?.first?.relativeOffset, -600)
      }
      let reminder = makeReminder()
      reminder.dueDateComponents = nil
      XCTAssertThrowsError(
        try ReminderSchedule(recurrence: "{\"frequency\":\"daily\"}").apply(to: reminder))
      XCTAssertThrowsError(try ReminderSchedule(earlyReminder: 30).apply(to: reminder))
    }

    func testUrgentRequiresTimedDueOnlyWhenEnabling() throws {
      let reminder = makeReminder()
      XCTAssertNoThrow(try ReminderSchedule(urgent: true).apply(to: reminder))
      reminder.dueDateComponents = nil
      XCTAssertThrowsError(try ReminderSchedule(urgent: true).apply(to: reminder))
      XCTAssertNoThrow(try ReminderSchedule(urgent: false).apply(to: reminder))
      XCTAssertNoThrow(try ReminderSchedule().apply(to: reminder))
      reminder.dueDateComponents = Calendar.current.dateComponents(
        [.year, .month, .day], from: Date())
      XCTAssertThrowsError(try ReminderSchedule(urgent: true).apply(to: reminder))
    }

    func testUrgentCommandPreservesThreeStates() throws {
      let enabled = try ReminderCommands.Create.parse(["--title", "Test", "--urgent", "true"])
      XCTAssertEqual(enabled.scheduleOptions.urgent, true)
      let disabled = try ReminderCommands.Update.parse(["--id", "r", "--urgent", "false"])
      XCTAssertEqual(disabled.scheduleOptions.urgent, false)
      let omitted = try ReminderCommands.Update.parse(["--id", "r"])
      XCTAssertNil(omitted.scheduleOptions.urgent)
      XCTAssertThrowsError(try ReminderCommands.Update.parse(["--id", "r", "--urgent", "maybe"]))
    }

    func testCommandRejectsConflictingAndNonpositiveOptions() throws {
      XCTAssertThrowsError(
        try ReminderCommands.Create.parse(["--title", "Care", "--early-reminder", "0"]))
      XCTAssertThrowsError(
        try ReminderCommands.Update.parse([
          "--id", "r", "--early-reminder", "15", "--clear-early-reminder",
        ]))
      XCTAssertThrowsError(
        try ReminderCommands.Update.parse([
          "--id", "r", "--recurrence-json", "{}", "--clear-schedule-recurrence",
        ])
      )
    }
  }
#endif
