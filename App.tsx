import React from 'react';
import { StatusBar, Text, View } from 'react-native';
import AppNavigator from './src/navigation/AppNavigator';

class ErrorBoundary extends React.Component<{children: React.ReactNode}, {hasError: boolean, error?: string}> {
  constructor(props: {children: React.ReactNode}) {
    super(props);
    this.state = { hasError: false };
  }

  static getDerivedStateFromError(error: any) {
    return { hasError: true, error: error.toString() };
  }

  render() {
    if (this.state.hasError) {
      return (
        <View style={{flex: 1, justifyContent: 'center', alignItems: 'center', padding: 20}}>
          <Text style={{fontSize: 18, marginBottom: 10}}>Something went wrong:</Text>
          <Text style={{fontSize: 14, color: 'red'}}>{this.state.error}</Text>
        </View>
      );
    }

    return this.props.children;
  }
}

export default function App() {
  return (
    <ErrorBoundary>
      <StatusBar barStyle="light-content" />
      <AppNavigator />
    </ErrorBoundary>
  );
}
