import Foundation

/// The app uses UserDefaults; validation and tests use a separate in-memory store.
/// Consumers cannot create preference domains or depend on CFPreferences cleanup.
protocol PreferencesStore: AnyObject {
    func object(forKey key: String) -> Any?
    func bool(forKey key: String) -> Bool
    func integer(forKey key: String) -> Int
    func double(forKey key: String) -> Double
    func string(forKey key: String) -> String?
    func stringArray(forKey key: String) -> [String]?
    func dictionary(forKey key: String) -> [String: Any]?
    func data(forKey key: String) -> Data?
    func set(_ value: Any?, forKey key: String)
    func removeObject(forKey key: String)
    func register(defaults registration: [String: Any])
}

extension UserDefaults: PreferencesStore {}

final class InMemoryPreferences: PreferencesStore, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Any]
    private var registered: [String: Any] = [:]
    private var fallbacks: [InMemoryPreferences] = []

    init(values: [String: Any] = [:]) { self.values = values }
    var snapshot: [String: Any] { lock.lock(); defer { lock.unlock() }; return values }

    func object(forKey key: String) -> Any? {
        lock.lock()
        let own = values[key], defaults = registered[key], inherited = fallbacks
        lock.unlock()
        if let own { return own }
        for store in inherited.reversed() { if let value = store.object(forKey: key) { return value } }
        return defaults
    }
    func bool(forKey key: String) -> Bool {
        if let number = object(forKey: key) as? NSNumber { return number.boolValue }
        return (object(forKey: key) as? NSString)?.boolValue ?? false
    }
    func integer(forKey key: String) -> Int {
        if let number = object(forKey: key) as? NSNumber { return number.intValue }
        return (object(forKey: key) as? NSString)?.integerValue ?? 0
    }
    func double(forKey key: String) -> Double {
        if let number = object(forKey: key) as? NSNumber { return number.doubleValue }
        return (object(forKey: key) as? NSString)?.doubleValue ?? 0
    }
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func dictionary(forKey key: String) -> [String: Any]? { object(forKey: key) as? [String: Any] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    func set(_ value: Any?, forKey key: String) {
        lock.lock(); defer { lock.unlock() }
        values[key] = value
    }
    func removeObject(forKey key: String) { set(nil, forKey: key) }
    func register(defaults registration: [String: Any]) {
        lock.lock(); defer { lock.unlock() }
        registered.merge(registration) { _, new in new }
    }
    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        values.removeAll(); registered.removeAll(); fallbacks.removeAll()
    }
    func addFallback(_ store: InMemoryPreferences) {
        precondition(store !== self)
        lock.lock(); defer { lock.unlock() }
        fallbacks.append(store)
    }
    func removeFallback(_ store: InMemoryPreferences) {
        lock.lock(); defer { lock.unlock() }
        fallbacks.removeAll { $0 === store }
    }
}
