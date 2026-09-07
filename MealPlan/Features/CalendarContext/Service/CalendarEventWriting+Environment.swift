import SwiftUI

/// Lets `PublishCalendarView` (and anything else that needs to write plan
/// events into a calendar) reach the shared writer without importing
/// EventKit itself, and lets tests/previews swap in a mock.
///
/// A plain `EnvironmentKey` rather than the `@Observable`-based
/// `.environment(_:)` form: `CalendarEventWriting` is a protocol existential
/// with no observable state of its own, not a class SwiftUI can track.
private struct CalendarEventWritingKey: EnvironmentKey {
    static let defaultValue: any CalendarEventWriting = EventKitCalendarWriter()
}

extension EnvironmentValues {
    var calendarEventWriter: any CalendarEventWriting {
        get { self[CalendarEventWritingKey.self] }
        set { self[CalendarEventWritingKey.self] = newValue }
    }
}
