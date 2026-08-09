import Foundation
import MusicKit

// MARK: - Track Model (Apple catalog)
struct Track: Codable, Hashable, Identifiable {
    let id: String
    let name: String
    let artistName: String
    let albumName: String
    let albumId: String?
    let artworkUrl: String?
    let releaseDate: String? // "YYYY-MM-DD" or ISO
    let previewUrl: String?  // ~30s audio preview
    let externalUrl: String? // Apple Music page
    let genreName: String?
    var tier: MusicService.Tier = .medium

    var releaseYear: Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }
}

// MARK: - Music Service
// Discovery + previews from Apple's catalog. Replaces the removed Spotify APIs.
// Two backends sharing the same catalog and genre IDs:
//  - MusicKit (preferred): Apple's supported framework, automatic developer
//    token, documented rate limits, storefront follows the device region.
//    Requires the MusicKit app service to be enabled for this App ID in the
//    developer portal; until then every request 401s and we fall back.
//  - iTunes Search/RSS (itunes.apple.com), keyless fallback. Rate-limited
//    (~20 req/min); the per-game queue build stays well under it.
// Catalog-only: no Apple Music subscription needed, but MusicKit requires the
// one-time MusicAuthorization prompt (it refuses even catalog requests while
// status is .notDetermined). Declining just means the iTunes fallback serves.
final class MusicService {
    static let shared = MusicService()

    enum Tier: String, Codable {
        case easy, medium, hard
    }

    private let storefront = "us" // iTunes fallback only; MusicKit picks its own
    private var musicKitDown = false

    private var chartCache: [String: [Track]] = [:]
    private var albumCache: [String: [Track]] = [:]
    private var searchCache: [String: [Track]] = [:]
    private var playedTrackIDs: Set<String> = []
    // Songs heard in ANY game this session (by title+artist, so remasters and
    // re-releases count as the same song). Keeps "Play Again" fresh.
    private var sessionPlayedSongs: Set<String> = []

    // Apple genre IDs are shared between the Apple Music API and iTunes.
    // Keys match GameSetupView's availableGenres.
    static let genreIDs: [String: Int] = [
        "Pop": 14,
        "Rock": 21,
        "Hip-Hop": 18,
        "Country": 6,
        "R&B": 15,
        "Electronic": 7,
        "Jazz": 11,
        "Classical": 5,
        "Indie": 20,        // Apple has no Indie genre; Alternative is the closest
        "Alternative": 20,
    ]

    // Terms accepted when matching a catalog genre label against a selection.
    private let genreMatchers: [String: [String]] = [
        "Hip-Hop": ["hip-hop", "hip hop", "rap"],
        "R&B": ["r&b", "soul"],
        "Indie": ["indie", "alternative", "singer/songwriter"],
        "Alternative": ["alternative", "indie"],
        "Electronic": ["electronic", "dance"],
    ]

    private let easyChartCutoff = 40
    private let deepCutSources = 6
    private let deepCutsPerAlbum = 2

    // MARK: - Public API

    /// Builds a shuffled game queue for the selected filters. Only tracks with
    /// a playable preview are returned.
    func loadTracks(genres: [String], decades: [String], difficulty: Difficulty) async throws -> [Track] {
        playedTrackIDs.removeAll()
        await ensureMusicKitAuthorization()

        let genreList = genres.filter { Self.genreIDs[$0] != nil }
        // No genres selected = all music: the overall charts (genre nil).
        let genreKeys: [String?] = genreList.isEmpty ? [nil] : genreList

        var pool: [Track] = []
        for genre in genreKeys {
            let chart = await chartTracks(genre: genre)
            let chartInDecades = filterByDecades(chart, decades: decades)
            pool += chartInDecades.filter { wantedTiers(for: difficulty).contains($0.tier) }

            if difficulty == .hard {
                let cuts = await deepCuts(from: chart)
                pool += filterByDecades(cuts, decades: decades)
            }

            // Charts skew recent, so decades need their own search pass.
            for decade in decades {
                let found = await decadeTracks(decade: decade, genre: genre)
                pool += found.filter { wantedTiers(for: difficulty).contains($0.tier) }
            }
        }

        var queue = dedupeSongs(pool).filter { $0.previewUrl != nil }

        // Prefer songs not heard in any game this session; only fall back to
        // repeats if that would leave too small a queue.
        let fresh = queue.filter { !sessionPlayedSongs.contains(songKey($0)) }
        if fresh.count >= 15 {
            queue = fresh
        }

        queue.shuffle()
        print("[MusicService] Built queue of \(queue.count) tracks (\(fresh.count) unheard) for genres=\(genreList.isEmpty ? ["All"] : genreList) decades=\(decades) difficulty=\(difficulty.rawValue)")
        return Array(queue.prefix(150))
    }

    func markTrackAsPlayed(_ track: Track) {
        playedTrackIDs.insert(track.id)
        sessionPlayedSongs.insert(songKey(track))
    }

    func shouldSkipTrack(_ track: Track) -> Bool {
        playedTrackIDs.contains(track.id)
    }

    // MARK: - Tiering

    private func wantedTiers(for difficulty: Difficulty) -> Set<Tier> {
        switch difficulty {
        case .easy: return [.easy]
        case .medium: return [.easy, .medium]
        case .hard: return [.medium, .hard]
        }
    }

    private func filterByDecades(_ tracks: [Track], decades: [String]) -> [Track] {
        guard !decades.isEmpty else { return tracks }
        let ranges = decades.compactMap { Self.yearRange(for: $0) }
        return tracks.filter { track in
            guard let year = track.releaseYear else { return false }
            return ranges.contains { year >= $0.0 && year <= $0.1 }
        }
    }

    static func yearRange(for decade: String) -> (Int, Int)? {
        guard decade.count == 5, let start = Int(decade.dropLast()) else { return nil }
        return (start, start + 9)
    }

    private func matchesGenre(label: String?, genre: String?) -> Bool {
        guard let genre else { return true } // "all music" — every genre matches
        guard let label = label?.lowercased() else { return false }
        let matchers = genreMatchers[genre] ?? [genre.lowercased()]
        return matchers.contains { label.contains($0) || $0.contains(label) }
    }

    // "Billie Jean", "Billie Jean (Remastered)" and "Billie Jean - Single" are
    // the same song; key on cleaned title + artist, not track ID.
    private func songKey(_ track: Track) -> String {
        var title = track.name.lowercased()
        for separator in [" (", " [", " - "] {
            if let range = title.range(of: separator) {
                title = String(title[..<range.lowerBound])
            }
        }
        return title.trimmingCharacters(in: .whitespaces) + "|" + track.artistName.lowercased()
    }

    private func dedupeSongs(_ tracks: [Track]) -> [Track] {
        var ids = Set<String>()
        var keys = Set<String>()
        return tracks.filter { ids.insert($0.id).inserted && keys.insert(songKey($0)).inserted }
    }

    // MARK: - Pool builders

    /// Top-of-chart tracks for a genre, tiered easy/medium by rank.
    private func chartTracks(genre: String?) async -> [Track] {
        let cacheKey = "chart:\(genre ?? "all")"
        if let cached = chartCache[cacheKey] { return cached }

        var tracks: [Track] = []
        if useMusicKit {
            do { tracks = try await musicKitChartTracks(genre: genre) }
            catch { demoteMusicKit(error) }
        }
        if tracks.isEmpty {
            do { tracks = try await itunesChartTracks(genre: genre) }
            catch { print("[MusicService] chart fetch failed for \(genre ?? "all"): \(error)") }
        }

        tracks = tracks.enumerated().map { index, track in
            var t = track
            t.tier = index < easyChartCutoff ? .easy : .medium
            return t
        }
        chartCache[cacheKey] = tracks
        return tracks
    }

    /// Album tracks that never charted, mined from chart artists — the 'hard' tier.
    private func deepCuts(from chart: [Track]) async -> [Track] {
        let chartIDs = Set(chart.map(\.id))
        let sources = chart.shuffled().prefix(deepCutSources)
        var cuts: [Track] = []
        for source in sources {
            guard let albumId = await albumId(for: source) else { continue }
            let albumTracks = await tracksForAlbum(albumId)
            let fresh = albumTracks.filter { $0.id != source.id && !chartIDs.contains($0.id) }
            for var cut in fresh.shuffled().prefix(deepCutsPerAlbum) {
                cut.tier = .hard
                cuts.append(cut)
            }
        }
        return cuts
    }

    /// Songs from a decade within a genre, tiered by search rank.
    private func decadeTracks(decade: String, genre: String?) async -> [Track] {
        let cacheKey = "decade:\(decade):\(genre ?? "all")"
        if let cached = searchCache[cacheKey] { return cached }

        let shorthand = decade.count == 5 ? String(decade.dropFirst(2)) : decade
        let term = "\(shorthand) \(genre ?? "hits")"

        var results: [Track] = []
        if useMusicKit {
            do { results = try await musicKitSearchTracks(term: term) }
            catch { demoteMusicKit(error) }
        }
        if results.isEmpty {
            do { results = try await itunesSearchTracks(term: term) }
            catch { print("[MusicService] decade search failed for \(term): \(error)") }
        }

        guard let range = Self.yearRange(for: decade) else { return [] }
        var filtered = results.filter { track in
            guard let year = track.releaseYear, year >= range.0, year <= range.1 else { return false }
            return matchesGenre(label: track.genreName, genre: genre)
        }
        filtered = filtered.enumerated().map { index, track in
            var t = track
            t.tier = index < 40 ? .easy : (index < 120 ? .medium : .hard)
            return t
        }
        searchCache[cacheKey] = filtered
        return filtered
    }

    private func tracksForAlbum(_ albumId: String) async -> [Track] {
        if let cached = albumCache[albumId] { return cached }
        var tracks: [Track] = []
        if useMusicKit {
            do { tracks = try await musicKitAlbumTracks(albumId: albumId) }
            catch { demoteMusicKit(error) }
        }
        if tracks.isEmpty {
            do { tracks = try await itunesAlbumTracks(albumId: albumId) }
            catch { print("[MusicService] album lookup failed for \(albumId): \(error)") }
        }
        albumCache[albumId] = tracks
        return tracks
    }

    /// MusicKit chart songs don't carry their album relationship inline;
    /// resolve it on demand (only needed when mining deep cuts for hard mode).
    private func albumId(for track: Track) async -> String? {
        if let albumId = track.albumId { return albumId }
        guard useMusicKit else { return nil }
        do { return try await musicKitAlbumId(forSongId: track.id) }
        catch { demoteMusicKit(error); return nil }
    }

    // MARK: - MusicKit backend

    // Authorization is re-checked per queue build (not latched), so granting
    // access later in Settings upgrades the next game without a relaunch.
    private var useMusicKit: Bool {
        !musicKitDown && MusicAuthorization.currentStatus == .authorized
    }

    /// Triggers the one-time system prompt. Any outcome other than .authorized
    /// simply leaves the iTunes fallback serving.
    private func ensureMusicKitAuthorization() async {
        guard !musicKitDown, MusicAuthorization.currentStatus == .notDetermined else { return }
        let status = await MusicAuthorization.request()
        if status != .authorized {
            print("[MusicService] Apple Music access not granted (\(status)); using iTunes catalog")
        }
    }

    private var genreCache: [Int: Genre] = [:]

    private func demoteMusicKit(_ error: Error) {
        if !musicKitDown {
            print("[MusicService] MusicKit unavailable (is the MusicKit app service enabled for this App ID?), falling back to iTunes: \(error)")
            musicKitDown = true
        }
    }

    private static let releaseDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    private func mapSong(_ song: Song) -> Track {
        Track(
            id: song.id.rawValue,
            name: song.title,
            artistName: song.artistName,
            albumName: song.albumTitle ?? "",
            albumId: song.albums?.first?.id.rawValue,
            artworkUrl: song.artwork?.url(width: 300, height: 300)?.absoluteString,
            releaseDate: song.releaseDate.map { Self.releaseDateFormatter.string(from: $0) },
            previewUrl: song.previewAssets?.first?.url?.absoluteString,
            externalUrl: song.url?.absoluteString,
            genreName: song.genreNames.first
        )
    }

    private func chartGenre(for genre: String?) async throws -> Genre? {
        guard let genre, let genreID = Self.genreIDs[genre] else { return nil }
        if let cached = genreCache[genreID] { return cached }
        let request = MusicCatalogResourceRequest<Genre>(matching: \.id, equalTo: MusicItemID(String(genreID)))
        let response = try await request.response()
        if let found = response.items.first {
            genreCache[genreID] = found
        }
        return genreCache[genreID]
    }

    private func musicKitChartTracks(genre: String?) async throws -> [Track] {
        let catalogGenre = try await chartGenre(for: genre)
        var tracks: [Track] = []
        for offset in [0, 50] {
            var request = MusicCatalogChartsRequest(genre: catalogGenre, kinds: [.mostPlayed], types: [Song.self])
            request.limit = 50
            request.offset = offset
            let response = try await request.response()
            let songs = response.songCharts.first?.items ?? []
            tracks += songs.map(mapSong)
            if songs.count < 50 { break }
        }
        return tracks
    }

    private func musicKitSearchTracks(term: String) async throws -> [Track] {
        var tracks: [Track] = []
        for offset in [0, 25] {
            var request = MusicCatalogSearchRequest(term: term, types: [Song.self])
            request.limit = 25
            request.offset = offset
            let response = try await request.response()
            tracks += response.songs.map(mapSong)
            if response.songs.count < 25 { break }
        }
        return tracks
    }

    private func musicKitAlbumTracks(albumId: String) async throws -> [Track] {
        var request = MusicCatalogResourceRequest<Album>(matching: \.id, equalTo: MusicItemID(albumId))
        request.properties = [.tracks]
        let response = try await request.response()
        guard let albumTracks = response.items.first?.tracks else { return [] }
        return albumTracks.compactMap { item in
            if case .song(let song) = item { return mapSong(song) }
            return nil
        }
    }

    private func musicKitAlbumId(forSongId songId: String) async throws -> String? {
        var request = MusicCatalogResourceRequest<Song>(matching: \.id, equalTo: MusicItemID(songId))
        request.properties = [.albums]
        let response = try await request.response()
        return response.items.first?.albums?.first?.id.rawValue
    }

    // MARK: - iTunes backend (no key required)

    private func itunesFetch(_ urlString: String) async throws -> [String: Any] {
        let (data, response) = try await URLSession.shared.data(from: URL(string: urlString)!)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func mapItunesTrack(_ r: [String: Any]) -> Track? {
        guard let idNum = r["trackId"] as? Int,
              let name = r["trackName"] as? String else { return nil }
        let albumIdNum = r["collectionId"] as? Int
        return Track(
            id: String(idNum),
            name: name,
            artistName: r["artistName"] as? String ?? "",
            albumName: r["collectionName"] as? String ?? "",
            albumId: albumIdNum.map(String.init),
            artworkUrl: r["artworkUrl100"] as? String,
            releaseDate: r["releaseDate"] as? String,
            previewUrl: r["previewUrl"] as? String,
            externalUrl: r["trackViewUrl"] as? String,
            genreName: r["primaryGenreName"] as? String
        )
    }

    private func itunesChartTracks(genre: String?) async throws -> [Track] {
        let genreSegment = genre.flatMap { Self.genreIDs[$0] }.map { "/genre=\($0)" } ?? ""
        let rss = try await itunesFetch("https://itunes.apple.com/\(storefront)/rss/topsongs/limit=100\(genreSegment)/json")
        let feed = rss["feed"] as? [String: Any]
        let entries = feed?["entry"] as? [[String: Any]] ?? []
        let ids: [String] = entries.compactMap { entry in
            let idField = entry["id"] as? [String: Any]
            let attributes = idField?["attributes"] as? [String: Any]
            return attributes?["im:id"] as? String
        }
        guard !ids.isEmpty else { return [] }

        // The RSS feed lacks release dates and album IDs; a batch lookup fills
        // in full metadata while preserving chart order.
        let lookup = try await itunesFetch("https://itunes.apple.com/lookup?id=\(ids.joined(separator: ","))&country=\(storefront)")
        let results = lookup["results"] as? [[String: Any]] ?? []
        var byID: [String: Track] = [:]
        for r in results where (r["wrapperType"] as? String) == "track" {
            if let track = mapItunesTrack(r) { byID[track.id] = track }
        }
        return ids.compactMap { byID[$0] }
    }

    private func itunesSearchTracks(term: String) async throws -> [Track] {
        let encoded = term.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? term
        let data = try await itunesFetch("https://itunes.apple.com/search?term=\(encoded)&entity=song&limit=200&country=\(storefront)")
        let results = data["results"] as? [[String: Any]] ?? []
        return results.compactMap(mapItunesTrack)
    }

    private func itunesAlbumTracks(albumId: String) async throws -> [Track] {
        let data = try await itunesFetch("https://itunes.apple.com/lookup?id=\(albumId)&entity=song&country=\(storefront)")
        let results = data["results"] as? [[String: Any]] ?? []
        return results
            .filter { ($0["wrapperType"] as? String) == "track" }
            .compactMap(mapItunesTrack)
    }
}
