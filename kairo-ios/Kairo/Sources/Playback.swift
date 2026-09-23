import SwiftUI
import AVKit

struct PlaybackRequest: Identifiable {
    let id = UUID()
    var anime: Anime
    var episode: Int
    var stream: StreamOption?
    var localURL: URL?
    var localAudio: AudioChoice? = nil
    var audio: AudioChoice? { stream?.audio ?? localAudio }
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
    @Published private(set) var active: PlaybackRequest?
    @Published var audioNotice: String?
    @Published private(set) var isSwitchingAudio = false
    private var lastProgressSave = Date.distantPast
    private weak var store: AppStore?

    @MainActor func open(_ request: PlaybackRequest, store: AppStore, resumeAt: Double? = nil) async {
        saveProgress()
        isPreparing = true
        error = nil
        skipPrompt = nil
        intervals = []
        skipped = []
        if let timeToken { player.removeTimeObserver(timeToken); self.timeToken = nil }
        observation = nil
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
            active = request
            let item = AVPlayerItem(asset: asset)
            if let audio = request.audio,
               let group = try? await asset.loadMediaSelectionGroup(for: .audible),
               let option = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: audio.languageCode)).first {
                item.select(option, in: group)
            }
            try Task.checkCancellation()
            observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    DispatchQueue.main.async { self?.error = "Playback failed. \(item.error?.localizedDescription ?? "Try another provider.")" }
                }
            }
            player.replaceCurrentItem(with: item)
            if let resumeAt, resumeAt.isFinite, resumeAt > 0 {
                await player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
            } else if let progress = store.progress(request.anime, episode: request.episode), !progress.finished {
                await player.seek(to: CMTime(seconds: progress.seconds, preferredTimescale: 600))
            }
            try Task.checkCancellation()
            timeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 1), queue: .main) { [weak self] _ in
                if let self, Date().timeIntervalSince(self.lastProgressSave) >= 5 {
                    self.saveProgress(); self.lastProgressSave = Date()
                }
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
    @MainActor func playNext(store: AppStore) async {
        guard let request = active, !isPreparing, !isSwitchingAudio else { return }
        let episode = request.episode + 1
        guard request.anime.episodeCount.map({ episode <= $0 }) ?? false else { return }
        let audio = request.audio ?? store.state.preferences.audio
        isPreparing = true
        do {
            if let saved = store.readyDownload(request.anime, episode: episode, audio: audio) {
                try Task.checkCancellation()
                await open(PlaybackRequest(anime: request.anime, episode: episode, localURL: saved.localURL, localAudio: saved.audio), store: store)
            } else {
                guard store.state.preferences.animexEnabled else { throw KairoError.message("Enable Animex to stream the next episode, or download its selected language first.") }
                let options = try await CatalogAPI.shared.streams(request.anime, episode: episode, audio: audio)
                try Task.checkCancellation()
                guard let choice = options.first(where: { $0.provider == request.stream?.provider }) ?? options.first else {
                    throw KairoError.message("The next episode has no playable stream.")
                }
                await open(PlaybackRequest(anime: request.anime, episode: episode, stream: choice), store: store)
            }
        } catch is CancellationError { isPreparing = false }
        catch { self.error = "Couldn't start episode \(episode) in \(audio.label): \(error.localizedDescription)"; isPreparing = false }
    }

    @MainActor func switchAudio(to audio: AudioChoice, store: AppStore) async {
        guard let request = active, !isPreparing, !isSwitchingAudio, request.audio != audio else { return }
        isSwitchingAudio = true; audioNotice = nil
        defer { isSwitchingAudio = false }
        do {
            let replacement: PlaybackRequest
            if let saved = store.readyDownload(request.anime, episode: request.episode, audio: audio) {
                replacement = PlaybackRequest(anime: request.anime, episode: request.episode, localURL: saved.localURL, localAudio: audio)
            } else {
                guard store.state.preferences.animexEnabled else { throw KairoError.message("Enable Animex to check this language online.") }
                let options = try await CatalogAPI.shared.streams(request.anime, episode: request.episode, audio: audio)
                guard let stream = options.first(where: { $0.provider == request.stream?.provider }) ?? options.first else {
                    throw KairoError.message("No provider offers \(audio.label) for this episode.")
                }
                replacement = PlaybackRequest(anime: request.anime, episode: request.episode, stream: stream)
            }
            try Task.checkCancellation()
            let position = player.currentTime().seconds
            await open(replacement, store: store, resumeAt: position)
            if error == nil, !Task.isCancelled {
                store.state.preferences.audio = audio; store.save()
            }
        } catch is CancellationError { }
        catch { audioNotice = "Couldn't switch to \(audio.label). \(error.localizedDescription)" }
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
        active = nil
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let onTap: () -> Void
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void
        init(onTap: @escaping () -> Void) { self.onTap = onTap }
        @objc func didTap() { onTap() }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = AVPlayerViewController()
        view.player = player
        view.allowsPictureInPicturePlayback = true
        view.canStartPictureInPictureAutomaticallyFromInline = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap))
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.view.addGestureRecognizer(tap)
        return view
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
        context.coordinator.onTap = onTap
    }
}

struct PlayerScreen: View {
    let request: PlaybackRequest
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var controller = PlaybackController()
    @AppStorage("playerAutoPlayNext") private var autoPlayNext = false
    @AppStorage("playerAutoSkipIntro") private var autoSkipIntro = false
    @State private var transitionTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayer(player: controller.player, onTap: toggleControls).ignoresSafeArea()
            if controller.isPreparing {
                Color.black.ignoresSafeArea()
                    .onTapGesture(perform: toggleControls)
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
            if controlsVisible {
                HStack {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.subheadline.bold())
                        .frame(width: 38, height: 38)
                        .background(.black.opacity(0.65), in: Circle())
                }.accessibilityLabel("Close player")
                Spacer()
                Menu {
                    ForEach(AudioChoice.allCases) { choice in
                        Button {
                            transitionTask?.cancel()
                            transitionTask = Task { await controller.switchAudio(to: choice, store: store) }
                        } label: {
                            if controller.active?.audio == choice { Label(choice.label, systemImage: "checkmark") }
                            else { Text(choice.label) }
                        }
                    }
                    Text("Undownloaded audio requires a connection.")
                } label: {
                    Text(controller.isSwitchingAudio ? "Checking…" : (controller.active?.audio ?? request.audio ?? store.state.preferences.audio).shortLabel)
                        .font(.subheadline.bold()).padding(.horizontal, 12).frame(height: 38)
                        .background(.black.opacity(0.65), in: Capsule())
                }.disabled(controller.isPreparing || controller.isSwitchingAudio)
                    .accessibilityLabel("Sub or Dub audio")
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
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: controlsVisible)
        .task { controller.autoSkip = autoSkipIntro; await controller.open(request, store: store) }
        .alert("Audio unavailable", isPresented: Binding(get: { controller.audioNotice != nil }, set: { if !$0 { controller.audioNotice = nil } })) {
            Button("OK", role: .cancel) { controller.audioNotice = nil }
        } message: { Text(controller.audioNotice ?? "") }
        .onChange(of: controller.isPreparing) { _, preparing in
            if preparing { hideControlsTask?.cancel(); controlsVisible = true }
            else { scheduleHideControls() }
        }
        .onChange(of: autoSkipIntro) { _, enabled in controller.autoSkip = enabled }
        .onChange(of: scenePhase) { _, phase in if phase != .active { controller.saveProgress() } }
        .onDisappear { transitionTask?.cancel(); hideControlsTask?.cancel(); controller.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === controller.player.currentItem else { return }
            controller.saveProgress(finished: true)
            if autoPlayNext {
                transitionTask?.cancel()
                transitionTask = Task { await controller.playNext(store: store) }
            }
        }
    }
    private func toggleControls() {
        hideControlsTask?.cancel()
        controlsVisible.toggle()
        if controlsVisible && !controller.isPreparing { scheduleHideControls() }
    }
    private func scheduleHideControls() {
        hideControlsTask?.cancel()
        hideControlsTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            if !Task.isCancelled { controlsVisible = false }
        }
    }
}
