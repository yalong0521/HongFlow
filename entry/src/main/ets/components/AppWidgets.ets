import { UIContext } from '@kit.ArkUI';
import { MainModel } from '../model/MainModel';
import { ProfileInfo } from '../model/AppModels';
import { LayoutTokens, ThemeTokens } from './DesignTokens';

export function formatBytes(bytes: number): string {
  if (bytes < 1024) {
    return `${Math.max(0, bytes).toFixed(0)} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  if (bytes < 1024 * 1024 * 1024) {
    return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
  }
  return `${(bytes / (1024 * 1024 * 1024)).toFixed(2)} GB`;
}

export function formatDate(timestamp: number): string {
  return timestamp > 0 ? new Date(timestamp).toLocaleString() : '尚未更新';
}

export function showError(context: UIContext, error: Error): void {
  if (context.isAvailable()) {
    try {
      context.getPromptAction().showToast({ message: error?.message || '操作失败，请重试' });
    } catch (_) {
      // An async result can arrive after its window has closed.
    }
  }
}

export function connectionActionLabel(model: MainModel): string {
  switch (model.phase) {
    case 'starting':
      return '取消连接';
    case 'connected':
      return '断开';
    case 'stopping':
      return '正在断开…';
    default:
      return model.needsCleanup ? '清理连接' : model.profiles.length === 0 ? '添加配置' : '连接 VPN';
  }
}

export function runConnectionAction(model: MainModel, context: UIContext, openProfiles: () => void): void {
  const active = model.phase === 'starting' || model.phase === 'connected' || model.phase === 'stopping';
  // Recovery remains available even if the stored configuration is unavailable.
  if (!active && !model.needsCleanup && model.profiles.length === 0) {
    openProfiles();
    return;
  }
  model.toggleConnection().catch((error: Error) => showError(context, error));
}

/** 原生标题栏承接光感控件，正文由 Navigation 在标题下方独立布局。 */
@ComponentV2
export struct NativePageScaffold {
  @BuilderParam titleBuilder: () => void;
  @BuilderParam contentBuilder: () => void;
  // 首次布局先保留一行高度，使标题能参与测量，随后完全使用内容的实测高度。
  @Local private titleHeight: number = LayoutTokens.rowMinHeight;
  @Local private titleMeasured: boolean = false;

  @Builder
  private TitleContent() {
    Column() {
      this.titleBuilder()
    }
    .width('100%')
    .height(LayoutPolicy.fixAtIdealSize)
    .alignItems(HorizontalAlign.Center)
    .onSizeChange((_oldSize: SizeOptions, size: SizeOptions) => {
      const height = Number(size.height);
      if (Number.isFinite(height) && height > 0) {
        if (height !== this.titleHeight) {
          this.titleHeight = height;
        }
        // 先确定自然高度，再创建正文，避免正文首帧按临时标题高度确定滚动空间。
        this.titleMeasured = true;
      }
    })
  }

  @Builder
  private Title() {
    IntrinsicPageTitle({
      builder: () => {
        this.TitleContent();
      }
    })
  }

  build() {
    Navigation() {
      if (this.titleMeasured) {
        this.contentBuilder()
      }
    }
    .title({
      builder: () => {
        this.Title();
      }, height: this.titleHeight
    }, {
      barStyle: BarStyle.STANDARD,
      backgroundColor: ThemeTokens.background,
    })
    .hideBackButton(true)
    .hideToolBar(true)
    .mode(NavigationMode.Stack)
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Transparent)
  }
}

/** 解除原生标题当前高度对子内容的约束，以真实宽度测量其自然高度。 */
@ComponentV2
struct IntrinsicPageTitle {
  @BuilderParam builder: () => void;

  onMeasureSize(_selfLayoutInfo: GeometryInfo, children: Array<Measurable>,
    constraint: ConstraintSizeOptions): SizeResult {
    // builder 始终只有一个 Column；高度不依赖上一帧标题高度，避免截断或循环放大。
    return children[0].measure({
      minWidth: constraint.maxWidth,
      maxWidth: constraint.maxWidth,
      minHeight: 0,
      maxHeight: Infinity,
    });
  }

  onPlaceChildren(_selfLayoutInfo: GeometryInfo, children: Array<Layoutable>,
    _constraint: ConstraintSizeOptions): void {
    children[0].layout({ x: 0, y: 0 });
  }

  build() {
    this.builder()
  }
}

/** 页面标题共用字号和间距，内容区域继续使用各页的原生滚动容器。 */
@ComponentV2
export struct PageHeading {
  @Require @Param title: string;
  @Param detail: string = '';

  build() {
    Column({ space: 6 }) {
      Text(this.title)
        .fontSize(LayoutTokens.headingSize)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeTokens.textPrimary)
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(LayoutTokens.headingDetailSize)
          .fontColor(ThemeTokens.textSecondary)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}

/** 主操作保留真实起停阶段，清理与取消入口始终与连接生命周期一致。 */
@ComponentV2
export struct ConnectionControl {
  @Require @Param model: MainModel;
  @Event onOpenProfiles: () => void = () => {
  };

  private title(): string {
    if (this.model.needsCleanup) {
      return '连接待清理';
    }
    switch (this.model.phase) {
      case 'starting':
        return '正在连接';
      case 'connected':
        return '已连接';
      case 'stopping':
        return '正在断开';
      case 'error':
        return '连接失败';
      default:
        return '未连接';
    }
  }

  private detail(): string {
    if (this.model.message.length > 0 && this.model.phase !== 'connected') {
      return this.model.message;
    }
    if (this.model.phase === 'starting') {
      return '正在建立系统 VPN 连接';
    }
    if (this.model.phase === 'stopping') {
      return '正在释放系统 VPN 连接';
    }
    return this.model.profiles.find((item: ProfileInfo) => item.id === this.model.selectedProfileId)?.name ??
      '添加订阅或导入本地 YAML 配置，开始连接';
  }

  build() {
    Column({ space: 24 }) {
      Row({ space: 16 }) {
        if (this.model.phase === 'starting' || this.model.phase === 'stopping') {
          LoadingProgress().width(24).height(24)
        } else {
          SymbolGlyph($r('sys.symbol.ohos_lock'))
            .fontSize(28)
            .fontColor([this.model.phase === 'connected' ? ThemeTokens.success : ThemeTokens.accent])
            .accessibilityLevel('no')
        }
        Column({ space: 4 }) {
          Text(this.title())
            .fontSize(28)
            .fontWeight(FontWeight.Medium)
            .fontColor(ThemeTokens.textPrimary)
          Text(this.detail())
            .fontSize(14)
            .fontColor(ThemeTokens.textSecondary)
            .maxLines(3)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
      }
      .width('100%')

      Button(connectionActionLabel(this.model), { type: ButtonType.Capsule })
        .width('100%')
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .constraintSize({ minHeight: 48 })
        .padding({ left: 18, right: 18 })
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .backgroundColor(ThemeTokens.actionBackground)
        .fontColor(ThemeTokens.actionForeground)
        .enabled(this.model.phase !== 'stopping' && (!this.model.busy ||
          this.model.phase === 'starting' || this.model.phase === 'connected'))
        .onClick(() => runConnectionAction(this.model, this.getUIContext(), this.onOpenProfiles))
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(LayoutTokens.cardPadding)
    .backgroundColor(ThemeTokens.surface)
    .borderRadius(LayoutTokens.surfaceRadius)
  }
}

@ComponentV2
export struct EmptyState {
  @Param title: string = '';
  @Param detail: string = '';

  build() {
    Column({ space: 12 }) {
      Text(this.title)
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeTokens.textPrimary)
      Text(this.detail)
        .fontSize(14)
        .fontColor(ThemeTokens.textSecondary)
        .constraintSize({ maxWidth: 420 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(LayoutTokens.cardPadding)
  }
}

@ComponentV2
export struct InlineNotice {
  @Param title: string = '';
  @Param detail: string = '';

  build() {
    Column({ space: 6 }) {
      if (this.title.length > 0) {
        Text(this.title)
          .fontSize(15)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeTokens.textPrimary)
      }
      Text(this.detail)
        .fontSize(14)
        .fontColor(ThemeTokens.textSecondary)
        .width('100%')
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(LayoutTokens.cardPadding)
    .borderRadius(LayoutTokens.surfaceRadius)
    .backgroundColor(ThemeTokens.surface)
  }
}
