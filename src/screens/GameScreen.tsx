import React, { useState, useEffect, useRef } from 'react';
import {
  View,
  StyleSheet,
  ScrollView,
  Alert,
  Image,
  Text,
  Linking,
} from 'react-native';
import {
  Card,
  Title,
  Paragraph,
  Button,
  TextInput,
  ActivityIndicator,
  IconButton,
  Chip,
} from 'react-native-paper';
import { Audio } from 'expo-av';
import { useGameStore } from '../store/gameStore';
import { spotifyService, SpotifyTrack } from '../services/spotifyService';

const GameScreen = () => {
  const { teams, filters, currentTrack, setCurrentTrack, addToHistory, setIsPlaying, isPlaying } = useGameStore();
  const [loading, setLoading] = useState(false);
  const [scores, setScores] = useState<Record<string, string>>({});
  const [showScores, setShowScores] = useState(false);
  const [sound, setSound] = useState<Audio.Sound | null>(null);

  useEffect(() => {
    return sound
      ? () => {
          sound.unloadAsync();
        }
      : undefined;
  }, [sound]);

  const playRandomTrack = async () => {
    if (teams.length < 2) {
      Alert.alert('Not Enough Teams', 'Please add at least 2 teams before starting the game.');
      return;
    }
    if (filters.difficulty.length === 0) {
      Alert.alert('No Difficulty Selected', 'Please select at least one difficulty level.');
      return;
    }
    setLoading(true);
    try {
      let trackOrResult = await spotifyService.getRandomTrack(filters);
      if ('noTracks' in (trackOrResult as any)) {
        Alert.alert(
          'No Track Found',
          'No tracks found for your selected filters. Would you like to relax the filters and try again?',
          [
            { text: 'Cancel', style: 'cancel' },
            {
              text: 'Relax Filters',
              onPress: async () => {
                setLoading(true);
                const relaxedTrack = await spotifyService.getRandomTrack({ ...filters, relaxFilters: true });
                setLoading(false);
                if (relaxedTrack && !('noTracks' in relaxedTrack)) {
                  await playTrackInApp(relaxedTrack);
                } else {
                  Alert.alert('No Track Found', 'No tracks found even after relaxing filters.');
                }
              },
            },
          ]
        );
      } else if (trackOrResult && !('noTracks' in trackOrResult)) {
        await playTrackInApp(trackOrResult);
      } else {
        Alert.alert('No Track Found', 'No tracks found with the current filters.');
      }
    } catch (error) {
      Alert.alert('Error', 'Failed to fetch a random track. Please try again.');
    } finally {
      setLoading(false);
    }
  };

  const playTrackInApp = async (track: SpotifyTrack) => {
    setCurrentTrack(track);
    setShowScores(false);
    setScores({});
    
    try {
      // Check if track has a preview URL (30 seconds)
      if (track.preview_url) {
        console.log('Playing 30-second preview in app');
        const { sound: newSound } = await Audio.Sound.createAsync(
          { uri: track.preview_url },
          { shouldPlay: true, positionMillis: 0 }
        );
        setSound(newSound);
        setIsPlaying(true);
        
        // Set up the onPlaybackStatusUpdate to handle when preview ends
        newSound.setOnPlaybackStatusUpdate((status) => {
          if (status.isLoaded && status.didJustFinish) {
            setIsPlaying(false);
            setShowScores(true);
          }
        });
      } else {
        // No preview URL - open full track in Spotify from beginning
        console.log('Opening full track in Spotify from beginning');
        if (track.external_urls?.spotify) {
          Alert.alert(
            'Full Track in Spotify', 
            'Opening the full track in Spotify from the beginning. Listen to the song, then return here to score!',
            [
              { text: 'Cancel', style: 'cancel' },
              { 
                text: 'Open Spotify', 
                onPress: () => {
                  Linking.openURL(track.external_urls.spotify);
                  // Allow scoring after a delay
                  setTimeout(() => {
                    setIsPlaying(false);
                    setShowScores(true);
                  }, 30000); // 30 seconds
                }
              }
            ]
          );
        } else {
          Alert.alert('Track Unavailable', 'This track is not available for playback.');
          setShowScores(true);
        }
      }
    } catch (error) {
      console.error('Error playing track:', error);
      Alert.alert('Playback Error', 'Could not play the track. You can still score manually.');
      setShowScores(true);
    }
  };

  const stopTrack = async () => {
    if (sound) {
      await sound.stopAsync();
      await sound.unloadAsync();
      setSound(null);
    }
    setIsPlaying(false);
    setShowScores(true);
  };

  const handleScoreChange = (teamId: string, value: string) => {
    setScores(prev => ({ ...prev, [teamId]: value }));
  };

  const submitScores = () => {
    const scoreEntries = Object.entries(scores);
    const validScores: Record<string, number> = {};
    for (const [teamId, scoreStr] of scoreEntries) {
      const score = parseInt(scoreStr);
      if (!isNaN(score) && score >= 0 && score <= 10) {
        validScores[teamId] = score;
      }
    }
    if (Object.keys(validScores).length === 0) {
      Alert.alert('No Valid Scores', 'Please enter at least one valid score (0-10).');
      return;
    }
    addToHistory(currentTrack!, validScores);
    Object.entries(validScores).forEach(([teamId, score]) => {
      useGameStore.getState().updateTeamScore(teamId, score);
    });
    Alert.alert('Scores Submitted', 'Scores have been recorded!');
    setScores({});
    setShowScores(false);
    setCurrentTrack(null);
  };

  const getDifficultyColor = (difficulty: string) => {
    switch (difficulty) {
      case 'easy': return '#4CAF50';
      case 'medium': return '#FF9800';
      case 'hard': return '#F44336';
      case 'expert': return '#9C27B0';
      default: return '#757575';
    }
  };

  const getDifficultyFromPopularity = (popularity: number) => {
    if (popularity >= 75) return 'Easy';
    if (popularity >= 50) return 'Medium';
    if (popularity >= 25) return 'Hard';
    return 'Expert';
  };

  return (
    <View style={styles.container}>
      <ScrollView style={styles.scrollView}>
        {/* Game Controls */}
        <Card style={styles.controlCard}>
          <Card.Content>
            <Title>SongSmash Game</Title>
            <Paragraph>
              Press the button below to play a random track based on your filters.
            </Paragraph>
            <Button
              mode="contained"
              onPress={playRandomTrack}
              loading={loading}
              disabled={loading || isPlaying}
              style={styles.playButton}
              icon="play"
            >
              {loading ? 'Loading...' : 'Play Random Track'}
            </Button>
          </Card.Content>
        </Card>

        {/* Current Track Display */}
        {currentTrack && (
          <Card style={styles.trackCard}>
            <Card.Content>
              {showScores ? (
                // Show track info after guessing phase
                <View style={styles.trackHeader}>
                  <View style={styles.trackInfo}>
                    <Title>{currentTrack.name}</Title>
                    <Paragraph>
                      {currentTrack.artists.map((artist: { name: string }) => artist.name).join(', ')}
                    </Paragraph>
                    <Paragraph>{currentTrack.album.name}</Paragraph>
                    
                    {/* Track characteristics like the reference code */}
                    <View style={styles.trackCharacteristics}>
                      <Chip style={styles.characteristicChip}>
                        Popularity: {currentTrack.popularity || 0}/100
                      </Chip>
                      <Chip style={styles.characteristicChip}>
                        Difficulty: {getDifficultyFromPopularity(currentTrack.popularity || 0)}
                      </Chip>
                      {currentTrack.album.release_date && (
                        <Chip style={styles.characteristicChip}>
                          {currentTrack.album.release_date.slice(0, 4)}
                        </Chip>
                      )}
                    </View>
                  </View>
                  {currentTrack.album.images[0] && (
                    <Image
                      source={{ uri: currentTrack.album.images[0].url }}
                      style={styles.albumArt}
                    />
                  )}
                </View>
              ) : (
                // Show minimal info during guessing phase
                <View style={styles.trackHeader}>
                  <View style={styles.trackInfo}>
                    <Title>🎵 Now Playing</Title>
                    <Paragraph>
                      {currentTrack.preview_url 
                        ? 'Listen to the 30-second preview and guess the song!'
                        : 'Opening full track in Spotify from the beginning. Listen and return here to score!'
                      }
                    </Paragraph>
                    
                    {/* Only show difficulty and year during guessing */}
                    <View style={styles.trackCharacteristics}>
                      <Chip style={styles.characteristicChip}>
                        Difficulty: {getDifficultyFromPopularity(currentTrack.popularity || 0)}
                      </Chip>
                      {currentTrack.album.release_date && (
                        <Chip style={styles.characteristicChip}>
                          {currentTrack.album.release_date.slice(0, 4)}
                        </Chip>
                      )}
                    </View>
                  </View>
                  {currentTrack.album.images[0] && (
                    <Image
                      source={{ uri: currentTrack.album.images[0].url }}
                      style={styles.albumArt}
                    />
                  )}
                </View>
              )}

              {showScores && (
                <View style={styles.scoreSection}>
                  <Title style={styles.scoreTitle}>Enter Scores (0-10)</Title>
                  {teams.map((team) => (
                    <View key={team.id} style={styles.scoreInput}>
                      <TextInput
                        label={`${team.name} Score`}
                        value={scores[team.id] || ''}
                        onChangeText={(value) => handleScoreChange(team.id, value)}
                        keyboardType="numeric"
                        mode="outlined"
                        style={styles.input}
                      />
                    </View>
                  ))}
                  <Button
                    mode="contained"
                    onPress={submitScores}
                    style={styles.submitButton}
                    icon="check"
                  >
                    Submit Scores
                  </Button>
                </View>
              )}

              {isPlaying && currentTrack.preview_url && (
                <View style={styles.controls}>
                  <Button
                    mode="outlined"
                    onPress={stopTrack}
                    icon="stop"
                  >
                    Stop Preview
                  </Button>
                </View>
              )}

              {isPlaying && !currentTrack.preview_url && (
                <View style={styles.controls}>
                  <Button
                    mode="outlined"
                    onPress={() => {
                      setIsPlaying(false);
                      setShowScores(true);
                    }}
                    icon="check"
                  >
                    Done Listening
                  </Button>
                </View>
              )}
            </Card.Content>
          </Card>
        )}

        {/* Current Filters Display */}
        <Card style={styles.filtersCard}>
          <Card.Content>
            <Title>Current Filters</Title>
            <View style={styles.filterChips}>
              {filters.genres.map((genre) => (
                <Chip key={genre} style={styles.chip}>
                  {genre}
                </Chip>
              ))}
              {filters.decades.map((decade) => (
                <Chip key={decade} style={styles.chip}>
                  {decade}
                </Chip>
              ))}
              {filters.difficulty.map((level) => (
                <Chip 
                  key={level} 
                  style={[styles.chip, { backgroundColor: getDifficultyColor(level) }]}
                  textStyle={{ color: 'white' }}
                >
                  {level}
                </Chip>
              ))}
            </View>
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
  controlCard: {
    marginBottom: 16,
  },
  playButton: {
    marginTop: 16,
    backgroundColor: '#1DB954',
  },
  trackCard: {
    marginBottom: 16,
  },
  trackHeader: {
    flexDirection: 'row',
    marginBottom: 16,
  },
  trackInfo: {
    flex: 1,
  },
  albumArt: {
    width: 80,
    height: 80,
    borderRadius: 8,
  },
  controls: {
    marginTop: 16,
  },
  scoreSection: {
    marginTop: 16,
    paddingTop: 16,
    borderTopWidth: 1,
    borderTopColor: '#e0e0e0',
  },
  scoreTitle: {
    marginBottom: 16,
  },
  scoreInput: {
    marginBottom: 12,
  },
  input: {
    backgroundColor: 'white',
  },
  submitButton: {
    marginTop: 16,
    backgroundColor: '#1DB954',
  },
  filtersCard: {
    marginBottom: 16,
  },
  filterChips: {
    flexDirection: 'row',
    flexWrap: 'wrap',
    marginTop: 8,
  },
  chip: {
    margin: 4,
  },
  trackCharacteristics: {
    flexDirection: 'row',
    marginTop: 8,
  },
  characteristicChip: {
    marginRight: 8,
  },
});

export default GameScreen;