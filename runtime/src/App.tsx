import React, { useEffect, useRef, useState } from 'react';
import Svg, { Path, Rect, Circle } from 'react-native-svg';
import { Keyboard, Pressable, RefreshControl, ScrollView, StyleSheet, Text, TextInput, useColorScheme, useWindowDimensions, View } from 'react-native';
import { send, subscribe } from './native';
import { startUpdates } from './updates';
import { ManualRefresh } from './refresh';
import { TrendCard } from './TrendCard';
import { DeveloperTools } from './DeveloperTools';
import { telemetry } from './telemetry';
import { layout, palette } from './theme';
import { acceptsSnapshotClient, bytes, groupedServices, stateText } from './presentation';
import type { Route, Snapshot } from './types';

type Props = { route: Route; client: string; snapshotJSON: string; appearance?: 'light' | 'dark'; disableRemoteUpdates?: boolean; bottomInset?: number; nativeSearch?: boolean; searchQuery?: string; nativeToolbar?: boolean; serviceFilter?: string };
export default function App({ route, client, snapshotJSON, appearance, disableRemoteUpdates = false, bottomInset = 0, nativeSearch = false, searchQuery = '', nativeToolbar = false, serviceFilter = '全部' }: Props) {
  const [snapshot, setSnapshot] = useState<Snapshot>(() => JSON.parse(snapshotJSON));
  const [dashboard, setDashboard] = useState(() => telemetry.accept(snapshot));
  const [filter, setFilter] = useState(serviceFilter);
  const [query, setQuery] = useState(searchQuery);
  const [pulling, setPulling] = useState(false);
  const [refreshFeedback, setRefreshFeedback] = useState('');
  const manualRefresh = useRef<ManualRefresh | null>(null);
  if (!manualRefresh.current) manualRefresh.current = new ManualRefresh(
    () => send(client, 'refresh'), (pulling, feedback) => { setPulling(pulling); setRefreshFeedback(feedback); });
  const system = useColorScheme();
  const dark = (appearance === 'light' || appearance === 'dark' ? appearance : system) === 'dark';
  const colors = palette(dark);
  const { width, fontScale } = useWindowDimensions();
  const narrow = fontScale > 1.4 || width < 350;
  const act = (action: string, id?: string) => send(client, action, id);
  useEffect(() => {
    const unsubscribe = subscribe(message => {
      if (message.type === 'corenest.snapshot' && message.snapshot && acceptsSnapshotClient(message.client, client)) {
        setSnapshot(message.snapshot);
        setDashboard(telemetry.accept(message.snapshot));
        manualRefresh.current?.snapshot(message.snapshot.refreshing, message.snapshot.refreshAcknowledgement === true);
      }
      if (message.type === 'corenest.refresh' && message.client === client) {
        manualRefresh.current?.finish();
      }
      if (message.command === 'search' && message.client === client && typeof message.query === 'string') {
        setQuery(message.query.slice(0, 128));
      }
      if (message.command === 'filter' && message.client === client && ['全部', 'Docker', '系统'].includes(message.query ?? '')) {
        setFilter(message.query!);
      }
    });
    act('ready'); startUpdates(disableRemoteUpdates);
    return () => { unsubscribe(); manualRefresh.current?.dispose(); };
  }, [client]);
  const label = (value: string, secondary = false, size = 13) => <Text style={{ color: secondary ? colors.quiet : colors.ink, fontSize: size }}>{value}</Text>;
  const card = (children: React.ReactNode, key?: string, flush = false) => <View key={key} style={[styles.card, { backgroundColor: colors.surface, padding: flush ? 0 : layout.cardInset }]}>{children}</View>;
  const separator = <View style={{ height: StyleSheet.hairlineWidth, backgroundColor: colors.separator, marginHorizontal: 14 }} />;
  const link = (title: string, subtitle: string, action: string, id: string, deviceID?: string, badge?: string, state?: string) => (
    <Pressable key={id} accessibilityRole="button" accessibilityLabel={`${title}${state ? `，${stateText(state)}` : ''}`} testID={id} onPress={() => act(action, deviceID)}
      style={({ pressed }) => [styles.link, { opacity: pressed ? .55 : 1 }]}>
      {badge && <View style={[styles.icon, { backgroundColor: colors.background }]}>
        <RowIcon kind={badge} color={colors.quiet} />
      </View>}
      <View style={styles.linkText}>
        <Text numberOfLines={narrow ? undefined : 1} style={{ color: colors.ink, fontSize: 17, fontWeight: '500' }}>{title}</Text>
        {!!subtitle && <Text numberOfLines={narrow ? undefined : 1} style={{ color: colors.quiet, fontSize: 13 }}>{subtitle}</Text>}
        {state && narrow && label(stateText(state), true, 13)}
      </View>
      {state && !narrow && <View style={styles.status}><View style={{ width: 5, height: 5, borderRadius: 3,
        backgroundColor: ['active', 'running'].includes(state) ? colors.success : ['failed', 'dead'].includes(state) ? colors.warning : colors.quiet }} />{label(stateText(state), true, 12)}</View>}
      <Text accessibilityElementsHidden style={{ color: colors.quiet, fontSize: 19 }}>›</Text>
    </Pressable>
  );
  const metric = (title: string, value: string, detail = '', fraction?: number) => <View key={title} style={[styles.metric, { width: narrow ? '100%' : '50%' }]}>
    {label(title, true, 12)}
    <Text numberOfLines={1} style={{ color: colors.ink, fontSize: 16, fontWeight: '600', fontVariant: ['tabular-nums'] }}>{value}</Text>
    {!!detail && label(detail, true, 11)}
    {fraction != null && <View style={{ height: 3, borderRadius: 2, backgroundColor: colors.separator }}><View style={{ height: 3, borderRadius: 2, backgroundColor: fraction > .85 ? colors.warning : colors.accent, width: `${Math.max(0, Math.min(1, fraction)) * 100}%` }} /></View>}
  </View>;
  const b = dashboard.reading ?? snapshot.status;
  const hardware = snapshot.inventory;
  const managed = snapshot.management;
  const containers = managed?.containers ?? [];
  const groups = groupedServices(snapshot.services, containers, query, filter);
  const running = snapshot.services.filter(s => s.state === 'active').length + containers.filter(c => c.state === 'running').length;
  if (route === 'developer') return <DeveloperTools snapshot={snapshot} dark={dark} bottomInset={bottomInset}
    disableRemote={disableRemoteUpdates} refreshing={pulling} onRefresh={() => manualRefresh.current?.start(snapshot.demo)} />;
  return <ScrollView testID={`runtime-${route}`} style={{ flex: 1, backgroundColor: colors.background }}
    contentInsetAdjustmentBehavior="never" automaticallyAdjustContentInsets={false} automaticallyAdjustsScrollIndicatorInsets={false}
    keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag" automaticallyAdjustKeyboardInsets
    contentContainerStyle={[styles.page, { paddingBottom: bottomInset + 16 }]}
    refreshControl={<RefreshControl testID="manual-refresh" refreshing={pulling} onRefresh={() => manualRefresh.current?.start(snapshot.demo)} tintColor={colors.accent} />}>
    <View style={styles.content}>
      <View accessibilityLabel={snapshot.demo ? '演示数据' : snapshot.stale ? '连接中断，上次数据' : '已连接'} style={styles.banner}>
        <View style={{ flexDirection: 'row', gap: 6, alignItems: 'center' }}>
          <View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: snapshot.stale ? colors.warning : snapshot.demo ? colors.quiet : colors.success }} />
          {label(snapshot.demo ? '演示数据' : snapshot.stale ? `${snapshot.connectionText ?? '离线'} · 保留上次数据` : snapshot.connectionText ?? (snapshot.live ? '已连接' : '正在连接'), true, 11)}
        </View>
        {route === 'overview' && label(`${running}/${snapshot.services.length + containers.length} 服务在线`, true, 11)}
      </View>
      {!!snapshot.error && <Text style={{ color: colors.warning, fontSize: 12 }}>{snapshot.error}</Text>}
      {!!refreshFeedback && <Text style={{ color: colors.warning, fontSize: 12 }}>{refreshFeedback}</Text>}
      {route === 'overview' && snapshot.status?.temperatures.some(item => item.celsius >= 75) && <Text style={{ color: colors.warning, fontSize: 12 }}>温度偏高，请检查散热</Text>}
      {route === 'overview' && <>
        {b ? <>
          <View style={{ gap: 4, paddingVertical: 3 }}>
            <Text numberOfLines={1} style={{ color: colors.ink, fontSize: 20, fontWeight: '600' }}>{b.hostname}</Text>
            {label(`Cubie A7S${b.uptimeSeconds != null ? ` · 运行 ${Math.floor(b.uptimeSeconds / 3600)}h ${Math.floor(b.uptimeSeconds % 3600 / 60)}m` : ''}`, true, 12)}
          </View>
          <TrendCard data={dashboard} dark={dark} demo={snapshot.demo} stale={snapshot.stale} largeText={narrow} sampleInterval={snapshot.sampleInterval} />
          {card(<View style={styles.metrics}>
            {b.memoryUsedBytes != null && metric('内存', bytes(b.memoryUsedBytes), `共 ${bytes(b.memoryTotalBytes)}`, b.memoryTotalBytes ? b.memoryUsedBytes / b.memoryTotalBytes : undefined)}
            {b.diskUsedBytes != null && metric('存储', bytes(b.diskUsedBytes), `共 ${bytes(b.diskTotalBytes)}`, b.diskTotalBytes ? b.diskUsedBytes / b.diskTotalBytes : undefined)}
            {b.powerWatts != null && metric('功耗', `${b.powerWatts.toFixed(1)} W`)}
            {b.fanRPM != null && metric('风扇', `${Math.round(b.fanRPM)} RPM`)}
          </View>, undefined, true)}
        </> : card(label('等待设备数据', true))}
        {!nativeToolbar && card(<>
          {link('网络连接', snapshot.network?.campusText ?? '等待数据', 'open.network', 'network-details', undefined, 'Wi')}
          {separator}
          {link('设备控制', managed ? `${managed.leds.length} 个指示灯 · ${containers.length} 个容器` : '灯光与 Docker 管理', 'open.controls', 'overview-controls', undefined, '⌘')}
        </>, undefined, true)}
      </>}
      {route === 'services' && <>
        <View style={styles.heading}>
          {label(query ? `搜索“${query}”` : filter === '全部' ? '全部服务' : filter, true, 13)}
          {label(`${groups.reduce((sum, group) => sum + group.items.length, 0)} 项`, true, 12)}
        </View>
        {!nativeSearch && <TextInput accessibilityLabel="搜索服务" testID="service-search" defaultValue="" onChangeText={setQuery} placeholder="搜索名称、镜像或系统单元"
          placeholderTextColor={colors.quiet} clearButtonMode="while-editing" autoCorrect={false} autoCapitalize="none"
          returnKeyType="search" onSubmitEditing={Keyboard.dismiss}
          style={[styles.search, { color: colors.ink, backgroundColor: colors.surface }]} />}
        {!nativeToolbar && <View style={styles.filters}>
          {['全部', 'Docker', '系统'].map(item => <Pressable key={item} accessibilityRole="button" accessibilityState={{ selected: filter === item }} onPress={() => setFilter(item)}
            style={[styles.filter, { backgroundColor: filter === item ? colors.ink : colors.surface }]}><Text style={{ color: filter === item ? colors.surface : colors.quiet, fontSize: 12, fontWeight: '600' }}>{item}</Text></Pressable>)}
        </View>}
        {!snapshot.demo && snapshot.managementError && <Text style={{ color: colors.warning, fontSize: 12 }}>{snapshot.managementError}</Text>}
        {groups.map(group => <View key={group.title} style={{ gap: 7 }}>
          <View style={styles.heading}>{label(group.title, true, 12)}{label(String(group.items.length), true, 11)}</View>
          {card(group.items.map((s, i) => <React.Fragment key={s.id}>
            {i > 0 && separator}
            {link(s.name, `${s.subtitle}${snapshot.operation?.busy && snapshot.operation.target === s.id && snapshot.operation.kind === (s.kind === 'docker' ? 'container' : 'service') ? ' · 正在操作…' : ''}`, s.kind === 'docker' ? 'open.container' : 'open.service', `${s.kind === 'docker' ? 'container' : 'service'}-${s.id}`, s.id, group.badge, s.state)}
          </React.Fragment>), undefined, true)}
        </View>)}
        {!groups.length && card(label(query ? '没有匹配的服务' : '暂无服务数据', true))}
      </>}
      {route === 'devices' && <>
        {!nativeToolbar && card(link('灯光与设备控制', managed?.leds.length ? `${managed.leds.length} 个指示灯 · 支持恢复系统模式` : '查看管理权限与控制状态', 'open.controls', 'device-controls', undefined, '⌘'), undefined, true)}
        {hardware ? <>
          {card(<>
            <Text style={{ color: colors.ink, fontSize: 17, fontWeight: '600' }}>{b?.hostname ?? '开发板'}</Text>
            {label([hardware.board.model, hardware.board.cpuCores != null ? `${hardware.board.cpuCores} 核` : '', bytes(hardware.board.memoryBytes)].filter(Boolean).join(' · '), true, 12)}
            {label([hardware.board.architecture, hardware.board.kernel].filter(Boolean).join(' · '), true, 11)}
          </>)}
          {(snapshot.inventoryError || snapshot.inventoryStale) && <Text style={{ color: colors.warning, fontSize: 12 }}>{snapshot.inventoryError ?? '硬件信息已过期，等待重新连接。'}</Text>}
          {([['storage', '存储', 'storage'], ['usb', 'USB 设备', 'usb'], ['network', '网络接口', 'network'], ['bluetooth', '蓝牙控制器', 'bluetooth']] as const).map(([category, title, badge]) => {
            const devices = hardware.devices.filter(d => d.category === category);
            return devices.length ? <View key={category} style={{ gap: 7 }}><View style={styles.heading}>{label(title, true, 12)}{label(String(devices.length), true, 11)}</View>
              {card(devices.map((d, i) => <React.Fragment key={d.id}>
                {i > 0 && separator}
                {link(d.name, d.stateText, 'open.hardware', `hardware-${d.id}`, d.id, badge)}
              </React.Fragment>), undefined, true)}</View> : null;
          })}
          {!hardware.devices.length && card(label('暂未识别到其他设备，插入后下拉刷新。', true))}
          {label(`识别于 ${new Date(hardware.sampledAt).toLocaleTimeString('zh-CN')}`, true, 11)}
        </> : card(label(snapshot.inventoryError ?? '正在读取硬件信息', true))}
      </>}
    </View>
  </ScrollView>;
}

// Code-native vector icons share one stroke and never require fonts or new native modules.
function RowIcon({ kind, color }: { kind: string; color: string }) {
  const paths: Record<string, string> = {
    docker: 'M12 3 21 8v9l-9 5-9-5V8l9-5ZM3 8l9 5 9-5M12 13v9M7.5 5.5l9 5',
    system: 'M8 5V3m8 2V3M8 21v-2m8 2v-2M5 8H3m2 8H3m18-8h-2m2 8h-2M9 9h6v6H9Z',
    storage: 'M5 4h14v16H5ZM8 8h8M8 12h8',
    usb: 'M12 21V4m-3 3 3-4 3 4M12 16l-6-4V9m6 4 6-3V6',
    network: 'M12 8v5M5 17v-4h14v4',
    bluetooth: 'M7 7l10 10-5 4V3l5 4L7 17',
  };
  return <Svg width={22} height={22} viewBox="0 0 24 24" fill="none" stroke={color} strokeWidth={1.6}
    strokeLinecap="round" strokeLinejoin="round" accessible={false} accessibilityElementsHidden>
    {kind === 'system' && <Rect x={5} y={5} width={14} height={14} rx={3} />}
    {kind === 'network' && <><Rect x={9} y={2} width={6} height={6} rx={1} /><Rect x={2} y={17} width={6} height={5} rx={1} /><Rect x={16} y={17} width={6} height={5} rx={1} /></>}
    {kind === 'storage' && <Circle cx={16} cy={17} r={.6} />}
    <Path d={paths[kind] ?? 'M5 12h14M12 5v14'} />
  </Svg>;
}
const styles = StyleSheet.create({
  page: { paddingHorizontal: layout.inset, paddingTop: 4, alignItems: 'center' },
  content: { width: '100%', maxWidth: 720, gap: layout.gap },
  card: { borderRadius: layout.radius, gap: 6, overflow: 'hidden' },
  banner: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 20 },
  heading: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 8 },
  board: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  metrics: { flexDirection: 'row', flexWrap: 'wrap', padding: 4 },
  metric: { paddingHorizontal: 10, paddingVertical: 8, gap: 3 },
  link: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 64, paddingVertical: 10, paddingHorizontal: 14 },
  linkText: { flex: 1, gap: 3 },
  icon: { width: 32, height: 32, borderRadius: 8, alignItems: 'center', justifyContent: 'center' },
  status: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  search: { borderRadius: 12, paddingHorizontal: 13, paddingVertical: 10, fontSize: 14, minHeight: 42 },
  filters: { flexDirection: 'row', gap: 7 },
  filter: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: 10, minHeight: 34, justifyContent: 'center' },
});
