// Music discovery + previews via Apple, replacing the removed Spotify APIs.
//
// Two backends, same catalog and genre IDs:
//  - Apple Music API (api.music.apple.com) — used when APPLE_MUSIC_DEV_TOKEN is
//    configured. Higher rate limits. Token is a developer JWT; no user login.
//  - iTunes Search/RSS (itunes.apple.com) — keyless fallback, used when no
//    token is set or an Apple Music call fails. Rate-limited (~20 req/min),
//    which the pool cache keeps us well under.
//
// Neither backend needs the player to authenticate, so there is no OAuth,
// token storage, or per-user allowlist anywhere in the app.

export type Difficulty = 'easy' | 'medium' | 'hard' | 'expert';

export interface Track {
  id: string;
  name: string;
  artistName: string;
  albumName: string;
  albumId: string | null;
  artworkUrl: string | null;
  releaseDate: string | null; // ISO date string
  previewUrl: string | null; // ~30s audio preview
  externalUrl: string | null; // Apple Music page for the track
  genreName: string | null;
  difficulty: Difficulty;
}

export interface TrackFilters {
  genres?: string[];
  decades?: string[];
  difficulty?: string[];
  relaxFilters?: boolean;
}

export type NoTracksResult = { noTracks: true; attemptedFilters: TrackFilters };

// Apple genre IDs are shared between the Apple Music API and iTunes
// (verified against https://itunes.apple.com/WebObjects/MZStoreServices.woa/ws/genres).
const GENRES: Record<string, number> = {
  'Pop': 14,
  'Rock': 21,
  'Alternative': 20,
  'Hip-Hop/Rap': 18,
  'R&B/Soul': 15,
  'Country': 6,
  'Dance': 17,
  'Electronic': 7,
  'Jazz': 11,
  'Blues': 2,
  'Classical': 5,
  'Latin': 12,
  'Reggae': 24,
  'Metal': 1153,
  'Folk': 1289,
  'Soundtrack': 16,
};

// Terms accepted as a match when filtering search results by genre label.
const GENRE_MATCHERS: Record<string, string[]> = {
  'Hip-Hop/Rap': ['hip-hop', 'hip hop', 'rap'],
  'R&B/Soul': ['r&b', 'soul'],
  'Dance': ['dance', 'electronic'],
  'Metal': ['metal', 'hard rock', 'rock'],
  'Folk': ['folk', 'singer/songwriter'],
};

const DECADE_RANGES: Record<string, [number, number]> = {
  '1960s': [1960, 1969],
  '1970s': [1970, 1979],
  '1980s': [1980, 1989],
  '1990s': [1990, 1999],
  '2000s': [2000, 2009],
  '2010s': [2010, 2019],
  '2020s': [2020, 2029],
};

const ALL_DIFFICULTIES: Difficulty[] = ['easy', 'medium', 'hard', 'expert'];

// Chart rank below this is "easy"; the rest of the chart is "medium".
const EASY_CHART_CUTOFF = 40;
// How many chart artists to mine for album deep cuts per difficulty tier.
const DEEP_CUT_SOURCES = 6;
const DEEP_CUTS_PER_ALBUM = 2;

function getConfigExtra(): Record<string, any> {
  try {
    // Resolved by Metro in the app; falls through in plain Node (tests/scripts).
    const Constants = require('expo-constants').default;
    return Constants?.expoConfig?.extra ?? {};
  } catch {
    return {};
  }
}

function decadeShorthand(decade: string): string {
  // '1980s' -> '80s'
  return decade.length === 5 ? decade.slice(2) : decade;
}

function pickRandom<T>(items: T[]): T {
  return items[Math.floor(Math.random() * items.length)];
}

function sampleWithoutReplacement<T>(items: T[], count: number): T[] {
  const copy = [...items];
  const out: T[] = [];
  while (copy.length > 0 && out.length < count) {
    out.push(copy.splice(Math.floor(Math.random() * copy.length), 1)[0]);
  }
  return out;
}

class MusicService {
  private devToken: string;
  private storefront: string;
  // Set when an Apple Music API call fails; we then stay on iTunes for the session.
  private appleMusicDown = false;

  private chartCache = new Map<string, Track[]>();
  private albumCache = new Map<string, Track[]>();
  private searchCache = new Map<string, Track[]>();
  private playedIds = new Set<string>();

  constructor() {
    const extra = getConfigExtra();
    this.devToken = extra.APPLE_MUSIC_DEV_TOKEN || '';
    this.storefront = (extra.APPLE_MUSIC_STOREFRONT || 'us').toLowerCase();
  }

  getAvailableGenres(): string[] {
    return Object.keys(GENRES);
  }

  getDifficultyExplanation(): string {
    return `Difficulty is based on how well-known a song is:
    • Easy: current chart-toppers in the genre
    • Medium: songs further down the charts
    • Hard: album deep cuts from popular artists
    • Expert: deep cuts from lesser-known charting artists`;
  }

  async getRandomTrack(filters: TrackFilters): Promise<Track | NoTracksResult | null> {
    const attempts: TrackFilters[] = filters.relaxFilters
      ? [
          { ...filters, genres: [] },
          { ...filters, genres: [], decades: [] },
          { difficulty: filters.difficulty },
        ]
      : [filters];

    try {
      for (const attempt of attempts) {
        let pool = await this.buildPool(attempt);

        // Prefer tracks playable in-app; only fall back to link-out tracks
        // when previews are scarce.
        const withPreview = pool.filter(t => t.previewUrl);
        if (withPreview.length >= 5) pool = withPreview;

        let candidates = pool.filter(t => !this.playedIds.has(t.id));
        if (candidates.length === 0) candidates = pool; // exhausted: allow repeats

        if (candidates.length > 0) {
          const pick = pickRandom(candidates);
          this.playedIds.add(pick.id);
          return pick;
        }
      }
      return { noTracks: true, attemptedFilters: filters };
    } catch (error) {
      console.error('Error fetching track:', error);
      return null;
    }
  }

  // ---- Pool construction ----------------------------------------------------

  private async buildPool(filters: TrackFilters): Promise<Track[]> {
    const wanted = new Set<Difficulty>(
      (filters.difficulty && filters.difficulty.length > 0
        ? filters.difficulty.filter((d): d is Difficulty => ALL_DIFFICULTIES.includes(d as Difficulty))
        : ALL_DIFFICULTIES)
    );
    const decades = (filters.decades ?? []).filter(d => DECADE_RANGES[d]);
    const genreNames = (filters.genres ?? []).filter(g => GENRES[g] !== undefined);
    const genreKeys: (string | null)[] = genreNames.length > 0 ? genreNames : [null];

    const pool: Track[] = [];
    for (const genre of genreKeys) {
      const chart = await this.getChartTracks(genre);
      const chartInDecades = this.filterByDecades(chart, decades);
      pool.push(...chartInDecades.filter(t => wanted.has(t.difficulty)));

      if (wanted.has('hard') || wanted.has('expert')) {
        const cuts = await this.getDeepCuts(chart, wanted);
        pool.push(...this.filterByDecades(cuts, decades));
      }

      // Charts skew recent, so decade filters need their own search pass.
      for (const decade of decades) {
        const found = await this.getDecadeTracks(decade, genre);
        pool.push(...found.filter(t => wanted.has(t.difficulty)));
      }
    }

    const seen = new Set<string>();
    return pool.filter(t => (seen.has(t.id) ? false : (seen.add(t.id), true)));
  }

  private filterByDecades(tracks: Track[], decades: string[]): Track[] {
    if (decades.length === 0) return tracks;
    const ranges = decades.map(d => DECADE_RANGES[d]);
    return tracks.filter(t => {
      if (!t.releaseDate) return false;
      const year = parseInt(t.releaseDate.slice(0, 4), 10);
      return ranges.some(([start, end]) => year >= start && year <= end);
    });
  }

  private matchesGenre(label: string | null, genre: string | null): boolean {
    if (!genre) return true;
    if (!label) return false;
    const needle = label.toLowerCase();
    const matchers = GENRE_MATCHERS[genre] ?? [genre.toLowerCase()];
    return matchers.some(m => needle.includes(m) || m.includes(needle));
  }

  // Top-of-chart tracks for a genre (or overall), tiered easy/medium by rank.
  private async getChartTracks(genre: string | null): Promise<Track[]> {
    const cacheKey = `chart:${genre ?? 'all'}`;
    const cached = this.chartCache.get(cacheKey);
    if (cached) return cached;

    let tracks: Track[] = [];
    if (this.useAppleMusic()) {
      try {
        tracks = await this.appleChartTracks(genre);
      } catch (error) {
        this.demoteAppleMusic(error);
      }
    }
    if (tracks.length === 0) {
      tracks = await this.itunesChartTracks(genre);
    }

    tracks.forEach((t, i) => {
      t.difficulty = i < EASY_CHART_CUTOFF ? 'easy' : 'medium';
    });
    this.chartCache.set(cacheKey, tracks);
    return tracks;
  }

  // Album tracks that never charted: 'hard' from top-half chart artists,
  // 'expert' from bottom-half (less famous) chart artists.
  private async getDeepCuts(chart: Track[], wanted: Set<Difficulty>): Promise<Track[]> {
    const chartIds = new Set(chart.map(t => t.id));
    const half = Math.floor(chart.length / 2);
    const segments: Array<[Difficulty, Track[]]> = [];
    if (wanted.has('hard')) segments.push(['hard', chart.slice(0, half)]);
    if (wanted.has('expert')) segments.push(['expert', chart.slice(half)]);

    const cuts: Track[] = [];
    for (const [tier, segment] of segments) {
      const sources = sampleWithoutReplacement(segment, DEEP_CUT_SOURCES);
      for (const source of sources) {
        try {
          const albumTracks = await this.getAlbumTracks(source);
          const fresh = albumTracks.filter(t => t.id !== source.id && !chartIds.has(t.id));
          for (const cut of sampleWithoutReplacement(fresh, DEEP_CUTS_PER_ALBUM)) {
            cuts.push({ ...cut, difficulty: tier });
          }
        } catch (error) {
          console.warn('Deep cut lookup failed, skipping album:', error);
        }
      }
    }
    return cuts;
  }

  // Songs from a decade (optionally within a genre), tiered by search rank.
  private async getDecadeTracks(decade: string, genre: string | null): Promise<Track[]> {
    const cacheKey = `decade:${decade}:${genre ?? 'all'}`;
    const cached = this.searchCache.get(cacheKey);
    if (cached) return cached;

    const term = `${decadeShorthand(decade)} ${genre ?? 'hits'}`.trim();
    let results: Track[] = [];
    if (this.useAppleMusic()) {
      try {
        results = await this.appleSearchTracks(term);
      } catch (error) {
        this.demoteAppleMusic(error);
      }
    }
    if (results.length === 0) {
      results = await this.itunesSearchTracks(term);
    }

    const [start, end] = DECADE_RANGES[decade];
    const filtered = results.filter(t => {
      if (!t.releaseDate) return false;
      const year = parseInt(t.releaseDate.slice(0, 4), 10);
      if (year < start || year > end) return false;
      return this.matchesGenre(t.genreName, genre);
    });

    filtered.forEach((t, i) => {
      t.difficulty = i < 40 ? 'easy' : i < 120 ? 'medium' : 'hard';
    });
    this.searchCache.set(cacheKey, filtered);
    return filtered;
  }

  private async getAlbumTracks(source: Track): Promise<Track[]> {
    let albumId = source.albumId;
    if (!albumId && this.useAppleMusic()) {
      albumId = await this.appleAlbumIdForSong(source.id);
    }
    if (!albumId) return [];

    const cached = this.albumCache.get(albumId);
    if (cached) return cached;

    let tracks: Track[] = [];
    if (this.useAppleMusic()) {
      try {
        tracks = await this.appleAlbumTracks(albumId);
      } catch (error) {
        this.demoteAppleMusic(error);
      }
    }
    if (tracks.length === 0) {
      tracks = await this.itunesAlbumTracks(albumId);
    }
    this.albumCache.set(albumId, tracks);
    return tracks;
  }

  // ---- Apple Music API backend (developer token) ----------------------------

  private useAppleMusic(): boolean {
    return this.devToken.length > 0 && !this.appleMusicDown;
  }

  private demoteAppleMusic(error: unknown): void {
    if (!this.appleMusicDown) {
      console.warn('Apple Music API unavailable, falling back to iTunes:', error);
      this.appleMusicDown = true;
    }
  }

  private async appleFetch(pathAndQuery: string): Promise<any> {
    const response = await fetch(
      `https://api.music.apple.com/v1/catalog/${this.storefront}${pathAndQuery}`,
      { headers: { Authorization: `Bearer ${this.devToken}` } }
    );
    if (!response.ok) {
      throw new Error(`Apple Music API ${response.status} for ${pathAndQuery}`);
    }
    return response.json();
  }

  private mapAppleSong(song: any): Track | null {
    const a = song?.attributes;
    if (!song?.id || !a?.name) return null;
    return {
      id: String(song.id),
      name: a.name,
      artistName: a.artistName ?? '',
      albumName: a.albumName ?? '',
      albumId: song.relationships?.albums?.data?.[0]?.id ?? null,
      artworkUrl: a.artwork?.url
        ? String(a.artwork.url).replace('{w}', '300').replace('{h}', '300')
        : null,
      releaseDate: a.releaseDate ?? null,
      previewUrl: a.previews?.[0]?.url ?? null,
      externalUrl: a.url ?? null,
      genreName: a.genreNames?.[0] ?? null,
      difficulty: 'medium',
    };
  }

  private async appleChartTracks(genre: string | null): Promise<Track[]> {
    const genreParam = genre ? `&genre=${GENRES[genre]}` : '';
    const tracks: Track[] = [];
    for (const offset of [0, 50]) {
      const data = await this.appleFetch(
        `/charts?types=songs&limit=50&offset=${offset}${genreParam}`
      );
      const songs = data?.results?.songs?.[0]?.data ?? [];
      for (const song of songs) {
        const track = this.mapAppleSong(song);
        if (track) tracks.push(track);
      }
      if (songs.length < 50) break;
    }
    return tracks;
  }

  private async appleSearchTracks(term: string): Promise<Track[]> {
    const tracks: Track[] = [];
    for (const offset of [0, 25]) {
      const data = await this.appleFetch(
        `/search?types=songs&term=${encodeURIComponent(term)}&limit=25&offset=${offset}`
      );
      const songs = data?.results?.songs?.data ?? [];
      for (const song of songs) {
        const track = this.mapAppleSong(song);
        if (track) tracks.push(track);
      }
      if (songs.length < 25) break;
    }
    return tracks;
  }

  private async appleAlbumIdForSong(songId: string): Promise<string | null> {
    try {
      const data = await this.appleFetch(`/songs/${songId}?include=albums`);
      return data?.data?.[0]?.relationships?.albums?.data?.[0]?.id ?? null;
    } catch (error) {
      this.demoteAppleMusic(error);
      return null;
    }
  }

  private async appleAlbumTracks(albumId: string): Promise<Track[]> {
    const data = await this.appleFetch(`/albums/${albumId}`);
    const songs = data?.data?.[0]?.relationships?.tracks?.data ?? [];
    const tracks: Track[] = [];
    for (const song of songs) {
      if (song?.type && song.type !== 'songs') continue;
      const track = this.mapAppleSong(song);
      if (track) tracks.push({ ...track, albumId });
    }
    return tracks;
  }

  // ---- iTunes backend (no key required) -------------------------------------

  private mapItunesTrack(r: any): Track | null {
    if (!r?.trackId || !r?.trackName) return null;
    return {
      id: String(r.trackId),
      name: r.trackName,
      artistName: r.artistName ?? '',
      albumName: r.collectionName ?? '',
      albumId: r.collectionId ? String(r.collectionId) : null,
      artworkUrl: r.artworkUrl100 ?? null,
      releaseDate: r.releaseDate ?? null,
      previewUrl: r.previewUrl ?? null,
      externalUrl: r.trackViewUrl ?? null,
      genreName: r.primaryGenreName ?? null,
      difficulty: 'medium',
    };
  }

  private async itunesChartTracks(genre: string | null): Promise<Track[]> {
    const genreSegment = genre ? `/genre=${GENRES[genre]}` : '';
    const rssUrl = `https://itunes.apple.com/${this.storefront}/rss/topsongs/limit=100${genreSegment}/json`;
    const rssResponse = await fetch(rssUrl);
    if (!rssResponse.ok) {
      throw new Error(`iTunes RSS ${rssResponse.status} for genre ${genre}`);
    }
    const rss = await rssResponse.json();
    const entries = rss?.feed?.entry ?? [];
    const ids: string[] = entries
      .map((e: any) => e?.id?.attributes?.['im:id'])
      .filter(Boolean);
    if (ids.length === 0) return [];

    // The RSS feed lacks release dates and album IDs; a batch lookup fills
    // in full track metadata while preserving chart order.
    const byId = await this.itunesLookup(ids);
    return ids
      .map(id => byId.get(id))
      .filter((t): t is Track => Boolean(t));
  }

  private async itunesLookup(ids: string[]): Promise<Map<string, Track>> {
    const response = await fetch(
      `https://itunes.apple.com/lookup?id=${ids.join(',')}&country=${this.storefront}`
    );
    if (!response.ok) throw new Error(`iTunes lookup ${response.status}`);
    const data = await response.json();
    const byId = new Map<string, Track>();
    for (const r of data?.results ?? []) {
      if (r?.wrapperType !== 'track') continue;
      const track = this.mapItunesTrack(r);
      if (track) byId.set(track.id, track);
    }
    return byId;
  }

  private async itunesSearchTracks(term: string): Promise<Track[]> {
    const url =
      `https://itunes.apple.com/search?term=${encodeURIComponent(term)}` +
      `&entity=song&limit=200&country=${this.storefront}`;
    const response = await fetch(url);
    if (!response.ok) throw new Error(`iTunes search ${response.status}`);
    const data = await response.json();
    const tracks: Track[] = [];
    for (const r of data?.results ?? []) {
      const track = this.mapItunesTrack(r);
      if (track) tracks.push(track);
    }
    return tracks;
  }

  private async itunesAlbumTracks(albumId: string): Promise<Track[]> {
    const response = await fetch(
      `https://itunes.apple.com/lookup?id=${albumId}&entity=song&country=${this.storefront}`
    );
    if (!response.ok) throw new Error(`iTunes album lookup ${response.status}`);
    const data = await response.json();
    const tracks: Track[] = [];
    for (const r of data?.results ?? []) {
      if (r?.wrapperType !== 'track') continue;
      const track = this.mapItunesTrack(r);
      if (track) tracks.push(track);
    }
    return tracks;
  }
}

export const musicService = new MusicService();
