const fs = require('node:fs');
const path = require('node:path');

const runtime = fs.readFileSync(path.join(__dirname, 'runtime-version.txt'), 'utf8').trim();
if (!/^\d+\.\d+\.\d+$/.test(runtime)) throw new Error('Invalid native runtime version');
// This is a NEW project. Never reuse Tempo's project, owner, token or channels.
const projectId = process.env.CORENEST_EXPO_PROJECT_ID || '';
if (projectId && !/^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(projectId)) {
  throw new Error('CORENEST_EXPO_PROJECT_ID must be a project UUID');
}
const channel = process.env.CORENEST_OTA_CHANNEL || 'production';
if (!['preview', 'production'].includes(channel)) throw new Error('Unknown OTA channel');

module.exports = {
  expo: {
    name: 'CoreNest', slug: 'corenest-ios-runtime', version: '0.9.2',
    platforms: ['ios'], orientation: 'default', userInterfaceStyle: 'automatic',
    ios: { bundleIdentifier: 'org.corenest.app', supportsTablet: true },
    plugins: [
      ['expo-build-properties', { ios: { deploymentTarget: '17.0', usePrecompiledModules: true } }],
      ['expo-brownfield', { ios: { targetName: 'CoreNestRuntime', bundleIdentifier: 'org.corenest.app.runtime' } }],
    ],
    runtimeVersion: runtime,
    updates: projectId ? {
      enabled: true,
      url: `https://u.expo.dev/${projectId}`,
      requestHeaders: { 'expo-channel-name': channel },
      // JS owns foreground checks. Never delay launch or reload a running page.
      checkAutomatically: 'NEVER', fallbackToCacheTimeout: 0,
    } : { enabled: false },
    extra: projectId ? { eas: { projectId } } : {},
  },
};
