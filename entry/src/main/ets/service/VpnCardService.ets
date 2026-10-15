import { common, Want } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { fileIo } from '@kit.CoreFileKit';
import { formBindingData, formInfo, formProvider } from '@kit.FormKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { APP_BUNDLE_NAME, VPN_START_TIMEOUT } from '../model/AppModels';
import { CardCommand } from './CardCommandInbox';
import { FileStore } from './FileStore';

export interface VpnCardData {
  phase: string;
  statusLabel: string;
  action: string;
  actionLabel: string;
  formId: string;
  cardToken: string;
  requestId: string;
}

interface CardWantParameters {
  cardAction?: string;
  cardId?: string;
  cardToken?: string;
  cardRequestId?: string;
}

const FORM_NAME: string = 'HongFlowQuick';
const HEARTBEAT_TIMEOUT: number = 6000;

/** Card data contains public display fields and a separate control token, never core secrets. */
export class VpnCardService {
  private store: FileStore;
  private lastSignature: string = '';
  private failedSignature: string = '';
  private retryAt: number = 0;
  private updating: boolean = false;
  private dirty: boolean = false;
  private forcePending: boolean = false;

  constructor(context: common.Context) {
    this.store = new FileStore(context);
  }

  static openManager(): void {
    try {
      formProvider.openFormManager({
        bundleName: APP_BUNDLE_NAME,
        abilityName: 'HongFlowFormAbility',
        parameters: {
          'ohos.extra.param.key.form_dimension': formInfo.FormDimension.Dimension_1_2,
          'ohos.extra.param.key.form_name': FORM_NAME,
          'ohos.extra.param.key.module_name': 'entry'
        }
      });
    } catch (error) {
      throw error as Error;
    }
  }

  addForm(formId: string): VpnCardData {
    if (!this.validFormId(formId)) {
      throw new Error('桌面卡片标识无效');
    }
    return this.data(formId, this.token(formId, true));
  }

  removeForm(formId: string): void {
    if (!this.validFormId(formId)) {
      return;
    }
    const path = this.tokenPath(formId);
    try {
      if (fileIo.accessSync(path)) {
        fileIo.unlinkSync(path);
      }
    } catch (error) {
      hilog.warn(0x0000, 'HongFlow', '移除桌面卡片令牌失败: %{public}s', String(error));
    }
  }

  async updateForm(formId: string): Promise<void> {
    try {
      const data = this.addForm(formId);
      await formProvider.updateForm(formId, formBindingData.createFormBindingData(data));
    } catch (error) {
      throw error as Error;
    }
  }

  authenticatedCommand(want: Want): CardCommand | undefined {
    // Both FormLink router and call carry a JSON-encoded params object.
    const encoded = want.parameters?.params;
    if (typeof encoded !== 'string' || encoded.length > 2048) {
      return undefined;
    }
    let params: CardWantParameters;
    try {
      params = JSON.parse(encoded) as CardWantParameters;
      if (params === null) {
        return undefined;
      }
    } catch (_) {
      return undefined;
    }
    const action = params.cardAction;
    const formId = params.cardId;
    const token = params.cardToken;
    const requestId = params.cardRequestId;
    if ((action !== 'start' && action !== 'stop') || typeof formId !== 'string' ||
      !this.validFormId(formId) || typeof token !== 'string' || token.length === 0 ||
      typeof requestId !== 'string' || token !== this.token(formId, false)) {
      return undefined;
    }
    return { action: action, requestId: requestId };
  }

  refresh(force: boolean = false): void {
    this.dirty = true;
    this.forcePending = this.forcePending || force;
    if (this.updating) {
      return;
    }
    this.updating = true;
    this.publish().catch((error: Error) => {
      // Card service availability must never interrupt VPN setup or teardown.
      hilog.warn(0x0000, 'HongFlow', '桌面卡片刷新失败: %{public}s', String(error));
    }).finally(() => {
      this.updating = false;
      if (this.dirty) {
        this.refresh();
      }
    });
  }

  private async publish(): Promise<void> {
    while (this.dirty) {
      this.dirty = false;
      const force = this.forcePending;
      this.forcePending = false;
      const state = this.data('', '');
      // Heartbeats refresh private state each second; only display changes need IPC.
      const signature = JSON.stringify([state.phase, state.action, state.requestId]);
      if (!force && signature === this.lastSignature) {
        continue;
      }
      // A temporary Form service failure must recover without a new VPN phase.
      // Rate-limit retries, while a new phase or an explicit refresh retries now.
      if (!force && signature === this.failedSignature && Date.now() < this.retryAt) {
        continue;
      }
      const forms = await formProvider.getPublishedRunningFormInfos().catch((error: Error) => {
        this.failedSignature = signature;
        this.retryAt = Date.now() + 30000;
        throw error;
      });
      this.failedSignature = '';
      this.retryAt = 0;
      let failed = false;
      for (const form of forms) {
        if (form.bundleName !== APP_BUNDLE_NAME || form.moduleName !== 'entry' ||
          form.abilityName !== 'HongFlowFormAbility' || form.formName !== FORM_NAME) {
          continue;
        }
        const token = this.token(form.formId, false);
        if (token.length === 0) {
          continue;
        }
        try {
          // Re-read inside the serialized publisher so queued heartbeats cannot
          // publish a connected state captured before a later stop.
          await formProvider.updateForm(form.formId,
            formBindingData.createFormBindingData(this.data(form.formId, token)));
        } catch (error) {
          failed = true;
          hilog.warn(0x0000, 'HongFlow', '更新桌面卡片失败: %{public}s', String(error));
        }
      }
      if (!failed) {
        this.lastSignature = signature;
      } else {
        this.lastSignature = '';
        this.failedSignature = signature;
        this.retryAt = Date.now() + 30000;
      }
    }
  }

  private data(formId: string, token: string): VpnCardData {
    const request = this.store.readRequest();
    const snapshot = this.store.readSnapshot();
    const profiles = this.store.readProfiles();
    const settings = this.store.readSettings();
    const now = Date.now();
    const matching = request !== undefined && request.id === snapshot.requestId &&
      request.profileId === snapshot.profileId && request.secret === snapshot.secret;
    const activeSnapshot = snapshot.phase === 'connected' || snapshot.phase === 'starting';
    let phase = 'idle';
    if (request?.stopping === true) {
      phase = snapshot.phase === 'error' || (snapshot.updatedAt > 0 &&
        now - snapshot.updatedAt > HEARTBEAT_TIMEOUT) ? 'error' : 'stopping';
    } else if (activeSnapshot && (!matching || request?.cancelled === true ||
      snapshot.updatedAt <= 0 || now - snapshot.updatedAt > HEARTBEAT_TIMEOUT)) {
      phase = 'error';
    } else if (snapshot.phase === 'connected' && matching && !request?.cancelled) {
      phase = 'connected';
    } else if (request !== undefined && !request.cancelled) {
      phase = now - request.createdAt < VPN_START_TIMEOUT ? 'starting' : 'error';
    } else if (snapshot.phase === 'error') {
      phase = 'error';
    }
    const needsStop = phase === 'connected' || phase === 'starting' || phase === 'stopping' ||
      request?.stopping === true || activeSnapshot || (request !== undefined && !request.cancelled);
    const profileId = needsStop && request !== undefined ? request.profileId : settings.selectedProfileId;
    const profile = profiles.find((item) => item.id === profileId) ?? profiles[0];
    const action = needsStop ? 'stop' : profile === undefined ? 'none' : 'start';
    const status = phase === 'connected' ? '已连接' : phase === 'starting' ? '正在连接' :
      phase === 'stopping' ? '正在断开' : phase === 'error' ? '连接异常' :
        profile === undefined ? '请先导入配置' : '未连接';
    const actionLabel = phase === 'connected' ? '断开 VPN' : phase === 'starting' ? '取消连接' :
      needsStop ? '清理连接' : profile === undefined ? '请先在应用中导入配置' : '连接 VPN';
    return {
      phase: phase,
      statusLabel: status,
      action: action,
      actionLabel: actionLabel,
      formId: formId,
      cardToken: token,
      requestId: request?.id || ''
    };
  }

  private validFormId(formId: string): boolean {
    return /^-?\d{1,20}$/.test(formId);
  }

  private tokenPath(formId: string): string {
    return this.store.root + '/card-' + formId + '.token';
  }

  private token(formId: string, create: boolean): string {
    if (!this.validFormId(formId)) {
      return '';
    }
    const path = this.tokenPath(formId);
    try {
      if (fileIo.accessSync(path)) {
        return this.store.readText(path);
      }
      if (!create) {
        return '';
      }
      const token = util.generateRandomUUID() + util.generateRandomUUID();
      this.store.writeText(path, token);
      return token;
    } catch (error) {
      throw error as Error;
    }
  }
}
