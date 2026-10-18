import Foundation
import Combine

// MARK: - IntegrationGate
// Thread-safe mirror of AppState.activeIntegrations so the background pollers can skip
// their network call when the pill is not active (their results would be discarded anyway).

final class IntegrationGate: @unchecked Sendable {
    static let shared = IntegrationGate()
    private let lock = NSLock()
    private var active: Set<String> = []
    private var sub: AnyCancellable?

    private init() {}

    /// Call once on the main actor at launch.
    @MainActor
    func bind(to state: AppState) {
        sub = state.$activeIntegrations.sink { [weak self] ids in
            guard let self else { return }
            self.lock.lock(); self.active = ids; self.lock.unlock()
        }
    }

    static func isActive(_ pillID: String) -> Bool {
        shared.lock.lock(); defer { shared.lock.unlock() }
        return shared.active.contains(pillID)
    }
}
