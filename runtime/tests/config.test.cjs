const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const configPath = require.resolve('../app.config');
function config(project, channel) {
  delete require.cache[configPath];
  delete process.env.CORENEST_EXPO_PROJECT_ID;
  delete process.env.CORENEST_OTA_CHANNEL;
  if (project) process.env.CORENEST_EXPO_PROJECT_ID = project;
  if (channel) process.env.CORENEST_OTA_CHANNEL = channel;
  return require(configPath).expo;
}
test('unconfigured OTA is honestly disabled, embedded pages still ship', () => {
  assert.equal(config().updates.enabled, false);
  assert.equal(config().extra.eas, undefined);
});
test('independent project, explicit channels, no launch stall', () => {
  const c = config('00000000-0000-4000-8000-000000000001', 'preview');
  assert.equal(c.updates.enabled, true);
  assert.equal(c.updates.requestHeaders['expo-channel-name'], 'preview');
  assert.equal(c.updates.checkAutomatically, 'NEVER');
  assert.equal(c.updates.fallbackToCacheTimeout, 0);
  assert.throws(() => config('bad'));
  assert.throws(() => config(undefined, 'other'));
});
test('foreground controller never reloads or logs secrets', () => {
  const s = fs.readFileSync(path.join(__dirname, '../src/updates.ts'), 'utf8');
  assert.ok(!/Updates\.reloadAsync\s*\(/.test(s));
  assert.ok(s.includes('60 * 60 * 1000'));
  assert.ok(!s.includes('console.'));
  assert.ok(s.includes("publish('pending', 1)"));
});
