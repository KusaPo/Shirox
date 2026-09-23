import SwiftUI
import AVKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var anime: Anime
    var episode: Int
    var stream: StreamOption?
    var localURL: URL?
}

final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published var error: String?
    @Published var isPreparing = true
    private var observation: NSKeyValueObservation?
    private var timeToken: Any?
    private var active: PlaybackRequest?
    private weak var store: AppStore?

    @MainActor func open(_ request: PlaybackRequest, store: AppStore) async {
        isPreparing = true
        error = nil
        active = request
        self.store = store
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            guard let url = request.localURL ?? request.stream?.url else { throw KairoError.message("The player has no media URL.") }
            if request.localURL != nil, !FileManager.default.fileExists(atPath: url.path) { throw KairoError.message("This downloaded file is no longer on the device.") }
            let headers = request.localURL == nil ? request.stream?.headers ?? [:] : [:]
            let asset = AVURLAsset(url: url, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
            guard try await asset.load(.isPlayable) else { throw KairoError.message("This stream was found but iOS cannot play its format. Try another provider.") }
            try Task.checkCancellation()
            let item = AVPlayerItem(asset: asset)
            observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    DispatchQueue.main.async { self?.error = "Playback failed. \(item.error?.localizedDescription ?? "Try another provider.")" }
                }
            }
            player.replaceCurrentItem(with: item)
            if let progress = store.progress(request.anime, episode: request.episode), !progress.finished {
                await player.seek(to: CMTime(seconds: progress.seconds, preferredTimescale: 600))
            }
            try Task.checkCancellation()
            timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self] _ in self?.saveProgress() }
            player.play()
            isPreparing = false
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; isPreparing = false }
    }

    func saveProgress(finished: Bool = false) {
        guard let active, let duration = player.currentItem?.duration.seconds else { return }
        let seconds = player.currentTime().seconds
        store?.record(active.anime, episode: active.episode, seconds: seconds, duration: duration, finished: finished || (duration.isFinite && duration > 0 && seconds >= duration - 1))
    }
    func stop() {
        saveProgress()
        player.pause()
        if let timeToken { player.removeTimeObserver(timeToken); self.timeToken = nil }
        observation = nil
        player.replaceCurrentItem(with: nil)
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = AVPlayerViewController()
        view.player = player
        view.allowsPictureInPicturePlayback = true
        view.canStartPictureInPictureAutomaticallyFromInline = true
        return view
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) { uiViewController.player = player }
}

struct PlayerScreen: View {
    let request: PlaybackRequest
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var controller = PlaybackController()
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayer(player: controller.player).ignoresSafeArea()
            if controller.isPreparing {
                Color.black.ignoresSafeArea()
                ProgressView("Preparing episode…").tint(.white).foregroundStyle(.white)
            }
            if let error = controller.error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.play").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button("Choose another provider") { dismiss() }.buttonStyle(.borderedProminent)
                }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding()
            }
        }
        .overlay(alignment: .topLeading) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.subheadline.bold())
                    .frame(width: 38, height: 38)
                    .background(.black.opacity(0.65), in: Circle())
            }
            .foregroundStyle(.white)
            .accessibilityLabel("Close player")
            .padding()
        }
        .task { await controller.open(request, store: store) }
        .onDisappear { controller.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === controller.player.currentItem else { return }
            controller.saveProgress(finished: true)
        }
    }
}
