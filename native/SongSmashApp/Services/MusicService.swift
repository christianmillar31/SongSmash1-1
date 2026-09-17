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
    var isExplicit: Bool = false
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

    // MusicKit health. Failures are counted per queue build, never latched for
    // the life of the app: one timeout on party wifi used to drop every later
    // game in the session onto the thinner iTunes catalog.
    private var musicKitFailures = 0
    private var musicKitOffForBuild = false
    /// What the last build actually ran on, for the setup screen's footnote.
    private(set) var usingFallbackCatalog = false
    private(set) var catalogNote: String?

    private var chartCache: [String: [Track]] = [:]
    private var albumCache: [String: [Track]] = [:]
    private var searchCache: [String: [Track]] = [:]
    private var essentialsCache: [String: [Track]] = [:]
    private var topSongsCache: [String: [String]] = [:] // normalized artist -> ordered songKeys
    private var playedTrackIDs: Set<String> = []
    // Songs heard in past games, oldest first, by title+artist so remasters and
    // re-releases count as the same song. Persisted: a game night that gets
    // interrupted (phone locked, app swiped away) used to forget everything and
    // then replay the same songs from the same editorial playlists.
    private var recentlyPlayed: [String] = []
    private var recentlyPlayedLoaded = false
    private static let recentlyPlayedKey = "RecentlyPlayedSongs"
    private let recentlyPlayedLimit = 600

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
    private let genreEssentialsFamousCutoff = 40 // playlist position treated as famous
    private let deepCutSources = 8       // distinct artists mined per hard game
    private let deepCutsPerAlbum = 3
    private let essentialsBudget = 8     // playlist fetches per queue build
    private let deezerLookupBudget = 48  // per build; results cache to disk forever
    private let maxQueueLength = 300
    private let minEasyPool = 40
    // One song scores at most 2 points for a team, and rooms routinely draw a
    // blank, so a game to N can run well past N rounds. Build for the long one.
    private let roundsPerPoint = 3.0
    private let minQueueLength = 45
    private let artistGap = 8            // songs between repeats of one artist
    private let artistShareDivisor = 25  // queue length per allowed song by one artist
    // Decade searches per genre when the player picked no decades; bounded so
    // a many-genre selection stays under the iTunes fallback's ~20 req/min.
    private let allErasSearchBudget = 8

    // Signals gathered while collecting candidates, consumed by grading.
    private struct GradingContext {
        var chartRank: [String: Int] = [:]      // songKey -> best current chart rank
        var hitsEssentials: Set<String> = []    // songKey in a decade "Hits Essentials"
        // songKey -> best position in a genre Essentials playlist. Apple leads
        // these with the defining hits, so position stands in for fame and
        // keeps Easy/Medium/Hard distinct within one genre.
        var genreEssentials: [String: Int] = [:]
        var artistTop: [String: [String]] = [:] // normalized artist -> ordered top-song keys

        mutating func recordChartRank(_ rank: Int, for key: String) {
            chartRank[key] = min(rank, chartRank[key] ?? Int.max)
        }
    }

    // MARK: - Public API

    /// Builds a difficulty-stratified game queue for the selected filters.
    /// Only tracks with a playable preview are returned.
    /// - Parameters:
    ///   - targetScore: the game's winning score; the queue is sized so a slow
    ///     game can't run out of songs mid-party.
    ///   - familyFriendly: drop tracks Apple marks explicit.
    ///   - continuing: top-up for a game already in progress — keeps what has
    ///     already been played in this game marked as played.
    func loadTracks(
        genres: [String],
        decades: [String],
        difficulty: Difficulty,
        targetScore: Int = 25,
        familyFriendly: Bool = true,
        continuing: Bool = false
    ) async throws -> [Track] {
        if !continuing { playedTrackIDs.removeAll() }
        musicKitFailures = 0
        musicKitOffForBuild = false
        catalogNote = nil // may be replaced with a specific reason below
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
#if DEBUG
            dlog("chart \(genre ?? "all"): \(chart.count) → in-decade \(filterByDecades(chart, decades: decades).count)")
#endif

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
        if familyFriendly { queue = queue.filter { !$0.isExplicit } }
        queue = gradeTracks(queue, context: context)
        let needed = min(maxQueueLength, max(minQueueLength, Int(Double(targetScore) * roundsPerPoint)))
        queue = await deezerUpgrade(queue, difficulty: difficulty, needed: needed)

        // Songs the room has heard lately go to the back of the line rather
        // than being dropped outright: a thin pool should replay the oldest
        // songs, never repeat the last game wholesale.
        // Twice the game's length, so tier filtering still has songs to pick from.
        queue = preferUnheard(queue, needed: needed * 2)

        let assembled = assembleQueue(queue, difficulty: difficulty, balanceDecades: genreList.isEmpty && decades.isEmpty, limit: needed)
        let famous = queue.filter { $0.tier == .easy }.count
        let known = queue.filter { $0.tier == .medium }.count
        usingFallbackCatalog = !useMusicKit
        if !usingFallbackCatalog {
            catalogNote = nil
        } else if catalogNote == nil {
            catalogNote = MusicAuthorization.currentStatus == .authorized
                ? "Apple Music catalog unavailable — using the smaller iTunes catalog."
                : "Apple Music access is off, so songs come from the smaller iTunes catalog."
        }
        print("[MusicService] Queue \(assembled.count)/\(queue.count) tracks (fame \(famous)F/\(known)K/\(queue.count - famous - known)O, need \(needed), musicKit=\(useMusicKit)) for genres=\(genreList.isEmpty ? ["All"] : genreList) decades=\(decades) difficulty=\(difficulty.rawValue)")
#if DEBUG
        debugReport(assembled, raw: pool.count, deduped: dedupeSongs(pool).count, fresh: queue.count)
#endif
        return assembled
    }

#if DEBUG
    private func dlog(_ s: String) { print("[BETA] \(s)") }

    private func debugReport(_ q: [Track], raw: Int, deduped: Int, fresh: Int) {
        dlog("pool raw=\(raw) deduped=\(deduped) fresh=\(fresh) queue=\(q.count)")
        func dist(_ tracks: ArraySlice<Track>, _ key: (Track) -> String, top: Int = 12) -> String {
            var c: [String: Int] = [:]
            for t in tracks { c[key(t), default: 0] += 1 }
            return c.sorted { $0.value > $1.value }.prefix(top).map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
        }
        let first40 = q.prefix(40)
        dlog("first40 tiers: \(dist(first40, { $0.tier.rawValue }))")
        dlog("first40 decades: \(dist(first40, { $0.releaseYear.map { "\($0 / 10 * 10)s" } ?? "?" }))")
        dlog("first40 genres: \(dist(first40, { $0.genreName ?? "?" }))")
        dlog("first40 artists: \(dist(first40, { FameDatabase.normalizeArtist($0.artistName) }, top: 8))")
        dlog("all decades: \(dist(q[...], { $0.releaseYear.map { "\($0 / 10 * 10)s" } ?? "?" }))")
        dlog("all genres: \(dist(q[...], { $0.genreName ?? "?" }))")
        dlog("all artists: \(dist(q[...], { FameDatabase.normalizeArtist($0.artistName) }, top: 10))")
        // Same song under different catalog spellings (songKey misses these).
        var seen: [String: Track] = [:]
        for t in q {
            let k = FameDatabase.normalizeTitle(t.name) + "|" + FameDatabase.normalizeArtist(t.artistName)
            if let prior = seen[k] {
                dlog("DUPLICATE: '\(prior.name)' / '\(prior.artistName)' [\(prior.albumName)] vs '\(t.name)' / '\(t.artistName)' [\(t.albumName)]")
            } else { seen[k] = t }
        }
        var titles: [String: Track] = [:]
        for t in q {
            let k = FameDatabase.normalizeTitle(t.name)
            if let prior = titles[k], FameDatabase.normalizeArtist(prior.artistName) != FameDatabase.normalizeArtist(t.artistName) {
                dlog("SAME TITLE: '\(prior.name)' / '\(prior.artistName)' vs '\(t.name)' / '\(t.artistName)'")
            }
            titles[k] = t
        }
        for (i, t) in q.prefix(45).enumerated() {
            dlog("  \(i + 1). [\(t.tier.rawValue)] \(t.releaseYear.map(String.init) ?? "????") \(t.genreName ?? "?") | \(t.name) — \(t.artistName)")
        }
    }

    /// Replays the beta-test games from the Sept 2026 feedback, marking the
    /// first `played` tracks heard like a real game to 20 would.
    func debugSimulateBeta() async {
        let mode = UserDefaults.standard.string(forKey: "SimulateBeta") ?? ""
        var games: [(String, [String], [String], Difficulty, Int, Bool)] = []
        if mode == "itunes" {
            debugForceITunes = true
            games = [
                ("I4 rock+pop 60-70 easy [iTunes]", ["Rock", "Pop"], ["1960s", "1970s"], .easy, 30, true),
                ("I5 rock 60-70 medium after I4 [iTunes]", ["Rock"], ["1960s", "1970s"], .medium, 30, false),
                ("I5b rock 60-70 medium fresh [iTunes]", ["Rock"], ["1960s", "1970s"], .medium, 30, true),
                ("I2 country 70-90 easy [iTunes]", ["Country"], ["1970s", "1980s", "1990s"], .easy, 30, true),
                ("I1 all/all easy [iTunes]", [], [], .easy, 30, true),
            ]
        } else if mode == "country" {
            for i in 1...4 { games.append(("C\(i) country 70-90 easy, rematch \(i)", ["Country"], ["1970s", "1980s", "1990s"], .easy, 30, i == 1)) }
        } else if mode == "hard" {
            games = [
                ("H1 rock 60-70 hard", ["Rock"], ["1960s", "1970s"], .hard, 30, true),
                ("H2 all/all hard", [], [], .hard, 30, true),
                ("H3 country 70-90 hard", ["Country"], ["1970s", "1980s", "1990s"], .hard, 30, true),
            ]
        } else {
            games = [
                ("G1 all/all easy", [], [], .easy, 30, true),
                ("G2 country 70-90 easy", ["Country"], ["1970s", "1980s", "1990s"], .easy, 30, true),
                ("G4 rock+pop 60-70 easy", ["Rock", "Pop"], ["1960s", "1970s"], .easy, 30, true),
                ("G5 rock 60-70 medium (after G4)", ["Rock"], ["1960s", "1970s"], .medium, 30, false),
                ("G5b rock 60-70 medium (fresh session)", ["Rock"], ["1960s", "1970s"], .medium, 30, true),
            ]
        }
        for (name, genres, decades, difficulty, played, reset) in games {
            if reset {
                recentlyPlayed.removeAll()
                recentlyPlayedLoaded = true
                UserDefaults.standard.removeObject(forKey: Self.recentlyPlayedKey)
            }
            dlog("==================== \(name) ====================")
            let q = (try? await loadTracks(genres: genres, decades: decades, difficulty: difficulty, targetScore: 20)) ?? []
            for t in q.prefix(played) { markTrackAsPlayed(t) }
        }
        dlog("SIMULATION DONE")
    }
#endif

    func markTrackAsPlayed(_ track: Track) {
        playedTrackIDs.insert(track.id)
        loadRecentlyPlayedIfNeeded()
        let key = songKey(track)
        recentlyPlayed.removeAll { $0 == key }
        recentlyPlayed.append(key)
        if recentlyPlayed.count > recentlyPlayedLimit {
            recentlyPlayed.removeFirst(recentlyPlayed.count - recentlyPlayedLimit)
        }
        UserDefaults.standard.set(recentlyPlayed, forKey: Self.recentlyPlayedKey)
    }

    private func loadRecentlyPlayedIfNeeded() {
        guard !recentlyPlayedLoaded else { return }
        recentlyPlayedLoaded = true
        recentlyPlayed = UserDefaults.standard.stringArray(forKey: Self.recentlyPlayedKey) ?? []
    }

    /// Unheard songs first; if there still aren't enough for the game, top up
    /// with the ones heard longest ago.
    private func preferUnheard(_ tracks: [Track], needed: Int) -> [Track] {
        loadRecentlyPlayedIfNeeded()
        var heardAt: [String: Int] = [:]
        for (index, key) in recentlyPlayed.enumerated() { heardAt[key] = index }

        var unheard: [Track] = []
        var heard: [Track] = []
        for track in tracks {
            if heardAt[songKey(track)] == nil { unheard.append(track) } else { heard.append(track) }
        }
        guard unheard.count < needed else { return unheard }
        heard.sort { (heardAt[songKey($0)] ?? 0) < (heardAt[songKey($1)] ?? 0) }
        return unheard + heard.prefix(needed - unheard.count)
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
        // Apple's genre Essentials are only fetched for genres the player chose,
        // and to a room that picked Country, the front of "'70s Country
        // Essentials" IS the easy round. Grading all of it merely "known" left
        // Easy country with a handful of pop-crossover hits by the same artists.
        if let rank = context.genreEssentials[key] {
            grade = max(grade, rank < genreEssentialsFamousCutoff ? .famous : .known)
        }
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
    private func deezerUpgrade(_ tracks: [Track], difficulty: Difficulty, needed: Int) async -> [Track] {
        var tracks = tracks
        // Easy needs enough *famous* songs, not merely recognizable ones. On the
        // iTunes fallback — no editorial playlists — a genre like Country only
        // musters a couple dozen, which is how one artist ended up owning a game.
        let recognizable = difficulty == .easy
            ? tracks.filter { $0.tier == .easy }.count
            : tracks.filter { $0.tier != .hard }.count
        if difficulty != .hard && recognizable >= needed { return tracks }

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
        await DeezerRankService.shared.persistCache()
        if upgraded > 0 { print("[MusicService] Deezer upgraded \(upgraded)/\(chosen.count) obscure tracks") }
        return tracks
    }

    // MARK: - Queue assembly

    /// Orders the graded pool for the chosen difficulty. Harder queues carry
    /// challengers, but anchors are woven in so no window of three songs is
    /// ever all-unrecognizable — the thing that kills a party.
    private func assembleQueue(_ tracks: [Track], difficulty: Difficulty, balanceDecades: Bool, limit: Int) -> [Track] {
        let famous = tracks.filter { $0.tier == .easy }.shuffled()
        let known = tracks.filter { $0.tier == .medium }.shuffled()
        let obscure = tracks.filter { $0.tier == .hard }.shuffled()

        var ordered: [Track]
        switch difficulty {
        case .easy:
            ordered = famous
            if ordered.count < max(minEasyPool, limit) {
                // Thin era/genre combo: pad with the most defensible knowns.
                let padding = known.prefix(max(minEasyPool, limit) - ordered.count)
                ordered = (ordered + padding).shuffled()
                if !padding.isEmpty {
                    print("[MusicService] Easy pool thin (\(famous.count) famous); padded with \(padding.count) known")
                }
            }
        case .medium:
            ordered = interleave(anchors: famous, others: known, maxOthersRun: 2)
            if ordered.count < limit {
                ordered += obscure.prefix(limit - ordered.count)
            }
        case .hard:
            var anchors = known
            if anchors.count * 2 < obscure.count {
                // Not enough knowns to anchor every third slot; promote hits.
                anchors = (anchors + famous).shuffled()
            }
            ordered = interleave(anchors: anchors, others: obscure, maxOthersRun: 2)
        }

        if balanceDecades { ordered = roundRobinByDecade(ordered) }
        return spreadArtists(ordered, limit: min(limit, maxQueueLength))
    }

    /// Deals the queue out decade by decade so "all music" isn't 40% of
    /// whatever is charting now — every era a player might know gets an equal
    /// share of the front of the queue, which is all a game actually reaches.
    private func roundRobinByDecade(_ tracks: [Track]) -> [Track] {
        var buckets: [Int: [Track]] = [:]
        for track in tracks {
            buckets[(track.releaseYear ?? 0) / 10 * 10, default: []].append(track)
        }
        var out: [Track] = []
        out.reserveCapacity(tracks.count)
        while !buckets.isEmpty {
            for decade in buckets.keys.shuffled() {
                guard var bucket = buckets[decade], !bucket.isEmpty else { continue }
                out.append(bucket.removeFirst())
                buckets[decade] = bucket.isEmpty ? nil : bucket
            }
        }
        return out
    }

    /// Keeps one artist from taking over a game: no repeat within `artistGap`
    /// songs and a per-game cap, both enforced by pushing that artist's other
    /// songs later rather than dropping them, so the queue never gets shorter.
    private func spreadArtists(_ tracks: [Track], limit: Int) -> [Track] {
        let cap = max(2, limit / artistShareDivisor)
        var remaining = tracks
        var out: [Track] = []
        var playedAt: [String: Int] = [:]
        var count: [String: Int] = [:]

        while out.count < limit, !remaining.isEmpty {
            let pick = remaining.firstIndex { track in
                let artist = FameDatabase.normalizeArtist(track.artistName)
                if count[artist, default: 0] >= cap { return false }
                if let last = playedAt[artist], out.count - last < artistGap { return false }
                return true
            } ?? 0 // every candidate is capped: take the best one left anyway
            let track = remaining.remove(at: pick)
            let artist = FameDatabase.normalizeArtist(track.artistName)
            playedAt[artist] = out.count
            count[artist, default: 0] += 1
            out.append(track)
        }
        return out
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
    // the same song; key on cleaned title + artist, not track ID. Uses the fame
    // database's normalization, which also folds punctuation and curly quotes —
    // "Sugar, Sugar" and "Sugar Sugar" are one song, and used to be two.
    private func songKey(_ track: Track) -> String {
        FameDatabase.normalizeTitle(track.name) + "|" + FameDatabase.normalizeArtist(track.artistName)
    }

    private func dedupeSongs(_ tracks: [Track]) -> [Track] {
        var ids = Set<String>()
        var artistsByTitle: [String: [String]] = [:]
        var out: [Track] = []
        for track in tracks {
            guard ids.insert(track.id).inserted else { continue }
            let title = FameDatabase.normalizeTitle(track.name)
            let artist = FameDatabase.normalizeArtist(track.artistName)
            guard !title.isEmpty, !artist.isEmpty else { continue }
            // The catalog credits one recording several ways — "Charlie Daniels"
            // and "The Charlie Daniels Band" both carry Devil Went Down to
            // Georgia. Same title and one credit inside the other = same song.
            let seen = artistsByTitle[title] ?? []
            if seen.contains(where: { $0 == artist || $0.contains(artist) || artist.contains($0) }) { continue }
            artistsByTitle[title, default: []].append(artist)
            out.append(track)
        }
        return out
    }

    // MARK: - Pool builders

    /// Current top-of-chart tracks for a genre (chart order preserved; the
    /// caller records ranks for grading).
    private func chartTracks(genre: String?) async -> [Track] {
        let cacheKey = "chart:\(genre ?? "all")"
        if let cached = chartCache[cacheKey] { return cached }

        var tracks: [Track] = []
        var fetched = false
        if useMusicKit {
            do { tracks = try await musicKitChartTracks(genre: genre); fetched = true }
            catch { demoteMusicKit(error) }
        }
        if tracks.isEmpty {
            do { tracks = try await itunesChartTracks(genre: genre); fetched = true }
            catch { print("[MusicService] chart fetch failed for \(genre ?? "all"): \(error)") }
        }
        // Never cache a failure. A rate-limited or dropped request used to be
        // remembered as "this genre has no songs" for the rest of the session,
        // so every later game in the night was built from a smaller pool.
        if fetched { chartCache[cacheKey] = tracks }
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
        var fetched = false
        if useMusicKit {
            do { results = try await musicKitSearchTracks(term: term); fetched = true }
            catch { demoteMusicKit(error) }
        }
        if results.isEmpty {
            do { results = try await itunesSearchTracks(term: term); fetched = true }
            catch { print("[MusicService] decade search failed for \(term): \(error)") }
        }

        guard let range = Self.yearRange(for: decade) else { return [] }
        let filtered = results.filter { track in
            guard let year = track.releaseYear, year >= range.0, year <= range.1 else { return false }
            return matchesGenre(label: track.genreName, genre: genre)
        }
#if DEBUG
        let inYears = results.filter { ($0.releaseYear ?? 0) >= range.0 && ($0.releaseYear ?? 0) <= range.1 }.count
        dlog("search '\(term)': raw \(results.count) → in-decade \(inYears) → genre-match \(filtered.count)")
#endif
        if fetched { searchCache[cacheKey] = filtered }
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
        if decades.isEmpty {
            // "All music" used to fetch no editorial playlists at all, leaving
            // the queue to today's chart plus whatever search turned up — which
            // is why a room with parents in it heard mostly the last few years.
            // Sweep every decade so each era has a bench of real hits.
            hitsSpecs = genres.isEmpty ? Self.allDecades.map { EssentialsSpec(genre: nil, decade: $0) } : []
        }
        var genreSpecs: [EssentialsSpec] = []
        for genre in genres {
            if decades.isEmpty {
                genreSpecs.append(EssentialsSpec(genre: genre, decade: nil))
            } else {
                genreSpecs += decades.map { EssentialsSpec(genre: genre, decade: $0) }
            }
        }

        let specs = (hitsSpecs + genreSpecs.shuffled()).prefix(max(essentialsBudget, hitsSpecs.count))
        var collected: [Track] = []
#if DEBUG
        dlog("essentials specs: \(specs.map { "\($0.genre ?? "Hits")/\($0.decade ?? "all")" }) (of \(hitsSpecs.count + genreSpecs.count))")
#endif
        for spec in specs {
            var tracks = await essentialsPlaylistTracks(spec)
#if DEBUG
            let rawCount = tracks.count
#endif
            if let decade = spec.decade {
                tracks = filterByDecades(tracks, decades: [decade])
            }
#if DEBUG
            let decadeCount = tracks.count
#endif
            if spec.genre == nil && !genres.isEmpty {
                // Cross-genre hits playlist inside a genre-filtered game: keep
                // only tracks whose label matches some selected genre.
                tracks = tracks.filter { track in genres.contains { matchesGenre(label: track.genreName, genre: $0) } }
            }
#if DEBUG
            dlog("essentials \(spec.genre ?? "Hits")/\(spec.decade ?? "all"): raw \(rawCount) → in-decade \(decadeCount) → genre-match \(tracks.count)")
#endif
            for (index, track) in tracks.enumerated() {
                let key = songKey(track)
                if spec.genre == nil {
                    context.hitsEssentials.insert(key)
                } else {
                    context.genreEssentials[key] = min(index, context.genreEssentials[key] ?? Int.max)
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
        if !tracks.isEmpty { essentialsCache[cacheKey] = tracks }
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
            // Exact name match only. "contains" also accepted "'60s Italian Pop
            // Essentials" and "K-Pop Essentials", which is how Italian pop
            // turned up in a US 60s/70s rock game.
            let wanted = compact((decadeToken ?? "") + subject + "Essentials")
            let playlist = response.playlists.first { playlist in
                guard (playlist.curatorName ?? "").lowercased().hasPrefix("apple music") else { return false }
                return compact(playlist.name) == wanted
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
                || context.genreEssentials[key] != nil
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
        if !tracks.isEmpty { albumCache[albumId] = tracks }
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
#if DEBUG
        if debugForceITunes { return false }
#endif
        return !musicKitOffForBuild && MusicAuthorization.currentStatus == .authorized
    }
#if DEBUG
    private var debugForceITunes = false
#endif

    /// Triggers the one-time system prompt. Any outcome other than .authorized
    /// simply leaves the iTunes fallback serving. Retried on every queue build:
    /// a developer token that fails once (no network at launch) must not cost
    /// the player the full catalog for the rest of the night.
    private func ensureMusicKitAuthorization() async {
        guard MusicAuthorization.currentStatus == .notDetermined else { return }
        // Apple's dialog is all-or-nothing ("music and video activity", "media
        // library") even though we only read the public catalog. Don't show it
        // unless MusicKit can actually serve: while the MusicKit app service
        // isn't enabled for this App ID, the developer token fails and every
        // request would 401 into the iTunes fallback anyway.
        do {
            _ = try await DefaultMusicTokenProvider().developerToken(options: [])
        } catch {
            // A failed token can stick in the cache; force one fresh attempt
            // before writing the catalog off for this build.
            if (try? await DefaultMusicTokenProvider().developerToken(options: .ignoreCache)) != nil {
                _ = await MusicAuthorization.request()
                return
            }
            // Surfaced in the setup screen so a tester can report the real
            // reason instead of just seeing a thin, odd-looking setlist.
            catalogNote = "Apple Music catalog unavailable on this device (\(error.localizedDescription))."
            print("[MusicService] developer token failed: \(error)")
            demoteMusicKit(error)
            return
        }
        let status = await MusicAuthorization.request()
        if status != .authorized {
            print("[MusicService] Apple Music access not granted (\(status)); using iTunes catalog")
        }
    }

    private var genreCache: [Int: Genre] = [:]

    /// Counts MusicKit failures within one queue build. A couple of dropped
    /// requests are normal on party wifi and are simply retried next build;
    /// only a build that keeps failing switches to iTunes, and only for itself.
    private func demoteMusicKit(_ error: Error) {
        musicKitFailures += 1
        guard !musicKitOffForBuild else { return }
        print("[MusicService] MusicKit request failed (\(musicKitFailures)): \(error)")
        if musicKitFailures >= 3 {
            musicKitOffForBuild = true
            print("[MusicService] MusicKit failing repeatedly; using iTunes for this queue only")
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
            genreName: song.genreNames.first,
            isExplicit: song.contentRating == .explicit
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
            genreName: r["primaryGenreName"] as? String,
            isExplicit: (r["trackExplicitness"] as? String) == "explicit"
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
