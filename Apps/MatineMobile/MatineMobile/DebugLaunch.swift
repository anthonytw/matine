#if DEBUG
import Foundation
import MatineKit

/// Simulator-only shortcuts for scripts/mobile.sh: sign in from environment
/// variables (`SIMCTL_CHILD_MATINE_DEV_*`) and jump to a screen and language
/// from launch arguments (`-MatineDevScreen`, `-MatineDevLanguage`).
/// Compiled out of Release builds.
extension AppModel {
    func applyDebugLaunch() async {
        let env = ProcessInfo.processInfo.environment
        guard let server = env["MATINE_DEV_SERVER"].flatMap(Profiles.serverURL(from:)),
              let user = env["MATINE_DEV_USER"], let password = env["MATINE_DEV_PASSWORD"]
        else { return }
        let saved = accounts.first { $0.server == server && $0.name.lowercased() == user.lowercased() }
        var account: Account
        if let saved {
            account = saved
        } else {
            guard let signedIn = try? await signIn(server: server, username: user, password: password) else { return }
            account = signedIn
        }
        let arguments = UserDefaults.standard
        if let raw = arguments.string(forKey: "MatineDevLanguage"), let language = AppLanguage(rawValue: raw) {
            debugDefaultLanguage = language
            setLanguage(language, for: account)
            account = current(account)
        }
        // -MatineDevRole kid|adult: the profile's role, past the house rules (debug only).
        if let raw = arguments.string(forKey: "MatineDevRole"), let role = ProfileRole(rawValue: raw) {
            var changed = current(account)
            changed.role = role
            try? profiles.store.update(changed)
            reload()
            account = current(account)
        }
        // -MatineDevName NAME: what the picker calls this profile (screenshots).
        if let name = arguments.string(forKey: "MatineDevName") {
            var changed = current(account)
            changed.displayName = name
            try? profiles.store.update(changed)
            reload()
            account = current(account)
        }
        // -MatineDevDemoProfiles: made-up housemates next to the real login, so the picker
        // has more than one profile (screenshots; they hold a dummy token and open nothing).
        if arguments.bool(forKey: "MatineDevDemoProfiles") {
            let look = [("Leo", ProfileRole.kid, Avatar(figure: .animal(.dog), color: .tangerine)),
                        ("Marta", .adult, Avatar(figure: .robot(seed: 7), color: .ocean)),
                        ("Nico", .kid, Avatar(figure: .animal(.hare), color: .forest))]
            for (name, role, avatar) in look {
                let demo = Account(id: "demo-" + name.lowercased(), name: name, server: server, language: account.language,
                                   displayName: name, role: role, avatar: avatar)
                try? profiles.store.upsert(demo, token: "demo")
            }
            reload()
        }
        // Jump only when asked: a plain run keeps the normal start (picker, PIN).
        guard let target = arguments.string(forKey: "MatineDevScreen") else { return }
        switch target {
        case "picker": screen = .picker
        case "add": screen = .addProfile(nil)
        case "pin": screen = .pin(account)
        default:
            // "home", or a place inside it: item:ID, library:ID, search, profile, play:ID.
            if target != "home" { debugRoute = target }
            screen = .home(account)
        }
    }
}
#endif
