/**
 * iTunes Search API service — free, no auth required.
 * Same Apple catalog and preview URLs as MusicKit, but without a developer token.
 * Rate limit: ~20 requests/minute per IP.
 *
 * Use this for development/testing. For production, switch to appleMusicService.ts.
 */

import type { MusicService, MusicTrack, TrackFilters, NoTracksResult } from './musicService';

const API_BASE = 'https://itunes.apple.com';

// iTunes genre IDs (same as Apple Music)
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
  4: 'Folk',
  29: 'World',
  27: 'Metal',
  28: 'Punk',
};

// Reverse lookup
const GENRE_NAME_TO_ID: Record<string, number> = {};
for (const [id, name] of Object.entries(GENRE_MAP)) {
  GENRE_NAME_TO_ID[name.toLowerCase()] = Number(id);
}

// Common aliases → genre ID
const GENRE_ALIASES: Record<string, number> = {
  'hip hop': 18,
  rap: 18,
  'r&b': 15,
  soul: 15,
  edm: 7,
  house: 17,
  techno: 7,
  trance: 7,
  indie: 20,
  metal: 27,
  punk: 28,
  ambient: 7,
  folk: 4,
};

// Difficulty → popularity ranges
const DIFFICULTY_RANGES: Record<string, [number, number]> = {
  easy: [70, 100],
  medium: [40, 80],
  hard: [0, 50],
  expert: [0, 30],
};

// Search terms for variety when no genre is selected
const BROAD_SEARCH_TERMS = [
  'love', 'night', 'heart', 'dream', 'fire', 'rain', 'dance',
  'baby', 'world', 'time', 'life', 'summer', 'star', 'money',
  'city', 'road', 'home', 'light', 'run', 'blue', 'gold',
];

class ItunesSearchService implements MusicService {
  private ready = true; // No auth needed

  async initialize(): Promise<void> {
    // Nothing to initialize — iTunes Search API is open
  }

  async authenticate(): Promise<boolean> {
    // Always authenticated — no API key needed
    // Do a quick connectivity check
    try {
      const resp = await fetch(`${API_BASE}/search?term=test&media=music&limit=1`);
      return resp.ok;
    } catch {
      return false;
    }
  }

  isAuthenticated(): boolean {
    return this.ready;
  }

  getProviderName(): string {
    return 'iTunes';
  }

  getDifficultyExplanation(): string {
    return `Difficulty is based on song recognition:
    \u2022 Easy: Top charting, widely known songs (popularity 70-100)
    \u2022 Medium: Moderately popular songs (popularity 40-80)
    \u2022 Hard: Lesser-known deep cuts (popularity 0-50)
    \u2022 Expert: Very obscure tracks (popularity 0-30)`;
  }

  // ── Genres ─────────────────────────────────────────────────────

  async getAvailableGenres(): Promise<string[]> {
    return Object.values(GENRE_MAP);
  }

  async getPopularGenres(): Promise<string[]> {
    return Object.values(GENRE_MAP);
  }

  // ── Track Discovery ────────────────────────────────────────────

  async getRandomTrack(
    filters: TrackFilters
  ): Promise<MusicTrack | NoTracksResult | null> {
    try {
      const searchAttempts = filters.relaxFilters
        ? [
            filters,
            { ...filters, genres: [] },
            { ...filters, genres: [], decades: [] },
            { genres: [], decades: [], difficulty: filters.difficulty },
          ]
        : [filters];

      for (const attempt of searchAttempts) {
        let tracks = await this.discoverTracks(attempt);

        // Filter by decade
        tracks = this.filterByDecade(tracks, attempt.decades);

        // Filter by difficulty
        tracks = this.filterByDifficulty(tracks, attempt.difficulty);

        // Only tracks with preview URLs
        tracks = tracks.filter((t) => t.preview_url);

        if (tracks.length > 0) {
          return tracks[Math.floor(Math.random() * tracks.length)];
        }
      }

      return { noTracks: true, attemptedFilters: filters };
    } catch (error) {
      console.error('Error fetching track:', error);
      return null;
    }
  }

  // ── Private: Discovery ─────────────────────────────────────────

  private async discoverTracks(filters: TrackFilters): Promise<MusicTrack[]> {
    const allTracks: MusicTrack[] = [];

    if (filters.genres && filters.genres.length > 0) {
      // Search by each genre (both as keyword + genre ID filter)
      for (const genre of filters.genres.slice(0, 3)) {
        const genreId = this.resolveGenreId(genre);
        const results = await this.searchItunes(genre, 50, genreId);
        allTracks.push(...results);
      }
    } else {
      // Broad search with random terms for variety
      const term = BROAD_SEARCH_TERMS[Math.floor(Math.random() * BROAD_SEARCH_TERMS.length)];
      const results = await this.searchItunes(term, 50);
      allTracks.push(...results);

      // Second random term for more variety
      const term2 = BROAD_SEARCH_TERMS[Math.floor(Math.random() * BROAD_SEARCH_TERMS.length)];
      if (term2 !== term) {
        const results2 = await this.searchItunes(term2, 50);
        allTracks.push(...results2);
      }
    }

    // Deduplicate by track ID
    const seen = new Set<string>();
    return allTracks.filter((t) => {
      if (seen.has(t.id)) return false;
      seen.add(t.id);
      return true;
    });
  }

  private async searchItunes(
    term: string,
    limit: number = 50,
    genreId?: number | null
  ): Promise<MusicTrack[]> {
    try {
      const params = new URLSearchParams({
        term,
        media: 'music',
        entity: 'song',
        limit: String(limit),
      });

      if (genreId) {
        params.set('genreId', String(genreId));
      }

      const url = `${API_BASE}/search?${params.toString()}`;
      console.log('iTunes search:', url);

      const response = await fetch(url);

      if (!response.ok) {
        console.error('iTunes search failed:', response.status);
        return [];
      }

      const data = await response.json();
      const results = data.results || [];

      return results
        .filter((item: any) => item.kind === 'song')
        .map((item: any) => this.mapItunesTrack(item));
    } catch (error) {
      console.error('Error searching iTunes:', error);
      return [];
    }
  }

  // ── Private: Mapping ───────────────────────────────────────────

  private mapItunesTrack(item: any): MusicTrack {
    // iTunes artwork URLs come as 100x100. Replace to get larger images.
    const artworkUrl = item.artworkUrl100
      ? item.artworkUrl100.replace('100x100', '600x600')
      : '';

    return {
      id: String(item.trackId),
      name: item.trackName || 'Unknown',
      artists: [
        {
          name: item.artistName || 'Unknown Artist',
          id: String(item.artistId || ''),
        },
      ],
      album: {
        name: item.collectionName || 'Unknown Album',
        images: artworkUrl ? [{ url: artworkUrl }] : [],
        id: String(item.collectionId || ''),
        release_date: item.releaseDate
          ? item.releaseDate.slice(0, 10) // "2023-05-12T00:00:00Z" → "2023-05-12"
          : undefined,
      },
      preview_url: item.previewUrl || null,
      external_urls: {
        web: item.trackViewUrl || '',
      },
      // iTunes doesn't give a popularity score directly.
      // We use a heuristic: higher trackId = newer release.
      // For now, assign a random-ish popularity so difficulty filtering works.
      popularity: this.estimatePopularity(item),
      genres: item.primaryGenreName ? [item.primaryGenreName] : [],
    };
  }

  /**
   * Estimate popularity from iTunes metadata.
   * Uses a combination of: whether it's in a known collection,
   * track number (lower = more likely a single/hit), and randomness.
   */
  private estimatePopularity(item: any): number {
    // Base: mid-range
    let score = 50;

    // Tracks with high track counts in their collection are likely album deep cuts
    if (item.trackCount && item.trackNumber) {
      // Singles/early tracks are usually more popular
      const positionRatio = item.trackNumber / item.trackCount;
      if (positionRatio <= 0.3) score += 15; // Early track (likely single)
      if (positionRatio >= 0.7) score -= 10; // Deep cut
    }

    // Explicit tracks tend to be mainstream hip-hop/pop (slightly higher popularity)
    if (item.trackExplicitness === 'explicit') score += 5;

    // Add some randomness to create variety in difficulty filtering
    score += Math.floor(Math.random() * 20) - 10;

    return Math.max(0, Math.min(100, score));
  }

  // ── Private: Genre Resolution ──────────────────────────────────

  private resolveGenreId(genreName: string): number | null {
    const lower = genreName.toLowerCase().trim();

    // Direct match
    if (GENRE_NAME_TO_ID[lower]) return GENRE_NAME_TO_ID[lower];

    // Alias match
    if (GENRE_ALIASES[lower]) return GENRE_ALIASES[lower];

    // Fuzzy: check if any known genre contains or is contained by the input
    for (const [name, id] of Object.entries(GENRE_NAME_TO_ID)) {
      if (name.includes(lower) || lower.includes(name)) return id;
    }

    return null;
  }

  // ── Private: Filtering ─────────────────────────────────────────

  private filterByDecade(tracks: MusicTrack[], decades?: string[]): MusicTrack[] {
    if (!decades || decades.length === 0) return tracks;

    const yearRanges = decades
      .map((d) => {
        const match = d.match(/^(\d{4})s$/);
        if (!match) return null;
        const start = parseInt(match[1]);
        return [start, start + 9] as [number, number];
      })
      .filter(Boolean) as [number, number][];

    if (yearRanges.length === 0) return tracks;

    return tracks.filter((track) => {
      const rd = track.album.release_date;
      if (!rd) return false;
      const year = parseInt(rd.slice(0, 4));
      return yearRanges.some(([s, e]) => year >= s && year <= e);
    });
  }

  private filterByDifficulty(tracks: MusicTrack[], difficulty?: string[]): MusicTrack[] {
    if (!difficulty || difficulty.length === 0) return tracks;

    const ranges = difficulty
      .filter((d) => DIFFICULTY_RANGES[d])
      .map((d) => DIFFICULTY_RANGES[d]);

    if (ranges.length === 0) return tracks;

    const minPop = Math.min(...ranges.map((r) => r[0]));
    const maxPop = Math.max(...ranges.map((r) => r[1]));

    return tracks.filter((t) => t.popularity >= minPop && t.popularity <= maxPop);
  }
}

// Singleton
export const itunesSearchService = new ItunesSearchService();
