import { common } from '@kit.AbilityKit';
import { http, vpnExtension, webSocket } from '@kit.NetworkKit';
import { fileIo, picker } from '@kit.CoreFileKit';
import { BusinessError, deviceInfo } from '@kit.BasicServicesKit';
import { util } from '@kit.ArkTS';
import native from 'libhongflowbridge.so';
import {
  LogLine,
  OperationKind,
  APP_BUNDLE_NAME,
  ProfileInfo,
  ProxyGroup,
  ProxyNode,
  SavedSettings,
  isSelectableGroup,
  VPN_START_TIMEOUT,
  ValidationResult,
  VpnRequest,
  VpnSnapshot
} from './AppModels';
import { CoreApi } from '../service/CoreApi';
import { FileStore } from '../service/FileStore';
import { isVpnRequestReleased } from '../service/VpnNetworkState';
import { CardCommand, CardCommandInbox } from '../service/CardCommandInbox';
import { VpnCardService } from '../service/VpnCardService';

interface CoreProxy {
  type: string;
  now?: string;
  all?: string[];
  hidden?: boolean;
}

interface ProxiesResponse {
  proxies: Record<string, CoreProxy>;
}

interface ConnectionsResponse {
  uploadTotal: number;
  downloadTotal: number;
}

interface ConfigsResponse {
  mode: string;
}

interface DelayResponse {
  delay: number;
}

interface CoreLog {
  type: string;
  payload: string;
}

interface NodeSelection {
  name: string;
}

const MAX_PROFILE_BYTES: number = 5 * 1024 * 1024;
const HEARTBEAT_TIMEOUT: number = 6000;
const TEST_URL: string = 'https://www.gstatic.com/generate_204';

function sdkError(error: Error | undefined | null): Error {
  // The VPN NAPI can reject without an error value on a system query failure.
  return error ?? new Error('系统接口调用失败，未返回错误详情');
}

function errorText(error: Error | undefined | null): string {
  const failure = sdkError(error);
  return failure.message?.length > 0 ? failure.message : String(failure);
}

@ObservedV2
export class MainModel {
  @Trace phase: string = 'idle';
  @Trace message: string = '';
  @Trace profiles: ProfileInfo[] = [];
  @Trace selectedProfileId: string = '';
  @Trace groups: ProxyGroup[] = [];
  @Trace mode: string = 'rule';
  @Trace uploadSpeed: number = 0;
  @Trace downloadSpeed: number = 0;
  @Trace uploadTotal: number = 0;
  @Trace downloadTotal: number = 0;
  @Trace connectedSince: number = 0;
  @Trace logs: LogLine[] = [];
  @Trace busy: boolean = false;
  @Trace operationKind: OperationKind = 'none';
  @Trace operationTarget: string = '';
  @Trace cleanupRequired: boolean = false;
  private context?: common.UIAbilityContext;
  private store?: FileStore;
  private settings: SavedSettings = new SavedSettings();
  private generation: number = 0;
  private disposed: boolean = true;
  private operationId: number = 0;
  private pollTimer: number = -1;
  private polling: boolean = false;
  private pendingRequestId: string = '';
  private deniedRequestId: string = '';
  private failedStartRequestId: string = '';
  private systemStop: Promise<void> | undefined;
  private api?: CoreApi;
  private apiRequestId: string = '';
  private preparedRequestId: string = '';
  private logSocket?: webSocket.WebSocket;
  private observer?: vpnExtension.VpnObserver;
  private lastTotalsAt: number = 0;
  private lastGroupsAt: number = 0;
  private groupsLoadId: number = 0;
  private cards?: VpnCardService;
  private cardCommandHandler = (command: CardCommand): void => {
    const generation = this.generation;
    const task = this.applyCardCommand(command);
    const operationId = this.operationId;
    task.catch((error: Error) => {
      // A later disconnect can interrupt a card start while authorization is pending.
      if (this.alive(generation) && this.operationId === operationId) {
        this.message = errorText(error);
      }
    });
  };

  get canModifyProfiles(): boolean {
    return !this.busy && !this.cleanupRequired && this.phase !== 'connected' &&
      this.phase !== 'starting' && this.phase !== 'stopping';
  }

  get needsCleanup(): boolean {
    // Active sessions also require eventual cleanup; only an inactive phase
    // with an unreleased tunnel should be presented as a recovery state.
    return this.cleanupRequired && this.phase !== 'connected' &&
      this.phase !== 'starting' && this.phase !== 'stopping';
  }

  get canChangeMode(): boolean {
    return !this.busy && !this.needsCleanup && this.phase !== 'starting' && this.phase !== 'stopping';
  }

  async initialize(context: common.UIAbilityContext): Promise<void> {
    this.dispose();
    this.disposed = false;
    this.context = context;
    this.store = new FileStore(context);
    this.cards = new VpnCardService(context);
    const generation = this.generation;
    this.profiles = this.requireStore().readProfiles();
    this.settings = this.requireStore().readSettings();
    this.selectedProfileId = this.profiles.some((profile: ProfileInfo) =>
    profile.id === this.settings.selectedProfileId) ? this.settings.selectedProfileId :
      (this.profiles.length > 0 ? this.profiles[0].id : '');
    this.mode = this.validMode(this.settings.mode) ? this.settings.mode : 'rule';
    this.saveSettings();
    // API 26 adds authorization-result observation; older systems are tracked
    // through the extension's request identity and startup timeout instead.
    if (deviceInfo.apiAvailable('26.0.0')) {
      this.observer = vpnExtension.createVpnObserver();
      this.observer.onAuthorizationResult((allowed: boolean) => {
        if (this.alive(generation) && !allowed && this.pendingRequestId.length > 0) {
          this.deniedRequestId = this.pendingRequestId;
        }
      });
    }
    this.pollTimer = setInterval(() => {
      const operationId = this.operationId;
      this.pollState(generation).catch((error: Error) => {
        if (this.alive(generation) && this.operationId === operationId) {
          this.message = errorText(error);
        }
      });
    }, 1000);
    const operationId = this.operationId;
    try {
      await this.pollState(generation);
    } catch (error) {
      if (this.alive(generation) && this.operationId === operationId) {
        // 初次观测可能遇到正在断开的会话或暂时不可达的内核，仍需保留后续轮询和断开入口。
        this.phase = 'error';
        this.message = errorText(error as Error);
      }
    }
    if (this.alive(generation)) {
      this.cards?.refresh(true);
      CardCommandInbox.attach(this.cardCommandHandler);
    }
  }

  dispose(): void {
    CardCommandInbox.detach(this.cardCommandHandler);
    this.disposed = true;
    this.generation += 1;
    this.operationId += 1;
    if (this.pollTimer !== -1) {
      clearInterval(this.pollTimer);
      this.pollTimer = -1;
    }
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (this.observer !== undefined) {
        this.observer.offAuthorizationResult();
        this.observer = undefined;
      }
    }
    this.clearCoreSession();
    this.pendingRequestId = '';
    this.polling = false;
    this.busy = false;
    this.operationKind = 'none';
    this.operationTarget = '';
    this.cards = undefined;
    // The Ability owns this shared controller. Disposing it only ends observation;
    // a VPN already running in its extension process keeps its own lifecycle.
  }

  async toggleConnection(): Promise<void> {
    const request = this.requireStore().readRequest();
    const snapshot = this.requireStore().readSnapshot();
    const shouldStop = this.phase === 'connected' || this.phase === 'starting' ||
      snapshot.phase === 'connected' || snapshot.phase === 'starting' ||
      request?.stopping === true || this.systemStop !== undefined ||
      (request !== undefined && !request.cancelled && this.phase === 'error');
    const profileId = shouldStop ? request?.profileId || snapshot.profileId : this.selectedProfileId;
    await this.operation(shouldStop ? 'disconnect' : 'connect', profileId, async (generation: number) => {
      if (shouldStop) {
        await this.stopConnection(generation);
      } else {
        await this.startConnection(generation);
      }
    }, shouldStop && this.phase !== 'stopping');
  }

  private async applyCardCommand(command: CardCommand): Promise<void> {
    const store = this.requireStore();
    const request = store.readRequest();
    const snapshot = store.readSnapshot();
    const active = snapshot.phase === 'connected' || snapshot.phase === 'starting' ||
      request?.stopping === true || (request !== undefined && !request.cancelled);
    if (command.action === 'stop') {
      // A delayed click on an old card must not disconnect a different new VPN.
      if (command.requestId !== (request?.id || '')) {
        this.cards?.refresh(true);
        throw new Error('卡片连接状态已变化，请检查当前连接');
      }
      if (!active || this.phase === 'stopping') {
        return;
      }
      await this.operation('disconnect', request?.profileId || snapshot.profileId,
        (generation: number) => this.stopConnection(generation), true);
    } else if (command.action === 'start') {
      if (!request?.cancelled && (this.phase === 'connected' || this.phase === 'starting')) {
        return;
      }
      if (command.requestId !== (request?.id || '')) {
        this.cards?.refresh(true);
        throw new Error('卡片连接状态已变化，请重新点击卡片');
      }
      if (active) {
        throw new Error('请先清理未断开的连接');
      }
      await this.operation('connect', this.selectedProfileId,
        (generation: number) => this.startConnection(generation));
    }
  }

  async importSubscription(name: string, url: string): Promise<void> {
    await this.operation('importSubscription', '', async (generation: number) => {
      this.requireDisconnected();
      const checkedUrl = this.subscriptionUrl(url);
      const yaml = await this.download(checkedUrl);
      this.ensureAlive(generation);
      await this.saveProfile(name.trim(), checkedUrl, yaml, generation);
    });
  }

  async importLocalFile(): Promise<void> {
    await this.operation('importLocalFile', '', async (generation: number) => {
      this.requireDisconnected();
      const context = this.context;
      if (context === undefined) {
        throw new Error('页面尚未初始化');
      }
      const documentPicker = new picker.DocumentViewPicker(context);
      const options: picker.DocumentSelectOptions = {
        maxSelectNumber: 1,
        fileSuffixFilters: ['YAML 配置|.yaml,.yml']
      };
      const files = await documentPicker.select(options);
      this.ensureAlive(generation);
      if (files.length === 0) {
        return;
      }
      const file = fileIo.openSync(files[0], fileIo.OpenMode.READ_ONLY);
      let yaml: string = '';
      try {
        const size = fileIo.statSync(file.fd).size;
        if (size <= 0 || size > MAX_PROFILE_BYTES) {
          throw new Error('配置文件需为非空文件，且不超过 5 MB');
        }
        const bytes = new Uint8Array(size);
        const buffer = new ArrayBuffer(Math.min(size, 64 * 1024));
        let offset = 0;
        // 文档提供方可能分段返回数据；必须读满原文件，不能把合法的 YAML 前半段当作完整配置。
        while (offset < size) {
          const read = fileIo.readSync(file.fd, buffer, { length: Math.min(buffer.byteLength, size - offset) });
          if (read <= 0) {
            throw new Error('配置文件读取不完整，请重新选择文件');
          }
          bytes.set(new Uint8Array(buffer, 0, read), offset);
          offset += read;
        }
        yaml = util.TextDecoder.create('utf-8', { fatal: true })
          .decodeToString(bytes);
      } finally {
        fileIo.closeSync(file);
      }
      let fileName = files[0].substring(files[0].lastIndexOf('/') + 1);
      try {
        fileName = decodeURIComponent(fileName);
      } catch (_) {
        fileName = '本地配置';
      }
      await this.saveProfile(fileName, '', yaml, generation);
    });
  }

  async selectProfile(id: string): Promise<void> {
    await this.operation('selectProfile', id, async (_generation: number) => {
      this.requireDisconnected();
      this.requireProfile(id);
      this.selectedProfileId = id;
      this.groups = [];
      this.saveSettings();
    });
  }

  async refreshProfile(id: string): Promise<void> {
    await this.operation('refreshProfile', id, async (generation: number) => {
      this.requireDisconnected();
      const profile = this.requireProfile(id);
      if (profile.url.length === 0) {
        throw new Error('本地配置请重新从文件导入');
      }
      const yaml = await this.download(this.subscriptionUrl(profile.url));
      this.ensureAlive(generation);
      const validation = await this.validate(yaml);
      this.ensureAlive(generation);
      this.requireDisconnected();
      const updated = new ProfileInfo();
      updated.id = profile.id;
      updated.name = profile.name;
      updated.url = profile.url;
      updated.nodeCount = validation.proxies;
      updated.updatedAt = Date.now();
      const profiles = this.profiles.map((item: ProfileInfo) => item.id === id ? updated : item);
      this.requireStore().writeText(this.requireStore().profilePath(id), yaml);
      this.requireStore().writeProfiles(profiles);
      this.profiles = profiles;
      this.message = '配置已更新';
    });
  }

  async removeProfile(id: string): Promise<void> {
    await this.operation('removeProfile', id, async (_generation: number) => {
      this.requireDisconnected();
      this.requireProfile(id);
      const store = this.requireStore();
      const profiles = this.profiles.filter((item: ProfileInfo) => item.id !== id);
      store.writeProfiles(profiles);
      this.profiles = profiles;
      const retainedSelections: Record<string, Record<string, string>> = {};
      for (const key of Object.keys(this.settings.selections)) {
        if (key !== id) {
          retainedSelections[key] = this.settings.selections[key];
        }
      }
      this.settings.selections = retainedSelections;
      if (this.selectedProfileId === id) {
        this.selectedProfileId = profiles.length > 0 ? profiles[0].id : '';
        this.groups = [];
      }
      this.saveSettings();
      const path = store.profilePath(id);
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    });
  }

  async selectNode(group: string, node: string): Promise<void> {
    await this.operation('selectNode', group, async (generation: number) => {
      const api = this.requireConnectedApi();
      const requestId = this.apiRequestId;
      const current = this.groups.find((item: ProxyGroup) => item.name === group);
      if (current === undefined || !isSelectableGroup(current.type) ||
        !current.nodes.some((item: ProxyNode) => item.name === node)) {
        throw new Error('节点已经变化，请刷新后重试');
      }
      const selection: NodeSelection = { name: node };
      await api.request('/proxies/' + encodeURIComponent(group), http.RequestMethod.PUT,
        JSON.stringify(selection));
      this.ensureSession(generation, requestId);
      const profileId = this.requireStore().readSnapshot().profileId;
      const selections = this.settings.selections[profileId] ?? {};
      const entries: string[] = [];
      for (const key of Object.keys(selections)) {
        if (key !== group) {
          entries.push(JSON.stringify(key) + ':' + JSON.stringify(selections[key]));
        }
      }
      entries.push(JSON.stringify(group) + ':' + JSON.stringify(node));
      // JSON 解析将任意代理组名保存为自有键，避免触发 __proto__ 的原型 setter。
      this.settings.selections[profileId] = JSON.parse('{' + entries.join(',') + '}') as Record<string, string>;
      this.saveSettings();
      await this.loadGroups(api, generation, requestId);
    });
  }

  async testGroup(group: string): Promise<void> {
    await this.operation('testGroup', group, async (generation: number) => {
      const api = this.requireConnectedApi();
      const requestId = this.apiRequestId;
      const current = this.groups.find((item: ProxyGroup) => item.name === group);
      if (current === undefined) {
        throw new Error('代理组不存在');
      }
      // Bound probe concurrency so a large subscription cannot exhaust sockets.
      for (let offset = 0; offset < current.nodes.length; offset += 6) {
        this.ensureSession(generation, requestId);
        const batch = current.nodes.slice(offset, offset + 6);
        await Promise.all(batch.map((node: ProxyNode) =>
        this.testNode(api, group, node.name, generation, requestId)));
      }
    });
  }

  async setMode(mode: string): Promise<void> {
    await this.operation('setMode', '', async (generation: number) => {
      if (!this.validMode(mode)) {
        throw new Error('代理模式无效');
      }
      if (this.phase === 'starting' || this.phase === 'stopping') {
        throw new Error('请等待 VPN 完成当前操作');
      }
      if (this.phase === 'connected') {
        const api = this.requireConnectedApi();
        const requestId = this.apiRequestId;
        await api.setMode(mode);
        this.ensureSession(generation, requestId);
      } else {
        this.requireDisconnected();
      }
      this.mode = mode;
      this.saveSettings();
    });
  }

  private async operation(kind: OperationKind, target: string,
    task: (generation: number) => Promise<void>, interrupt: boolean = false): Promise<void> {
    if (this.busy && !interrupt) {
      throw new Error('请等待当前操作完成');
    }
    const generation = this.generation;
    this.ensureAlive(generation);
    const operationId = ++this.operationId;
    this.busy = true;
    this.operationKind = kind;
    this.operationTarget = target;
    try {
      await task(generation);
    } catch (error) {
      if (this.alive(generation) && this.operationId === operationId) {
        this.message = errorText(error as Error);
      }
      throw error as Error;
    } finally {
      if (this.alive(generation) && this.operationId === operationId) {
        this.busy = false;
        // An interrupted task may settle later than its replacement. Only the
        // current owner can clear the operation shown by the UI.
        this.operationKind = 'none';
        this.operationTarget = '';
        this.cards?.refresh();
      }
    }
  }

  private async startConnection(generation: number): Promise<void> {
    this.requireDisconnected();
    const profile = this.requireProfile(this.selectedProfileId);
    const store = this.requireStore();
    const yaml = store.readText(store.profilePath(profile.id));
    await this.validate(yaml);
    this.ensureAlive(generation);
    this.requireDisconnected();
    const request = new VpnRequest();
    request.id = util.generateRandomUUID();
    request.profileId = profile.id;
    request.secret = util.generateRandomUUID() + util.generateRandomUUID();
    request.createdAt = Date.now();
    store.writeRequest(request);
    this.pendingRequestId = request.id;
    this.failedStartRequestId = '';
    this.deniedRequestId = '';
    this.phase = 'starting';
    this.message = '请允许系统 VPN 授权';
    this.cards?.refresh();
    const deadline = request.createdAt + VPN_START_TIMEOUT;
    try {
      const snapshot = new VpnSnapshot();
      snapshot.requestId = request.id;
      snapshot.profileId = request.profileId;
      snapshot.secret = request.secret;
      snapshot.tunnelState = 'not-created';
      // 授权前就保存无网卡状态；文件损坏/缺失仍是 unknown，不能被当作未创建。
      store.writeSnapshot(snapshot);
      let startFailure: Error | undefined;
      // Some systems leave this promise pending during authorization. Observe
      // it immediately, but use the extension's real snapshot as completion.
      vpnExtension.startVpnExtensionAbility({
        bundleName: APP_BUNDLE_NAME,
        abilityName: 'HongFlowVpnAbility',
        parameters: { requestId: request.id }
      }).catch((error: Error) => {
        startFailure = sdkError(error);
      });
      const completion = (async (): Promise<void> => {
        while (Date.now() < deadline) {
          this.ensureAlive(generation);
          const current = store.readRequest();
          if (current === undefined || current.id !== request.id || current.cancelled) {
            throw new Error('VPN 启动已取消');
          }
          if (this.deniedRequestId === request.id) {
            throw new Error('系统 VPN 授权被拒绝');
          }
          if (startFailure !== undefined) {
            throw startFailure;
          }
          await this.pollState(generation);
          this.ensureAlive(generation);
          if (Date.now() >= deadline) {
            break;
          }
          if (this.phase === 'connected' && this.preparedRequestId === request.id) {
            return;
          }
          const snapshot = store.readSnapshot();
          if (snapshot.requestId === request.id && snapshot.phase === 'error') {
            throw new Error(snapshot.message || 'VPN 启动失败');
          }
          await new Promise<void>((resolve) => setTimeout(resolve, 200));
        }
        throw new Error('VPN 启动超时，请检查系统授权后重试');
      })();
      await this.withTimeout(completion, Math.max(1, deadline - Date.now()),
        'VPN 启动超时，请检查系统授权后重试');
      this.ensureAlive(generation);
      const current = store.readRequest();
      if (current === undefined || current.id !== request.id || current.cancelled) {
        throw new Error('VPN 启动已取消');
      }
      if (this.pendingRequestId === request.id) {
        this.pendingRequestId = '';
      }
    } catch (error) {
      // A destroyed Ability must not cancel a VPN the user already requested.
      if (this.alive(generation) && this.pendingRequestId === request.id) {
        const current = store.readRequest();
        if (current !== undefined && current.id === request.id && !current.cancelled) {
          current.cancelled = true;
          current.stopping = true;
          store.writeRequest(current);
        }
        this.pendingRequestId = '';
        this.failedStartRequestId = request.id;
        this.clearCoreSession();
        this.phase = 'error';
        this.message = errorText(error as Error);
        if (current !== undefined && current.id === request.id) {
          try {
            await this.withTimeout(this.stopSystemVpn(), 2000, '清理未完成');
            if (isVpnRequestReleased(store.readRequest(), store.readSnapshot())) {
              this.setStopPending(store, request, false);
            }
          } catch (_) {
            // Cancellation is already durable. A late authorization will see
            // this canceled identity and cannot start its expired request.
          }
        }
      }
      throw error as Error;
    }
  }

  private async stopConnection(generation: number): Promise<void> {
    const store = this.requireStore();
    const request = store.readRequest();
    const previousSnapshot = store.readSnapshot();
    if (request !== undefined) {
      request.cancelled = true;
      request.stopping = true;
      store.writeRequest(request);
    }
    this.pendingRequestId = '';
    this.phase = 'stopping';
    this.message = '正在断开';
    this.cards?.refresh();
    this.clearCoreSession();
    const deadline = Date.now() + 10000;
    let stopFailure: Error | undefined;
    let stopTask: Promise<void> | undefined;
    let stopDispatched: boolean = false;
    let stopCompleted: boolean = false;
    const dispatchStop = (): void => {
      if (stopDispatched) {
        return;
      }
      stopDispatched = true;
      try {
        stopTask = this.stopSystemVpn();
        stopTask.then(() => {
          stopCompleted = true;
        }).catch((error: Error) => {
          stopFailure = sdkError(error);
        });
      } catch (error) {
        stopFailure = sdkError(error as Error);
      }
    };
    while (Date.now() < deadline) {
      this.ensureAlive(generation);
      const snapshot = store.readSnapshot();
      const current = store.readRequest();
      if (current !== undefined && request !== undefined && current.id !== request.id) {
        throw new Error('VPN 连接请求已经变化');
      }
      if (snapshot.phase === 'idle') {
        // The extension clears stopping only after system release. Let that
        // cooperative stop finish before issuing a controller fallback.
        if (!stopDispatched && current?.stopping === true && Date.now() < deadline - 7000) {
          await new Promise<void>((resolve) => setTimeout(resolve, 200));
          continue;
        }
        if (stopDispatched || current?.stopping !== false || this.systemStop !== undefined) {
          dispatchStop();
        }
        try {
          if (stopTask !== undefined) {
            await this.withTimeout(stopTask, Math.max(1, deadline - Date.now()), '系统尚未确认断开');
          } else if (stopFailure !== undefined) {
            throw stopFailure;
          }
        } catch (error) {
          const failure = sdkError(error as Error);
          const code = (failure as BusinessError).code;
          const explicitlyAbsent = code === 16000001 || code === 16000011;
          if (!explicitlyAbsent || !isVpnRequestReleased(store.readRequest(), store.readSnapshot())) {
            this.setStopPending(store, request, true);
            this.phase = 'error';
            throw failure;
          }
        }
        // Some system versions resolve the SDK call even when native release
        // reports an error. An idle snapshot cannot override an existing owned network.
        if (!isVpnRequestReleased(store.readRequest(), store.readSnapshot())) {
          this.setStopPending(store, request, true);
          this.phase = 'error';
          throw new Error('系统 VPN 尚未释放，请重试');
        }
        this.setStopPending(store, request, false);
        this.ensureAlive(generation);
        this.phase = 'idle';
        this.cleanupRequired = false;
        this.message = '';
        this.connectedSince = 0;
        return;
      }
      // Let the extension acknowledge cooperative cleanup first. Falling back
      // to the SDK also handles a request still waiting on system authorization.
      if (!stopDispatched && Date.now() >= deadline - 7000) {
        dispatchStop();
      }
      const code = stopFailure === undefined ? 0 : (stopFailure as BusinessError).code;
      const explicitlyAbsent = code === 16000001 || code === 16000011;
      const stale = snapshot.updatedAt > 0 && Date.now() - snapshot.updatedAt > HEARTBEAT_TIMEOUT;
      const sameRun = snapshot.requestId === previousSnapshot.requestId &&
        (current === undefined || request === undefined || current.id === request.id);
      // An app upgrade or process death can leave a stale private snapshot.
      // 已记录身份时只确认自有网卡已消失；旧快照缺少身份时仍采用保守系统检查。
      if (stale && sameRun && (stopCompleted || explicitlyAbsent) &&
        isVpnRequestReleased(store.readRequest(), snapshot)) {
        const idle = new VpnSnapshot();
        idle.requestId = snapshot.requestId;
        idle.profileId = snapshot.profileId;
        store.writeSnapshot(idle);
        this.setStopPending(store, request, false);
        this.phase = 'idle';
        this.cleanupRequired = false;
        this.message = '';
        this.connectedSince = 0;
        return;
      }
      if (stopFailure !== undefined) {
        this.phase = 'error';
        throw stopFailure;
      }
      await new Promise<void>((resolve) => setTimeout(resolve, 200));
    }
    this.ensureAlive(generation);
    this.phase = 'error';
    throw new Error('断开状态尚未确认，请重试');
  }

  private withTimeout(task: Promise<void>, milliseconds: number, message: string): Promise<void> {
    return new Promise<void>((resolve, reject) => {
      const timer = setTimeout(() => reject(new Error(message)), milliseconds);
      // Keep both handlers attached after a timeout so late SDK failures never
      // become unhandled rejections or write into another connection operation.
      task.then(() => {
        clearTimeout(timer);
        resolve();
      }).catch((error: Error) => {
        clearTimeout(timer);
        reject(error);
      });
    });
  }

  private stopSystemVpn(): Promise<void> {
    if (this.systemStop !== undefined) {
      return this.systemStop;
    }
    // SDK 停止操作不带 requestId。清理重试必须等待同一调用结束，防止旧停止晚到后关闭新连接。
    let task: Promise<void>;
    try {
      task = vpnExtension.stopVpnExtensionAbility({
        bundleName: APP_BUNDLE_NAME, abilityName: 'HongFlowVpnAbility'
      });
    } catch (error) {
      // SDK 也可能同步抛错，统一交回调用方的异步清理错误处理。
      return Promise.reject(error as Error);
    }
    this.systemStop = task;
    task.then(() => {
      if (this.systemStop === task) {
        this.systemStop = undefined;
      }
    }, () => {
      if (this.systemStop === task) {
        this.systemStop = undefined;
      }
    });
    return task;
  }

  private setStopPending(store: FileStore, request: VpnRequest | undefined, pending: boolean): void {
    const current = store.readRequest();
    if (current !== undefined && request !== undefined && current.id === request.id) {
      current.stopping = pending;
      store.writeRequest(current);
    }
  }

  private async pollState(generation: number): Promise<void> {
    if (!this.alive(generation) || this.polling) {
      return;
    }
    this.polling = true;
    try {
      const store = this.requireStore();
      const snapshot = store.readSnapshot();
      const request = store.readRequest();
      this.cleanupRequired =
        request?.stopping === true || this.systemStop !== undefined || (request !== undefined && !request.cancelled) ||
          snapshot.phase === 'connected' || snapshot.phase === 'starting';
      if (request?.stopping === true || this.systemStop !== undefined) {
        if (request !== undefined && !request.stopping) {
          request.stopping = true;
          store.writeRequest(request);
        }
        this.clearCoreSession();
        if (this.phase !== 'stopping') {
          this.phase = 'error';
          this.message = '上次断开尚未确认，请清理连接';
        }
        return;
      }
      const belongsToRequest = request !== undefined && !request.cancelled &&
        request.id === snapshot.requestId && request.profileId === snapshot.profileId &&
        request.secret === snapshot.secret;
      const fresh = snapshot.updatedAt > 0 && Date.now() - snapshot.updatedAt <= HEARTBEAT_TIMEOUT;
      // The startup deadline belongs to the persisted request, so reopening the
      // UI cannot extend an authorization or native startup that is still pending.
      if (request !== undefined && !request.cancelled &&
        (snapshot.requestId !== request.id || snapshot.phase !== 'connected') &&
        Date.now() - request.createdAt >= VPN_START_TIMEOUT) {
        request.cancelled = true;
        request.stopping = true;
        store.writeRequest(request);
        this.pendingRequestId = '';
        this.failedStartRequestId = request.id;
        this.clearCoreSession();
        this.phase = 'error';
        this.message = 'VPN 启动超时，请检查系统授权后重试';
        this.stopSystemVpn().then(() => {
          if (isVpnRequestReleased(store.readRequest(), store.readSnapshot())) {
            this.setStopPending(store, request, false);
          }
        }).catch(() => {
        });
        return;
      }
      if (snapshot.phase === 'connected' && belongsToRequest && fresh) {
        if (this.apiRequestId !== snapshot.requestId) {
          this.clearCoreSession();
          this.api = new CoreApi(snapshot.secret);
          this.apiRequestId = snapshot.requestId;
        }
        const api = this.api;
        if (api === undefined) {
          return;
        }
        if (this.preparedRequestId !== snapshot.requestId) {
          await this.prepareCore(api, snapshot, generation);
          this.ensureSession(generation, snapshot.requestId);
          this.preparedRequestId = snapshot.requestId;
          this.openLogSocket(api, generation, snapshot.requestId);
        }
        this.ensureSession(generation, snapshot.requestId);
        this.phase = 'connected';
        this.message = '';
        this.connectedSince = snapshot.connectedSince;
        await this.loadTraffic(api, generation, snapshot.requestId);
        if (Date.now() - this.lastGroupsAt >= 5000) {
          await this.loadGroups(api, generation, snapshot.requestId);
        }
        if (this.logSocket === undefined) {
          this.openLogSocket(api, generation, snapshot.requestId);
        }
        return;
      }
      this.clearCoreSession();
      if (request !== undefined && !request.cancelled && (!belongsToRequest || snapshot.phase === 'idle')) {
        // 后台授权期间可能尚未创建扩展/状态文件。重建 Ability 后仍以持久请求阻止第二次启动或改配置。
        this.phase = 'starting';
        this.message = '正在等待系统 VPN 授权';
        this.connectedSince = 0;
        return;
      }
      if (this.pendingRequestId.length > 0 &&
        (snapshot.requestId !== this.pendingRequestId || snapshot.phase === 'idle')) {
        return;
      }
      if (this.phase === 'stopping' && snapshot.phase !== 'idle') {
        return;
      }
      this.connectedSince = 0;
      if (snapshot.phase === 'idle' && this.phase === 'error' && request?.cancelled &&
        request.id === this.failedStartRequestId) {
        return;
      }
      if (snapshot.phase === 'connected') {
        this.phase = 'error';
        this.message = 'VPN 状态已失效，请断开后重新连接';
      } else if (snapshot.phase === 'starting' && !belongsToRequest) {
        // An old extension callback must not turn a canceled operation back
        // into a visible startup after its timeout or an explicit user stop.
        this.phase = 'error';
        if (this.message.length === 0) {
          this.message = 'VPN 启动已取消，请断开后重试';
        }
      } else {
        this.phase = snapshot.phase;
        this.message = snapshot.message;
      }
    } finally {
      if (this.alive(generation)) {
        this.polling = false;
        this.cards?.refresh();
      }
    }
  }

  private async prepareCore(api: CoreApi, snapshot: VpnSnapshot, generation: number): Promise<void> {
    // The extension restores saved mode and selections before publishing its
    // connected snapshot. Read that live state when the shared model initializes.
    await this.loadGroups(api, generation, snapshot.requestId);
    const config = JSON.parse(await api.request('/configs')) as ConfigsResponse;
    this.ensureSession(generation, snapshot.requestId);
    if (this.validMode(config.mode)) {
      this.mode = config.mode;
    }
  }

  private async loadGroups(api: CoreApi, generation: number, requestId: string): Promise<void> {
    const loadId = ++this.groupsLoadId;
    const response = JSON.parse(await api.request('/proxies')) as ProxiesResponse;
    this.ensureSession(generation, requestId);
    // 定时刷新可能晚于切换节点后的刷新返回，旧响应不能覆盖已经确认的新选择。
    if (loadId !== this.groupsLoadId) {
      return;
    }
    const groups: ProxyGroup[] = [];
    for (const name of Object.keys(response.proxies)) {
      const data = response.proxies[name];
      if (data.all === undefined || data.hidden === true) {
        continue;
      }
      const group = new ProxyGroup();
      group.name = name;
      group.type = data.type;
      group.now = data.now === undefined ? '' : data.now;
      const previous = this.groups.find((item: ProxyGroup) => item.name === name);
      group.nodes = data.all.map((nodeName: string) => {
        const node = new ProxyNode();
        node.name = nodeName;
        const proxy = response.proxies[nodeName];
        node.type = proxy === undefined ? '' : proxy.type;
        const existing = previous?.nodes.find((item: ProxyNode) => item.name === nodeName);
        node.delay = existing === undefined ? 0 : existing.delay;
        return node;
      });
      groups.push(group);
    }
    this.groups = groups;
    this.lastGroupsAt = Date.now();
  }

  private async loadTraffic(api: CoreApi, generation: number, requestId: string): Promise<void> {
    const totals = JSON.parse(await api.request('/connections')) as ConnectionsResponse;
    this.ensureSession(generation, requestId);
    const now = Date.now();
    const elapsed = (now - this.lastTotalsAt) / 1000;
    if (this.lastTotalsAt !== 0 && elapsed > 0) {
      this.uploadSpeed = Math.max(0, totals.uploadTotal - this.uploadTotal) / elapsed;
      this.downloadSpeed = Math.max(0, totals.downloadTotal - this.downloadTotal) / elapsed;
    }
    this.uploadTotal = totals.uploadTotal;
    this.downloadTotal = totals.downloadTotal;
    this.lastTotalsAt = now;
  }

  private async testNode(api: CoreApi, group: string, node: string,
    generation: number, requestId: string): Promise<void> {
    let delay: number = -1;
    try {
      const path = '/proxies/' + encodeURIComponent(node) + '/delay?timeout=5000&url=' +
        encodeURIComponent(TEST_URL);
      const response = JSON.parse(await api.request(path)) as DelayResponse;
      delay = response.delay;
    } catch (_) {
      delay = -1;
    }
    this.ensureSession(generation, requestId);
    this.groups = this.groups.map((item: ProxyGroup) => {
      if (item.name !== group) {
        return item;
      }
      const updated = new ProxyGroup();
      updated.name = item.name;
      updated.type = item.type;
      updated.now = item.now;
      updated.nodes = item.nodes.map((old: ProxyNode) => {
        if (old.name !== node) {
          return old;
        }
        const result = new ProxyNode();
        result.name = old.name;
        result.type = old.type;
        result.delay = delay;
        return result;
      });
      return updated;
    });
  }

  private openLogSocket(api: CoreApi, generation: number, requestId: string): void {
    if (this.logSocket !== undefined || !this.alive(generation)) {
      return;
    }
    const socket = webSocket.createWebSocket();
    this.logSocket = socket;
    socket.on('message', (error, data: string | ArrayBuffer) => {
      if (!this.alive(generation) || this.apiRequestId !== requestId || this.logSocket !== socket ||
        error !== undefined) {
        return;
      }
      try {
        const text = typeof data === 'string' ? data :
          util.TextDecoder.create().decodeToString(new Uint8Array(data));
        const record = JSON.parse(text) as CoreLog;
        this.appendLog(record.type, record.payload);
      } catch (_) {
        // Ignore malformed frames without replacing genuine core log output.
      }
    });
    socket.on('close', () => {
      if (this.alive(generation) && this.logSocket === socket) {
        this.logSocket = undefined;
      }
    });
    socket.on('error', () => {
      if (this.alive(generation) && this.logSocket === socket) {
        this.closeLogSocket();
      }
    });
    const options: webSocket.WebSocketRequestOptions = {
      header: { 'Authorization': 'Bearer ' + api.secret }
    };
    socket.connect('ws://127.0.0.1:9090/logs?level=info', options).then((connected: boolean) => {
      if (this.alive(generation) && this.logSocket === socket && !connected) {
        this.closeLogSocket();
      }
    }).catch(() => {
      if (this.alive(generation) && this.logSocket === socket) {
        this.closeLogSocket();
      }
    });
  }

  private appendLog(level: string, message: string): void {
    let safeMessage = message;
    // 内核错误可能包含完整订阅地址。先替换较长地址，避免前缀相同的配置留下私有参数。
    const subscriptionUrls = this.profiles.map((profile: ProfileInfo) => profile.url)
      .filter((url: string) => url.length > 0)
      .sort((left: string, right: string) => right.length - left.length);
    for (const url of subscriptionUrls) {
      safeMessage = safeMessage.split(url).join('[订阅地址已隐藏]');
    }
    const line = new LogLine();
    line.time = Date.now();
    line.level = level;
    line.message = safeMessage;
    this.logs = [...this.logs.slice(-199), line];
  }

  private closeLogSocket(): void {
    const socket = this.logSocket;
    this.logSocket = undefined;
    if (socket === undefined) {
      return;
    }
    socket.off('message');
    socket.off('close');
    socket.off('error');
    socket.close().catch(() => {
    });
  }

  private clearCoreSession(): void {
    this.closeLogSocket();
    this.api = undefined;
    this.apiRequestId = '';
    this.preparedRequestId = '';
    this.lastTotalsAt = 0;
    this.lastGroupsAt = 0;
    this.uploadSpeed = 0;
    this.downloadSpeed = 0;
    this.uploadTotal = 0;
    this.downloadTotal = 0;
  }

  private async download(url: string): Promise<string> {
    const client = http.createHttp();
    try {
      const options: http.HttpRequestOptions = {
        method: http.RequestMethod.GET,
        usingCache: false,
        header: { 'User-Agent': 'ClashMeta HongFlow/0.1.0', 'Accept': 'text/yaml, text/plain, */*' },
        expectDataType: http.HttpDataType.ARRAY_BUFFER,
        connectTimeout: 10000,
        readTimeout: 20000,
        maxLimit: MAX_PROFILE_BYTES
      };
      const response = await client.request(url, options);
      if (response.responseCode < 200 || response.responseCode >= 300) {
        throw new Error('订阅下载失败 (' + response.responseCode + ')');
      }
      const bytes = response.result as ArrayBuffer;
      if (bytes.byteLength === 0 || bytes.byteLength > MAX_PROFILE_BYTES) {
        throw new Error('订阅内容为空或超过 5 MB');
      }
      return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(new Uint8Array(bytes));
    } catch (error) {
      throw error as Error;
    } finally {
      client.destroy();
    }
  }

  private async validate(yaml: string): Promise<ValidationResult> {
    if (yaml.length === 0 || util.TextEncoder.create().encodeInto(yaml).byteLength > MAX_PROFILE_BYTES) {
      throw new Error('配置内容为空或超过 5 MB');
    }
    const result = JSON.parse(await native.validateProfile(yaml)) as ValidationResult;
    if (!result.valid) {
      throw new Error(result.error || '配置校验失败，请使用兼容的 YAML 配置');
    }
    return result;
  }

  private async saveProfile(name: string, url: string, yaml: string, generation: number): Promise<void> {
    const result = await this.validate(yaml);
    this.ensureAlive(generation);
    this.requireDisconnected();
    const profile = new ProfileInfo();
    profile.id = util.generateRandomUUID();
    profile.name = name.length > 0 ? name : (url.length > 0 ? '订阅配置' : '本地配置');
    profile.url = url;
    profile.updatedAt = Date.now();
    profile.nodeCount = result.proxies;
    const profiles = [...this.profiles, profile];
    const store = this.requireStore();
    store.writeText(store.profilePath(profile.id), yaml);
    store.writeProfiles(profiles);
    this.profiles = profiles;
    if (this.selectedProfileId.length === 0) {
      this.selectedProfileId = profile.id;
    }
    this.saveSettings();
    this.message = '配置导入成功';
  }

  private subscriptionUrl(value: string): string {
    const url = value.trim();
    if (!/^https?:\/\/[^\s]+$/i.test(url)) {
      throw new Error('请输入 http 或 https 开头的订阅链接');
    }
    return url;
  }

  private requireProfile(id: string): ProfileInfo {
    const profile = this.profiles.find((item: ProfileInfo) => item.id === id);
    if (profile === undefined) {
      throw new Error('请先导入并选择一个配置');
    }
    return profile;
  }

  private requireDisconnected(): void {
    const store = this.requireStore();
    const snapshot = store.readSnapshot();
    const request = store.readRequest();
    const active = request !== undefined && !request.cancelled;
    const unclearedTunnel = snapshot.phase === 'connected' || snapshot.phase === 'starting';
    if (this.phase === 'connected' || this.phase === 'starting' || this.phase === 'stopping' ||
      request?.stopping === true || this.systemStop !== undefined || active || unclearedTunnel) {
      throw new Error('请先断开 VPN，再修改配置');
    }
  }

  private requireConnectedApi(): CoreApi {
    const api = this.api;
    if (this.phase !== 'connected' || api === undefined) {
      throw new Error('请先连接 VPN');
    }
    this.ensureSession(this.generation, this.apiRequestId);
    return api;
  }

  private ensureSession(generation: number, requestId: string): void {
    this.ensureAlive(generation);
    const store = this.requireStore();
    const snapshot = store.readSnapshot();
    const request = store.readRequest();
    if (requestId.length === 0 || this.apiRequestId !== requestId || request === undefined ||
      request.cancelled || request.id !== requestId || snapshot.requestId !== requestId ||
      request.secret !== snapshot.secret || this.api?.secret !== snapshot.secret ||
      snapshot.phase !== 'connected' || Date.now() - snapshot.updatedAt > HEARTBEAT_TIMEOUT) {
      throw new Error('VPN 连接已变化，请重试');
    }
  }

  private saveSettings(): void {
    this.settings.selectedProfileId = this.selectedProfileId;
    this.settings.mode = this.mode;
    this.requireStore().writeSettings(this.settings);
  }

  private validMode(mode: string): boolean {
    return mode === 'rule' || mode === 'global' || mode === 'direct';
  }

  private requireStore(): FileStore {
    const store = this.store;
    if (store === undefined || this.disposed) {
      throw new Error('页面尚未初始化');
    }
    return store;
  }

  private alive(generation: number): boolean {
    return !this.disposed && this.generation === generation;
  }

  private ensureAlive(generation: number): void {
    if (!this.alive(generation)) {
      throw new Error('页面已关闭');
    }
  }
}
