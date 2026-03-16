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
  scheme: 'songsmash',
  plugins: [
    'expo-av',
    'expo-secure-store'
  ],
  jsEngine: 'jsc', // Use JSC for maximum compatibility
  extra: {
    // Apple Music developer token (JWT signed with your MusicKit private key).
    // Generate via: https://developer.apple.com/documentation/applemusicapi/generating_developer_tokens
    APPLE_MUSIC_DEVELOPER_TOKEN: process.env.APPLE_MUSIC_DEVELOPER_TOKEN || '',
  },
}); 