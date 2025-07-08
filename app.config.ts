import { ExpoConfig, ConfigContext } from 'expo/config';

export default ({ config }: ConfigContext): ExpoConfig => ({
  ...config,
  name: 'SongSmash',
  slug: 'songsmash',
  version: '1.0.0',
  orientation: 'portrait',
  icon: './assets/icon.png',
  userInterfaceStyle: 'light',
  splash: {
    image: './assets/splash-icon.png',
    resizeMode: 'contain',
    backgroundColor: '#ffffff'
  },
  assetBundlePatterns: [
    '**/*'
  ],
  ios: {
    supportsTablet: true,
    bundleIdentifier: 'com.songsmash.app'
  },
  android: {
    adaptiveIcon: {
      foregroundImage: './assets/adaptive-icon.png',
      backgroundColor: '#ffffff'
    },
    package: 'com.songsmash.app'
  },
  web: {
    favicon: './assets/favicon.png'
  },
  scheme: 'songbattle',
  // Ensure this matches Info.plist and Spotify dashboard
  plugins: [
    'expo-av',
    'expo-secure-store'
  ],
  jsEngine: 'jsc', // Use JSC for maximum compatibility
  extra: {
    SPOTIFY_CLIENT_ID: process.env.SPOTIFY_CLIENT_ID || 'c4788e07ffa548f78f8101af9c8aa0c5',
    SPOTIFY_REDIRECT_URI: process.env.SPOTIFY_REDIRECT_URI || 'songbattle://spotify-callback',
  },
}); 