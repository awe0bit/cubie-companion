import type { Container, Service } from './types';
export function acceptsSnapshotClient(target: string | undefined, client: string): boolean {
  return target === undefined || target === client;
}
export function bytes(value: number | null | undefined): string {
  if (value == null || !Number.isFinite(value)) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB']; let index = 0;
  while (value >= 1000 && index < units.length - 1) { value /= 1000; index++; }
  return `${value.toLocaleString('zh-CN', { maximumFractionDigits: 1 })} ${units[index]}`;
}
export function stateText(state: string): string {
  return ({ active: '运行中', running: '运行中', inactive: '已停止', exited: '已停止', failed: '故障', dead: '故障',
    activating: '启动中', deactivating: '停止中', restarting: '重启中', paused: '已暂停', created: '待启动' } as Record<string, string>)[state] ?? '未知';
}
export function groupedServices(services: Service[], containers: Container[], query: string, filter: string) {
  type Item = { id: string; name: string; subtitle: string; state: string; kind: string };
  const groups: { title: string; badge: string; items: Item[] }[] = [
    { title: 'Docker 应用', badge: 'DK', items: filter === '系统' ? [] : containers.map(c => ({ ...c, subtitle: `${c.image} · ${c.controllable ? '可管理' : '只读'}`, kind: 'docker' })) },
    { title: '系统服务', badge: 'SYS', items: filter === 'Docker' ? [] : services.map(s => ({ ...s, subtitle: `${s.unit}${s.controllable === undefined ? '' : s.controllable ? ' · 可管理' : ' · 只读'}`, kind: 'system' })) },
  ];
  const needle = query.trim().toLocaleLowerCase();
  return groups.map(group => ({ ...group, items: group.items.filter(s => `${s.name} ${s.subtitle}`.toLocaleLowerCase().includes(needle))
    .sort((a, b) => Number(['failed', 'dead'].includes(b.state)) - Number(['failed', 'dead'].includes(a.state)) || a.name.localeCompare(b.name)) }))
    .filter(group => group.items.length > 0);
}
