import React from 'react';
import { NavigationContainer } from '@react-navigation/native';
import { createBottomTabNavigator } from '@react-navigation/bottom-tabs';
import { Provider as PaperProvider } from 'react-native-paper';
import { Ionicons } from '@expo/vector-icons';

import TeamsScreen from '../screens/TeamsScreen';
import FiltersScreen from '../screens/FiltersScreen';
import GameScreen from '../screens/GameScreen';
import ResultsScreen from '../screens/ResultsScreen';

const Tab = createBottomTabNavigator();

const AppNavigator = () => {
  return (
    <PaperProvider>
      <NavigationContainer>
        <Tab.Navigator
          screenOptions={({ route }) => ({
            tabBarIcon: ({ focused, color, size }) => {
              let iconName: keyof typeof Ionicons.glyphMap;

              if (route.name === 'Teams') {
                iconName = focused ? 'people' : 'people-outline';
              } else if (route.name === 'Filters') {
                iconName = focused ? 'filter' : 'filter-outline';
              } else if (route.name === 'Game') {
                iconName = focused ? 'play-circle' : 'play-circle-outline';
              } else if (route.name === 'Results') {
                iconName = focused ? 'trophy' : 'trophy-outline';
              } else {
                iconName = 'help-outline';
              }

              return <Ionicons name={iconName} size={size} color={color} />;
            },
            tabBarActiveTintColor: '#1DB954',
            tabBarInactiveTintColor: 'gray',
            headerStyle: {
              backgroundColor: '#1DB954',
            },
            headerTintColor: '#fff',
            headerTitleStyle: {
              fontWeight: 'bold',
            },
          })}
        >
          <Tab.Screen 
            name="Teams" 
            component={TeamsScreen}
            options={{ title: 'Teams' }}
          />
          <Tab.Screen 
            name="Filters" 
            component={FiltersScreen}
            options={{ title: 'Filters' }}
          />
          <Tab.Screen 
            name="Game" 
            component={GameScreen}
            options={{ title: 'SongSmash' }}
          />
          <Tab.Screen 
            name="Results" 
            component={ResultsScreen}
            options={{ title: 'Results' }}
          />
        </Tab.Navigator>
      </NavigationContainer>
    </PaperProvider>
  );
};

export default AppNavigator; 