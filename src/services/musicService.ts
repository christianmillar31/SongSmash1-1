/**
 * Provider-agnostic music service interface.
 * Implementations: appleMusicService.ts (production), spotifyService.ts (legacy)
 */

export interface MusicTrack {
  id: string;
  name: string;
  artists: Array<{ name: string; id: string }>;
  album: {
    name: string;
    images: Array<{ url: string }>;
    id: string;
    release_date?: string;
  };
  preview_url: string | null;
  external_urls: { web: string };
  popularity: number; // 0-100 (mapped from provider-specific data)
  genres?: string[];
}

export interface TrackFilters {
  genres?: string[];
  decades?: string[];
  difficulty?: string[];
  relaxFilters?: boolean;
}

export interface NoTracksResult {
  noTracks: true;
  attemptedFilters: TrackFilters;
}

export interface MusicService {
  /** Initialize the service (load tokens, etc.) */
  initialize(): Promise<void>;

  /** Authenticate with the music provider. Returns true if successful. */
  authenticate(): Promise<boolean>;

  /** Whether the service is currently authenticated */
  isAuthenticated(): boolean;

  /** Get a random track matching the given filters */
  getRandomTrack(filters: TrackFilters): Promise<MusicTrack | NoTracksResult | null>;

  /** Get available genres for filtering */
  getAvailableGenres(): Promise<string[]>;

  /** Get popular/curated genres */
  getPopularGenres(): Promise<string[]>;

  /** Human-readable explanation of the difficulty system */
  getDifficultyExplanation(): string;

  /** Get the provider name (for UI display) */
  getProviderName(): string;
}
