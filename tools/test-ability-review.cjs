'use strict';

// Execute the production Ability/service modules; simulate only their platform
// boundaries and persistent store so lifecycle ordering is deterministic.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { environment } = require('./test-card-host.cjs');
const sdkRoot = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ts = require(path.join(sdkRoot, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));
const sourceRoot = process.env.HONGFLOW_TEST_SOURCE_ROOT || path.resolve(__dirname, '../entry/src/main/ets');
const tests = [];

async function flush() {
  for (let index = 0; index < 80; index++) await Promise.resolve();
}

function deferred() {
  let resolve;
  const promise = new Promise(accept => { resolve = accept; });
  return { promise, resolve };
}

function loader(mocks, globals = {}) {
  const sandbox = vm.createContext({
    console, Date, Promise, Uint8Array, ObservedV2: value => value, Trace() { },
    ...globals
  });
  const cache = new Map();
  function load(relative) {
    const filename = path.resolve(sourceRoot, relative);
    if (cache.has(filename)) return cache.get(filename).exports;
    const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      fileName: filename.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true }
    });
    assert.deepEqual((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error)
      .map(item => ts.flattenDiagnosticMessageText(item.messageText, ' ')), [], filename);
    const module = { exports: {} };
    cache.set(filename, module);
    const requireModule = specifier => {
      if (Object.hasOwn(mocks, specifier)) return mocks[specifier];
      assert.ok(specifier.startsWith('.'), 'Unmocked dependency: ' + specifier);
      return load(path.resolve(path.dirname(filename), specifier) + '.ets');
    };
    new vm.Script('(function(require,module,exports){\n' + compiled.outputText + '\n})', { filename })
      .runInContext(sandbox)(requireModule, module, module.exports);
    return module.exports;
  }
  return load;
}

function vpnFixture() {
  const events = {
    starts: 0, stops: 0, destroys: 0, releases: 0, closes: [], snapshots: [], refreshes: 0
  };
  const state = {
    request: {
      id: 'run-current', profileId: 'profile-fixture', secret: 'fixture-secret',
      createdAt: Date.now(), cancelled: false, stopping: false
    },
    snapshot: {}, active: false, createGate: undefined, destroyFails: false, queryFails: false, writeFails: false,
    startFails: false, snapshotFails: false, writeFailuresRemaining: 0,
    foreignActive: false, registrationDelayed: false, nameFails: false, destroySilentlyFails: false
  };
  const timers = new Map();
  class Store {
    root = '/fixture';
    readRequest() { return state.request ? { ...state.request } : undefined; }
    writeRequest(request) {
      if (state.writeFailuresRemaining-- > 0) throw new Error('Fixture transient persistence failure');
      if (state.writeFails) throw new Error('Fixture persistence failure');
      state.request = { ...request };
    }
    writeSnapshot(snapshot) {
      if (state.snapshotFails) throw new Error('Fixture snapshot failure');
      state.snapshot = { ...snapshot, updatedAt: Date.now() };
      events.snapshots.push(state.snapshot);
    }
    readSettings() { return { mode: 'rule', selections: {} }; }
    profilePath(id) { return '/fixture/' + id + '.yaml'; }
    seedCoreResources() { }
  }
  const connection = {
    async protectProcessNet() { },
    async create() {
      if (state.createGate) await state.createGate.promise;
      state.active = true;
      return 17;
    },
    async destroy() {
      events.destroys++;
      if (state.destroyFails) throw new Error('Fixture interface release failure');
      if (!state.destroySilentlyFails) state.active = false;
    }
  };
  const mocks = {
    '@kit.NetworkKit': {
      VpnExtensionAbility: class { context = {}; },
      http: { RequestMethod: { PUT: 'PUT' } },
      vpnExtension: {
        createVpnConnection: () => connection,
        async stopVpnExtensionAbility() { events.releases++; }
      },
      connection: {
        NetBearType: { BEARER_VPN: 9 },
        getAllNetsSync() {
          if (state.queryFails) throw new Error('Fixture unavailable network service');
          return [...(state.active && !state.registrationDelayed ? [{ netId: 107 }] : []),
          ...(state.foreignActive ? [{ netId: 207 }] : [])];
        },
        getNetCapabilitiesSync: () => ({ bearerTypes: [9] }),
        getConnectionPropertiesSync: network => ({
          interfaceName: network.netId === 107 ? 'tun-fixture' : 'tun-other'
        })
      }
    },
    '@kit.CoreFileKit': { fileIo: { closeSync: fd => events.closes.push(fd) } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() { }, warn() { }, error() { } } },
    'libhongflowbridge.so': {
      default: {
        tunInterfaceName(fd) {
          assert.equal(fd, 17);
          if (state.nameFails) throw new Error('Fixture unavailable TUN identity');
          return 'tun-fixture';
        },
        async start() {
          events.starts++;
          if (state.startFails) throw new Error('Fixture native start failure');
        }, async stop() { events.stops++; }
      }
    },
    '../service/FileStore': { FileStore: Store },
    '../service/CoreApi': { CoreApi: class { async setMode() { } } },
    '../service/VpnCardService': { VpnCardService: class { refresh() { events.refreshes++; } } }
  };
  const load = loader(mocks, {
    setInterval: callback => { const id = timers.size + 1; timers.set(id, callback); return id; },
    clearInterval: id => timers.delete(id)
  });
  const Ability = load('vpnability/HongFlowVpnAbility.ets').default;
  const ability = new Ability();
  return {
    ability, events, state, timers, load,
    async start() { ability.onCreate({ parameters: { requestId: 'run-current' } }); await flush(); }
  };
}

function desktopFixture() {
  const callbacks = [];
  const events = [];
  let active = '';
  const menus = [];
  const tooltips = [];
  const listeners = new Map();
  const statusBarManager = {
    async isStatusBarCapabilitySupported() { return true; },
    on(name, callback) {
      if (!listeners.has(name)) listeners.set(name, new Set());
      listeners.get(name).add(callback);
    },
    off(name, callback) { listeners.get(name)?.delete(callback); },
    updateStatusBarMenu(_context, menu) { menus.push(menu); },
    async updateStatusBarHoverTips(_context, tip) { tooltips.push(tip); },
    addToStatusBar(context, item, callback) {
      events.push('add:' + context.id);
      callbacks.push(() => { active = context.id; callback(undefined); });
    },
    removeFromStatusBar(context) { events.push('remove:' + context.id); active = ''; }
  };
  const load = loader({
    '@kit.AbilityKit': {},
    '@kit.BasicServicesKit': { deviceInfo: { deviceType: '2in1', apiAvailable: () => true } },
    '@kit.DesktopExtensionKit': { statusBarManager },
    '@kit.ImageKit': {
      image: {
        PixelMapFormat: { RGBA_8888: 1 }, AlphaType: { UNPREMUL: 1 },
        async createPixelMap() { return { release() { } }; }
      }
    }
  }, { canIUse: () => true });
  const { DesktopStatus } = load('service/DesktopStatus.ets');
  return {
    DesktopStatus, callbacks, events, menus, tooltips,
    emit(name, data) { listeners.get(name)?.forEach(callback => callback({ data })); },
    get active() { return active; }
  };
}

function test(name, body) { tests.push({ name, body }); }

test('system destruction cancels the owned request and confirms cleanup without another stop', async () => {
  const e = vpnFixture();
  await e.start();
  assert.equal(e.state.snapshot.phase, 'connected');
  assert.equal(e.events.starts, 1);
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.request.cancelled, true);
  assert.equal(e.state.request.stopping, false);
  assert.equal(e.state.snapshot.phase, 'idle');
  assert.equal(e.events.stops, 1);
  assert.equal(e.events.destroys, 1);
  assert.deepEqual(e.events.closes, [17]);
  assert.equal(e.events.releases, 0);
  assert.equal(e.timers.size, 0);
});

test('system destruction during pending TUN creation cancels before a late native start', async () => {
  const e = vpnFixture();
  e.state.createGate = deferred();
  await e.start();
  e.ability.onDestroy();
  assert.equal(e.state.request.cancelled, true);
  assert.equal(e.state.request.stopping, true);
  e.state.createGate.resolve();
  await flush();
  assert.equal(e.events.starts, 0);
  assert.equal(e.events.stops, 1);
  assert.equal(e.events.destroys, 1);
  assert.equal(e.state.request.stopping, false);
  assert.equal(e.state.snapshot.phase, 'idle');
});

test('failed interface cleanup remains recoverable and is never reported as released', async () => {
  const e = vpnFixture();
  await e.start();
  e.state.destroyFails = true;
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.request.cancelled, true);
  assert.equal(e.state.request.stopping, true);
  assert.equal(e.state.snapshot.phase, 'error');
  assert.equal(e.state.active, true);
});

test('a failed system VPN query cannot clear the durable stopping flag', async () => {
  const e = vpnFixture();
  await e.start();
  e.state.queryFails = true;
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.request.cancelled, true);
  assert.equal(e.state.request.stopping, true);
  const { isSystemVpnAbsent } = e.load('service/VpnNetworkState.ets');
  assert.equal(isSystemVpnAbsent(), false);
});

test('old extension destruction cannot cancel or publish over a newer request', async () => {
  const e = vpnFixture();
  await e.start();
  e.state.request = { ...e.state.request, id: 'run-new', cancelled: false, stopping: false };
  e.state.snapshot = { requestId: 'run-new', phase: 'starting' };
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.request.id, 'run-new');
  assert.equal(e.state.request.cancelled, false);
  assert.equal(e.state.request.stopping, false);
  assert.equal(e.state.snapshot.requestId, 'run-new');
  assert.equal(e.state.snapshot.phase, 'starting');
});

test('a persistence error cannot block system-requested native and TUN teardown', async () => {
  const e = vpnFixture();
  await e.start();
  e.state.writeFails = true;
  assert.doesNotThrow(() => e.ability.onDestroy());
  await flush();
  assert.equal(e.events.stops, 1);
  assert.equal(e.events.destroys, 1);
  assert.deepEqual(e.events.closes, [17]);
  assert.equal(e.state.active, false);
});

test('native startup failure still cleans resources when request cancellation cannot be saved', async () => {
  const e = vpnFixture();
  e.state.startFails = true;
  e.state.writeFails = true;
  await e.start();
  e.ability.onDestroy();
  await flush();
  assert.equal(e.events.stops, 1);
  assert.equal(e.events.destroys, 1);
  assert.deepEqual(e.events.closes, [17]);
  assert.equal(e.state.active, false);
});

test('heartbeat storage failure stays contained and a later heartbeat can publish again', async () => {
  const e = vpnFixture();
  await e.start();
  e.state.snapshotFails = true;
  const beat = Array.from(e.timers.values())[0];
  assert.doesNotThrow(() => beat());
  const count = e.events.snapshots.length;
  e.state.snapshotFails = false;
  beat();
  assert.equal(e.events.snapshots.length, count + 1);
  e.ability.onDestroy();
  await flush();
});

test('confirmed release durably cancels a request after a transient cancellation write failure', async () => {
  const e = vpnFixture();
  await e.start();
  e.state.writeFailuresRemaining = 1;
  e.ability.onDestroy();
  await flush();
  assert.equal(e.events.stops, 1);
  assert.equal(e.events.destroys, 1);
  assert.equal(e.state.request.cancelled, true);
  assert.equal(e.state.request.stopping, false);
});

test('snapshot write failure cannot prevent cooperative cleanup from releasing the extension', async () => {
  const e = vpnFixture();
  await e.start();
  e.state.snapshotFails = true;
  e.state.request.cancelled = true;
  e.state.request.stopping = true;
  Array.from(e.timers.values())[0]();
  await flush();
  assert.equal(e.events.stops, 1);
  assert.equal(e.events.destroys, 1);
  assert.equal(e.events.releases, 1);
  assert.equal(e.state.active, false);
});

test('extension cleanup ignores another VPN after the owned interface is removed', async () => {
  const e = vpnFixture();
  e.state.foreignActive = true;
  await e.start();
  assert.equal(e.state.snapshot.vpnNetId, 107);
  assert.equal(e.state.snapshot.tunnelState, 'created');
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.snapshot.tunnelState, 'released');
  assert.equal(e.state.request.stopping, false);
  assert.equal(e.state.active, false);
  assert.equal(e.state.foreignActive, true);
});

test('late network registration can capture identity without restarting a working VPN', async () => {
  const e = vpnFixture();
  e.state.registrationDelayed = true;
  e.state.foreignActive = true;
  await e.start();
  assert.equal(e.state.snapshot.phase, 'connected');
  assert.equal(e.state.snapshot.vpnNetId, -1);
  e.state.registrationDelayed = false;
  Array.from(e.timers.values())[0]();
  assert.equal(e.state.snapshot.vpnNetId, 107);
  assert.equal(e.events.starts, 1);
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.request.stopping, false);
  assert.equal(e.state.snapshot.tunnelState, 'released');
});

test('create in flight never publishes released evidence before its late TUN is cleaned', async () => {
  const e = vpnFixture();
  e.state.createGate = deferred();
  e.state.foreignActive = true;
  await e.start();
  assert.equal(e.state.snapshot.tunnelState, 'creating');
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.request.stopping, true);
  assert.equal(e.state.snapshot.tunnelState, 'creating');
  assert.equal(e.events.destroys, 0);
  e.state.createGate.resolve();
  await flush();
  assert.equal(e.events.starts, 0);
  assert.equal(e.events.destroys, 1);
  assert.equal(e.state.snapshot.tunnelState, 'released');
  assert.equal(e.state.request.stopping, false);
});

test('cancel before create stays not-created and ignores an unrelated active VPN', async () => {
  const e = vpnFixture();
  e.state.foreignActive = true;
  e.ability.onCreate({ parameters: { requestId: 'run-current' } });
  e.ability.onDestroy();
  await flush();
  assert.equal(e.events.starts, 0);
  assert.equal(e.events.destroys, 0);
  assert.equal(e.state.snapshot.tunnelState, 'not-created');
  assert.equal(e.state.request.stopping, false);
  assert.equal(e.state.foreignActive, true);
});

test('a reported destroy success cannot hide an owned network that still exists', async () => {
  const e = vpnFixture();
  e.state.foreignActive = true;
  await e.start();
  e.state.destroySilentlyFails = true;
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.snapshot.tunnelState, 'released');
  assert.equal(e.state.request.stopping, true);
  assert.equal(e.state.active, true);
});

test('failed destroy cannot publish release confirmation when network identity was unavailable', async () => {
  const e = vpnFixture();
  e.state.nameFails = true;
  e.state.foreignActive = true;
  await e.start();
  assert.equal(e.state.snapshot.vpnNetId, -1);
  e.state.destroyFails = true;
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.snapshot.tunnelState, 'created');
  assert.equal(e.state.snapshot.phase, 'error');
  assert.equal(e.state.request.stopping, true);
  assert.equal(e.state.active, true);
});

test('unknown network identity keeps cleanup pending after a silent destroy failure', async () => {
  const e = vpnFixture();
  e.state.nameFails = true;
  e.state.foreignActive = true;
  await e.start();
  e.state.destroySilentlyFails = true;
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.snapshot.vpnNetId, -1);
  assert.equal(e.state.snapshot.tunnelState, 'released');
  assert.equal(e.state.request.stopping, true);
  assert.equal(e.state.active, true);
});

test('unknown network identity cannot treat a failed system query as released', async () => {
  const e = vpnFixture();
  e.state.nameFails = true;
  await e.start();
  e.state.queryFails = true;
  e.ability.onDestroy();
  await flush();
  assert.equal(e.state.snapshot.vpnNetId, -1);
  assert.equal(e.state.snapshot.tunnelState, 'released');
  assert.equal(e.state.request.stopping, true);
  assert.equal(e.state.active, false);
});

test('failure to persist the creating marker prevents native interface creation', async () => {
  const e = vpnFixture();
  e.state.snapshotFails = true;
  await e.start();
  assert.equal(e.events.starts, 0);
  assert.equal(e.events.destroys, 0);
  assert.equal(e.state.active, false);
  assert.equal(e.state.request.cancelled, true);
});

test('status bar describes cleanup and refreshes when cleanup alone changes', async () => {
  const e = desktopFixture();
  const model = { phase: 'error', busy: false, needsCleanup: true };
  const status = new e.DesktopStatus();
  const attaching = status.attach({ id: 'cleanup' }, model);
  await flush();
  e.callbacks.shift()();
  await attaching;
  assert.equal(e.menus.at(-1)[0][0].title, '清理连接');
  assert.equal(e.tooltips.at(-1), '鸿流 · 连接待清理');
  model.needsCleanup = false;
  status.refresh();
  assert.equal(e.menus.at(-1)[0][0].title, '连接 VPN');
  assert.equal(e.tooltips.at(-1), '鸿流 · 连接失败');
  status.dispose();
});

test('a cancelled status bar start cannot overwrite a newer disconnect message', async () => {
  const e = environment();
  const desktop = desktopFixture();
  const status = new desktop.DesktopStatus();
  const gate = e.holdStop();
  try {
    e.setStartMode('pending');
    await e.initialize();
    const attaching = status.attach(e.context, e.model);
    await flush();
    desktop.callbacks.shift()();
    await attaching;
    desktop.emit('rightMenuClick', { menuCode: 'hongflow.toggle' });
    await e.clock.until(() => e.events.starts.length === 1);
    desktop.emit('rightMenuClick', { menuCode: 'hongflow.toggle' });
    await e.clock.advance(400);
    assert.equal(e.model.phase, 'stopping');
    assert.equal(e.model.operationKind, 'disconnect');
    assert.equal(e.model.message, '正在断开');
    gate.resolve();
    await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
    assert.equal(e.model.message, '');
  } finally {
    gate.resolve();
    status.dispose();
    e.cleanup();
    await flush();
  }
});

test('status bar registration is serialized across destroyed and recreated page instances', async () => {
  const e = desktopFixture();
  const model = { phase: 'idle', busy: false };
  const oldStatus = new e.DesktopStatus();
  const oldAttach = oldStatus.attach({ id: 'old' }, model);
  await flush();
  assert.deepEqual(e.events, ['add:old']);
  oldStatus.dispose();
  const newStatus = new e.DesktopStatus();
  const newAttach = newStatus.attach({ id: 'new' }, model);
  await flush();
  assert.deepEqual(e.events, ['add:old'], 'New registration must wait for the old callback and rollback');
  e.callbacks.shift()();
  await flush();
  assert.deepEqual(e.events, ['add:old', 'remove:old', 'add:new']);
  e.callbacks.shift()();
  await Promise.all([oldAttach, newAttach]);
  assert.equal(e.active, 'new');
  newStatus.dispose();
  assert.equal(e.active, '');
});

(async () => {
  let failed = 0;
  for (const { name, body } of tests) {
    try { await body(); console.log('PASS ' + name); }
    catch (error) { failed++; console.error('FAIL ' + name + '\n' + error.stack); }
  }
  console.log(`${tests.length - failed}/${tests.length} ability/service tests passed`);
  process.exitCode = failed ? 1 : 0;
})();
