import * as Updates from 'expo-updates';
import { AppState } from 'react-native';
import { reportUpdate, subscribe } from './native';
import type { OTAState } from './types';

// One controller for all three React roots; switching tabs cannot trigger retries.
let task: Promise<void> | undefined;
let checkedAt = 0;
let started = false;
let state: OTAState = {
  stage: Updates.isEnabled ? 'idle' : 'disabled', progress: 0,
  runtime: Updates.runtimeVersion ?? 'embedded', channel: Updates.channel ?? 'not-configured',
};
function publish(stage: OTAState['stage'], progress = 0) {
  state = { ...state, stage, progress };
  reportUpdate(state);
}
export function checkUpdate(force = false): Promise<void> {
  if (!Updates.isEnabled || __DEV__) { publish('disabled'); return Promise.resolve(); }
  if (state.stage === 'pending') { reportUpdate(state); return Promise.resolve(); }
  if (task) return task;
  if (!force && Date.now() - checkedAt < 60 * 60 * 1000) { reportUpdate(state); return Promise.resolve(); }
  checkedAt = Date.now();
  task = (async () => {
    publish('checking');
    const result = await Updates.checkForUpdateAsync();
    if (!result.isAvailable) { publish('current', 1); return; }
    publish('downloading');
    await Updates.fetchUpdateAsync();
    publish('pending', 1);
    // Applied at the next cold launch, never via reloadAsync during a session.
  })().catch(() => publish('error')).finally(() => { task = undefined; });
  return task;
}
export function startUpdates(disableRemote = false) {
  if (started) { reportUpdate(state); return; }
  started = true;
  if (disableRemote) { publish('disabled'); return; }
  void checkUpdate();
  AppState.addEventListener('change', next => { if (next === 'active' && state.stage !== 'pending') void checkUpdate(); });
  subscribe(message => { if (message.command === 'check-update') void checkUpdate(true); });
}
