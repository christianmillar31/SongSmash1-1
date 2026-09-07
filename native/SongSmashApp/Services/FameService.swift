import Foundation

// MARK: - Fame grading
// How recognizable a song is to a room of players. Grades come from layered
// signals (bundled chart history, Apple editorial playlists, artist top songs,
// current charts, Deezer rank) and drive difficulty tiers: easy queues serve
// famous songs, hard queues serve obscure ones anchored by known ones.
enum FameGrade: Int, Comparable {
    case obscure = 0
    case known = 1
    case famous = 2

    static func < (lhs: FameGrade, rhs: FameGrade) -> Bool { lhs.rawValue < rhs.rawValue }
}

// MARK: - Offline fame database
// Bundled fame.tsv: one row per unique song from 68 years of weekly US
// singles-chart history (32.5k songs, ~1.2 MB). Regenerate with
// native/tools/generate-fame-db.py — its normalization MUST stay in lockstep
// with normalizeTitle/normalizeArtist below, because lookups work by
// recomputing the same normalization on Apple catalog metadata.
struct FameRecord {
    let peak: Int      // best chart position ever (1 = #1)
    let weeks: Int     // most weeks on the chart in a run
    let year: Int      // first year it charted

    var grade: FameGrade {
        if peak <= 10 || (peak <= 30 && weeks >= 20) { return .famous }
        if peak <= 40 || weeks >= 15 { return .known }
        return .obscure // charted, but briefly and low — still a deep cut to most rooms
    }
}

final class FameDatabase {
    static let shared = FameDatabase()

    private var byTitleArtist: [String: FameRecord] = [:]
    private var byTitle: [String: [(artist: String, record: FameRecord)]] = [:]
    private var loaded = false

    /// Parses the bundled TSV on first use (~50ms, done once).
    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        // FAME_TSV_PATH lets the command-line test harness run without an app bundle.
        let url = ProcessInfo.processInfo.environment["FAME_TSV_PATH"].map { URL(fileURLWithPath: $0) }
            ?? Bundle.main.url(forResource: "fame", withExtension: "tsv")
        guard let url, let text = try? String(contentsOf: url, encoding: .utf8) else {
            print("[FameDatabase] fame.tsv missing from bundle; offline grading disabled")
            return
        }
        for line in text.split(separator: "\n") {
            guard !line.hasPrefix("#") else { continue }
            let cols = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard cols.count == 5,
                  let peak = Int(cols[2]), let weeks = Int(cols[3]), let year = Int(cols[4]) else { continue }
            let title = String(cols[0])
            let artist = String(cols[1])
            let record = FameRecord(peak: peak, weeks: weeks, year: year)
            byTitleArtist["\(title)|\(artist)"] = record
            byTitle[title, default: []].append((artist, record))
        }
        print("[FameDatabase] loaded \(byTitleArtist.count) songs")
    }

    func lookup(title: String, artist: String) -> FameRecord? {
        loadIfNeeded()
        let t = Self.normalizeTitle(title)
        let a = Self.normalizeArtist(artist)
        guard !t.isEmpty, !a.isEmpty else { return nil }
        if let hit = byTitleArtist["\(t)|\(a)"] { return hit }
        // Fallback for artist-credit drift ("Prince" vs "Prince and The
        // Revolution"): same title, and one artist string contains the other.
        // Ambiguous covers (multiple containment matches) are rejected.
        let candidates = (byTitle[t] ?? []).filter { $0.artist.contains(a) || a.contains($0.artist) }
        return candidates.count == 1 ? candidates[0].record : nil
    }

    // MARK: Normalization (mirrors generate-fame-db.py exactly)

    private static let titleCuts = [" (", " [", " - ", "/"]
    private static let artistCuts = [" featuring ", " feat. ", " feat ", " ft. ", " ft ", " with ",
                                     " duet with ", " and ", " & ", ", ", " x ", " + "]
    private static let keptCharacters = Set("abcdefghijklmnopqrstuvwxyz0123456789 ")

    static func normalizeTitle(_ s: String) -> String {
        stripPunctuation(cutAtFirst(fold(s), separators: titleCuts))
    }

    static func normalizeArtist(_ s: String) -> String {
        var a = cutAtFirst(fold(s), separators: artistCuts)
        if a.hasPrefix("the ") { a = String(a.dropFirst(4)) }
        return stripPunctuation(a)
    }

    private static func fold(_ s: String) -> String {
        s.folding(options: [.diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
    }

    private static func cutAtFirst(_ s: String, separators: [String]) -> String {
        var cut = s.endIndex
        for separator in separators {
            if let range = s.range(of: separator), range.lowerBound > s.startIndex, range.lowerBound < cut {
                cut = range.lowerBound
            }
        }
        return String(s[..<cut])
    }

    private static func stripPunctuation(_ s: String) -> String {
        let replaced = s.replacingOccurrences(of: "&", with: " and ")
        let kept = String(replaced.filter { keptCharacters.contains($0) })
        return kept.split(separator: " ").joined(separator: " ")
    }
}

// MARK: - Deezer rank fallback
// Keyless public API; `rank` is a 0–1M popularity score that is comparable
// across eras (a 1985 mega-hit and today's #1 both sit near 1M). Used only to
// upgrade songs the offline database and Apple signals couldn't grade —
// famous album cuts and international hits that never charted in the US.
// Results are cached on disk forever, so repeat games cost no requests, and
// any network failure just leaves the local grade standing.
final class DeezerRankService {
    static let shared = DeezerRankService()

    static let famousThreshold = 800_000
    static let knownThreshold = 450_000

    private var cache: [String: Int] = [:]  // normalized "title|artist" -> rank (0 = looked up, not found)
    private var cacheLoaded = false
    private var cacheDirty = false

    private var cacheURL: URL? {
        guard let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        else { return nil }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("deezer-rank-cache.json")
    }

    private func loadCacheIfNeeded() {
        guard !cacheLoaded else { return }
        cacheLoaded = true
        guard let url = cacheURL, let data = try? Data(contentsOf: url),
              let stored = try? JSONDecoder().decode([String: Int].self, from: data) else { return }
        cache = stored
    }

    func persistCache() {
        guard cacheDirty, let url = cacheURL, let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
        cacheDirty = false
    }

    func grade(forRank rank: Int) -> FameGrade {
        if rank >= Self.famousThreshold { return .famous }
        if rank >= Self.knownThreshold { return .known }
        return .obscure
    }

    /// Highest Deezer rank for the song, or nil when unknown (miss or offline).
    func rank(title: String, artist: String) async -> Int? {
        loadCacheIfNeeded()
        let t = FameDatabase.normalizeTitle(title)
        let a = FameDatabase.normalizeArtist(artist)
        guard !t.isEmpty, !a.isEmpty else { return nil }
        let key = "\(t)|\(a)"
        if let cached = cache[key] { return cached > 0 ? cached : nil }

        let query = "artist:\"\(artist)\" track:\"\(title)\""
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://api.deezer.com/search?q=\(encoded)&limit=5") else { return nil }
        do {
            var request = URLRequest(url: url)
            request.timeoutInterval = 6
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            let results = try JSONDecoder().decode(DeezerSearchResponse.self, from: data).data
            // Only trust results that are actually the same song.
            let rank = results
                .filter {
                    FameDatabase.normalizeTitle($0.title) == t
                        && FameDatabase.normalizeArtist($0.artist.name) == a
                }
                .map(\.rank)
                .max()
            cache[key] = rank ?? 0  // negative-cache real misses, never network errors
            cacheDirty = true
            return rank
        } catch {
            return nil
        }
    }

    private struct DeezerSearchResponse: Decodable {
        struct Entry: Decodable {
            struct Artist: Decodable { let name: String }
            let title: String
            let rank: Int
            let artist: Artist
        }
        let data: [Entry]
    }
}
