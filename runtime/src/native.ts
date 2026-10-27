import * as Brownfield from 'expo-brownfield';
import type { Snapshot } from './types';

type Message = { type?: string; snapshot?: Snapshot; client?: string; command?: string; query?: string };
const listeners = new Set<(message: Message) => void>();
Brownfield.addMessageListener((message: Message) => listeners.forEach(listener => listener(message)));

export function subscribe(listener: (message: Message) => void) {
  listeners.add(listener);
  return () => { listeners.delete(listener); };
}
export function send(client: string, action: string, id?: string) {
  Brownfield.sendMessage({ type: 'corenest.action', client, action, ...(id ? { id } : {}) });
}
export function reportUpdate(state: Record<string, unknown>) {
  Brownfield.sendMessage({ type: 'corenest.ota', ...state });
}
