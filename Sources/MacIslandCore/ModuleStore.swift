import Foundation

/// The persistence seam for module on/off state — injected like `Clock`/`AudioOutput` so
/// `ModuleRegistry` stays headless-testable. We persist the **disabled** set (not the
/// enabled one) so new built-ins default **on** without a migration.
public protocol ModuleStore {
    func disabledIDs() -> Set<SourceID>
    func setDisabled(_ ids: Set<SourceID>)
}

/// Production store — one `UserDefaults` key holding the sorted raw ids of disabled
/// modules. Injectable defaults so tests can use a throwaway suite.
public final class UserDefaultsModuleStore: ModuleStore {
    private let defaults: UserDefaults
    private let key = "modules.disabled"

    public init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    public func disabledIDs() -> Set<SourceID> {
        Set((defaults.stringArray(forKey: key) ?? []).map(SourceID.init(raw:)))
    }

    public func setDisabled(_ ids: Set<SourceID>) {
        defaults.set(ids.map(\.raw).sorted(), forKey: key)   // sorted → stable on disk
    }
}
