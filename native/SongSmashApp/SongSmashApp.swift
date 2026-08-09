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

    private var player: AVPlayer?
    private var endObserver: NSObjectProtocol?

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
        player?.pause()
        player = nil
        currentTrack = nil
        isPlaying = false
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

    enum GameState {
        case setup, playing, paused, finished
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
                        .opacity(0.30)
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
struct Card: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let content: AnyView

    init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }

    var body: some View {
        content
            .padding(DesignSystem.spacing.md)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.radius.card, style: .continuous)
                    .fill(reduceTransparency
                          ? AnyShapeStyle(Color(white: 0.12))
                          : AnyShapeStyle(.ultraThinMaterial))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radius.card, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [.white.opacity(0.28), .white.opacity(0.05)],
                            startPoint: .top, endPoint: .bottom
                        ),
                        lineWidth: 0.75
                    )
            )
            .shadow(color: .black.opacity(0.25), radius: 14, y: 8)
    }
}

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
                        .tint(DesignSystem.colors.primary)
                }
                Text(title)
                    .font(.headline)
            }
            .foregroundColor(isEnabled ? DesignSystem.colors.primary : .secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.spacing.md)
            .background(
                RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                    .fill(isEnabled
                          ? AnyShapeStyle(DesignSystem.colors.primary.opacity(0.20))
                          : AnyShapeStyle(Color.white.opacity(0.06)))
            )
            .overlay(
                RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                    .strokeBorder(DesignSystem.colors.primary.opacity(isEnabled ? 0.45 : 0.08), lineWidth: 0.75)
            )
            .shadow(color: isEnabled ? DesignSystem.colors.primary.opacity(0.25) : .clear, radius: 12, y: 4)
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

struct SectionHeader: View {
    let title: String
    let action: (() -> Void)?
    let actionTitle: String?

    init(title: String, action: (() -> Void)? = nil, actionTitle: String? = nil) {
        self.title = title
        self.action = action
        self.actionTitle = actionTitle
    }

    var body: some View {
        HStack {
            Text(title)
                .font(.title3.weight(.semibold))
            Spacer()
            if let action = action, let actionTitle = actionTitle {
                Button(action: {
                    Haptics.tap()
                    action()
                }) {
                    Text(actionTitle)
                        .font(.subheadline.weight(.medium))
                        .foregroundColor(DesignSystem.colors.primary)
                }
            }
        }
    }
}

struct TeamAvatar: View {
    let team: Team
    var size: CGFloat = 44
    var glow: Bool = true

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [team.color.opacity(0.85), team.color],
                    startPoint: .top, endPoint: .bottom
                )
            )
            .frame(width: size, height: size)
            .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))
            .overlay(
                Text(String(team.name.prefix(1)))
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundColor(.white)
            )
            .shadow(color: glow ? team.color.opacity(0.55) : .clear, radius: size * 0.22, y: 3)
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

// Five bars that bounce while the preview is playing and rest while paused.
struct EqualizerView: View {
    var isPlaying: Bool
    @State private var animating = false

    private let tall: [CGFloat] = [26, 40, 32, 44, 28]
    private let short: [CGFloat] = [12, 18, 14, 20, 12]

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0..<5, id: \.self) { index in
                RoundedRectangle(cornerRadius: 2.5)
                    .fill(DesignSystem.colors.primary)
                    .frame(width: 5, height: animating ? tall[index] : short[index])
                    .animation(
                        isPlaying
                            ? .easeInOut(duration: 0.45).repeatForever(autoreverses: true).delay(Double(index) * 0.09)
                            : DesignSystem.animation,
                        value: animating
                    )
            }
        }
        .frame(height: 44, alignment: .center)
        .opacity(isPlaying ? 1 : 0.35)
        .onAppear { animating = isPlaying }
        .onChange(of: isPlaying) { playing in
            animating = playing
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
struct GameSetupView: View {
    @EnvironmentObject var gameManager: GameManager
    @EnvironmentObject var playerManager: PlayerManager
    @State private var showingTeamSetup = UserDefaults.standard.bool(forKey: "ShowTeamSetup")
    @State private var showingGenreSelection = UserDefaults.standard.bool(forKey: "ShowGenreSelection")
    @State private var showingDecadeSelection = UserDefaults.standard.bool(forKey: "ShowDecadeSelection")
    @State private var editingTeam: Team?

    let availableGenres = ["Pop", "Rock", "Hip-Hop", "Country", "R&B", "Electronic", "Jazz", "Classical", "Indie", "Alternative"]
    let availableDecades = ["2020s", "2010s", "2000s", "1990s", "1980s", "1970s", "1960s"]

    // Honest completion: teams are the only requirement; music filters are optional.
    var setupCompletion: Double {
        Double(min(gameManager.gameSettings.teams.count, 2)) / 2.0
    }

    var body: some View {
        ScrollView {
            VStack(spacing: DesignSystem.spacing.md) {
                HStack {
                    Text("New Game")
                        .font(.largeTitle.bold())
                    Spacer()
                }
                .padding(.horizontal)
                .padding(.top, DesignSystem.spacing.md)

                setupProgressView
                teamsCard
                    .padding(.horizontal)
                musicSelectionCard
                    .padding(.horizontal)
                gameSettingsCard
                    .padding(.horizontal)
                if let error = gameManager.loadError {
                    errorCard(error)
                        .padding(.horizontal)
                }
                startGameButton
            }
            .padding(.vertical)
        }
        .sheet(isPresented: $showingTeamSetup) {
            TeamSetupView()
        }
        .sheet(item: $editingTeam) { team in
            TeamSetupView(teamToEdit: team)
        }
        .sheet(isPresented: $showingGenreSelection) {
            SelectionView(
                title: "Select Genres",
                options: availableGenres,
                selections: $gameManager.gameSettings.genres
            )
        }
        .sheet(isPresented: $showingDecadeSelection) {
            SelectionView(
                title: "Select Decades",
                options: availableDecades,
                selections: $gameManager.gameSettings.decades
            )
        }
    }

    private var setupProgressView: some View {
        VStack(spacing: DesignSystem.spacing.sm) {
            HStack {
                Text("Setup Progress")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(setupCompletion * 100))%")
                    .font(.subheadline.weight(.semibold))
                    .contentTransition(.numericText())
            }

            ProgressView(value: setupCompletion)
                .tint(DesignSystem.colors.primary)
                .animation(DesignSystem.animation, value: setupCompletion)
        }
        .padding(.horizontal)
    }

    private var teamsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSystem.spacing.md) {
                SectionHeader(
                    title: "Teams",
                    action: { showingTeamSetup = true },
                    actionTitle: "Add Team"
                )

                if gameManager.gameSettings.teams.isEmpty {
                    HStack {
                        Image(systemName: "person.2.fill")
                            .foregroundColor(.secondary)
                        Text("Add at least 2 teams to play")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, DesignSystem.spacing.sm)
                } else {
                    ForEach(gameManager.gameSettings.teams) { team in
                        HStack(spacing: DesignSystem.spacing.md) {
                            TeamAvatar(team: team, size: 36)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(team.name)
                                    .font(.body)
                                Text("Tap to edit")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Button(action: {
                                Haptics.tap()
                                withAnimation(DesignSystem.snappy) {
                                    gameManager.gameSettings.teams.removeAll { $0.id == team.id }
                                }
                            }) {
                                Image(systemName: "minus.circle.fill")
                                    .font(.title3)
                                    .foregroundColor(DesignSystem.colors.danger.opacity(0.85))
                                    .frame(width: 44, height: 44)
                            }
                            .buttonStyle(PressableButtonStyle())
                        }
                        .padding(.vertical, DesignSystem.spacing.xs)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            Haptics.tap()
                            editingTeam = team
                        }
                    }
                }
            }
        }
    }

    private var musicSelectionCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSystem.spacing.md) {
                SectionHeader(title: "Music Selection")

                // Genres
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Button(action: {
                        Haptics.tap()
                        showingGenreSelection = true
                    }) {
                        HStack {
                            Label("Genres", systemImage: "music.note")
                                .font(.body)
                            Spacer()
                            if gameManager.gameSettings.genres.isEmpty {
                                Text("All genres")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(gameManager.gameSettings.genres.count) selected")
                                    .font(.subheadline)
                                    .foregroundColor(DesignSystem.colors.primary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)

                    if !gameManager.gameSettings.genres.isEmpty {
                        Text(gameManager.gameSettings.genres.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }

                Divider()

                // Decades
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Button(action: {
                        Haptics.tap()
                        showingDecadeSelection = true
                    }) {
                        HStack {
                            Label("Decades", systemImage: "calendar")
                                .font(.body)
                            Spacer()
                            if gameManager.gameSettings.decades.isEmpty {
                                Text("All decades")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(gameManager.gameSettings.decades.count) selected")
                                    .font(.subheadline)
                                    .foregroundColor(DesignSystem.colors.primary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)

                    if !gameManager.gameSettings.decades.isEmpty {
                        Text(gameManager.gameSettings.decades.joined(separator: ", "))
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
    }

    private var gameSettingsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: DesignSystem.spacing.md) {
                SectionHeader(title: "Game Settings")

                // Difficulty
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Text("Difficulty")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    Picker("Difficulty", selection: $gameManager.gameSettings.difficulty) {
                        ForEach(Difficulty.allCases, id: \.self) { difficulty in
                            Text(difficulty.rawValue).tag(difficulty)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())

                    Text(gameManager.gameSettings.difficulty.description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Divider()

                // Target score — chunky ±44pt controls instead of a fiddly stepper
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Text("Playing To")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    HStack {
                        Text("\(gameManager.gameSettings.targetScore) points")
                            .font(.title.weight(.semibold))
                            .contentTransition(.numericText())

                        Spacer()

                        HStack(spacing: DesignSystem.spacing.sm) {
                            stepperButton(systemName: "minus") {
                                if gameManager.gameSettings.targetScore > 5 {
                                    withAnimation(DesignSystem.snappy) {
                                        gameManager.gameSettings.targetScore -= 5
                                    }
                                }
                            }
                            stepperButton(systemName: "plus") {
                                if gameManager.gameSettings.targetScore < 100 {
                                    withAnimation(DesignSystem.snappy) {
                                        gameManager.gameSettings.targetScore += 5
                                    }
                                }
                            }
                        }
                    }

                    Text("First team to \(gameManager.gameSettings.targetScore) points wins")
                        .font(.caption)
                        .foregroundColor(.secondary)
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
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(
                    Circle().fill(Color.white.opacity(0.08))
                )
                .overlay(Circle().strokeBorder(.white.opacity(0.18), lineWidth: 0.75))
        }
        .buttonStyle(PressableButtonStyle())
        .foregroundColor(.primary)
    }

    private func errorCard(_ message: String) -> some View {
        Card {
            HStack(spacing: DesignSystem.spacing.md) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundColor(DesignSystem.colors.warning)
                Text(message)
                    .font(.subheadline)
                    .foregroundColor(.primary)
            }
        }
    }

    private var startGameButton: some View {
        PrimaryButton(
            title: gameManager.isLoadingTracks ? "Building your setlist…" : "Start Game",
            action: {
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
            },
            isEnabled: gameManager.gameSettings.teams.count >= 2,
            isLoading: gameManager.isLoadingTracks
        )
        .padding(.horizontal)
        .padding(.top, DesignSystem.spacing.md)
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
                    Text("Team Name")
                        .font(.subheadline)
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
                    Text("Team Color")
                        .font(.subheadline)
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
        .presentationBackground(.ultraThinMaterial)
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

// MARK: - Selection View
struct SelectionView: View {
    let title: String
    let options: [String]
    @Binding var selections: [String]
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                if !selections.isEmpty {
                    HStack {
                        Text("\(selections.count) selected")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Clear All") {
                            Haptics.tap()
                            selections.removeAll()
                        }
                        .font(.subheadline)
                        .foregroundColor(DesignSystem.colors.danger)
                    }
                    .padding()
                }

                List {
                    ForEach(options, id: \.self) { option in
                        HStack {
                            Text(option)
                                .font(.body)
                            Spacer()
                            if selections.contains(option) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(DesignSystem.colors.primary)
                                    .font(.title3)
                            }
                        }
                        .contentShape(Rectangle())
                        .listRowBackground(Color.white.opacity(0.06))
                        .onTapGesture {
                            Haptics.tap()
                            withAnimation(DesignSystem.snappy) {
                                if selections.contains(option) {
                                    selections.removeAll { $0 == option }
                                } else {
                                    selections.append(option)
                                }
                            }
                        }
                    }
                }
                .listStyle(InsetGroupedListStyle())
                .scrollContentBackground(.hidden)
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.body.weight(.semibold))
                }
            }
        }
        .presentationBackground(.ultraThinMaterial)
    }
}

// MARK: - Game Play View
// One focal point (the mystery card), a compact score strip, and a single
// scoring model: reveal, tap teams to cycle points, next song.
struct GamePlayView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var gameManager: GameManager
    @State private var roundScores: [UUID: Int] = [:]
    @State private var showEndGameConfirm = false
    @State private var showRoundBanner = false

    var body: some View {
        VStack(spacing: 0) {
            topBar

            ScrollView {
                VStack(spacing: DesignSystem.spacing.md) {
                    scoreStrip
                        .padding(.horizontal)

                    if playerManager.currentTrack != nil {
                        heroCard
                            .padding(.horizontal)
                    }

                    actionSection
                        .padding(.horizontal)
                }
                .padding(.top, DesignSystem.spacing.sm)
                .padding(.bottom, DesignSystem.spacing.xl)
            }

            playbackDock
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
    }

    // MARK: Top bar
    private var topBar: some View {
        VStack(spacing: DesignSystem.spacing.sm) {
            HStack {
                Text("Round \(gameManager.currentRoundNumber) · First to \(gameManager.gameSettings.targetScore)")
                    .font(.headline)
                    .contentTransition(.numericText())
                Spacer()
                Button(action: { showEndGameConfirm = true }) {
                    Text("End Game")
                        .font(.subheadline)
                        .foregroundColor(DesignSystem.colors.danger)
                        .padding(.vertical, 6)
                        .padding(.horizontal, 10)
                }
            }

            ProgressView(value: gameManager.progress)
                .tint(DesignSystem.colors.primary)
                .animation(DesignSystem.animation, value: gameManager.progress)
        }
        .padding(.horizontal)
        .padding(.vertical, DesignSystem.spacing.sm)
    }

    // MARK: Score strip — compact, glanceable, out of the way
    private var scoreStrip: some View {
        HStack(spacing: DesignSystem.spacing.md) {
            ForEach(gameManager.gameSettings.teams) { team in
                HStack(spacing: DesignSystem.spacing.sm) {
                    TeamAvatar(team: team, size: 28, glow: false)
                    Text(team.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text("\(team.score)")
                        .font(.headline)
                        .contentTransition(.numericText())
                        .foregroundColor(team.color)
                }
                .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, DesignSystem.spacing.sm)
        .padding(.horizontal, DesignSystem.spacing.md)
        .background(
            Capsule().fill(.ultraThinMaterial)
        )
        .overlay(
            Capsule().strokeBorder(.white.opacity(0.15), lineWidth: 0.75)
        )
    }

    // MARK: Hero card — the mystery is the star of the screen
    private var heroCard: some View {
        Card {
            VStack(spacing: DesignSystem.spacing.md) {
                EqualizerView(isPlaying: playerManager.isPlaying)

                Text("NOW PLAYING")
                    .font(.caption.weight(.semibold))
                    .tracking(2)
                    .foregroundColor(.secondary)

                if gameManager.showAnswer, let track = playerManager.currentTrack {
                    VStack(spacing: DesignSystem.spacing.sm) {
                        Text(track.name)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .multilineTextAlignment(.center)
                            .minimumScaleFactor(0.6)
                        Text(track.artistName)
                            .font(.title3)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                        if let year = track.releaseYear {
                            Text(String(year))
                                .font(.caption.weight(.semibold))
                                .padding(.vertical, 4)
                                .padding(.horizontal, 10)
                                .background(Capsule().fill(Color.white.opacity(0.1)))
                        }
                    }
                    .transition(.scale(scale: 0.8).combined(with: .opacity))
                } else {
                    VStack(spacing: DesignSystem.spacing.sm) {
                        Text("?????")
                            .font(.system(size: 64, weight: .heavy, design: .rounded))
                            .foregroundColor(.white.opacity(0.35))
                        Text("Listen carefully!")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                    .transition(.opacity)
                }
            }
            .padding(.vertical, DesignSystem.spacing.md)
        }
        .animation(DesignSystem.animation, value: gameManager.showAnswer)
    }

    // MARK: Actions — reveal, then score inline, then next song
    private var actionSection: some View {
        VStack(spacing: DesignSystem.spacing.md) {
            if !gameManager.showAnswer {
                Button(action: {
                    Haptics.reveal()
                    withAnimation(DesignSystem.animation) {
                        gameManager.showAnswer = true
                    }
                }) {
                    HStack {
                        Image(systemName: "eye.fill")
                        Text("Reveal Answer")
                    }
                    .font(.headline)
                    .foregroundColor(DesignSystem.colors.warning)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, DesignSystem.spacing.md)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                            .fill(DesignSystem.colors.warning.opacity(0.16))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                            .strokeBorder(DesignSystem.colors.warning.opacity(0.4), lineWidth: 0.75)
                    )
                }
                .buttonStyle(PressableButtonStyle())
            } else {
                scoringChips

                PrimaryButton(
                    title: "Next Song",
                    action: advanceToNextSong
                )
            }
        }
    }

    // One scoring model: tap a team to cycle 0 → 1 → 2 points.
    private var scoringChips: some View {
        VStack(spacing: DesignSystem.spacing.sm) {
            Text("Tap a team once = artist or title (+1) · twice = both (+2)")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: DesignSystem.spacing.md) {
                ForEach(gameManager.gameSettings.teams) { team in
                    let points = roundScores[team.id] ?? 0

                    Button(action: {
                        Haptics.score()
                        withAnimation(DesignSystem.snappy) {
                            roundScores[team.id] = (points + 1) % 3
                        }
                    }) {
                        VStack(spacing: DesignSystem.spacing.xs) {
                            ZStack {
                                TeamAvatar(team: team, size: 62, glow: points > 0)
                                if points > 0 {
                                    Text("+\(points)")
                                        .font(.caption.weight(.heavy))
                                        .foregroundColor(.black)
                                        .frame(width: 26, height: 26)
                                        .background(Circle().fill(DesignSystem.colors.primary))
                                        .offset(x: 24, y: -22)
                                        .transition(.scale.combined(with: .opacity))
                                }
                            }
                            Text(team.name)
                                .font(.caption)
                                .foregroundColor(.primary)
                                .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, DesignSystem.spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                                .fill(points > 0 ? AnyShapeStyle(team.color.opacity(0.18)) : AnyShapeStyle(Color.white.opacity(0.05)))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: DesignSystem.radius.control, style: .continuous)
                                .strokeBorder(points > 0 ? team.color.opacity(0.6) : .white.opacity(0.12), lineWidth: 1)
                        )
                    }
                    .buttonStyle(PressableButtonStyle())
                }
            }
        }
    }

    // MARK: Playback dock
    private var playbackDock: some View {
        HStack {
            Spacer()
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
                    .font(.title2)
                    .foregroundColor(.white)
                    .frame(width: 62, height: 62)
                    .background(Circle().fill(.ultraThinMaterial))
                    .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.75))
                    .shadow(color: .black.opacity(0.3), radius: 10, y: 5)
            }
            .buttonStyle(PressableButtonStyle())
            Spacer()
        }
        .padding(.vertical, DesignSystem.spacing.sm)
    }

    // MARK: Round banner
    private var roundBanner: some View {
        Group {
            if showRoundBanner {
                Text("Round \(gameManager.currentRoundNumber)")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                    .padding(.vertical, DesignSystem.spacing.md)
                    .padding(.horizontal, DesignSystem.spacing.xl)
                    .background(
                        RoundedRectangle(cornerRadius: DesignSystem.radius.card, style: .continuous)
                            .fill(.ultraThinMaterial)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: DesignSystem.radius.card, style: .continuous)
                            .strokeBorder(.white.opacity(0.25), lineWidth: 0.75)
                    )
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
struct GameFinishedView: View {
    @EnvironmentObject var gameManager: GameManager
    @EnvironmentObject var playerManager: PlayerManager
    @State private var crownScale = 0.4

    var sortedTeams: [Team] {
        gameManager.gameSettings.teams.sorted(by: { $0.score > $1.score })
    }

    var body: some View {
        ZStack {
            VStack(spacing: DesignSystem.spacing.lg) {
                if let winner = gameManager.winner {
                    VStack(spacing: DesignSystem.spacing.md) {
                        Text("Winner!")
                            .font(.system(size: 44, weight: .heavy, design: .rounded))

                        ZStack {
                            Circle()
                                .fill(winner.color)
                                .frame(width: 130, height: 130)
                                .shadow(color: winner.color.opacity(0.65), radius: 30, y: 10)
                            Text("👑")
                                .font(.system(size: 62))
                        }
                        .scaleEffect(crownScale)

                        VStack(spacing: DesignSystem.spacing.xs) {
                            Text(winner.name)
                                .font(.largeTitle.bold())
                            Text("\(winner.score) points")
                                .font(.title3)
                                .foregroundColor(.secondary)
                        }
                    }
                    .padding(.top, DesignSystem.spacing.xl)
                }

                Card {
                    VStack(alignment: .leading, spacing: DesignSystem.spacing.md) {
                        Text("Final Scores")
                            .font(.title3.weight(.semibold))

                        ForEach(Array(sortedTeams.enumerated()), id: \.element.id) { index, team in
                            HStack(spacing: DesignSystem.spacing.md) {
                                Text("\(index + 1)")
                                    .font(.headline)
                                    .foregroundColor(index == 0 ? .yellow : .secondary)
                                    .frame(width: 28)

                                TeamAvatar(team: team, size: 34, glow: index == 0)

                                Text(team.name)
                                    .font(.body)

                                Spacer()

                                Text("\(team.score)")
                                    .font(.title3.bold())
                                    .foregroundColor(team.color)
                            }
                            .padding(.vertical, DesignSystem.spacing.xs)

                            if index < sortedTeams.count - 1 {
                                Divider()
                            }
                        }
                    }
                }
                .padding(.horizontal)

                Spacer()

                VStack(spacing: DesignSystem.spacing.md) {
                    PrimaryButton(
                        title: "Play Again",
                        action: {
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
                        },
                        isLoading: gameManager.isLoadingTracks
                    )

                    Button(action: {
                        playerManager.stopPlayback()
                        gameManager.resetScores()
                        gameManager.gameState = .setup
                    }) {
                        Text("New Game")
                            .font(.body)
                            .foregroundColor(DesignSystem.colors.primary)
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, DesignSystem.spacing.xl)
            }

            ConfettiView(colors: confettiColors)
        }
        .onAppear {
            Haptics.celebrate()
            withAnimation(.spring(response: 0.6, dampingFraction: 0.55).delay(0.15)) {
                crownScale = 1.0
            }
        }
    }

    private var confettiColors: [Color] {
        let teamColors = gameManager.gameSettings.teams.map(\.color)
        return teamColors.isEmpty ? [.blue, .pink, .yellow, DesignSystem.colors.primary] : teamColors + [.yellow, .white]
    }
}
