import SwiftUI
import SwiftData

/// When each meal happens, so calendar context is tied to the household's own
/// rhythm rather than a hardcoded dinner time.
@MainActor
struct MealTimingSettingsView: View {
    @Environment(CalendarContextStore.self) private var store: CalendarContextStore?
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var meals: [MealType]

    var body: some View {
        Form {
            if let store {
                ForEach(meals) { meal in
                    Section {
                        DatePicker(
                            String(localized: "From"),
                            selection: timeBinding(store, key: meal.key, isStart: true),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            String(localized: "Until"),
                            selection: timeBinding(store, key: meal.key, isStart: false),
                            displayedComponents: .hourAndMinute
                        )
                        Button(String(localized: "Use the standard times")) {
                            store.settings.resetWindow(forMealKey: meal.key)
                        }
                        .disabled(store.settings.mealWindows[meal.key] == nil)
                    } header: {
                        Label(meal.name, systemImage: meal.symbolName)
                    } footer: {
                        let window = store.settings.window(forMealKey: meal.key)
                        Text("Events between \(window.startText) and \(window.endText) count towards this meal.")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle(String(localized: "Meal times"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private func timeBinding(_ store: CalendarContextStore, key: String, isStart: Bool) -> Binding<Date> {
        Binding(
            get: {
                let window = store.settings.window(forMealKey: key)
                return Self.date(minutes: isStart ? window.startMinutes : window.endMinutes)
            },
            set: { newValue in
                let minutes = Self.minutes(from: newValue)
                let window = store.settings.window(forMealKey: key)
                let updated = isStart
                    ? MealTimeWindow(startMinutes: minutes, endMinutes: window.endMinutes)
                    : MealTimeWindow(startMinutes: window.startMinutes, endMinutes: minutes)
                store.settings.setWindow(updated, forMealKey: key)
            }
        )
    }

    private static func date(minutes: Int) -> Date {
        let midnight = Date.now.startOfDay
        return Calendar.current.date(byAdding: .minute, value: minutes, to: midnight) ?? midnight
    }

    private static func minutes(from date: Date) -> Int {
        let components = Calendar.current.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }
}

#Preview {
    PreviewCalendarHost {
        NavigationStack { MealTimingSettingsView() }
    }
    .modelContainer(PreviewData.container)
}
