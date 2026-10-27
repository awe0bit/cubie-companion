export type Route = 'overview' | 'services' | 'devices';
export type Service = { id: string; name: string; unit: string; state: string; stateText: string };
export type Container = { id: string; name: string; image: string; state: string; controllable: boolean };
export type Hardware = { id: string; category: string; name: string; stateText: string };
export type Snapshot = {
  demo: boolean; stale: boolean; refreshing: boolean; error?: string; notice?: string;
  refreshAcknowledgement?: boolean; live?: boolean; telemetrySession?: string;
  lastContact?: string; inventoryError?: string; inventoryStale: boolean;
  status?: {
    sampledAt: string; hostname: string; cpuPercent?: number; memoryUsedBytes?: number; memoryTotalBytes?: number;
    diskUsedBytes?: number; diskTotalBytes?: number; uptimeSeconds?: number;
    rxBytesPerSecond?: number; txBytesPerSecond?: number;
    temperatures: { name: string; celsius: number }[]; powerWatts?: number; fanRPM?: number;
  };
  services: Service[];
  managementError?: string;
  management?: { containers: Container[]; leds: { id: string; name: string; mode: string; controllable: boolean }[]; dockerAvailable: boolean };
  network?: { campusText: string };
  inventory?: {
    board: { model?: string; architecture?: string; kernel?: string; cpuCores?: number; memoryBytes?: number };
    devices: Hardware[]; sampledAt: string;
  };
};
export type OTAState = { stage: 'disabled' | 'idle' | 'checking' | 'downloading' | 'pending' | 'current' | 'error'; progress: number; runtime: string; channel: string; launchUpdateID: string; embeddedLaunch: boolean; emergencyLaunch: boolean };
