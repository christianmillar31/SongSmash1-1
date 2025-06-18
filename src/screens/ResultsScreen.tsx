import React from 'react';
import {
  View,
  StyleSheet,
  ScrollView,
  Alert,
} from 'react-native';
import {
  Card,
  Title,
  Paragraph,
  Button,
  List,
  Divider,
  Chip,
} from 'react-native-paper';
import { useGameStore } from '../store/gameStore';

const ResultsScreen = () => {
  const { teams, gameHistory, resetGame } = useGameStore();

  const handleResetGame = () => {
    Alert.alert(
      'Reset Game',
      'Are you sure you want to reset the entire game? This will clear all scores and history.',
      [
        { text: 'Cancel', style: 'cancel' },
        { 
          text: 'Reset', 
          style: 'destructive', 
          onPress: () => {
            resetGame();
            Alert.alert('Game Reset', 'The game has been reset successfully!');
          }
        },
      ]
    );
  };

  const sortedTeams = [...teams].sort((a, b) => b.score - a.score);

  const getPositionColor = (index: number) => {
    switch (index) {
      case 0: return '#FFD700'; // Gold
      case 1: return '#C0C0C0'; // Silver
      case 2: return '#CD7F32'; // Bronze
      default: return '#e0e0e0';
    }
  };

  const formatDate = (timestamp: string) => {
    return new Date(timestamp).toLocaleTimeString();
  };

  return (
    <View style={styles.container}>
      <ScrollView style={styles.scrollView}>
        {/* Scoreboard */}
        <Card style={styles.scoreboardCard}>
          <Card.Content>
            <Title>Final Scoreboard</Title>
            <Paragraph>Current standings after all rounds</Paragraph>
            
            {sortedTeams.map((team, index) => (
              <View key={team.id} style={styles.teamRow}>
                <View style={styles.positionContainer}>
                  <Chip 
                    style={[
                      styles.positionChip, 
                      { backgroundColor: getPositionColor(index) }
                    ]}
                  >
                    #{index + 1}
                  </Chip>
                </View>
                <View style={styles.teamInfo}>
                  <Title style={styles.teamName}>{team.name}</Title>
                  <Paragraph style={styles.teamScore}>
                    Total Score: {team.score} points
                  </Paragraph>
                </View>
              </View>
            ))}
          </Card.Content>
        </Card>

        {/* Game History */}
        {gameHistory.length > 0 && (
          <Card style={styles.historyCard}>
            <Card.Content>
              <Title>Game History</Title>
              <Paragraph>Recent tracks and scores</Paragraph>
              
              {gameHistory.slice(-5).reverse().map((entry, index) => (
                <View key={index}>
                  <List.Item
                    title={entry.track.name}
                    description={`${entry.track.artists.map((artist: { name: string }) => artist.name).join(', ')}`}
                    left={(props) => (
                      <List.Icon {...props} icon="music" />
                    )}
                    right={() => (
                      <View style={styles.historyScores}>
                        {entry.teamScores.map((teamScore: { teamId: string; teamName: string; score: number }) => (
                          <Chip key={teamScore.teamId} style={styles.scoreChip}>
                            {teamScore.teamName}: {teamScore.score}
                          </Chip>
                        ))}
                      </View>
                    )}
                  />
                  <Paragraph style={styles.timestamp}>
                    {formatDate(entry.timestamp)}
                  </Paragraph>
                  {index < gameHistory.slice(-5).length - 1 && <Divider />}
                </View>
              ))}
            </Card.Content>
          </Card>
        )}

        {/* Statistics */}
        <Card style={styles.statsCard}>
          <Card.Content>
            <Title>Game Statistics</Title>
            <View style={styles.statsRow}>
              <View style={styles.statItem}>
                <Title style={styles.statNumber}>{teams.length}</Title>
                <Paragraph>Teams</Paragraph>
              </View>
              <View style={styles.statItem}>
                <Title style={styles.statNumber}>{gameHistory.length}</Title>
                <Paragraph>Rounds Played</Paragraph>
              </View>
              <View style={styles.statItem}>
                <Title style={styles.statNumber}>
                  {teams.length > 0 ? Math.max(...teams.map(t => t.score)) : 0}
                </Title>
                <Paragraph>Highest Score</Paragraph>
              </View>
            </View>
          </Card.Content>
        </Card>

        {/* Reset Button */}
        <Button
          mode="outlined"
          onPress={handleResetGame}
          style={styles.resetButton}
          icon="refresh"
          buttonColor="#f44336"
          textColor="#f44336"
        >
          Reset Game
        </Button>
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
  scoreboardCard: {
    marginBottom: 16,
  },
  teamRow: {
    flexDirection: 'row',
    alignItems: 'center',
    marginVertical: 8,
    paddingVertical: 8,
  },
  positionContainer: {
    marginRight: 16,
  },
  positionChip: {
    minWidth: 50,
  },
  teamInfo: {
    flex: 1,
  },
  teamName: {
    fontSize: 18,
    fontWeight: 'bold',
  },
  teamScore: {
    fontSize: 16,
    color: '#666',
  },
  historyCard: {
    marginBottom: 16,
  },
  historyScores: {
    alignItems: 'flex-end',
  },
  scoreChip: {
    marginVertical: 2,
    fontSize: 12,
  },
  timestamp: {
    fontSize: 12,
    color: '#999',
    fontStyle: 'italic',
    marginLeft: 56,
  },
  statsCard: {
    marginBottom: 16,
  },
  statsRow: {
    flexDirection: 'row',
    justifyContent: 'space-around',
    marginTop: 16,
  },
  statItem: {
    alignItems: 'center',
  },
  statNumber: {
    fontSize: 24,
    fontWeight: 'bold',
    color: '#1DB954',
  },
  resetButton: {
    marginTop: 16,
    borderColor: '#f44336',
  },
});

export default ResultsScreen; 