import Foundation
import GRDB
import PoscarCore

/// Applies mail actions locally at once and sends them to the server a few seconds later,
/// so `z` can undo them without having to reverse anything on the server.
@MainActor
final class ActionQueue {
    private struct Pending {
        var plans: [String: ActionPlan]
        var timer: Task<Void, Never>?
    }

    static let commitDelay: UInt64 = 5_000_000_000

    private unowned let model: AppModel
    private var pending: [UUID: Pending] = [:]

    init(model: AppModel) {
        self.model = model
    }

    func enqueue(_ plans: [String: ActionPlan]) async throws -> UUID {
        try await write(plans.values.flatMap(\.updated))
        let id = UUID()
        pending[id] = Pending(plans: plans, timer: Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.commitDelay)
            guard !Task.isCancelled else { return }
            await self?.commit(id)
        })
        await updateProtectedRows()
        return id
    }

    /// Restores the previous local state. Returns false when the action already reached the server.
    func undo(_ id: UUID) async -> Bool {
        guard let entry = pending.removeValue(forKey: id) else { return false }
        entry.timer?.cancel()
        do {
            try await write(entry.plans.values.flatMap(\.original))
        } catch {
            model.showError("Undo failed: \(error.localizedDescription)")
        }
        await updateProtectedRows()
        return true
    }

    func commitAll() async {
        for id in Array(pending.keys) {
            pending[id]?.timer?.cancel()
            await commit(id)
        }
    }

    private func commit(_ id: UUID) async {
        guard let entry = pending.removeValue(forKey: id) else { return }
        for (accountID, plan) in entry.plans {
            guard let engine = model.engine(for: accountID) else { continue }
            do {
                try await engine.perform(plan.operations)
            } catch {
                try? await write(plan.original)
                model.showError("\(model.account(accountID)?.name ?? "Server"): \(error.localizedDescription)")
            }
        }
        await updateProtectedRows()
    }

    private func write(_ records: [MessageRecord]) async throws {
        guard let database = model.database, !records.isEmpty else { return }
        try await database.writer.write { db in
            for record in records {
                // Sync may have removed the row in the meantime; nothing to restore then.
                do { try record.update(db) } catch RecordError.recordNotFound {}
            }
        }
    }

    private func updateProtectedRows() async {
        var byAccount: [String: Set<Int64>] = [:]
        for entry in pending.values {
            for (accountID, plan) in entry.plans {
                byAccount[accountID, default: []].formUnion(plan.updated.compactMap(\.id))
            }
        }
        for (accountID, engine) in model.engines {
            await engine.setProtectedRows(byAccount[accountID] ?? [])
        }
    }
}
