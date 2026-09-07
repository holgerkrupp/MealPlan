import Foundation
import UniformTypeIdentifiers

/// The plain iCalendar file the publish feature writes. Unlike
/// `BackupFileType` this is a completely standard format — every OS resolves
/// `.ics` to some flavor of "calendar" UTI on its own — so there is nothing
/// custom to declare, only a fallback chain for the rare host that doesn't
/// know the extension.
enum PublishedCalendarFileType {
    static let fileExtension = "ics"

    static var contentType: UTType {
        UTType(filenameExtension: fileExtension)
            ?? UTType(mimeType: "text/calendar")
            ?? .plainText
    }
}
