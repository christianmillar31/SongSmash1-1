# SongSmash - Music Trivia Game

A React Native app built with Expo that creates a music trivia game using the Spotify Web API. Teams compete by guessing songs and earning points.

## Features

- **Team Management**: Add, edit, and delete up to 6 teams
- **Customizable Filters**: Select genres, decades, and difficulty levels
- **Spotify Integration**: Play random tracks based on your filters
- **Score Tracking**: Manual score entry and real-time scoreboard
- **Game History**: Track all rounds and scores
- **Modern UI**: Clean interface using React Native Paper

## Authentication Requirements

**Important**: Genre selection requires Spotify authentication. When you first access the Filters screen, the app will prompt you to log in to your Spotify account. This is necessary to:

- Load the complete list of available genres from Spotify
- Access personalized track recommendations
- Ensure proper API access for track discovery

If you cancel the authentication process, genre selection will be limited to predefined categories. You can retry authentication at any time using the "Retry Authentication" button in the Filters screen.

## Setup Instructions

### 1. Prerequisites

- Node.js (v16 or higher)
- Expo CLI (`npm install -g @expo/cli`)
- Expo Go app on your iOS/Android device
- Spotify Developer Account

### 2. Spotify API Setup

1. Go to [Spotify Developer Dashboard](https://developer.spotify.com/dashboard)
2. Create a new app
3. Get your `Client ID`
4. **Important for PKCE Flow**: You do NOT need to store the Client Secret in your app. The PKCE flow is designed to work without it for mobile apps.
5. **Configure Redirect URI**: In your Spotify app settings, add the redirect URI: `exp://localhost:8081/--/spotify-auth-callback`

### 3. Environment Configuration

1. Copy your Spotify Client ID from the dashboard
2. Create a `.env` file in the project root:
   ```bash
   # Create the .env file
   touch .env
   ```
3. Add the following content to your `.env` file:
   ```
   SPOTIFY_CLIENT_ID=your_spotify_client_id_here
   SPOTIFY_REDIRECT_URI=exp://localhost:8081/--/spotify-auth-callback
   ```
4. Replace `your_spotify_client_id_here` with your actual Spotify Client ID

### 4. Installation

```bash
# Install dependencies
npm install

# Start the development server
npx expo start
```

### 5. Running the App

1. Run `npx expo start` in your terminal
2. Scan the QR code with Expo Go on your device
3. The app will load and you can start playing!

## How to Play

1. **Teams Tab**: Add 2-6 teams to participate
2. **Filters Tab**: Select your preferred genres, decades, and difficulty levels
3. **Game Tab**: Press "Play Random Track" to start a round
   - The track will play for 30 seconds
   - Enter scores (0-10) for each team
   - Submit scores to record them
4. **Results Tab**: View the scoreboard and game history

## Technical Details

### Architecture

- **State Management**: Zustand for global state
- **Navigation**: React Navigation with bottom tabs
- **UI Components**: React Native Paper
- **Audio**: Expo AV for track playback
- **Authentication**: Expo Auth Session with PKCE flow

### Spotify API Integration

The app uses the Spotify Web API with OAuth PKCE flow:

- **No Client Secret Required**: PKCE flow is designed for mobile apps without server-side components
- **Scopes**: `user-read-private`, `user-read-email`, `playlist-read-private`, `playlist-read-collaborative`, `user-library-read`
- **Search**: Uses Spotify's search API with custom filters

### Environment Variables

- `SPOTIFY_CLIENT_ID`: Your Spotify app's client ID
- `SPOTIFY_REDIRECT_URI`: OAuth redirect URI (configured for Expo development)

## Troubleshooting

### Common Issues

1. **"No tracks found"**: Try adjusting your filters or ensure you have a Spotify Premium account
2. **Authentication fails**: Check your Client ID and ensure your Spotify app is properly configured
3. **Audio doesn't play**: Some tracks may not have preview URLs available
4. **Genres not loading**: 
   - Ensure you complete the Spotify authentication process
   - Check your internet connection
   - Use the "Retry Authentication" button if authentication was cancelled
   - Verify your Spotify app is properly configured in the developer dashboard

### Authentication Issues

- **"Spotify authentication required"**: Complete the login process when prompted
- **"Authentication was cancelled"**: Use the retry button to attempt authentication again
- **"Authentication failed"**: Check your internet connection and Spotify app configuration
- **Limited genre selection**: This indicates authentication is needed - complete the login process

### Development Notes

- The app uses Expo's managed workflow
- All Spotify API calls are made client-side
- No backend server required
- Works offline for team management and scoring

## License

MIT License - feel free to use and modify as needed! 