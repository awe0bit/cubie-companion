const { test } = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const ts = require('typescript');
const exportsObject = {};
vm.runInNewContext(ts.transpileModule(fs.readFileSync(require.resolve('../src/refresh.ts'), 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2022, module: ts.ModuleKind.CommonJS },
}).outputText, { exports: exportsObject, setTimeout, clearTimeout });
function fixture() {
  const states = []; let requests = 0, deadline, cancelled = 0;
  const controller = new exportsObject.ManualRefresh(() => requests++, (on, text) => states.push({ on, text }),
    (callback, ms) => { assert.equal(ms, 20000); deadline = callback; return 1; }, () => cancelled++);
  return { controller, states, requests: () => requests, expire: () => deadline(), cancelled: () => cancelled };
}
test('background polls never spin, duplicate gestures send once, matching completion ends gesture', () => {
  const f = fixture(); f.controller.snapshot(true, true); assert.equal(f.states.length, 0);
  f.controller.start(false); f.controller.start(false); assert.equal(f.requests(), 1);
  f.controller.snapshot(false, true); assert.equal(f.states.at(-1).on, true);
  f.controller.finish(); assert.equal(f.states.at(-1).on, false); assert.equal(f.cancelled(), 1);
});
test('legacy snapshots must observe start then end; demo never pretends to fetch', () => {
  const f = fixture(); f.controller.start(true); assert.equal(f.requests(), 0);
  f.controller.start(false); f.controller.snapshot(false, false); assert.equal(f.states.at(-1).on, true);
  f.controller.snapshot(true, false); f.controller.snapshot(false, false); assert.equal(f.states.at(-1).on, false);
});
test('missing acknowledgement stops honestly and disposal cancels feedback timer', () => {
  const f = fixture(); f.controller.start(false); f.expire();
  assert.equal(f.states.at(-1).on, false); assert.ok(f.states.at(-1).text.includes('未收到'));
  f.controller.start(false); f.controller.dispose(); assert.equal(f.cancelled(), 1);
});
