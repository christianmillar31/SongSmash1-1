import * as AuthSession from 'expo-auth-session';
import * as Crypto from 'expo-crypto';
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
  private artistGenresCache: Record<string, string[]> = {};
  private albumGenresCache: Record<string, string[]> = {};

  async authenticate(): Promise<boolean> {
    try {
      // Use AuthSession.AuthRequest to handle PKCE automatically
      const request = new AuthSession.AuthRequest({
        clientId: SPOTIFY_CLIENT_ID!,
        scopes: SPOTIFY_SCOPES,
        redirectUri: SPOTIFY_REDIRECT_URI!,
        responseType: AuthSession.ResponseType.Code,
        codeChallengeMethod: AuthSession.CodeChallengeMethod.S256,
      });

      // Debug: print the full Spotify Auth URL
      console.log('DEBUG: Full Spotify Auth URL', request.url);

      const result = await request.promptAsync(SPOTIFY_DISCOVERY);

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
      if (!request.codeVerifier) {
        throw new Error('Code verifier not found on AuthRequest');
      }

      const body = [
        `grant_type=authorization_code`,
        `code=${encodeURIComponent(code)}`,
        `redirect_uri=${encodeURIComponent(SPOTIFY_REDIRECT_URI!)}`,
        `client_id=${encodeURIComponent(SPOTIFY_CLIENT_ID!)}`,
        `code_verifier=${encodeURIComponent(request.codeVerifier)}`,
      ].join('&');

      const tokenResponse = await fetch('https://accounts.spotify.com/api/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body,
      });

      const tokenData = await tokenResponse.json();
      console.log('DEBUG: Token exchange response:', JSON.stringify(tokenData, null, 2));
      if (tokenData.access_token) {
        this.accessToken = tokenData.access_token ?? null;
        this.refreshToken = tokenData.refresh_token ?? null;
        console.log('DEBUG: Successfully obtained access token');
      } else {
        console.error('DEBUG: No access token in response:', tokenData);
      }
    } catch (error) {
      console.error('Token exchange error:', error);
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
    const genres: Set<string> = new Set();
    
    // Get genres from album
    if (track.album?.id && !this.albumGenresCache[track.album.id]) {
      try {
        const response = await fetch(`https://api.spotify.com/v1/albums/${track.album.id}`, {
          headers: {
            'Authorization': `Bearer ${this.accessToken}`,
          },
        });
        if (response.ok) {
          const albumData = await response.json();
          this.albumGenresCache[track.album.id] = albumData.genres || [];
        }
      } catch (error) {
        console.error('Error fetching album genres:', error);
      }
    }
    
    if (track.album?.id && this.albumGenresCache[track.album.id]) {
      this.albumGenresCache[track.album.id].forEach((genre: string) => genres.add(genre));
    }

    // Get genres from artists
    const artistIds = track.artists?.map((artist: any) => artist.id).filter(Boolean) || [];
    const uncachedArtists = artistIds.filter((id: string) => !this.artistGenresCache[id]);
    
    if (uncachedArtists.length > 0) {
      try {
        const response = await fetch(`https://api.spotify.com/v1/artists?ids=${uncachedArtists.join(',')}`, {
          headers: {
            'Authorization': `Bearer ${this.accessToken}`,
          },
        });
        if (response.ok) {
          const artistsData = await response.json();
          artistsData.artists.forEach((artist: any) => {
            if (artist && artist.id) {
              this.artistGenresCache[artist.id] = artist.genres || [];
            }
          });
        }
      } catch (error) {
        console.error('Error fetching artist genres:', error);
      }
    }
    
    artistIds.forEach((artistId: string) => {
      if (this.artistGenresCache[artistId]) {
        this.artistGenresCache[artistId].forEach((genre: string) => genres.add(genre));
      }
    });

    return Array.from(genres);
  }

  // Enhanced genre filtering like the reference code
  private async filterTracksByGenre(tracks: any[], selectedGenres: string[]): Promise<any[]> {
    if (selectedGenres.length === 0) return tracks;
    
    const filteredTracks: any[] = [];
    
    for (const track of tracks) {
      const trackGenres = await this.getTrackGenres(track);
      const hasMatchingGenre = selectedGenres.some(selectedGenre => 
        trackGenres.some(trackGenre => 
          trackGenre.toLowerCase().includes(selectedGenre.toLowerCase()) ||
          selectedGenre.toLowerCase().includes(trackGenre.toLowerCase())
        )
      );
      
      if (hasMatchingGenre) {
        filteredTracks.push(track);
      }
    }
    
    return filteredTracks;
  }

  async getRandomTrack(filters: {
    genres?: string[];
    decades?: string[];
    difficulty?: string[];
    relaxFilters?: boolean;
  }): Promise<SpotifyTrack | { noTracks: true; attemptedFilters: any } | null> {
    if (!this.accessToken) {
      const authenticated = await this.authenticate();
      if (!authenticated) return null;
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
        
        // Build search query based on decades
        let searchQuery = 'track:*'; // Default to all tracks
        if (attemptFilters.decades && attemptFilters.decades.length > 0) {
          const yearRanges = attemptFilters.decades.map((decade: string) => {
            switch (decade) {
              case '1960s': return 'year:1960-1969';
              case '1970s': return 'year:1970-1979';
              case '1980s': return 'year:1980-1989';
              case '1990s': return 'year:1990-1999';
              case '2000s': return 'year:2000-2009';
              case '2010s': return 'year:2010-2019';
              case '2020s': return 'year:2020-2029';
              default: return '';
            }
          }).filter(Boolean);
          
          if (yearRanges.length > 0) {
            searchQuery = yearRanges.join(' OR ');
          }
        }
        
        const apiUrl = `https://api.spotify.com/v1/search?q=${encodeURIComponent(searchQuery)}&type=track&limit=50`;
        
        console.log(`DEBUG: Spotify search attempt ${i + 1}:`, searchQuery);
        let response = await fetch(apiUrl, {
          headers: {
            'Authorization': `Bearer ${this.accessToken}`,
          },
        });
        
        if (response.status === 401) {
          console.log('DEBUG: Access token invalid, re-authenticating...');
          const authenticated = await this.authenticate();
          if (!authenticated) return null;
          response = await fetch(apiUrl, {
            headers: {
              'Authorization': `Bearer ${this.accessToken}`,
            },
          });
        }
        
        const data = await response.json();
        let tracks = (data.tracks && data.tracks.items) ? data.tracks.items : [];
        console.log(`DEBUG: Initial tracks found: ${tracks.length}`);

        // If no tracks found, try a broader search
        if (tracks.length === 0) {
          console.log(`DEBUG: No tracks found with "${searchQuery}", trying broader search`);
          const broaderApiUrl = `https://api.spotify.com/v1/search?q=track:*&type=track&limit=50`;
          const broaderResponse = await fetch(broaderApiUrl, {
            headers: {
              'Authorization': `Bearer ${this.accessToken}`,
            },
          });
          
          if (broaderResponse.ok) {
            const broaderData = await broaderResponse.json();
            tracks = (broaderData.tracks && broaderData.tracks.items) ? broaderData.tracks.items : [];
            console.log(`DEBUG: Broader search found: ${tracks.length} tracks`);
          }
        }

        // If still no tracks, try recommendations API
        if (tracks.length === 0) {
          console.log(`DEBUG: Still no tracks, trying recommendations API`);
          const recommendationsUrl = `https://api.spotify.com/v1/recommendations?limit=50&seed_genres=pop&min_popularity=50`;
          const recommendationsResponse = await fetch(recommendationsUrl, {
            headers: {
              'Authorization': `Bearer ${this.accessToken}`,
            },
          });
          
          if (recommendationsResponse.ok) {
            const recommendationsData = await recommendationsResponse.json();
            tracks = recommendationsData.tracks || [];
            console.log(`DEBUG: Recommendations API found: ${tracks.length} tracks`);
          }
        }

        // Decade filtering (existing logic)
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

        // Simple genre filtering using Spotify's search
        if (attemptFilters.genres && attemptFilters.genres.length > 0) {
          console.log(`DEBUG: Attempting genre filtering for: ${attemptFilters.genres.join(', ')}`);
          
          // Try multiple genre search strategies
          const genreStrategies = [
            attemptFilters.genres.join(' '), // All genres together
            attemptFilters.genres[0], // Just first genre
            `genre:${attemptFilters.genres.join(' OR ')}` // Explicit genre search
          ];
          
          for (const genreQuery of genreStrategies) {
            const genreApiUrl = `https://api.spotify.com/v1/search?q=${encodeURIComponent(genreQuery)}&type=track&limit=50`;
            console.log(`DEBUG: Trying genre search strategy: ${genreQuery}`);
            
            const genreResponse = await fetch(genreApiUrl, {
              headers: {
                'Authorization': `Bearer ${this.accessToken}`,
              },
            });
            
            if (genreResponse.ok) {
              const genreData = await genreResponse.json();
              const genreTracks = (genreData.tracks && genreData.tracks.items) ? genreData.tracks.items : [];
              console.log(`DEBUG: Tracks from genre search "${genreQuery}": ${genreTracks.length}`);
              
              if (genreTracks.length > 0) {
                // If we have decade filters, apply them to genre results
                if (attemptFilters.decades && attemptFilters.decades.length > 0) {
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
                  
                  const filteredGenreTracks = genreTracks.filter((track: any) => {
                    if (!track.album || !track.album.release_date) return false;
                    const year = parseInt(track.album.release_date.slice(0, 4));
                    return yearRanges.some(([start, end]) => year >= start && year <= end);
                  });
                  
                  console.log(`DEBUG: Genre tracks after decade filtering: ${filteredGenreTracks.length}`);
                  tracks = filteredGenreTracks;
                } else {
                  tracks = genreTracks;
                }
                
                // If we found tracks, break out of the strategy loop
                if (tracks.length > 0) {
                  console.log(`DEBUG: Successfully found ${tracks.length} tracks with genre strategy: ${genreQuery}`);
                  break;
                }
              }
            }
          }
        }

        // Popularity-based difficulty filtering (existing logic)
        const selectedDifficulties = Array.isArray(attemptFilters.difficulty) ? attemptFilters.difficulty : [];
        if (selectedDifficulties.length > 0 && tracks.length > 0) {
          // Compute popularity percentiles like the reference code
          const pops = tracks.map((t: any) => t.popularity || 0).sort((a: number, b: number) => a - b);
          const percentile = (arr: number[], p: number) => {
            if (arr.length === 0) return 0;
            const idx = Math.floor((p / 100) * arr.length);
            return arr[Math.min(idx, arr.length - 1)];
          };
          
          const easyCut = percentile(pops, 75); // Top 25% most popular
          const hardCut = percentile(pops, 25); // Bottom 25% least popular
          
          const easyTracks = tracks.filter((t: any) => t.popularity >= easyCut);
          const hardTracks = tracks.filter((t: any) => t.popularity <= hardCut);
          const mediumTracks = tracks.filter((t: any) => t.popularity > hardCut && t.popularity < easyCut);
          
          console.log(`DEBUG: Popularity percentiles: easyCut=${easyCut}, hardCut=${hardCut}`);
          console.log(`DEBUG: easyTracks=${easyTracks.length}, mediumTracks=${mediumTracks.length}, hardTracks=${hardTracks.length}`);
          
          let filtered: any[] = [];
          if (selectedDifficulties.includes('easy')) filtered = filtered.concat(easyTracks);
          if (selectedDifficulties.includes('medium')) filtered = filtered.concat(mediumTracks);
          if (selectedDifficulties.includes('hard')) filtered = filtered.concat(hardTracks);
          if (selectedDifficulties.includes('expert')) filtered = filtered.concat(hardTracks); // Expert = hard
          
          // Remove duplicates
          tracks = Array.from(new Set(filtered));
          console.log(`DEBUG: Tracks after difficulty filtering: ${tracks.length}`);
          
          if (tracks.length > 0 && tracks.length < 5) {
            console.warn(`Only ${tracks.length} tracks match your filters. Consider relaxing difficulty or decade.`);
          }
        }

        // Prioritize tracks with preview URLs for in-app playback
        const tracksWithPreview = tracks.filter((track: any) => !!track.preview_url);
        const tracksWithoutPreview = tracks.filter((track: any) => !track.preview_url);
        
        console.log(`DEBUG: Tracks with preview: ${tracksWithPreview.length}`);
        console.log(`DEBUG: Tracks without preview: ${tracksWithoutPreview.length}`);
        
        // For in-app playback, we need tracks with preview URLs
        if (tracksWithPreview.length > 0) {
          tracks = tracksWithPreview;
          console.log(`DEBUG: Using tracks with preview URLs for in-app playback: ${tracks.length}`);
        } else {
          tracks = [];
          console.log(`DEBUG: No tracks with preview URLs found for in-app playback`);
        }

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

  private buildSearchQuery(filters: {
    genres?: string[];
    decades?: string[];
    difficulty?: string[];
  }): string {
    // Simplified query to get more tracks for better filtering
    let query = 'track:*'; // This will match any track

    if (filters.decades && filters.decades.length > 0) {
      const yearRanges = filters.decades.map(decade => {
        switch (decade) {
          case '1960s': return 'year:1960-1969';
          case '1970s': return 'year:1970-1979';
          case '1980s': return 'year:1980-1989';
          case '1990s': return 'year:1990-1999';
          case '2000s': return 'year:2000-2009';
          case '2010s': return 'year:2010-2019';
          case '2020s': return 'year:2020-2029';
          default: return '';
        }
      }).filter(Boolean);
      
      if (yearRanges.length > 0) {
        query += ` (${yearRanges.join(' OR ')})`;
      }
    }

    return query;
  }

  isAuthenticated(): boolean {
    return !!this.accessToken;
  }

  getAccessToken(): string | null {
    return this.accessToken;
  }

  async getAvailableGenres(): Promise<string[]> {
    if (!this.accessToken) {
      const authenticated = await this.authenticate();
      if (!authenticated) return [];
    }
    try {
      let response = await fetch('https://api.spotify.com/v1/recommendations/available-genre-seeds', {
        headers: {
          'Authorization': `Bearer ${this.accessToken}`,
        },
      });
      if (response.status === 401) {
        // Token expired, re-authenticate and retry
        const authenticated = await this.authenticate();
        if (!authenticated) return [];
        response = await fetch('https://api.spotify.com/v1/recommendations/available-genre-seeds', {
          headers: {
            'Authorization': `Bearer ${this.accessToken}`,
          },
        });
      }
      if (!response.ok) {
        const text = await response.text();
        console.error('Error fetching available genres, status:', response.status, text);
        return [];
      }
      const data = await response.json();
      if (data.genres) {
        return data.genres;
      }
      return [];
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
}

export const spotifyService = new SpotifyService(); 