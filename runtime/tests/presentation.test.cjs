const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(require.resolve('../src/presentation.ts'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: exportsObject });
const { groupedServices, bytes, stateText } = exportsObject;
test('targeted snapshots do not wake other roots and legacy broadcasts still work', () => {
  assert.equal(exportsObject.acceptsSnapshotClient('overview', 'overview'), true);
  assert.equal(exportsObject.acceptsSnapshotClient('overview', 'services'), false);
  assert.equal(exportsObject.acceptsSnapshotClient(undefined, 'services'), true);
});
test('control badges reflect permissions without granting them', () => {
  const groups = groupedServices([{ id: 'panel', name: 'Panel', unit: 'panel.service', state: 'active', controllable: false }], [], '', '系统');
  assert.ok(groups[0].items[0].subtitle.endsWith('只读'));
  assert.ok(!groups[0].items[0].subtitle.includes('panel.service'), 'Technical unit stays searchable, not primary list copy');
  assert.equal(groups[0].badge, 'system');
});
const services = [{ id: 'panel', name: '1Panel', unit: '1panel.service', state: 'active' }];
const containers = [{ id: 'fixture', name: 'demo-blog', image: 'example/blog:1', state: 'running' }];
test('Docker and host services are never mixed in one category', () => {
  const groups = groupedServices(services, containers, '', '全部');
  assert.equal(groups.length, 2);
  assert.equal(groups[0].items[0].kind, 'docker');
  assert.equal(groups[1].items[0].kind, 'system');
  assert.equal(groupedServices(services, containers, '', 'Docker').length, 1);
  assert.equal(groupedServices(services, containers, '', '系统')[0].items[0].id, 'panel');
});
test('search matches units and images, no results are honest', () => {
  assert.equal(groupedServices(services, containers, 'EXAMPLE/BLOG', '全部')[0].items[0].name, 'demo-blog');
  assert.equal(groupedServices(services, containers, '1panel.service', '全部')[0].items[0].id, 'panel');
  assert.equal(groupedServices(services, containers, 'missing', '全部').length, 0);
  assert.equal(bytes(null), '—');
  assert.equal(bytes(Infinity), '—');
  assert.equal(stateText('exited'), '已停止');
});
test('embedded pages do not create a second tab bar or auto-adjust native safe areas', () => {
  const source = fs.readFileSync(require.resolve('../src/App.tsx'), 'utf8');
  assert.ok(source.includes('contentInsetAdjustmentBehavior="never"'));
  assert.ok(source.includes('automaticallyAdjustContentInsets={false}'));
  assert.ok(!source.includes('tabBar'));
  assert.ok(source.includes('refreshing={pulling}'));
  assert.ok(!source.includes('refreshing={snapshot.refreshing}'));
  assert.ok(source.includes('defaultValue="" onChangeText={setQuery}'));
});
