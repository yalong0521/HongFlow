'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const { environment, flush } = require('./test-card-host.cjs');

const tests = [];
const test = (name, run) => tests.push({ name, run });
const deferred = () => {
  let resolve;
  const promise = new Promise(accept => { resolve = accept; });
  return { promise, resolve };
};

function interceptHttp(e, handler) {
  const create = e.network.http.createHttp;
  e.network.http.createHttp = () => {
    const client = create();
    return {
      request: (url, options) => handler(url, options, () => client.request(url, options)),
      destroy: () => client.destroy()
    };
  };
}

test('a rejected subscription update preserves the previously usable YAML and metadata', async e => {
  const profile = e.store.readProfiles()[0];
  profile.url = 'https://fixture.invalid/profile.yaml';
  e.store.writeProfiles([profile]);
  await e.initialize();
  const filename = e.store.profilePath(profile.id);
  const previousYaml = e.store.readText(filename);
  const previousProfiles = e.store.readText(e.store.root + '/profiles.json');
  const invalidYaml = 'proxies: [{name: node, type: direct}]\nrules: ["MATCH,missing"]\n';
  interceptHttp(e, (url, _options, fallback) => url === profile.url ? Promise.resolve({
    responseCode: 200, result: new TextEncoder().encode(invalidYaml).buffer
  }) : fallback());
  // Native Go regressions check the parser; this verifies its failure cannot replace saved data.
  e.native.validateProfile = async yaml => {
    assert.equal(yaml, invalidYaml);
    return JSON.stringify({ valid: false, error: 'proxy [missing] not found' });
  };
  await assert.rejects(e.model.refreshProfile(profile.id), /proxy \[missing\] not found/);
  assert.equal(e.store.readText(filename), previousYaml);
  assert.equal(e.store.readText(e.store.root + '/profiles.json'), previousProfiles);
  assert.notEqual(e.model.message, '配置已更新');
  assert.equal(e.model.busy, false);
});

test('a restored authorization request stays starting and blocks profile edits', async e => {
  e.seedRun('pending-authority', false, false, 'idle');
  await e.initialize();
  assert.equal(e.model.phase, 'starting');
  assert.equal(e.model.canModifyProfiles, false);
  assert.equal(e.model.needsCleanup, false);
  await assert.rejects(e.model.removeProfile(e.model.selectedProfileId), /请先断开/);
  assert.equal(e.store.readProfiles().length, 1);
  const stopping = e.model.toggleConnection();
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  await stopping;
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.store.readRequest().id, 'pending-authority');
  assert.equal(e.store.readRequest().cancelled, true);
});

test('a previous error snapshot cannot hide a fresh pending authorization', async e => {
  e.seedRun('pending-new', false, false, 'idle');
  e.store.writeSnapshot({ ...e.store.readSnapshot(), requestId: 'failed-old', phase: 'error' });
  await e.initialize();
  assert.equal(e.model.phase, 'starting');
  assert.equal(e.events.starts.length, 0);
});

test('a timed-out start keeps cleanup durable and reuses a pending SDK stop', async e => {
  e.setStartMode('pending');
  const held = e.holdStop();
  await e.initialize();
  const starting = e.model.toggleConnection().then(() => undefined, error => error);
  await e.clock.advance(33000);
  assert.match((await starting).message, /超时/);
  assert.equal(e.store.readRequest().cancelled, true);
  assert.equal(e.store.readRequest().stopping, true);
  assert.equal(e.events.stops.length, 1);
  await assert.rejects(e.model.selectProfile(e.model.selectedProfileId), /请先断开/);
  const cleanup = e.model.toggleConnection().then(() => undefined, error => error);
  await e.clock.advance(11000);
  assert.ok(await cleanup);
  assert.equal(e.events.stops.length, 1, 'Retry must wait on the earlier unscoped stop');
  assert.equal(e.store.readRequest().stopping, true);
  held.resolve();
  await e.clock.advance(1000);
  e.setStartMode('connected');
  const retry = e.model.toggleConnection();
  await e.clock.until(() => e.model.phase === 'connected' && !e.model.busy);
  await retry;
  assert.equal(e.events.starts.length, 2);
});

test('an immediate SDK start failure cannot permit another start while cleanup is pending', async e => {
  const held = e.holdStop();
  e.network.vpnExtension.startVpnExtensionAbility = want => {
    e.events.starts.push(want);
    return Promise.reject(new Error('Synthetic start failure'));
  };
  await e.initialize();
  const starting = e.model.toggleConnection().then(() => undefined, error => error);
  await e.clock.advance(2500);
  assert.match((await starting).message, /Synthetic start failure/);
  assert.equal(e.store.readRequest().stopping, true);
  const cleanup = e.model.toggleConnection().then(() => undefined, error => error);
  await e.clock.advance(11000);
  assert.ok(await cleanup);
  assert.equal(e.events.starts.length, 1);
  assert.equal(e.events.stops.length, 1);
  held.resolve();
  await flush();
});

test('initial core observation failure retains the model and recovers on its next poll', async e => {
  e.seedRun('initial-api-failure');
  let fail = true;
  interceptHttp(e, (url, _options, fallback) => {
    if (fail && new URL(url).pathname === '/proxies') return Promise.reject(new Error('Temporary core failure'));
    return fallback();
  });
  await e.initialize();
  assert.equal(e.model.phase, 'error');
  assert.equal(e.model.cleanupRequired, true);
  assert.match(e.model.message, /Temporary core failure/);
  fail = false;
  await e.clock.advance(1000);
  assert.equal(e.model.phase, 'connected');
  assert.equal(e.model.message, '');
});

test('disconnect during initial observation does not detach the live model', async e => {
  e.seedRun('initial-disconnect');
  const observation = deferred();
  let first = true;
  interceptHttp(e, (url, _options, fallback) => {
    if (first && new URL(url).pathname === '/proxies') {
      first = false;
      return observation.promise;
    }
    return fallback();
  });
  const initialization = e.initialize();
  await flush();
  const request = e.store.readRequest();
  request.cancelled = true;
  e.store.writeRequest(request);
  e.store.writeSnapshot({ ...e.store.readSnapshot(), phase: 'idle' });
  observation.resolve({ responseCode: 200, result: JSON.stringify({ proxies: {} }) });
  await initialization;
  await e.clock.advance(1000);
  assert.equal(e.model.phase, 'idle');
  assert.equal(e.model.canModifyProfiles, true);
  await e.model.selectProfile(e.model.selectedProfileId);
});

test('local import reads every short chunk before validation and storage', async e => {
  await e.initialize();
  const yaml = 'proxies: [{name: fixture, type: direct}]\n# 完整配置\nrules: [MATCH,DIRECT]\n';
  const input = e.store.root + '/short-read.yaml';
  e.store.writeText(input, yaml);
  const read = e.fileIo.readSync;
  let reads = 0;
  e.fileIo.readSync = (fd, buffer, options) => {
    reads++;
    return read(fd, buffer, { ...options, length: Math.min(options?.length ?? buffer.byteLength, 11) });
  };
  const picker = e.holdPicker();
  const importing = e.model.importLocalFile();
  picker.resolve([input]);
  await importing;
  assert.ok(reads > 1);
  assert.equal(e.store.readProfiles().length, 2);
  const profile = e.store.readProfiles().at(-1);
  assert.equal(e.store.readText(e.store.profilePath(profile.id)), yaml);
});

test('local import rejects premature EOF and invalid UTF-8 without adding profiles', async e => {
  await e.initialize();
  const input = e.store.root + '/incomplete.yaml';
  e.store.writeText(input, 'proxies: []\nrules: [MATCH,DIRECT]\n');
  const read = e.fileIo.readSync;
  let reads = 0;
  e.fileIo.readSync = (fd, buffer) => ++reads === 1 ? read(fd, buffer, { length: 12 }) : 0;
  let picker = e.holdPicker();
  let importing = e.model.importLocalFile();
  picker.resolve([input]);
  await assert.rejects(importing, /读取不完整/);
  assert.equal(e.store.readProfiles().length, 1);
  e.fileIo.readSync = read;
  fs.writeFileSync(input, Buffer.from([0xff, 0xfe, 0xfd]));
  picker = e.holdPicker();
  importing = e.model.importLocalFile();
  picker.resolve([input]);
  await assert.rejects(importing);
  assert.equal(e.store.readProfiles().length, 1);
});

test('an older periodic group response cannot undo a completed node selection', async e => {
  const proxies = {
    Group: { type: 'Selector', now: 'A', all: ['A', 'B'] },
    A: { type: 'Direct' }, B: { type: 'Direct' }
  };
  e.setProxies(proxies);
  e.seedRun('group-response-order');
  await e.initialize();
  const stale = deferred();
  let holdNext = true;
  interceptHttp(e, (url, options, fallback) => {
    const route = new URL(url).pathname;
    if (route === '/proxies' && holdNext) {
      holdNext = false;
      return stale.promise;
    }
    if (route === '/proxies/Group' && options.method === 'PUT') {
      proxies.Group.now = JSON.parse(options.extraData).name;
      return Promise.resolve({ responseCode: 204, result: '' });
    }
    return fallback();
  });
  await e.clock.advance(5000);
  await e.model.selectNode('Group', 'B');
  assert.equal(e.model.groups[0].now, 'B');
  stale.resolve({
    responseCode: 200, result: JSON.stringify({
      proxies: { ...proxies, Group: { ...proxies.Group, now: 'A' } }
    })
  });
  await flush();
  assert.equal(e.model.groups[0].now, 'B');
  assert.equal(e.store.readSettings().selections[e.store.readRequest().profileId].Group, 'B');
  await assert.rejects(e.model.selectNode('Group', 'missing'), /节点已经变化/);
});

test('mode changes validate values and a late result after disconnect cannot update settings', async e => {
  await e.initialize();
  await assert.rejects(e.model.setMode('invalid'), /代理模式无效/);
  await e.model.setMode('global');
  assert.equal(e.store.readSettings().mode, 'global');
  e.seedRun('mode-late-result');
  await e.clock.advance(1000);
  const mode = deferred();
  e.native.setMode = () => mode.promise;
  const switching = e.model.setMode('direct').then(() => undefined, error => error);
  const stopping = e.model.toggleConnection();
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  await stopping;
  mode.resolve();
  assert.match((await switching).message, /VPN 连接已变化/);
  assert.equal(e.store.readSettings().mode, 'global');
});

test('subscription import, refresh and removal preserve identity and clear saved selections', async e => {
  await e.initialize();
  const yaml = 'proxies: [{name: fixture, type: direct}]\nrules: [MATCH,DIRECT]\n';
  interceptHttp(e, (url, options, fallback) => {
    if (url === 'https://fixture.invalid/profile') {
      assert.equal(options.maxLimit, 5 * 1024 * 1024);
      return Promise.resolve({ responseCode: 200, result: new TextEncoder().encode(yaml).buffer });
    }
    return fallback();
  });
  await e.model.importSubscription('  Reviewed profile  ', 'https://fixture.invalid/profile');
  const profile = e.store.readProfiles().at(-1);
  assert.equal(profile.name, 'Reviewed profile');
  await e.model.selectProfile(profile.id);
  await e.model.refreshProfile(profile.id);
  assert.equal(e.store.readProfiles().at(-1).id, profile.id);
  assert.equal(e.store.readText(e.store.profilePath(profile.id)), yaml);
  await e.model.removeProfile(profile.id);
  assert.equal(e.store.readProfiles().length, 1);
  assert.notEqual(e.store.readSettings().selectedProfileId, profile.id);
  assert.equal(e.fileIo.accessSync(e.store.profilePath(profile.id)), false);
});

test('failed downloads and partial file writes leave the previous saved data intact', async e => {
  await e.initialize();
  let destroyed = 0;
  e.network.http.createHttp = () => ({
    async request() { return { responseCode: 401, result: new ArrayBuffer(0) }; },
    destroy() { destroyed++; }
  });
  await assert.rejects(e.model.importSubscription('Rejected', 'https://fixture.invalid/rejected'), /401/);
  assert.equal(destroyed, 1);
  assert.equal(e.store.readProfiles().length, 1);
  const previous = e.store.readSettings();
  const write = e.fileIo.writeSync;
  e.fileIo.writeSync = (fd, content) => {
    const bytes = Buffer.from(content);
    fs.writeSync(fd, bytes.subarray(0, bytes.byteLength - 1));
    return bytes.byteLength - 1;
  };
  assert.throws(() => e.store.writeSettings({ ...previous, mode: 'direct' }), /不完整写入/);
  e.fileIo.writeSync = write;
  assert.equal(e.store.readSettings().mode, previous.mode);
  assert.equal(fs.readdirSync(e.store.root).some(name => name.endsWith('.tmp')), false);
});

(async () => {
  const unhandled = [];
  process.on('unhandledRejection', error => unhandled.push(error));
  let failures = 0;
  for (const item of tests) {
    const e = environment();
    try {
      await item.run(e);
      console.log('PASS ' + item.name);
    } catch (error) {
      failures++;
      console.error('FAIL ' + item.name + '\n' + (error.stack || error));
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
  console.log(`${tests.length - failures}/${tests.length} model review regressions passed.`);
  console.log('Boundary: production model/storage/API modules; simulated Harmony Kits/native/VPN/HTTP, no device VPN test.');
  process.exitCode = failures ? 1 : 0;
})();
