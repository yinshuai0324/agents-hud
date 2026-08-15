import XCTest
@testable import AgentsHUDCore

final class DailyTimeRangeTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 8 * 3600)!
        return value
    }

    func testSameDayRangeIncludesStartAndExcludesEnd() throws {
        let range = DailyTimeRange(startHour: 9, startMinute: 0, endHour: 18, endMinute: 0)
        XCTAssertNotNil(range.activeOccurrenceStart(at: date(9, 0), calendar: calendar))
        XCTAssertNotNil(range.activeOccurrenceStart(at: date(17, 59), calendar: calendar))
        XCTAssertNil(range.activeOccurrenceStart(at: date(18, 0), calendar: calendar))
        XCTAssertNil(range.activeOccurrenceStart(at: date(8, 59), calendar: calendar))
    }

    func testCrossMidnightRangeUsesPreviousOccurrenceAfterMidnight() throws {
        let range = DailyTimeRange(startHour: 22, startMinute: 0, endHour: 7, endMinute: 0)
        let afterMidnight = try XCTUnwrap(range.activeOccurrenceStart(
            at: date(1, 30), calendar: calendar
        ))
        XCTAssertEqual(calendar.component(.day, from: afterMidnight), 15)
        XCTAssertEqual(calendar.component(.hour, from: afterMidnight), 22)
        XCTAssertNotNil(range.activeOccurrenceStart(at: date(23, 0), calendar: calendar))
        XCTAssertNil(range.activeOccurrenceStart(at: date(12, 0), calendar: calendar))
    }

    func testEqualEndpointsAreInvalid() {
        let range = DailyTimeRange(startHour: 9, startMinute: 0, endHour: 9, endMinute: 0)
        XCTAssertFalse(range.isValid)
        XCTAssertNil(range.activeOccurrenceStart(at: date(9, 0), calendar: calendar))
    }

    private func date(_ hour: Int, _ minute: Int) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: 8, day: 16, hour: hour, minute: minute
        ))!
    }
}
