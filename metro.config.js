const { getDefaultConfig } = require('expo/metro-config');

const config = getDefaultConfig(__dirname);

// Remove the server.host configuration that's causing validation warnings
// Metro will automatically listen on all interfaces when needed

// Add custom resolver to handle network issues
config.resolver = {
  ...config.resolver,
  platforms: ['ios', 'android', 'native', 'web'],
};

module.exports = config;