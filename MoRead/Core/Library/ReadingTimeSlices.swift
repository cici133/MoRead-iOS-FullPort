import Foundation

struct ReadingTimeSlice: Equatable, Sendable {
    let epochDay: Int64
    let hour: Int
    let durationMs: Int64
    let lastReadAt: Int64
}

enum ReadingTimeSlicer {
    /// Splits using real local hour boundaries, preserving totals across midnight and DST transitions.
    static func slices(durationMs: Int64, recordedAt: Int64, calendar baseCalendar: Calendar = .current) -> [ReadingTimeSlice] {
        guard durationMs > 0, recordedAt > 0 else { return [] }
        var calendar = baseCalendar
        let endDate = Date(timeIntervalSince1970: Double(recordedAt) / 1000)
        var cursorMs = max(0, recordedAt - durationMs)
        var result: [ReadingTimeSlice] = []
        while cursorMs < recordedAt {
            let cursor = Date(timeIntervalSince1970: Double(cursorMs) / 1000)
            let components = calendar.dateComponents([.year, .month, .day, .hour], from: cursor)
            guard let hourStart = calendar.date(from: components), let nextHour = calendar.date(byAdding: .hour, value: 1, to: hourStart) else { break }
            let boundary = Int64((nextHour.timeIntervalSince1970 * 1000).rounded())
            let sliceEnd = min(recordedAt, boundary)
            let dayStart = calendar.startOfDay(for: cursor)
            let reference = Date(timeIntervalSince1970: 0)
            let referenceDay = calendar.startOfDay(for: reference)
            let epochDay = Int64(calendar.dateComponents([.day], from: referenceDay, to: dayStart).day ?? 0)
            let hour = calendar.component(.hour, from: cursor)
            result.append(.init(epochDay: epochDay, hour: hour, durationMs: sliceEnd - cursorMs, lastReadAt: sliceEnd))
            if sliceEnd <= cursorMs { break }
            cursorMs = sliceEnd
        }
        _ = endDate // keeps explicit relation to recordedAt in debug traces
        return result
    }
}
