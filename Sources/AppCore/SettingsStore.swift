import Foundation

/// Minimal key→`Data` seam behind `SettingsStore`, so the store is unit-testable
/// with an in-memory fake and never touches the real defaults database in CI.
/// Production uses `UserDefaultsStorage`; tests use their own conformer.
public protocol SettingsStorage {
    func data(forKey key: String) -> Data?
    /// `nil` removes the key.
    func setData(_ data: Data?, forKey key: String)
}

/// `UserDefaults`-backed storage (docs/09 §Persistence: v1 persists to
/// `UserDefaults`). Wraps an instance rather than conforming `UserDefaults`
/// retroactively, keeping the seam explicit and Sendable-clean.
public struct UserDefaultsStorage: SettingsStorage {
    private let defaults: UserDefaults
    public init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    public func data(forKey key: String) -> Data? { defaults.data(forKey: key) }
    public func setData(_ data: Data?, forKey key: String) {
        if let data { defaults.set(data, forKey: key) } else { defaults.removeObject(forKey: key) }
    }
}

/// Loads/saves `AppSettings` and moves it in/out of a JSON file for the
/// cross-machine Export/Import (docs/09 §Persistence & sync). Stateless over its
/// storage — every call reads/writes through the seam — so there is no cached copy
/// to fall out of sync.
public struct SettingsStore {
    private let storage: any SettingsStorage
    private let key: String

    /// `key` is versioned so a future incompatible schema can migrate rather than
    /// misread an old blob (the bundle ID it lives under is fixed — docs/12).
    public init(storage: any SettingsStorage, key: String = "settings.v1") {
        self.storage = storage
        self.key = key
    }

    /// Current settings, or **defaults** when nothing is stored *or* the stored blob
    /// is unreadable — a corrupt store must never brick launch. (Distinct from
    /// `importJSON`, which *does* surface an error on an invalid file the user chose.)
    public func load() -> AppSettings {
        guard let data = storage.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    public func save(_ settings: AppSettings) {
        storage.setData(try? JSONEncoder().encode(settings), forKey: key)
    }

    /// Restore defaults and persist them.
    @discardableResult
    public func reset() -> AppSettings {
        let defaults = AppSettings()
        save(defaults)
        return defaults
    }

    /// Human-readable, stable JSON for the Export file (sorted keys → clean diffs
    /// and reproducible files).
    public func exportJSON(_ settings: AppSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(settings)
    }

    /// Decode an Export file and persist it. **Throws** on data that isn't valid
    /// settings JSON at all (so the UI can tell the user the import failed), but a
    /// valid-yet-partial file decodes leniently to defaults for the missing pieces.
    @discardableResult
    public func importJSON(_ data: Data) throws -> AppSettings {
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        save(settings)
        return settings
    }
}
