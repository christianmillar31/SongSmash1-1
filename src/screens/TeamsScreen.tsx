import React, { useState } from 'react';
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
  TextInput,
  FAB,
  Dialog,
  Portal,
  Text,
  IconButton,
} from 'react-native-paper';
import { useGameStore, Team } from '../store/gameStore';

const TeamsScreen = () => {
  const { teams, addTeam, updateTeam, deleteTeam } = useGameStore();
  const [dialogVisible, setDialogVisible] = useState(false);
  const [editingTeam, setEditingTeam] = useState<Team | null>(null);
  const [teamName, setTeamName] = useState('');

  const handleAddTeam = () => {
    if (teams.length >= 6) {
      Alert.alert('Maximum Teams', 'You can only have up to 6 teams.');
      return;
    }
    setEditingTeam(null);
    setTeamName('');
    setDialogVisible(true);
  };

  const handleEditTeam = (team: Team) => {
    setEditingTeam(team);
    setTeamName(team.name);
    setDialogVisible(true);
  };

  const handleDeleteTeam = (team: Team) => {
    if (teams.length <= 2) {
      Alert.alert('Minimum Teams', 'You must have at least 2 teams.');
      return;
    }
    
    Alert.alert(
      'Delete Team',
      `Are you sure you want to delete "${team.name}"?`,
      [
        { text: 'Cancel', style: 'cancel' },
        { text: 'Delete', style: 'destructive', onPress: () => deleteTeam(team.id) },
      ]
    );
  };

  const handleSaveTeam = () => {
    if (!teamName.trim()) {
      Alert.alert('Error', 'Please enter a team name.');
      return;
    }

    if (editingTeam) {
      updateTeam(editingTeam.id, teamName.trim());
    } else {
      addTeam(teamName.trim());
    }

    setDialogVisible(false);
    setTeamName('');
    setEditingTeam(null);
  };

  const handleCancel = () => {
    setDialogVisible(false);
    setTeamName('');
    setEditingTeam(null);
  };

  return (
    <View style={styles.container}>
      <ScrollView style={styles.scrollView}>
        <Card style={styles.infoCard}>
          <Card.Content>
            <Title>Teams ({teams.length}/6)</Title>
            <Paragraph>
              Manage your teams here. You can have between 2-6 teams.
            </Paragraph>
          </Card.Content>
        </Card>

        {teams.map((team) => (
          <Card key={team.id} style={styles.teamCard}>
            <Card.Content>
              <View style={styles.teamHeader}>
                <View style={styles.teamInfo}>
                  <Title>{team.name}</Title>
                  <Paragraph>Score: {team.score}</Paragraph>
                </View>
                <View style={styles.teamActions}>
                  <IconButton
                    icon="pencil"
                    size={20}
                    onPress={() => handleEditTeam(team)}
                  />
                  <IconButton
                    icon="delete"
                    size={20}
                    onPress={() => handleDeleteTeam(team)}
                    disabled={teams.length <= 2}
                  />
                </View>
              </View>
            </Card.Content>
          </Card>
        ))}

        {teams.length < 6 && (
          <Button
            mode="outlined"
            onPress={handleAddTeam}
            style={styles.addButton}
            icon="plus"
          >
            Add Team
          </Button>
        )}
      </ScrollView>

      <Portal>
        <Dialog visible={dialogVisible} onDismiss={handleCancel}>
          <Dialog.Title>
            {editingTeam ? 'Edit Team' : 'Add New Team'}
          </Dialog.Title>
          <Dialog.Content>
            <TextInput
              label="Team Name"
              value={teamName}
              onChangeText={setTeamName}
              mode="outlined"
              autoFocus
            />
          </Dialog.Content>
          <Dialog.Actions>
            <Button onPress={handleCancel}>Cancel</Button>
            <Button onPress={handleSaveTeam}>Save</Button>
          </Dialog.Actions>
        </Dialog>
      </Portal>
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
  teamCard: {
    marginBottom: 12,
  },
  teamHeader: {
    flexDirection: 'row',
    justifyContent: 'space-between',
    alignItems: 'center',
  },
  teamInfo: {
    flex: 1,
  },
  teamActions: {
    flexDirection: 'row',
  },
  addButton: {
    marginTop: 16,
  },
});

export default TeamsScreen; 