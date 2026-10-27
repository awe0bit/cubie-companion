import React, { useEffect, useState } from 'react';
import { ActivityIndicator, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import * as Updates from 'expo-updates';
import { checkUpdate, observeUpdates, updateState } from './updates';
import { layout, palette } from './theme';
import type { Snapshot } from './types';

const messages = {
  disabled: '热更新不可用', idle: '等待检查', checking: '正在检查更新', downloading: '正在下载更新',
  pending: '更新已下载', current: '已是最新兼容页面', error: '更新检查未完成',
};
export function DeveloperTools({ snapshot, dark, bottomInset, disableRemote, refreshing, onRefresh }: {
  snapshot: Snapshot; dark: boolean; bottomInset: number; disableRemote: boolean; refreshing: boolean; onRefresh: () => void;
}) {
  const colors = palette(dark);
  const [ota, setOTA] = useState(updateState);
  const actual = Updates.useUpdates();
  useEffect(() => observeUpdates(setOTA), []);
  const busy = ['checking', 'downloading'].includes(ota.stage);
  const progress = ota.stage === 'downloading' && actual.downloadProgress != null ? Math.max(0, Math.min(1, actual.downloadProgress)) : undefined;
  const row = (name: string, value: string) => <View key={name} style={styles.row}>
    <Text style={{ color: colors.quiet, fontSize: 13 }}>{name}</Text>
    <Text selectable style={{ color: colors.ink, fontSize: 13, textAlign: 'right', flexShrink: 1 }}>{value}</Text>
  </View>;
  const section = (title: string, children: React.ReactNode) => <View style={{ gap: 7 }}>
    <Text style={{ color: colors.quiet, fontSize: 12 }}>{title}</Text>
    <View style={[styles.card, { backgroundColor: colors.surface }]}>{children}</View>
  </View>;
  const button = (title: string, id: string, onPress: () => void, disabled = false) => <Pressable testID={id}
    accessibilityRole="button" accessibilityState={{ disabled }} disabled={disabled} onPress={onPress} style={styles.button}>
    <Text style={{ color: disabled ? colors.quiet : colors.accent, fontSize: 14, fontWeight: '600' }}>{title}</Text>
  </Pressable>;
  return <ScrollView testID="runtime-developer" style={{ flex: 1, backgroundColor: colors.background }}
    contentInsetAdjustmentBehavior="never" automaticallyAdjustContentInsets={false}
    contentContainerStyle={[styles.page, { paddingBottom: bottomInset + 20 }]}>
    <Text testID="developer-title" style={{ color: colors.quiet, fontSize: 12 }}>只读诊断与页面更新，不提供任意命令或凭据查看。</Text>
    {section('页面热更新', <>
      <View style={styles.row}><Text testID="developer-ota-status" style={{ color: ota.stage === 'error' ? colors.warning : colors.ink, fontSize: 16, fontWeight: '600' }}>{messages[ota.stage]}</Text>
        {busy && <ActivityIndicator color={colors.accent} />}</View>
      {progress != null && <><View style={{ height: 4, borderRadius: 2, backgroundColor: colors.separator }}><View style={{ height: 4, borderRadius: 2, width: `${progress * 100}%`, backgroundColor: colors.accent }} /></View>
        <Text style={{ color: colors.quiet, fontSize: 11 }}>{Math.round(progress * 100)}% · SDK 下载进度</Text></>}
      {ota.stage === 'pending' && <Text style={{ color: colors.quiet, fontSize: 12 }}>下次冷启动应用，不会重启主板或中断当前操作。</Text>}
      {disableRemote ? <Text style={{ color: colors.quiet, fontSize: 12 }}>测试模式不访问更新服务</Text>
        : ota.stage !== 'disabled' && button('检查页面更新', 'developer-check-ota', () => { void checkUpdate(true); }, busy || ota.stage === 'pending')}
    </>)}
    {section('运行环境', <>
      {row('安装版本', snapshot.app ? `${snapshot.app.version} (${snapshot.app.build})` : '旧版宿主')}
      {row('兼容运行时', ota.runtime)}{row('更新通道', ota.channel)}
      {row('页面来源', ota.embeddedLaunch ? '安装包内置' : 'OTA 缓存')}
      {!!ota.launchUpdateID && row('页面 ID', ota.launchUpdateID)}
      {ota.emergencyLaunch && <Text style={{ color: colors.warning, fontSize: 12 }}>上次页面未能正常启动，已回退到可用版本。</Text>}
    </>)}
    {section('会话诊断', <>
      {row('数据连接', snapshot.demo ? '演示模式' : snapshot.stale ? '连接中断' : snapshot.live ? '实时推送' : '正在重连')}
      {row('系统服务', String(snapshot.services.length))}{row('Docker 容器', String(snapshot.management?.containers.length ?? 0))}
      {row('已识别硬件', String(snapshot.inventory?.devices.length ?? 0))}
      {snapshot.status?.sampledAt && row('最近采样', new Date(snapshot.status.sampledAt).toLocaleTimeString('zh-CN'))}
      {!snapshot.demo && button(refreshing ? '刷新中…' : '刷新设备状态', 'developer-refresh', onRefresh, refreshing)}
      {!!snapshot.error && <Text style={{ color: colors.warning, fontSize: 12 }}>{snapshot.error}</Text>}
    </>)}
    <Text style={{ color: colors.quiet, fontSize: 11 }}>页面和样式走 OTA；原生能力或权限变化才需要新安装包。此处不显示设备地址、账号或访问令牌。</Text>
  </ScrollView>;
}
const styles = StyleSheet.create({
  page: { paddingHorizontal: layout.inset, paddingTop: 8, gap: 14 }, card: { padding: 14, gap: 10, borderRadius: layout.radius },
  row: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 16 },
  button: { minHeight: 44, justifyContent: 'center' },
});
