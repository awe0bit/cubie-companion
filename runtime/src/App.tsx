import React, { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, RefreshControl, ScrollView, StyleSheet, Text, useColorScheme, useWindowDimensions, View } from 'react-native';
import { send, subscribe } from './native';
import { startUpdates } from './updates';
import { layout, palette } from './theme';
import type { Route, Snapshot } from './types';

type Props = { route: Route; client: string; snapshotJSON: string; appearance?: 'light' | 'dark'; disableRemoteUpdates?: boolean };
function bytes(value: number | null | undefined): string {
  if (value == null) return '—';
  const units = ['B', 'KB', 'MB', 'GB', 'TB'];
  let index = 0;
  while (value >= 1000 && index < units.length - 1) { value /= 1000; index++; }
  return `${value.toLocaleString('zh-CN', { maximumFractionDigits: 1 })} ${units[index]}`;
}

export default function App({ route, client, snapshotJSON, appearance, disableRemoteUpdates = false }: Props) {
  const [snapshot, setSnapshot] = useState<Snapshot>(() => JSON.parse(snapshotJSON));
  const system = useColorScheme();
  const colors = palette((appearance === 'light' || appearance === 'dark' ? appearance : system) === 'dark');
  const { width, fontScale } = useWindowDimensions();
  const oneColumn = fontScale > 1.4 || width < 350;
  const act = (action: string, id?: string) => send(client, action, id);
  useEffect(() => {
    const unsubscribe = subscribe(message => {
      if (message.type === 'corenest.snapshot' && message.snapshot) setSnapshot(message.snapshot);
    });
    act('ready');
    startUpdates(disableRemoteUpdates);
    return unsubscribe;
  }, [client]);

  const text = (value: string, secondary = false, large = false) => <Text style={{ color: secondary ? colors.quiet : colors.ink, fontSize: large ? 30 : 15, fontWeight: large ? '700' : '400' }}>{value}</Text>;
  const card = (children: React.ReactNode, key?: string) => <View key={key} style={[styles.card, { backgroundColor: colors.surface }]}>{children}</View>;
  const row = (label: string, value: string) => <View key={label} style={[styles.info, fontScale > 1.4 && { flexDirection: 'column', alignItems: 'flex-start' }]}>
    <Text style={{ color: colors.quiet, fontSize: 15 }}>{label}</Text>
    <Text selectable style={{ color: colors.ink, fontSize: 15, flexShrink: 1, textAlign: fontScale > 1.4 ? 'left' : 'right' }}>{value}</Text>
  </View>;
  const link = (title: string, subtitle: string, action: string, id: string, deviceID?: string, symbol = '↗') => (
    <Pressable key={id} accessibilityRole="button" accessibilityLabel={title} testID={id} onPress={() => act(action, deviceID)}
      style={({ pressed }) => [styles.link, { opacity: pressed ? .55 : 1 }]}>
      <View style={styles.linkText}><Text style={{ color: colors.ink, fontSize: 17, fontWeight: '600' }}>{title}</Text>{text(subtitle, true)}</View>
      <Text accessibilityElementsHidden style={{ color: colors.accent, fontSize: 22 }}>{symbol}</Text>
    </Pressable>
  );
  const metric = (title: string, value: string, detail = '') => <View key={title} style={{ width: oneColumn ? '100%' : '48%' }}>
    {card(<>{text(title, true)}<Text numberOfLines={1} adjustsFontSizeToFit minimumFontScale={.7} style={{ color: colors.ink, fontSize: 28, fontWeight: '600', fontVariant: ['tabular-nums'] }}>{value}</Text>{detail ? text(detail, true) : null}</>)}
  </View>;
  const b = snapshot.status;
  const hardware = snapshot.inventory;
  return <ScrollView testID={`runtime-${route}`} style={{ backgroundColor: colors.background }}
    contentContainerStyle={styles.page} refreshControl={<RefreshControl refreshing={snapshot.refreshing} onRefresh={() => act('refresh')} tintColor={colors.accent} />}>
    <View style={styles.content}>
      <View accessibilityLabel={snapshot.demo ? '演示数据' : snapshot.stale ? '连接中断，上次数据' : '已连接'} style={styles.banner}>
        <Text style={{ color: colors.quiet, fontSize: 13 }}>{snapshot.demo ? '✧  演示数据' : snapshot.stale ? '●  连接中断 · 上次数据' : '●  已连接'}</Text>
        {snapshot.refreshing && <ActivityIndicator color={colors.accent} size="small" />}
      </View>
      {snapshot.error ? <Text style={{ color: colors.warning }}>{snapshot.error}</Text> : null}
      {snapshot.notice ? text(snapshot.notice, true) : null}
      {route === 'overview' && <>
        {snapshot.demo && card(link('绑定开发板', '扫码后查看真实状态', 'open.binding', 'overview-connect'))}
        {b ? <>
          {card(<>
            <View style={styles.heading}><Text style={{ color: colors.ink, fontSize: 17, fontWeight: '600', flexShrink: 1 }}>{b.hostname}</Text><Text style={{ color: colors.accent }}>CORENEST</Text></View>
            {text('Cubie A7S', true)}
            {b.temperatures.length > 0 && <View style={styles.temperature}>
              <Text style={{ color: colors.ink, fontSize: 52, fontWeight: '500', fontVariant: ['tabular-nums'] }}>{Math.max(...b.temperatures.map(t => t.celsius)).toFixed(1)}°</Text>
              {text('最高温度 · °C', true)}
            </View>}
            {b.temperatures.some(t => t.celsius >= 75) && <Text style={{ color: colors.warning }}>温度偏高，请检查散热</Text>}
            {b.uptimeSeconds != null && text(`已运行 ${Math.floor(b.uptimeSeconds / 3600)} 小时 ${Math.floor(b.uptimeSeconds % 3600 / 60)} 分钟`, true)}
          </>)}
          <View style={styles.metrics}>
            {b.cpuPercent != null && metric('CPU', `${b.cpuPercent.toFixed(1)}%`, '实时利用率')}
            {b.memoryUsedBytes != null && metric('内存', bytes(b.memoryUsedBytes), b.memoryTotalBytes != null ? `共 ${bytes(b.memoryTotalBytes)}` : '')}
            {b.diskUsedBytes != null && metric('存储', bytes(b.diskUsedBytes), b.diskTotalBytes != null ? `共 ${bytes(b.diskTotalBytes)}` : '')}
            {b.rxBytesPerSecond != null && metric('下载', `${bytes(b.rxBytesPerSecond)}/s`, b.txBytesPerSecond != null ? `上传 ${bytes(b.txBytesPerSecond)}/s` : '')}
            {b.powerWatts != null && metric('功耗', `${b.powerWatts.toFixed(1)} W`)}
            {b.fanRPM != null && metric('风扇', `${Math.round(b.fanRPM)} RPM`)}
          </View>
        </> : card(text('等待设备数据', true))}
        {card(link('网络连接', snapshot.network?.campusText ?? '等待数据', 'open.network', 'network-details'))}
      </>}
      {route === 'services' && <>
        {text(`${snapshot.services.filter(s => s.state === 'active').length} / ${snapshot.services.length}`, false, true)}
        {text('运行中的系统服务', true)}
        {snapshot.services.length ? card(snapshot.services.slice().sort((a, b) => Number(a.state === 'active') - Number(b.state === 'active') || a.name.localeCompare(b.name)).map((s, i) => <React.Fragment key={s.id}>
          {i > 0 && <View style={{ height: StyleSheet.hairlineWidth, backgroundColor: colors.separator }} />}
          {link(s.name, s.stateText, 'open.service', `service-${s.id}`, s.id, '›')}
        </React.Fragment>)) : card(text('暂无服务数据', true))}
      </>}
      {route === 'devices' && <>
        {hardware ? <>
          {card(<>{text(b?.hostname ?? '开发板', false, true)}
            {hardware.board.model && row('型号标识', hardware.board.model)}
            {hardware.board.cpuCores != null && row('CPU 核心', `${hardware.board.cpuCores} 核`)}
            {hardware.board.memoryBytes != null && row('系统内存', bytes(hardware.board.memoryBytes))}
            {hardware.board.architecture && row('架构', hardware.board.architecture)}
            {hardware.board.kernel && row('内核', hardware.board.kernel)}
          </>)}
          {(snapshot.inventoryError || snapshot.inventoryStale) && <Text style={{ color: colors.warning }}>{snapshot.inventoryError ?? '硬件信息已过期，等待设备重新连接。'}</Text>}
          {([['storage', '存储'], ['usb', 'USB 总线'], ['network', '网卡'], ['bluetooth', '蓝牙']] as const).map(([category, title]) => {
            const devices = hardware.devices.filter(d => d.category === category);
            return devices.length ? <View key={category} style={{ gap: 10 }}>{text(title, true)}{card(devices.map((d, i) => <React.Fragment key={d.id}>
              {i > 0 && <View style={{ height: StyleSheet.hairlineWidth, backgroundColor: colors.separator }} />}
              {link(d.name, d.stateText, 'open.hardware', `hardware-${d.id}`, d.id, '›')}
            </React.Fragment>))}</View> : null;
          })}
          {!hardware.devices.length && card(text('暂未识别到其他设备，插入 USB 设备后下拉刷新。', true))}
          {text(`识别于 ${new Date(hardware.sampledAt).toLocaleTimeString('zh-CN')}`, true)}
        </> : card(text(snapshot.inventoryError ?? '正在读取设备，连接主板后自动识别。', true))}
      </>}
    </View>
  </ScrollView>;
}

const styles = StyleSheet.create({
  page: { padding: layout.inset, paddingBottom: 32, alignItems: 'center' },
  content: { width: '100%', maxWidth: 720, gap: layout.gap },
  card: { padding: layout.cardInset, borderRadius: layout.radius, gap: 12 },
  banner: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between' },
  info: { flexDirection: 'row', alignItems: 'flex-start', justifyContent: 'space-between', gap: 12 },
  heading: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'center', gap: 12 },
  temperature: { flexDirection: 'row', alignItems: 'baseline', justifyContent: 'space-between', flexWrap: 'wrap', gap: 8 },
  metrics: { flexDirection: 'row', flexWrap: 'wrap', justifyContent: 'space-between', gap: 12 },
  link: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 52, paddingVertical: 8 },
  linkText: { flex: 1, gap: 5 },
});
