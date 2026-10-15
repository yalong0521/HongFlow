'use strict';

// Host regression: execute the production .ets modules through the SDK compiler.
// Only platform Kits, VPN/HTTP transports and the native bridge are simulated.
const assert = require('node:assert/strict');
const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const sdkRoot = process.env.DEVECO_SDK_HOME || '/Applications/DevEco-Studio.app/Contents/sdk';
const ts = require(path.join(sdkRoot, 'default/openharmony/ets/build-tools/ets-loader/node_modules/typescript/lib/typescript.js'));

const workspace = path.resolve(__dirname, '..');
const sourceRoot = process.env.HONGFLOW_TEST_SOURCE_ROOT || path.join(workspace, 'entry/src/main/ets');
const tests = [];
const unhandled = [];

async function flush() {
  for (let n = 0; n < 50; n++) await Promise.resolve();
}

function deferred() {
  let resolve;
  const promise = new Promise(accept => { resolve = accept; });
  return { promise, resolve };
}

class Clock {
  now = 1800000000000;
  next = 1;
  timers = new Map();

  set(callback, delay, interval = false) {
    const id = this.next++;
    this.timers.set(id, { callback, at: this.now + Math.max(1, delay || 0), period: interval ? Math.max(1, delay) : 0 });
    return id;
  }

  async advance(duration) {
    const end = this.now + duration;
    await flush();
    while (true) {
      let id;
      let next;
      for (const [key, timer] of this.timers) {
        if (timer.at <= end && (!next || timer.at < next.at)) {
          id = key;
          next = timer;
        }
      }
      if (!next) break;
      this.now = next.at;
      if (next.period) next.at += next.period;
      else this.timers.delete(id);
      next.callback();
      await flush();
    }
    this.now = end;
    await flush();
  }

  async until(predicate, timeout = 12000) {
    for (let elapsed = 0; elapsed <= timeout; elapsed += 100) {
      await flush();
      if (predicate()) return;
      await this.advance(100);
    }
    throw new Error('Host virtual-clock condition timed out');
  }
}

function environment() {
  fs.mkdirSync(path.join(workspace, 'work'), { recursive: true });
  const directory = fs.mkdtempSync(path.join(workspace, 'work/card-fixture-'));
  const clock = new Clock();
  const events = { starts: [], stops: [], queries: 0, publications: [], warnings: [], http: [], windows: [], managers: [] };
  const form = { items: [], failQueries: 0, failUpdates: 0 };
  let activeVpn = false;
  let foreignVpnActive = false;
  let heartbeat;
  let startMode = 'connected';
  let proxies = {};
  let subscription;
  let delayRequest;
  let stopRequest;
  let pickerRequest;
  let store;
  const sockets = [];
  const context = {
    filesDir: directory, resourceManager: {},
    getApplicationContext: () => ({ setColorMode() { } })
  };

  class HostEncoder {
    static create() { return new HostEncoder(); }
    encodeInto(value) { return new TextEncoder().encode(value); }
  }
  class HostDecoder {
    constructor(encoding, options) { this.decoder = new TextDecoder(encoding, options); }
    static create(encoding, options) { return new HostDecoder(encoding, options); }
    decodeToString(bytes) { return this.decoder.decode(bytes); }
  }
  class HostDate extends Date {
    constructor(...values) { super(...(values.length ? values : [clock.now])); }
    static now() { return clock.now; }
  }
  class UIAbility {
    constructor() {
      this.context = context;
      const handlers = new Map();
      this.callee = {
        handlers,
        on: (method, handler) => {
          assert.equal(handlers.has(method), false, 'Callee method must register once per Ability lifetime');
          handlers.set(method, handler);
        },
        off: method => handlers.delete(method)
      };
    }
  }

  const fileIo = {
    OpenMode: { CREATE: 1, WRITE_ONLY: 2, READ_ONLY: 4 },
    accessSync: target => fs.existsSync(target),
    mkdirSync: (target, recursive) => fs.mkdirSync(target, { recursive }),
    unlinkSync: target => fs.unlinkSync(target),
    readTextSync: target => fs.readFileSync(target, 'utf8'),
    readSync: (fd, buffer, options = {}) => fs.readSync(fd, Buffer.from(buffer), 0,
      options.length ?? buffer.byteLength, options.offset ?? null),
    openSync: (target, mode) => ({ fd: fs.openSync(target, mode & 4 ? 'r' : 'w') }),
    writeSync: (fd, bytes) => fs.writeSync(fd, Buffer.from(bytes)),
    fsyncSync: fd => fs.fsyncSync(fd),
    closeSync: file => fs.closeSync(typeof file === 'number' ? file : file.fd),
    renameSync: (from, to) => fs.renameSync(from, to),
    statSync: target => typeof target === 'number' ? fs.fstatSync(target) : fs.statSync(target)
  };

  function writeConnected() {
    const request = store.readRequest();
    activeVpn = true;
    store.writeSnapshot({
      phase: 'connected', message: '', requestId: request.id, profileId: request.profileId,
      secret: request.secret, connectedSince: clock.now, updatedAt: clock.now,
      tunnelState: 'created', vpnNetId: 107
    });
    heartbeat = clock.set(() => {
      if (activeVpn) store.writeSnapshot(store.readSnapshot());
    }, 500, true);
  }

  const native = {
    async validateProfile(yaml) {
      assert.match(yaml, /proxies:/);
      return JSON.stringify({ valid: true, proxies: 1, groups: 1, rules: 1, providers: 0, mode: 'rule' });
    },
    async setMode() { },
  };
  const kits = {
    '@kit.AbilityKit': { UIAbility, ConfigurationConstant: { ColorMode: { COLOR_MODE_NOT_SET: -1 } } },
    '@kit.ArkUI': { window: {} },
    '@kit.IPCKit': { rpc: {} },
    '@kit.ArkTS': { util: { TextEncoder: HostEncoder, TextDecoder: HostDecoder, generateRandomUUID: () => crypto.randomUUID() } },
    '@kit.BasicServicesKit': { deviceInfo: { apiAvailable: () => true } },
    '@kit.CoreFileKit': {
      fileIo,
      picker: { DocumentViewPicker: class { async select() { return pickerRequest ? pickerRequest.promise : []; } } }
    },
    '@kit.PerformanceAnalysisKit': { hilog: { warn: (...args) => events.warnings.push(args), error() { }, info() { } } },
    '@kit.LocalizationKit': {},
    '@kit.FormKit': {
      formInfo: { FormDimension: { Dimension_1_2: 1 } },
      formBindingData: { createFormBindingData: data => ({ data: JSON.stringify(data) }) },
      formProvider: {
        async getPublishedRunningFormInfos() {
          events.queries++;
          if (form.failQueries-- > 0) throw Object.assign(new Error('Mock transient Form IPC failure'), { code: 16500050 });
          return form.items;
        },
        async updateForm(id, data) {
          if (form.failUpdates-- > 0) throw Object.assign(new Error('Mock update failure'), { code: 16500050 });
          events.publications.push({ id, value: JSON.parse(data.data) });
        },
        openFormManager: want => events.managers.push(want)
      }
    },
    '@kit.NetworkKit': {
      connection: {
        NetBearType: { BEARER_VPN: 4 },
        getAllNetsSync: () => [...(activeVpn ? [{ netId: 107 }] : []),
        ...(foreignVpnActive ? [{ netId: 207 }] : [])],
        getNetCapabilitiesSync: () => ({ bearerTypes: [4] }),
        getConnectionPropertiesSync: network => ({
          interfaceName: network.netId === 107 ? 'tun-fixture' : 'tun-other'
        })
      },
      vpnExtension: {
        createVpnObserver: () => ({ onAuthorizationResult() { }, offAuthorizationResult() { } }),
        startVpnExtensionAbility(want) {
          events.starts.push(want);
          if (startMode === 'pending') return new Promise(() => { });
          assert.equal(want.parameters.requestId, store.readRequest().id);
          writeConnected();
          return Promise.resolve();
        },
        async stopVpnExtensionAbility(want) {
          events.stops.push(want);
          if (stopRequest) await stopRequest.promise;
          activeVpn = false;
          clock.timers.delete(heartbeat);
          const request = store.readRequest();
          if (request) { request.cancelled = true; request.stopping = false; store.writeRequest(request); }
          const snapshot = store.readSnapshot();
          store.writeSnapshot({ ...snapshot, phase: 'idle', message: '', connectedSince: 0, tunnelState: 'released' });
        }
      },
      webSocket: {
        createWebSocket() {
          const handlers = new Map();
          const socket = {
            on: (name, callback) => handlers.set(name, callback),
            off: name => handlers.delete(name),
            async connect(url, options) {
              assert.equal(url, 'ws://127.0.0.1:9090/logs?level=info');
              assert.equal(options.header.Authorization, 'Bearer ' + store.readSnapshot().secret);
              return true;
            },
            async close() { },
            emit: data => handlers.get('message')?.(undefined, data)
          };
          sockets.push(socket);
          return socket;
        }
      },
      http: {
        RequestMethod: { GET: 'GET', PUT: 'PUT', DELETE: 'DELETE' }, HttpDataType: { STRING: 0, ARRAY_BUFFER: 1 },
        createHttp: () => ({
          async request(url, options) {
            // Only an explicitly configured synthetic subscription is accepted.
            // This fixture never sends HTTP requests to any network.
            if (subscription && url === 'https://fixture.invalid/clash.yaml') {
              events.http.push(url);
              return subscription.promise;
            }
            assert.ok(url.startsWith('http://127.0.0.1:9090/'), 'Unexpected external HTTP request');
            assert.equal(options.header.Authorization, 'Bearer ' + store.readSnapshot().secret);
            events.http.push(url);
            const route = new URL(url).pathname;
            if (delayRequest && route.endsWith('/delay')) return delayRequest.promise;
            const payload = route === '/proxies' ? { proxies } :
              route === '/configs' ? { mode: 'rule' } :
                route === '/connections' ? { uploadTotal: 0, downloadTotal: 0 } : undefined;
            assert.ok(payload, 'Unexpected core API route');
            return { responseCode: 200, result: JSON.stringify(payload) };
          },
          destroy() { }
        })
      }
    }
  };
  const sandbox = vm.createContext({
    console, Promise, Date: HostDate, URL, TextEncoder, TextDecoder,
    ObservedV2: value => value, Trace: () => { },
    setTimeout: (callback, delay) => clock.set(callback, delay),
    setInterval: (callback, delay) => clock.set(callback, delay, true),
    clearTimeout: id => clock.timers.delete(id), clearInterval: id => clock.timers.delete(id)
  });
  const cache = new Map();
  function load(filename) {
    if (cache.has(filename)) return cache.get(filename).exports;
    const source = fs.readFileSync(filename, 'utf8');
    const compiled = ts.transpileModule(source, {
      fileName: filename.replace(/\.ets$/, '.ts'), reportDiagnostics: true,
      compilerOptions: { module: ts.ModuleKind.CommonJS, target: ts.ScriptTarget.ES2020, experimentalDecorators: true }
    });
    assert.deepEqual((compiled.diagnostics || []).filter(item => item.category === ts.DiagnosticCategory.Error)
      .map(item => ts.flattenDiagnosticMessageText(item.messageText, ' ')), [], filename);
    const module = { exports: {} };
    cache.set(filename, module);
    const localRequire = specifier => {
      if (kits[specifier]) return kits[specifier];
      if (specifier === 'libhongflowbridge.so') return { default: native };
      assert.ok(specifier.startsWith('.'), 'Unmocked dependency: ' + specifier);
      return load(path.resolve(path.dirname(filename), specifier) + '.ets');
    };
    const wrapper = new vm.Script('(function(require,module,exports){\n' + compiled.outputText + '\n})', { filename });
    wrapper.runInContext(sandbox)(localRequire, module, module.exports);
    return module.exports;
  }
  const models = load(path.join(sourceRoot, 'model/AppModels.ets'));
  const { FileStore } = load(path.join(sourceRoot, 'service/FileStore.ets'));
  const { VpnCardService } = load(path.join(sourceRoot, 'service/VpnCardService.ets'));
  const { CardCommandInbox } = load(path.join(sourceRoot, 'service/CardCommandInbox.ets'));
  const { appSession } = load(path.join(sourceRoot, 'service/AppSession.ets'));
  const EntryAbility = load(path.join(sourceRoot, 'entryability/EntryAbility.ets')).default;
  store = new FileStore(context);
  const profile = new models.ProfileInfo();
  profile.id = 'aaaaaaaa-aaaa-4aaa-aaaa-aaaaaaaaaaaa';
  profile.name = 'Synthetic local fixture';
  store.writeText(store.profilePath(profile.id), 'proxies: [{name: fixture, type: direct}]\nproxy-groups: []\nrules: [MATCH,DIRECT]');
  store.writeProfiles([profile]);
  const settings = new models.SavedSettings();
  settings.selectedProfileId = profile.id;
  store.writeSettings(settings);
  const cards = new VpnCardService(context);
  const card = cards.addForm('1007');
  form.items = [{ formId: card.formId, bundleName: models.APP_BUNDLE_NAME, moduleName: 'entry', abilityName: 'HongFlowFormAbility', formName: 'HongFlowQuick' }];
  const model = appSession.model;
  const entry = new EntryAbility();

  const wantFor = (data, action = data.action) => ({
    parameters: {
      params: JSON.stringify({
        cardAction: action, cardId: data.formId, cardToken: data.cardToken, cardRequestId: data.requestId
      })
    }
  });
  const initialize = async () => {
    if (!entry.callee.handlers.has('controlVpn')) entry.onCreate({});
    await appSession.ready();
  };
  const offer = want => {
    const handler = entry.callee.handlers.get('controlVpn');
    assert.ok(handler, 'The production Ability must register its background call handler');
    const reply = handler({ readString: () => want.parameters?.params });
    let accepted;
    assert.equal(reply.marshalling({ writeBoolean: value => { accepted = value; } }), true);
    return accepted;
  };
  const createWindow = () => entry.onWindowStageCreate({
    getMainWindowSync: () => ({ async setWindowLayoutFullScreen() { } }),
    loadContent: (page, callback) => { events.windows.push(page); callback({ code: 0 }); }
  });
  const seedRun = (id, cancelled = false, stopping = false, phase = cancelled ? 'idle' : 'connected') => {
    const request = new models.VpnRequest();
    request.id = id; request.profileId = profile.id; request.secret = 'fixture-secret-' + id;
    request.createdAt = clock.now; request.cancelled = cancelled; request.stopping = stopping;
    store.writeRequest(request);
    const snapshot = new models.VpnSnapshot();
    snapshot.phase = phase; snapshot.requestId = id; snapshot.profileId = profile.id; snapshot.secret = request.secret;
    snapshot.connectedSince = phase === 'connected' ? clock.now : 0;
    store.writeSnapshot(snapshot);
    activeVpn = phase === 'connected' && !cancelled;
    return request;
  };
  return {
    model, appSession, initialize, createWindow, cards, card, store, context, clock, events, form, wantFor, offer, entry, seedRun, CardCommandInbox,
    fileIo, native, network: kits['@kit.NetworkKit'],
    openManager: () => VpnCardService.openManager(),
    setStartMode: mode => { startMode = mode; },
    setForeignVpnActive: value => { foreignVpnActive = value; },
    setProxies: value => { proxies = value; },
    holdSubscription: () => { subscription = deferred(); return subscription; },
    holdDelay: () => { delayRequest = deferred(); return delayRequest; },
    holdStop: () => { stopRequest = deferred(); return stopRequest; },
    holdPicker: () => { pickerRequest = deferred(); return pickerRequest; },
    emitCoreLog(data) {
      assert.ok(sockets.length > 0, 'The production model must open its core log socket first');
      sockets.at(-1).emit(data);
    },
    cleanup() { entry.onDestroy(); clock.timers.clear(); fs.rmSync(directory, { recursive: true, force: true }); }
  };
}

function test(name, callback) { tests.push({ name, callback }); }

test('minimal card omits configuration details and the manager requests the 1x2 size', async e => {
  const profile = e.store.readProfiles()[0];
  profile.name = 'Private subscription name';
  e.store.writeProfiles([profile]);
  const data = e.cards.addForm('1007');
  assert.equal(Object.hasOwn(data, 'profileName'), false);
  assert.equal(Object.hasOwn(data, 'updatedLabel'), false);
  assert.equal(JSON.stringify(data).includes(profile.name), false);
  e.openManager();
  assert.equal(e.events.managers.length, 1);
  assert.equal(e.events.managers[0].parameters['ohos.extra.param.key.form_dimension'], 1);
});

test('a card without a profile gives guidance and cannot start or open a window', async e => {
  e.store.writeProfiles([]);
  await e.initialize();
  const data = e.cards.addForm('1007');
  assert.equal(data.action, 'none');
  assert.equal(data.statusLabel, '请先导入配置');
  assert.equal(e.offer(e.wantFor(data)), false);
  // An old cached start action still cannot bypass the real profile check.
  assert.equal(e.offer(e.wantFor(data, 'start')), true);
  await e.clock.advance(300);
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.events.stops.length, 0);
  assert.equal(e.events.windows.length, 0);
  assert.equal(e.store.readRequest(), undefined);
});

test('retired notification commands cannot disconnect on cold or warm app entry', async e => {
  const request = e.seedRun('retired-notification-run');
  const want = { parameters: { operation: 'disconnect', controlToken: request.secret } };
  e.entry.onCreate(want);
  await e.appSession.ready();
  assert.equal(e.model.phase, 'connected');
  assert.equal(e.store.readRequest().cancelled, false);
  e.entry.onNewWant(want);
  await e.appSession.ready();
  assert.equal(e.model.phase, 'connected');
  assert.equal(e.store.readRequest().cancelled, false);
  assert.equal(e.events.stops.length, 0);
});

test('cold background call starts without a window and foreground reuses the active model', async e => {
  e.entry.onCreate({});
  assert.equal(e.offer(e.wantFor(e.card, 'start')), true);
  await e.clock.until(() => e.model.phase === 'connected' && !e.model.busy);
  assert.equal(e.events.windows.length, 0);
  assert.equal(e.events.starts.length, 1);
  const requestId = e.store.readRequest().id;
  const initialization = e.appSession.ready();
  assert.equal(e.appSession.initialize(e.context), initialization);
  e.createWindow();
  await flush();
  assert.deepEqual(e.events.windows, ['pages/Index']);
  assert.equal(e.appSession.model, e.model);
  assert.equal(e.model.phase, 'connected');
  assert.equal(e.store.readRequest().id, requestId);
  assert.equal(e.events.starts.length, 1);
});

test('router launches without control parameters preserve idle and connected sessions', async e => {
  const routerWants = [{}, { parameters: { params: '{}' } }];
  e.entry.onCreate(routerWants[0]);
  e.createWindow();
  await e.appSession.ready();
  for (const want of routerWants) e.entry.onNewWant(want);
  await e.clock.advance(300);
  assert.equal(e.events.windows.length, 1);
  assert.equal(e.model.phase, 'idle');
  assert.equal(e.model.busy, false);
  assert.equal(e.store.readRequest(), undefined);
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.events.stops.length, 0);

  assert.equal(e.offer(e.wantFor(e.card, 'start')), true);
  await e.clock.until(() => e.model.phase === 'connected' && !e.model.busy);
  const requestId = e.store.readRequest().id;
  for (const want of routerWants) e.entry.onNewWant(want);
  await e.clock.advance(300);
  assert.equal(e.model.phase, 'connected');
  assert.equal(e.model.busy, false);
  assert.equal(e.store.readRequest().id, requestId);
  assert.equal(e.store.readRequest().cancelled, false);
  assert.equal(e.events.starts.length, 1);
  assert.equal(e.events.stops.length, 0);
});

test('window destruction leaves a pending background start owned by the Ability', async e => {
  e.setStartMode('pending');
  e.entry.onCreate({});
  e.offer(e.wantFor(e.card, 'start'));
  await e.clock.until(() => e.events.starts.length === 1);
  const requestId = e.store.readRequest().id;
  e.entry.onWindowStageDestroy();
  await e.clock.advance(500);
  assert.equal(e.model.busy, true);
  assert.equal(e.model.phase, 'starting');
  assert.equal(e.store.readRequest().id, requestId);
  assert.equal(e.store.readRequest().cancelled, false);
  e.createWindow();
  await flush();
  assert.equal(e.appSession.model, e.model);
  assert.equal(e.events.starts.length, 1);
  const index = fs.readFileSync(path.join(sourceRoot, 'pages/Index.ets'), 'utf8');
  assert.match(index, /model: MainModel = appSession\.model/);
  assert.doesNotMatch(index, /this\.model\.(?:initialize|dispose)\(/);
  e.entry.onDestroy();
  assert.equal(e.entry.callee.handlers.size, 0);
  assert.equal(e.model.busy, false);
});

test('a failed cold initialization can retry a card call without leaving another model', async e => {
  const profiles = e.store.readProfiles();
  e.store.writeText(e.store.root + '/profiles.json', '{');
  e.entry.onCreate({});
  e.offer(e.wantFor(e.card, 'start'));
  await assert.rejects(e.appSession.ready(), /读取订阅列表失败/);
  await flush();
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.model.busy, false);
  e.store.writeProfiles(profiles);
  assert.equal(e.offer(e.wantFor(e.card, 'start')), true);
  await e.clock.until(() => e.model.phase === 'connected' && !e.model.busy);
  assert.equal(e.events.starts.length, 1);
  assert.equal(e.events.windows.length, 0);
  assert.equal(e.appSession.model, e.model);
});

test('cold start consumes one command; window/model recreation does not replay', async e => {
  e.entry.onCreate(e.wantFor(e.card, 'start'));
  assert.equal(e.events.starts.length, 0);
  await e.initialize();
  await e.clock.until(() => e.model.phase === 'connected' && !e.model.busy);
  assert.equal(e.events.starts.length, 1);
  const id = e.store.readRequest().id;
  e.entry.onDestroy();
  await e.initialize();
  await e.clock.advance(500);
  assert.equal(e.events.starts.length, 1);
  assert.equal(e.store.readRequest().id, id);
});

test('duplicate start clicks are idempotent during startup and after connection', async e => {
  await e.initialize();
  e.offer(e.wantFor(e.card, 'start'));
  e.offer(e.wantFor(e.card, 'start'));
  await e.clock.until(() => e.model.phase === 'connected' && !e.model.busy);
  const id = e.store.readRequest().id;
  e.offer(e.wantFor(e.card, 'start'));
  await e.clock.advance(200);
  assert.equal(e.events.starts.length, 1);
  assert.equal(e.store.readRequest().id, id);
});

test('duplicate stop clicks are idempotent during cleanup and after idle', async e => {
  e.seedRun('run-stop');
  await e.initialize();
  const command = e.cards.authenticatedCommand(e.wantFor(e.cards.addForm('1007'), 'stop'));
  e.CardCommandInbox.offer(command);
  e.CardCommandInbox.offer(command);
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  e.CardCommandInbox.offer(command);
  await e.clock.advance(300);
  assert.equal(e.events.stops.length, 1);
  assert.equal(e.store.readRequest().id, 'run-stop');
  assert.equal(e.store.readRequest().cancelled, true);
  assert.equal(e.store.readRequest().stopping, false);
});

test('stop from an old run cannot cancel the current connected run', async e => {
  e.seedRun('run-new');
  await e.initialize();
  const old = { ...e.cards.addForm('1007'), requestId: 'run-old' };
  e.offer(e.wantFor(old, 'stop'));
  await e.clock.advance(300);
  assert.equal(e.events.stops.length, 0);
  assert.equal(e.store.readRequest().cancelled, false);
  assert.equal(e.store.readRequest().id, 'run-new');
  assert.match(e.model.message, /状态已变化/);
});

test('start from an old run cannot restart a later disconnected run', async e => {
  e.seedRun('run-new', true);
  await e.initialize();
  const old = { ...e.cards.addForm('1007'), requestId: 'run-old' };
  e.offer(e.wantFor(old, 'start'));
  await e.clock.advance(300);
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.store.readRequest().id, 'run-new');
  assert.equal(e.store.readRequest().cancelled, true);
  assert.match(e.model.message, /状态已变化/);
});

test('cancelled/stopping error card offers cleanup and completes through the model', async e => {
  e.seedRun('run-cleanup', true, true, 'error');
  const data = e.cards.addForm('1007');
  assert.equal(data.phase, 'error');
  assert.equal(data.action, 'stop');
  assert.equal(data.actionLabel, '清理连接');
  e.entry.onCreate(e.wantFor(data));
  await e.initialize();
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.events.stops.length, 1);
  assert.equal(e.store.readRequest().stopping, false);
});

test('forged or malformed background call params cannot operate the VPN', async e => {
  await e.initialize();
  const valid = JSON.parse(e.wantFor(e.card, 'start').parameters.params);
  const invalid = [undefined, '', '{', 'null', '[]', 'false', '42', JSON.stringify(valid).repeat(100),
    JSON.stringify({ ...valid, cardToken: 'forged' }),
    JSON.stringify({ ...valid, cardId: '../../status' }),
    JSON.stringify({ ...valid, cardAction: 'toggle' }),
    JSON.stringify({ ...valid, cardRequestId: 1 })];
  for (const encoded of invalid) {
    const want = { parameters: { params: encoded } };
    assert.equal(e.cards.authenticatedCommand(want), undefined);
    e.offer(want);
  }
  await e.clock.advance(100);
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.events.stops.length, 0);
  assert.equal(e.store.readRequest(), undefined);
});

test('removed card token is revoked for later background calls', async e => {
  const want = e.wantFor(e.card, 'start');
  assert.ok(e.cards.authenticatedCommand(want));
  e.cards.removeForm(e.card.formId);
  assert.equal(e.cards.authenticatedCommand(want), undefined);
  await e.initialize();
  e.offer(want);
  await e.clock.advance(100);
  assert.equal(e.events.starts.length, 0);
});

test('same-state Form IPC failure retries after backoff; new phase retries immediately', async e => {
  e.form.failQueries = 1;
  e.cards.refresh();
  await flush();
  assert.equal(e.events.queries, 1);
  assert.equal(e.events.publications.length, 0);
  await e.clock.advance(29000);
  e.cards.refresh();
  await flush();
  assert.equal(e.events.queries, 1, 'Retry should respect the 30-second backoff');
  await e.clock.advance(1001);
  e.cards.refresh();
  await flush();
  assert.equal(e.events.queries, 2, 'An unchanged phase must retry after the backoff');
  assert.equal(e.events.publications.at(-1).value.phase, 'idle');
  e.form.failQueries = 1;
  e.seedRun('next-run', true, true, 'error');
  e.cards.refresh();
  await flush();
  assert.equal(e.events.queries, 3);
  const request = e.store.readRequest();
  request.stopping = false;
  e.store.writeRequest(request);
  e.store.writeSnapshot({ ...e.store.readSnapshot(), phase: 'idle' });
  e.cards.refresh();
  await flush();
  assert.equal(e.events.queries, 4, 'A changed phase must bypass backoff');
  assert.equal(e.events.publications.at(-1).value.phase, 'idle');
});

test('pending system authorization times out and durably cancels the request', async e => {
  e.setStartMode('pending');
  await e.initialize();
  e.offer(e.wantFor(e.card, 'start'));
  await e.clock.until(() => e.events.starts.length === 1);
  assert.equal(e.model.phase, 'starting');
  assert.equal(e.model.operationKind, 'connect');
  assert.equal(e.model.operationTarget, e.store.readRequest().profileId);
  assert.equal(e.model.needsCleanup, false);
  await e.clock.advance(30500);
  await e.clock.until(() => !e.model.busy);
  assert.equal(e.store.readRequest().cancelled, true);
  assert.equal(e.model.phase, 'error');
  assert.equal(e.events.starts.length, 1);
  assert.equal(e.model.operationKind, 'none');
  assert.equal(e.model.operationTarget, '');
});

test('subscription busy feedback follows the actual request; rejected second actions cannot replace it', async e => {
  await e.initialize();
  const selected = e.model.selectedProfileId;
  const subscription = e.holdSubscription();
  const importing = e.model.importSubscription('Synthetic new profile', 'https://fixture.invalid/clash.yaml');
  assert.equal(e.model.phase, 'idle');
  assert.equal(e.model.busy, true);
  assert.equal(e.model.operationKind, 'importSubscription');
  assert.equal(e.model.operationTarget, '');
  assert.equal(e.model.canModifyProfiles, false);
  await assert.rejects(e.model.selectProfile(selected), /当前操作/);
  assert.equal(e.model.operationKind, 'importSubscription');
  subscription.resolve({
    responseCode: 200,
    result: new TextEncoder().encode('proxies: [{name: synthetic, type: direct}]').buffer
  });
  await importing;
  assert.equal(e.store.readProfiles().length, 2);
  assert.equal(e.model.selectedProfileId, selected);
  assert.equal(e.model.busy, false);
  assert.equal(e.model.operationKind, 'none');
  assert.equal(e.model.operationTarget, '');
  assert.equal(e.model.canModifyProfiles, true);
});

test('disconnect retains operation ownership when an interrupted node test settles later', async e => {
  e.setProxies({
    'Fixture group': { type: 'Selector', now: 'Fixture node', all: ['Fixture node'] },
    'Fixture node': { type: 'Shadowsocks' }
  });
  e.seedRun('run-feedback-race');
  await e.initialize();
  const delay = e.holdDelay();
  const stop = e.holdStop();
  const testing = e.model.testGroup('Fixture group').then(() => undefined, error => error);
  await flush();
  assert.equal(e.model.operationKind, 'testGroup');
  assert.equal(e.model.operationTarget, 'Fixture group');
  const stopping = e.model.toggleConnection();
  assert.equal(e.model.operationKind, 'disconnect');
  assert.equal(e.model.operationTarget, e.store.readRequest().profileId);
  await e.clock.until(() => e.events.stops.length === 1);
  delay.resolve({ responseCode: 200, result: JSON.stringify({ delay: 48 }) });
  assert.match((await testing).message, /连接已变化/);
  assert.equal(e.model.phase, 'stopping');
  assert.equal(e.model.busy, true);
  assert.equal(e.model.operationKind, 'disconnect');
  assert.equal(e.model.operationTarget, e.store.readRequest().profileId);
  assert.equal(e.model.message, '正在断开');
  stop.resolve();
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  await stopping;
  assert.equal(e.model.operationKind, 'none');
  assert.equal(e.model.operationTarget, '');
  assert.equal(e.model.needsCleanup, false);
});

test('disposing a model clears pending feedback and a late import cannot publish a profile', async e => {
  await e.initialize();
  const subscription = e.holdSubscription();
  const importing = e.model.importSubscription('Disposed import', 'https://fixture.invalid/clash.yaml')
    .then(() => undefined, error => error);
  assert.equal(e.model.operationKind, 'importSubscription');
  e.entry.onDestroy();
  assert.equal(e.model.busy, false);
  assert.equal(e.model.operationKind, 'none');
  assert.equal(e.model.operationTarget, '');
  subscription.resolve({
    responseCode: 200,
    result: new TextEncoder().encode('proxies: [{name: synthetic, type: direct}]').buffer
  });
  assert.match((await importing).message, /页面已关闭/);
  assert.equal(e.store.readProfiles().length, 1);
  assert.equal(e.model.operationKind, 'none');
  assert.equal(e.events.starts.length, 0);
  assert.equal(e.events.stops.length, 0);
});

test('an active session is not a cleanup error; a durable stop failure blocks profile and mode changes', async e => {
  e.seedRun('run-active-state');
  await e.initialize();
  assert.equal(e.model.phase, 'connected');
  assert.equal(e.model.cleanupRequired, true);
  assert.equal(e.model.needsCleanup, false);
  assert.equal(e.model.canModifyProfiles, false);
  assert.equal(e.model.canChangeMode, true);
  e.seedRun('run-active-state', true, true, 'error');
  await e.clock.advance(1000);
  assert.equal(e.model.phase, 'error');
  assert.equal(e.model.needsCleanup, true);
  assert.equal(e.model.canModifyProfiles, false);
  assert.equal(e.model.canChangeMode, false);
  const stopping = e.model.toggleConnection();
  assert.equal(e.model.operationKind, 'disconnect');
  assert.equal(e.model.needsCleanup, false);
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  await stopping;
  assert.equal(e.model.needsCleanup, false);
  assert.equal(e.model.canModifyProfiles, true);
  assert.equal(e.model.canChangeMode, true);
});

test('cancelling the file picker clears import feedback without reporting a successful import', async e => {
  await e.initialize();
  const picker = e.holdPicker();
  const importing = e.model.importLocalFile();
  assert.equal(e.model.operationKind, 'importLocalFile');
  assert.equal(e.model.operationTarget, '');
  assert.equal(e.model.busy, true);
  picker.resolve([]);
  await importing;
  assert.equal(e.store.readProfiles().length, 1);
  assert.equal(e.model.message, '');
  assert.equal(e.model.busy, false);
  assert.equal(e.model.operationKind, 'none');
});

test('core log transport hides saved subscription URLs without exposing shared-prefix credentials', async e => {
  const shortUrl = 'https://private.fixture.invalid/link/[sample]+?token=short-fixture';
  const longUrl = shortUrl + '&privateKey=long-fixture-secret';
  const profiles = e.store.readProfiles();
  profiles[0].url = shortUrl;
  profiles.push({ ...profiles[0], id: crypto.randomUUID(), name: 'Second subscription', url: longUrl });
  e.store.writeProfiles(profiles);
  e.seedRun('run-log-privacy');
  await e.initialize();
  const message = `provider fetch ${longUrl} failed; retry ${shortUrl}; retry ${longUrl}`;
  e.emitCoreLog(JSON.stringify({ type: 'warning', payload: message }));
  assert.equal(e.model.logs.length, 1);
  const line = e.model.logs[0];
  assert.equal(line.level, 'warning');
  assert.equal(line.time, e.clock.now);
  assert.match(line.message, /provider fetch .* failed; retry .*; retry /);
  assert.ok(line.message.includes('[订阅地址已隐藏]'));
  assert.ok(!line.message.includes(shortUrl));
  assert.ok(!line.message.includes(longUrl));
  assert.ok(!line.message.includes('short-fixture'));
  assert.ok(!line.message.includes('long-fixture-secret'));
  assert.equal(e.model.profiles[0].url, shortUrl, 'Log privacy must not change the subscription used for updates');
  assert.equal(e.store.readProfiles()[1].url, longUrl);
});

test('binary core log transport preserves ordinary diagnostics and unknown URLs for a local-only profile', async e => {
  e.seedRun('run-log-diagnostics');
  await e.initialize();
  const message = 'dial fixture-node:443: timeout; test https://public.fixture.invalid/generate_204';
  const frame = new TextEncoder().encode(JSON.stringify({ type: 'error', payload: message })).buffer;
  e.emitCoreLog(frame);
  assert.equal(e.model.logs.length, 1);
  assert.equal(e.model.logs[0].level, 'error');
  assert.equal(e.model.logs[0].message, message);
  e.emitCoreLog('not valid JSON');
  assert.equal(e.model.logs.length, 1, 'Malformed core frames must not overwrite useful diagnostic output');
});

test('another VPN does not block cleanup after a start fails before creating HongFlow networking', async e => {
  e.setForeignVpnActive(true);
  e.network.vpnExtension.startVpnExtensionAbility = want => {
    e.events.starts.push(want);
    return Promise.reject(new Error('Fixture authorization service failure'));
  };
  e.network.vpnExtension.stopVpnExtensionAbility = async want => { e.events.stops.push(want); };
  await e.initialize();
  const starting = e.model.toggleConnection().then(() => undefined, error => error);
  await e.clock.advance(4000);
  assert.match((await starting).message, /Fixture authorization service failure/);
  assert.equal(e.store.readSnapshot().tunnelState, 'not-created');
  assert.equal(e.store.readRequest().cancelled, true);
  assert.equal(e.store.readRequest().stopping, false);
  assert.equal(e.model.canModifyProfiles, true);
  assert.equal(e.model.canChangeMode, true);
  assert.equal(e.cards.addForm('1007').action, 'start');
  assert.deepEqual(e.network.connection.getAllNetsSync(), [{ netId: 207 }]);
});

test('normal disconnect releases only the owned network while another VPN remains active', async e => {
  e.setForeignVpnActive(true);
  await e.initialize();
  const starting = e.model.toggleConnection();
  await e.clock.until(() => e.model.phase === 'connected' && !e.model.busy);
  await starting;
  assert.equal(e.store.readSnapshot().vpnNetId, 107);
  const stopping = e.model.toggleConnection();
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  await stopping;
  assert.equal(e.store.readRequest().stopping, false);
  assert.equal(e.model.canModifyProfiles, true);
  assert.deepEqual(e.network.connection.getAllNetsSync(), [{ netId: 207 }]);
  assert.equal(e.events.stops.length, 1);
  assert.equal(e.events.stops[0].abilityName, 'HongFlowVpnAbility');
});

test('persisted own network identity recovers after process death while another VPN is active', async e => {
  e.seedRun('process-death-owned-network', true, true, 'connected');
  e.store.writeSnapshot({ ...e.store.readSnapshot(), tunnelState: 'created', vpnNetId: 107 });
  e.setForeignVpnActive(true);
  e.network.vpnExtension.stopVpnExtensionAbility = async want => { e.events.stops.push(want); };
  await e.clock.advance(7000);
  await e.initialize();
  const stopping = e.model.toggleConnection();
  await e.clock.until(() => e.model.phase === 'idle' && !e.model.busy);
  await stopping;
  assert.equal(e.store.readRequest().stopping, false);
  assert.equal(e.model.canModifyProfiles, true);
  assert.equal(e.cards.addForm('1007').action, 'start');
  assert.deepEqual(e.network.connection.getAllNetsSync(), [{ netId: 207 }]);
});

test('successful SDK stop cannot clear an owned network that still exists', async e => {
  e.seedRun('owned-network-still-active');
  e.store.writeSnapshot({ ...e.store.readSnapshot(), tunnelState: 'created', vpnNetId: 107 });
  e.setForeignVpnActive(true);
  e.network.vpnExtension.stopVpnExtensionAbility = async want => { e.events.stops.push(want); };
  await e.initialize();
  const stopping = e.model.toggleConnection().then(() => undefined, error => error);
  await e.clock.advance(11000);
  assert.match((await stopping).message, /断开状态尚未确认/);
  assert.equal(e.store.readRequest().stopping, true);
  assert.equal(e.model.needsCleanup, true);
  assert.equal(e.model.canModifyProfiles, false);
  assert.equal(e.cards.addForm('1007').action, 'stop');
});

test('unknown or mismatched cleanup evidence cannot bypass an active system VPN', async e => {
  e.seedRun('unverified-release', true, true, 'idle');
  e.setForeignVpnActive(true);
  e.network.vpnExtension.stopVpnExtensionAbility = async want => { e.events.stops.push(want); };
  await e.initialize();
  for (const evidence of [
    {},
    { tunnelState: 'released' },
    { tunnelState: 'released', requestId: 'different-request', vpnNetId: 107 },
    { tunnelState: 'not-created', secret: 'different-secret' },
    { tunnelState: 'creating' }
  ]) {
    e.store.writeSnapshot({
      ...e.store.readSnapshot(), requestId: 'unverified-release',
      secret: 'fixture-secret-unverified-release', tunnelState: 'unknown', vpnNetId: -1, ...evidence
    });
    const stopping = e.model.toggleConnection().then(() => undefined, error => error);
    await e.clock.advance(11000);
    assert.match((await stopping).message, /系统 VPN 尚未释放/);
    assert.equal(e.store.readRequest().stopping, true);
    assert.equal(e.model.canModifyProfiles, false);
  }
});

module.exports = { environment, flush };

if (require.main === module) {
  process.on('unhandledRejection', error => unhandled.push(error));
  (async () => {
    let failed = 0;
    for (const item of tests) {
      const e = environment();
      try {
        await item.callback(e);
        console.log('PASS ' + item.name);
      } catch (error) {
        failed++;
        console.error('FAIL ' + item.name + '\n' + (error.stack || error));
      } finally {
        e.cleanup();
        await flush();
      }
    }
    // Let Node report any unhandled rejections from timed-out background work.
    await new Promise(resolve => setImmediate(resolve));
    if (unhandled.length) {
      failed++;
      console.error('FAIL unhandled asynchronous rejection: ' + unhandled.map(String).join('; '));
    }
    console.log(`${tests.length - failed}/${tests.length} host regressions passed (SDK TypeScript ${ts.version}).`);
    console.log('Boundary: real production command/storage/model modules; mocked Kits, VPN, Form IPC, native validation and core HTTP. No device, launcher, TUN, authorization dialog or external network tested.');
    process.exitCode = failed ? 1 : 0;
  })();
}
