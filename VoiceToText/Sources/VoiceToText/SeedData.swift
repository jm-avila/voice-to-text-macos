import Foundation

/// Sample history for snapshots: APP_SEED=1 with APP_STORE set, into an empty store only.
enum SeedData {
    static let samples = [
        "Can you move our sync to Thursday at 4? Wednesday is packed.",
        "Note to self: the invoice for October goes out on Monday, and copy Laura on it.",
        "Hola, te confirmo la reserva para el viernes a las nueve.",
        "Ship the release notes after the build passes, not before.",
    ]

    static func insertIfRequested(into services: Services) {
        guard ProcessInfo.processInfo.environment["APP_SEED"] == "1", Store.isOverridden,
              services.dictation.history.isEmpty else { return }
        for (index, text) in samples.enumerated() {
            try? services.store.appendHistory(text, at: Date.now - Double(samples.count - index) * 3_600)
        }
        services.dictation.reloadHistory()
    }
}
