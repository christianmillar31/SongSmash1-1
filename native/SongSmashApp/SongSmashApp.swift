import SwiftUI
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
        }
    }
}

// MARK: - Design System
struct DesignSystem {
    static let spacing = (
        xs: 4.0,
        sm: 8.0,
        md: 16.0,
        lg: 24.0,
        xl: 32.0
    )
    
    static let fontSize = (
        xs: 12.0,
        sm: 14.0,
        md: 16.0,
        lg: 20.0,
        xl: 28.0,
        xxl: 36.0
    )
    
    static let animation = Animation.easeInOut(duration: 0.3)
    
    static let colors = (
        primary: Color.green,
        secondary: Color.blue,
        danger: Color.red,
        warning: Color.orange,
        surface: Color(UIColor.secondarySystemBackground),
        background: Color(UIColor.systemBackground)
    )
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
    var rounds: Int = 25
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
    
    enum GameState {
        case setup, playing, paused, finished
    }
    
    var currentRoundNumber: Int {
        rounds.count + 1
    }
    
    var progress: Double {
        Double(rounds.count) / Double(gameSettings.rounds)
    }
    
    func startGame() {
        gameState = .playing
        rounds = []
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
            
            // Check if we've completed all rounds AFTER appending
            if rounds.count >= gameSettings.rounds {
                currentRound = nil
                endGame()
                return
            }
        }
        
        currentRound = Round(songTitle: title, artist: artist)
        showAnswer = false
    }
    
    func endGame() {
        if let current = currentRound {
            rounds.append(current)
        }
        print("Game ended with \(rounds.count) rounds played out of \(gameSettings.rounds) total")
        gameState = .finished
    }
    
    var winner: Team? {
        gameSettings.teams.max(by: { $0.score < $1.score })
    }
    
    @MainActor
    func loadTracks() async {
        isLoadingTracks = true
        do {
            availableTracks = try await MusicService.shared.loadTracks(
                genres: gameSettings.genres,
                decades: gameSettings.decades,
                difficulty: gameSettings.difficulty
            )
            print("Loaded \(availableTracks.count) tracks for game")
        } catch {
            print("Error loading tracks: \(error)")
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

// MARK: - Reusable Components
struct PrimaryButton: View {
    let title: String
    let action: () -> Void
    var isEnabled: Bool = true
    var isLoading: Bool = false
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignSystem.spacing.sm) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(0.8)
                }
                Text(title)
                    .font(.system(size: DesignSystem.fontSize.md, weight: .semibold))
            }
            .foregroundColor(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, DesignSystem.spacing.md)
            .background(isEnabled ? DesignSystem.colors.primary : Color.gray)
            .cornerRadius(12)
            .shadow(color: isEnabled ? DesignSystem.colors.primary.opacity(0.3) : .clear,
                   radius: 8, x: 0, y: 4)
        }
        .disabled(!isEnabled || isLoading)
        .animation(DesignSystem.animation, value: isEnabled)
    }
}

struct Card: View {
    let content: AnyView
    
    init<Content: View>(@ViewBuilder content: () -> Content) {
        self.content = AnyView(content())
    }
    
    var body: some View {
        content
            .padding(DesignSystem.spacing.md)
            .background(DesignSystem.colors.surface)
            .cornerRadius(12)
            .shadow(color: Color.black.opacity(0.05), radius: 4, x: 0, y: 2)
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
                .font(.system(size: DesignSystem.fontSize.lg, weight: .semibold))
            Spacer()
            if let action = action, let actionTitle = actionTitle {
                Button(actionTitle, action: action)
                    .font(.system(size: DesignSystem.fontSize.sm))
                    .foregroundColor(DesignSystem.colors.primary)
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
                            MusicService.shared.markTrackAsPlayed(firstTrack.id)
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

// MARK: - WiFi Required View
struct NetworkRequiredView: View {
    var body: some View {
        VStack(spacing: DesignSystem.spacing.lg) {
            Spacer()
            
            Image(systemName: "wifi.slash")
                .font(.system(size: 80))
                .foregroundColor(DesignSystem.colors.danger)
                .padding(.bottom, DesignSystem.spacing.md)
            
            Text("Internet Connection Required")
                .font(.system(size: DesignSystem.fontSize.xl, weight: .bold))
            
            Text("SongSmash needs an internet connection to stream song previews. Please connect and try again.")
                .font(.system(size: DesignSystem.fontSize.md))
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
    
    let availableGenres = ["Pop", "Rock", "Hip-Hop", "Country", "R&B", "Electronic", "Jazz", "Classical", "Indie", "Alternative"]
    let availableDecades = ["2020s", "2010s", "2000s", "1990s", "1980s", "1970s", "1960s"]
    
    var setupCompletion: Double {
        var completed: Double = 0.0
        
        // Check teams (25% of completion)
        if gameManager.gameSettings.teams.count >= 2 {
            completed = completed + 0.25
        }
        
        // Check genres (25% of completion)
        if !gameManager.gameSettings.genres.isEmpty {
            completed = completed + 0.25
        }
        
        // Check decades (25% of completion)
        if !gameManager.gameSettings.decades.isEmpty {
            completed = completed + 0.25
        }
        
        // Difficulty is always set (25% of completion)
        completed = completed + 0.25
        
        return completed
    }
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: DesignSystem.spacing.md) {
                    setupProgressView
                    teamsCard
                        .padding(.horizontal)
                    musicSelectionCard
                        .padding(.horizontal)
                    gameSettingsCard
                        .padding(.horizontal)
                    startGameButton
                }
                .padding(.vertical)
            }
            .navigationTitle("New Game")
            .sheet(isPresented: $showingTeamSetup) {
                TeamSetupView()
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
    }
    
    private var setupProgressView: some View {
        VStack(spacing: DesignSystem.spacing.sm) {
            HStack {
                Text("Setup Progress")
                    .font(.system(size: DesignSystem.fontSize.sm))
                    .foregroundColor(.secondary)
                Spacer()
                Text("\(Int(setupCompletion * 100))%")
                    .font(.system(size: DesignSystem.fontSize.sm, weight: .semibold))
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
                            .font(.system(size: DesignSystem.fontSize.sm))
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, DesignSystem.spacing.sm)
                } else {
                    ForEach(gameManager.gameSettings.teams) { team in
                        HStack(spacing: DesignSystem.spacing.md) {
                            Circle()
                                .fill(team.color)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(String(team.name.prefix(1)))
                                        .foregroundColor(.white)
                                        .font(.system(size: DesignSystem.fontSize.sm, weight: .bold))
                                )
                            Text(team.name)
                                .font(.system(size: DesignSystem.fontSize.md))
                            Spacer()
                        }
                        .padding(.vertical, DesignSystem.spacing.xs)
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
                    Button(action: { showingGenreSelection = true }) {
                        HStack {
                            Label("Genres", systemImage: "music.note")
                                .font(.system(size: DesignSystem.fontSize.md))
                            Spacer()
                            if gameManager.gameSettings.genres.isEmpty {
                                Text("Select")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(gameManager.gameSettings.genres.count) selected")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(DesignSystem.colors.primary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: DesignSystem.fontSize.sm))
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                    
                    if !gameManager.gameSettings.genres.isEmpty {
                        Text(gameManager.gameSettings.genres.joined(separator: ", "))
                            .font(.system(size: DesignSystem.fontSize.xs))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                
                Divider()
                
                // Decades
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Button(action: { showingDecadeSelection = true }) {
                        HStack {
                            Label("Decades", systemImage: "calendar")
                                .font(.system(size: DesignSystem.fontSize.md))
                            Spacer()
                            if gameManager.gameSettings.decades.isEmpty {
                                Text("Select")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(.secondary)
                            } else {
                                Text("\(gameManager.gameSettings.decades.count) selected")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(DesignSystem.colors.primary)
                            }
                            Image(systemName: "chevron.right")
                                .font(.system(size: DesignSystem.fontSize.sm))
                                .foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                    
                    if !gameManager.gameSettings.decades.isEmpty {
                        Text(gameManager.gameSettings.decades.joined(separator: ", "))
                            .font(.system(size: DesignSystem.fontSize.xs))
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
                        .font(.system(size: DesignSystem.fontSize.sm))
                        .foregroundColor(.secondary)
                    
                    Picker("Difficulty", selection: $gameManager.gameSettings.difficulty) {
                        ForEach(Difficulty.allCases, id: \.self) { difficulty in
                            Text(difficulty.rawValue).tag(difficulty)
                        }
                    }
                    .pickerStyle(SegmentedPickerStyle())
                    
                    Text(gameManager.gameSettings.difficulty.description)
                        .font(.system(size: DesignSystem.fontSize.xs))
                        .foregroundColor(.secondary)
                }
                
                Divider()
                
                // Rounds
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Text("Number of Rounds")
                        .font(.system(size: DesignSystem.fontSize.sm))
                        .foregroundColor(.secondary)
                    
                    HStack {
                        Text("\(gameManager.gameSettings.rounds)")
                            .font(.system(size: DesignSystem.fontSize.xl, weight: .semibold))
                        
                        Spacer()
                        
                        Stepper("", value: $gameManager.gameSettings.rounds, in: 10...50, step: 5)
                            .labelsHidden()
                    }
                }
            }
        }
    }
    
    private var startGameButton: some View {
        PrimaryButton(
            title: "Start Game",
            action: {
                Task {
                    await gameManager.loadTracks()
                    gameManager.startGame()
                    if let firstTrack = gameManager.availableTracks.first {
                        MusicService.shared.markTrackAsPlayed(firstTrack.id)
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
            },
            isEnabled: gameManager.gameSettings.teams.count >= 2 && !gameManager.gameSettings.genres.isEmpty && !gameManager.gameSettings.decades.isEmpty,
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
    @State private var teamName = ""
    @State private var selectedColorName = "blue"
    
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
    
    var body: some View {
        NavigationView {
            VStack(spacing: DesignSystem.spacing.lg) {
                // Team Name Input
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Text("Team Name")
                        .font(.system(size: DesignSystem.fontSize.sm))
                        .foregroundColor(.secondary)
                    
                    TextField("Enter team name", text: $teamName)
                        .font(.system(size: DesignSystem.fontSize.md))
                        .padding()
                        .background(DesignSystem.colors.surface)
                        .cornerRadius(10)
                        .textInputAutocapitalization(.words)
                }
                
                // Color Selection
                VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                    Text("Team Color")
                        .font(.system(size: DesignSystem.fontSize.sm))
                        .foregroundColor(.secondary)
                    
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 5), spacing: DesignSystem.spacing.md) {
                        ForEach(colorOptions, id: \.name) { option in
                            Circle()
                                .fill(option.color)
                                .frame(width: 50, height: 50)
                                .overlay(
                                    Circle()
                                        .stroke(Color.white, lineWidth: selectedColorName == option.name ? 3 : 0)
                                        .padding(2)
                                )
                                .overlay(
                                    Image(systemName: "checkmark")
                                        .foregroundColor(.white)
                                        .font(.system(size: DesignSystem.fontSize.md, weight: .bold))
                                        .opacity(selectedColorName == option.name ? 1 : 0)
                                )
                                .onTapGesture {
                                    selectedColorName = option.name
                                }
                                .animation(DesignSystem.animation, value: selectedColorName)
                        }
                    }
                }
                
                Spacer()
                
                PrimaryButton(
                    title: "Add Team",
                    action: {
                        let team = Team(name: teamName, colorName: selectedColorName)
                        gameManager.gameSettings.teams.append(team)
                        dismiss()
                    },
                    isEnabled: !teamName.isEmpty
                )
            }
            .padding()
            .navigationTitle("Add Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
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
                            .font(.system(size: DesignSystem.fontSize.sm))
                            .foregroundColor(.secondary)
                        Spacer()
                        Button("Clear All") {
                            selections.removeAll()
                        }
                        .font(.system(size: DesignSystem.fontSize.sm))
                        .foregroundColor(DesignSystem.colors.danger)
                    }
                    .padding()
                    .background(DesignSystem.colors.surface)
                }
                
                List {
                    ForEach(options, id: \.self) { option in
                        HStack {
                            Text(option)
                                .font(.system(size: DesignSystem.fontSize.md))
                            Spacer()
                            if selections.contains(option) {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(DesignSystem.colors.primary)
                                    .font(.system(size: DesignSystem.fontSize.lg))
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture {
                            withAnimation(DesignSystem.animation) {
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
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                        .font(.system(size: DesignSystem.fontSize.md, weight: .semibold))
                }
            }
        }
    }
}

// MARK: - Game Play View
struct GamePlayView: View {
    @EnvironmentObject var playerManager: PlayerManager
    @EnvironmentObject var gameManager: GameManager
    @State private var showingScoreSheet = false
    @State private var selectedTeam: Team?
    @State private var pulseAnimation = false
    @State private var showingScoringPrompt = false
    @State private var readyForNextSong = false
    
    var body: some View {
        VStack(spacing: 0) {
            // Top Bar with Progress
            VStack(spacing: DesignSystem.spacing.sm) {
                HStack {
                    Text("Round \(gameManager.currentRoundNumber) of \(gameManager.gameSettings.rounds)")
                        .font(.system(size: DesignSystem.fontSize.md, weight: .semibold))
                    Spacer()
                    Button(action: { gameManager.endGame() }) {
                        Text("End Game")
                            .font(.system(size: DesignSystem.fontSize.sm))
                            .foregroundColor(DesignSystem.colors.danger)
                    }
                }
                
                ProgressView(value: gameManager.progress)
                    .tint(DesignSystem.colors.primary)
                    .animation(DesignSystem.animation, value: gameManager.progress)
            }
            .padding()
            .background(DesignSystem.colors.surface)
            
            ScrollView {
                VStack(spacing: DesignSystem.spacing.lg) {
                    // Score Display
                    Card {
                        HStack {
                            ForEach(gameManager.gameSettings.teams) { team in
                                VStack(spacing: DesignSystem.spacing.sm) {
                                    Circle()
                                        .fill(team.color)
                                        .frame(width: 60, height: 60)
                                        .overlay(
                                            Text(String(team.name.prefix(1)))
                                                .foregroundColor(.white)
                                                .font(.system(size: DesignSystem.fontSize.lg, weight: .bold))
                                        )
                                    Text(team.name)
                                        .font(.system(size: DesignSystem.fontSize.sm))
                                        .lineLimit(1)
                                    Text("\(team.score)")
                                        .font(.system(size: DesignSystem.fontSize.xl, weight: .bold))
                                }
                                .frame(maxWidth: .infinity)
                            }
                        }
                    }
                    .padding(.horizontal)
                    
                    // Now Playing Card
                    if playerManager.currentTrack != nil {
                        Card {
                            VStack(spacing: DesignSystem.spacing.lg) {
                                HStack(spacing: DesignSystem.spacing.xs) {
                                    ForEach(0..<5) { index in
                                        RoundedRectangle(cornerRadius: 2)
                                            .fill(DesignSystem.colors.primary)
                                            .frame(width: 4, height: CGFloat.random(in: 20...40))
                                            .animation(
                                                Animation.easeInOut(duration: 0.5)
                                                    .repeatForever()
                                                    .delay(Double(index) * 0.1),
                                                value: pulseAnimation
                                            )
                                    }
                                }
                                .frame(height: 40)
                                .onAppear { pulseAnimation = true }
                                
                                Text("Now Playing")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(.secondary)
                                
                                if gameManager.showAnswer, let track = playerManager.currentTrack {
                                    VStack(spacing: DesignSystem.spacing.sm) {
                                        Text(track.name)
                                            .font(.system(size: DesignSystem.fontSize.xl, weight: .bold))
                                            .multilineTextAlignment(.center)
                                        Text(track.artistName)
                                            .font(.system(size: DesignSystem.fontSize.lg))
                                            .foregroundColor(.secondary)
                                    }
                                    .transition(.scale.combined(with: .opacity))
                                } else {
                                    VStack(spacing: DesignSystem.spacing.sm) {
                                        Text("?????")
                                            .font(.system(size: DesignSystem.fontSize.xxl, weight: .bold))
                                            .foregroundColor(.secondary.opacity(0.5))
                                        Text("Listen carefully!")
                                            .font(.system(size: DesignSystem.fontSize.sm))
                                            .foregroundColor(.secondary)
                                    }
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                    
                    // Control Section
                    VStack(spacing: DesignSystem.spacing.lg) {
                        // Team Buttons
                        if !gameManager.showAnswer {
                            VStack(alignment: .leading, spacing: DesignSystem.spacing.sm) {
                                Text("Which team knows the answer?")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal)
                                
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: DesignSystem.spacing.md) {
                                        ForEach(gameManager.gameSettings.teams) { team in
                                            let hasScored = gameManager.currentRound?.scoredTeams.contains(team.id) ?? false
                                            
                                            Button(action: {
                                                selectedTeam = team
                                                showingScoreSheet = true
                                            }) {
                                                VStack(spacing: DesignSystem.spacing.sm) {
                                                    Circle()
                                                        .fill(team.color.opacity(hasScored ? 0.3 : 1.0))
                                                        .frame(width: 80, height: 80)
                                                        .overlay(
                                                            Text(String(team.name.prefix(1)))
                                                                .foregroundColor(.white)
                                                                .font(.system(size: DesignSystem.fontSize.xl, weight: .bold))
                                                        )
                                                        .overlay(
                                                            hasScored ?
                                                            Image(systemName: "checkmark.circle.fill")
                                                                .foregroundColor(.white)
                                                                .font(.system(size: 30))
                                                                .background(Circle().fill(DesignSystem.colors.primary))
                                                            : nil
                                                        )
                                                    Text(team.name)
                                                        .font(.system(size: DesignSystem.fontSize.sm))
                                                        .foregroundColor(.primary)
                                                }
                                            }
                                            .disabled(hasScored)
                                            .scaleEffect(hasScored ? 0.9 : 1.0)
                                            .animation(DesignSystem.animation, value: hasScored)
                                        }
                                    }
                                    .padding(.horizontal)
                                }
                            }
                        }
                        
                        // Action Buttons
                        VStack(spacing: DesignSystem.spacing.md) {
                            if !gameManager.showAnswer {
                                Button(action: {
                                    withAnimation(DesignSystem.animation) {
                                        gameManager.showAnswer = true
                                        // Automatically prompt for scoring after revealing
                                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                                            showingScoringPrompt = true
                                        }
                                    }
                                }) {
                                    HStack {
                                        Image(systemName: "eye.fill")
                                        Text("Reveal Answer")
                                    }
                                    .font(.system(size: DesignSystem.fontSize.md, weight: .semibold))
                                    .foregroundColor(DesignSystem.colors.warning)
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, DesignSystem.spacing.md)
                                    .background(DesignSystem.colors.warning.opacity(0.15))
                                    .cornerRadius(12)
                                }
                            } else if readyForNextSong {
                                PrimaryButton(
                                    title: "Next Song",
                                    action: {
                                        // Reset state for next round
                                        readyForNextSong = false
                                        
                                        // Check if we should end the game
                                        if gameManager.rounds.count >= gameManager.gameSettings.rounds - 1 {
                                            gameManager.endGame()
                                            return
                                        }
                                        
                                        // Get next track from the queue
                                        let currentTrackIndex = gameManager.rounds.count
                                        
                                        // Find next unplayed track
                                        var nextTrack: Track?
                                        for i in currentTrackIndex..<gameManager.availableTracks.count {
                                            let track = gameManager.availableTracks[i]
                                            if !MusicService.shared.shouldSkipTrack(track) {
                                                nextTrack = track
                                                break
                                            }
                                        }
                                        
                                        if let track = nextTrack {
                                            MusicService.shared.markTrackAsPlayed(track.id)
                                            playerManager.playSong(track) { success in
                                                if success {
                                                    gameManager.nextRound(
                                                        title: track.name,
                                                        artist: track.artistName
                                                    )
                                                } else {
                                                    print("Failed to play track: \(track.name)")
                                                    // Try next track or show error
                                                }
                                            }
                                        } else {
                                            print("No more tracks available")
                                            gameManager.endGame()
                                        }
                                    }
                                )
                            } else {
                                // Show message to score teams first
                                VStack(spacing: DesignSystem.spacing.sm) {
                                    Text("Please score all teams before continuing")
                                        .font(.system(size: DesignSystem.fontSize.md))
                                        .foregroundColor(.secondary)
                                        .multilineTextAlignment(.center)
                                    
                                    Button("Skip Scoring") {
                                        readyForNextSong = true
                                    }
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(DesignSystem.colors.warning)
                                }
                                .padding()
                                .background(DesignSystem.colors.surface)
                                .cornerRadius(12)
                            }
                            
                            // Playback Control
                            HStack(spacing: DesignSystem.spacing.md) {
                                Button(action: {
                                    if gameManager.gameState == .playing {
                                        playerManager.pausePlayback()
                                        gameManager.gameState = .paused
                                    } else {
                                        playerManager.resumePlayback()
                                        gameManager.gameState = .playing
                                    }
                                }) {
                                    Image(systemName: gameManager.gameState == .playing ? "pause.circle.fill" : "play.circle.fill")
                                        .font(.system(size: 60))
                                        .foregroundColor(DesignSystem.colors.primary)
                                }
                            }
                        }
                        .padding(.horizontal)
                    }
                }
                .padding(.bottom, DesignSystem.spacing.xl)
            }
        }
        .sheet(isPresented: $showingScoreSheet) {
            if let team = selectedTeam {
                ScoringView(team: team)
            }
        }
        .sheet(isPresented: $showingScoringPrompt) {
            ScoringPromptView(onComplete: {
                showingScoringPrompt = false
                readyForNextSong = true
            })
        }
        .onAppear {
#if DEBUG
            if UserDefaults.standard.bool(forKey: "ShowScoring"), selectedTeam == nil {
                selectedTeam = gameManager.gameSettings.teams.first
                showingScoreSheet = true
            }
            if UserDefaults.standard.bool(forKey: "ShowScoringPrompt") {
                gameManager.showAnswer = true
                showingScoringPrompt = true
            }
#endif
        }
    }
}

// MARK: - Scoring Prompt View
struct ScoringPromptView: View {
    @EnvironmentObject var gameManager: GameManager
    let onComplete: () -> Void
    @State private var teamScores: [String: Int] = [:]
    
    var body: some View {
        NavigationView {
            VStack(spacing: DesignSystem.spacing.xl) {
                VStack(spacing: DesignSystem.spacing.md) {
                    Text("Time to Score!")
                        .font(.system(size: DesignSystem.fontSize.xl, weight: .bold))
                    
                    Text("Tap teams to cycle through points: 0 → 1 → 2")
                        .font(.system(size: DesignSystem.fontSize.sm))
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                
                // Simple team grid with clickable icons
                LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: DesignSystem.spacing.lg) {
                    ForEach(gameManager.gameSettings.teams) { team in
                        let currentScore = teamScores[team.id.uuidString] ?? 0
                        let hasScored = gameManager.currentRound?.scoredTeams.contains(team.id) ?? false
                        
                        Button(action: {
                            if !hasScored {
                                // Cycle through 0 → 1 → 2 → 0
                                let nextScore = (currentScore + 1) % 3
                                teamScores[team.id.uuidString] = nextScore
                            }
                        }) {
                            VStack(spacing: DesignSystem.spacing.sm) {
                                ZStack {
                                    Circle()
                                        .fill(team.color)
                                        .frame(width: 80, height: 80)
                                        .overlay(
                                            Circle()
                                                .stroke(currentScore > 0 ? DesignSystem.colors.primary : Color.clear, lineWidth: 4)
                                        )
                                    
                                    VStack(spacing: 2) {
                                        Text(String(team.name.prefix(1)))
                                            .foregroundColor(.white)
                                            .font(.system(size: DesignSystem.fontSize.lg, weight: .bold))
                                        
                                        if currentScore > 0 {
                                            Text("\(currentScore)")
                                                .foregroundColor(.white)
                                                .font(.system(size: DesignSystem.fontSize.sm, weight: .bold))
                                                .background(Circle().fill(DesignSystem.colors.primary).frame(width: 20, height: 20))
                                        }
                                    }
                                    
                                    if hasScored {
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundColor(DesignSystem.colors.primary)
                                            .font(.system(size: 30))
                                            .background(Circle().fill(.white))
                                            .offset(x: 25, y: -25)
                                    }
                                }
                                
                                Text(team.name)
                                    .font(.system(size: DesignSystem.fontSize.sm, weight: .semibold))
                                    .foregroundColor(.primary)
                                    .lineLimit(1)
                            }
                        }
                        .disabled(hasScored)
                        .scaleEffect(hasScored ? 0.9 : 1.0)
                        .animation(DesignSystem.animation, value: currentScore)
                        .animation(DesignSystem.animation, value: hasScored)
                    }
                }
                
                Spacer()
                
                // Simple action buttons
                VStack(spacing: DesignSystem.spacing.md) {
                    PrimaryButton(
                        title: "Confirm Scores",
                        action: {
                            // Apply scores for all teams
                            for team in gameManager.gameSettings.teams {
                                let points = teamScores[team.id.uuidString] ?? 0
                                if points > 0 {
                                    // Convert points to title/artist correct booleans
                                    let titleCorrect = points >= 1
                                    let artistCorrect = points >= 2
                                    gameManager.scoreTeam(team, titleCorrect: titleCorrect, artistCorrect: artistCorrect)
                                }
                            }
                            onComplete()
                        }
                    )
                    
                    Button("No one got it right") {
                        onComplete()
                    }
                    .font(.system(size: DesignSystem.fontSize.md))
                    .foregroundColor(.secondary)
                }
            }
            .padding()
            .navigationTitle("Score Round")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Scoring View
struct ScoringView: View {
    let team: Team
    @EnvironmentObject var gameManager: GameManager
    @Environment(\.dismiss) var dismiss
    @State private var titleCorrect = false
    @State private var artistCorrect = false
    
    var points: Int {
        var pts = 0
        if titleCorrect { pts += 1 }
        if artistCorrect { pts += 1 }
        return pts
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: DesignSystem.spacing.xl) {
                // Team Header
                VStack(spacing: DesignSystem.spacing.md) {
                    Circle()
                        .fill(team.color)
                        .frame(width: 100, height: 100)
                        .overlay(
                            Text(String(team.name.prefix(1)))
                                .foregroundColor(.white)
                                .font(.system(size: DesignSystem.fontSize.xxl, weight: .bold))
                        )
                    
                    Text(team.name)
                        .font(.system(size: DesignSystem.fontSize.xl, weight: .semibold))
                }
                
                // Scoring Options
                VStack(spacing: DesignSystem.spacing.lg) {
                    Button(action: { withAnimation { titleCorrect.toggle() } }) {
                        HStack {
                            VStack(alignment: .leading, spacing: DesignSystem.spacing.xs) {
                                Text("Song Title")
                                    .font(.system(size: DesignSystem.fontSize.md, weight: .semibold))
                                Text("Team correctly guessed the song title")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: titleCorrect ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 30))
                                .foregroundColor(titleCorrect ? DesignSystem.colors.primary : .secondary)
                        }
                        .padding()
                        .background(titleCorrect ? DesignSystem.colors.primary.opacity(0.1) : DesignSystem.colors.surface)
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                    
                    Button(action: { withAnimation { artistCorrect.toggle() } }) {
                        HStack {
                            VStack(alignment: .leading, spacing: DesignSystem.spacing.xs) {
                                Text("Artist Name")
                                    .font(.system(size: DesignSystem.fontSize.md, weight: .semibold))
                                Text("Team correctly guessed the artist")
                                    .font(.system(size: DesignSystem.fontSize.sm))
                                    .foregroundColor(.secondary)
                            }
                            Spacer()
                            Image(systemName: artistCorrect ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 30))
                                .foregroundColor(artistCorrect ? DesignSystem.colors.primary : .secondary)
                        }
                        .padding()
                        .background(artistCorrect ? DesignSystem.colors.primary.opacity(0.1) : DesignSystem.colors.surface)
                        .cornerRadius(12)
                    }
                    .buttonStyle(PlainButtonStyle())
                }
                
                // Points Display
                VStack(spacing: DesignSystem.spacing.sm) {
                    Text("Points to Award")
                        .font(.system(size: DesignSystem.fontSize.sm))
                        .foregroundColor(.secondary)
                    
                    Text("\(points)")
                        .font(.system(size: 60, weight: .bold))
                        .foregroundColor(points > 0 ? DesignSystem.colors.primary : .secondary)
                        .animation(DesignSystem.animation, value: points)
                    
                    if points == 2 {
                        Text("Both correct! 🎉")
                            .font(.system(size: DesignSystem.fontSize.md))
                            .foregroundColor(DesignSystem.colors.primary)
                            .transition(.scale.combined(with: .opacity))
                    }
                }
                
                Spacer()
                
                PrimaryButton(
                    title: "Award Points",
                    action: {
                        gameManager.scoreTeam(team, titleCorrect: titleCorrect, artistCorrect: artistCorrect)
                        dismiss()
                    },
                    isEnabled: points > 0
                )
            }
            .padding()
            .navigationTitle("Score Team")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

// MARK: - Game Finished View
struct GameFinishedView: View {
    @EnvironmentObject var gameManager: GameManager
    @State private var showConfetti = false
    
    var sortedTeams: [Team] {
        gameManager.gameSettings.teams.sorted(by: { $0.score > $1.score })
    }
    
    var body: some View {
        VStack(spacing: DesignSystem.spacing.xl) {
            if let winner = gameManager.winner {
                VStack(spacing: DesignSystem.spacing.lg) {
                    Text("🎉 Winner! 🎉")
                        .font(.system(size: DesignSystem.fontSize.xxl, weight: .bold))
                        .scaleEffect(showConfetti ? 1.1 : 1.0)
                        .animation(
                            Animation.easeInOut(duration: 0.5)
                                .repeatCount(3, autoreverses: true),
                            value: showConfetti
                        )
                        .onAppear { showConfetti = true }
                    
                    Circle()
                        .fill(winner.color)
                        .frame(width: 120, height: 120)
                        .overlay(
                            Text("👑")
                                .font(.system(size: 60))
                        )
                        .shadow(color: winner.color.opacity(0.5), radius: 20, x: 0, y: 10)
                    
                    VStack(spacing: DesignSystem.spacing.sm) {
                        Text(winner.name)
                            .font(.system(size: DesignSystem.fontSize.xl, weight: .bold))
                        Text("\(winner.score) points")
                            .font(.system(size: DesignSystem.fontSize.lg))
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.vertical)
            }
            
            Card {
                VStack(alignment: .leading, spacing: DesignSystem.spacing.md) {
                    Text("Final Scores")
                        .font(.system(size: DesignSystem.fontSize.lg, weight: .semibold))
                    
                    ForEach(Array(sortedTeams.enumerated()), id: \.element.id) { index, team in
                        HStack(spacing: DesignSystem.spacing.md) {
                            Text("\(index + 1)")
                                .font(.system(size: DesignSystem.fontSize.md, weight: .semibold))
                                .foregroundColor(.secondary)
                                .frame(width: 30)
                            
                            Circle()
                                .fill(team.color)
                                .frame(width: 32, height: 32)
                                .overlay(
                                    Text(String(team.name.prefix(1)))
                                        .foregroundColor(.white)
                                        .font(.system(size: DesignSystem.fontSize.sm, weight: .bold))
                                )
                            
                            Text(team.name)
                                .font(.system(size: DesignSystem.fontSize.md))
                            
                            Spacer()
                            
                            Text("\(team.score)")
                                .font(.system(size: DesignSystem.fontSize.lg, weight: .bold))
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
                        gameManager.resetScores()
                        gameManager.startGame()
                    }
                )
                
                Button(action: {
                    gameManager.gameState = .setup
                    gameManager.resetScores()
                }) {
                    Text("New Game")
                        .font(.system(size: DesignSystem.fontSize.md))
                        .foregroundColor(DesignSystem.colors.primary)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, DesignSystem.spacing.xl)
        }
    }
}
