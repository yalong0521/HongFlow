'use strict';

const assert = require('node:assert/strict');
const { environment, flush } = require('./test-card-host.cjs');

function holdNextRoute(e, pathname) {
  let resolve;
  let held = false;
  const promise = new Promise(accept => { resolve = accept; });
  const create = e.network.http.createHttp;
  e.network.http.createHttp = () => {
    const client = create();
    return {
      request(url, options) {
        if (!held && new URL(url).pathname === pathname) {
          held = true;
          return promise;
        }
        return client.request(url, options);
      },
      destroy: () => client.destroy()
    };
  };
  return payload => resolve({ responseCode: 200, result: JSON.stringify(payload) });
}

const tests = [
  ['a cancelled card start cannot replace the later disconnect feedback', async e => {
    e.setStartMode('pending');
    const gate = e.holdStop();
    await e.initialize();
    e.offer(e.wantFor(e.card, 'start'));
    await e.clock.until(() => e.events.starts.length === 1);
    e.offer(e.wantFor(e.cards.addForm('1007'), 'stop'));
    await e.clock.advance(400);
    assert.equal(e.model.phase, 'stopping');
    assert.equal(e.model.operationKind, 'disconnect');
    assert.equal(e.model.message, '正在断开');
    gate.resolve();
    await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
    assert.equal(e.model.message, '');
  }],
  ['an old periodic HTTP response cannot replace disconnect feedback', async e => {
    e.seedRun('periodic-response-owner');
    await e.initialize();
    const resolve = holdNextRoute(e, '/connections');
    await e.clock.advance(1000);
    const gate = e.holdStop();
    const stopping = e.model.toggleConnection();
    resolve({ uploadTotal: 0, downloadTotal: 0 });
    await flush();
    assert.equal(e.model.phase, 'stopping');
    assert.equal(e.model.operationKind, 'disconnect');
    assert.equal(e.model.message, '正在断开');
    gate.resolve();
    await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
    await stopping;
  }],
  ['an initial HTTP observation cannot turn a newer disconnect into an error', async e => {
    e.seedRun('initial-response-owner');
    const resolve = holdNextRoute(e, '/proxies');
    const initialization = e.initialize();
    await flush();
    const gate = e.holdStop();
    const stopping = e.model.toggleConnection();
    resolve({ proxies: {} });
    await initialization;
    assert.equal(e.model.phase, 'stopping');
    assert.equal(e.model.operationKind, 'disconnect');
    assert.equal(e.model.message, '正在断开');
    gate.resolve();
    await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
    await stopping;
  }]
];

(async () => {
  const unhandled = [];
  process.on('unhandledRejection', error => unhandled.push(error));
  let failures = 0;
  for (const [name, run] of tests) {
    const e = environment();
    try {
      await run(e);
      console.log('PASS ' + name);
    } catch (error) {
      failures++;
      console.error('FAIL ' + name + '\n' + (error.stack || error));
    } finally {
      e.cleanup();
      await flush();
    }
  }
  await new Promise(resolve => setImmediate(resolve));
  if (unhandled.length) {
    failures++;
    console.error('FAIL unhandled rejection: ' + unhandled.map(String).join('; '));
  }
  console.log(`${tests.length - failures}/${tests.length} final model regressions passed.`);
  console.log('Boundary: production model/storage/card entry; simulated Harmony Kits/native/VPN/HTTP, no device VPN test.');
  process.exitCode = failures ? 1 : 0;
})();
