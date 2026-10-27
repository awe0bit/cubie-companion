const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const moduleExports = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(require.resolve('../src/telemetry.ts'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: moduleExports });
const { TelemetryWindow, plot } = moduleExports;
function sample(second, cpu = second, session = 'fixture', overrides = {}) {
  return { demo: false, telemetrySession: session, status: { hostname: 'fixture', sampledAt: new Date(1_800_000_000_000 + second * 1000).toISOString(),
    cpuPercent: cpu, memoryUsedBytes: 50, memoryTotalBytes: 100, temperatures: [{ celsius: 52 }], rxBytesPerSecond: 10, txBytesPerSecond: 5, ...overrides } };
}
test('one-second curve samples do not make numbers change every second', () => {
  const model = new TelemetryWindow();
  for (let second = 0; second < 10; second++) {
    const result = model.accept(sample(second));
    assert.equal(result.points.length, second + 1);
    assert.equal(result.reading.cpuPercent, second < 5 ? 0 : 5);
  }
});
test('duplicate and out-of-order source timestamps never invent history or rewind values', () => {
  const model = new TelemetryWindow();
  model.accept(sample(10));
  model.accept(sample(10, 99));
  const result = model.accept(sample(9));
  assert.equal(result.points.length, 1);
  assert.equal(result.reading.cpuPercent, 10);
});
test('history is capped and reset between bindings even with the same hostname', () => {
  const model = new TelemetryWindow();
  let result;
  for (let second = 0; second < 500; second++) result = model.accept(sample(second, 10));
  assert.equal(result.points.length, 121);
  result = model.accept(sample(501, 20, 'new-binding'));
  assert.equal(result.points.length, 1);
  assert.equal(result.reading.cpuPercent, 20);
});
test('unknown or invalid values remain missing, not synthetic zeros', () => {
  const model = new TelemetryWindow();
  const { points } = model.accept(sample(0, NaN, 'fixture', { temperatures: [], memoryTotalBytes: 0, rxBytesPerSecond: null, txBytesPerSecond: Infinity }));
  for (const key of ['cpu', 'temperature', 'memory', 'rx', 'tx']) assert.equal(points[0][key], null);
  assert.equal(plot(points, 'cpu', 100, 300, 100).path, '');
  assert.equal(new TelemetryWindow().accept(sample(0, 1, 'fixture', { sampledAt: 'invalid' })).points.length, 0);
});
test('plots use source time, split outages/missing data and keep points inside the chart', () => {
  const points = [0, 1, 6, 7, 8, 9].map(t => ({ t: t * 1000, cpu: t === 7 ? null : t === 9 ? 1000 : 50 }));
  const result = plot(points, 'cpu', 100, 300, 100);
  assert.equal((result.path.match(/M/g) || []).length, 3);
  assert.equal((result.path.match(/L/g) || []).length, 2);
  assert.equal(result.last.x, 300);
  assert.equal(result.last.y, 0);
  assert.ok(result.path.startsWith('M277.50,50.00'));
});

test('intentional low-power cadence connects real points but still splits missed samples', () => {
  const points = [0, 15, 30, 75].map(t => ({ t: t * 1000, cpu: 50 }));
  const result = plot(points, 'cpu', 100, 300, 100, 15);
  assert.equal((result.path.match(/L/g) || []).length, 2);
  assert.equal((result.path.match(/M/g) || []).length, 2);
  assert.equal((plot(points, 'cpu', 100, 300, 100).path.match(/L/g) || []).length, 0);
});

test('switching to economy does not erase a real outage from earlier samples', () => {
  const points = [{ t: 0, cpu: 50, interval: 1 }, { t: 20000, cpu: 50, interval: 15 }, { t: 35000, cpu: 50, interval: 15 }];
  const result = plot(points, 'cpu', 100, 300, 100, 15);
  assert.equal((result.path.match(/M/g) || []).length, 2);
  assert.equal((result.path.match(/L/g) || []).length, 1);
});
