import AVFoundation
import AVKit
import MatineKit
import SwiftUI

/// Full-screen playback with the system player: scrubbing, picture in
/// picture and the audio and subtitle menus come with it, and so does its
/// close button, which closes this cover (see `SystemPlayer`).
struct PlayerView: View {
    let item: Item
    let account: Account
    let source: any LibrarySource
    let language: AppLanguage
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var playback = Playback()
    /// A slow start says so after a few seconds, with a way out.
    @State private var slow = false
    private let startTicks: Int64

    init(item: Item, account: Account, source: any LibrarySource, language: AppLanguage, startTicks: Int64? = nil) {
        self.item = item
        self.account = account
        self.source = source
        self.language = language
        self.startTicks = startTicks ?? item.resumeTicks
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = playback.player {
                SystemPlayer(player: player, onClose: { dismiss() }).ignoresSafeArea()
            } else if playback.failed {
                VStack(spacing: 20) {
                    Text("No se puede reproducir.").font(.title3)
                    Button("Volver") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .foregroundStyle(.white)
            } else {
                VStack(spacing: 24) {
                    ProgressView().tint(.white)
                    if slow {
                        Text("Cargando…").foregroundStyle(.secondary)
                        Button("Volver") { dismiss() }.buttonStyle(.bordered)
                    }
                }
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    slow = true
                }
            }
        }
        .onChange(of: playback.ended) { if playback.ended { dismiss() } }
        .task {
            // A relock as the app goes to the background still tells the server.
            playback.keepAlive = BackgroundTask.run
            await playback.start(item: item, source: source, startTicks: startTicks, language: language, constrained: model.isMetered)
            #if DEBUG
            // -MatineDevStopAfter N: close after N seconds (scripts, no touch screen).
            let stopAfter = UserDefaults.standard.double(forKey: "MatineDevStopAfter")
            if stopAfter > 0, playback.player != nil {
                try? await Task.sleep(for: .seconds(stopAfter))
                dismiss()
            }
            #endif
        }
        .onAppear { model.playerAppeared() }
        .onDisappear {
            model.playerDisappeared()
            Task {
                // Only once Stopped is sent, and only if something played, do
                // Home and Detail refresh.
                if await playback.close() { model.playbackEnded() }
            }
        }
        // The player is a full-screen cover, above the root's own cover: it covers itself for the
        // app switcher's snapshot (a PIN profile's player stays open in the background).
        .overlay { if scenePhase != .active, model.hasPin(account) { PrivacyCover() } }
        .statusBarHidden()
    }
}

private struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let onClose: () -> Void

    /// The system player's own close button, and a swipe down, leave its
    /// full-screen presentation; that is the cue to close ours. Starting
    /// Picture in Picture leaves it too, but then the video plays on: the
    /// player stays until the PiP window is closed (or restored).
    @MainActor final class Coordinator: NSObject, @preconcurrency AVPlayerViewControllerDelegate {
        var onClose: () -> Void = {}
        private var pipStarting = false
        private var pipActive = false
        private var restoring = false

        func playerViewController(_ controller: AVPlayerViewController, willEndFullScreenPresentationWithAnimationCoordinator coordinator: any UIViewControllerTransitionCoordinator) {
            // An interactive swipe down can be cancelled; PiP may start at
            // any point of the transition, so its flags are read at the end.
            coordinator.animate(alongsideTransition: nil) { context in
                let cancelled = context.isCancelled
                MainActor.assumeIsolated { self.fullScreenEnded(cancelled: cancelled) }
            }
        }

        private func fullScreenEnded(cancelled: Bool) {
            if !cancelled, !pipStarting, !pipActive { onClose() }
        }

        func playerViewControllerWillStartPictureInPicture(_ controller: AVPlayerViewController) {
            pipStarting = true
        }

        func playerViewControllerDidStartPictureInPicture(_ controller: AVPlayerViewController) {
            pipStarting = false
            pipActive = true
        }

        func playerViewController(_ controller: AVPlayerViewController, failedToStartPictureInPictureWithError error: any Error) {
            pipStarting = false
        }

        /// The PiP window's "back to app" button: our player is still
        /// presented underneath, so there is nothing to bring back.
        func playerViewController(_ controller: AVPlayerViewController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            restoring = true
            completionHandler(true)
        }

        /// The PiP window closed. Unless it went back to the app, that is a close.
        func playerViewControllerDidStopPictureInPicture(_ controller: AVPlayerViewController) {
            pipActive = false
            pipStarting = false
            let restored = restoring
            restoring = false
            if !restored { onClose() }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.delegate = context.coordinator
        controller.player = player
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        return controller
    }

    /// The HLS retry swaps in a new player; the controller must show it.
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        context.coordinator.onClose = onClose
        if controller.player !== player { controller.player = player }
    }
}

/// Holds a background task while `work` runs, so a report started as the app
/// leaves the screen is finished.
@MainActor enum BackgroundTask {
    private final class Box { var id = UIBackgroundTaskIdentifier.invalid }

    static func run(_ work: @escaping @MainActor () async -> Void) async {
        let box = Box()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "matine.stopped") {
            UIApplication.shared.endBackgroundTask(box.id)
            box.id = .invalid
        }
        await work()
        if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id) }
    }
}
