import { common } from '@kit.AbilityKit';
import { MainModel } from '../model/MainModel';

/** 窗口和卡片后台调用共用一个控制模型，由 UIAbility 统一持有生命周期。 */
class AppSession {
  readonly model: MainModel = new MainModel();
  private initialization: Promise<void> | undefined;
  private generation: number = 0;

  initialize(context: common.UIAbilityContext): Promise<void> {
    if (this.initialization !== undefined) {
      return this.initialization;
    }
    const generation = ++this.generation;
    this.initialization = this.model.initialize(context).catch((error: Error) => {
      if (generation === this.generation) {
        // 初始化失败不能留下轮询或半初始化的命令处理器；下次卡片调用可以重试。
        this.model.dispose();
        this.initialization = undefined;
      }
      throw error;
    });
    return this.initialization;
  }

  ready(): Promise<void> {
    return this.initialization ?? Promise.reject(new Error('应用尚未初始化'));
  }

  dispose(): void {
    this.generation += 1;
    this.initialization = undefined;
    this.model.dispose();
  }
}

export const appSession: AppSession = new AppSession();
