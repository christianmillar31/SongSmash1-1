import * as SecureStore from 'expo-secure-store';
import Constants from 'expo-constants';
import type { MusicService, MusicTrack, TrackFilters, NoTracksResult } from './musicService';

// Apple Music API base URL
const API_BASE = 'https://api.music.apple.com/v1';

// Default storefront (US). Can be made configurable later.
const DEFAULT_STOREFRONT = 'us';

// Get the developer token from config/env
// This is a JWT signed with your MusicKit private key.
// Generate it using your Apple Developer account Team ID, Key ID, and .p8 private key.
const getDeveloperToken = (): string => {
  return (
    Constants.expoConfig?.extra?.APPLE_MUSIC_DEVELOPER_TOKEN ||
    process.env.APPLE_MUSIC_DEVELOPER_TOKEN ||
    ''
  );
};

// Apple Music genre ID → name mapping for popular genres
const GENRE_MAP: Record<number, string> = {
  14: 'Pop',
  21: 'Rock',
  18: 'Hip-Hop/Rap',
  6: 'Country',
  11: 'Jazz',
  5: 'Classical',
  7: 'Electronic',
  17: 'Dance',
  15: 'R&B/Soul',
  2: 'Blues',
  20: 'Alternative',
  24: 'Reggae',
  12: 'Latin',
  22: 'Singer/Songwriter',
  29: 'World',
  13: 'Folk',
  1153: 'Ambient',
  27: 'Metal',
  28: 'Punk',
  1062: 'Indie',
};

// Reverse map for lookups
const GENRE_NAME_TO_ID: Record<string, number> = {};
for (const [id, name] of Object.entries(GENRE_MAP)) {
  GENRE_NAME_TO_ID[name.toLowerCase()] = Number(id);
}

// Difficulty ranges: maps difficulty level to Apple Music chart position ranges
// Since Apple Music doesn't have a "popularity" score, we use chart positions
// and search result ordering as a proxy:
// - Easy: Top chart songs (well-known)
// - Hard/Expert: Deep catalog searches (obscure)
const DIFFICULTY_RANGES: Record<string, [number, number]> = {
  easy: [70, 100],
  medium: [40, 80],
  hard: [0, 50],
  expert: [0, 30],
};

class AppleMusicService implements MusicService {
  private developerToken: string = '';
  private storefront: string = DEFAULT_STOREFRONT;
  private genreCache: string[] = [];

  constructor() {
    this.developerToken = getDeveloperToken();
  }

  async initialize(): Promise<void> {
    // Load any persisted storefront preference
    const savedStorefront = await SecureStore.getItemAsync('apple_music_storefront');
    if (savedStorefront) {
      this.storefront = savedStorefront;
    }
    // Refresh developer token from config
    this.developerToken = getDeveloperToken();
  }

  async authenticate(): Promise<boolean> {
    // Apple Music catalog access only requires a developer token (JWT).
    // No user authentication needed for search + previews.
    this.developerToken = getDeveloperToken();

    if (!this.developerToken) {
      console.error(
        'Apple Music developer token not configured. ' +
        'Set APPLE_MUSIC_DEVELOPER_TOKEN in your environment or app.config.ts.'
      );
      return false;
    }

    // Verify the token works by making a simple API call
    try {
      const response = await this.apiFetch(`/catalog/${this.storefront}/genres?limit=1`);
      return response.ok;
    } catch {
      return false;
    }
  }

  isAuthenticated(): boolean {
    return !!this.developerToken;
  }

  getProviderName(): string {
    return 'Apple Music';
  }

  getDifficultyExplanation(): string {
    return `Difficulty is based on song recognition:
    \u2022 Easy: Top charting, widely known songs (popularity 70-100)
    \u2022 Medium: Moderately popular songs (popularity 40-80)
    \u2022 Hard: Lesser-known deep cuts (popularity 0-50)
    \u2022 Expert: Very obscure tracks (popularity 0-30)`;
  }

  // ── Genre Methods ──────────────────────────────────────────────

  async getAvailableGenres(): Promise<string[]> {
    if (this.genreCache.length > 0) return this.genreCache;

    try {
      const response = await this.apiFetch(
        `/catalog/${this.storefront}/genres?limit=100`
      );

      if (!response.ok) {
        console.error('Failed to fetch genres:', response.status);
        return Object.values(GENRE_MAP);
      }

      const data = await response.json();
      const genres = (data.data || []).map((g: any) => g.attributes.name as string);
      this.genreCache = genres;
      return genres;
    } catch (error) {
      console.error('Error fetching genres:', error);
      return Object.values(GENRE_MAP);
    }
  }

  async getPopularGenres(): Promise<string[]> {
    return Object.values(GENRE_MAP);
  }

  // ── Track Discovery ────────────────────────────────────────────

  async getRandomTrack(
    filters: TrackFilters
  ): Promise<MusicTrack | NoTracksResult | null> {
    if (!this.developerToken) {
      console.error('No developer token available');
      return null;
    }

    try {
      const searchAttempts = filters.relaxFilters
        ? [
            filters,
            { ...filters, genres: [] },
            { ...filters, genres: [], decades: [] },
            { genres: [], decades: [], difficulty: filters.difficulty },
          ]
        : [filters];

      for (const attemptFilters of searchAttempts) {
        let tracks = await this.discoverTracks(attemptFilters);

        // Apply decade filtering
        tracks = this.filterByDecade(tracks, attemptFilters.decades);

        // Apply difficulty filtering (popularity proxy)
        tracks = this.filterByDifficulty(tracks, attemptFilters.difficulty);

        // Only keep tracks with preview URLs
        tracks = tracks.filter((t) => t.preview_url);

        if (tracks.length > 0) {
          const randomIndex = Math.floor(Math.random() * tracks.length);
          return tracks[randomIndex];
        }
      }

      return { noTracks: true, attemptedFilters: filters };
    } catch (error) {
      console.error('Error fetching track:', error);
      return null;
    }
  }

  // ── Private Helpers ────────────────────────────────────────────

  private async apiFetch(path: string): Promise<Response> {
    return fetch(`${API_BASE}${path}`, {
      headers: {
        Authorization: `Bearer ${this.developerToken}`,
      },
    });
  }

  /**
   * Discover tracks using Apple Music catalog search or charts.
   * Strategy:
   *   - If genres selected → search with genre terms + use chart endpoints
   *   - If no genres → use top charts
   */
  private async discoverTracks(filters: TrackFilters): Promise<MusicTrack[]> {
    const tracks: MusicTrack[] = [];

    if (filters.genres && filters.genres.length > 0) {
      // Strategy 1: Search by genre terms
      const searchResults = await this.searchByGenres(filters.genres);
      tracks.push(...searchResults);

      // Strategy 2: Also try chart songs for those genres
      const chartResults = await this.getChartSongsForGenres(filters.genres);
      tracks.push(...chartResults);
    } else {
      // No genre filter → get top charts across all genres
      const chartResults = await this.getTopCharts();
      tracks.push(...chartResults);

      // Also do a broad search for variety
      const searchTerms = [
        'love', 'night', 'heart', 'dream', 'fire', 'rain', 'sun', 'dance',
        'baby', 'world', 'time', 'life', 'city', 'summer', 'star',
      ];
      const term = searchTerms[Math.floor(Math.random() * searchTerms.length)];
      const searchResults = await this.searchTracks(term, 50);
      tracks.push(...searchResults);
    }

    // Deduplicate by track ID
    const seen = new Set<string>();
    return tracks.filter((t) => {
      if (seen.has(t.id)) return false;
      seen.add(t.id);
      return true;
    });
  }

  private async searchByGenres(genres: string[]): Promise<MusicTrack[]> {
    const allTracks: MusicTrack[] = [];

    // Search for each genre as a keyword (Apple Music search handles genre terms well)
    for (const genre of genres.slice(0, 3)) {
      const results = await this.searchTracks(`${genre} music`, 25);
      allTracks.push(...results);
    }

    return allTracks;
  }

  private async searchTracks(
    term: string,
    limit: number = 25
  ): Promise<MusicTrack[]> {
    try {
      const encodedTerm = encodeURIComponent(term);
      const response = await this.apiFetch(
        `/catalog/${this.storefront}/search?types=songs&term=${encodedTerm}&limit=${limit}`
      );

      if (!response.ok) {
        console.error('Search failed:', response.status);
        return [];
      }

      const data = await response.json();
      const songs = data.results?.songs?.data || [];
      return songs.map((song: any) => this.mapAppleMusicTrack(song));
    } catch (error) {
      console.error('Error searching tracks:', error);
      return [];
    }
  }

  private async getTopCharts(): Promise<MusicTrack[]> {
    try {
      const response = await this.apiFetch(
        `/catalog/${this.storefront}/charts?types=songs&limit=50`
      );

      if (!response.ok) {
        console.error('Charts failed:', response.status);
        return [];
      }

      const data = await response.json();
      const chartData = data.results?.songs?.[0]?.data || [];
      return chartData.map((song: any, index: number) =>
        this.mapAppleMusicTrack(song, this.chartPositionToPopularity(index, chartData.length))
      );
    } catch (error) {
      console.error('Error fetching charts:', error);
      return [];
    }
  }

  private async getChartSongsForGenres(genres: string[]): Promise<MusicTrack[]> {
    const allTracks: MusicTrack[] = [];

    for (const genre of genres.slice(0, 3)) {
      const genreId = this.resolveGenreId(genre);
      if (!genreId) continue;

      try {
        const response = await this.apiFetch(
          `/catalog/${this.storefront}/charts?types=songs&genre=${genreId}&limit=50`
        );

        if (response.ok) {
          const data = await response.json();
          const chartData = data.results?.songs?.[0]?.data || [];
          const mapped = chartData.map((song: any, index: number) =>
            this.mapAppleMusicTrack(song, this.chartPositionToPopularity(index, chartData.length))
          );
          allTracks.push(...mapped);
        }
      } catch (error) {
        console.error(`Error fetching chart for genre ${genre}:`, error);
      }
    }

    return allTracks;
  }

  /**
   * Map an Apple Music API song object to our MusicTrack interface.
   */
  private mapAppleMusicTrack(song: any, popularityOverride?: number): MusicTrack {
    const attrs = song.attributes || {};
    const previews = attrs.previews || [];
    const artwork = attrs.artwork;

    // Build artwork URL (Apple Music uses template URLs with {w}x{h})
    let artworkUrl = '';
    if (artwork?.url) {
      artworkUrl = artwork.url.replace('{w}', '300').replace('{h}', '300');
    }

    return {
      id: song.id,
      name: attrs.name || 'Unknown',
      artists: [
        {
          name: attrs.artistName || 'Unknown Artist',
          id: attrs.artistUrl || '',
        },
      ],
      album: {
        name: attrs.albumName || 'Unknown Album',
        images: artworkUrl ? [{ url: artworkUrl }] : [],
        id: attrs.albumName || '',
        release_date: attrs.releaseDate || undefined,
      },
      preview_url: previews.length > 0 ? previews[0].url : null,
      external_urls: {
        web: attrs.url || `https://music.apple.com/${this.storefront}/song/${song.id}`,
      },
      popularity: popularityOverride ?? this.estimatePopularity(attrs),
      genres: attrs.genreNames || [],
    };
  }

  /**
   * Estimate a popularity score (0-100) from Apple Music metadata.
   * Apple Music doesn't expose a direct popularity number, so we use heuristics.
   */
  private estimatePopularity(attrs: any): number {
    // Default to mid-range. Chart songs get explicit overrides.
    // We could also use play count if available in the future.
    return 50;
  }

  /**
   * Convert a chart position (0-based index) to a popularity score (0-100).
   * Position 0 = most popular = 100, last position = least popular in chart.
   */
  private chartPositionToPopularity(position: number, total: number): number {
    if (total <= 1) return 100;
    // Linear mapping: position 0 → 100, last position → 50 (chart songs are all fairly popular)
    return Math.round(100 - (position / (total - 1)) * 50);
  }

  /**
   * Resolve a genre name to an Apple Music genre ID.
   */
  private resolveGenreId(genreName: string): number | null {
    const lower = genreName.toLowerCase().trim();

    // Direct match
    if (GENRE_NAME_TO_ID[lower]) return GENRE_NAME_TO_ID[lower];

    // Fuzzy match
    for (const [name, id] of Object.entries(GENRE_NAME_TO_ID)) {
      if (name.includes(lower) || lower.includes(name)) return id;
    }

    // Common aliases
    const aliases: Record<string, number> = {
      'hip hop': 18,
      rap: 18,
      'r&b': 15,
      soul: 15,
      edm: 7,
      house: 17,
      techno: 7,
      trance: 7,
      ambient: 1153,
      indie: 1062,
      metal: 27,
      punk: 28,
    };

    return aliases[lower] || null;
  }

  // ── Filtering ──────────────────────────────────────────────────

  private filterByDecade(tracks: MusicTrack[], decades?: string[]): MusicTrack[] {
    if (!decades || decades.length === 0) return tracks;

    const yearRanges = decades
      .map((decade) => {
        const match = decade.match(/^(\d{4})s$/);
        if (!match) return null;
        const start = parseInt(match[1]);
        return [start, start + 9] as [number, number];
      })
      .filter(Boolean) as [number, number][];

    if (yearRanges.length === 0) return tracks;

    return tracks.filter((track) => {
      const releaseDate = track.album.release_date;
      if (!releaseDate) return false;
      const year = parseInt(releaseDate.slice(0, 4));
      return yearRanges.some(([start, end]) => year >= start && year <= end);
    });
  }

  private filterByDifficulty(tracks: MusicTrack[], difficulty?: string[]): MusicTrack[] {
    if (!difficulty || difficulty.length === 0) return tracks;

    const selectedRanges = difficulty
      .filter((d) => DIFFICULTY_RANGES[d])
      .map((d) => DIFFICULTY_RANGES[d]);

    if (selectedRanges.length === 0) return tracks;

    const minPop = Math.min(...selectedRanges.map((r) => r[0]));
    const maxPop = Math.max(...selectedRanges.map((r) => r[1]));

    return tracks.filter((track) => {
      return track.popularity >= minPop && track.popularity <= maxPop;
    });
  }
}

// Singleton instance
export const appleMusicService = new AppleMusicService();
