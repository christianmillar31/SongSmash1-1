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
    var tier: MusicService.Tier = .medium // fame grade: easy=famous, medium=known, hard=obscure

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
//
// Difficulty pipeline (no API exposes a song popularity number, so fame is
// assembled from layered signals):
//  1. Collect candidates: genre charts, decade searches, Apple editorial
//     "Essentials" playlists, and (hard games) album deep cuts mined from
//     famous artists.
//  2. Grade each song famous/known/obscure using the bundled chart-history
//     database (FameDatabase), current chart rank, Essentials membership,
//     and the artist's top-songs list; Deezer's rank upgrades stragglers the
//     local signals missed (famous album cuts, non-US hits).
//  3. Assemble the queue for the chosen difficulty with anchors interleaved
//     so players never hear three unrecognizable songs in a row.
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
    private var essentialsCache: [String: [Track]] = [:]
    private var topSongsCache: [String: [String]] = [:] // normalized artist -> ordered songKeys
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

    // Order matches GameSetupView's availableDecades (the view references this).
    static let allDecades = ["2020s", "2010s", "2000s", "1990s", "1980s", "1970s", "1960s"]

    // Apple's decade "Hits Essentials" playlists (verified 2026-08; IDs are
    // storefront-agnostic). Seeds only — a search fallback re-resolves when a
    // seed stops loading, so rotation by Apple is survivable.
    private static let decadeHitsPlaylistIDs: [String: String] = [
        "1970s": "pl.1745c21b5f084936ad637b4cd5cbd99a",
        "1980s": "pl.af4d982795c6472ea48579eb147cd726",
        "1990s": "pl.0d70b7c9be8e4e0b95ebbf5578aaf7a2",
        "2000s": "pl.e50ccee7318043eaaf8e8e28a2a55114",
        "2010s": "pl.6b1b5dfda067443481265436811002f1",
    ]

    private let chartFamousCutoff = 25   // current chart rank treated as famous
    private let deepCutSources = 8       // distinct artists mined per hard game
    private let deepCutsPerAlbum = 3
    private let essentialsBudget = 8     // playlist fetches per queue build
    private let deezerLookupBudget = 48  // per build; results cache to disk forever
    private let maxQueueLength = 150
    private let minEasyPool = 40
    // Decade searches per genre when the player picked no decades; bounded so
    // a many-genre selection stays under the iTunes fallback's ~20 req/min.
    private let allErasSearchBudget = 8

    // Signals gathered while collecting candidates, consumed by grading.
    private struct GradingContext {
        var chartRank: [String: Int] = [:]      // songKey -> best current chart rank
        var hitsEssentials: Set<String> = []    // songKey in a decade "Hits Essentials"
        var genreEssentials: Set<String> = []   // songKey in a genre Essentials playlist
        var artistTop: [String: [String]] = [:] // normalized artist -> ordered top-song keys

        mutating func recordChartRank(_ rank: Int, for key: String) {
            chartRank[key] = min(rank, chartRank[key] ?? Int.max)
        }
    }

    // MARK: - Public API

    /// Builds a difficulty-stratified game queue for the selected filters.
    /// Only tracks with a playable preview are returned.
    func loadTracks(genres: [String], decades: [String], difficulty: Difficulty) async throws -> [Track] {
        playedTrackIDs.removeAll()
        await ensureMusicKitAuthorization()

        let genreList = genres.filter { Self.genreIDs[$0] != nil }
        // No genres selected = all music: the overall charts (genre nil).
        let genreKeys: [String?] = genreList.isEmpty ? [nil] : genreList

        var pool: [Track] = []
        var context = GradingContext()

        for genre in genreKeys {
            let chart = await chartTracks(genre: genre)
            for (index, track) in chart.enumerated() {
                context.recordChartRank(index + 1, for: songKey(track))
            }
            pool += filterByDecades(chart, decades: decades)

            // Charts skew recent, so decades need their own search pass. With
            // no decades picked, sweep them all anyway — otherwise "all music"
            // is just today's chart, which is almost entirely the last two
            // years. Sampled per genre to respect the search budget.
            let searchDecades = decades.isEmpty
                ? Array(Self.allDecades.shuffled().prefix(max(2, allErasSearchBudget / genreKeys.count)))
                : decades
            for decade in searchDecades {
                pool += await decadeTracks(decade: decade, genre: genre)
            }
        }

        // Apple editorial Essentials playlists: human-curated "everyone knows
        // these" pools per decade and genre — the backbone of easy queues for
        // eras the current charts can't reach.
        pool += await essentialsTracks(genres: genreList, decades: decades, context: &context)

        if difficulty == .hard {
            pool += await deepCuts(pool: pool, context: &context)
        }

        var queue = dedupeSongs(pool).filter { $0.previewUrl != nil }
        queue = gradeTracks(queue, context: context)
        queue = await deezerUpgrade(queue, difficulty: difficulty)

        // Prefer songs not heard in any game this session; only fall back to
        // repeats if that would leave too small a queue.
        let fresh = queue.filter { !sessionPlayedSongs.contains(songKey($0)) }
        if fresh.count >= 15 {
            queue = fresh
        }

        let assembled = assembleQueue(queue, difficulty: difficulty)
        let famous = queue.filter { $0.tier == .easy }.count
        let known = queue.filter { $0.tier == .medium }.count
        print("[MusicService] Queue \(assembled.count)/\(queue.count) tracks (fame \(famous)F/\(known)K/\(queue.count - famous - known)O, \(fresh.count) unheard) for genres=\(genreList.isEmpty ? ["All"] : genreList) decades=\(decades) difficulty=\(difficulty.rawValue)")
#if DEBUG
        for (index, track) in assembled.prefix(15).enumerated() {
            print("[MusicService]   \(index + 1). [\(track.tier.rawValue)] \(track.name) — \(track.artistName)")
        }
#endif
        return assembled
    }

    func markTrackAsPlayed(_ track: Track) {
        playedTrackIDs.insert(track.id)
        sessionPlayedSongs.insert(songKey(track))
    }

    func shouldSkipTrack(_ track: Track) -> Bool {
        playedTrackIDs.contains(track.id)
    }

    // MARK: - Grading

    private func gradeTracks(_ tracks: [Track], context: GradingContext) -> [Track] {
        tracks.map { track in
            var t = track
            t.tier = tier(for: localGrade(track, context: context))
            return t
        }
    }

    private func localGrade(_ track: Track, context: GradingContext) -> FameGrade {
        var grade = FameGrade.obscure
        if let record = FameDatabase.shared.lookup(title: track.name, artist: track.artistName) {
            grade = max(grade, record.grade)
        }
        let key = songKey(track)
        if let rank = context.chartRank[key] {
            grade = max(grade, rank <= chartFamousCutoff ? .famous : .known)
        }
        if context.hitsEssentials.contains(key) { grade = max(grade, .famous) }
        if context.genreEssentials.contains(key) { grade = max(grade, .known) }
        if let top = context.artistTop[FameDatabase.normalizeArtist(track.artistName)],
           let index = top.firstIndex(of: key) {
            grade = max(grade, index < 5 ? .famous : .known)
        }
        return grade
    }

    private func tier(for grade: FameGrade) -> Tier {
        switch grade {
        case .famous: return .easy
        case .known: return .medium
        case .obscure: return .hard
        }
    }

    /// Ask Deezer to grade songs the local signals left obscure: famous album
    /// cuts and non-US hits never charted here. Hard games vet every would-be
    /// challenger (budget permitting); easy/medium only when the recognizable
    /// pool is thin. Lookups cache to disk, so repeat games cost nothing.
    private func deezerUpgrade(_ tracks: [Track], difficulty: Difficulty) async -> [Track] {
        var tracks = tracks
        let recognizable = tracks.filter { $0.tier != .hard }.count
        if difficulty != .hard && recognizable >= minEasyPool { return tracks }

        let candidates = tracks.indices.filter { tracks[$0].tier == .hard }.shuffled()
        let chosen = Array(candidates.prefix(deezerLookupBudget))
        guard !chosen.isEmpty else { return tracks }

        var upgraded = 0
        for chunkStart in stride(from: 0, to: chosen.count, by: 8) {
            let chunk = chosen[chunkStart..<min(chunkStart + 8, chosen.count)]
            let ranks = await withTaskGroup(of: (Int, Int?).self, returning: [Int: Int].self) { group in
                for index in chunk {
                    let track = tracks[index]
                    group.addTask {
                        (index, await DeezerRankService.shared.rank(title: track.name, artist: track.artistName))
                    }
                }
                var found: [Int: Int] = [:]
                for await (index, rank) in group {
                    if let rank { found[index] = rank }
                }
                return found
            }
            for (index, rank) in ranks {
                let grade = DeezerRankService.shared.grade(forRank: rank)
                if grade != .obscure {
                    tracks[index].tier = tier(for: grade)
                    upgraded += 1
                }
            }
        }
        DeezerRankService.shared.persistCache()
        if upgraded > 0 { print("[MusicService] Deezer upgraded \(upgraded)/\(chosen.count) obscure tracks") }
        return tracks
    }

    // MARK: - Queue assembly

    /// Orders the graded pool for the chosen difficulty. Harder queues carry
    /// challengers, but anchors are woven in so no window of three songs is
    /// ever all-unrecognizable — the thing that kills a party.
    private func assembleQueue(_ tracks: [Track], difficulty: Difficulty) -> [Track] {
        let famous = tracks.filter { $0.tier == .easy }.shuffled()
        let known = tracks.filter { $0.tier == .medium }.shuffled()
        let obscure = tracks.filter { $0.tier == .hard }.shuffled()

        switch difficulty {
        case .easy:
            var queue = famous
            if queue.count < minEasyPool {
                // Thin era/genre combo: pad with the most defensible knowns.
                queue = (queue + known.prefix(minEasyPool - queue.count)).shuffled()
                print("[MusicService] Easy pool thin (\(famous.count) famous); padded with \(queue.count - famous.count) known")
            }
            return Array(queue.prefix(maxQueueLength))
        case .medium:
            var queue = interleave(anchors: famous, others: known, maxOthersRun: 2)
            if queue.count < minEasyPool {
                queue += obscure.prefix(minEasyPool - queue.count)
            }
            return Array(queue.prefix(maxQueueLength))
        case .hard:
            var anchors = known
            if anchors.count * 2 < obscure.count {
                // Not enough knowns to anchor every third slot; promote hits.
                anchors = (anchors + famous).shuffled()
            }
            return Array(interleave(anchors: anchors, others: obscure, maxOthersRun: 2).prefix(maxQueueLength))
        }
    }

    /// Random weave of two pools, never allowing more than maxOthersRun
    /// consecutive "others" while anchors remain.
    private func interleave(anchors: [Track], others: [Track], maxOthersRun: Int) -> [Track] {
        var anchors = anchors[...]
        var others = others[...]
        var out: [Track] = []
        var run = 0
        while !(anchors.isEmpty && others.isEmpty) {
            let pickOther: Bool
            if others.isEmpty {
                pickOther = false
            } else if anchors.isEmpty {
                pickOther = true
            } else if run >= maxOthersRun {
                pickOther = false
            } else {
                pickOther = Double.random(in: 0..<1) < Double(others.count) / Double(others.count + anchors.count)
            }
            if pickOther {
                out.append(others.removeFirst())
                run += 1
            } else {
                out.append(anchors.removeFirst())
                run = 0
            }
        }
        return out
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

    /// Current top-of-chart tracks for a genre (chart order preserved; the
    /// caller records ranks for grading).
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
        chartCache[cacheKey] = tracks
        return tracks
    }

    /// Songs from a decade within a genre, filtered by release year and
    /// catalog genre label. Grading decides how recognizable each one is.
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
        let filtered = results.filter { track in
            guard let year = track.releaseYear, year >= range.0, year <= range.1 else { return false }
            return matchesGenre(label: track.genreName, genre: genre)
        }
        searchCache[cacheKey] = filtered
        return filtered
    }

    // MARK: - Essentials playlists (MusicKit only)

    private struct EssentialsSpec {
        let genre: String?   // nil = decade "Hits Essentials"
        let decade: String?  // nil = all-time genre Essentials
    }

    /// Tracks from Apple's editorial Essentials playlists for the selection,
    /// recording membership so grading can mark them famous/known.
    private func essentialsTracks(genres: [String], decades: [String], context: inout GradingContext) async -> [Track] {
        guard useMusicKit else { return [] }

        var hitsSpecs: [EssentialsSpec] = decades.map { EssentialsSpec(genre: nil, decade: $0) }
        if decades.isEmpty && !genres.isEmpty {
            hitsSpecs = [] // genre-only games get genre Essentials below
        }
        var genreSpecs: [EssentialsSpec] = []
        for genre in genres {
            if decades.isEmpty {
                genreSpecs.append(EssentialsSpec(genre: genre, decade: nil))
            } else {
                genreSpecs += decades.map { EssentialsSpec(genre: genre, decade: $0) }
            }
        }

        let specs = (hitsSpecs + genreSpecs.shuffled()).prefix(essentialsBudget)
        var collected: [Track] = []
        for spec in specs {
            var tracks = await essentialsPlaylistTracks(spec)
            if let decade = spec.decade {
                tracks = filterByDecades(tracks, decades: [decade])
            }
            if spec.genre == nil && !genres.isEmpty {
                // Cross-genre hits playlist inside a genre-filtered game: keep
                // only tracks whose label matches some selected genre.
                tracks = tracks.filter { track in genres.contains { matchesGenre(label: track.genreName, genre: $0) } }
            }
            for track in tracks {
                let key = songKey(track)
                if spec.genre == nil {
                    context.hitsEssentials.insert(key)
                } else {
                    context.genreEssentials.insert(key)
                }
            }
            collected += tracks
        }
        return collected
    }

    private func essentialsPlaylistTracks(_ spec: EssentialsSpec) async -> [Track] {
        let cacheKey = "ess:\(spec.genre ?? "hits"):\(spec.decade ?? "all")"
        if let cached = essentialsCache[cacheKey] { return cached }

        var tracks: [Track] = []
        // Fast path: known decade Hits Essentials IDs.
        if spec.genre == nil, let decade = spec.decade, let id = Self.decadeHitsPlaylistIDs[decade] {
            tracks = await playlistTracks(id: id)
        }
        if tracks.isEmpty {
            tracks = await searchEssentialsPlaylist(spec)
        }
        essentialsCache[cacheKey] = tracks
        if !tracks.isEmpty {
            print("[MusicService] Essentials \(cacheKey): \(tracks.count) tracks")
        }
        return tracks
    }

    private func playlistTracks(id: String) async -> [Track] {
        guard useMusicKit else { return [] }
        do {
            var request = MusicCatalogResourceRequest<Playlist>(matching: \.id, equalTo: MusicItemID(id))
            request.properties = [.tracks]
            let response = try await request.response()
            guard let items = response.items.first?.tracks else { return [] }
            return items.compactMap { item in
                if case .song(let song) = item { return mapSong(song) }
                return nil
            }
        } catch {
            demoteMusicKit(error)
            return []
        }
    }

    private func searchEssentialsPlaylist(_ spec: EssentialsSpec) async -> [Track] {
        guard useMusicKit else { return [] }
        let decadeToken = spec.decade.map { $0.count == 5 ? String($0.dropFirst(2)) : $0 } // "1980s" -> "80s"
        let subject = spec.genre ?? "Hits"
        let term = "\(decadeToken ?? "") \(subject) Essentials".trimmingCharacters(in: .whitespaces)
        do {
            var request = MusicCatalogSearchRequest(term: term, types: [Playlist.self])
            request.limit = 25
            let response = try await request.response()
            let wanted = compact(subject)
            let playlist = response.playlists.first { playlist in
                guard (playlist.curatorName ?? "").lowercased().hasPrefix("apple music") else { return false }
                let name = compact(playlist.name)
                guard name.contains("essentials"), name.contains(wanted) else { return false }
                if let decadeToken { return name.contains(compact(decadeToken)) }
                return true
            }
            guard let playlist else { return [] }
            let detailed = try await playlist.with(.tracks)
            return (detailed.tracks ?? []).compactMap { item in
                if case .song(let song) = item { return mapSong(song) }
                return nil
            }
        } catch {
            demoteMusicKit(error)
            return []
        }
    }

    /// Lowercased alphanumerics only — playlist names use styled apostrophes
    /// and hyphens ("’80s", "Hip-Hop") that would break contains() checks.
    private func compact(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) })
    }

    // MARK: - Deep cuts (hard tier candidates)

    /// Album tracks that were never hits, mined from recognizable artists in
    /// the pool — "you know the artist, but which song is this?" material.
    /// The artist's top songs and the fame database veto anything famous.
    private func deepCuts(pool: [Track], context: inout GradingContext) async -> [Track] {
        var seenArtists = Set<String>()
        var sources: [Track] = []
        for track in pool.shuffled() {
            let key = songKey(track)
            let recognizable = context.chartRank[key] != nil
                || context.hitsEssentials.contains(key)
                || context.genreEssentials.contains(key)
                || FameDatabase.shared.lookup(title: track.name, artist: track.artistName)?.grade == .famous
            guard recognizable else { continue }
            if seenArtists.insert(FameDatabase.normalizeArtist(track.artistName)).inserted {
                sources.append(track)
            }
            if sources.count >= deepCutSources { break }
        }

        var cuts: [Track] = []
        for source in sources {
            let artistNorm = FameDatabase.normalizeArtist(source.artistName)
            let topKeys = await topSongKeys(artistName: source.artistName)
            context.artistTop[artistNorm] = topKeys

            guard let albumId = await albumId(for: source) else { continue }
            let albumTracks = await tracksForAlbum(albumId)
            let candidates = albumTracks.filter { candidate in
                let key = songKey(candidate)
                guard key != songKey(source), !topKeys.contains(key), context.chartRank[key] == nil else { return false }
                let grade = FameDatabase.shared.lookup(title: candidate.name, artist: candidate.artistName)?.grade ?? .obscure
                return grade == .obscure
            }
            cuts += candidates.shuffled().prefix(deepCutsPerAlbum)
        }
        return cuts
    }

    /// Ordered songKeys of the artist's ~20 most popular songs in this
    /// storefront (Apple's own popularity ranking). Empty when unavailable.
    private func topSongKeys(artistName: String) async -> [String] {
        let norm = FameDatabase.normalizeArtist(artistName)
        guard !norm.isEmpty else { return [] }
        if let cached = topSongsCache[norm] { return cached }
        guard useMusicKit else { return [] }

        var keys: [String] = []
        do {
            var request = MusicCatalogSearchRequest(term: artistName, types: [Artist.self])
            request.limit = 5
            let response = try await request.response()
            let artist = response.artists.first { FameDatabase.normalizeArtist($0.name) == norm }
                ?? response.artists.first
            if let artist {
                let detailed = try await artist.with(.topSongs)
                keys = (detailed.topSongs ?? []).map { songKey(mapSong($0)) }
            }
        } catch {
            demoteMusicKit(error)
        }
        topSongsCache[norm] = keys
        return keys
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
        // Apple's dialog is all-or-nothing ("music and video activity", "media
        // library") even though we only read the public catalog. Don't show it
        // unless MusicKit can actually serve: while the MusicKit app service
        // isn't enabled for this App ID, the developer token fails and every
        // request would 401 into the iTunes fallback anyway.
        do {
            _ = try await DefaultMusicTokenProvider().developerToken(options: [])
        } catch {
            demoteMusicKit(error)
            return
        }
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
