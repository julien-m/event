#if canImport(EventKit)
  import EventKit
  import XCTest
  @testable import event

  final class TemporalReminderAlarmTests: XCTestCase {
    private let at = "2030-03-31T01:30:00Z"
    private let now = Date(timeIntervalSince1970: 1_893_456_000)

    func testExplicitOffsetAndCalendarValidation() throws {
      XCTAssertEqual(
        try TemporalReminderAlarm.instant(at),
        try TemporalReminderAlarm.instant("2030-03-31T03:30:00+02:00"))
      XCTAssertEqual(
        try TemporalReminderAlarm.instant(at),
        try TemporalReminderAlarm.instant("2030-03-31T01:30:00.000Z"))
      for invalid in [
        "2030-03-31 02:30:00", "2030-02-30T10:00:00Z", "2030-01-01T00:00:60Z",
        "2030-01-01T00:00:00.001Z", "2030-01-01T00:00:00-00:00", "2030-01-01T00:00:00+14:01",
        "2000-01-01T00:00:00Z",
      ] {
        XCTAssertThrowsError(try TemporalReminderAlarm.instant(invalid), invalid)
      }
    }

    func testAddReplaceClearPreservesOtherAlarmKindsAndReminderFields() throws {
      let reminder = EKReminder(eventStore: EKEventStore())
      reminder.notes = "Retained notes"
      let relative = EKAlarm(relativeOffset: -600)
      let location = EKAlarm()
      location.structuredLocation = EKStructuredLocation(title: "Place")
      location.proximity = .enter
      let unrelated = EKAlarm(absoluteDate: now.addingTimeInterval(-1000))
      for alarm in [relative, location, unrelated] { reminder.addAlarm(alarm) }
      let initialCount = reminder.alarms?.count ?? 0
      try TemporalReminderAlarm(action: "add", at: at, target: nil).apply(to: reminder, now: now)
      XCTAssertEqual(reminder.alarms?.count, initialCount + 1)
      let later = "2030-04-01T01:30:00Z"
      try TemporalReminderAlarm(action: "replace", at: later, target: at).apply(
        to: reminder, now: now)
      XCTAssertTrue(
        reminder.alarms?.contains { $0.absoluteDate == (try? TemporalReminderAlarm.instant(later)) }
          ?? false)
      try TemporalReminderAlarm(action: "clear", at: nil, target: later).apply(
        to: reminder, now: now)
      XCTAssertEqual(reminder.alarms?.count, initialCount)
      XCTAssertEqual(reminder.notes, "Retained notes")
      XCTAssertTrue(reminder.alarms?.contains { $0.structuredLocation != nil } ?? false)
      XCTAssertTrue(
        reminder.alarms?.contains {
          $0.absoluteDate == nil && $0.structuredLocation == nil && $0.relativeOffset == -600
        } ?? false)
    }

    func testRejectedMutationDoesNotChangeExistingAlarms() throws {
      let reminder = EKReminder(eventStore: EKEventStore())
      let date = try TemporalReminderAlarm.instant(at)
      reminder.addAlarm(EKAlarm(absoluteDate: date))
      let count = reminder.alarms?.count
      XCTAssertThrowsError(
        try TemporalReminderAlarm(action: "add", at: at, target: nil).apply(to: reminder, now: now))
      XCTAssertThrowsError(
        try TemporalReminderAlarm(action: "clear", at: nil, target: "2030-04-01T01:30:00Z").apply(
          to: reminder, now: now))
      XCTAssertThrowsError(
        try TemporalReminderAlarm(action: "replace", at: "2029-01-01T00:00:00Z", target: at).apply(
          to: reminder, now: now))
      XCTAssertEqual(reminder.alarms?.count, count)
      XCTAssertEqual(reminder.alarms?.first?.absoluteDate, date)
      // Clearing a target whose time has passed is explicitly allowed.
      try TemporalReminderAlarm(action: "clear", at: nil, target: at).apply(
        to: reminder, now: date.addingTimeInterval(1))
      XCTAssertTrue(reminder.alarms?.isEmpty ?? true)
    }

    func testTimedDueComponentsUseTheExplicitOffsetOnTheTargetedPath() throws {
      XCTAssertThrowsError(try TemporalReminderAlarm.dateComponents("2030-03-31T03:30:23+02:00"))
      let components = try TemporalReminderAlarm.dateComponents("2030-03-31T03:30:00+02:00")
      XCTAssertEqual(components.hour, 3)
      XCTAssertEqual(components.timeZone?.secondsFromGMT(), 7200)
      var calendar = Calendar(identifier: .gregorian)
      calendar.timeZone = components.timeZone ?? TimeZone(secondsFromGMT: 0)!
      XCTAssertEqual(calendar.date(from: components), try TemporalReminderAlarm.instant(at))
    }

    func testDuplicateNativeTargetsAreRejectedWithoutPositionSelection() throws {
      let date = try TemporalReminderAlarm.instant(at)
      XCTAssertThrowsError(
        try TemporalReminderAlarm.selectedTarget(
          in: [EKAlarm(absoluteDate: date), EKAlarm(absoluteDate: date)], date: date))
      XCTAssertThrowsError(try TemporalReminderAlarm.selectedTarget(in: [], date: date))
    }

    func testCommandPassesTargetedJSONAndOmissionPreservesSchedule() throws {
      let json = "{\"action\":\"add\",\"at\":\"\(at)\"}"
      let command = try ReminderCommands.Create.parse([
        "--title", "Synthetic", "--temporal-alarm-json", json,
      ])
      XCTAssertEqual(command.scheduleOptions.temporalAlarm, json)
      let reminder = EKReminder(eventStore: EKEventStore())
      reminder.addAlarm(EKAlarm(relativeOffset: -300))
      try ReminderSchedule().apply(to: reminder)
      XCTAssertEqual(reminder.alarms?.first?.relativeOffset, -300)
      XCTAssertThrowsError(
        try TemporalReminderAlarm.decode("{\"action\":\"add\",\"at\":\"\(at)\",\"extra\":1}"))
    }
  }
#endif
