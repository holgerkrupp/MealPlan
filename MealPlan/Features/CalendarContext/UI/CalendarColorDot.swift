import SwiftUI

extension Color {
    /// The calendar's own colour, in the same sRGB values Calendar draws it in.
    init(_ calendarColor: MealCalendarColor) {
        self.init(
            .sRGB,
            red: calendarColor.red,
            green: calendarColor.green,
            blue: calendarColor.blue,
            opacity: calendarColor.alpha
        )
    }
}

/// The small coloured dot Calendar uses to identify a calendar.
///
/// Colour is never the only carrier of meaning here — the calendar's name is
/// always next to it — so the dot is hidden from VoiceOver.
struct CalendarColorDot: View {
    let color: MealCalendarColor?
    var size: CGFloat = 10

    var body: some View {
        Circle()
            .fill(color.map(Color.init) ?? Color.secondary)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

#Preview {
    VStack(alignment: .leading, spacing: 10) {
        ForEach(PreviewCalendar.calendars) { calendar in
            HStack(spacing: 8) {
                CalendarColorDot(color: calendar.color)
                Text(calendar.title)
            }
        }
        HStack(spacing: 8) {
            CalendarColorDot(color: nil, size: 16)
            Text(verbatim: "No colour")
        }
    }
    .padding()
}
