const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');

function controller({ enabled = true, available = false, fail = false } = {}) {
  const states = [];
  let checks = 0, downloads = 0, listener;
  const updates = { isEnabled: enabled, runtimeVersion: '0.7.0', channel: 'production',
    updateId: '00000000-0000-4000-8000-000000000001', isEmbeddedLaunch: false, isEmergencyLaunch: false,
    checkForUpdateAsync: async () => { checks++; if (fail) throw new Error('private-network-detail'); return { isAvailable: available }; },
    fetchUpdateAsync: async () => { downloads++; },
  };
  const exports = {};
  const code = ts.transpileModule(fs.readFileSync(require.resolve('../src/updates.ts'), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
  }).outputText;
  vm.runInNewContext(code, { exports, __DEV__: false, Date, Promise,
    require: name => name === 'expo-updates' ? updates : name === 'react-native'
      ? { AppState: { addEventListener: (_, callback) => { listener = callback; } } }
      : { reportUpdate: value => states.push(value), subscribe: () => {} },
  });
  return { exports, states, checks: () => checks, downloads: () => downloads, foreground: () => listener?.('active') };
}

test('concurrent roots share one check and downloaded update is not re-fetched', async () => {
  const c = controller({ available: true });
  await Promise.all([c.exports.checkUpdate(), c.exports.checkUpdate(), c.exports.checkUpdate()]);
  assert.equal(c.checks(), 1);
  assert.equal(c.downloads(), 1);
  assert.equal(c.states.at(-1).stage, 'pending');
  assert.equal(c.states.at(-1).embeddedLaunch, false);
  assert.equal(c.states.at(-1).launchUpdateID, '00000000-0000-4000-8000-000000000001');
  await c.exports.checkUpdate(true);
  assert.equal(c.checks(), 1);
});
test('offline error is generic and automatic retries are throttled', async () => {
  const c = controller({ fail: true });
  await c.exports.checkUpdate();
  assert.equal(c.states.at(-1).stage, 'error');
  assert.ok(!JSON.stringify(c.states).includes('private-network-detail'));
  await c.exports.checkUpdate();
  assert.equal(c.checks(), 1);
  await c.exports.checkUpdate(true);
  assert.equal(c.checks(), 2);
});
test('disabled project never checks, healthy unchanged page never downloads', async () => {
  const disabled = controller({ enabled: false });
  await disabled.exports.checkUpdate();
  assert.equal(disabled.checks(), 0);
  assert.equal(disabled.states.at(-1).stage, 'disabled');
  const healthy = controller();
  await healthy.exports.checkUpdate();
  assert.equal(healthy.states.at(-1).stage, 'current');
  assert.equal(healthy.downloads(), 0);
});
