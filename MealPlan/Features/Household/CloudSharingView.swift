import SwiftUI
import CloudKit

#if canImport(UIKit)
import UIKit

/// Presents the system "share with family" sheet (`UICloudSharingController`).
///
/// The share is anchored to a dedicated CloudKit record that carries the local
/// household's `uuid`, so an accepting device can line the two up. Mirroring
/// the full SwiftData record graph onto this share still needs on-device
/// testing — see the note in `HouseholdView`.
struct CloudSharingView: UIViewControllerRepresentable {
    let householdName: String
    let householdUUID: UUID
    var onError: (Error) -> Void = { _ in }
    var onShareSaved: ([CKShare.Participant]) -> Void = { _ in }

    func makeCoordinator() -> Coordinator {
        Coordinator(onError: onError, onShareSaved: onShareSaved)
    }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController { _, completion in
            Task {
                do {
                    let (share, container) = try await Self.makeShare(name: householdName, uuid: householdUUID)
                    completion(share, container, nil)
                } catch {
                    context.coordinator.onError(error)
                    completion(nil, nil, error)
                }
            }
        }
        controller.delegate = context.coordinator
        controller.availablePermissions = [.allowPrivate, .allowReadOnly, .allowReadWrite]
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    static func makeShare(name: String, uuid: UUID) async throws -> (CKShare, CKContainer) {
        let container = CKContainer(identifier: SharedStore.cloudKitContainerID)
        let db = container.privateCloudDatabase

        let rootID = CKRecord.ID(recordName: "household-\(uuid.uuidString)")
        let root: CKRecord
        if let existing = try? await db.record(for: rootID) {
            root = existing
        } else {
            root = CKRecord(recordType: "HouseholdRoot", recordID: rootID)
        }
        root["name"] = name as CKRecordValue
        root["householdUUID"] = uuid.uuidString as CKRecordValue

        let share = CKShare(rootRecord: root)
        share[CKShare.SystemFieldKey.title] = name as CKRecordValue

        _ = try await db.modifyRecords(saving: [root, share], deleting: [])
        return (share, container)
    }

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let onError: (Error) -> Void
        let onShareSaved: ([CKShare.Participant]) -> Void

        init(onError: @escaping (Error) -> Void, onShareSaved: @escaping ([CKShare.Participant]) -> Void) {
            self.onError = onError
            self.onShareSaved = onShareSaved
        }

        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: Error) {
            onError(error)
        }

        func itemTitle(for csc: UICloudSharingController) -> String? { csc.share?[CKShare.SystemFieldKey.title] as? String }

        func cloudSharingControllerDidSaveShare(_ csc: UICloudSharingController) {
            onShareSaved(csc.share?.participants ?? [])
        }
    }
}
#endif
