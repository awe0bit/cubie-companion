import type { Snapshot } from './types';

export type Reading = NonNullable<Snapshot['status']>;
export type Metric = 'cpu' | 'temperature' | 'memory' | 'network';
export type Point = { t: number; interval?: number; cpu: number | null; temperature: number | null; memory: number | null; rx: number | null; tx: number | null };
export type Dashboard = { points: Point[]; reading?: Reading };
export const windowMS = 120_000;
const finite = (value: unknown): value is number => typeof value === 'number' && Number.isFinite(value) && value >= 0;

/** Shared between native-hosted roots. Only real source timestamps advance history. */
export class TelemetryWindow {
  private source = '';
  private points: Point[] = [];
  private reading?: Reading;
  private presentedAt = 0;
  accept(snapshot: Snapshot): Dashboard {
    const status = snapshot.status;
    const source = `${snapshot.demo ? 'demo' : 'device'}:${snapshot.telemetrySession ?? status?.hostname ?? ''}`;
    if (source !== this.source) { this.source = source; this.points = []; this.reading = undefined; this.presentedAt = 0; }
    if (!status) return { points: this.points, reading: this.reading };
    const t = Date.parse(status.sampledAt);
    const last = this.points.at(-1);
    if (!Number.isFinite(t) || (last && t <= last.t)) {
      return { points: this.points, reading: this.reading };
    }
    const temperatures = status.temperatures.map(item => item.celsius).filter(value => typeof value === 'number' && Number.isFinite(value));
    this.points = [...this.points.filter(point => point.t >= t - windowMS), {
      t, interval: finite(snapshot.sampleInterval) ? Math.max(1, Math.min(15, snapshot.sampleInterval)) : 1,
      cpu: finite(status.cpuPercent) && status.cpuPercent <= 100 ? status.cpuPercent : null,
      temperature: temperatures.length ? Math.max(...temperatures) : null,
      memory: finite(status.memoryUsedBytes) && finite(status.memoryTotalBytes) && status.memoryTotalBytes > 0
        ? Math.min(100, status.memoryUsedBytes / status.memoryTotalBytes * 100) : null,
      rx: finite(status.rxBytesPerSecond) ? status.rxBytesPerSecond : null,
      tx: finite(status.txBytesPerSecond) ? status.txBytesPerSecond : null,
    }].slice(-121);
    // Charts remain per-sample; displayed numbers change at most once per five sample seconds.
    if (!this.reading || t - this.presentedAt >= 5_000) { this.reading = status; this.presentedAt = t; }
    return { points: this.points, reading: this.reading };
  }
}
export const telemetry = new TelemetryWindow();

/** Split missing/late samples rather than drawing a misleading line through an outage. */
export function plot(points: Point[], key: Exclude<keyof Point, 't' | 'interval'>, maximum: number, width: number, height: number, sampleInterval = 1) {
  const end = points.at(-1)?.t ?? 0;
  let path = '';
  let previous = 0;
  let connected = false;
  let previousInterval = sampleInterval;
  let last: { x: number; y: number } | undefined;
  for (const point of points) {
    const value = point[key];
    if (value == null || !Number.isFinite(value)) { connected = false; continue; }
    const x = Math.max(0, Math.min(width, (point.t - (end - windowMS)) / windowMS * width));
    const y = height - Math.max(0, Math.min(1, value / maximum)) * height;
    const interval = point.interval ?? sampleInterval;
    const safeInterval = Number.isFinite(interval) ? Math.min(15, Math.max(1, interval)) : 1;
    const gap = Math.max(3_500, Math.min(previousInterval, safeInterval) * 1_500);
    path += `${connected && point.t - previous <= gap ? 'L' : 'M'}${x.toFixed(2)},${y.toFixed(2)} `;
    previous = point.t; connected = true; last = { x, y };
    previousInterval = safeInterval;
  }
  return { path: path.trim(), last };
}
