const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');

test('numeric transitions are native-driver, bounded, accessible and respect Reduce Motion', () => {
  const source = fs.readFileSync(require.resolve('../src/RollingValue.tsx'), 'utf8');
  assert.ok(source.includes('outputRange: [0, -size]'));
  assert.ok(source.includes('outputRange: [size, 0]'));
  assert.ok(source.includes('useNativeDriver: true'));
  assert.ok(source.includes('duration: 240'));
  assert.ok(source.includes('old === value || reducedMotion'));
  assert.ok(source.includes("'reduceMotionChanged'"));
  assert.ok(source.includes('progress.stopAnimation()'));
  assert.ok(source.includes('accessibilityLabel={value}'));
  assert.ok(!source.includes('setInterval'));
});

test('compact cards adapt to large text and never claim demo values are live', () => {
  const source = fs.readFileSync(require.resolve('../src/App.tsx'), 'utf8');
  assert.ok(source.includes('fontScale > 1.4'));
  assert.ok(source.includes('TrendCard data={dashboard}'));
  assert.ok(source.includes('minHeight: 64'));
  assert.ok(source.includes('state && narrow &&'));
  assert.ok(source.includes('<RowIcon'));
  assert.ok(!source.includes("badge: 'SYS'"));
  assert.ok(source.includes("snapshot.live ? '已连接'"));
  assert.ok(source.includes("snapshot.demo ? '演示数据'"));
  assert.ok(!source.includes('setInterval'));
  assert.ok(!source.includes('RollingValue'));
  assert.ok(source.includes('!nativeToolbar &&'));
});
