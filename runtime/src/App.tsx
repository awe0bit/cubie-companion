import React, { useEffect, useRef, useState } from 'react';
import { Keyboard, Pressable, RefreshControl, ScrollView, StyleSheet, Text, TextInput, useColorScheme, useWindowDimensions, View } from 'react-native';
import { send, subscribe } from './native';
import { startUpdates } from './updates';
import { ManualRefresh } from './refresh';
import { layout, palette } from './theme';
import { bytes, groupedServices, stateText } from './presentation';
import type { Route, Snapshot } from './types';

type Props = { route: Route; client: string; snapshotJSON: string; appearance?: 'light' | 'dark'; disableRemoteUpdates?: boolean; bottomInset?: number };
export default function App({ route, client, snapshotJSON, appearance, disableRemoteUpdates = false, bottomInset = 0 }: Props) {
  const [snapshot, setSnapshot] = useState<Snapshot>(() => JSON.parse(snapshotJSON));
  const [filter, setFilter] = useState('全部');
  const [query, setQuery] = useState('');
  const [pulling, setPulling] = useState(false);
  const [refreshFeedback, setRefreshFeedback] = useState('');
  const manualRefresh = useRef<ManualRefresh | null>(null);
  if (!manualRefresh.current) manualRefresh.current = new ManualRefresh(
    () => send(client, 'refresh'), (pulling, feedback) => { setPulling(pulling); setRefreshFeedback(feedback); });
  const system = useColorScheme();
  const colors = palette((appearance === 'light' || appearance === 'dark' ? appearance : system) === 'dark');
  const { width, fontScale } = useWindowDimensions();
  const narrow = fontScale > 1.4 || width < 350;
  const act = (action: string, id?: string) => send(client, action, id);
  useEffect(() => {
    const unsubscribe = subscribe(message => {
      if (message.type === 'corenest.snapshot' && message.snapshot) {
        setSnapshot(message.snapshot);
        manualRefresh.current?.snapshot(message.snapshot.refreshing, message.snapshot.refreshAcknowledgement === true);
      }
      if (message.type === 'corenest.refresh' && message.client === client) {
        manualRefresh.current?.finish();
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
      {badge && <View style={[styles.icon, { backgroundColor: colors.background }]}><Text style={{ color: colors.accent, fontSize: 12, fontWeight: '700' }}>{badge}</Text></View>}
      <View style={styles.linkText}>
        <Text numberOfLines={narrow ? undefined : 1} style={{ color: colors.ink, fontSize: 15, fontWeight: '600' }}>{title}</Text>
        {!!subtitle && <Text numberOfLines={narrow ? undefined : 1} style={{ color: colors.quiet, fontSize: 12 }}>{subtitle}</Text>}
      </View>
      {state && <View style={styles.status}><View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: ['active', 'running'].includes(state) ? colors.success : colors.warning }} />{label(stateText(state), true, 11)}</View>}
      <Text accessibilityElementsHidden style={{ color: colors.quiet, fontSize: 19 }}>›</Text>
    </Pressable>
  );
  const metric = (title: string, value: string, detail = '', fraction?: number) => <View key={title} style={[styles.metric, { width: narrow ? '100%' : '50%' }]}>
    {label(title, true, 12)}
    <Text numberOfLines={1} adjustsFontSizeToFit minimumFontScale={.7} style={{ color: colors.ink, fontSize: 23, fontWeight: '600', fontVariant: ['tabular-nums'] }}>{value}</Text>
    {!!detail && label(detail, true, 11)}
    {fraction != null && <View style={{ height: 3, borderRadius: 2, backgroundColor: colors.separator }}><View style={{ height: 3, borderRadius: 2, backgroundColor: fraction > .85 ? colors.warning : colors.accent, width: `${Math.max(0, Math.min(1, fraction)) * 100}%` }} /></View>}
  </View>;
  const b = snapshot.status;
  const hardware = snapshot.inventory;
  const managed = snapshot.management;
  const containers = managed?.containers ?? [];
  const groups = groupedServices(snapshot.services, containers, query, filter);
  const running = snapshot.services.filter(s => s.state === 'active').length + containers.filter(c => c.state === 'running').length;
  const highest = b?.temperatures.length ? Math.max(...b.temperatures.map(t => t.celsius)) : undefined;
  return <ScrollView testID={`runtime-${route}`} style={{ flex: 1, backgroundColor: colors.background }}
    contentInsetAdjustmentBehavior="never" automaticallyAdjustContentInsets={false} automaticallyAdjustsScrollIndicatorInsets={false}
    keyboardShouldPersistTaps="handled" keyboardDismissMode="on-drag" automaticallyAdjustKeyboardInsets
    contentContainerStyle={[styles.page, { paddingBottom: bottomInset + 16 }]}
    refreshControl={<RefreshControl testID="manual-refresh" refreshing={pulling} onRefresh={() => manualRefresh.current?.start(snapshot.demo)} tintColor={colors.accent} />}>
    <View style={styles.content}>
      <View accessibilityLabel={snapshot.demo ? '演示数据' : snapshot.stale ? '连接中断，上次数据' : '已连接'} style={styles.banner}>
        <View style={{ flexDirection: 'row', gap: 6, alignItems: 'center' }}>
          <View style={{ width: 5, height: 5, borderRadius: 3, backgroundColor: snapshot.stale ? colors.warning : snapshot.demo ? colors.quiet : colors.success }} />
          {label(snapshot.demo ? '演示数据' : snapshot.stale ? '连接中断 · 上次数据' : '实时连接', true, 11)}
        </View>
        {label('下拉刷新', true, 11)}
      </View>
      {!!snapshot.error && <Text style={{ color: colors.warning, fontSize: 12 }}>{snapshot.error}</Text>}
      {!!snapshot.notice && label(snapshot.notice, true, 12)}
      {!!refreshFeedback && <Text style={{ color: colors.warning, fontSize: 12 }}>{refreshFeedback}</Text>}
      {route === 'overview' && <>
        {snapshot.demo && card(link('绑定开发板', '扫码查看真实状态', 'open.binding', 'overview-connect'), undefined, true)}
        {b ? <>
          {card(<View style={[styles.board, narrow && { flexDirection: 'column', alignItems: 'flex-start' }]}>
            <View style={{ flex: 1, gap: 4 }}>
              <Text numberOfLines={1} style={{ color: colors.ink, fontSize: 18, fontWeight: '600' }}>{b.hostname}</Text>
              {label('Cubie A7S', true, 12)}
              {b.uptimeSeconds != null && label(`已运行 ${Math.floor(b.uptimeSeconds / 3600)}h ${Math.floor(b.uptimeSeconds % 3600 / 60)}m`, true, 11)}
            </View>
            {highest != null && <View style={{ alignItems: 'flex-end', gap: 2 }}>
              <Text style={{ color: highest >= 75 ? colors.warning : colors.ink, fontSize: 32, fontWeight: '500', fontVariant: ['tabular-nums'] }}>{highest.toFixed(1)}°</Text>
              {label(highest >= 75 ? '温度偏高' : '最高温度', true, 11)}
            </View>}
          </View>)}
          {card(<View style={styles.metrics}>
            {b.cpuPercent != null && metric('CPU', `${b.cpuPercent.toFixed(1)}%`, '实时负载', b.cpuPercent / 100)}
            {b.memoryUsedBytes != null && metric('内存', bytes(b.memoryUsedBytes), `共 ${bytes(b.memoryTotalBytes)}`, b.memoryTotalBytes ? b.memoryUsedBytes / b.memoryTotalBytes : undefined)}
            {b.diskUsedBytes != null && metric('存储', bytes(b.diskUsedBytes), `共 ${bytes(b.diskTotalBytes)}`, b.diskTotalBytes ? b.diskUsedBytes / b.diskTotalBytes : undefined)}
            {b.rxBytesPerSecond != null && metric('网络 ↓ / ↑', `${bytes(b.rxBytesPerSecond)}/s`, `↑ ${bytes(b.txBytesPerSecond)}/s`)}
            {b.powerWatts != null && metric('功耗', `${b.powerWatts.toFixed(1)} W`)}
            {b.fanRPM != null && metric('风扇', `${Math.round(b.fanRPM)} RPM`)}
          </View>, undefined, true)}
        </> : card(label('等待设备数据', true))}
        {card(<>
          {link('网络连接', snapshot.network?.campusText ?? '等待数据', 'open.network', 'network-details', undefined, 'Wi')}
          {separator}
          {link('设备控制', managed ? `${managed.leds.length} 个指示灯 · ${containers.length} 个容器` : '灯光与 Docker 管理', 'open.controls', 'overview-controls', undefined, '⌘')}
        </>, undefined, true)}
      </>}
      {route === 'services' && <>
        <View style={styles.heading}>
          <Text style={{ color: colors.ink, fontSize: 23, fontWeight: '600' }}>{running}<Text style={{ color: colors.quiet, fontSize: 13 }}> / {snapshot.services.length + containers.length} 运行中</Text></Text>
          {label(`${containers.length} 个容器`, true, 12)}
        </View>
        <TextInput accessibilityLabel="搜索服务" testID="service-search" defaultValue="" onChangeText={setQuery} placeholder="搜索名称、镜像或系统单元"
          placeholderTextColor={colors.quiet} clearButtonMode="while-editing" autoCorrect={false} autoCapitalize="none"
          returnKeyType="search" onSubmitEditing={Keyboard.dismiss}
          style={[styles.search, { color: colors.ink, backgroundColor: colors.surface }]} />
        <View style={styles.filters}>
          {['全部', 'Docker', '系统'].map(item => <Pressable key={item} accessibilityRole="button" accessibilityState={{ selected: filter === item }} onPress={() => setFilter(item)}
            style={[styles.filter, { backgroundColor: filter === item ? colors.ink : colors.surface }]}><Text style={{ color: filter === item ? colors.surface : colors.quiet, fontSize: 12, fontWeight: '600' }}>{item}</Text></Pressable>)}
        </View>
        {!snapshot.demo && snapshot.managementError && <Text style={{ color: colors.warning, fontSize: 12 }}>{snapshot.managementError}</Text>}
        {groups.map(group => <View key={group.title} style={{ gap: 7 }}>
          <View style={styles.heading}>{label(group.title, true, 12)}{label(String(group.items.length), true, 11)}</View>
          {card(group.items.map((s, i) => <React.Fragment key={s.id}>
            {i > 0 && separator}
            {link(s.name, s.subtitle, s.kind === 'docker' ? 'open.container' : 'open.service', `${s.kind === 'docker' ? 'container' : 'service'}-${s.id}`, s.id, group.badge, s.state)}
          </React.Fragment>), undefined, true)}
        </View>)}
        {!groups.length && card(label(query ? '没有匹配的服务' : '暂无服务数据', true))}
      </>}
      {route === 'devices' && <>
        {card(link('灯光与设备控制', managed?.leds.length ? `${managed.leds.length} 个指示灯 · 支持恢复系统模式` : '查看管理权限与控制状态', 'open.controls', 'device-controls', undefined, '⌘'), undefined, true)}
        {hardware ? <>
          {card(<>
            <Text style={{ color: colors.ink, fontSize: 17, fontWeight: '600' }}>{b?.hostname ?? '开发板'}</Text>
            {label([hardware.board.model, hardware.board.cpuCores != null ? `${hardware.board.cpuCores} 核` : '', bytes(hardware.board.memoryBytes)].filter(Boolean).join(' · '), true, 12)}
            {label([hardware.board.architecture, hardware.board.kernel].filter(Boolean).join(' · '), true, 11)}
          </>)}
          {(snapshot.inventoryError || snapshot.inventoryStale) && <Text style={{ color: colors.warning, fontSize: 12 }}>{snapshot.inventoryError ?? '硬件信息已过期，等待重新连接。'}</Text>}
          {([['storage', '存储', 'SD'], ['usb', 'USB 设备', 'USB'], ['network', '网络接口', 'NET'], ['bluetooth', '蓝牙控制器', 'BT']] as const).map(([category, title, badge]) => {
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
const styles = StyleSheet.create({
  page: { paddingHorizontal: layout.inset, paddingTop: 4, alignItems: 'center' },
  content: { width: '100%', maxWidth: 720, gap: layout.gap },
  card: { borderRadius: layout.radius, gap: 6, overflow: 'hidden' },
  banner: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', minHeight: 20 },
  heading: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 8 },
  board: { flexDirection: 'row', alignItems: 'center', gap: 12 },
  metrics: { flexDirection: 'row', flexWrap: 'wrap', padding: 4 },
  metric: { padding: 10, gap: 5 },
  link: { flexDirection: 'row', alignItems: 'center', gap: 10, minHeight: 60, paddingVertical: 10, paddingHorizontal: 14 },
  linkText: { flex: 1, gap: 4 },
  icon: { width: 32, height: 32, borderRadius: 9, alignItems: 'center', justifyContent: 'center' },
  status: { flexDirection: 'row', alignItems: 'center', gap: 4, maxWidth: 68 },
  search: { borderRadius: 12, paddingHorizontal: 13, paddingVertical: 10, fontSize: 14, minHeight: 42 },
  filters: { flexDirection: 'row', gap: 7 },
  filter: { paddingHorizontal: 14, paddingVertical: 8, borderRadius: 10, minHeight: 34, justifyContent: 'center' },
});
