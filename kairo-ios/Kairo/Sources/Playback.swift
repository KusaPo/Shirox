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
            player.appliesMediaSelectionCriteriaAutomatically = false
            if let audio = request.audio,
               let group = try? await asset.loadMediaSelectionGroup(for: .audible),
               let option = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: audio.languageCode)).first {
                item.select(option, in: group)
            }
            if request.audio == .sub,
               let group = try? await asset.loadMediaSelectionGroup(for: .legible),
               let option = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: "en")).first {
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
        let episode = request.anime.moduleEpisodes?.first(where: { $0.number > request.episode })?.number ?? (request.episode + 1)
        guard request.anime.episodeCount.map({ episode <= $0 }) ?? false else { return }
        let audio = request.audio ?? store.state.preferences.audio
        isPreparing = true
        do {
            if let saved = store.readyDownload(request.anime, episode: episode, audio: audio) {
                try Task.checkCancellation()
                await open(PlaybackRequest(anime: request.anime, episode: episode, localURL: saved.localURL, localAudio: saved.audio), store: store)
            } else {
                guard request.anime.moduleID != nil || store.state.preferences.animexEnabled else { throw KairoError.message("Enable Animex to stream the next episode, or download its selected language first.") }
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
                guard request.anime.moduleID != nil || store.state.preferences.animexEnabled else { throw KairoError.message("Enable Animex to check this language online.") }
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
    let nativeControls: Bool
    let fill: Bool
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
        view.showsPlaybackControls = nativeControls
        view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
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
        uiViewController.showsPlaybackControls = nativeControls
        uiViewController.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        context.coordinator.onTap = onTap
    }
}

struct PlayerAirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .white
        return view
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) { }
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
    @State private var timeObserver: Any?
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var scrubbing = false
    @State private var isPlaying = false
    @State private var fillVideo = false
    @State private var nativeControls = false
    @State private var speed = 1.0
    private var current: PlaybackRequest { controller.active ?? request }
    private var hasNext: Bool {
        let next = current.anime.moduleEpisodes?.first(where: { $0.number > current.episode })?.number ?? current.episode + 1
        return current.anime.episodeCount.map { next <= $0 } ?? false
    }
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            NativePlayer(player: controller.player, nativeControls: nativeControls, fill: fillVideo, onTap: toggleControls)
                .ignoresSafeArea()
            if controller.isPreparing {
                Color.black.ignoresSafeArea().onTapGesture(perform: toggleControls)
                ProgressView("Preparing episode…").tint(.white).foregroundStyle(.white)
            }
            if !nativeControls && controlsVisible && !controller.isPreparing && controller.error == nil {
                customControls.transition(.opacity)
            }
            if let prompt = controller.skipPrompt, !controller.isPreparing {
                VStack { Spacer(); HStack { Spacer(); Button(prompt.label) { controller.skipNow() }
                    .buttonStyle(.borderedProminent).padding(24) } }
            }
            if let error = controller.error {
                VStack(spacing: 16) {
                    Image(systemName: "exclamationmark.play").font(.largeTitle)
                    Text(error).multilineTextAlignment(.center)
                    Button("Choose another provider") { dismiss() }.buttonStyle(.borderedProminent)
                }.padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22)).padding()
            }
        }
        .overlay(alignment: .top) { if controlsVisible { topControls.transition(.opacity) } }
        .animation(.easeInOut(duration: 0.22), value: controlsVisible)
        .preferredColorScheme(.dark)
        .task { controller.autoSkip = autoSkipIntro; await controller.open(request, store: store) }
        .onAppear { startObserving() }
        .alert("Audio unavailable", isPresented: Binding(get: { controller.audioNotice != nil }, set: { if !$0 { controller.audioNotice = nil } })) {
            Button("OK", role: .cancel) { controller.audioNotice = nil }
        } message: { Text(controller.audioNotice ?? "") }
        .onChange(of: controller.isPreparing) { _, preparing in
            if preparing { hideControlsTask?.cancel(); controlsVisible = true; position = 0; duration = 0 }
            else { isPlaying = true; scheduleHideControls() }
        }
        .onChange(of: autoSkipIntro) { _, enabled in controller.autoSkip = enabled }
        .onChange(of: scenePhase) { _, phase in if phase != .active { controller.saveProgress() } }
        .onDisappear {
            transitionTask?.cancel(); hideControlsTask?.cancel()
            if let timeObserver { controller.player.removeTimeObserver(timeObserver); self.timeObserver = nil }
            controller.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: .AVPlayerItemDidPlayToEndTime)) { notification in
            guard let item = notification.object as? AVPlayerItem, item === controller.player.currentItem else { return }
            controller.saveProgress(finished: true)
            isPlaying = false
            if autoPlayNext { playNext() }
        }
    }
    private var topControls: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: { Image(systemName: "xmark")
                .font(.subheadline.bold()).frame(width: 40, height: 40)
                .background(.black.opacity(0.65), in: Circle()) }
                .accessibilityLabel("Close player")
            Spacer(minLength: 8)
            if nativeControls {
                Button("Kairo controls") { nativeControls = false; scheduleHideControls() }
                    .font(.caption.weight(.semibold)).padding(10).background(.black.opacity(0.65), in: Capsule())
            } else {
                PlayerAirPlayButton().frame(width: 40, height: 40)
                    .background(.black.opacity(0.65), in: Circle())
                    .accessibilityLabel("AirPlay")
                Menu {
                    ForEach(AudioChoice.allCases) { choice in
                        Button {
                            transitionTask?.cancel()
                            transitionTask = Task { await controller.switchAudio(to: choice, store: store) }
                        } label: {
                            if current.audio == choice { Label(choice.label, systemImage: "checkmark") }
                            else { Text(choice.label) }
                        }
                    }
                } label: {
                    Text(controller.isSwitchingAudio ? "Checking…" : (current.audio ?? store.state.preferences.audio).shortLabel)
                        .font(.caption.bold()).frame(minWidth: 40, minHeight: 40)
                        .background(.black.opacity(0.65), in: Capsule())
                }.disabled(controller.isPreparing || controller.isSwitchingAudio)
                    .accessibilityLabel("Sub or Dub audio")
                Menu {
                    Toggle("Auto-play next episode", isOn: $autoPlayNext)
                    Toggle("Auto-skip intro and recap", isOn: $autoSkipIntro)
                    Button("iOS controls (Picture in Picture and subtitles)") { nativeControls = true }
                } label: {
                    Image(systemName: "gearshape.fill").font(.subheadline.bold())
                        .frame(width: 40, height: 40).background(.black.opacity(0.65), in: Circle())
                }.accessibilityLabel("Playback settings")
            }
        }.foregroundStyle(.white).padding()
    }
    private var customControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 38) {
                controlButton("gobackward.10", label: "Back 10 seconds") { seek(position - 10) }
                controlButton(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play") {
                    if isPlaying { controller.player.pause() }
                    else { controller.player.play(); controller.player.rate = Float(speed) }
                    isPlaying.toggle()
                }.font(.system(size: 30, weight: .semibold))
                controlButton("goforward.10", label: "Forward 10 seconds") { seek(position + 10) }
            }.padding(16).background(.black.opacity(0.4), in: Capsule())
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("EPISODE \(current.episode)").font(.caption2.bold()).tracking(1.2).foregroundStyle(.white.opacity(0.7))
                Text(current.anime.title).font(.headline).lineLimit(1)
                HStack(spacing: 12) {
                    Button { seek(position + 85) } label: { Label("85s", systemImage: "goforward") }
                        .accessibilityLabel("Forward 85 seconds")
                    Spacer()
                    Button { fillVideo.toggle() } label: {
                        Image(systemName: fillVideo ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }.accessibilityLabel(fillVideo ? "Fit video" : "Fill screen")
                    Menu {
                        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { value in
                            Button(value == 1 ? "Normal" : "\(value.formatted())×") {
                                speed = value
                                if isPlaying { controller.player.rate = Float(value) }
                            }
                        }
                    } label: { Text("\(speed.formatted())×") }.accessibilityLabel("Playback speed")
                    if hasNext {
                        Button { playNext() } label: { Image(systemName: "forward.end.fill") }
                            .accessibilityLabel("Play next episode")
                    }
                }.font(.subheadline.weight(.semibold))
                HStack(spacing: 8) {
                    Text(timestamp(position)).monospacedDigit()
                    Slider(value: $position, in: 0...max(duration, 1), onEditingChanged: { editing in
                        scrubbing = editing
                        if !editing { seek(position) }
                        else { hideControlsTask?.cancel() }
                    }).tint(Theme.purple)
                        .accessibilityLabel("Playback position")
                    Text(timestamp(duration)).monospacedDigit()
                }.font(.caption2)
            }
            .padding(18)
            .background(LinearGradient(colors: [.clear, .black.opacity(0.88)], startPoint: .top, endPoint: .bottom))
        }.foregroundStyle(.white)
    }
    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 24, weight: .semibold))
            .frame(width: 48, height: 48) }
            .buttonStyle(.plain).accessibilityLabel(label)
    }
    private func startObserving() {
        guard timeObserver == nil else { return }
        timeObserver = controller.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { _ in
            let seconds = controller.player.currentTime().seconds
            let length = controller.player.currentItem?.duration.seconds ?? 0
            if !scrubbing, seconds.isFinite { position = max(0, seconds) }
            if length.isFinite, length > 0 { duration = length }
            if !controller.isPreparing { isPlaying = controller.player.rate > 0 }
        }
    }
    private func seek(_ seconds: Double) {
        let target = min(max(0, seconds), max(duration, 0))
        controller.player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        position = target
        scheduleHideControls()
    }
    private func playNext() {
        transitionTask?.cancel()
        transitionTask = Task { await controller.playNext(store: store) }
    }
    private func timestamp(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let value = Int(min(seconds, 359999))
        return String(format: "%d:%02d", value / 60, value % 60)
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
            if !Task.isCancelled && !scrubbing { controlsVisible = false }
        }
    }
}
