import CloudKit
import MatineKit
import Observation
import SwiftUI
import UIKit

// Sharing the search keywords with another Apple ID (a zone-wide CKShare of the
// Keywords zone only; see KeywordShare in MatineKit). Owner: ProfileView's
// "Búsqueda" row presents the system sharing sheet. Participant: opening the
// invitation link launches the app, which accepts it here.

/// A share the system handed to the app, waiting for the model to accept it.
@MainActor @Observable
final class ShareInbox {
    static let shared = ShareInbox()
    /// Bumped on every arrival: the app's `.task(id:)` runs again.
    private(set) var arrivals = 0
    @ObservationIgnored private var pending: CKShare.Metadata?

    func receive(_ metadata: CKShare.Metadata) {
        pending = metadata
        arrivals += 1
    }

    func take() -> CKShare.Metadata? {
        defer { pending = nil }
        return pending
    }
}

/// Gives the scene a delegate that hears of accepted shares (SwiftUI has no hook for it).
final class ShareAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        // Launched by the invitation link: the metadata comes with the connection options.
        if let metadata = options.cloudKitShareMetadata {
            ShareInbox.shared.receive(metadata)
        }
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = ShareSceneDelegate.self
        return configuration
    }
}

final class ShareSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// The app was already running when the link was opened.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        ShareInbox.shared.receive(cloudKitShareMetadata)
    }
}

/// "Compartir con otra persona…" in a grown-up's profile.
struct KeywordShareRow: View {
    @Environment(AppModel.self) private var model
    @State private var status: KeywordShare.Status?
    @State private var presenting: SharePresentation?
    @State private var busy = false
    @State private var failed = false

    private var isShared: Bool { if case .shared = status { true } else { false } }

    struct SharePresentation: Identifiable {
        let id = UUID()
        let share: CKShare
        let container: CKContainer
    }

    var body: some View {
        Group {
            if model.keywords.participating {
                Label("Recibes las palabras clave de otra persona.", systemImage: "person.2.fill")
                    .foregroundStyle(.secondary)
            }
            // A participant can't share back, but can still manage a share of her own.
            if !model.keywords.participating || isShared {
            Button {
                Task { await present() }
            } label: {
                HStack {
                    if case .shared = status { Text("Gestionar lo compartido…") } else { Text("Compartir con otra persona…") }
                    Spacer()
                    if busy { ProgressView() }
                }
            }
            .disabled(busy)
            }
            if case .shared(let people) = status {
                Text("Invitados: \(people)").foregroundStyle(.secondary)
            }
            if failed {
                Text("No se pudo preparar el uso compartido. Comprueba que iCloud esté activo.").foregroundStyle(.red)
            }
        }
        .task { await refresh() }
        .sheet(item: $presenting, onDismiss: { Task { await refresh() } }) { item in
            CloudSharingView(share: item.share, container: item.container) { presenting = nil }
                .ignoresSafeArea()
        }
    }

    private func refresh() async {
        status = try? await KeywordShare().status()
    }

    private func present() async {
        busy = true
        failed = false
        defer { busy = false }
        do {
            let (share, container) = try await KeywordShare().shareToPresent()
            presenting = SharePresentation(share: share, container: container)
        } catch {
            failed = true
        }
    }
}

/// The system sharing sheet: invite by Messages or Mail, see who has it, stop sharing.
private struct CloudSharingView: UIViewControllerRepresentable {
    let share: CKShare
    let container: CKContainer
    let done: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(done: done) }

    func makeUIViewController(context: Context) -> UICloudSharingController {
        let controller = UICloudSharingController(share: share, container: container)
        controller.availablePermissions = [.allowPrivate, .allowReadWrite]
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: UICloudSharingController, context: Context) {}

    final class Coordinator: NSObject, UICloudSharingControllerDelegate {
        let done: () -> Void
        init(done: @escaping () -> Void) { self.done = done }

        func itemTitle(for csc: UICloudSharingController) -> String? { KeywordShare.title }
        func cloudSharingController(_ csc: UICloudSharingController, failedToSaveShareWithError error: any Error) { done() }
        func cloudSharingControllerDidStopSharing(_ csc: UICloudSharingController) { done() }
    }
}
