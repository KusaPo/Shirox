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
    private var nextStreamTask: Task<[StreamOption]?, Never>?
    private var nextStreamKey: String?
    @Published private(set) var active: PlaybackRequest?
    @Published var audioNotice: String?
    @Published private(set) var isSwitchingAudio = false
    @Published private(set) var subtitleChoices: [SubtitleChoice] = []
    @Published private(set) var subtitleSelection: String?
    @Published private(set) var subtitleText = ""
    @Published private(set) var subtitlesLoading = false
    @Published private(set) var subtitleStatus: String?
    @Published var subtitleNotice: String?
    private var subtitleDiscoveryTask: Task<Void, Never>?
    private var subtitleLoadTask: Task<Void, Never>?
    private var subtitleTimeToken: Any?
    private var subtitleGroup: AVMediaSelectionGroup?
    private var nativeSubtitleOptions: [String: AVMediaSelectionOption] = [:]
    private var externalSubtitleTracks: [String: SubtitleTrack] = [:]
    private var subtitleDocuments: [String: SubtitleDocument] = [:]
    private var subtitleCues: [SubtitleCue] = []
    var burnedInSubtitles: Bool {
        guard let active else { return false }
        if let stream = active.stream { return stream.burnedInSubtitles }
        guard active.anime.moduleID == ReAnimeAPI.moduleID, let audio = active.audio else { return false }
        return store?.readyDownload(active.anime, episode: active.episode, audio: audio)?.provider?.lowercased().hasPrefix("hsub") == true
    }
    private var lastProgressSave = Date.distantPast
    private weak var store: AppStore?

    @MainActor func open(_ request: PlaybackRequest, store: AppStore, resumeAt: Double? = nil) async {
        saveProgress()
        resetSubtitles()
        isPreparing = true
        error = nil
        skipPrompt = nil
        intervals = []
        skipped = []
        nextStreamTask?.cancel(); nextStreamTask = nil; nextStreamKey = nil
        if let timeToken { player.removeTimeObserver(timeToken); self.timeToken = nil }
        observation = nil
        self.store = store
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
            try AVAudioSession.sharedInstance().setActive(true)
            guard let url = request.localURL ?? request.stream?.url else { throw KairoError.message("The player has no media URL.") }
            if request.localURL != nil, !FileManager.default.fileExists(atPath: url.path) { throw KairoError.message("This downloaded file is no longer on the device.") }
            let headers = request.localURL == nil ? request.stream?.headers ?? [:] : [:]
            let playbackURL: URL
            if request.localURL == nil, let media = request.stream?.reanimeMedia {
                playbackURL = try await ReAnimePlaybackServer.shared.playbackURL(media)
            } else { playbackURL = try await OfflineHLSServer.shared.playbackURL(for: url) }
            let asset = AVURLAsset(url: playbackURL, options: headers.isEmpty ? nil : ["AVURLAssetHTTPHeaderFieldsKey": headers])
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
            try Task.checkCancellation()
            observation = item.observe(\.status, options: [.new]) { [weak self] item, _ in
                if item.status == .failed {
                    DispatchQueue.main.async { self?.error = "Playback failed. \(item.error?.localizedDescription ?? "Try another provider.")" }
                }
            }
            player.replaceCurrentItem(with: item)
            subtitleDiscoveryTask = Task { @MainActor [weak self] in await self?.configureSubtitles(request, item: item) }
            subtitleTimeToken = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.1, preferredTimescale: 600), queue: .main) { [weak self] _ in self?.updateSubtitleText() }

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
                self?.prefetchNextIfNeeded()
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

    private func resetSubtitles() {
        subtitleDiscoveryTask?.cancel(); subtitleDiscoveryTask = nil
        subtitleLoadTask?.cancel(); subtitleLoadTask = nil
        if let subtitleTimeToken { player.removeTimeObserver(subtitleTimeToken); self.subtitleTimeToken = nil }
        subtitleChoices = []; subtitleSelection = nil; subtitleText = ""; subtitleCues = []
        subtitleGroup = nil; nativeSubtitleOptions = [:]; externalSubtitleTracks = [:]; subtitleDocuments = [:]
        subtitleStatus = nil; subtitleNotice = nil; subtitlesLoading = false
    }
    @MainActor private func configureSubtitles(_ request: PlaybackRequest, item: AVPlayerItem) async {
        subtitlesLoading = true
        let group = try? await item.asset.loadMediaSelectionGroup(for: .legible)
        guard !Task.isCancelled, active?.id == request.id, player.currentItem === item else { return }
        subtitleGroup = group
        nativeSubtitleOptions = [:]; externalSubtitleTracks = [:]
        if let group {
            for (index, option) in group.options.enumerated() { nativeSubtitleOptions["native-\(index)"] = option }
            item.select(nil, in: group)
        }
        var tracks = request.stream?.reanimeMedia?.subtitles ?? []
        if let local = request.localURL {
            let saved = SubtitleService.saved(at: local)
            for document in saved { subtitleDocuments[document.track.id] = document }
            tracks = saved.map(\.track)
            if tracks.isEmpty, request.anime.moduleID == ReAnimeAPI.moduleID, !burnedInSubtitles {
                do { tracks = try await ReAnimeAPI.shared.subtitleTracks(request.anime, episode: request.episode) }
                catch { subtitleStatus = "Captions were not saved with this download. Connect to load them once." }
            }
        }
        guard !Task.isCancelled, active?.id == request.id, player.currentItem === item else { return }
        var seen = Set<String>()
        tracks = tracks.filter { seen.insert($0.id).inserted }
        for track in tracks { externalSubtitleTracks[track.id] = track }
        subtitleChoices = nativeSubtitleOptions.keys.sorted().compactMap { id in nativeSubtitleOptions[id].map { SubtitleChoice(id: id, label: $0.displayName) } }
            + tracks.filter { externalSubtitleTracks[$0.id] != nil }.map { SubtitleChoice(id: $0.id, label: $0.label) }
        subtitlesLoading = false
        if subtitleChoices.isEmpty, subtitleStatus == nil { subtitleStatus = burnedInSubtitles ? "These captions are burned into the video. Choose HD-1 or HD-2 for an on/off toggle." : "This source provided no subtitle tracks." }
        let enabled = UserDefaults.standard.object(forKey: "playerSubtitlesEnabled") == nil ? request.audio == .sub : UserDefaults.standard.bool(forKey: "playerSubtitlesEnabled")
        guard enabled, !burnedInSubtitles else { return }
        let previous = UserDefaults.standard.string(forKey: "playerSubtitleTrack")
        let choice = subtitleChoices.first { $0.label == previous }
            ?? SubtitleService.preferred(tracks).flatMap { preferred in subtitleChoices.first { $0.id == preferred.id } }
            ?? subtitleChoices.first { nativeSubtitleOptions[$0.id]?.extendedLanguageTag?.hasPrefix("en") == true }
            ?? subtitleChoices.first
        selectSubtitle(choice?.id, persist: false)
    }
    @MainActor func reloadSubtitles() {
        guard let request = active, let item = player.currentItem else { return }
        subtitleDiscoveryTask?.cancel()
        subtitleDiscoveryTask = Task { [weak self] in await self?.configureSubtitles(request, item: item) }
    }
    @MainActor func selectSubtitle(_ id: String?, persist: Bool = true) {
        subtitleLoadTask?.cancel(); subtitleLoadTask = nil
        subtitleCues = []; subtitleText = ""; subtitleSelection = id; subtitleNotice = nil; subtitlesLoading = false
        if let group = subtitleGroup { player.currentItem?.select(nil, in: group) }
        if persist {
            UserDefaults.standard.set(id != nil, forKey: "playerSubtitlesEnabled")
            if let choice = subtitleChoices.first(where: { $0.id == id }) { UserDefaults.standard.set(choice.label, forKey: "playerSubtitleTrack") }
        }
        guard let id else { subtitlesLoading = false; return }
        if let option = nativeSubtitleOptions[id], let group = subtitleGroup { player.currentItem?.select(option, in: group); return }
        guard let track = externalSubtitleTracks[id], let request = active else { return }
        if let cached = subtitleDocuments[id] { subtitleCues = cached.cues; updateSubtitleText(); return }
        subtitlesLoading = true
        subtitleLoadTask = Task { @MainActor [weak self] in
            do {
                let document = try await SubtitleService.shared.document(track)
                try Task.checkCancellation()
                guard let self, self.active?.id == request.id, self.subtitleSelection == id else { return }
                self.subtitleDocuments[id] = document; self.subtitleCues = document.cues; self.subtitlesLoading = false
                self.updateSubtitleText()
                if let local = request.localURL { try? SubtitleService.save(document, beside: local) }
            } catch is CancellationError { }
            catch {
                guard let self, self.active?.id == request.id, self.subtitleSelection == id else { return }
                self.subtitlesLoading = false; self.subtitleSelection = nil; self.subtitleNotice = error.localizedDescription
            }
        }
    }
    private func updateSubtitleText() {
        let text = SubtitleParser.text(at: player.currentTime().seconds, cues: subtitleCues)
        if text != subtitleText { subtitleText = text }
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
    private func prefetchNextIfNeeded() {
        guard let active, active.localURL == nil, let store, !isPreparing,
              let duration = player.currentItem?.duration.seconds, duration.isFinite, duration > 0,
              player.currentTime().seconds >= duration * 0.8 else { return }
        let episode = active.anime.moduleEpisodes?.first(where: { $0.number > active.episode })?.number ?? active.episode + 1
        guard active.anime.episodeCount.map({ episode <= $0 }) ?? false else { return }
        let audio = active.audio ?? store.state.preferences.audio
        guard store.readyDownload(active.anime, episode: episode, audio: audio) == nil else { return }
        let key = "\(active.anime.id)|\(episode)|\(audio.rawValue)"
        guard nextStreamKey != key else { return }
        nextStreamKey = key
        let anime = active.anime
        nextStreamTask = Task {
            try? await CatalogAPI.shared.streams(anime, episode: episode, audio: audio)
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
                let key = "\(request.anime.id)|\(episode)|\(audio.rawValue)"
                let cached = key == nextStreamKey ? await nextStreamTask?.value : nil
                let options: [StreamOption]
                if let cached { options = cached }
                else { options = try await CatalogAPI.shared.streams(request.anime, episode: episode, audio: audio) }
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
        resetSubtitles()
        saveProgress()
        nextStreamTask?.cancel(); nextStreamTask = nil; nextStreamKey = nil
        player.pause()
        if let timeToken { player.removeTimeObserver(timeToken); self.timeToken = nil }
        observation = nil
        player.replaceCurrentItem(with: nil)
        active = nil
    }
}

final class CaptionPlayerViewController: AVPlayerViewController {
    private let caption = UILabel()
    private var subtitleBackground = true
    private var subtitleScale = 1.0
    private weak var styledItem: AVPlayerItem?

    func setSubtitleAppearance(background: Bool, scale: Double) {
        loadViewIfNeeded()
        let scale = scale.isFinite ? min(2, max(0.5, scale)) : 1
        let changed = subtitleBackground != background || subtitleScale != scale
        if changed {
            subtitleBackground = background; subtitleScale = scale
            caption.backgroundColor = background ? UIColor.black.withAlphaComponent(0.65) : .clear
            caption.shadowColor = background ? nil : .black
            caption.shadowOffset = CGSize(width: 1, height: 1)
            view.setNeedsLayout()
        }
        if let item = player?.currentItem, changed || styledItem !== item {
            // Apply the same preferences to embedded text subtitle tracks.
            let color: [CGFloat] = [background ? 0.65 : 0, 0, 0, 0]
            if let rule = AVTextStyleRule(textMarkupAttributes: [
                kCMTextMarkupAttribute_BackgroundColorARGB as String: color,
                kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: color,
                kCMTextMarkupAttribute_RelativeFontSize as String: scale * 100
            ]) { item.textStyleRules = [rule] }
            styledItem = item
        }
    }
    override func viewDidLoad() {
        super.viewDidLoad()
        caption.textColor = .white; caption.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        caption.textAlignment = .center; caption.numberOfLines = 0
        caption.font = .systemFont(ofSize: 22, weight: .medium)
        caption.layer.cornerRadius = 5; caption.layer.masksToBounds = true
        caption.isHidden = true; caption.isUserInteractionEnabled = false
        attachCaption()
    }
    private func attachCaption() {
        if let overlay = contentOverlayView, caption.superview !== overlay { overlay.addSubview(caption) }
    }
    func setCaption(_ text: String) {
        loadViewIfNeeded()
        attachCaption()
        guard caption.text != text else { return }
        caption.text = text; caption.isHidden = text.isEmpty
        view.setNeedsLayout()
    }
    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        attachCaption()
        guard let overlay = contentOverlayView else { return }
        let rect = videoBounds.isEmpty ? overlay.bounds : overlay.convert(videoBounds, from: view)
        let width = max(1, min(overlay.bounds.width - 32, rect.width - 24))
        caption.font = .systemFont(ofSize: min(26, max(18, rect.width / 25)) * CGFloat(subtitleScale), weight: .medium)
        let maxHeight = max(1, rect.height - 48)
        let height = min(maxHeight, caption.sizeThatFits(CGSize(width: max(1, width - 12), height: .greatestFiniteMagnitude)).height + 10)
        caption.frame = CGRect(x: rect.midX - width / 2, y: max(rect.minY, rect.maxY - height - 24), width: width, height: height)
    }
}

struct NativePlayer: UIViewControllerRepresentable {
    let player: AVPlayer
    let nativeControls: Bool
    let subtitleText: String
    var subtitleBackground = true
    var subtitleScale = 1.0
    let fill: Bool
    let onTap: () -> Void
    let onDoubleTap: (Bool) -> Void
    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onTap: () -> Void
        var onDoubleTap: (Bool) -> Void
        init(onTap: @escaping () -> Void, onDoubleTap: @escaping (Bool) -> Void) {
            self.onTap = onTap; self.onDoubleTap = onDoubleTap
        }
        @objc func didTap() { onTap() }
        @objc func didDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let view = recognizer.view else { return }
            onDoubleTap(recognizer.location(in: view).x < view.bounds.midX)
        }
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool { true }
    }
    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap, onDoubleTap: onDoubleTap) }
    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let view = CaptionPlayerViewController()
        view.setCaption(subtitleText)
        view.player = player
        view.setSubtitleAppearance(background: subtitleBackground, scale: subtitleScale)
        view.showsPlaybackControls = nativeControls
        view.videoGravity = fill ? .resizeAspectFill : .resizeAspect
        view.allowsPictureInPicturePlayback = true
        view.canStartPictureInPictureAutomaticallyFromInline = true
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didTap))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.didDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        doubleTap.cancelsTouchesInView = false
        doubleTap.delegate = context.coordinator
        tap.require(toFail: doubleTap)
        tap.cancelsTouchesInView = false
        tap.delegate = context.coordinator
        view.view.addGestureRecognizer(tap)
        view.view.addGestureRecognizer(doubleTap)
        return view
    }
    static func configure(_ view: AVPlayerViewController, player: AVPlayer, nativeControls: Bool, fill: Bool, subtitleText: String, subtitleBackground: Bool = true, subtitleScale: Double = 1) {
        (view as? CaptionPlayerViewController)?.setCaption(subtitleText)
        // Time/progress/caption updates must not reconfigure the audio player.
        if view.player !== player { view.player = player }
        (view as? CaptionPlayerViewController)?.setSubtitleAppearance(background: subtitleBackground, scale: subtitleScale)
        if view.showsPlaybackControls != nativeControls { view.showsPlaybackControls = nativeControls }
        let gravity: AVLayerVideoGravity = fill ? .resizeAspectFill : .resizeAspect
        if view.videoGravity != gravity { view.videoGravity = gravity }
    }
    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        Self.configure(uiViewController, player: player, nativeControls: nativeControls, fill: fill, subtitleText: subtitleText, subtitleBackground: subtitleBackground, subtitleScale: subtitleScale)
        context.coordinator.onTap = onTap
        context.coordinator.onDoubleTap = onDoubleTap
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
    @AppStorage("playerFillVideo") private var fillVideo = false
    @AppStorage("playerSeekShort") private var shortSeek = 10
    @AppStorage("playerSeekLong") private var longSeek = 85
    @AppStorage("playerSubtitleBackground") private var subtitleBackground = true
    @AppStorage("playerSubtitleScale") private var subtitleScale = 1.0
    @State private var showingSubtitleAppearance = false
    @State private var transitionTask: Task<Void, Never>?
    @State private var controlsVisible = true
    @State private var hideControlsTask: Task<Void, Never>?
    @State private var timeObserver: Any?
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var scrubbing = false
    @State private var isPlaying = false
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
            NativePlayer(player: controller.player, nativeControls: nativeControls, subtitleText: controller.subtitleText, subtitleBackground: subtitleBackground, subtitleScale: subtitleScale, fill: fillVideo,
                onTap: toggleControls, onDoubleTap: { left in
                    guard !nativeControls, !controller.isPreparing else { return }
                    seek(position + Double(left ? -shortSeek : shortSeek))
                })
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
        .sheet(isPresented: $showingSubtitleAppearance, onDismiss: { scheduleHideControls() }) {
            subtitleAppearance
                .presentationDetents([.medium, .large])
                .preferredColorScheme(.dark)
        }
        .preferredColorScheme(.dark)
        .task { controller.autoSkip = autoSkipIntro; await controller.open(request, store: store) }
        .onAppear { startObserving() }
        .alert("Audio unavailable", isPresented: Binding(get: { controller.audioNotice != nil }, set: { if !$0 { controller.audioNotice = nil } })) {
            Button("OK", role: .cancel) { controller.audioNotice = nil }
        } message: { Text(controller.audioNotice ?? "") }
        .alert("Subtitles unavailable", isPresented: Binding(get: { controller.subtitleNotice != nil }, set: { if !$0 { controller.subtitleNotice = nil } })) {
            Button("OK", role: .cancel) { controller.subtitleNotice = nil }
        } message: { Text(controller.subtitleNotice ?? "") }
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
            Menu {
                if controller.burnedInSubtitles {
                    Text("This video has burned-in captions. Choose HD-1 or HD-2 for toggleable subtitles.")
                }
                Button { controller.selectSubtitle(nil) } label: {
                    if controller.subtitleSelection == nil { Label(controller.burnedInSubtitles ? "Off (separate captions)" : "Off", systemImage: "checkmark") } else { Text(controller.burnedInSubtitles ? "Off (separate captions)" : "Off") }
                }
                ForEach(controller.subtitleChoices) { choice in
                    Button { controller.selectSubtitle(choice.id) } label: {
                        if controller.subtitleSelection == choice.id { Label(choice.label, systemImage: "checkmark") } else { Text(choice.label) }
                    }
                }
                Divider()
                Button("Subtitle appearance…") {
                    hideControlsTask?.cancel()
                    showingSubtitleAppearance = true
                }
                if controller.subtitlesLoading { Text("Loading subtitles…") }
                if let status = controller.subtitleStatus {
                    Text(status)
                    Button("Retry loading subtitles") { controller.reloadSubtitles() }
                }
            } label: {
                Image(systemName: controller.subtitleSelection == nil ? "captions.bubble" : "captions.bubble.fill")
                    .font(.subheadline.bold()).frame(width: 40, height: 40).background(.black.opacity(0.65), in: Circle())
            }.accessibilityLabel("Subtitles")
                .accessibilityValue(controller.subtitleChoices.first { $0.id == controller.subtitleSelection }?.label ?? "Off")
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
    private var subtitleAppearance: some View {
        NavigationStack {
            Form {
                Section("Preview") {
                    Text("This is how your subtitles will look.")
                        .font(.system(size: 22 * min(2, max(0.5, subtitleScale)), weight: .medium))
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .shadow(color: subtitleBackground ? .clear : .black, radius: 1, x: 1, y: 1)
                        .padding(8)
                        .background(subtitleBackground ? Color.black.opacity(0.65) : .clear, in: RoundedRectangle(cornerRadius: 5))
                        .frame(maxWidth: .infinity, minHeight: 90)
                        .listRowBackground(Color.gray.opacity(0.3))
                }
                Section {
                    Toggle("Subtitle background", isOn: $subtitleBackground)
                    HStack {
                        Text("Text size")
                        Spacer()
                        Text("\(Int((subtitleScale * 100).rounded()))%")
                            .foregroundStyle(.secondary).monospacedDigit()
                    }
                    Slider(value: $subtitleScale, in: 0.5...2, step: 0.05)
                        .accessibilityLabel("Subtitle text size")
                        .accessibilityValue("\(Int((subtitleScale * 100).rounded())) percent")
                    Button("Reset appearance") { subtitleBackground = true; subtitleScale = 1 }
                } footer: {
                    Text("Changes apply immediately and are saved for future episodes. Captions baked into the video cannot be restyled.")
                }
            }
            .navigationTitle("Subtitle appearance")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) {
                Button("Done") { showingSubtitleAppearance = false }
            } }
        }
    }
    private var customControls: some View {
        VStack {
            Spacer()
            HStack(spacing: 38) {
                controlButton("gobackward.10", label: "Back \(shortSeek) seconds") { seek(position - Double(shortSeek)) }
                controlButton(isPlaying ? "pause.fill" : "play.fill", label: isPlaying ? "Pause" : "Play") {
                    if isPlaying { controller.player.pause() }
                    else { controller.player.play(); controller.player.rate = Float(speed) }
                    isPlaying.toggle()
                }.font(.system(size: 30, weight: .semibold))
                controlButton("goforward.10", label: "Forward \(shortSeek) seconds") { seek(position + Double(shortSeek)) }
            }.padding(16).background(.black.opacity(0.4), in: Capsule())
            Spacer()
            VStack(alignment: .leading, spacing: 10) {
                Text("EPISODE \(current.episode)").font(.caption2.bold()).tracking(1.2).foregroundStyle(.white.opacity(0.7))
                Text(current.anime.title).font(.headline).lineLimit(1)
                HStack(spacing: 12) {
                    Button { seek(position + Double(longSeek)) } label: { Label("\(longSeek)s", systemImage: "goforward") }
                        .accessibilityLabel("Forward \(longSeek) seconds")
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
            if !Task.isCancelled && !scrubbing && !showingSubtitleAppearance { controlsVisible = false }
        }
    }
}
