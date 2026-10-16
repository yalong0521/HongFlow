import { common } from '@kit.AbilityKit';
import { workScheduler } from '@kit.BackgroundTasksKit';
import { fileIo } from '@kit.CoreFileKit';
import { util } from '@kit.ArkTS';
import {
  APP_BUNDLE_NAME,
  DEFAULT_SUBSCRIPTION_UPDATE_HOURS,
  SUBSCRIPTION_UPDATE_HOURS,
  ProfileInfo,
  SavedSettings
} from '../model/AppModels';
import { FileStore } from './FileStore';
import { MAX_PROFILE_BYTES, SubscriptionService } from './SubscriptionService';

export const SUBSCRIPTION_WORK_ID: number = 1001;

export const SUBSCRIPTION_ABILITY_NAME: string = 'HongFlowSubscriptionAbility';

const CHECK_BUDGET: number = 110000;

export interface SubscriptionUpdateStatus {
  checkedAt: number;
  error: string;
}

interface StoredUpdateStatus extends SubscriptionUpdateStatus {
  startedAt: number;
}

interface SubscriptionCursor {
  profileId: string;
  settingsRevision: string;
  startedAt: number;
}

class PendingSubscription {
  profileId: string = '';
  sourceUrl: string = '';
  sourceRevision: string = '';
  sourceUpdatedAt: number = 0;
  settingsRevision: string = '';
  startedAt: number = 0;
  fetchedAt: number = 0;
  nodeCount: number = 0;
  yaml: string = '';
}

interface PendingFile {
  path: string;
  update: PendingSubscription;
}

interface AppliedProfile {
  path: string;
  previousYaml: string;
}

/** 系统任务仅写候选；配置及列表只在 MainModel 确认断开后同步替换。 */
export class SubscriptionAutoUpdate {
  private store: FileStore;
  private directory: string;
  private subscription: SubscriptionService = new SubscriptionService();
  private generation: number = 0;
  private running?: Promise<void>;
  private scheduling?: Promise<void>;
  private cancelCheck?: () => void;

  constructor(context: common.Context) {
    this.store = new FileStore(context);
    this.directory = this.store.root + '/subscription-updates';
    if (!fileIo.accessSync(this.directory)) {
      try {
        fileIo.mkdirSync(this.directory, true);
      } catch (error) {
        if (!fileIo.accessSync(this.directory)) {
          throw error as Error;
        }
      }
    }
  }

  static ownsWork(work: workScheduler.WorkInfo): boolean {
    return work.workId === SUBSCRIPTION_WORK_ID && work.bundleName === APP_BUNDLE_NAME &&
      work.abilityName === SUBSCRIPTION_ABILITY_NAME;
  }

  async reconcileSchedule(): Promise<void> {
    const previous = this.scheduling ?? Promise.resolve();
    const scheduling = previous.catch(() => {
    }).then(() => this.updateSchedule());
    this.scheduling = scheduling;
    try {
      await scheduling;
    } finally {
      if (this.scheduling === scheduling) {
        this.scheduling = undefined;
      }
    }
  }

  private async updateSchedule(): Promise<void> {
    try {
      const works = await workScheduler.obtainAllWorks();
      // 查询系统期间用户可能改了周期；只能以查询完成后的持久设置注册任务。
      const settings = this.store.readSettings();
      const hours = this.intervalHours(settings);
      const existing = works.find((work: workScheduler.WorkInfo) => work.workId === SUBSCRIPTION_WORK_ID);
      if (existing !== undefined && !SubscriptionAutoUpdate.ownsWork(existing)) {
        throw new Error('自动更新任务标识冲突');
      }
      if (hours === 0 || !settings.autoUpdateRevision) {
        if (existing !== undefined) {
          workScheduler.stopWork(existing, true);
        }
        return;
      }
      if (existing !== undefined && existing.repeatCycleTime === hours * 60 * 60 * 1000 &&
        existing.networkType === workScheduler.NetworkType.NETWORK_TYPE_ANY && existing.isRepeat === true &&
        existing.isPersisted === true && existing.parameters?.revision === settings.autoUpdateRevision) {
        return;
      }
      if (existing !== undefined) {
        workScheduler.stopWork(existing, true);
      }
      const work: workScheduler.WorkInfo = {
        workId: SUBSCRIPTION_WORK_ID,
        bundleName: APP_BUNDLE_NAME,
        abilityName: SUBSCRIPTION_ABILITY_NAME,
        networkType: workScheduler.NetworkType.NETWORK_TYPE_ANY,
        isRepeat: true,
        isPersisted: true,
        repeatCycleTime: hours * 60 * 60 * 1000,
        parameters: { revision: settings.autoUpdateRevision }
      };
      workScheduler.startWork(work);
    } catch (error) {
      throw error as Error;
    }
  }

  checkDue(): Promise<void> {
    if (this.running !== undefined) {
      return this.running;
    }
    const generation = ++this.generation;
    const running = this.performCheck(generation).finally(() => {
      if (this.running === running) {
        this.running = undefined;
      }
    });
    this.running = running;
    return running;
  }

  cancel(): void {
    this.generation += 1;
    this.subscription.cancel();
    this.cancelCheck?.();
    // 设置变更后可立即重查；旧 Promise 的 finally 只释放它自己拥有的运行记录。
    this.running = undefined;
  }

  readStatus(): SubscriptionUpdateStatus {
    try {
      const status = JSON.parse(this.store.readText(this.directory + '/status.json')) as StoredUpdateStatus;
      return {
        checkedAt: typeof status.checkedAt === 'number' ? status.checkedAt : 0,
        error: typeof status.error === 'string' ? status.error : ''
      };
    } catch (_) {
      return { checkedAt: 0, error: '' };
    }
  }

  applyPending(profiles: ProfileInfo[]): ProfileInfo[] {
    const settings = this.store.readSettings();
    const pending = this.readPending();
    const updatedProfiles: ProfileInfo[] = [];
    const replaced: AppliedProfile[] = [];
    try {
      for (const profile of profiles) {
        const matches = pending.filter((file: PendingFile) => this.matches(file.update, profile, settings));
        matches.sort((left: PendingFile, right: PendingFile) =>
        right.update.startedAt - left.update.startedAt || right.update.fetchedAt - left.update.fetchedAt);
        const selected = matches[0]?.update;
        if (selected === undefined) {
          updatedProfiles.push(profile);
          continue;
        }
        const path = this.store.profilePath(profile.id);
        const previousYaml = this.store.readText(path);
        this.store.writeText(path, selected.yaml);
        replaced.push({ path: path, previousYaml: previousYaml });
        const updated = new ProfileInfo();
        updated.id = profile.id;
        updated.name = profile.name;
        updated.url = profile.url;
        updated.updatedAt = selected.fetchedAt;
        updated.nodeCount = selected.nodeCount;
        updated.revision = util.generateRandomUUID();
        updatedProfiles.push(updated);
      }
      if (replaced.length > 0) {
        this.store.writeProfiles(updatedProfiles);
      }
    } catch (error) {
      // 列表落盘失败时恢复刚替换的 YAML，候选仍保留，下一次断开检查可重试。
      for (const replacement of replaced) {
        try {
          this.store.writeText(replacement.path, replacement.previousYaml);
        } catch (_) {
          // 磁盘故障不能被当作成功；原始错误继续上报，候选不删除。
        }
      }
      throw error as Error;
    }
    // 只删除此次读取的独立文件；后台此刻发布的新候选不在这个列表中。
    for (const file of pending) {
      this.removePending(file.path);
    }
    return replaced.length > 0 ? updatedProfiles : profiles;
  }

  private async performCheck(generation: number): Promise<void> {
    const settings = this.store.readSettings();
    const hours = this.intervalHours(settings);
    if (hours === 0 || !settings.autoUpdateRevision) {
      return;
    }
    const startedAt = Date.now();
    let timer = -1;
    let cancelCheck: () => void = () => {
    };
    const cancellation = new Promise<void>((resolve) => {
      cancelCheck = resolve;
      this.cancelCheck = resolve;
    });
    const timeout = new Promise<void>((resolve) => {
      timer = setTimeout(() => {
        // HTTP 或内核校验可能迟迟不返回；先使所有后续结果失效，再主动结束本轮系统任务。
        if (this.isCurrent(generation, settings)) {
          try {
            this.writeStatus(startedAt, '本次自动检查超时，下次调度继续。');
          } catch (_) {
          }
        }
        if (this.generation === generation) {
          this.cancel();
        }
        resolve();
      }, CHECK_BUDGET);
    });
    try {
      await Promise.race([this.checkProfiles(generation, settings, hours, startedAt), timeout, cancellation]);
    } finally {
      clearTimeout(timer);
      if (this.cancelCheck === cancelCheck) {
        this.cancelCheck = undefined;
      }
    }
  }

  private async checkProfiles(generation: number, settings: SavedSettings, hours: number,
    startedAt: number): Promise<void> {
    const runId = util.generateRandomUUID();
    let failed = false;
    try {
      const profiles = this.store.readProfiles();
      const pending = this.readPending();
      const cursor = this.readCursor();
      const previousIndex = cursor?.settingsRevision === settings.autoUpdateRevision ?
        profiles.findIndex((profile: ProfileInfo) => profile.id === cursor.profileId) : -1;
      const ordered = [...profiles.slice(previousIndex + 1), ...profiles.slice(0, previousIndex + 1)];
      for (const profile of ordered) {
        if (!this.isCurrent(generation, settings)) {
          break;
        }
        if (!profile.url) {
          continue;
        }
        const lastFetched = pending.filter((file: PendingFile) => this.matches(file.update, profile, settings))
          .reduce((last: number, file: PendingFile) => Math.max(last, file.update.fetchedAt), profile.updatedAt || 0);
        if (Date.now() - lastFetched < hours * 60 * 60 * 1000) {
          continue;
        }
        try {
          // 在真正开始请求前保存进度；耗尽系统预算或进程被杀后，下轮先检查尚未尝试的订阅。
          // 本地配置及未到期项不移动游标，连续失败的前几项不能永久挤占后续订阅的预算。
          if (!this.moveCursor(profile.id, settings, startedAt)) {
            break;
          }
          const yaml = await this.subscription.download(profile.url);
          if (!this.isCurrent(generation, settings)) {
            break;
          }
          const validation = await SubscriptionService.validate(yaml);
          if (!this.isCurrent(generation, settings)) {
            break;
          }
          const current = this.store.readProfiles().find((item: ProfileInfo) => item.id === profile.id);
          const update = new PendingSubscription();
          update.profileId = profile.id;
          update.sourceUrl = profile.url;
          update.sourceRevision = profile.revision || '';
          update.sourceUpdatedAt = profile.updatedAt;
          update.settingsRevision = settings.autoUpdateRevision;
          update.startedAt = startedAt;
          update.fetchedAt = Date.now();
          update.nodeCount = validation.proxies;
          update.yaml = yaml;
          if (current === undefined || !this.matches(update, current, this.store.readSettings())) {
            continue;
          }
          // 每次执行有独立候选名；晚到的旧任务不能覆盖新任务已下载的内容。
          this.store.profilePath(profile.id);
          this.store.writeText(this.directory + '/' + runId + '-' + profile.id + '.json', JSON.stringify(update));
          for (const previous of pending) {
            if (previous.update.profileId === profile.id && previous.update.startedAt < startedAt) {
              this.removePending(previous.path);
            }
          }
        } catch (_) {
          failed = true;
        }
      }
      if (this.isCurrent(generation, settings)) {
        this.writeStatus(startedAt, failed ? '部分订阅更新失败，已保留原配置。' : '');
      }
    } catch (_) {
      if (this.isCurrent(generation, settings)) {
        this.writeStatus(startedAt, '本次自动检查未完成，已保留原配置。');
      }
    }
  }

  private intervalHours(settings: SavedSettings): number {
    return SUBSCRIPTION_UPDATE_HOURS.includes(settings.autoUpdateHours) ?
      settings.autoUpdateHours : DEFAULT_SUBSCRIPTION_UPDATE_HOURS;
  }

  private readCursor(): SubscriptionCursor | undefined {
    try {
      const cursor = JSON.parse(this.store.readText(this.directory + '/cursor.json')) as SubscriptionCursor;
      return typeof cursor.profileId === 'string' && typeof cursor.settingsRevision === 'string' &&
        Number.isFinite(cursor.startedAt) ? cursor : undefined;
    } catch (_) {
      return undefined;
    }
  }

  private moveCursor(profileId: string, settings: SavedSettings, startedAt: number): boolean {
    const currentSettings = this.store.readSettings();
    if (this.intervalHours(currentSettings) === 0 ||
      currentSettings.autoUpdateRevision !== settings.autoUpdateRevision) {
      return false;
    }
    const previous = this.readCursor();
    if (previous?.settingsRevision === settings.autoUpdateRevision && previous.startedAt > startedAt) {
      return false;
    }
    const cursor: SubscriptionCursor = {
      profileId: profileId, settingsRevision: settings.autoUpdateRevision, startedAt: startedAt
    };
    this.store.writeText(this.directory + '/cursor.json', JSON.stringify(cursor));
    return true;
  }

  private isCurrent(generation: number, settings: SavedSettings): boolean {
    if (this.generation !== generation) {
      return false;
    }
    try {
      const current = this.store.readSettings();
      return this.intervalHours(current) > 0 && current.autoUpdateRevision === settings.autoUpdateRevision;
    } catch (_) {
      return false;
    }
  }

  private matches(update: PendingSubscription, profile: ProfileInfo, settings: SavedSettings): boolean {
    if (this.intervalHours(settings) === 0 || !settings.autoUpdateRevision ||
      update.settingsRevision !== settings.autoUpdateRevision || update.profileId !== profile.id ||
      update.sourceUrl !== profile.url || !profile.url) {
      return false;
    }
    return profile.revision ? update.sourceRevision === profile.revision :
      !update.sourceRevision && update.sourceUpdatedAt === profile.updatedAt;
  }

  private readPending(): PendingFile[] {
    const pending: PendingFile[] = [];
    let names: string[];
    try {
      names = fileIo.listFileSync(this.directory);
    } catch (error) {
      throw error as Error;
    }
    for (const name of names) {
      if (!/^[0-9a-f-]+\.json$/i.test(name)) {
        continue;
      }
      const path = this.directory + '/' + name;
      try {
        if (fileIo.statSync(path).size > MAX_PROFILE_BYTES * 2) {
          continue;
        }
        const update = JSON.parse(this.store.readText(path)) as PendingSubscription;
        if (typeof update.profileId !== 'string' || typeof update.sourceUrl !== 'string' ||
          typeof update.settingsRevision !== 'string' || typeof update.yaml !== 'string' ||
          !Number.isFinite(update.startedAt) || !Number.isFinite(update.fetchedAt) ||
          !Number.isInteger(update.nodeCount) || update.nodeCount < 0 || update.startedAt <= 0 ||
          update.fetchedAt < update.startedAt || update.yaml.length === 0 ||
          util.TextEncoder.create().encodeInto(update.yaml).byteLength > MAX_PROFILE_BYTES) {
          continue;
        }
        pending.push({ path: path, update: update });
      } catch (_) {
        // 独立候选损坏不影响其他订阅，更不能替换现有可用配置。
      }
    }
    return pending;
  }

  private removePending(path: string): void {
    try {
      fileIo.unlinkSync(path);
    } catch (_) {
      // 已消费或已失效的候选可在下次检查再清理。
    }
  }

  private writeStatus(startedAt: number, error: string): void {
    const path = this.directory + '/status.json';
    try {
      const current = JSON.parse(this.store.readText(path)) as StoredUpdateStatus;
      if (current.startedAt > startedAt) {
        return;
      }
    } catch (_) {
    }
    const status: StoredUpdateStatus = { startedAt: startedAt, checkedAt: Date.now(), error: error };
    // 后台错误只存固定文案，HTTP/解析错误可能带订阅地址或节点凭据。
    this.store.writeText(path, JSON.stringify(status));
  }
}
