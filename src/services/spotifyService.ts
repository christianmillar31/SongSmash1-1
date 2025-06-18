import * as AuthSession from 'expo-auth-session';
import * as Crypto from 'expo-crypto';
import * as SecureStore from 'expo-secure-store';
import { SPOTIFY_CLIENT_ID, SPOTIFY_REDIRECT_URI } from '@env';

// Debug logging for environment variables
console.log('DEBUG: SPOTIFY_CLIENT_ID', SPOTIFY_CLIENT_ID);
console.log('DEBUG: SPOTIFY_REDIRECT_URI', SPOTIFY_REDIRECT_URI);

const SPOTIFY_SCOPES = [
  'user-read-private',
  'user-read-email',
  'playlist-read-private',
  'playlist-read-collaborative',
  'user-library-read'
];

const SPOTIFY_DISCOVERY = {
  authorizationEndpoint: 'https://accounts.spotify.com/authorize',
  tokenEndpoint: 'https://accounts.spotify.com/api/token',
};

export interface SpotifyTrack {
  id: string;
  name: string;
  artists: Array<{ name: string; id: string }>;
  album: { name: string; images: Array<{ url: string }>; id: string; release_date?: string };
  preview_url: string;
  external_urls: { spotify: string };
  popularity: number;
}

export interface SpotifyPlaylist {
  id: string;
  name: string;
  tracks: {
    items: Array<{ track: SpotifyTrack }>;
  };
}

class SpotifyService {
  private accessToken: string | null = null;
  private refreshToken: string | null = null;
  private tokenExpiry: number | null = null;
  private artistGenresCache: Record<string, string[]> = {};
  private albumGenresCache: Record<string, string[]> = {};
  private codeVerifier: string | null = null;

  // Secure storage keys
  private readonly ACCESS_TOKEN_KEY = 'spotify_access_token';
  private readonly REFRESH_TOKEN_KEY = 'spotify_refresh_token';
  private readonly TOKEN_EXPIRY_KEY = 'spotify_token_expiry';

  constructor() {
    this.loadTokensFromStorage();
  }

  // PKCE Helper Methods
  private generateCodeVerifier(): string {
    const array = new Uint8Array(32);
    crypto.getRandomValues(array);
    return this.base64URLEncode(array);
  }

  private async generateCodeChallenge(verifier: string): Promise<string> {
    const hash = await Crypto.digestStringAsync(
      Crypto.CryptoDigestAlgorithm.SHA256,
      verifier,
      { encoding: Crypto.CryptoEncoding.BASE64 }
    );
    // Convert base64 to base64url
    return hash.replace(/\+/g, '-').replace(/\//g, '_').replace(/=/g, '');
  }

  private base64URLEncode(buffer: Uint8Array): string {
    return btoa(String.fromCharCode(...buffer))
      .replace(/\+/g, '-')
      .replace(/\//g, '_')
      .replace(/=/g, '');
  }

  private async loadTokensFromStorage(): Promise<void> {
    try {
      const [accessToken, refreshToken, expiryStr] = await Promise.all([
        SecureStore.getItemAsync(this.ACCESS_TOKEN_KEY),
        SecureStore.getItemAsync(this.REFRESH_TOKEN_KEY),
        SecureStore.getItemAsync(this.TOKEN_EXPIRY_KEY),
      ]);

      if (accessToken && refreshToken && expiryStr) {
        this.accessToken = accessToken;
        this.refreshToken = refreshToken;
        this.tokenExpiry = parseInt(expiryStr, 10);

        // Check if token is expired and refresh if needed
        if (this.isTokenExpired()) {
          await this.refreshAccessToken();
        }
      }
    } catch (error) {
      console.error('Error loading tokens from storage:', error);
    }
  }

  private async saveTokensToStorage(): Promise<void> {
    try {
      await Promise.all([
        SecureStore.setItemAsync(this.ACCESS_TOKEN_KEY, this.accessToken || ''),
        SecureStore.setItemAsync(this.REFRESH_TOKEN_KEY, this.refreshToken || ''),
        SecureStore.setItemAsync(this.TOKEN_EXPIRY_KEY, this.tokenExpiry?.toString() || ''),
      ]);
    } catch (error) {
      console.error('Error saving tokens to storage:', error);
    }
  }

  private async clearTokensFromStorage(): Promise<void> {
    try {
      await Promise.all([
        SecureStore.deleteItemAsync(this.ACCESS_TOKEN_KEY),
        SecureStore.deleteItemAsync(this.REFRESH_TOKEN_KEY),
        SecureStore.deleteItemAsync(this.TOKEN_EXPIRY_KEY),
      ]);
    } catch (error) {
      console.error('Error clearing tokens from storage:', error);
    }
  }

  private isTokenExpired(): boolean {
    if (!this.tokenExpiry) return true;
    // Add 5 minute buffer to refresh before actual expiry
    return Date.now() >= (this.tokenExpiry - 5 * 60 * 1000);
  }

  private async refreshAccessToken(): Promise<boolean> {
    if (!this.refreshToken) return false;

    try {
      const response = await fetch('https://accounts.spotify.com/api/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          grant_type: 'refresh_token',
          refresh_token: this.refreshToken,
          client_id: SPOTIFY_CLIENT_ID,
        }),
      });

      if (response.ok) {
        const data = await response.json();
        this.accessToken = data.access_token;
        this.tokenExpiry = Date.now() + (data.expires_in * 1000);
        
        // Update refresh token if a new one is provided
        if (data.refresh_token) {
          this.refreshToken = data.refresh_token;
        }
        
        await this.saveTokensToStorage();
        return true;
      } else {
        console.error('Failed to refresh token:', response.status);
        await this.clearTokensFromStorage();
        return false;
      }
    } catch (error) {
      console.error('Error refreshing token:', error);
      await this.clearTokensFromStorage();
      return false;
    }
  }

  async authenticate(): Promise<boolean> {
    // Check if we already have a valid token
    if (this.accessToken && !this.isTokenExpired()) {
      return true;
    }

    // Try to refresh the token if we have a refresh token
    if (this.refreshToken && await this.refreshAccessToken()) {
      return true;
    }

    // If no valid token and no refresh token, perform full authentication
    try {
      const request = new AuthSession.AuthRequest({
        clientId: SPOTIFY_CLIENT_ID,
        scopes: [
          'user-read-private',
          'user-read-email',
          'playlist-read-private',
          'playlist-read-collaborative',
          'user-library-read'
        ],
        usePKCE: true,
        redirectUri: SPOTIFY_REDIRECT_URI,
        responseType: AuthSession.ResponseType.Code,
        extraParams: {
          code_challenge_method: 'S256',
        },
      });

      this.codeVerifier = this.generateCodeVerifier();
      const codeChallenge = await this.generateCodeChallenge(this.codeVerifier);

      request.codeChallenge = codeChallenge;

      const result = await request.promptAsync({
        authorizationEndpoint: 'https://accounts.spotify.com/authorize',
      });

      if (result.type === 'success' && result.params.code) {
        await this.exchangeCodeForTokens(request, result.params.code);
        return true;
      }

      return false;
    } catch (error) {
      console.error('Authentication error:', error);
      return false;
    }
  }

  private async exchangeCodeForTokens(request: AuthSession.AuthRequest, code: string): Promise<void> {
    try {
      const response = await fetch('https://accounts.spotify.com/api/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: new URLSearchParams({
          grant_type: 'authorization_code',
          code: code,
          redirect_uri: SPOTIFY_REDIRECT_URI,
          client_id: SPOTIFY_CLIENT_ID,
          code_verifier: this.codeVerifier!,
        }),
      });

      if (response.ok) {
        const data = await response.json();
        this.accessToken = data.access_token;
        this.refreshToken = data.refresh_token;
        this.tokenExpiry = Date.now() + (data.expires_in * 1000);
        
        // Save tokens to secure storage
        await this.saveTokensToStorage();
        
        console.log('Successfully authenticated with Spotify');
      } else {
        const errorText = await response.text();
        console.error('Failed to exchange code for tokens:', response.status, errorText);
        throw new Error(`Token exchange failed: ${response.status}`);
      }
    } catch (error) {
      console.error('Error exchanging code for tokens:', error);
      throw error;
    }
  }

  // Helper method to explain the difficulty system (like the reference code)
  getDifficultyExplanation(): string {
    return `Difficulty is based on track popularity:
    • Easy: Top 25% most popular tracks (popularity 75-100)
    • Medium: Middle 50% of tracks (popularity 25-75) 
    • Hard: Bottom 25% least popular tracks (popularity 0-25)
    • Expert: Same as Hard (very obscure tracks)`;
  }

  // Get popular genres for better filtering
  async getPopularGenres(): Promise<string[]> {
    const allGenres = await this.getAvailableGenres();
    
    // Popular genres from the reference code
    const popularGenres = [
      'pop', 'rock', 'hip hop', 'rap', 'country', 'jazz', 'classical', 'electronic',
      'dance', 'r&b', 'soul', 'blues', 'folk', 'indie', 'alternative', 'metal',
      'punk', 'reggae', 'latin', 'world', 'ambient', 'house', 'techno', 'trance'
    ];
    
    // Filter available genres to only include popular ones
    return allGenres.filter(genre => 
      popularGenres.some(popular => 
        genre.toLowerCase().includes(popular.toLowerCase()) ||
        popular.toLowerCase().includes(genre.toLowerCase())
      )
    );
  }

  // Enhanced genre filtering method inspired by the reference code
  private async getTrackGenres(track: any): Promise<string[]> {
    const genres: string[] = [];
    
    // Get genres from artists
    if (track.artists && track.artists.length > 0) {
      for (const artist of track.artists) {
        if (this.artistGenresCache[artist.id]) {
          genres.push(...this.artistGenresCache[artist.id]);
        } else {
          try {
            const response = await fetch(`https://api.spotify.com/v1/artists/${artist.id}`, {
              headers: {
                'Authorization': `Bearer ${this.accessToken}`,
              },
            });
            
            if (response.ok) {
              const artistData = await response.json();
              const artistGenres = artistData.genres || [];
              this.artistGenresCache[artist.id] = artistGenres;
              genres.push(...artistGenres);
            }
          } catch (error) {
            console.error('Error fetching artist genres:', error);
          }
        }
      }
    }
    
    // Get genres from album
    if (track.album && track.album.id) {
      if (this.albumGenresCache[track.album.id]) {
        genres.push(...this.albumGenresCache[track.album.id]);
      } else {
        try {
          const response = await fetch(`https://api.spotify.com/v1/albums/${track.album.id}`, {
            headers: {
              'Authorization': `Bearer ${this.accessToken}`,
            },
          });
          
          if (response.ok) {
            const albumData = await response.json();
            const albumGenres = albumData.genres || [];
            this.albumGenresCache[track.album.id] = albumGenres;
            genres.push(...albumGenres);
          }
        } catch (error) {
          console.error('Error fetching album genres:', error);
        }
      }
    }
    
    return [...new Set(genres)]; // Remove duplicates
  }

  async getRandomTrack(filters: {
    genres?: string[];
    decades?: string[];
    difficulty?: string[];
    relaxFilters?: boolean;
  }): Promise<SpotifyTrack | { noTracks: true; attemptedFilters: any } | null> {
    const hasValidToken = await this.ensureValidToken();
    if (!hasValidToken) {
      console.error('No valid token available for API call');
      return null;
    }

    try {
      // If relaxFilters is true, try relaxing genre and decade
      let searchAttempts = [filters];
      if (filters.relaxFilters) {
        searchAttempts = [
          { ...filters, genres: [] },
          { ...filters, genres: [], decades: [] },
          { genres: [], decades: [], difficulty: filters.difficulty },
        ];
      }
      
      for (let i = 0; i < searchAttempts.length; i++) {
        const attemptFilters = searchAttempts[i];
        let tracks: any[] = [];

        // Use Spotify's recommendations API for track discovery
        if (attemptFilters.genres && attemptFilters.genres.length > 0) {
          console.log(`DEBUG: Using recommendations API for genres: ${attemptFilters.genres.join(', ')}`);
          
          // Fetch available genre seeds from Spotify
          const availableSeeds = await this.getAvailableGenres();
          // Map user-selected genres to valid Spotify seeds (replace spaces with hyphens, lowercase)
          const validSeeds = attemptFilters.genres
            .map(g => g.toLowerCase().replace(/ /g, '-'))
            .filter(g => availableSeeds.includes(g));
          
          if (validSeeds.length === 0) {
            console.warn('No valid Spotify genre seeds found for selected genres:', attemptFilters.genres);
            continue; // Try next search attempt
          }
          
          // Translate difficulty levels to popularity parameters
          let minPopularity = 0;
          let maxPopularity = 100;
          
          if (attemptFilters.difficulty && attemptFilters.difficulty.length > 0) {
            const difficulties = Array.isArray(attemptFilters.difficulty) ? attemptFilters.difficulty : [];
            if (difficulties.includes('easy')) {
              minPopularity = 70;
              maxPopularity = 100;
            } else if (difficulties.includes('medium')) {
              minPopularity = 40;
              maxPopularity = 80;
            } else if (difficulties.includes('hard')) {
              minPopularity = 0;
              maxPopularity = 50;
            } else if (difficulties.includes('expert')) {
              minPopularity = 0;
              maxPopularity = 30;
            }
          }
          
          // Build recommendations API URL
          const seedGenres = validSeeds.slice(0, 5).map(encodeURIComponent).join(',');
          const recommendationsUrl = `https://api.spotify.com/v1/recommendations?seed_genres=${seedGenres}&min_popularity=${minPopularity}&max_popularity=${maxPopularity}&limit=100`;
          
          console.log(`DEBUG: Recommendations URL: ${recommendationsUrl}`);
          
          const recommendationsResponse = await fetch(recommendationsUrl, {
            headers: {
              'Authorization': `Bearer ${this.accessToken}`,
            },
          });
          
          if (recommendationsResponse.ok) {
            const recommendationsData = await recommendationsResponse.json();
            tracks = recommendationsData.tracks || [];
            console.log(`DEBUG: Tracks from recommendations API: ${tracks.length}`);
          } else {
            const errorText = await recommendationsResponse.text();
            console.error('Error fetching recommendations:', recommendationsResponse.status, errorText);
            continue; // Try next search attempt
          }
        } else {
          // Fallback: use search API for broader results
          console.log(`DEBUG: Using search API as fallback`);
          const searchQuery = 'track:*';
          const apiUrl = `https://api.spotify.com/v1/search?q=${encodeURIComponent(searchQuery)}&type=track&limit=50`;
          
          const response = await fetch(apiUrl, {
            headers: {
              'Authorization': `Bearer ${this.accessToken}`,
            },
          });
          
          if (response.ok) {
            const data = await response.json();
            tracks = (data.tracks && data.tracks.items) ? data.tracks.items : [];
            console.log(`DEBUG: Tracks from search API: ${tracks.length}`);
          }
        }

        // Apply decade filtering
        if (attemptFilters.decades && attemptFilters.decades.length > 0 && tracks.length > 0) {
          const yearRanges = attemptFilters.decades.map((decade: string) => {
            switch (decade) {
              case '1960s': return [1960, 1969];
              case '1970s': return [1970, 1979];
              case '1980s': return [1980, 1989];
              case '1990s': return [1990, 1999];
              case '2000s': return [2000, 2009];
              case '2010s': return [2010, 2019];
              case '2020s': return [2020, 2029];
              default: return null;
            }
          }).filter(Boolean) as [number, number][];
          
          tracks = tracks.filter((track: any) => {
            if (!track.album || !track.album.release_date) return false;
            const year = parseInt(track.album.release_date.slice(0, 4));
            return yearRanges.some(([start, end]) => year >= start && year <= end);
          });
          console.log(`DEBUG: Tracks after decade filtering: ${tracks.length}`);
        }

        // Apply difficulty filtering if not already applied in recommendations
        if ((!attemptFilters.difficulty || attemptFilters.difficulty.length === 0) && tracks.length > 0) {
          // Compute popularity percentiles for difficulty-based filtering
          const pops = tracks.map((t: any) => t.popularity || 0).sort((a: number, b: number) => a - b);
          const percentile = (arr: number[], p: number) => {
            if (arr.length === 0) return 0;
            const idx = Math.floor((p / 100) * arr.length);
            return arr[Math.min(idx, arr.length - 1)];
          };
          
          const easyCut = percentile(pops, 75);
          const hardCut = percentile(pops, 25);
          
          console.log(`DEBUG: Popularity percentiles: easyCut=${easyCut}, hardCut=${hardCut}`);
        }

        // Return a random track if we have any
        if (tracks.length > 0) {
          const randomIndex = Math.floor(Math.random() * tracks.length);
          return tracks[randomIndex];
        }
      }
      
      // If no tracks found, return special value for UI to prompt user
      return { noTracks: true, attemptedFilters: filters };
    } catch (error) {
      console.error('Error fetching track:', error);
      return null;
    }
  }

  isAuthenticated(): boolean {
    return !!this.accessToken;
  }

  getAccessToken(): string | null {
    return this.accessToken;
  }

  async getAvailableGenres(): Promise<string[]> {
    const hasValidToken = await this.ensureValidToken();
    if (!hasValidToken) {
      console.error('No valid token available for API call');
      return [];
    }

    try {
      const response = await fetch('https://api.spotify.com/v1/recommendations/available-genre-seeds', {
        headers: {
          'Authorization': `Bearer ${this.accessToken}`,
        },
      });

      if (!response.ok) {
        const text = await response.text();
        console.error('Error fetching available genres, status:', response.status, text);
        return [];
      }

      const data = await response.json();
      return data.genres || [];
    } catch (error) {
      console.error('Error fetching available genres:', error);
      return [];
    }
  }

  // Fetch genres for multiple artist IDs (up to 50 at a time)
  async getArtistsGenres(artistIds: string[]): Promise<Record<string, string[]>> {
    if (!this.accessToken) {
      const authenticated = await this.authenticate();
      if (!authenticated) return {};
    }
    try {
      const idsParam = artistIds.join(',');
      const response = await fetch(`https://api.spotify.com/v1/artists?ids=${idsParam}`, {
        headers: {
          'Authorization': `Bearer ${this.accessToken}`,
        },
      });
      if (!response.ok) {
        const text = await response.text();
        console.error('Error fetching artists genres, status:', response.status, text);
        return {};
      }
      const data = await response.json();
      const result: Record<string, string[]> = {};
      if (data.artists) {
        for (const artist of data.artists) {
          result[artist.id] = artist.genres || [];
        }
      }
      return result;
    } catch (error) {
      console.error('Error fetching artists genres:', error);
      return {};
    }
  }

  // Get full track URL for tracks without preview
  static getFullTrackUrl(trackId: string): string {
    return `https://open.spotify.com/track/${trackId}`;
  }

  // Check if a track has a preview URL
  static hasPreviewUrl(track: SpotifyTrack): boolean {
    return !!track.preview_url;
  }

  private async ensureValidToken(): Promise<boolean> {
    // If we have a valid token, return true
    if (this.accessToken && !this.isTokenExpired()) {
      return true;
    }

    // If we have a refresh token, try to refresh
    if (this.refreshToken && await this.refreshAccessToken()) {
      return true;
    }

    // If no valid token and refresh failed, authenticate
    return await this.authenticate();
  }
}

export const spotifyService = new SpotifyService(); 