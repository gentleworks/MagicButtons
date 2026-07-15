import Testing
import Foundation
@testable import AppCore
import GestureEngine
import TouchKit

// Phase 7.2 — settings persistence: one Codable bundle through a storage seam,
// plus Export/Import JSON and reset. Pure, hardware-free (docs/09 §Persistence,
// docs/11 §Phase 7.2).

/// In-memory `SettingsStorage` so the store is tested without the real defaults DB.
private final class MemoryStorage: SettingsStorage {
    private var store: [String: Data] = [:]
    func data(forKey key: String) -> Data? { store[key] }
    func setData(_ data: Data?, forKey key: String) { store[key] = data }
}

/// A settings value that differs from defaults in every section, for round-trips.
private func customized() -> AppSettings {
    AppSettings(
        zones: ZoneLayout(leftEdge: 0.30, rightEdge: 0.70),
        gestures: GestureConfig(maxSize: 22, doubleTapGap: 0.4),
        features: FeaturePolicy(masterEnabled: true, middleClick: false,
                                tapToClick: true, middleTapToClick: false),
        launchAtLogin: true)
}

@Suite struct SettingsStoreTests {

    @Test func loadReturnsDefaultsWhenEmpty() {
        let store = SettingsStore(storage: MemoryStorage())
        #expect(store.load() == AppSettings())
    }

    @Test func saveThenLoadRoundTrips() {
        let store = SettingsStore(storage: MemoryStorage())
        let settings = customized()
        store.save(settings)
        #expect(store.load() == settings)
    }

    @Test func resetRestoresDefaultsAndPersists() {
        let storage = MemoryStorage()
        let store = SettingsStore(storage: storage)
        store.save(customized())
        let reset = store.reset()
        #expect(reset == AppSettings())
        // Persisted, not just returned: a fresh store over the same storage agrees.
        #expect(SettingsStore(storage: storage).load() == AppSettings())
    }

    @Test func exportProducesReimportableJSON() throws {
        let store = SettingsStore(storage: MemoryStorage())
        let settings = customized()
        let json = try store.exportJSON(settings)
        #expect(try store.importJSON(json) == settings)
    }

    @Test func importPersistsToStore() throws {
        let storage = MemoryStorage()
        let settings = customized()
        let json = try SettingsStore(storage: MemoryStorage()).exportJSON(settings)
        _ = try SettingsStore(storage: storage).importJSON(json)
        // A fresh store over the imported-into storage loads the imported value.
        #expect(SettingsStore(storage: storage).load() == settings)
    }

    @Test func loadIgnoresCorruptData() {
        let storage = MemoryStorage()
        storage.setData(Data("not json".utf8), forKey: "settings.v1")
        // Corrupt blob must not throw/crash — fall back to defaults.
        #expect(SettingsStore(storage: storage).load() == AppSettings())
    }

    @Test func importThrowsOnInvalidJSON() {
        let store = SettingsStore(storage: MemoryStorage())
        // A JSON array is valid JSON but not a settings object → surface the error.
        #expect(throws: (any Error).self) {
            try store.importJSON(Data("[1,2,3]".utf8))
        }
    }
}
