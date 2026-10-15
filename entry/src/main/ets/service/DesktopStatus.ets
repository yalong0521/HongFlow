import { common } from '@kit.AbilityKit';
import { deviceInfo, emitter } from '@kit.BasicServicesKit';
import { statusBarManager } from '@kit.DesktopExtensionKit';
import { image } from '@kit.ImageKit';
import { MainModel } from '../model/MainModel';

const TOGGLE_MENU: string = 'hongflow.toggle';
const OPEN_MENU: string = 'hongflow.open';

interface DesktopIcons {
  white: image.PixelMap;
  black: image.PixelMap;
}

/** 电脑状态栏入口跟随 UIAbility 的存活周期，VPN 仍由独立扩展进程持有。 */
export class DesktopStatus {
  private context?: common.UIAbilityContext;
  private model?: MainModel;
  private white?: image.PixelMap;
  private black?: image.PixelMap;
  private attached: boolean = false;
  private static attachmentWork: Promise<void> = Promise.resolve();
  private generation: number = 0;
  private lastPhase: string = '';
  private lastBusy: boolean = false;
  private lastNeedsCleanup: boolean = false;
  private iconClick = (_event: emitter.EventData): void => {
    this.openEntryAbility();
  };
  private menuClick = (event: emitter.EventData): void => {
    const menuCode = event.data?.['menuCode'] as string;
    if (menuCode === OPEN_MENU) {
      this.openEntryAbility();
      return;
    }
    const model = this.model;
    // 系统菜单事件可能晚于状态更新，点击时重新检查操作状态。
    if (menuCode !== TOGGLE_MENU || model === undefined || model.phase === 'stopping' ||
      (model.busy && model.phase !== 'starting' && model.phase !== 'connected')) {
      return;
    }
    model.toggleConnection().catch(() => {
      // 模型按操作身份发布错误；旧连接被取消后的拒绝不能覆盖新断开的提示。
    });
  };

  async attach(context: common.UIAbilityContext, model: MainModel): Promise<void> {
    const generation = ++this.generation;
    // The platform has one icon per application. Share the queue across page
    // instances so an old window's rollback cannot remove a newer window's icon.
    const work = DesktopStatus.attachmentWork.catch(() => {
    }).then(async () => {
      if (generation === this.generation) {
        await this.attachOnce(context, model, generation);
      }
    });
    DesktopStatus.attachmentWork = work;
    await work;
  }

  private async attachOnce(context: common.UIAbilityContext, model: MainModel, generation: number): Promise<void> {
    if (canIUse('SystemCapability.PCService.StatusBarManager')) {
      if (this.attached || deviceInfo.deviceType !== '2in1') {
        return;
      }
      try {
        if (deviceInfo.apiAvailable('26.0.0')) {
          if (!(await statusBarManager.isStatusBarCapabilitySupported(context))) {
            return;
          }
        }
        if (generation !== this.generation) {
          return;
        }
        const icons = await this.createIcons();
        if (generation !== this.generation) {
          icons.white.release();
          icons.black.release();
          return;
        }
        this.context = context;
        this.model = model;
        this.white = icons.white;
        this.black = icons.black;
        const item: statusBarManager.StatusBarItem = {
          icons: icons,
          // 空 abilityName 使用公开的图标点击事件打开主窗口，无需额外扩展。
          quickOperation: { title: '鸿流', height: 1, abilityName: '' },
          statusBarGroupMenu: this.menuGroups(),
          hoverTips: this.tooltip(),
        };
        statusBarManager.on('statusBarIconClick', this.iconClick);
        statusBarManager.on('rightMenuClick', this.menuClick);
        await new Promise<void>((resolve, reject) => {
          statusBarManager.addToStatusBar(context, item, (error) => {
            if (error) {
              reject(error);
            } else {
              resolve();
            }
          });
        });
        if (generation !== this.generation) {
          statusBarManager.removeFromStatusBar(context);
          return;
        }
        this.attached = true;
        this.lastPhase = '';
        this.refresh();
      } catch (error) {
        if (generation === this.generation) {
          this.dispose();
        }
        throw error as Error;
      }
    }
  }

  refresh(): void {
    if (canIUse('SystemCapability.PCService.StatusBarManager')) {
      const context = this.context;
      const model = this.model;
      if (!this.attached || context === undefined || model === undefined ||
        (this.lastPhase === model.phase && this.lastBusy === model.busy &&
          this.lastNeedsCleanup === model.needsCleanup)) {
        return;
      }
      this.lastPhase = model.phase;
      this.lastBusy = model.busy;
      this.lastNeedsCleanup = model.needsCleanup;
      try {
        statusBarManager.updateStatusBarMenu(context, this.menuGroups());
        statusBarManager.updateStatusBarHoverTips(context, this.tooltip()).catch((error: Error) => {
          if (this.model === model) {
            model.message = error.message || '状态栏提示更新失败';
          }
        });
      } catch (error) {
        model.message = (error as Error).message || '状态栏菜单更新失败';
      }
    }
  }

  dispose(): void {
    this.generation += 1;
    if (canIUse('SystemCapability.PCService.StatusBarManager')) {
      if (this.context !== undefined && this.model !== undefined) {
        try {
          statusBarManager.off('statusBarIconClick', this.iconClick);
          statusBarManager.off('rightMenuClick', this.menuClick);
          if (this.attached) {
            statusBarManager.removeFromStatusBar(this.context);
          }
        } catch (_error) {
          // 最后窗口已关闭时系统可能拒绝移除，进程退出会回收系统入口。
        }
      }
    }
    this.attached = false;
    this.context = undefined;
    this.model = undefined;
    this.releaseIcons();
  }

  private openEntryAbility(): void {
    const context = this.context;
    const model = this.model;
    if (context === undefined) {
      return;
    }
    context.startAbility({
      bundleName: context.abilityInfo.bundleName,
      moduleName: 'entry',
      abilityName: 'EntryAbility',
    }).catch((error: Error) => {
      if (model !== undefined && this.model === model) {
        model.message = error.message || '无法打开鸿流';
      }
    });
  }

  private menuGroups(): statusBarManager.StatusBarGroupMenu[] {
    const phase = this.model?.phase || 'idle';
    const toggle: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility',
      moduleName: 'entry',
      notifyOnly: true,
      menuCode: TOGGLE_MENU,
    };
    const open: statusBarManager.StatusBarMenuAction = {
      abilityName: 'EntryAbility',
      moduleName: 'entry',
      notifyOnly: true,
      menuCode: OPEN_MENU,
    };
    return [[
      {
        title: this.model?.needsCleanup === true ? '清理连接' :
          phase === 'connected' ? '断开 VPN' : phase === 'starting' ? '取消连接' :
            phase === 'stopping' ? '正在断开…' : '连接 VPN', menuAction: toggle
      },
      { title: '打开鸿流', menuAction: open },
    ]];
  }

  private tooltip(): string {
    if (this.model?.needsCleanup === true) {
      return '鸿流 · 连接待清理';
    }
    switch (this.model?.phase) {
      case 'connected':
        return '鸿流 · 已连接';
      case 'starting':
        return '鸿流 · 正在连接';
      case 'stopping':
        return '鸿流 · 正在断开';
      case 'error':
        return '鸿流 · 连接失败';
      default:
        return '鸿流 · 未连接';
    }
  }

  private async createIcon(channel: number): Promise<image.PixelMap> {
    const size = 48;
    const pixels = new Uint8Array(size * size * 4);
    for (let y = 0; y < size; y += 1) {
      for (let x = 0; x < size; x += 1) {
        const body = x >= 11 && x <= 36 && y >= 22 && y <= 40;
        const arcDistance = Math.sqrt((x - 23.5) * (x - 23.5) + (y - 17) * (y - 17));
        const handle = y <= 22 && arcDistance >= 8 && arcDistance <= 12;
        const keyhole = x >= 22 && x <= 25 && y >= 28 && y <= 35;
        if ((body || handle) && !keyhole) {
          const offset = (y * size + x) * 4;
          pixels[offset] = channel;
          pixels[offset + 1] = channel;
          pixels[offset + 2] = channel;
          pixels[offset + 3] = 255;
        }
      }
    }
    return image.createPixelMap(pixels.buffer, {
      size: { width: size, height: size },
      pixelFormat: image.PixelMapFormat.RGBA_8888,
      alphaType: image.AlphaType.UNPREMUL,
      editable: false,
    });
  }

  private async createIcons(): Promise<DesktopIcons> {
    const white = await this.createIcon(255);
    try {
      const black = await this.createIcon(0);
      return { white: white, black: black };
    } catch (error) {
      white.release();
      throw error as Error;
    }
  }

  private releaseIcons(): void {
    this.white?.release();
    this.black?.release();
    this.white = undefined;
    this.black = undefined;
  }
}
