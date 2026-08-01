# SongSmash - Music Trivia Game

> **The main app now lives in [`native/`](native/)** — a SwiftUI iOS app (open
> `native/SongSmashApp.xcodeproj` in Xcode and run). Teams compete by guessing
> songs: pick genres, decades, difficulty, and a round count; a 30-second
> preview plays; tap the team that knows it, reveal the answer, and score by
> correct title/artist. Music discovery and previews come from Apple's catalog
> via `native/SongSmashApp/Services/MusicService.swift` — **no login required
> for anyone playing**. In DEBUG builds, the `-AutoDemo YES` launch argument
> seeds a demo game and starts playback without any taps.
>
> The React Native app below is the earlier incarnation, kept for reference.

A React Native app built with Expo. Teams compete by guessing songs and earning points. Music discovery and 30-second previews come from Apple's catalog — **no login required for anyone playing**.

## Features

- **Team Management**: Add, edit, and delete up to 6 teams
- **Customizable Filters**: Genres, decades, and difficulty levels
- **In-App Previews**: 30-second previews play directly in the app
- **Difficulty Tiers**: Easy (chart-toppers) → Expert (album deep cuts)
- **Score Tracking**: Manual score entry and real-time scoreboard
- **Game History**: Track all rounds and scores

## How the music side works

The app has two interchangeable backends sharing the same catalog and genre IDs:

1. **iTunes Search/RSS API** (default) — keyless, works out of the box. Genre
   charts via the RSS top-songs feed, decade discovery via search, deep cuts
   via album lookups. Rate-limited (~20 req/min), which the in-app cache keeps
   us well under.
2. **Apple Music API** (optional upgrade) — used automatically when
   `APPLE_MUSIC_DEV_TOKEN` is set. Same features, higher rate limits. Requires
   an Apple Developer Program membership. If a call fails, the app silently
   falls back to iTunes.

Difficulty is derived from chart data:

- **Easy**: top ~40 of the genre chart
- **Medium**: the rest of the chart
- **Hard**: album deep cuts from top-half chart artists
- **Expert**: deep cuts from bottom-half (less famous) chart artists

## Setup

### Prerequisites

- Node.js 18+
- Xcode (for iOS) / Android Studio (for Android)

### Install & run

```bash
npm install
npx expo run:ios       # or: npx expo start, then open in a dev build
```

No accounts, keys, or `.env` file are needed for the default (iTunes) backend.

### Optional: Apple Music API token

With an Apple Developer membership you can generate a developer token for
higher rate limits:

1. In [developer.apple.com/account](https://developer.apple.com/account):
   create a **Media ID** (Identifiers) and a **Key** with
   **Media Services (MusicKit)** enabled; download the `AuthKey_XXXXXXXXXX.p8`.
2. Generate the token (valid up to 180 days):

   ```bash
   node scripts/generate-apple-music-token.mjs \
     --key ~/Downloads/AuthKey_ABC123DEFG.p8 \
     --key-id ABC123DEFG \
     --team-id YOUR_TEAM_ID
   ```

3. Put the output in `.env` (gitignored — never commit the token or the .p8):

   ```
   APPLE_MUSIC_DEV_TOKEN=eyJhbGciOi...
   APPLE_MUSIC_STOREFRONT=us
   ```

4. Rebuild the app so the config is embedded.

## How to Play

1. **Teams Tab**: Add 2-6 teams
2. **Filters Tab**: Pick genres, decades, and difficulty levels
3. **Game Tab**: Press "Play Random Track" — a preview plays; guess the song,
   then enter scores (0-10) per team
4. **Results Tab**: Scoreboard and round history

## Technical Details

- **State Management**: Zustand
- **Navigation**: React Navigation (bottom tabs)
- **UI**: React Native Paper
- **Audio**: Expo AV playing Apple preview URLs
- **Music Data**: `src/services/musicService.ts` (Apple Music API + iTunes fallback)

### Distribution

For sharing with friends: build with EAS or Xcode and distribute via TestFlight
(internal testing needs no App Store review). There are no per-user music-API
limits — nobody logs into anything.

## Troubleshooting

- **"No tracks found"**: Filters may be too narrow (e.g. Expert + 1960s).
  Accept the "Relax Filters" prompt or widen the selection.
- **No audio**: Check the mute switch/volume; previews are streamed, so the
  device needs a network connection.
- **Apple Music API errors in logs**: The token may be expired (max ~6 months).
  Regenerate it, or delete `APPLE_MUSIC_DEV_TOKEN` to use the keyless fallback.

## License

MIT License - feel free to use and modify as needed!
