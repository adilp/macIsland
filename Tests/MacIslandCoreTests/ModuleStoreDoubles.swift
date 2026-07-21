@testable import MacIslandCore

/// In-memory `ModuleStore` for headless registry tests — the persistence analogue of
/// `TestClock`.
final class InMemoryModuleStore: ModuleStore {
    private var ids: Set<SourceID>
    init(_ ids: Set<SourceID> = []) { self.ids = ids }
    func disabledIDs() -> Set<SourceID> { ids }
    func setDisabled(_ ids: Set<SourceID>) { self.ids = ids }
}
