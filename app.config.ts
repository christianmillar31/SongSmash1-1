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
  plugins: [
    'expo-av',
    'expo-secure-store'
  ],
  jsEngine: 'jsc', // Use JSC for maximum compatibility
  extra: {
    // Optional: Apple Music API developer token (see scripts/generate-apple-music-token.mjs).
    // Without it the app falls back to the keyless iTunes Search API.
    APPLE_MUSIC_DEV_TOKEN: process.env.APPLE_MUSIC_DEV_TOKEN || '',
    APPLE_MUSIC_STOREFRONT: process.env.APPLE_MUSIC_STOREFRONT || 'us',
  },
}); 