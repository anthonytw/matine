import Foundation
import Testing
@testable import MatineKit

@Suite struct InstallMarkerTests {
    func store(settings: InMemoryKeyValueStore = InMemoryKeyValueStore(), secrets: InMemorySecretStore = InMemorySecretStore()) -> AccountStore {
        AccountStore(settings: settings, secrets: secrets)
    }

    @Test func aFirstLaunchRemovesLeftoverSecretsAndMarks() throws {
        let secrets = InMemorySecretStore()
        try secrets.write(Data("old".utf8), for: "token.gone")
        let s = store(secrets: secrets)
        #expect(try s.reconcileInstall() == .fresh)
        #expect(try secrets.read("token.gone") == nil)
        #expect(try secrets.read("install-marker") != nil)
    }

    @Test func profilesWithTheirMarkerAreLeftAlone() throws {
        let s = store()
        _ = try s.reconcileInstall()
        try s.upsert(Account(id: "a", name: "a", server: testServer), token: "t")
        #expect(try s.reconcileInstall() == .normal)
        #expect(s.accounts().count == 1)
    }

    @Test func aBuildThatPredatesTheMarkerKeepsItsProfilesAndMarksThem() throws {
        let secrets = InMemorySecretStore()
        let s = store(secrets: secrets)
        try s.upsert(Account(id: "a", name: "a", server: testServer), token: "t")
        #expect(try s.reconcileInstall() == .normal)
        #expect(try secrets.read("install-marker") != nil)
        #expect(s.accounts().count == 1)
    }

    @Test func profilesRestoredFromABackupComeBackEmptyNotPinless() throws {
        // The settings survive a backup; the ThisDeviceOnly Keychain does not.
        let settings = InMemoryKeyValueStore()
        let before = store(settings: settings)
        _ = try before.reconcileInstall()
        try before.upsert(Account(id: "a", name: "a", server: testServer, role: .kid), token: "t")
        RecentSearches(settings: settings, accountId: "a").add("leones")

        let after = store(settings: settings, secrets: InMemorySecretStore())
        #expect(try after.reconcileInstall() == .restored)
        #expect(after.accounts().isEmpty)
        #expect(RecentSearches(settings: settings, accountId: "a").list().isEmpty)
        // From here on it is an ordinary install with no profiles.
        #expect(try after.reconcileInstall() == .normal)
    }

    @Test func anUnreadableListIsNeverWiped() throws {
        let settings = InMemoryKeyValueStore()
        settings.set(Data("not json".utf8), forKey: AccountStore.accountsKey)
        let s = store(settings: settings)
        #expect(throws: (any Error).self) { try s.reconcileInstall() }
        #expect(settings.data(forKey: AccountStore.accountsKey) != nil)
    }
}
