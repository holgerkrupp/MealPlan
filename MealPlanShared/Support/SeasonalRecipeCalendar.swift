import Foundation

enum SeasonalHemisphere: String, Sendable, Equatable {
    case northern
    case southern
}

enum SeasonalSeason: String, CaseIterable, Sendable, Equatable {
    case spring
    case summer
    case autumn
    case winter
}

struct SeasonalDate: Sendable, Equatable {
    let month: Int
    let day: Int

    init(month: Int, day: Int) {
        self.month = month
        self.day = day
    }
}

enum SeasonalSchedule: Sendable, Equatable {
    case fixedDate(month: Int, day: Int)
    case dateRange(startMonth: Int, startDay: Int, endMonth: Int, endDay: Int)
    /// Calendar weekday numbering: Sunday = 1, Saturday = 7.
    case nthWeekday(month: Int, weekday: Int, ordinal: Int)
    /// Day offset from Western Gregorian Easter Sunday.
    case easterRelative(days: Int)
    case seasonWindow(SeasonalSeason)
    case explicitDateTable([Int: SeasonalDate])
}

enum SeasonalApplicability: Sendable, Equatable {
    case global
    /// Region codes determine availability when present. Language codes are
    /// optional affinity metadata for keyword selection and future ordering.
    /// A language-only entry is valid only when a market region is known.
    case regions(
        regionCodes: Set<String>,
        languageCodes: Set<String> = [],
        hemisphere: SeasonalHemisphere? = nil
    )
}

struct SeasonalRecipeMoment: Identifiable, Sendable, Equatable {
    let id: String
    let titleKey: String
    let symbolName: String?
    let applicability: SeasonalApplicability
    let schedule: SeasonalSchedule
    let leadDays: Int
    let trailDays: Int
    let localizedKeywords: [String: [String]]

    var localizedTitle: String {
        String(localized: String.LocalizationValue(titleKey))
    }

    func keywords(for languageCode: String?) -> [String] {
        let language = languageCode?.split(separator: "-", maxSplits: 1).first.map(String.init)?.lowercased()
        return localizedKeywords[language ?? ""] ?? localizedKeywords["en"] ?? []
    }
}

/// Pure, deterministic seasonal content windows. Region tags describe where
/// a topic is commonly useful; they do not infer what a household celebrates.
enum SeasonalRecipeCalendar {
    static let catalog: [SeasonalRecipeMoment] = [
        SeasonalRecipeMoment(
            id: "halloween",
            titleKey: "Seasonal moment: Halloween",
            symbolName: "sparkles",
            applicability: .regions(
                regionCodes: ["US", "CA", "GB", "IE", "DE", "AT", "CH", "AU", "NZ"],
                languageCodes: ["en", "de"]
            ),
            schedule: .fixedDate(month: 10, day: 31),
            leadDays: 21,
            trailDays: 1,
            localizedKeywords: [
                "en": ["halloween", "pumpkin", "spooky", "autumn party"],
                "de": ["halloween", "kürbis", "kuerbis", "gruselig", "herbstparty"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "autumn-harvest",
            titleKey: "Seasonal moment: Autumn harvest",
            symbolName: "leaf",
            applicability: .global,
            schedule: .seasonWindow(.autumn),
            leadDays: 0,
            trailDays: 0,
            localizedKeywords: [
                "en": ["autumn", "fall", "harvest", "squash", "pumpkin", "apples"],
                "de": ["herbst", "ernte", "kürbis", "kuerbis", "äpfel", "aepfel"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "winter-holiday-baking",
            titleKey: "Seasonal moment: Winter holiday baking",
            symbolName: "birthday.cake",
            applicability: .global,
            schedule: .dateRange(startMonth: 12, startDay: 1, endMonth: 1, endDay: 6),
            leadDays: 14,
            trailDays: 0,
            localizedKeywords: [
                "en": ["winter baking", "holiday baking", "cookies", "gingerbread", "cinnamon"],
                "de": ["wintergebäck", "weihnachtsgebäck", "plätzchen", "plaetzchen", "lebkuchen", "zimt"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "winter-comfort-food",
            titleKey: "Seasonal moment: Winter comfort food",
            symbolName: "snowflake",
            applicability: .global,
            schedule: .seasonWindow(.winter),
            leadDays: 0,
            trailDays: 0,
            localizedKeywords: [
                "en": ["winter", "comfort food", "stew", "soup", "roast"],
                "de": ["winter", "eintopf", "suppe", "schmorgericht", "braten"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "new-year",
            titleKey: "Seasonal moment: New Year",
            symbolName: "party.popper",
            applicability: .global,
            schedule: .fixedDate(month: 1, day: 1),
            leadDays: 7,
            trailDays: 2,
            localizedKeywords: [
                "en": ["new year", "celebration", "party", "brunch"],
                "de": ["silvester", "neujahr", "feiern", "party", "brunch"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "spring-easter-cooking",
            titleKey: "Seasonal moment: Spring and Easter cooking",
            symbolName: "carrot",
            applicability: .regions(
                regionCodes: ["US", "CA", "GB", "IE", "DE", "AT", "CH", "FR", "IT", "ES", "NL", "BE", "AU", "NZ"],
                languageCodes: ["en", "de", "fr", "it", "es", "nl"]
            ),
            schedule: .easterRelative(days: 0),
            leadDays: 28,
            trailDays: 1,
            localizedKeywords: [
                "en": ["easter", "spring vegetables", "lamb", "carrots", "hot cross buns"],
                "de": ["ostern", "frühlingsgemüse", "fruehlingsgemuese", "lamm", "möhren", "moehren"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "summer-grilling-picnic",
            titleKey: "Seasonal moment: Summer grilling and picnics",
            symbolName: "sun.max",
            applicability: .global,
            schedule: .seasonWindow(.summer),
            leadDays: 0,
            trailDays: 0,
            localizedKeywords: [
                "en": ["summer", "grilling", "barbecue", "picnic", "salad"],
                "de": ["sommer", "grillen", "grill", "picknick", "salat"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "thanksgiving-us",
            titleKey: "Seasonal moment: Thanksgiving",
            symbolName: "fork.knife",
            applicability: .regions(regionCodes: ["US"], languageCodes: ["en"]),
            schedule: .nthWeekday(month: 11, weekday: 5, ordinal: 4),
            leadDays: 21,
            trailDays: 1,
            localizedKeywords: [
                "en": ["thanksgiving", "turkey", "stuffing", "cranberry", "pumpkin pie"],
                "de": ["thanksgiving", "truthahn", "füllung", "fuellung", "cranberry"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "thanksgiving-canada",
            titleKey: "Seasonal moment: Thanksgiving",
            symbolName: "fork.knife",
            applicability: .regions(regionCodes: ["CA"], languageCodes: ["en", "fr"]),
            schedule: .nthWeekday(month: 10, weekday: 2, ordinal: 2),
            leadDays: 21,
            trailDays: 1,
            localizedKeywords: [
                "en": ["thanksgiving", "turkey", "stuffing", "cranberry", "pumpkin pie"],
                "fr": ["action de grâce", "dinde", "farce", "canneberge", "tarte à la citrouille"],
            ]
        ),
        SeasonalRecipeMoment(
            id: "lunar-new-year-cooking",
            titleKey: "Seasonal moment: Lunar New Year cooking",
            symbolName: "sparkles",
            applicability: .regions(regionCodes: ["CN", "SG", "VN", "KR", "MY"], languageCodes: ["en", "de"]),
            schedule: .explicitDateTable([
                2024: SeasonalDate(month: 2, day: 10),
                2025: SeasonalDate(month: 1, day: 29),
                2026: SeasonalDate(month: 2, day: 17),
                2027: SeasonalDate(month: 2, day: 6),
                2028: SeasonalDate(month: 1, day: 26),
                2029: SeasonalDate(month: 2, day: 13),
                2030: SeasonalDate(month: 2, day: 3),
            ]),
            leadDays: 14,
            trailDays: 1,
            localizedKeywords: [
                "en": ["lunar new year", "new year feast", "dumplings", "spring festival"],
                "de": ["mondneujahr", "chinesisches neujahr", "teigtaschen", "frühlingsfest"],
            ]
        ),
    ]

    static func activeMoments(
        on date: Date,
        context: RecipeDiscoveryMarketContext,
        calendar: Calendar = .current,
        timeZone: TimeZone? = nil
    ) -> [SeasonalRecipeMoment] {
        let calendar = configured(calendar, timeZone: timeZone)
        let year = calendar.component(.year, from: date)
        let years = (year - 1)...(year + 1)
        let active: [(index: Int, moment: SeasonalRecipeMoment)] = catalog.enumerated().compactMap { entry -> (index: Int, moment: SeasonalRecipeMoment)? in
            let index = entry.offset
            let moment = entry.element
            guard isApplicable(moment.applicability, context: context) else { return nil }
            let hemisphere = hemisphere(for: moment.applicability, context: context)
            let isActive = intervals(
                for: moment.schedule,
                years: years,
                calendar: calendar,
                hemisphere: hemisphere,
                leadDays: moment.leadDays,
                trailDays: moment.trailDays
            ).contains { date >= $0.start && date < $0.end }
            return isActive ? (index: index, moment: moment) : nil
        }
        return active.sorted { lhs, rhs in
            let leftAffinity = languageAffinity(lhs.moment.applicability, context: context)
            let rightAffinity = languageAffinity(rhs.moment.applicability, context: context)
            return leftAffinity == rightAffinity ? lhs.index < rhs.index : leftAffinity < rightAffinity
        }
        .map(\.moment)
    }

    /// The next catalog boundary lets a view refresh at a moment's start or
    /// expiry without polling. Returns nil when the remaining explicit-date
    /// tables contain no future transition.
    static func nextTransition(
        after date: Date,
        context: RecipeDiscoveryMarketContext,
        calendar: Calendar = .current,
        timeZone: TimeZone? = nil
    ) -> Date? {
        let calendar = configured(calendar, timeZone: timeZone)
        let year = calendar.component(.year, from: date)
        let years = (year - 1)...(year + 2)
        return catalog
            .filter { isApplicable($0.applicability, context: context) }
            .flatMap { moment in
                intervals(
                    for: moment.schedule,
                    years: years,
                    calendar: calendar,
                    hemisphere: hemisphere(for: moment.applicability, context: context),
                    leadDays: moment.leadDays,
                    trailDays: moment.trailDays
                ).flatMap { [$0.start, $0.end] }
            }
            .filter { $0 > date }
            .min()
    }

    private static let southernRegionCodes: Set<String> = ["AU", "NZ", "ZA", "AR", "CL", "UY", "PY"]

    private static func configured(_ calendar: Calendar, timeZone: TimeZone?) -> Calendar {
        guard let timeZone else { return calendar }
        var copy = calendar
        copy.timeZone = timeZone
        return copy
    }

    private static func isApplicable(_ applicability: SeasonalApplicability, context: RecipeDiscoveryMarketContext) -> Bool {
        switch applicability {
        case .global:
            return true
        case .regions(let regions, let languages, _):
            // Unknown region is deliberately not guessed from language alone.
            guard let regionCode = context.regionCode else { return false }
            let normalizedRegions = Set(regions.map { $0.uppercased() })
            if !normalizedRegions.isEmpty { return normalizedRegions.contains(regionCode.uppercased()) }
            return languages.contains { $0.lowercased() == context.languageCode?.lowercased() }
        }
    }

    private static func languageAffinity(
        _ applicability: SeasonalApplicability,
        context: RecipeDiscoveryMarketContext
    ) -> Int {
        guard case .regions(_, let languages, _) = applicability,
              !languages.isEmpty,
              let languageCode = context.languageCode?.lowercased() else { return 1 }
        return languages.contains { $0.lowercased() == languageCode } ? 0 : 1
    }

    private static func hemisphere(
        for applicability: SeasonalApplicability,
        context: RecipeDiscoveryMarketContext
    ) -> SeasonalHemisphere {
        if case .regions(_, _, let explicit?) = applicability { return explicit }
        guard let regionCode = context.regionCode?.uppercased() else { return .northern }
        return southernRegionCodes.contains(regionCode) ? .southern : .northern
    }

    private static func intervals(
        for schedule: SeasonalSchedule,
        years: ClosedRange<Int>,
        calendar: Calendar,
        hemisphere: SeasonalHemisphere,
        leadDays: Int,
        trailDays: Int
    ) -> [DateInterval] {
        years.flatMap { year in
            baseIntervals(for: schedule, year: year, calendar: calendar, hemisphere: hemisphere)
        }.compactMap { interval in
            let start = calendar.date(byAdding: .day, value: -max(0, leadDays), to: interval.start)
            let end = calendar.date(byAdding: .day, value: max(0, trailDays), to: interval.end)
            guard let start, let end, end > start else { return nil }
            return DateInterval(start: start, end: end)
        }
    }

    private static func baseIntervals(
        for schedule: SeasonalSchedule,
        year: Int,
        calendar: Calendar,
        hemisphere: SeasonalHemisphere
    ) -> [DateInterval] {
        switch schedule {
        case .fixedDate(let month, let day):
            guard let start = date(year: year, month: month, day: day, calendar: calendar) else { return [] }
            return dayInterval(starting: start, calendar: calendar)
        case .dateRange(let startMonth, let startDay, let endMonth, let endDay):
            let start = date(year: year, month: startMonth, day: startDay, calendar: calendar)
            let crossesYearBoundary = endMonth < startMonth || (endMonth == startMonth && endDay < startDay)
            let endYear = crossesYearBoundary ? year + 1 : year
            let end = date(year: endYear, month: endMonth, day: endDay, calendar: calendar)
            guard let start, let end, let endExclusive = calendar.date(byAdding: .day, value: 1, to: end), endExclusive > start else {
                return []
            }
            return [DateInterval(start: start, end: endExclusive)]
        case .nthWeekday(let month, let weekday, let ordinal):
            guard (1...12).contains(month), (1...7).contains(weekday), (1...5).contains(ordinal),
                  let start = calendar.date(from: DateComponents(year: year, month: month, weekday: weekday, weekdayOrdinal: ordinal)) else {
                return []
            }
            return dayInterval(starting: calendar.startOfDay(for: start), calendar: calendar)
        case .easterRelative(let days):
            guard let easter = easterSunday(in: year, calendar: calendar),
                  let start = calendar.date(byAdding: .day, value: days, to: easter) else { return [] }
            return dayInterval(starting: calendar.startOfDay(for: start), calendar: calendar)
        case .seasonWindow(let season):
            let components = seasonMonths(season, hemisphere: hemisphere)
            let start = date(year: year, month: components.start, day: 1, calendar: calendar)
            let endYear = components.end <= components.start ? year + 1 : year
            let end = date(year: endYear, month: components.end, day: 1, calendar: calendar)
            guard let start, let end, end > start else { return [] }
            return [DateInterval(start: start, end: end)]
        case .explicitDateTable(let table):
            guard let value = table[year], let start = date(year: year, month: value.month, day: value.day, calendar: calendar) else {
                return []
            }
            return dayInterval(starting: start, calendar: calendar)
        }
    }

    private static func seasonMonths(
        _ season: SeasonalSeason,
        hemisphere: SeasonalHemisphere
    ) -> (start: Int, end: Int) {
        switch (season, hemisphere) {
        case (.spring, .northern): (3, 6)
        case (.summer, .northern): (6, 9)
        case (.autumn, .northern): (9, 12)
        case (.winter, .northern): (12, 3)
        case (.spring, .southern): (9, 12)
        case (.summer, .southern): (12, 3)
        case (.autumn, .southern): (3, 6)
        case (.winter, .southern): (6, 9)
        }
    }

    private static func date(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        guard (1...12).contains(month), (1...31).contains(day),
              let value = calendar.date(from: DateComponents(year: year, month: month, day: day)) else { return nil }
        let components = calendar.dateComponents([.year, .month, .day], from: value)
        guard components.year == year, components.month == month, components.day == day else { return nil }
        return calendar.startOfDay(for: value)
    }

    private static func dayInterval(starting date: Date, calendar: Calendar) -> [DateInterval] {
        guard let end = calendar.date(byAdding: .day, value: 1, to: date), end > date else { return [] }
        return [DateInterval(start: date, end: end)]
    }

    private static func easterSunday(in year: Int, calendar: Calendar) -> Date? {
        // Meeus/Jones/Butcher Gregorian computus.
        let a = year % 19
        let b = year / 100
        let c = year % 100
        let d = b / 4
        let e = b % 4
        let f = (b + 8) / 25
        let g = (b - f + 1) / 3
        let h = (19 * a + b - d - g + 15) % 30
        let i = c / 4
        let k = c % 4
        let l = (32 + 2 * e + 2 * i - h - k) % 7
        let m = (a + 11 * h + 22 * l) / 451
        let value = h + l - 7 * m + 114
        let month = value / 31
        let day = value % 31 + 1
        return date(year: year, month: month, day: day, calendar: calendar)
    }
}
