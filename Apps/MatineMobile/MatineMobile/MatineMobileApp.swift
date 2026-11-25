import MatineKit
import SwiftUI

@main
struct MatineMobileApp: App {
    @State private var model = AppModel.live()
    // Keyword share: hears of an accepted invitation (KeywordShareViews).
    @UIApplicationDelegateAdaptor(ShareAppDelegate.self) private var shareDelegate
    private let shareInbox = ShareInbox.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .environment(\.locale, model.language.locale)
                // Keyword share: accept the invitation, then read what the other person made.
                .task(id: shareInbox.arrivals) {
                    guard let metadata = shareInbox.take() else { return }
                    await model.keywords.acceptShare(metadata)
                    await model.refreshKeywords()
                }
                .alert(model.keywords.shareNotice ?? "", isPresented: Binding(
                    get: { model.keywords.shareNotice != nil }, set: { if !$0 { model.keywords.shareNotice = nil } }
                )) { Button("Vale") {} }
                #if DEBUG
                .task { await model.applyDebugLaunch() }
                #endif
        }
        .onChange(of: scenePhase) { _, phase in model.phaseChanged(to: phase) }
        // The system relaunched the app for downloads that finished meanwhile:
        // the engine (made with the model) receives them; hold on until it has.
        .backgroundTask(.urlSession(Downloader.sessionIdentifier)) { [engine = model.downloads.engine] in
            await engine.waitForBackgroundEvents()
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        screen
            // The app switcher shows a snapshot of the last frame: a profile
            // behind a PIN is covered the moment the app stops being active.
            .overlay { if covered { PrivacyCover() } }
            .overlay(alignment: .top) {
                if let notice = model.householdNotice {
                    HouseholdBanner(notice: notice)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeOut(duration: 0.25), value: model.householdNotice)
    }

    private var covered: Bool {
        guard scenePhase != .active, case .home(let account) = model.screen else { return false }
        return model.hasPin(account)
    }

    @ViewBuilder private var screen: some View {
        switch model.screen {
        case .picker:
            ProfilePickerView()
        case .addProfile(let account):
            SignInView(again: account)
        case .pin(let account):
            PinEntryView(account: account)
        case .adultCheck:
            AdultCheckView()
        case .home(let account):
            if let source = model.source(for: account) {
                // Keyed by id: a language change re-renders in place instead of
                // rebuilding the screen.
                MainView(account: account, source: source)
                    .id(account.id)
            } else {
                // The token is gone from the Keychain: sign in again.
                SignInView(again: account)
            }
        }
    }
}

/// Opaque and empty but for the lock: nothing of the profile shows through.
struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            Image(systemName: "lock.fill").font(.largeTitle).foregroundStyle(.secondary)
        }
        .accessibilityHidden(true)
    }
}

/// "iPad ha entrado como Ana": another device of this household was let in from here.
/// A passing notice, in the app only; it takes no taps and no focus.
private struct HouseholdBanner: View {
    let notice: AppModel.HouseholdNotice

    var body: some View {
        Label("\(notice.device) ha entrado como \(notice.name)", systemImage: "person.crop.circle.badge.checkmark")
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .allowsHitTesting(false)
            .accessibilityAddTraits(.updatesFrequently)
    }
}
