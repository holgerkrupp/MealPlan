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
    @Query(sort: [SortDescriptor(\MealType.sortOrder), SortDescriptor(\MealType.name)])
    private var mealTypes: [MealType]

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
                    }
                }

                Section(String(localized: "When")) {
                    DatePicker(String(localized: "Day"), selection: $date, displayedComponents: .date)
                    Picker(String(localized: "Meal"), selection: $mealKey) {
                        if !mealTypes.contains(where: { $0.key == mealKey }) {
                            Text(MealType.legacyName(for: mealKey)).tag(mealKey)
                        }
                        ForEach(mealTypes) { meal in
                            Label(meal.name, systemImage: meal.symbolName).tag(meal.key)
                        }
                    }
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
            .navigationTitle(entry.dish?.name ?? String(localized: "Planned meal"))
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
        let name = entry.dish?.name ?? String(localized: "Meal")
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
