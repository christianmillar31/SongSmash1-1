import Foundation

// MARK: - Apple Music developer token
// The game reads Apple's catalog through the Apple Music web API, which needs
// only a developer token — never anything from the player. MusicKit's own
// request types refused to run until the player accepted the "media library"
// prompt, so anyone who declined it, or whose phone had Screen Time limits,
// silently got the small iTunes catalog.
//
// The token is a JWT signed on the developer's Mac with the Media Services key
// (native/tools/mint-music-token.py) and published on the project's GitHub
// Pages site. Apple caps a token's life at six months; serving it from Pages
// means renewing it is a commit, not an app update. Publishing it is normal:
// Apple's own web player embeds the same kind of token in page source, and
// the private key never leaves the developer's machine.
actor AppleMusicToken {
    static let shared = AppleMusicToken()

    private static let source = URL(string: "https://christianmillar31.github.io/SongSmash1-1/music-token.txt")!
    private static let cacheKey = "AppleMusicDeveloperToken"

    private var token: String?

    /// A usable token, or nil when none can be had (offline, or the published
    /// one has expired) — callers then fall back to the iTunes catalog.
    func current() async -> String? {
#if DEBUG
        // Lets the simulator run against a freshly minted token before it is
        // published: -DebugMusicToken <jwt>
        if let debug = UserDefaults.standard.string(forKey: "DebugMusicToken"), !debug.isEmpty {
            return debug
        }
#endif
        if let token, !Self.isExpiring(token) { return token }
        if let cached = UserDefaults.standard.string(forKey: Self.cacheKey), !Self.isExpiring(cached) {
            token = cached
            return cached
        }
        guard let fetched = await fetch() else { return nil }
        token = fetched
        UserDefaults.standard.set(fetched, forKey: Self.cacheKey)
        return fetched
    }

    /// Forget the token after the API rejects it (revoked key, rotated token),
    /// so the next queue build fetches the published one again.
    func invalidate() {
        token = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    private func fetch() async -> String? {
        let request = URLRequest(url: Self.source, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 8)
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !text.isEmpty, !Self.isExpiring(text) else {
            print("[AppleMusicToken] couldn't load a valid token from \(Self.source)")
            return nil
        }
        return text
    }

    /// True when the JWT's `exp` is less than a day away (or unreadable), so a
    /// game never starts on a token that dies mid-setlist.
    static func isExpiring(_ jwt: String) -> Bool {
        let parts = jwt.split(separator: ".")
        guard parts.count == 3 else { return true }
        var payload = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while payload.count % 4 != 0 { payload += "=" }
        guard let data = Data(base64Encoded: payload),
              let claims = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = claims["exp"] as? Double else { return true }
        return Date(timeIntervalSince1970: exp) < Date().addingTimeInterval(24 * 60 * 60)
    }
}
