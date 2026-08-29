import Foundation
import EventKit

enum RemindersExportError: LocalizedError {
    case accessDenied
    case noList

    var errorDescription: String? {
        switch self {
        case .accessDenied: String(localized: "MealPlan doesn’t have permission to add to Reminders.")
        case .noList: String(localized: "Couldn’t find a list to add the items to.")
        }
    }
}

/// Sends unchecked shopping-list items to Apple Reminders, into a dedicated
/// "MealPlan" list.
struct RemindersExporter {
    static let listTitle = "MealPlan"

    @discardableResult
    static func export(_ items: [ShoppingListItem]) async throws -> Int {
        let store = EKEventStore()
        let granted = try await store.requestFullAccessToReminders()
        guard granted else { throw RemindersExportError.accessDenied }

        let list = try reminderList(in: store)
        var count = 0
        for item in items where !item.isChecked {
            let reminder = EKReminder(eventStore: store)
            reminder.calendar = list
            reminder.title = title(for: item)
            try store.save(reminder, commit: false)
            count += 1
        }
        try store.commit()
        return count
    }

    private static func title(for item: ShoppingListItem) -> String {
        if let amount = item.displayText, !amount.isEmpty {
            return "\(item.name) — \(amount)"
        }
        return item.name
    }

    private static func reminderList(in store: EKEventStore) throws -> EKCalendar {
        if let existing = store.calendars(for: .reminder).first(where: { $0.title == listTitle }) {
            return existing
        }
        guard let source = store.defaultCalendarForNewReminders()?.source
            ?? store.sources.first(where: { $0.sourceType == .calDAV })
            ?? store.sources.first else {
            throw RemindersExportError.noList
        }
        let calendar = EKCalendar(for: .reminder, eventStore: store)
        calendar.title = listTitle
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        return calendar
    }
}
