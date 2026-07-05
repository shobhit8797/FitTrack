import FirebaseFirestore
import Foundation

// Supplement / medication reminders (users/{uid}/reminders). Persisted in
// Firestore so a user's schedule survives reinstall and syncs across devices;
// the actual alerts are local notifications rescheduled from these records
// (see NotificationService). Scoped under users/{uid} like the rest of Repository.

extension Repository {
    func remindersCollection() throws -> CollectionReference {
        try userDoc().collection("reminders")
    }

    func addReminder(_ reminder: SupplementReminder) async throws {
        if Demo.isActive { return }
        let ref = try remindersCollection().document()
        var r = reminder; r.id = ref.documentID
        try ref.setData(from: r)
    }

    func updateReminder(_ reminder: SupplementReminder) async throws {
        if Demo.isActive { return }
        try remindersCollection().document(reminder.id).setData(from: reminder)
    }

    func deleteReminder(_ id: String) async throws {
        if Demo.isActive { return }
        try await remindersCollection().document(id).delete()
    }

    /// Live reminders list, newest first. The app subscribes to this once signed
    /// in and re-syncs local notifications whenever it changes.
    func remindersStream() -> AsyncThrowingStream<[SupplementReminder], Error> {
        if Demo.isActive { return Demo.stream(DemoData.reminders) }
        return AsyncThrowingStream { continuation in
            do {
                let reg = try remindersCollection()
                    .order(by: "createdAt", descending: true)
                    .addSnapshotListener { snap, err in
                        if let err { continuation.finish(throwing: err); return }
                        let reminders = snap?.documents
                            .compactMap { try? $0.data(as: SupplementReminder.self) } ?? []
                        continuation.yield(reminders)
                    }
                continuation.onTermination = { _ in reg.remove() }
            } catch { continuation.finish(throwing: error) }
        }
    }
}
