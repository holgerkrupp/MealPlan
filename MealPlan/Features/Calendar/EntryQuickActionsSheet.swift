import SwiftUI
import SwiftData
import PhotosUI

/// Everything you can do to one planned meal: reschedule, rescale, react,
/// mark cooked or skipped, or remove it (with undo).
@MainActor
struct EntryQuickActionsSheet: View {
    @Bindable var entry: MealPlanEntry

    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    @State private var date: Date = .now
    @State private var mealKey: String = ""
    @State private var servings: Int = 2
    @State private var showCookPhoto = false
    @State private var photoItem: PhotosPickerItem?
    @State private var useAsDishImage = true

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if let dish = entry.dish {
                        NavigationLink {
                            DishDetailView(dish: dish)
                        } label: {
                            HStack(spacing: 12) {
                                DishThumbnail(dish: dish, size: 52)
                                VStack(alignment: .leading) {
                                    Text(dish.name).font(.headline)
                                    if let by = entry.plannedByName {
                                        Text(String(localized: "Planned by \(by)"))
                                            .font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                    } else if entry.isEatingOut {
                        eatingOutHeader
                    }
                }

                Section {
                    MealPlannerStrip(
                        reschedulingEntry: entry,
                        selectedDate: $date,
                        selectedMealKey: $mealKey
                    )
                    .listRowInsets(EdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4))
                } header: {
                    Text(String(localized: "When"))
                } footer: {
                    Text(String(localized: "Tap a slot to move this meal."))
                }

                Section(String(localized: "For this meal")) {
                    Stepper(value: $servings, in: 1...50) {
                        Text(String(localized: "\(servings) servings"))
                    }
                    reactionPicker
                    TextField(
                        String(localized: "Note"),
                        text: Binding(get: { entry.note ?? "" }, set: { entry.note = $0.isEmpty ? nil : $0 }),
                        axis: .vertical
                    )
                }

                Section {
                    if entry.cookedLog == nil {
                        Button {
                            markCooked()
                        } label: {
                            Label(String(localized: "Mark as cooked"), systemImage: "checkmark.circle")
                        }
                    } else {
                        Label(String(localized: "Cooked"), systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    }

                    Toggle(isOn: Binding(
                        get: { entry.skipped },
                        set: { entry.skipped = $0; save() }
                    )) {
                        Label(String(localized: "We skipped this"), systemImage: "xmark.circle")
                    }

                    Toggle(isOn: Binding(
                        get: { entry.prepReminder },
                        set: { entry.prepReminder = $0; save(); rescheduleNotifications() }
                    )) {
                        Label(String(localized: "Remind me the evening before"), systemImage: "bell")
                    }
                }

                if showCookPhoto {
                    Section(String(localized: "Add a photo of tonight’s result")) {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(String(localized: "Choose photo"), systemImage: "camera")
                        }
                        Toggle(String(localized: "Use as the dish’s photo"), isOn: $useAsDishImage)
                    }
                }

                Section {
                    Button(role: .destructive, action: remove) {
                        Label(String(localized: "Remove from plan"), systemImage: "trash")
                    }
                }
            }
            .navigationTitle(entry.displayTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(String(localized: "Done")) { applyReschedule(); dismiss() }
                }
            }
            .onAppear {
                date = entry.date
                mealKey = entry.mealKey
                servings = entry.effectiveServings
            }
            .onChange(of: servings) { _, newValue in
                entry.servingsOverride = (newValue == entry.dish?.servings) ? nil : newValue
                touch()
            }
            .onChange(of: photoItem) { _, item in
                Task { await attachCookPhoto(item) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    /// Header for a meal the family eats out: the place, its address, and a
    /// way to open it in Maps.
    @ViewBuilder
    private var eatingOutHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "storefront")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: 52)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.placeName ?? String(localized: "Eating out")).font(.headline)
                if let address = entry.placeAddress {
                    Text(address).font(.caption).foregroundStyle(.secondary)
                }
                if let by = entry.plannedByName {
                    Text(String(localized: "Planned by \(by)"))
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }

        TextField(
            String(localized: "Where are we going?"),
            text: Binding(
                get: { entry.placeName ?? "" },
                set: { entry.placeName = $0.isEmpty ? nil : $0; save() }
            )
        )

        if let url = mapsURL {
            Link(destination: url) {
                Label(String(localized: "Open in Maps"), systemImage: "map")
            }
        }
    }

    /// A Maps link for the picked place — by coordinate when we have one, by
    /// name otherwise.
    private var mapsURL: URL? {
        var components = URLComponents(string: "https://maps.apple.com/")
        if let coordinate = entry.placeCoordinate {
            components?.queryItems = [
                URLQueryItem(name: "ll", value: "\(coordinate.latitude),\(coordinate.longitude)"),
                URLQueryItem(name: "q", value: entry.placeName ?? String(localized: "Restaurant")),
            ]
        } else if let name = entry.placeName, !name.isEmpty {
            components?.queryItems = [URLQueryItem(name: "q", value: name)]
        } else {
            return nil
        }
        return components?.url
    }

    private var reactionPicker: some View {
        Picker(String(localized: "Reaction"), selection: Binding(
            get: { entry.reaction },
            set: { entry.reaction = $0; save() }
        )) {
            Text(String(localized: "None")).tag(Reaction?.none)
            ForEach(Reaction.allCases) { r in
                Image(systemName: r.symbolName).tag(Reaction?.some(r))
            }
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Actions

    private func applyReschedule() {
        guard !date.isSameDay(as: entry.date) || mealKey != entry.mealKey else { return }
        MealPlanner.move(entry, to: date, mealKey: mealKey, memberName: appState.currentMemberName, context: context)
    }

    private func markCooked() {
        let log = CookedLog(date: entry.date, dish: entry.dish, servings: entry.effectiveServings)
        log.entry = entry
        log.household = appState.currentHousehold
        context.insert(log)
        if let dish = entry.dish {
            if (dish.lastUsedDate ?? .distantPast) < entry.date { dish.lastUsedDate = entry.date }
            dish.usageCount += 1
        }
        save()
        SharedStore.reloadWidgets()
        withAnimation { showCookPhoto = true }
    }

    private func attachCookPhoto(_ item: PhotosPickerItem?) async {
        guard let item, let raw = try? await item.loadTransferable(type: Data.self) else { return }
        let data = ImagePreparation.prepared(from: raw)
        entry.cookedLog?.photoData = data
        if useAsDishImage, let dish = entry.dish {
            for image in dish.sortedImages { image.isPrimary = false }
            let image = DishImage(data: data, sortIndex: -1, isPrimary: true)
            image.dish = dish
            context.insert(image)
        }
        save()
        SharedStore.reloadWidgets()
    }

    private func rescheduleNotifications() {
        Task { await MealNotificationScheduler.shared.refreshFromStore(context: context) }
    }

    private func remove() {
        let name = entry.displayTitle
        context.delete(entry)
        save()
        SharedStore.reloadWidgets()
        let undoManager = context.undoManager
        appState.offerUndo(String(localized: "Removed “\(name)”")) {
            undoManager?.undo()
            try? context.save()
        }
        dismiss()
    }

    private func touch() {
        entry.lastEditedByName = appState.currentMemberName
        entry.lastEditedDate = .now
        save()
    }

    private func save() { try? context.save() }
}

#Preview {
    EntryQuickActionsSheet(entry: PreviewData.entry)
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}

#Preview("Eating out") {
    EntryQuickActionsSheet(entry: PreviewData.eatingOutEntry)
        .environment(AppState.preview)
        .modelContainer(PreviewData.container)
}
