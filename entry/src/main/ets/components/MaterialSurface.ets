import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { LayoutTokens, ThemeTokens } from './DesignTokens';

export const FLOATING_BAR_BOTTOM_MARGIN: number = LayoutTokens.floatingBarBottomMargin;

let cachedControlMaterial: uiMaterial.ImmersiveMaterial | undefined = undefined;

export function supportsImmersiveMaterial(): boolean {
  if (deviceInfo.apiAvailable('26.0.0')) {
    return uiMaterial.isImmersiveMaterialSupported();
  }
  return false;
}

export function nativeControlMaterial(): uiMaterial.Material | undefined {
  if (deviceInfo.apiAvailable('26.0.0')) {
    if (!uiMaterial.isImmersiveMaterialSupported()) {
      return undefined;
    }
    if (cachedControlMaterial === undefined) {
      // 复用稳定材质参数；设备档位和系统光感设置由原生材质自适应。
      cachedControlMaterial = new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.THIN,
        colorInvert: true,
        interactive: true,
        lightEffect: {},
      });
    }
    return cachedControlMaterial;
  }
  return undefined;
}

/** 标题内控件的原生阴影需要在标题边界内衰减，不能由正文遮住尾部。 */
export function nativeControlShadowSpace(): number {
  return nativeControlMaterial() === undefined ? 0 : LayoutTokens.pageCompact;
}

/** 仅挂在原生标题栏内的交互控件上，正文不通过修改器扩大材质生效范围。 */
export class NativeControlMaterial implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(attribute: CommonAttribute): void {
    if (deviceInfo.apiAvailable('26.0.0')) {
      attribute.systemMaterial(nativeControlMaterial());
    }
  }
}

export class NativeTabMaterial implements AttributeModifier<TabsAttribute> {
  private bottomBar: boolean;
  private bottomInset: number;

  constructor(bottomBar: boolean, bottomInset: number) {
    this.bottomBar = bottomBar;
    this.bottomInset = bottomInset;
  }

  applyNormalAttribute(attribute: TabsAttribute): void {
    if (deviceInfo.apiAvailable('26.0.0')) {
      // 浮动光感仅适用于横向 Tabs 的底部栏，宽屏纵向侧栏使用原生常规样式。
      if (this.bottomBar && supportsImmersiveMaterial()) {
        const material = nativeControlMaterial() as uiMaterial.ImmersiveMaterial | undefined;
        attribute.barBackgroundColor(Color.Transparent);
        attribute.barWidth(-1);
        attribute.barOverlap(true);
        attribute.barFloatingStyle({
          // 画布覆盖系统手势区，只有胶囊位置避让实测安全区，避免材质阴影被父边界裁切。
          barBottomMargin: FLOATING_BAR_BOTTOM_MARGIN + this.bottomInset,
          maskColor: ThemeTokens.background,
          systemMaterial: material,
        });
        return;
      }
      // 同一 Tabs 跨越宽度断点时清除旧浮动样式，侧栏不继承底栏的光感和遮罩。
      attribute.barFloatingStyle(undefined);
    }
    attribute.barWidth(this.bottomBar ? '100%' : LayoutTokens.railWidth);
    attribute.barOverlap(false);
    attribute.barBackgroundColor(ThemeTokens.surface);
  }
}
