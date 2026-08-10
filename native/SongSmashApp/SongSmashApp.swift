import SwiftUI
import UIKit
import AVFoundation
import Network
import Combine

// MARK: - App Main
@main
struct SongSmashApp: App {
    @StateObject private var playerManager = PlayerManager()
    @StateObject private var gameManager = GameManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(playerManager)
                .environmentObject(gameManager)
                .preferredColorScheme(.dark)
        }
    }
}

// MARK: - Design System
// Glass-first: hierarchy comes from depth (ambient background → content glass →
// floating controls), not from decoration. Radii are concentric; motion is springs.
struct DesignSystem {
    static let spacing = (
        xs: 4.0,
        sm: 8.0,
        md: 16.0,
        lg: 24.0,
        xl: 32.0
    )

    static let radius = (
        card: 28.0,
        control: 20.0,
        chip: 14.0
    )

    static let animation = Animation.spring(response: 0.4, dampingFraction: 0.8)
    static let snappy = Animation.spring(response: 0.3, dampingFraction: 0.65)

    static let colors = (
        primary: Color(red: 0.20, green: 0.84, blue: 0.44),
        danger: Color(red: 1.0, green: 0.27, blue: 0.23),
        warning: Color(red: 1.0, green: 0.62, blue: 0.04),
        background: Color(red: 0.04, green: 0.04, blue: 0.06)
    )
}

// MARK: - Haptics
enum Haptics {
    static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    static func score() { UIImpactFeedbackGenerator(style: .medium).impactOccurred() }
    static func reveal() { UIImpactFeedbackGenerator(style: .heavy).impactOccurred() }
    static func celebrate() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
}

// MARK: - Models
struct Team: Identifiable {
    let id = UUID()
    var name: String
    var score: Int = 0
    var colorName: String

    var color: Color {
        switch colorName {
        case "red": return .red
        case "blue": return .blue
        case "green": return .green
        case "orange": return .orange
        case "purple": return .purple
        case "pink": return .pink
        case "yellow": return .yellow
        case "cyan": return .cyan
        case "indigo": return .indigo
        default: return .blue
        }
    }

    // Scoreboard shorthand: one initial per word — "Busy Bella" → "BB",
    // "Mithil" → "M". Capped at three letters.
    var initials: String {
        name.split(separator: " ").prefix(3).compactMap { $0.first }.map(String.init).joined().uppercased()
    }

    init(name: String, colorName: String) {
        self.name = name
        self.colorName = colorName
        self.score = 0
    }
}

struct GameSettings {
    var genres: [String] = []
    var decades: [String] = []
    var difficulty: Difficulty = .medium
    var targetScore: Int = 25
    var teams: [Team] = []
}

enum Difficulty: String, CaseIterable {
    case easy = "Easy"
    case medium = "Medium"
    case hard = "Hard"

    var description: String {
        switch self {
        case .easy: return "Popular hits everyone knows"
        case .medium: return "Mix of hits and deeper cuts"
        case .hard: return "Challenge your music knowledge"
        }
    }
}

struct Round: Identifiable {
    let id = UUID()
    let songTitle: String
    let artist: String
    var scoredTeams: Set<UUID> = []
    var correctTitle: Bool = false
    var correctArtist: Bool = false
}


// MARK: - Player Manager
// Plays 30-second preview URLs from Apple's catalog via AVPlayer.
class PlayerManager: NSObject, ObservableObject {
    @Published var currentTrack: Track?
    @Published var isPlaying = false
    @Published var remainingSeconds = 30

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?
    private var timeObserver: Any?

    override init() {
        super.init()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
    }

    func playSong(_ track: Track, completion: @escaping (Bool) -> Void) {
        guard let urlString = track.previewUrl, let url = URL(string: urlString) else {
            completion(false)
            return
        }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        detachTimeObserver()
        let item = AVPlayerItem(url: url)
        player = AVPlayer(playerItem: item)
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: item, queue: .main
        ) { [weak self] _ in
            self?.isPlaying = false
        }
        player?.play()
        currentTrack = track
        isPlaying = true
        remainingSeconds = 30
        attachTimeObserver()
        completion(true)
    }

    func pausePlayback() {
        player?.pause()
        isPlaying = false
    }

    func resumePlayback() {
        player?.play()
        isPlaying = true
    }

    func stopPlayback() {
        detachTimeObserver()
        player?.pause()
        player = nil
        currentTrack = nil
        isPlaying = false
        remainingSeconds = 30
    }

    // Drives the big on-screen countdown while a preview plays.
    private func attachTimeObserver() {
        guard let player else { return }
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self, let item = self.player?.currentItem else { return }
            let duration = item.duration.seconds
            guard duration.isFinite, duration > 0 else { return }
            self.remainingSeconds = max(0, Int((duration - time.seconds).rounded()))
        }
    }

    private func detachTimeObserver() {
        if let timeObserver, let player {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }
}

// Snapshot of the setup that survives app relaunches, so a returning game
// night doesn't have to re-enter teams and settings. Scores are not saved.
private struct SavedSetup: Codable {
    struct SavedTeam: Codable {
        var name: String
        var colorName: String
    }

    var teams: [SavedTeam]
    var genres: [String]
    var decades: [String]
    var difficulty: String
    var targetScore: Int

    private static let key = "SavedGameSetup"

    static func save(_ settings: GameSettings) {
        let snapshot = SavedSetup(
            teams: settings.teams.map { SavedTeam(name: $0.name, colorName: $0.colorName) },
            genres: settings.genres,
            decades: settings.decades,
            difficulty: settings.difficulty.rawValue,
            targetScore: settings.targetScore
        )
        if let data = try? JSONEncoder().encode(snapshot) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    static func restore() -> GameSettings? {
        guard let data = UserDefaults.standard.data(forKey: key),
              let snapshot = try? JSONDecoder().decode(SavedSetup.self, from: data) else { return nil }
        var settings = GameSettings()
        settings.teams = snapshot.teams.map { Team(name: $0.name, colorName: $0.colorName) }
        settings.genres = snapshot.genres
        settings.decades = snapshot.decades
        settings.difficulty = Difficulty(rawValue: snapshot.difficulty) ?? .medium
        settings.targetScore = snapshot.targetScore
        return settings
    }
}

// MARK: - Game Manager
class GameManager: ObservableObject {
    @Published var gameSettings = GameSettings()
    @Published var currentRound: Round?
    @Published var rounds: [Round] = []
    @Published var gameState: GameState = .setup
    @Published var showAnswer = false
    @Published var availableTracks: [Track] = []
    @Published var isLoadingTracks = false
    @Published var loadError: String?

    private var cancellables = Set<AnyCancellable>()

    enum GameState {
        case setup, playing, paused, finished
    }

    init() {
        if let saved = SavedSetup.restore() {
            gameSettings = saved
        }
        $gameSettings
            .dropFirst()
            .sink { SavedSetup.save($0) }
            .store(in: &cancellables)
    }

    var currentRoundNumber: Int {
        rounds.count + 1
    }

    var leadingScore: Int {
        gameSettings.teams.map(\.score).max() ?? 0
    }

    var progress: Double {
        guard gameSettings.targetScore > 0 else { return 0 }
        return min(1.0, Double(leadingScore) / Double(gameSettings.targetScore))
    }

    var hasReachedTargetScore: Bool {
        leadingScore >= gameSettings.targetScore
    }

    func startGame() {
        gameState = .playing
        rounds = []
        currentRound = nil
        showAnswer = false
        resetScores()
    }

    func resetScores() {
        for i in 0..<gameSettings.teams.count {
            gameSettings.teams[i].score = 0
        }
    }

    func scoreTeam(_ team: Team, titleCorrect: Bool, artistCorrect: Bool) {
        guard let index = gameSettings.teams.firstIndex(where: { $0.id == team.id }) else { return }

        var points = 0
        if titleCorrect { points += 1 }
        if artistCorrect { points += 1 }

        gameSettings.teams[index].score += points

        if titleCorrect {
            currentRound?.correctTitle = true
        }
        if artistCorrect {
            currentRound?.correctArtist = true
        }

        currentRound?.scoredTeams.insert(team.id)
    }

    func nextRound(title: String, artist: String) {
        if let current = currentRound {
            rounds.append(current)
        }
        currentRound = Round(songTitle: title, artist: artist)
        showAnswer = false
    }

    func endGame() {
        if let current = currentRound {
            rounds.append(current)
            currentRound = nil
        }
        print("Game ended after \(rounds.count) rounds, leading score \(leadingScore) of \(gameSettings.targetScore)")
        gameState = .finished
    }

    var winner: Team? {
        gameSettings.teams.max(by: { $0.score < $1.score })
    }

    @MainActor
    func loadTracks() async {
        isLoadingTracks = true
        loadError = nil
        do {
            availableTracks = try await MusicService.shared.loadTracks(
                genres: gameSettings.genres,
                decades: gameSettings.decades,
                difficulty: gameSettings.difficulty
            )
            print("Loaded \(availableTracks.count) tracks for game")
            if availableTracks.isEmpty {
                loadError = "No playable songs found for that mix. Try different genres or decades."
            }
        } catch {
            print("Error loading tracks: \(error)")
            loadError = "Couldn't build your setlist. Check your connection and try again."
        }
        isLoadingTracks = false
    }
}


// MARK: - Network Monitor
class NetworkMonitor: ObservableObject {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "NetworkMonitor")
    @Published var isConnected = true

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async {
                self?.isConnected = path.status == .satisfied
            }
        }
        monitor.start(queue: queue)
    }
}

// MARK: - Ambient Background
// The bottom layer of the depth stack: near-black with the current teams'
// colors bleeding through as blurred light. Every game night gets its own glow.
struct AmbientBackground: View {
    var teamColors: [Color]

    var body: some View {
        ZStack {
            DesignSystem.colors.background
            GeometryReader { geo in
                let colors = teamColors.isEmpty
                    ? [Color.blue, DesignSystem.colors.primary]
                    : teamColors
                ForEach(Array(colors.prefix(4).enumerated()), id: \.offset) { index, color in
                    Circle()
                        .fill(color)
                        .frame(width: geo.size.width * 1.2, height: geo.size.width * 1.2)
                        .position(bloomPosition(index, in: geo.size))
                        .blur(radius: 110)
                        .opacity(0.18)
                }
            }
        }
        .ignoresSafeArea()
    }

    private func bloomPosition(_ index: Int, in size: CGSize) -> CGPoint {
        switch index {
        case 0: return CGPoint(x: size.width * 0.10, y: size.height * 0.05)
        case 1: return CGPoint(x: size.width * 0.95, y: size.height * 0.90)
        case 2: return CGPoint(x: size.width * 0.95, y: size.height * 0.15)
        default: return CGPoint(x: size.width * 0.05, y: size.height * 0.85)
        }
    }
}

// MARK: - Reusable Components
// Wraps chips onto as many rows as they need.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > width, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width.isFinite ? width : x, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// Arcade-weight action button: solid green, black caps, hard under-shadow.
struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true
    var isLoading: Bool = false

    var body: some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            HStack(spacing: DesignSystem.spacing.sm) {
                if isLoading {
                    ProgressView()
                        .tint(.black)
                }
                Text(title.uppercased())
                    .font(.headline.weight(.black))
                    .tracking(1)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
            }
            .foregroundColor(isEnabled ? .black : .white.opacity(0.35))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                        .fill(isEnabled ? Color(red: 0.10, green: 0.52, blue: 0.26) : Color.white.opacity(0.04))
                        .offset(y: 5)
                    RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                        .fill(isEnabled ? DesignSystem.colors.primary : Color.white.opacity(0.08))
                }
            )
            .shadow(color: isEnabled ? DesignSystem.colors.primary.opacity(0.35) : .clear, radius: 16, y: 8)
        }
        .buttonStyle(PressableButtonStyle())
        .disabled(!isEnabled || isLoading)
        .animation(DesignSystem.animation, value: isEnabled)
    }
}

struct PressableButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(DesignSystem.snappy, value: configuration.isPressed)
    }
}

// Deterministic falling confetti drawn on a Canvas — no per-particle state.
struct ConfettiView: View {
    var colors: [Color] = [.blue, .pink, DesignSystem.colors.primary, .yellow, .orange, .purple]
    private let start = Date()

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let t = timeline.date.timeIntervalSince(start)
                for i in 0..<70 {
                    let seed = Double(i)
                    let x = (seed * 73.13).truncatingRemainder(dividingBy: 1.0) * size.width
                    let speed = 90.0 + (seed * 37.7).truncatingRemainder(dividingBy: 1.0) * 150.0
                    let y = (t * speed + seed * 97.0)
                        .truncatingRemainder(dividingBy: Double(size.height) + 40.0) - 20.0
                    let sway = sin(t * 2.0 + seed) * 14.0

                    var ctx = context
                    ctx.translateBy(x: x + sway, y: y)
                    ctx.rotate(by: .degrees(t * 140.0 + seed * 41.0))
                    ctx.fill(
                        Path(CGRect(x: -3, y: -5, width: 6, height: 10)),
                        with: .color(colors[i % colors.count].opacity(0.9))
                    )
                }
            }
        }
        .allowsHitTesting(false)
        .ignoresSafeArea()
    }
}

// Full-height equalizer — on the Play screen the brand mark IS the interface.
// Five wide bars rise from the bottom and bounce while the preview plays.
struct StadiumEqualizer: View {
    var isPlaying: Bool
    @State private var animating = false

    private let tall: [CGFloat] = [0.62, 0.82, 1.0, 0.72, 0.55]
    private let short: [CGFloat] = [0.30, 0.45, 0.58, 0.38, 0.26]

    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .bottom, spacing: geo.size.width * 0.045) {
                ForEach(0..<5, id: \.self) { index in
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [DesignSystem.colors.primary, DesignSystem.colors.primary.opacity(0.30)],
                                startPoint: .top, endPoint: .bottom
                            )
                        )
                        .frame(height: geo.size.height * (animating ? tall[index] : short[index]))
                        .animation(
                            isPlaying
                                ? .easeInOut(duration: 0.5).repeatForever(autoreverses: true).delay(Double(index) * 0.11)
                                : DesignSystem.animation,
                            value: animating
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        }
        .opacity(isPlaying ? 1 : 0.45)
        .onAppear { animating = isPlaying }
        .onChange(of: isPlaying) { playing in
            animating = playing
        }
    }
}

// Tiny static five-bar mark, used where the equalizer is a signature, not a hero.
struct EqualizerGlyph: View {
    private let heights: [CGFloat] = [14, 22, 30, 18, 12]

    var body: some View {
        HStack(alignment: .bottom, spacing: 4) {
            ForEach(0..<5, id: \.self) { index in
                Capsule()
                    .frame(width: 6, height: heights[index])
            }
        }
    }
}

// MARK: - Main Views
struct ContentView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var gameManager: GameManager
    @StateObject private var networkMonitor = NetworkMonitor()

    var body: some View {
        ZStack {
            AmbientBackground(teamColors: gameManager.gameSettings.teams.map(\.color))

            Group {
                if !networkMonitor.isConnected {
                    NetworkRequiredView()
                } else {
                    switch gameManager.gameState {
                    case .setup:
                        GameSetupView()
                    case .playing, .paused:
                        GamePlayView()
                    case .finished:
                        GameFinishedView()
                    }
                }
            }
        }
        .animation(DesignSystem.animation, value: gameManager.gameState)
        .onAppear {
#if DEBUG
            // Dev shortcut: `-AutoDemo YES` launch argument seeds a demo game and
            // exercises the real discovery + playback path without any taps.
            if UserDefaults.standard.bool(forKey: "AutoDemo"), gameManager.gameSettings.teams.isEmpty {
                gameManager.gameSettings.teams = [
                    Team(name: "The Bears", colorName: "blue"),
                    Team(name: "The Sharks", colorName: "pink")
                ]
                gameManager.gameSettings.genres = ["Rock"]
                gameManager.gameSettings.decades = ["1980s"]
                if UserDefaults.standard.string(forKey: "DemoGenres") == "none" {
                    gameManager.gameSettings.genres = []
                    gameManager.gameSettings.decades = []
                }
                switch UserDefaults.standard.string(forKey: "AutoDemoState") {
                case "setup":
                    break // seeded settings only; stay on the setup screen
                case "finished":
                    gameManager.gameSettings.teams[0].score = 12
                    gameManager.gameSettings.teams[1].score = 9
                    gameManager.gameState = .finished
                default:
                    Task {
                        await gameManager.loadTracks()
                        gameManager.startGame()
                        if let firstTrack = gameManager.availableTracks.first {
                            MusicService.shared.markTrackAsPlayed(firstTrack)
                            playerManager.playSong(firstTrack) { success in
                                if success {
                                    gameManager.nextRound(title: firstTrack.name, artist: firstTrack.artistName)
                                    if UserDefaults.standard.string(forKey: "AutoDemoState") == "revealed" {
                                        gameManager.showAnswer = true
                                    }
                                }
                            }
                        }
                    }
                }
            }
#endif
        }
    }
}

// MARK: - Network Required View
struct NetworkRequiredView: View {
    var body: some View {
        VStack(spacing: DesignSystem.spacing.lg) {
            Spacer()

            Image(systemName: "wifi.slash")
                .font(.system(size: 72))
                .foregroundColor(DesignSystem.colors.danger)
                .padding(.bottom, DesignSystem.spacing.md)

            Text("Internet Connection Required")
                .font(.title.bold())
                .multilineTextAlignment(.center)

            Text("SongSmash needs an internet connection to stream song previews. Please connect and try again.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, DesignSystem.spacing.xl)

            Spacer()
        }
        .padding()
    }
}

// MARK: - Game Setup View
// Stadium style: no cards — sections sit right on the dark canvas, every
// selected state is solid green, and controls are sized for a party.
struct GameSetupView: View {
    @EnvironmentObject var gameManager: GameManager
    @EnvironmentObject var playerManager: PlayerManager
    @State private var showingTeamSetup = UserDefaults.standard.bool(forKey: "ShowTeamSetup")
    @State private var showingMusicSheet = false
    @State private var editingTeam: Team?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DesignSystem.spacing.lg) {
                Text("NEW GAME")
                    .font(.system(size: 38, weight: .black, design: .rounded))
                    .padding(.top, DesignSystem.spacing.md)

                teamsSection
                musicSection
                difficultySection
                targetScoreSection

                if let error = gameManager.loadError {
                    errorBox(error)
                }

                PrimaryButton(
                    title: gameManager.isLoadingTracks ? "Building your setlist…" : "Start",
                    action: startGame,
                    isEnabled: gameManager.gameSettings.teams.count >= 2,
                    isLoading: gameManager.isLoadingTracks
                )
                .padding(.top, DesignSystem.spacing.sm)
            }
            .padding(.horizontal, DesignSystem.spacing.lg)
            .padding(.bottom, DesignSystem.spacing.xl)
        }
        .sheet(isPresented: $showingTeamSetup) {
            TeamSetupView()
        }
        .sheet(item: $editingTeam) { team in
            TeamSetupView(teamToEdit: team)
        }
        .sheet(isPresented: $showingMusicSheet) {
            MusicSelectionSheet()
        }
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.heavy))
            .tracking(2)
            .foregroundColor(.secondary)
    }

    private var teamsSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
            sectionLabel("TEAMS")

            ForEach(gameManager.gameSettings.teams) { team in
                ZStack(alignment: .trailing) {
                    Button(action: {
                        Haptics.tap()
                        editingTeam = team
                    }) {
                        HStack {
                            Text(team.name.uppercased())
                                .font(.title3.weight(.black))
                                .foregroundColor(.black)
                                .lineLimit(1)
                                .minimumScaleFactor(0.6)
                            Spacer()
                        }
                        .padding(.horizontal, DesignSystem.spacing.md)
                        .padding(.trailing, 44)
                        .frame(height: 64)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                                .fill(team.color)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())

                    Button(action: {
                        Haptics.tap()
                        withAnimation(DesignSystem.snappy) {
                            gameManager.gameSettings.teams.removeAll { $0.id == team.id }
                        }
                    }) {
                        Image(systemName: "xmark")
                            .font(.subheadline.weight(.black))
                            .foregroundColor(.black.opacity(0.45))
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }

            Button(action: {
                Haptics.tap()
                showingTeamSetup = true
            }) {
                Text("ADD TEAM +")
                    .font(.headline.weight(.heavy))
                    .tracking(1)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6, 5]))
                            .foregroundColor(.white.opacity(0.25))
                    )
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    // The mix reads as one line ("ROCK · 1980s"); the chips live in a sheet.
    private var musicSection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
            sectionLabel("MUSIC")

            Button(action: {
                Haptics.tap()
                showingMusicSheet = true
            }) {
                HStack {
                    Text(musicSummary)
                        .font(.headline.weight(.heavy))
                        .tracking(1)
                        .foregroundColor(hasMusicFilters ? DesignSystem.colors.primary : .white)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.subheadline.weight(.black))
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, DesignSystem.spacing.md)
                .frame(height: 56)
                .background(
                    RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
            }
            .buttonStyle(PressableButtonStyle())
        }
    }

    private var hasMusicFilters: Bool {
        !gameManager.gameSettings.genres.isEmpty || !gameManager.gameSettings.decades.isEmpty
    }

    private var musicSummary: String {
        let items = gameManager.gameSettings.genres.map { $0.uppercased() } + gameManager.gameSettings.decades
        if items.isEmpty { return "ALL MUSIC" }
        if items.count > 4 {
            return items.prefix(3).joined(separator: " · ") + " +\(items.count - 3)"
        }
        return items.joined(separator: " · ")
    }

    private var difficultySection: some View {
        VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
            sectionLabel("DIFFICULTY")

            HStack(spacing: DesignSystem.spacing.sm) {
                ForEach(Difficulty.allCases, id: \.self) { difficulty in
                    let isOn = gameManager.gameSettings.difficulty == difficulty
                    Button(action: {
                        Haptics.tap()
                        withAnimation(DesignSystem.snappy) {
                            gameManager.gameSettings.difficulty = difficulty
                        }
                    }) {
                        Text(difficulty.rawValue.uppercased())
                            .font(.subheadline.weight(.heavy))
                            .foregroundColor(isOn ? .black : .white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(isOn ? DesignSystem.colors.primary : Color.white.opacity(0.08)))
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    private var targetScoreSection: some View {
        HStack {
            sectionLabel("FIRST TO")
            Spacer()
            HStack(spacing: DesignSystem.spacing.sm) {
                stepperButton(systemName: "minus") {
                    if gameManager.gameSettings.targetScore > 5 {
                        withAnimation(DesignSystem.snappy) {
                            gameManager.gameSettings.targetScore -= 5
                        }
                    }
                }
                Text("\(gameManager.gameSettings.targetScore)")
                    .font(.system(size: 44, weight: .black, design: .rounded))
                    .foregroundColor(DesignSystem.colors.primary)
                    .frame(minWidth: 76)
                    .contentTransition(.numericText())
                stepperButton(systemName: "plus") {
                    if gameManager.gameSettings.targetScore < 100 {
                        withAnimation(DesignSystem.snappy) {
                            gameManager.gameSettings.targetScore += 5
                        }
                    }
                }
            }
        }
    }

    private func stepperButton(systemName: String, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.tap()
            action()
        }) {
            Image(systemName: systemName)
                .font(.body.weight(.black))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundColor(.primary)
    }

    private func errorBox(_ message: String) -> some View {
        HStack(spacing: DesignSystem.spacing.md) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.black)
            Text(message)
                .font(.subheadline.weight(.semibold))
                .foregroundColor(.black)
        }
        .padding(DesignSystem.spacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                .fill(DesignSystem.colors.warning)
        )
    }

    private func startGame() {
        Task {
            await gameManager.loadTracks()
            guard let firstTrack = gameManager.availableTracks.first else { return }
            gameManager.startGame()
            MusicService.shared.markTrackAsPlayed(firstTrack)
            playerManager.playSong(firstTrack) { success in
                if success {
                    gameManager.nextRound(
                        title: firstTrack.name,
                        artist: firstTrack.artistName
                    )
                }
            }
        }
    }
}

// MARK: - Team Setup View
struct TeamSetupView: View {
    @EnvironmentObject var gameManager: GameManager
    @Environment(\.dismiss) var dismiss
    var teamToEdit: Team?
    @State private var teamName: String
    @State private var selectedColorName: String

    init(teamToEdit: Team? = nil) {
        self.teamToEdit = teamToEdit
        _teamName = State(initialValue: teamToEdit?.name ?? "")
        _selectedColorName = State(initialValue: teamToEdit?.colorName ?? "blue")
    }

    let colorOptions: [(name: String, color: Color)] = [
        ("red", .red),
        ("blue", .blue),
        ("green", .green),
        ("orange", .orange),
        ("purple", .purple),
        ("pink", .pink),
        ("yellow", .yellow),
        ("cyan", .cyan),
        ("indigo", .indigo)
    ]

    private var trimmedName: String {
        teamName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: DesignSystem.spacing.lg) {
                // Team Name Input
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Text("TEAM NAME")
                        .font(.footnote.weight(.heavy))
                        .tracking(2)
                        .foregroundColor(.secondary)

                    TextField("Enter team name", text: $teamName)
                        .font(.body)
                        .padding()
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.radius.chip, style: .continuous)
                                .fill(Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.radius.chip, style: .continuous)
                                .strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
                        )
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .onSubmit { saveTeam() }
                }

                // Color Selection
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Text("TEAM COLOR")
                        .font(.footnote.weight(.heavy))
                        .tracking(2)
                        .foregroundColor(.secondary)

                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: DesignSystem.spacing.md) {
                        ForEach(colorOptions, id: \.name) { option in
                            Circle()
                                .fill(option.color)
                                .frame(width: 50, height: 50)
                                .shadow(color: option.color.opacity(selectedColorName == option.name ? 0.6 : 0), radius: 10, y: 3)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: selectedColorName == option.name ? 3 : 0)
                                        .padding(2)
                                )
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.white)
                                        .font(.body.weight(.bold))
                                        .opacity(selectedColorName == option.name ? 1 : 0)
                                )
                                .scaleEffect(selectedColorName == option.name ? 1.08 : 1.0)
                                .onTapGesture {
                                    Haptics.tap()
                                    selectedColorName = option.name
                                }
                                .animation(DesignSystem.snappy, value: selectedColorName)
                        }
                    }
                }

                PrimaryButton(
                    title: teamToEdit == nil ? "Add Team" : "Save Changes",
                    action: { saveTeam() },
                    isEnabled: !trimmedName.isEmpty
                )
                }
                .padding()
            }
            .navigationTitle(teamToEdit == nil ? "Add Team" : "Edit Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationBackground(Color(red: 0.07, green: 0.07, blue: 0.09))
        .presentationDetents([.medium, .large])
    }

    private func saveTeam() {
        guard !trimmedName.isEmpty else { return }
        if let teamToEdit,
           let index = gameManager.gameSettings.teams.firstIndex(where: { $0.id == teamToEdit.id }) {
            gameManager.gameSettings.teams[index].name = trimmedName
            gameManager.gameSettings.teams[index].colorName = selectedColorName
        } else {
            gameManager.gameSettings.teams.append(Team(name: trimmedName, colorName: selectedColorName))
        }
        Haptics.score()
        dismiss()
    }
}

// MARK: - Music Selection Sheet
// The full combinable chip cloud, off the main screen. Nothing selected = all music.
struct MusicSelectionSheet: View {
    @EnvironmentObject var gameManager: GameManager
    @Environment(\.dismiss) var dismiss

    let availableGenres = ["Pop", "Rock", "Hip-Hop", "Country", "R&B", "Electronic", "Jazz", "Classical", "Indie", "Alternative"]
    let availableDecades = ["2020s", "2010s", "2000s", "1990s", "1980s", "1970s", "1960s"]

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: DesignSystem.spacing.lg) {
                    VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                        groupLabel("GENRES")
                        FlowLayout(spacing: DesignSystem.spacing.sm) {
                            ForEach(availableGenres, id: \.self) { genre in
                                chip(genre.uppercased(), isOn: gameManager.gameSettings.genres.contains(genre)) {
                                    if let index = gameManager.gameSettings.genres.firstIndex(of: genre) {
                                        gameManager.gameSettings.genres.remove(at: index)
                                    } else {
                                        gameManager.gameSettings.genres.append(genre)
                                    }
                                }
                            }
                        }
                    }

                    VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                        groupLabel("DECADES")
                        FlowLayout(spacing: DesignSystem.spacing.sm) {
                            ForEach(availableDecades, id: \.self) { decade in
                                chip(decade, isOn: gameManager.gameSettings.decades.contains(decade)) {
                                    if let index = gameManager.gameSettings.decades.firstIndex(of: decade) {
                                        gameManager.gameSettings.decades.remove(at: index)
                                    } else {
                                        gameManager.gameSettings.decades.append(decade)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding()
            }
            .navigationTitle("Music")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Clear") {
                        Haptics.tap()
                        withAnimation(DesignSystem.snappy) {
                            gameManager.gameSettings.genres.removeAll()
                            gameManager.gameSettings.decades.removeAll()
                        }
                    }
                    .disabled(gameManager.gameSettings.genres.isEmpty && gameManager.gameSettings.decades.isEmpty)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .presentationBackground(Color(red: 0.07, green: 0.07, blue: 0.09))
        .presentationDetents([.medium, .large])
    }

    private func groupLabel(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.heavy))
            .tracking(2)
            .foregroundColor(.secondary)
    }

    private func chip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: {
            Haptics.tap()
            withAnimation(DesignSystem.snappy) { action() }
        }) {
            Text(label)
                .font(.subheadline.weight(.heavy))
                .foregroundColor(isOn ? .black : .white)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Capsule().fill(isOn ? DesignSystem.colors.primary : Color.white.opacity(0.08)))
        }
        .buttonStyle(PressableButtonStyle())
    }
}

// MARK: - Game Play View
// Stadium: the Play screen IS the equalizer, with a split-color scoreboard
// and one giant countdown. Reveal swaps to the answer + half-screen scoring
// slabs. Same flow as before: reveal → tap teams to cycle points → next song.
struct GamePlayView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var gameManager: GameManager
    @State private var roundScores: [UUID: Int] = [:]
    @State private var showEndGameConfirm = false
    @State private var showRoundBanner = false

    var body: some View {
        Group {
            if gameManager.showAnswer {
                revealView
            } else {
                mysteryView
            }
        }
        .overlay { roundBanner }
        .confirmationDialog("End this game?", isPresented: $showEndGameConfirm, titleVisibility: .visible) {
            Button("End Game", role: .destructive) {
                applyRoundScores()
                playerManager.stopPlayback()
                gameManager.endGame()
            }
            Button("Keep Playing", role: .cancel) {}
        } message: {
            Text("Scores so far will be kept.")
        }
        .onChange(of: gameManager.currentRoundNumber) { _ in
            flashRoundBanner()
        }
        .animation(DesignSystem.animation, value: gameManager.showAnswer)
    }

    // MARK: Mystery — full-height equalizer with the countdown on top
    private var mysteryView: some View {
        VStack(spacing: 0) {
            HStack(spacing: DesignSystem.spacing.sm) {
                scoreBar
                endGameButton
            }
            .padding(.horizontal)
            .padding(.top, DesignSystem.spacing.sm)

            ZStack {
                StadiumEqualizer(isPlaying: playerManager.isPlaying)
                    .padding(.horizontal, DesignSystem.spacing.lg)
                    .padding(.top, DesignSystem.spacing.md)

                VStack(spacing: DesignSystem.spacing.md) {
                    Text(countdown)
                        .font(.system(size: 88, weight: .black, design: .rounded))
                        .foregroundColor(.white)
                        .contentTransition(.numericText())
                        .padding(.top, DesignSystem.spacing.lg)

                    Text("ROUND \(gameManager.currentRoundNumber) · FIRST TO \(gameManager.gameSettings.targetScore)")
                        .font(.footnote.weight(.heavy))
                        .tracking(1)
                        .foregroundColor(.white.opacity(0.85))
                        .padding(.vertical, 8)
                        .padding(.horizontal, 14)
                        .background(Capsule().fill(Color.black.opacity(0.45)))

                    Spacer()
                }
            }

            HStack(spacing: DesignSystem.spacing.md) {
                pausePlayButton

                PrimaryButton(title: "Reveal", action: {
                    Haptics.reveal()
                    withAnimation(DesignSystem.animation) {
                        gameManager.showAnswer = true
                    }
                })
            }
            .padding(.horizontal)
            .padding(.bottom, DesignSystem.spacing.sm)
        }
    }

    private var countdown: String {
        let seconds = max(0, playerManager.remainingSeconds)
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }

    // MARK: Reveal — the answer + half-screen scoring slabs
    private var revealView: some View {
        VStack(spacing: DesignSystem.spacing.md) {
            HStack {
                Spacer()
                Button(action: advanceToNextSong) {
                    HStack(spacing: 6) {
                        Text("NEXT")
                            .font(.subheadline.weight(.heavy))
                            .tracking(1)
                        Image(systemName: "arrow.right")
                            .font(.subheadline.weight(.black))
                    }
                    .foregroundColor(.white)
                    .padding(.vertical, 12)
                    .padding(.horizontal, 18)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(PressableButtonStyle())
            }
            .padding(.horizontal)
            .padding(.top, DesignSystem.spacing.sm)

            Spacer(minLength: 0)

            answerBlock

            Spacer(minLength: 0)

            Text("TAP ONCE +1 · TWICE +2")
                .font(.caption2.weight(.heavy))
                .tracking(2)
                .foregroundColor(.secondary)

            scoringSlabs
                .padding(.horizontal)
                .padding(.bottom, DesignSystem.spacing.md)
        }
    }

    private var answerBlock: some View {
        ZStack {
            // Ghost year — era drama behind the reveal, borrowed from the
            // Poster direction.
            if let year = playerManager.currentTrack?.releaseYear {
                Text(String(year))
                    .font(.system(size: 190, weight: .black, design: .rounded))
                    .foregroundColor(.white.opacity(0.05))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }

            VStack(spacing: DesignSystem.spacing.sm) {
                Text("THAT WAS")
                    .font(.footnote.weight(.heavy))
                    .tracking(3)
                    .foregroundColor(DesignSystem.colors.primary)

                Text((playerManager.currentTrack?.name ?? "Mystery Song").uppercased())
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .minimumScaleFactor(0.4)

                if let track = playerManager.currentTrack {
                    Text(revealSubtitle(for: track))
                        .font(.subheadline.weight(.heavy))
                        .tracking(1)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, DesignSystem.spacing.lg)
        }
    }

    private func revealSubtitle(for track: Track) -> String {
        var subtitle = track.artistName.uppercased()
        if let year = track.releaseYear {
            subtitle += " · \(year)"
        }
        return subtitle
    }

    // Tap a slab to cycle 0 → +1 → +2 → 0; the slab shows the running total.
    private var scoringSlabs: some View {
        let teams = gameManager.gameSettings.teams
        let columnCount = teams.count <= 3 ? max(teams.count, 1) : (teams.count == 4 ? 2 : 3)
        let columns = Array(repeating: GridItem(.flexible(), spacing: DesignSystem.spacing.md), count: columnCount)
        return LazyVGrid(columns: columns, spacing: DesignSystem.spacing.md) {
            ForEach(teams) { team in
                scoringSlab(team)
            }
        }
    }

    private func scoringSlab(_ team: Team) -> some View {
        let points = roundScores[team.id] ?? 0
        return Button(action: {
            Haptics.score()
            withAnimation(DesignSystem.snappy) {
                roundScores[team.id] = (points + 1) % 3
            }
        }) {
            VStack(spacing: DesignSystem.spacing.xs) {
                Text(team.name.uppercased())
                    .font(.footnote.weight(.heavy))
                    .foregroundColor(.black.opacity(0.75))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)

                Text("\(team.score)")
                    .font(.system(size: 64, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .contentTransition(.numericText())

                Text(points > 0 ? "+\(points)" : "+1 · +2")
                    .font(.caption.weight(.heavy))
                    .foregroundColor(points > 0 ? .white : .black.opacity(0.45))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.radius.card, style: .continuous)
                    .fill(team.color)
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radius.card, style: .continuous)
                    .strokeBorder(.white, lineWidth: points > 0 ? 4 : 0)
            )
            .shadow(color: team.color.opacity(points > 0 ? 0.6 : 0.25), radius: 12, y: 6)
        }
        .buttonStyle(PressableButtonStyle())
        .animation(DesignSystem.snappy, value: points)
    }

    // MARK: Scoreboard — a split-color bar anyone can read across the table.
    // Four or more teams: full names can't fit, so segments switch to initials.
    private var scoreBar: some View {
        let teams = gameManager.gameSettings.teams
        let compact = teams.count >= 4
        return HStack(spacing: 2) {
            ForEach(teams) { team in
                HStack(spacing: compact ? 4 : 6) {
                    Text(compact ? team.initials : team.name.uppercased())
                        .font(.caption.weight(.heavy))
                        .lineLimit(1)
                        .minimumScaleFactor(compact ? 0.8 : 0.4)
                    Text("\(team.score)")
                        .font(.title3.weight(.black))
                        .contentTransition(.numericText())
                }
                .foregroundColor(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(team.color)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: DesignSystem.radius.chip, style: .continuous))
    }

    private var endGameButton: some View {
        Button(action: { showEndGameConfirm = true }) {
            Image(systemName: "xmark")
                .font(.subheadline.weight(.black))
                .foregroundColor(.white.opacity(0.7))
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.white.opacity(0.08)))
        }
        .buttonStyle(PressableButtonStyle())
    }

    private var pausePlayButton: some View {
        Button(action: {
            Haptics.tap()
            if gameManager.gameState == .playing {
                playerManager.pausePlayback()
                gameManager.gameState = .paused
            } else {
                playerManager.resumePlayback()
                gameManager.gameState = .playing
            }
        }) {
            Image(systemName: gameManager.gameState == .playing ? "pause.fill" : "play.fill")
                .font(.title3.weight(.black))
                .foregroundColor(.white)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Color.white.opacity(0.1)))
        }
        .buttonStyle(PressableButtonStyle())
    }

    // MARK: Round banner
    private var roundBanner: some View {
        Group {
            if showRoundBanner {
                Text("ROUND \(gameManager.currentRoundNumber)")
                    .font(.system(size: 40, weight: .black, design: .rounded))
                    .foregroundColor(.black)
                    .padding(.vertical, DesignSystem.spacing.md)
                    .padding(.horizontal, DesignSystem.spacing.xl)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.radius.card, style: .continuous)
                            .fill(DesignSystem.colors.primary)
                    )
                    .shadow(color: DesignSystem.colors.primary.opacity(0.4), radius: 20, y: 8)
                    .transition(.scale(scale: 0.6).combined(with: .opacity))
            }
        }
    }

    private func flashRoundBanner() {
        withAnimation(DesignSystem.snappy) { showRoundBanner = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            withAnimation(DesignSystem.animation) { showRoundBanner = false }
        }
    }

    // MARK: Round flow
    private func applyRoundScores() {
        for team in gameManager.gameSettings.teams {
            let points = roundScores[team.id] ?? 0
            if points > 0 {
                gameManager.scoreTeam(team, titleCorrect: points >= 1, artistCorrect: points >= 2)
            }
        }
        roundScores = [:]
    }

    private func advanceToNextSong() {
        applyRoundScores()

        if gameManager.hasReachedTargetScore {
            playerManager.stopPlayback()
            gameManager.endGame()
            return
        }

        // Find the next unplayed track in the queue
        var nextTrack: Track?
        for track in gameManager.availableTracks where !MusicService.shared.shouldSkipTrack(track) {
            nextTrack = track
            break
        }

        if let track = nextTrack {
            MusicService.shared.markTrackAsPlayed(track)
            playerManager.playSong(track) { success in
                if success {
                    gameManager.nextRound(title: track.name, artist: track.artistName)
                    gameManager.gameState = .playing
                } else {
                    print("Failed to play track: \(track.name)")
                }
            }
        } else {
            print("No more tracks available")
            playerManager.stopPlayback()
            gameManager.endGame()
        }
    }
}

// MARK: - Game Finished View
// Stadium winner moment: the whole screen floods the winning team's color.
// No crowns — the color and the giant score ARE the celebration.
struct GameFinishedView: View {
    @EnvironmentObject var gameManager: GameManager
    @EnvironmentObject var playerManager: PlayerManager
    @State private var scoreScale = 0.5

    var sortedTeams: [Team] {
        gameManager.gameSettings.teams.sorted(by: { $0.score > $1.score })
    }

    var body: some View {
        ZStack {
            (gameManager.winner?.color ?? DesignSystem.colors.primary)
                .ignoresSafeArea()

            VStack(spacing: DesignSystem.spacing.md) {
                Spacer()

                Text("WINNERS")
                    .font(.caption.weight(.heavy))
                    .tracking(3)
                    .foregroundColor(.white)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 16)
                    .background(Capsule().fill(.black))

                if let winner = gameManager.winner {
                    Text(winner.name.uppercased())
                        .font(.system(size: 44, weight: .black, design: .rounded))
                        .foregroundColor(.black)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .padding(.horizontal, DesignSystem.spacing.lg)

                    Text("\(winner.score)")
                        .font(.system(size: 168, weight: .black, design: .rounded))
                        .foregroundColor(.black)
                        .lineLimit(1)
                        .minimumScaleFactor(0.4)
                        .scaleEffect(scoreScale)
                }

                EqualizerGlyph()
                    .foregroundColor(.white)

                VStack(spacing: DesignSystem.spacing.xs) {
                    ForEach(Array(sortedTeams.dropFirst())) { team in
                        Text("\(team.name.uppercased()) · \(team.score)")
                            .font(.subheadline.weight(.heavy))
                            .tracking(1)
                            .foregroundColor(.black.opacity(0.55))
                    }
                }

                Spacer()

                VStack(spacing: DesignSystem.spacing.sm) {
                    Button(action: rematch) {
                        Text(gameManager.isLoadingTracks ? "BUILDING YOUR SETLIST…" : "REMATCH")
                            .font(.headline.weight(.black))
                            .tracking(1)
                            .lineLimit(1)
                            .minimumScaleFactor(0.6)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                                    .fill(.black)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(gameManager.isLoadingTracks)

                    Button(action: {
                        Haptics.tap()
                        playerManager.stopPlayback()
                        gameManager.resetScores()
                        gameManager.gameState = .setup
                    }) {
                        Text("NEW GAME")
                            .font(.headline.weight(.black))
                            .tracking(1)
                            .foregroundColor(.black)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                                    .strokeBorder(.black.opacity(0.6), lineWidth: 2)
                            )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
                .padding(.horizontal, DesignSystem.spacing.lg)
                .padding(.bottom, DesignSystem.spacing.lg)
            }

            ConfettiView(colors: [.white, .black, .white.opacity(0.7)])
        }
        .onAppear {
            Haptics.celebrate()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55).delay(0.15)) {
                scoreScale = 1.0
            }
        }
    }

    private func rematch() {
        Haptics.tap()
        Task {
            await gameManager.loadTracks()
            guard let firstTrack = gameManager.availableTracks.first else { return }
            gameManager.startGame()
            MusicService.shared.markTrackAsPlayed(firstTrack)
            playerManager.playSong(firstTrack) { success in
                if success {
                    gameManager.nextRound(title: firstTrack.name, artist: firstTrack.artistName)
                }
            }
        }
    }
}
