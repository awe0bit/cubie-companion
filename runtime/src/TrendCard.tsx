import React, { useState } from 'react';
import { Pressable, StyleSheet, Text, View } from 'react-native';
import Svg, { Circle, Line, Path } from 'react-native-svg';
import { bytes } from './presentation';
import { palette } from './theme';
import { Dashboard, Metric, plot } from './telemetry';

const metrics: { key: Metric; title: string }[] = [
  { key: 'cpu', title: 'CPU' }, { key: 'temperature', title: '温度' }, { key: 'memory', title: '内存' }, { key: 'network', title: '网络' },
];
export function TrendCard({ data, dark, demo, stale, largeText }: { data: Dashboard; dark: boolean; demo: boolean; stale: boolean; largeText: boolean }) {
  const [metric, setMetric] = useState<Metric>('cpu');
  const colors = palette(dark);
  const latest = data.reading;
  const temperature = latest?.temperatures.length ? Math.max(...latest.temperatures.map(item => item.celsius)) : null;
  const memory = latest?.memoryUsedBytes != null && latest?.memoryTotalBytes ? latest.memoryUsedBytes / latest.memoryTotalBytes * 100 : null;
  const value = metric === 'cpu' ? latest?.cpuPercent != null ? `${Math.round(latest.cpuPercent)}%` : '—'
    : metric === 'temperature' ? temperature != null ? `${Math.round(temperature)}°C` : '—'
    : metric === 'memory' ? memory != null ? `${Math.round(memory)}%` : '—'
    : latest?.rxBytesPerSecond != null ? `${bytes(latest.rxBytesPerSecond)}/s` : '—';
  const maximum = metric === 'network' ? Math.max(1024, ...data.points.flatMap(point => [point.rx ?? 0, point.tx ?? 0]))
    : metric === 'temperature' ? Math.max(100, ...data.points.map(point => point.temperature ?? 0)) : 100;
  const series = metric === 'network' ? ['rx', 'tx'] as const : [metric] as const;
  const width = 300, height = 92;
  return <View testID="performance-trend" style={[styles.card, { backgroundColor: colors.surface }]}>
    <View style={styles.heading}>
      <View style={{ gap: 3, flex: 1 }}><Text style={{ color: colors.ink, fontSize: 15, fontWeight: '600' }}>性能趋势</Text>
        <Text style={{ color: colors.quiet, fontSize: 11 }}>近 2 分钟{stale ? ' · 数据已暂停' : ''}</Text></View>
      <Text testID="trend-value" style={{ color: colors.ink, fontSize: 24, fontWeight: '600', fontVariant: ['tabular-nums'] }}>{value}</Text>
    </View>
    <View style={styles.selectors}>{metrics.map(item => <Pressable key={item.key} testID={`trend-${item.key}`}
      accessibilityRole="button" accessibilityState={{ selected: metric === item.key }} onPress={() => setMetric(item.key)}
      style={[styles.selector, { minWidth: largeText ? '45%' : undefined, backgroundColor: metric === item.key ? colors.background : 'transparent' }]}>
      <Text style={{ fontSize: 13, fontWeight: metric === item.key ? '600' : '400', color: metric === item.key ? colors.ink : colors.quiet }}>{item.title}</Text>
    </Pressable>)}</View>
    <View accessible testID="trend-chart" accessibilityLabel={`${metrics.find(item => item.key === metric)?.title}趋势，${data.points.length} 个采样${demo ? '，演示快照' : ''}`} style={{ gap: 5 }}>
      <View style={{ flexDirection: 'row', alignItems: 'center', gap: 8 }}>
        <View style={{ flex: 1 }}><Svg width="100%" height={height + 8} viewBox={`-3 -4 ${width + 6} ${height + 8}`} preserveAspectRatio="none">
          {[0, height / 2, height].map(y => <Line key={y} x1={0} x2={width} y1={y} y2={y} stroke={colors.separator} strokeWidth={.6} strokeDasharray="3 4" />)}
          {series.map((key, index) => {
            const line = plot(data.points, key, maximum, width, height);
            const color = index === 0 ? colors.accent : colors.success;
            return <React.Fragment key={key}><Path d={line.path} stroke={color} strokeWidth={1.8} fill="none" strokeLinejoin="round" strokeLinecap="round" />
              {line.last && <Circle cx={line.last.x} cy={line.last.y} r={2.2} fill={color} />}</React.Fragment>;
          })}
        </Svg></View>
        <View accessibilityElementsHidden style={{ height, justifyContent: 'space-between', alignItems: 'flex-end' }}>
          {[maximum, maximum / 2, 0].map((number, index) => <Text key={index} style={{ color: colors.quiet, fontSize: 9 }}>{metric === 'network' ? bytes(number) : `${Math.round(number)}${metric === 'temperature' ? '°' : '%'}`}</Text>)}
        </View>
      </View>
      <View style={styles.heading}><Text style={{ color: colors.quiet, fontSize: 10 }}>2 分钟前</Text>
        <Text style={{ color: colors.quiet, fontSize: 10 }}>{demo ? '演示快照 · 不生成历史' : data.points.length < 2 ? '积累趋势中' : metric === 'network' ? '蓝色下载 · 绿色上传' : '最近采样'}</Text></View>
    </View>
  </View>;
}
const styles = StyleSheet.create({
  card: { padding: 14, borderRadius: 16, gap: 8 }, heading: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', gap: 8 },
  selectors: { flexDirection: 'row', flexWrap: 'wrap', gap: 3 },
  selector: { flexGrow: 1, alignItems: 'center', justifyContent: 'center', minHeight: 44, paddingHorizontal: 8, borderRadius: 10 },
});
