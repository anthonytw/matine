import MatineKit
import SwiftUI

@main
struct MatineApp: App {
    @State private var model = AppModel.live()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.locale, model.language.locale)
                .onOpenURL { model.open($0) }
                #if DEBUG
                .task { await model.applyDebugLaunch() }
                #endif
        }
        // initial: the starting phase too. A launch that is already active
        // must clear the previous run's away record (AwayRecord), or it would
        // outlive this session and ignore every later leave.
        .onChange(of: scenePhase, initial: true) { _, phase in model.phaseChanged(to: phase) }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        screen
            .overlay(alignment: .top) {
                // A passing notice, never over the player.
                if let notice = model.householdNotice, !model.playerIsOpen {
                    HouseholdBanner(notice: notice)
                }
            }
            .overlay {
            // A PIN profile stays open in the background for the grace period:
            // keep it out of the app switcher's snapshot. (Not when merely
            // inactive: Control Center over a film must not black it out.)
            if scenePhase == .background, case .home(let account) = model.screen, model.hasPin(account) {
                Color.black.ignoresSafeArea()
            }
        }
    }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .picker:
            ProfilePickerView()
        case .addProfile(let account):
            AddProfileView(again: account)
        case .pin(let account):
            PinEntryView(account: account)
        case .adultCheck:
            AdultCheckView()
        case .home(let account):
            if let client = model.client(for: account) {
                // Keyed by id: a language change re-renders in place instead
                // of rebuilding the screen and closing Settings.
                MainTabs(account: account, client: client)
                    .id(account.id)
            } else {
                // The token is gone from the Keychain: sign in again.
                AddProfileView(again: account)
            }
        }
    }
}

/// "iPad ha entrado como Ana": another device of this household was let in from here.
private struct HouseholdBanner: View {
    let notice: AppModel.HouseholdNotice

    var body: some View {
        Label("\(notice.device) ha entrado como \(notice.name)", systemImage: "person.crop.circle.badge.checkmark")
            .font(.callout.weight(.medium))
            .padding(.horizontal, 28).padding(.vertical, 14)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 40)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
