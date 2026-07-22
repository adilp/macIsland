import Foundation

/// The single `UserDefaults` suite the whole app reads and writes. Using a named suite
/// rather than `.standard` because `.standard`'s domain name varies by launch style (a
/// bare binary resolves to the process name, a bundle to its bundle id), making the key
/// space fragile across dev runs and packaging. Note: `UserDefaults(suiteName:)` rejects
/// the app's own bundle identifier, so the suite name must differ from `com.macisland.app`.
///
/// `nonisolated(unsafe)` follows the `EKEventStore` precedent in this repo: `UserDefaults`
/// is not `Sendable` under Swift 6 strict concurrency, but its thread safety is documented
/// by Apple and the reference is read-only after init.
public enum AppDefaults {
    /// The single settings suite shared by every component.
    nonisolated(unsafe) public static let shared = UserDefaults(suiteName: "com.macisland.settings")!

    /// Copy values for `keys` from the first legacy domain that has them into `target`,
    /// skipping any key already present in `target`. Never overwrites an existing value.
    /// When several domains in `legacy` contain the same key, the first one in the array wins.
    public static func migrate(keys: [String], from legacy: [UserDefaults], to target: UserDefaults) {
        for key in keys {
            guard target.object(forKey: key) == nil else { continue }
            for source in legacy {
                if let value = source.object(forKey: key) {
                    target.set(value, forKey: key)
                    break
                }
            }
        }
    }

    /// One-shot call at app startup — promotes any values written to `.standard` or the
    /// old named suites into `shared`. Safe to call repeatedly: `migrate` never overwrites.
    public static func migrateLegacyDomains() {
        let legacySuites: [UserDefaults] = [.standard] +
            ["MacIslandApp", "com.macisland.app"].compactMap { UserDefaults(suiteName: $0) }
        migrate(keys: ["github.config", "modules.disabled"],
                from: legacySuites,
                to: shared)
    }
}
