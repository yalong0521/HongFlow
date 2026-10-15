import { http, VpnExtensionAbility, vpnExtension } from '@kit.NetworkKit';
import { Want } from '@kit.AbilityKit';
import { fileIo } from '@kit.CoreFileKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import core from 'libhongflowbridge.so';
import { FileStore } from '../service/FileStore';
import { CoreApi } from '../service/CoreApi';
import { findVpnNetworkId, isVpnRequestReleased } from '../service/VpnNetworkState';
import { VpnCardService } from '../service/VpnCardService';
import { APP_BUNDLE_NAME, isSelectableGroup, VPN_START_TIMEOUT, VpnRequest, VpnSnapshot } from '../model/AppModels';

const VPN_WANT: Want = { bundleName: APP_BUNDLE_NAME, abilityName: 'HongFlowVpnAbility' };

interface ProxyState {
  type: string;
  all?: string[];
}

interface ProxyStates {
  proxies: Record<string, ProxyState>;
}

export default class HongFlowVpnAbility extends VpnExtensionAbility {
  private store: FileStore | undefined;
  private cards: VpnCardService | undefined;
  private connection: vpnExtension.VpnConnection | undefined;
  private request: VpnRequest | undefined;
  private snapshot: VpnSnapshot = new VpnSnapshot();
  private tunFd: number = -1;
  private interfaceCreated: boolean = false;
  private creationAttempted: boolean = false;
  private interfaceReleased: boolean = false;
  private interfaceName: string = '';
  private heartbeat: number = -1;
  private destroyed: boolean = false;
  private failed: boolean = false;
  private cleaned: boolean = false;
  private work: Promise<void> = Promise.resolve();

  onCreate(want: Want): void {
    this.store = new FileStore(this.context);
    this.cards = new VpnCardService(this.context);
    this.work = this.start(want).catch(async (error: Error) => {
      this.failed = !this.isCancelled();
      this.snapshot.phase = this.failed ? 'error' : 'idle';
      this.snapshot.message = this.failed ? (error?.message || 'VPN 启动失败') : '';
      if (this.failed) {
        this.cancelOwnedRequest();
      }
      await this.cleanup();
      try {
        await this.releaseExtension();
      } catch (_) {
        // Cleanup already removed the interface even if the extension is being released.
      }
    });
  }

  onDestroy(): void {
    this.destroyed = true;
    // 系统设置也可以直接停止扩展；清理确认前，卡片必须看到请求已取消且仍待释放。
    this.cancelOwnedRequest();
    if (this.heartbeat !== -1) {
      clearInterval(this.heartbeat);
      this.heartbeat = -1;
    }
    // A stop can arrive while protect/create/native start is awaiting a result.
    // Serialize teardown after startup so a late native result cannot revive the VPN.
    this.work = this.work.then(async () => {
      if (!this.failed) {
        this.snapshot.phase = 'idle';
        this.snapshot.message = '';
      }
      await this.cleanup();
      // destroyed 为 true 时只确认释放，不再发出可能影响新实例的 stop。
      await this.releaseExtension();
    }).catch((error: Error) => {
      hilog.error(0x0000, 'HongFlow', '销毁 VPN 扩展失败: %{public}s', String(error));
    });
  }

  private cancelOwnedRequest(): void {
    try {
      if (this.request && this.store) {
        const current = this.store.readRequest();
        if (current && current.id === this.request.id) {
          current.cancelled = true;
          current.stopping = true;
          this.store.writeRequest(current);
        }
      }
    } catch (error) {
      // 启动失败和系统销毁都必须清理网卡/内核，持久化失败不能让清理 Promise 提前拒绝。
      hilog.error(0x0000, 'HongFlow', '保存 VPN 停止状态失败: %{public}s', String(error));
    }
  }

  private isCancelled(): boolean {
    if (this.destroyed || !this.request || !this.store) {
      return true;
    }
    const current = this.store.readRequest();
    return !current || current.id !== this.request.id || current.cancelled;
  }

  private assertActive(): void {
    if (this.isCancelled()) {
      throw new Error('连接请求已取消');
    }
    if (this.snapshot.phase !== 'connected' &&
      Date.now() - this.request!.createdAt >= VPN_START_TIMEOUT) {
      throw new Error('VPN 启动请求已过期');
    }
  }

  private writeStatus(required: boolean = false): void {
    if (!this.store || !this.request) {
      return;
    }
    try {
      const current = this.store.readRequest();
      if (current && current.id === this.request.id) {
        if (this.snapshot.tunnelState === 'created' && this.snapshot.vpnNetId < 0) {
          this.captureNetworkIdentity();
        }
        this.store.writeSnapshot(this.snapshot);
        this.cards?.refresh();
      } else if (required) {
        throw new Error('连接请求已变化');
      }
    } catch (error) {
      if (required) {
        throw error as Error;
      }
      // 心跳稍后可以重试，状态写入失败也不能阻断 cleanup 后的系统扩展释放。
      hilog.error(0x0000, 'HongFlow', '保存 VPN 状态失败: %{public}s', String(error));
    }
  }

  private captureNetworkIdentity(): void {
    if (this.tunFd < 0 || !this.interfaceCreated || this.snapshot.tunnelState !== 'created') {
      return;
    }
    if (this.interfaceName.length === 0) {
      try {
        this.interfaceName = core.tunInterfaceName(this.tunFd);
      } catch (_) {
        // 身份读取失败不阻断合法连接；没有身份时仍按未知连接保守清理。
        return;
      }
    }
    this.snapshot.vpnNetId = findVpnNetworkId(this.interfaceName);
  }

  private async start(want: Want): Promise<void> {
    const store = this.store!;
    const request = store.readRequest();
    const requestedId = want.parameters?.requestId as string | undefined;
    if (!request ||
      (requestedId !== undefined && requestedId !== request.id)) {
      throw new Error('连接请求无效或已过期');
    }
    this.request = request;
    this.snapshot.requestId = request.id;
    this.snapshot.profileId = request.profileId;
    this.snapshot.secret = request.secret;
    this.snapshot.tunnelState = 'not-created';
    this.assertActive();
    this.snapshot.phase = 'starting';
    this.snapshot.message = '正在建立 VPN';
    this.writeStatus();
    store.seedCoreResources();
    this.assertActive();

    const connection = vpnExtension.createVpnConnection(this.context);
    this.connection = connection;
    // The VPN extension runs in its own process. Its outbound sockets must use
    // the physical network rather than recursively entering the virtual interface.
    await connection.protectProcessNet();
    this.assertActive();
    const config: vpnExtension.VpnConfig = {
      addresses: [
        { address: { address: '198.18.0.1', family: 1 }, prefixLength: 30 },
        { address: { address: 'fdfe:dcba:9876::1', family: 2 }, prefixLength: 126 }
      ],
      routes: [
        {
          interface: '',
          destination: { address: { address: '0.0.0.0', family: 1 }, prefixLength: 0 },
          gateway: { address: '', family: 1 },
          hasGateway: false,
          isDefaultRoute: true
        },
        {
          interface: '',
          destination: { address: { address: '::', family: 2 }, prefixLength: 0 },
          gateway: { address: '', family: 2 },
          hasGateway: false,
          isDefaultRoute: true
        }
      ],
      dnsAddresses: ['198.18.0.2', 'fdfe:dcba:9876::2'],
      mtu: 1500,
      blockedApplications: [APP_BUNDLE_NAME]
    };
    try {
      // 必须先成功落盘再复查取消：控制器不能在 create 已开始后仍看到 not-created。
      this.snapshot.tunnelState = 'creating';
      this.writeStatus(true);
      this.assertActive();
      this.creationAttempted = true;
      this.tunFd = await connection.create(config);
      this.interfaceCreated = true;
      this.snapshot.tunnelState = 'created';
      this.writeStatus(true);
      this.assertActive();
      await core.start(store.profilePath(request.profileId), store.root + '/core', this.tunFd, request.secret);
    } catch (error) {
      throw error as Error;
    }
    this.assertActive();
    await this.restoreSelection();
    this.assertActive();
    // start() must apply the configuration and take ownership of a duplicated TUN
    // descriptor before any UI is allowed to show a connected state.
    this.snapshot.phase = 'connected';
    this.snapshot.message = '';
    this.snapshot.connectedSince = Date.now();
    this.writeStatus();
    this.heartbeat = setInterval(() => {
      if (this.isCancelled()) {
        clearInterval(this.heartbeat);
        this.heartbeat = -1;
        // Complete native and interface cleanup while this process still lives.
        // The system may release it immediately once stopVpnExtensionAbility runs.
        this.work = this.work.then(async () => {
          this.snapshot.phase = 'idle';
          this.snapshot.message = '';
          await this.cleanup();
          await this.releaseExtension();
        }).catch((error: Error) => {
          hilog.error(0x0000, 'HongFlow', '断开 VPN 失败: %{public}s', error.message);
        });
        return;
      }
      this.writeStatus();
    }, 1000);
  }

  private async restoreSelection(): Promise<void> {
    const settings = this.store!.readSettings();
    const api = new CoreApi(this.snapshot.secret);
    if (['rule', 'global', 'direct'].includes(settings.mode)) {
      await api.setMode(settings.mode);
    }
    this.assertActive();
    const saved = settings.selections[this.snapshot.profileId];
    if (!saved) {
      return;
    }
    const response = JSON.parse(await api.request('/proxies')) as ProxyStates;
    for (const group of Object.keys(saved)) {
      this.assertActive();
      const state = response.proxies[group];
      if (state !== undefined && isSelectableGroup(state.type) && state.all?.includes(saved[group])) {
        await api.request('/proxies/' + encodeURIComponent(group), http.RequestMethod.PUT,
          JSON.stringify({ name: saved[group] }));
      }
    }
  }

  private async releaseExtension(): Promise<void> {
    // A foreground fallback may already have delivered onDestroy. Do not send
    // another late stop that could release a newly created extension instance.
    if (!this.destroyed) {
      try {
        await vpnExtension.stopVpnExtensionAbility(VPN_WANT);
      } catch (error) {
        // Keep the durable stopping flag until the foreground can confirm or
        // retry system cleanup; an idle core alone is not that confirmation.
        hilog.error(0x0000, 'HongFlow', '释放 VPN 扩展失败: %{public}s', String(error));
        return;
      }
    }
    if (this.cleaned && this.request && this.store) {
      const current = this.store.readRequest();
      if (current && current.id === this.request.id && isVpnRequestReleased(current, this.snapshot)) {
        // 早先取消写入可能暂时失败；确认资源释放后再次终结请求，不能重新留下 starting。
        current.cancelled = true;
        current.stopping = false;
        this.store.writeRequest(current);
        this.cards?.refresh();
      }
    }
  }

  private async cleanup(): Promise<void> {
    if (this.cleaned) {
      return;
    }
    let failure: string = '';
    if (this.heartbeat !== -1) {
      clearInterval(this.heartbeat);
      this.heartbeat = -1;
    }
    try {
      await core.stop();
    } catch (error) {
      failure = '内核清理失败，请重试断开';
      hilog.error(0x0000, 'HongFlow', '内核停止失败: %{public}s', String(error));
    }
    if (this.tunFd >= 0) {
      try {
        fileIo.closeSync(this.tunFd);
      } catch (error) {
        failure = '网卡句柄清理失败，请重试断开';
        hilog.error(0x0000, 'HongFlow', '网卡句柄关闭失败: %{public}s', String(error));
      }
      this.tunFd = -1;
    }
    if (this.connection && this.interfaceCreated) {
      try {
        await this.connection.destroy();
        this.connection = undefined;
        this.interfaceCreated = false;
        this.interfaceReleased = true;
      } catch (error) {
        failure = '系统网卡清理失败，请重试断开';
        hilog.error(0x0000, 'HongFlow', '系统网卡销毁失败: %{public}s', String(error));
      }
    }
    this.cleaned = failure.length === 0;
    if (this.cleaned && (!this.creationAttempted || this.interfaceReleased)) {
      // 记录 native/fd/网卡清理调用均成功；系统网络是否消失仍由释放检查确认。
      // 从未尝试 create 才能确定没有网卡；尝试过但缺少网络身份时仍需系统确认。
      this.snapshot.tunnelState = this.creationAttempted ? 'released' : 'not-created';
    }
    if (!this.cleaned) {
      this.snapshot.phase = 'error';
      this.snapshot.message = failure;
      this.cancelOwnedRequest();
    }
    this.writeStatus();
  }
}
