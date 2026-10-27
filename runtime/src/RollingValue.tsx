import React, { useEffect, useRef, useState } from 'react';
import { AccessibilityInfo, Animated, Easing, StyleSheet, Text, View } from 'react-native';

/** One bounded transition per formatted value, never an accumulating animation queue. */
export function RollingValue({ value, color, size = 22 }: { value: string; color: string; size?: number }) {
  const previous = useRef(value);
  const [outgoing, setOutgoing] = useState<string | null>(null);
  const [reducedMotion, setReducedMotion] = useState(true);
  const progress = useRef(new Animated.Value(1)).current;
  useEffect(() => {
    let mounted = true;
    AccessibilityInfo.isReduceMotionEnabled().then(enabled => { if (mounted) setReducedMotion(enabled); });
    const listener = AccessibilityInfo.addEventListener('reduceMotionChanged', setReducedMotion);
    return () => { mounted = false; listener.remove(); progress.stopAnimation(); };
  }, [progress]);
  useEffect(() => {
    const old = previous.current;
    previous.current = value;
    progress.stopAnimation();
    if (old === value || reducedMotion) { setOutgoing(null); progress.setValue(1); return; }
    setOutgoing(old);
    progress.setValue(0);
    Animated.timing(progress, { toValue: 1, duration: 240, easing: Easing.out(Easing.cubic), useNativeDriver: true })
      .start(({ finished }) => { if (finished) setOutgoing(null); });
    return () => progress.stopAnimation();
  }, [value, reducedMotion, progress]);
  const textStyle = { color, fontSize: size, fontWeight: '600' as const, fontVariant: ['tabular-nums' as const] };
  return <View accessible accessibilityLabel={value} style={styles.clip}>
    {/* Invisible sizing text keeps Dynamic Type and layout stable without fixed heights. */}
    <Text accessible={false} accessibilityElementsHidden numberOfLines={1} adjustsFontSizeToFit minimumFontScale={.75}
      style={[textStyle, { opacity: 0 }]}>{value}</Text>
    {outgoing != null && <Animated.Text accessible={false} accessibilityElementsHidden numberOfLines={1}
      style={[styles.layer, textStyle, { opacity: progress.interpolate({ inputRange: [0, 1], outputRange: [1, 0] }),
        transform: [{ translateY: progress.interpolate({ inputRange: [0, 1], outputRange: [0, -size] }) }] }]}>{outgoing}</Animated.Text>}
    <Animated.Text accessible={false} accessibilityElementsHidden numberOfLines={1} adjustsFontSizeToFit minimumFontScale={.75}
      style={[styles.layer, textStyle, { opacity: progress, transform: [{ translateY: progress.interpolate({ inputRange: [0, 1], outputRange: [size, 0] }) }] }]}>{value}</Animated.Text>
  </View>;
}
const styles = StyleSheet.create({ clip: { overflow: 'hidden', flexShrink: 1 }, layer: { position: 'absolute', left: 0, right: 0, top: 0 } });
