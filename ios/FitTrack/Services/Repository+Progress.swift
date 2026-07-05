import FirebaseFirestore
import Foundation

// Progress data access (spec §7.6). Lives in an extension so the core Repository
// stays focused; same AsyncThrowingStream + snapshot-listener pattern as the
// streams in Repository.swift. Every path is scoped under users/{uid}.

extension Repository {
    /// Live day-log rollups (calories + macros + health metrics), oldest→newest.
    /// Feeds the calories-vs-target and macro-adherence charts (spec §7.6).
    func dayLogsStream() -> AsyncThrowingStream<[DayLog], Error> {
        if Demo.isActive { return Demo.stream(DemoData.dayLogs) }
        return AsyncThrowingStream { continuation in
            do {
                let reg = try userDoc().collection("dayLogs")
                    .order(by: "date")
                    .addSnapshotListener { snap, err in
                        if let err { continuation.finish(throwing: err); return }
                        let logs = snap?.documents.compactMap { try? $0.data(as: DayLog.self) } ?? []
                        continuation.yield(logs)
                    }
                continuation.onTermination = { _ in reg.remove() }
            } catch { continuation.finish(throwing: error) }
        }
    }
}
