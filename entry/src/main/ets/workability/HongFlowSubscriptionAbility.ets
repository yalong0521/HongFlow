import { workScheduler, WorkSchedulerExtensionAbility } from '@kit.BackgroundTasksKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { SubscriptionAutoUpdate } from '../service/SubscriptionAutoUpdate';
import { FileStore } from '../service/FileStore';

export default class HongFlowSubscriptionAbility extends WorkSchedulerExtensionAbility {
  private updater?: SubscriptionAutoUpdate;
  private generation: number = 0;
  private revision: string = '';

  onWorkStart(work: workScheduler.WorkInfo): void {
    if (!this.isCurrentWork(work)) {
      return;
    }
    this.updater?.cancel();
    const generation = ++this.generation;
    this.revision = typeof work.parameters?.revision === 'string' ? work.parameters.revision : '';
    try {
      const updater = new SubscriptionAutoUpdate(this.context);
      this.updater = updater;
      updater.checkDue().catch(() => {
        hilog.warn(0x0000, 'HongFlowSubscription', '后台订阅检查未完成');
      }).finally(() => {
        if (this.generation === generation && this.updater === updater) {
          this.updater = undefined;
          if (!this.isCurrentWork(work)) {
            return;
          }
          try {
            workScheduler.stopWork(work, false);
          } catch (_) {
            hilog.warn(0x0000, 'HongFlowSubscription', '结束后台订阅检查失败');
          }
        }
      });
    } catch (_) {
      hilog.warn(0x0000, 'HongFlowSubscription', '创建后台订阅检查失败');
      if (!this.isCurrentWork(work)) {
        return;
      }
      try {
        workScheduler.stopWork(work, false);
      } catch (_) {
      }
    }
  }

  private isCurrentWork(work: workScheduler.WorkInfo): boolean {
    if (!SubscriptionAutoUpdate.ownsWork(work) || typeof work.parameters?.revision !== 'string' ||
      work.parameters.revision.length === 0) {
      return false;
    }
    try {
      const settings = new FileStore(this.context).readSettings();
      // 系统停止任务只按 workId 定位；旧周期的回调不能取消或停止同 ID 下的新注册任务。
      return settings.autoUpdateHours !== 0 && work.parameters.revision === settings.autoUpdateRevision;
    } catch (_) {
      return false;
    }
  }

  onWorkStop(work: workScheduler.WorkInfo): void {
    if (!SubscriptionAutoUpdate.ownsWork(work) ||
      (typeof work.parameters?.revision === 'string' && work.parameters.revision !== this.revision)) {
      return;
    }
    // 系统超时或取消后立刻销毁 HTTP；旧 Promise 完成时不能发布候选或停止新任务。
    this.generation += 1;
    this.updater?.cancel();
    this.updater = undefined;
  }
}
