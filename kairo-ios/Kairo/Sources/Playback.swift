import SwiftUI
import AVKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var anime: Anime
    var episode: Int
    var stream: StreamOption?
    var localURL: URL?
}

struct SkipInterval {
    let start: Double
    let end: Double
    let label: String
}

actor SkipTimeAPI {
    static let shared = SkipTimeAPI()
    func intervals(malID: Int, episode: Int, duration: Double) async -> [SkipInterval] {
        guard malID > 0, episode > 0, duration.isFinite, duration > 0,
              let url = URL(string: "https://api.aniskip.com/v2/skip-times/\(malID)/\(episode)?types=op&types=recap&episodeLength=\(Int(duration))") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 8
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["results"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let type = row["skipType"] as? String, ["op", "mixed-op", "recap"].contains(type),
                  let interval = row["interval"] as? [String: Any],
                  let start = (interval["startTime"] as? NSNumber)?.doubleValue,
                  let end = (interval["endTime"] as? NSNumber)?.doubleValue,
                  start >= 0, end > start, end <= duration + 10 else { return nil }
            return SkipInterval(start: start, end: min(end, duration), label: type == "recap" ? "Skip recap" : "Skip intro")
        }
    }
}

final class PlaybackController: ObservableObject {
    let player = AVPlayer()
    @Published var error: String?
    @Published var isPreparing = true
    @Published var skipPrompt: SkipInterval?
    var autoSkip = false
    private var intervals: [SkipInterval] = []
    private var skipped = Set<Int>()
    private var observation: NSKeyValueObservation?
    private var timeToken: Any?
    private var active: PlaybackRequest?
    private weak var store: AppStore?

    @MainActor func open(_ request: PlaybackRequest, store: AppStore) async {
        isPreparing = true
        error = nil
        skipPrompt = nil
        intervals = []
        skipped = []
        if let timeToken { player.removeTimeObserver(timeToken); self.timeToken = nil }
        observation = nil
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
            timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
                self?.saveProgress()
                self?.checkSkip()
            }
            player.play()
            isPreparing = false
            if let malID = request.anime.malID {
                let duration = try? await asset.load(.duration)
                let intervals = await SkipTimeAPI.shared.intervals(malID: malID, episode: request.episode, duration: duration?.seconds ?? .nan)
                if !Task.isCancelled, active?.id == request.id { self.intervals = intervals }
            }
        } catch is CancellationError { }
        catch { self.error = error.localizedDescription; isPreparing = false }
    }

    private func checkSkip() {
        let seconds = player.currentTime().seconds
        guard seconds.isFinite else { return }
        skipPrompt = nil
        for (index, interval) in intervals.enumerated() where !skipped.contains(index) && seconds >= interval.start && seconds < interval.end - 1 {
            if autoSkip { skipped.insert(index); player.seek(to: CMTime(seconds: interval.end, preferredTimescale: 600)) }
            else { skipPrompt = interval }
            break
        }
    }
    func skipNow() {
        guard let interval = skipPrompt else { return }
        if let index = intervals.firstIndex(where: { $0.start == interval.start }) { skipped.insert(index) }
        skipPrompt = nil
        player.seek(to: CMTime(seconds: interval.end, preferredTimescale: 600))
    }
    @MainActor func playNext(after request: PlaybackRequest, store: AppStore) async {
        let episode = request.episode + 1
        guard request.anime.episodeCount.map({ episode <= $0 }) ?? false else { return }
        isPreparing = true
        do {
            if let local = store.state.downloads.first(where: {
                $0.anime.id == request.anime.id && $0.episode == episode && $0.state == .ready
            })?.localURL {
                await open(PlaybackRequest(anime: request.anime, episode: episode, stream: nil, localURL: local), store: store)
            } else {
                let options = try await CatalogAPI.shared.streams(request.anime, episode: episode, audio: request.stream?.audio ?? .sub)
                guard let choice = options.first(where: { $0.provider == request.stream?.provider }) ?? options.first else {
                    throw KairoError.message("The next episode has no playable stream.")
                }
                await open(PlaybackRequest(anime: request.anime, episode: episode, stream: choice), store: store)
            }
        } catch { self.error = "Couldn't start episode \(episode): \(error.localizedDescription)"; isPreparing = false }
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
    @AppStorage("playerAutoPlayNext") private var autoPlayNext = false
    @AppStorage("playerAutoSkipIntro") private var autoSkipIntro = false
    @State private var currentRequest: PlaybackRequest?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayer(player: controller.player).ignoresSafeArea()
            if controller.isPreparing {
                Color.black.ignoresSafeArea()
                ProgressView("Preparing episode…").tint(.white).foregroundStyle(.white)
            }
            if let prompt = controller.skipPrompt, !controller.isPreparing {
                VStack { Spacer(); HStack { Spacer(); Button(prompt.label) { controller.skipNow() }.buttonStyle(.borderedProminent).padding(24) } }
            }
            if let error = controller.error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.play").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button("Choose another provider") { dismiss() }.buttonStyle(.borderedProminent)
                }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding()
            }
        }
        .overlay(alignment: .top) {
            HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.bold())
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.65), in: Circle())
                }.accessibilityLabel("Close player")
                Spacer()
                Menu {
                    Toggle("Auto-play next episode", isOn: $autoPlayNext)
                    Toggle("Auto-skip intro and recap", isOn: $autoSkipIntro)
                } label: {
                    Image(systemName: "gearshape.fill").font(.subheadline.bold())
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.65), in: Circle())
                }.accessibilityLabel("Playback settings")
            }
            .foregroundStyle(.white)
            .padding()
        }
        .task { currentRequest = request; controller.autoSkip = autoSkipIntro; await controller.open(request, store: store) }
        .onChange(of: autoSkipIntro) { _, enabled in controller.autoSkip = enabled }
        .onDisappear { controller.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === controller.player.currentItem else { return }
            controller.saveProgress(finished: true)
            if autoPlayNext, let currentRequest {
                Task { await controller.playNext(after: currentRequest, store: store) }
                self.currentRequest = PlaybackRequest(anime: currentRequest.anime, episode: currentRequest.episode + 1, stream: nil)
            }
        }
    }
}
