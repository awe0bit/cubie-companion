export type Route = 'overview' | 'services' | 'devices';
export type Service = { id: string; name: string; state: string; stateText: string };
export type Hardware = { id: string; category: string; name: string; stateText: string };
export type Snapshot = {
  demo: boolean; stale: boolean; refreshing: boolean; error?: string; notice?: string;
  lastContact?: string; inventoryError?: string; inventoryStale: boolean;
  status?: {
    hostname: string; cpuPercent?: number; memoryUsedBytes?: number; memoryTotalBytes?: number;
    diskUsedBytes?: number; diskTotalBytes?: number; uptimeSeconds?: number;
    rxBytesPerSecond?: number; txBytesPerSecond?: number;
    temperatures: { name: string; celsius: number }[]; powerWatts?: number; fanRPM?: number;
  };
  services: Service[];
  network?: { campusText: string };
  inventory?: {
    board: { model?: string; architecture?: string; kernel?: string; cpuCores?: number; memoryBytes?: number };
    devices: Hardware[]; sampledAt: string;
  };
};
export type OTAState = { stage: 'disabled' | 'idle' | 'checking' | 'downloading' | 'pending' | 'current' | 'error'; progress: number; runtime: string; channel: string };
