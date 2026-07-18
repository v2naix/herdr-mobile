import Foundation

@MainActor
public final class OriginDefaultsStore: OriginPersisting {
    private let defaults: UserDefaults
    private let key = "configuredHTTPSOrigin"

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public func loadOrigin() -> String? {
        defaults.string(forKey: key)
    }

    public func saveOrigin(_ origin: String) {
        defaults.set(origin, forKey: key)
    }

    public func clearOrigin() {
        defaults.removeObject(forKey: key)
    }
}
