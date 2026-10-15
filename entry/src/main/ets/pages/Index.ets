import { common } from '@kit.AbilityKit';
import { SymbolGlyphModifier, window } from '@kit.ArkUI';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { MainModel } from '../model/MainModel';
import { appSession } from '../service/AppSession';
import { NativeTabMaterial, supportsImmersiveMaterial } from '../components/MaterialSurface';
import { LayoutTokens, ThemeTokens } from '../components/DesignTokens';
import { showError } from '../components/AppWidgets';
import { DesktopStatus } from '../service/DesktopStatus';
import { ConnectionPage } from './ConnectionPage';
import { ProfilesPage } from './ProfilesPage';
import { MorePage } from './MorePage';

type AvoidAreaHandler = (options: window.AvoidAreaOptions) => void;

@Entry
@ComponentV2
struct Index {
  @Local private model: MainModel = appSession.model;
  @Local private windowWidth: number = 0;
  @Local private topInset: number = 0;
  @Local private bottomInset: number = 0;
  @Local private leftInset: number = 0;
  @Local private rightInset: number = 0;
  private tabsController: TabsController = new TabsController();
  private desktopStatus: DesktopStatus = new DesktopStatus();
  private generation: number = 0;
  private immersiveSupported: boolean = false;
  private avoidAreaWindow: window.Window | undefined = undefined;
  private avoidAreaHandler: AvoidAreaHandler | undefined = undefined;

  aboutToAppear(): void {
    this.immersiveSupported = supportsImmersiveMaterial();
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    const generation = ++this.generation;
    this.observeAvoidAreas(context, generation);
    appSession.ready().then(async () => {
      if (generation === this.generation) {
        await this.desktopStatus.attach(context, this.model);
      }
    }).catch((error: Error) => {
      if (generation === this.generation) {
        showError(this.getUIContext(), error);
      }
    });
  }

  aboutToDisappear(): void {
    this.generation += 1;
    this.releaseAvoidAreaListener();
    this.desktopStatus.dispose();
    // 卡片可以在没有窗口时执行操作，页面消失不能终止共享模型的连接流程。
  }

  @Monitor('model.phase', 'model.busy', 'model.cleanupRequired')
  onConnectionStateChanged(): void {
    this.desktopStatus.refresh();
  }

  private floatingBottomBar(): boolean {
    return this.windowWidth < LayoutTokens.wideMinWidth && this.immersiveSupported;
  }

  private footerSpace(): number {
    return this.floatingBottomBar() ?
      LayoutTokens.tabBarHeight + LayoutTokens.floatingBarBottomMargin + this.bottomInset : 0;
  }

  private pageWidth(): number {
    return this.windowWidth >= LayoutTokens.wideMinWidth ? this.windowWidth - LayoutTokens.railWidth : this.windowWidth;
  }

  private tabStyle(symbol: Resource, label: string): BottomTabBarStyle {
    return BottomTabBarStyle.of({
      normal: new SymbolGlyphModifier(symbol).fontColor([ThemeTokens.textPrimary]),
      selected: new SymbolGlyphModifier(symbol).fontColor([$r('sys.color.brand')]),
    }, label).labelStyle({
      selectedColor: $r('sys.color.brand'),
      unselectedColor: ThemeTokens.textPrimary,
    });
  }

  private observeAvoidAreas(context: common.UIAbilityContext, generation: number): void {
    this.releaseAvoidAreaListener();
    window.getLastWindow(context).then((appWindow: window.Window) => {
      if (generation !== this.generation) {
        return;
      }
      const handler = (options: window.AvoidAreaOptions): void => {
        if (generation !== this.generation || (options.type !== window.AvoidAreaType.TYPE_SYSTEM &&
          options.type !== window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR &&
          options.type !== window.AvoidAreaType.TYPE_CUTOUT)) {
          return;
        }
        this.updateAvoidInsets(appWindow);
      };
      this.avoidAreaWindow = appWindow;
      this.avoidAreaHandler = handler;
      appWindow.on('avoidAreaChange', handler);
      this.updateAvoidInsets(appWindow);
    }).catch((error: Error) => {
      if (generation === this.generation) {
        hilog.warn(0x0000, 'HongFlow', '窗口安全区监听失败: %{public}s', String(error));
      }
    });
  }

  private updateAvoidInsets(appWindow: window.Window): void {
    const context = this.getUIContext();
    if (!context.isAvailable()) {
      return;
    }
    try {
      // Non-immersive windows already avoid system areas at the window boundary.
      // In immersive windows, the outer background fills the screen. Floating
      // tabs keep this bottom canvas and apply the inset to their controls and
      // scroll tail; outer bottom padding would clip their material/shadow.
      if (!appWindow.getWindowProperties().isLayoutFullScreen) {
        this.topInset = 0;
        this.bottomInset = 0;
        this.leftInset = 0;
        this.rightInset = 0;
        return;
      }
      let top: number = 0;
      let bottom: number = 0;
      let left: number = 0;
      let right: number = 0;
      const types: window.AvoidAreaType[] = [window.AvoidAreaType.TYPE_SYSTEM,
        window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR, window.AvoidAreaType.TYPE_CUTOUT];
      for (const type of types) {
        try {
          const area = appWindow.getWindowAvoidArea(type);
          // System bars, the gesture indicator and a cutout can cover the same
          // edge. Reserve their maximum extent once rather than adding overlaps.
          top = Math.max(top, area.topRect.height);
          bottom = Math.max(bottom, area.bottomRect.height);
          left = Math.max(left, area.leftRect.width);
          right = Math.max(right, area.rightRect.width);
        } catch (_error) {
          // A device may not expose every area type; retain the supported ones.
        }
      }
      this.topInset = context.px2vp(top);
      this.bottomInset = context.px2vp(bottom);
      this.leftInset = context.px2vp(left);
      this.rightInset = context.px2vp(right);
    } catch (error) {
      hilog.warn(0x0000, 'HongFlow', '窗口安全区读取失败: %{public}s', String(error));
    }
  }

  private releaseAvoidAreaListener(): void {
    const appWindow = this.avoidAreaWindow;
    const handler = this.avoidAreaHandler;
    this.avoidAreaWindow = undefined;
    this.avoidAreaHandler = undefined;
    if (appWindow && handler) {
      try {
        appWindow.off('avoidAreaChange', handler);
      } catch (_error) {
        // The window may have been destroyed before the page disappears.
      }
    }
  }

  build() {
    Column() {
      Tabs({
        barPosition: this.windowWidth >= LayoutTokens.wideMinWidth ? BarPosition.Start : BarPosition.End,
        controller: this.tabsController
      }) {
        TabContent() {
          ConnectionPage({
            model: this.model,
            footerSpace: this.footerSpace(),
            onOpenProfiles: () => this.tabsController.changeIndex(1),
          })
        }
        .tabBar(this.tabStyle($r('sys.symbol.ohos_lock'), '连接'))

        TabContent() {
          ProfilesPage({
            model: this.model,
            footerSpace: this.footerSpace(),
            contentWidth: this.pageWidth(),
            onOpenConnection: () => this.tabsController.changeIndex(0),
          })
        }
        .tabBar(this.tabStyle($r('sys.symbol.folder'), '配置'))

        TabContent() {
          MorePage({ model: this.model, footerSpace: this.footerSpace(), contentWidth: this.pageWidth() })
        }
        .tabBar(this.tabStyle($r('sys.symbol.gearshape'), '设置'))
      }
      .vertical(this.windowWidth >= LayoutTokens.wideMinWidth)
      .barHeight(this.windowWidth >= LayoutTokens.wideMinWidth ? '100%' : LayoutTokens.tabBarHeight)
      .scrollable(false)
      .animationDuration(180)
      .attributeModifier(new NativeTabMaterial(this.windowWidth < LayoutTokens.wideMinWidth, this.bottomInset))
      .width('100%')
      .layoutWeight(1)
      .background(ThemeTokens.background)
      .onSizeChange((_oldSize: SizeOptions, newSize: SizeOptions) => {
        this.windowWidth = Number(newSize.width);
      })
    }
    .width('100%')
    .height('100%')
    .padding({
      top: this.topInset,
      bottom: this.floatingBottomBar() ? 0 : this.bottomInset,
      left: this.leftInset,
      right: this.rightInset,
    })
    .background(ThemeTokens.background)
  }
}
