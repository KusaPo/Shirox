import Foundation
import Combine

final class AppStore: ObservableObject {
    @Published var state = SavedState()
    @Published var storageError: String?
    private let file: URL
    private var canWrite = true

    init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Kairo", isDirectory: true)
        file = folder.appendingPathComponent("state.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                state = try JSONDecoder().decode(SavedState.self, from: Data(contentsOf: file))
            }
        } catch {
            canWrite = false // Never overwrite an unreadable existing library with an empty one.
            storageError = "Your saved library could not be opened. Existing data was preserved. \(error.localizedDescription)"
        }
    }

    func save() {
        guard canWrite else { return }
        do {
            let data = try JSONEncoder().encode(state)
            try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { storageError = "Changes could not be saved: \(error.localizedDescription)" }
    }

    func toggleSaved(_ anime: Anime) {
        if state.library.contains(where: { $0.id == anime.id }) { state.library.removeAll { $0.id == anime.id } }
        else { state.library.append(anime) }
        save()
    }

    func record(_ anime: Anime, episode: Int, seconds: Double, duration: Double, finished: Bool = false) {
        guard seconds.isFinite, duration.isFinite, duration > 0 else { return }
        let entry = WatchProgress(anime: anime, episode: episode, seconds: max(0, seconds), duration: duration, finished: finished)
        state.progress.removeAll { $0.id == entry.id }
        state.progress.append(entry)
        if !state.library.contains(where: { $0.id == anime.id }) { state.library.append(anime) }
        save()
    }

    func progress(_ anime: Anime, episode: Int) -> WatchProgress? {
        state.progress.first { $0.id == WatchProgress.key(anime.id, episode) }
    }

    var continuing: [WatchProgress] {
        var seen = Set<String>()
        return state.progress.sorted { $0.updated > $1.updated }.filter {
            guard seen.insert($0.anime.id).inserted else { return false }
            return !$0.finished && $0.seconds > 0
        }
    }

    func updateDownload(_ id: UUID, _ change: (inout DownloadRecord) -> Void) {
        guard let index = state.downloads.firstIndex(where: { $0.id == id }) else { return }
        change(&state.downloads[index])
        save()
    }
}
