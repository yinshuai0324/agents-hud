import Foundation

/// A repeating local-time interval. End is exclusive; an end earlier than the
/// start crosses midnight (22:00–07:00). Equal endpoints are invalid rather
/// than ambiguously meaning either zero or twenty-four hours.
public struct DailyTimeRange: Sendable, Equatable {
    public var startHour: Int
    public var startMinute: Int
    public var endHour: Int
    public var endMinute: Int

    public init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.startHour = startHour
        self.startMinute = startMinute
        self.endHour = endHour
        self.endMinute = endMinute
    }

    public var isValid: Bool {
        startHour * 60 + startMinute != endHour * 60 + endMinute
    }

    /// Start date of the occurrence containing `date`, or nil outside it.
    public func activeOccurrenceStart(at date: Date, calendar: Calendar = .current) -> Date? {
        guard isValid else { return nil }
        let day = calendar.startOfDay(for: date)
        guard let start = calendar.date(
            bySettingHour: min(max(startHour, 0), 23),
            minute: min(max(startMinute, 0), 59),
            second: 0,
            of: day
        ), let end = calendar.date(
            bySettingHour: min(max(endHour, 0), 23),
            minute: min(max(endMinute, 0), 59),
            second: 0,
            of: day
        ) else { return nil }

        if start < end {
            return date >= start && date < end ? start : nil
        }
        if date >= start { return start }
        if date < end { return calendar.date(byAdding: .day, value: -1, to: start) }
        return nil
    }
}
