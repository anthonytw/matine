import AVKit
import MatineKit
import SwiftUI

/// Full-screen playback with the system player: Siri Remote scrubbing and the
/// audio and subtitle menus come with it.
struct PlayerView: View {
    let item: Item
    /// The Apple TV's source: `ServerLibrarySource` with no device name asks
    /// the server with `PlaybackProfile.appleTV`.
    let source: any LibrarySource
    let startTicks: Int64
    let language: AppLanguage
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase

    @State private var playback = Playback()
    /// Which player this is, for the phone's controls (see `AppModel.playerAppeared`).
    @State private var playerId = UUID()
    /// A slow start says so after a few seconds, with a way out.
    @State private var slow = false

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let player = playback.player {
                SystemPlayer(player: player).ignoresSafeArea()
            } else if playback.failed {
                VStack(spacing: 24) {
                    Text("No se puede reproducir.").font(.title3)
                    Button("Volver") { dismiss() }
                }
            } else {
                VStack(spacing: 32) {
                    ProgressView()
                    if slow {
                        Text("Cargando…").font(.title3).foregroundStyle(.secondary)
                        Button("Volver") { dismiss() }
                    }
                }
                .task {
                    try? await Task.sleep(for: .seconds(5))
                    slow = true
                }
            }
        }
        // A PIN profile's relock waits for this player (`RelockGate`): in the
        // background the player covers itself, as the profile's screen does,
        // and back past the grace it stays covered while it closes.
        .overlay {
            if model.playerMustClose || model.coverPinPlayer || scenePhase == .background, case .home(let account) = model.screen, model.hasPin(account) {
                Color.black.ignoresSafeArea()
            }
        }
        .onChange(of: model.playerMustClose, initial: true) { if model.playerMustClose { dismiss() } }
        // The end of the video closes the player, back to where it was opened.
        .onChange(of: playback.ended) { if playback.ended { dismiss() } }
        .task {
            await playback.start(item: item, source: source, startTicks: startTicks, language: language)
            #if DEBUG
            // scripts/app.sh run-dev … -MatineDevStopAfter N: close after N seconds,
            // the way the Menu button would (the simulator has no remote).
            let stopAfter = UserDefaults.standard.double(forKey: "MatineDevStopAfter")
            if stopAfter > 0, playback.player != nil {
                try? await Task.sleep(for: .seconds(stopAfter))
                dismiss()
            }
            #endif
        }
        .onAppear {
            // The phone's controls steer this player while it is up.
            model.playerAppeared(playerId) { command in
                switch command {
                case .stop: dismiss()
                default: playback.apply(command)
                }
            }
        }
        .onDisappear {
            model.playerDisappeared(playerId)
            Task {
                // Only once Stopped is sent, and only if something played, do
                // Home and Detail refresh.
                if await playback.close() { model.playbackEnded() }
            }
        }
    }
}

private struct SystemPlayer: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let controller = AVPlayerViewController()
        controller.player = player
        // tvOS always publishes Now Playing (Control Center, the iPhone
        // remote); unlike iOS there is no switch for it.
        return controller
    }

    /// The HLS retry swaps in a new player; the controller must show it.
    func updateUIViewController(_ controller: AVPlayerViewController, context: Context) {
        if controller.player !== player { controller.player = player }
    }
}
