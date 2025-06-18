import { create } from 'zustand';

export interface Team {
  id: string;
  name: string;
  score: number;
}

export interface Filters {
  genres: string[];
  decades: string[];
  difficulty: string[];
}

export interface GameState {
  teams: Team[];
  filters: Filters;
  currentTrack: any;
  gameHistory: any[];
  isPlaying: boolean;
}

interface GameStore extends GameState {
  // Team actions
  addTeam: (name: string) => void;
  updateTeam: (id: string, name: string) => void;
  deleteTeam: (id: string) => void;
  updateTeamScore: (id: string, score: number) => void;
  
  // Filter actions
  updateFilters: (filters: Partial<Filters>) => void;
  
  // Game actions
  setCurrentTrack: (track: any) => void;
  addToHistory: (track: any, scores: Record<string, number>) => void;
  setIsPlaying: (playing: boolean) => void;
  resetGame: () => void;
}

const initialFilters: Filters = {
  genres: [],
  decades: [],
  difficulty: ['easy', 'medium', 'hard', 'expert']
};

const initialTeams: Team[] = [
  { id: '1', name: 'Team 1', score: 0 },
  { id: '2', name: 'Team 2', score: 0 }
];

export const useGameStore = create<GameStore>((set, get) => ({
  teams: initialTeams,
  filters: initialFilters,
  currentTrack: null,
  gameHistory: [],
  isPlaying: false,

  addTeam: (name: string) => {
    const { teams } = get();
    if (teams.length >= 6) return;
    
    const newTeam: Team = {
      id: Date.now().toString(),
      name,
      score: 0
    };
    
    set({ teams: [...teams, newTeam] });
  },

  updateTeam: (id: string, name: string) => {
    const { teams } = get();
    set({
      teams: teams.map(team => 
        team.id === id ? { ...team, name } : team
      )
    });
  },

  deleteTeam: (id: string) => {
    const { teams } = get();
    if (teams.length <= 2) return;
    
    set({
      teams: teams.filter(team => team.id !== id)
    });
  },

  updateTeamScore: (id: string, score: number) => {
    const { teams } = get();
    set({
      teams: teams.map(team => 
        team.id === id ? { ...team, score: team.score + score } : team
      )
    });
  },

  updateFilters: (newFilters: Partial<Filters>) => {
    const { filters } = get();
    set({
      filters: { ...filters, ...newFilters }
    });
  },

  setCurrentTrack: (track: any) => {
    set({ currentTrack: track });
  },

  addToHistory: (track: any, scores: Record<string, number>) => {
    const { gameHistory, teams } = get();
    const historyEntry = {
      track,
      scores,
      timestamp: new Date().toISOString(),
      teamScores: teams.map(team => ({
        teamId: team.id,
        teamName: team.name,
        score: scores[team.id] || 0
      }))
    };
    
    set({ gameHistory: [...gameHistory, historyEntry] });
  },

  setIsPlaying: (playing: boolean) => {
    set({ isPlaying: playing });
  },

  resetGame: () => {
    set({
      teams: initialTeams,
      filters: initialFilters,
      currentTrack: null,
      gameHistory: [],
      isPlaying: false
    });
  }
})); 