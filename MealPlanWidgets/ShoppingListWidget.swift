import AppIntents
import WidgetKit
import SwiftUI

struct ShoppingListProvider: TimelineProvider {

    func placeholder(in context: Context) -> ShoppingWidgetEntry { .sample }

    func getSnapshot(in context: Context, completion: @escaping (ShoppingWidgetEntry) -> Void) {
        completion(context.isPreview ? .sample : ShoppingWidgetLoader.entry())
    }

    /// A shopping list changes when somebody changes it, not with the clock —
    /// so there is nothing to schedule. `SharedStore.reloadWidgets()` is what
    /// refreshes this, from the app, from the watch link, and from the tick
    /// intent below. The daily policy is only a backstop.
    func getTimeline(in context: Context, completion: @escaping (Timeline<ShoppingWidgetEntry>) -> Void) {
        let entry = ShoppingWidgetLoader.entry()
        completion(Timeline(entries: [entry], policy: .after(Date.now.adding(days: 1).startOfDay)))
    }
}

struct ShoppingListWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ShoppingListWidget", provider: ShoppingListProvider()) { entry in
            ShoppingListWidgetView(entry: entry)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName(String(localized: "Shopping list"))
        .description(String(localized: "What’s still to buy. Tap a line to tick it off."))
        .supportedFamilies([
            .systemSmall, .systemMedium, .systemLarge,
            .accessoryRectangular, .accessoryInline, .accessoryCircular,
        ])
    }
}

struct ShoppingListWidgetView: View {
    var entry: ShoppingWidgetEntry
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryInline:
            inline
        case .accessoryCircular:
            circular
        case .accessoryRectangular:
            rectangular
        case .systemLarge:
            grouped
        default:
            flat
        }
    }

    // MARK: - Home screen

    /// Small and medium: just what is left, in aisle order. There is no room
    /// here for lines already in the basket, and "what do I still need?" is
    /// the only question a widget this size can answer.
    private var flat: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Nothing in the subtitle that the note underneath already says.
            header(subtitle: entry.isEmpty || entry.isDone ? nil : countLabel)
            if entry.isEmpty {
                NothingToBuyNote()
            } else if entry.isDone {
                AllTickedOffNote()
            } else {
                ForEach(entry.remaining.prefix(family == .systemSmall ? 5 : 6)) { item in
                    ShoppingWidgetRow(
                        item: item,
                        titleFont: family == .systemSmall ? .system(size: 12) : .caption
                    )
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(entry.link)
    }

    /// Large: the list itself, aisle by aisle, with the ticked lines still
    /// there — struck through and dimmed. This is the one family with room to
    /// undo a mis-tap, so it keeps what the others drop.
    private var grouped: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Here a finished list still shows its lines, struck through, so
            // the subtitle is the only thing that says it is done.
            header(subtitle: entry.isEmpty ? nil : countLabel)
            if entry.isEmpty {
                NothingToBuyNote()
            } else {
                ForEach(entry.aisles.trimmed(toRows: 13)) { aisle in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(aisle.name)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ForEach(aisle.items) { item in
                            ShoppingWidgetRow(item: item, titleFont: .subheadline)
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .widgetURL(entry.link)
    }

    /// "Shopping list · 5 of 7 left".
    private func header(subtitle: String?) -> some View {
        WidgetHeader(
            title: String(localized: "Shopping list"),
            subtitle: subtitle,
            symbol: "cart"
        )
    }

    private var countLabel: String {
        let left = entry.remaining.count
        return left == 0
            ? String(localized: "all ticked off")
            : String(localized: "\(left) of \(entry.allItems.count) left")
    }

    // MARK: - Lock screen

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(String(localized: "Shopping list")).font(.headline)
            if entry.isEmpty {
                Text(String(localized: "Nothing to buy")).font(.caption)
            } else if entry.isDone {
                Text(String(localized: "All ticked off")).font(.caption)
            } else {
                ForEach(entry.remaining.prefix(2)) { item in
                    Text(item.amount.map { "\(item.name) · \($0)" } ?? item.name)
                        .font(.caption)
                        .lineLimit(1)
                }
            }
        }
    }

    /// The count as a ring: how much of the list is already in the basket.
    private var circular: some View {
        Gauge(value: Double(entry.allItems.count - entry.remaining.count),
              in: 0...Double(max(entry.allItems.count, 1))) {
            Image(systemName: "cart")
        } currentValueLabel: {
            Text("\(entry.remaining.count)")
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityLabel(String(localized: "Shopping list"))
        .accessibilityValue(entry.isEmpty
                            ? String(localized: "Nothing to buy")
                            : String(localized: "\(entry.remaining.count) left to buy"))
    }

    @ViewBuilder
    private var inline: some View {
        if entry.isEmpty {
            Text(String(localized: "Nothing to buy"))
        } else if let next = entry.remaining.first {
            Text("\(entry.remaining.count) · \(next.name)")
        } else {
            Text(String(localized: "All ticked off"))
        }
    }
}

// MARK: - Rows

/// One line, and the button that ticks it.
///
/// The whole row is the target rather than the little circle beside it: a
/// widget line is around eleven points tall and nobody can hit a checkbox that
/// size on a home screen.
struct ShoppingWidgetRow: View {
    var item: WidgetShoppingItem
    var titleFont: Font = .caption

    var body: some View {
        Button(intent: ToggleShoppingItemIntent(id: item.id)) {
            HStack(spacing: 7) {
                Image(systemName: item.isChecked ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 13))
                    .foregroundStyle(item.isChecked ? AnyShapeStyle(.green) : AnyShapeStyle(.tertiary))
                Text(item.name)
                    .font(titleFont)
                    .strikethrough(item.isChecked)
                    .foregroundStyle(item.isChecked ? .secondary : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                if let amount = item.amount {
                    Text(amount)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(item.amount.map { "\(item.name), \($0)" } ?? item.name)
        .accessibilityValue(item.isChecked
                            ? String(localized: "Ticked off")
                            : String(localized: "Still to buy"))
        .accessibilityAddTraits(item.isChecked ? .isSelected : [])
    }
}

// MARK: - Empty states

/// Shown when there is no list at all — the state before the first rebuild.
struct NothingToBuyNote: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "cart")
                .font(.title3)
                .foregroundStyle(.tertiary)
            Text(String(localized: "Nothing to buy yet"))
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shown when there *is* a list and every line is ticked. Worth its own note:
/// an empty widget would otherwise read as "the list is gone".
struct AllTickedOffNote: View {
    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(String(localized: "All ticked off"))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Previews

#Preview("Small", as: .systemSmall) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sample
}

#Preview("Medium", as: .systemMedium) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sample
}

#Preview("Large", as: .systemLarge) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sample
}

#Preview("Lock screen", as: .accessoryRectangular) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sample
}

#Preview("Circular", as: .accessoryCircular) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sample
}

#Preview("Inline", as: .accessoryInline) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sample
}

#Preview("Nothing to buy", as: .systemMedium) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sampleEmpty
}

#Preview("All ticked off", as: .systemMedium) {
    ShoppingListWidget()
} timeline: {
    ShoppingWidgetEntry.sampleDone
}
