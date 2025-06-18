import React, { useEffect, useState } from 'react';
import {
  View,
  StyleSheet,
  ScrollView,
  Text,
  Alert,
} from 'react-native';
import {
  Card,
  Title,
  Paragraph,
  Chip,
  Divider,
  Button,
  ActivityIndicator,
} from 'react-native-paper';
import { useGameStore } from '../store/gameStore';
import { spotifyService } from '../services/spotifyService';

const FiltersScreen = () => {
  const { filters, updateFilters } = useGameStore();

  const [genres, setGenres] = useState<string[]>([]);
  const [loadingGenres, setLoadingGenres] = useState(true);
  const [authError, setAuthError] = useState<string | null>(null);
  const [isAuthenticating, setIsAuthenticating] = useState(false);

  const decades = [
    '1960s', '1970s', '1980s', '1990s', '2000s', '2010s', '2020s'
  ];

  const difficultyLevels = ['easy', 'medium', 'hard', 'expert'];

  // Popular genre categories like the reference code
  const genreCategories = {
    'Popular': ['pop', 'rock', 'hip hop', 'rap', 'country'],
    'Electronic': ['electronic', 'dance', 'house', 'techno', 'trance', 'ambient'],
    'Alternative': ['indie', 'alternative', 'folk', 'punk'],
    'Classical': ['classical', 'jazz', 'blues'],
    'World': ['reggae', 'latin', 'world', 'r&b', 'soul', 'metal']
  };

  const fetchGenres = async () => {
    setLoadingGenres(true);
    setAuthError(null);
    
    try {
      // Ensure authentication is completed before fetching genres
      const isAuthenticated = await spotifyService.authenticate();
      
      if (!isAuthenticated) {
        setAuthError('Spotify authentication required to load genres. Please try again.');
        setLoadingGenres(false);
        return;
      }
      
      const popularGenres = await spotifyService.getPopularGenres();
      setGenres(popularGenres);
    } catch (error) {
      console.error('Error fetching genres:', error);
      setAuthError('Failed to load genres. Please check your internet connection and try again.');
    } finally {
      setLoadingGenres(false);
    }
  };

  const handleRetryAuthentication = async () => {
    setIsAuthenticating(true);
    setAuthError(null);
    
    try {
      const isAuthenticated = await spotifyService.authenticate();
      
      if (isAuthenticated) {
        await fetchGenres();
      } else {
        setAuthError('Authentication was cancelled. Genre selection requires Spotify login.');
      }
    } catch (error) {
      console.error('Error during authentication retry:', error);
      setAuthError('Authentication failed. Please try again.');
    } finally {
      setIsAuthenticating(false);
    }
  };

  useEffect(() => {
    fetchGenres();
  }, []);

  const toggleGenre = (genre: string) => {
    const newGenres = filters.genres.includes(genre)
      ? filters.genres.filter(g => g !== genre)
      : [...filters.genres, genre];
    updateFilters({ genres: newGenres });
  };

  const toggleDecade = (decade: string) => {
    const newDecades = filters.decades.includes(decade)
      ? filters.decades.filter(d => d !== decade)
      : [...filters.decades, decade];
    updateFilters({ decades: newDecades });
  };

  const toggleDifficulty = (difficulty: string) => {
    const newDifficulty = filters.difficulty.includes(difficulty)
      ? filters.difficulty.filter(d => d !== difficulty)
      : [...filters.difficulty, difficulty];
    updateFilters({ difficulty: newDifficulty });
  };

  const getChipStyle = (isSelected: boolean) => ({
    margin: 4,
    backgroundColor: isSelected ? '#1DB954' : '#e0e0e0',
  });

  const getChipTextStyle = (isSelected: boolean) => ({
    color: isSelected ? 'white' : 'black',
  });

  return (
    <View style={styles.container}>
      <ScrollView style={styles.scrollView}>
        <Card style={styles.infoCard}>
          <Card.Content>
            <Title>Game Filters</Title>
            <Paragraph>
              Select your preferences to customize the game experience.
            </Paragraph>
          </Card.Content>
        </Card>

        {/* Genres */}
        <Card style={styles.filterCard}>
          <Card.Content>
            <Title>Genres</Title>
            <Paragraph>Select music genres (optional)</Paragraph>
            
            {Object.entries(genreCategories).map(([category, categoryGenres]) => (
              <View key={category} style={styles.genreCategory}>
                <Title style={styles.categoryTitle}>{category}</Title>
                <View style={styles.chipContainer}>
                  {categoryGenres.map((genre) => (
                    <Chip
                      key={genre}
                      selected={filters.genres.includes(genre)}
                      onPress={() => toggleGenre(genre)}
                      style={getChipStyle(filters.genres.includes(genre))}
                      textStyle={getChipTextStyle(filters.genres.includes(genre))}
                    >
                      {genre}
                    </Chip>
                  ))}
                </View>
              </View>
            ))}
            
            <Divider style={styles.divider} />
            <Title style={styles.categoryTitle}>All Available Genres</Title>
            <View style={styles.chipContainer}>
              {loadingGenres ? (
                <View style={styles.loadingContainer}>
                  <ActivityIndicator size="small" color="#1DB954" />
                  <Paragraph style={styles.loadingText}>Loading genres...</Paragraph>
                </View>
              ) : authError ? (
                <View style={styles.errorContainer}>
                  <Paragraph style={styles.errorText}>{authError}</Paragraph>
                  <Button
                    mode="contained"
                    onPress={handleRetryAuthentication}
                    loading={isAuthenticating}
                    disabled={isAuthenticating}
                    style={styles.retryButton}
                    icon="refresh"
                  >
                    {isAuthenticating ? 'Authenticating...' : 'Retry Authentication'}
                  </Button>
                </View>
              ) : genres.length === 0 ? (
                <Paragraph>No genres available.</Paragraph>
              ) : (
                genres.map((genre) => (
                  <Chip
                    key={genre}
                    selected={filters.genres.includes(genre)}
                    onPress={() => toggleGenre(genre)}
                    style={getChipStyle(filters.genres.includes(genre))}
                    textStyle={getChipTextStyle(filters.genres.includes(genre))}
                  >
                    {genre}
                  </Chip>
                ))
              )}
            </View>
          </Card.Content>
        </Card>

        <Divider style={styles.divider} />

        {/* Decades */}
        <Card style={styles.filterCard}>
          <Card.Content>
            <Title>Decades</Title>
            <Paragraph>Select time periods (optional)</Paragraph>
            <View style={styles.chipContainer}>
              {decades.map((decade) => (
                <Chip
                  key={decade}
                  selected={filters.decades.includes(decade)}
                  onPress={() => toggleDecade(decade)}
                  style={getChipStyle(filters.decades.includes(decade))}
                  textStyle={getChipTextStyle(filters.decades.includes(decade))}
                >
                  {decade}
                </Chip>
              ))}
            </View>
          </Card.Content>
        </Card>

        <Divider style={styles.divider} />

        {/* Difficulty Levels */}
        <Card style={styles.filterCard}>
          <Card.Content>
            <Title>Difficulty Levels</Title>
            <Paragraph>Select difficulty levels (at least one required)</Paragraph>
            <Paragraph style={styles.explanationText}>
              {spotifyService.getDifficultyExplanation()}
            </Paragraph>
            <View style={styles.chipContainer}>
              {difficultyLevels.map((level) => (
                <Chip
                  key={level}
                  selected={filters.difficulty.includes(level)}
                  onPress={() => toggleDifficulty(level)}
                  style={getChipStyle(filters.difficulty.includes(level))}
                  textStyle={getChipTextStyle(filters.difficulty.includes(level))}
                >
                  {level.charAt(0).toUpperCase() + level.slice(1)}
                </Chip>
              ))}
            </View>
          </Card.Content>
        </Card>

        {/* Summary */}
        <Card style={styles.summaryCard}>
          <Card.Content>
            <Title>Current Filters</Title>
            <Paragraph>
              <Text style={styles.boldText}>Genres:</Text> {filters.genres.length > 0 ? filters.genres.join(', ') : 'All'}
            </Paragraph>
            <Paragraph>
              <Text style={styles.boldText}>Decades:</Text> {filters.decades.length > 0 ? filters.decades.join(', ') : 'All'}
            </Paragraph>
            <Paragraph>
              <Text style={styles.boldText}>Difficulty:</Text> {filters.difficulty.join(', ')}
            </Paragraph>
          </Card.Content>
        </Card>
      </ScrollView>
    </View>
  );
};

const styles = StyleSheet.create({
  container: {
    flex: 1,
    backgroundColor: '#f5f5f5',
  },
  scrollView: {
    flex: 1,
    padding: 16,
  },
  infoCard: {
    marginBottom: 16,
  },
  filterCard: {
    marginBottom: 16,
  },
  summaryCard: {
    marginBottom: 16,
    backgroundColor: '#e8f5e8',
  },
  chipContainer: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    marginTop: 8,
  },
  divider: {
    marginVertical: 8,
  },
  boldText: {
    fontWeight: 'bold',
  },
  genreCategory: {
    marginBottom: 16,
  },
  categoryTitle: {
    marginBottom: 8,
  },
  unavailableChip: {
    backgroundColor: '#e0e0e0',
  },
  explanationText: {
    marginBottom: 8,
  },
  loadingContainer: {
    flexDirection: 'row',
    alignItems: 'center',
    paddingVertical: 8,
  },
  loadingText: {
    marginLeft: 8,
    color: '#666',
  },
  errorContainer: {
    flexDirection: 'column',
    alignItems: 'center',
    paddingVertical: 8,
  },
  errorText: {
    marginBottom: 8,
    color: '#d32f2f',
    textAlign: 'center',
  },
  retryButton: {
    marginTop: 8,
    backgroundColor: '#1DB954',
  },
});

export default FiltersScreen; 