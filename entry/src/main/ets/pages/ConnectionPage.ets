import { CapsuleSegmentButtonV2, SegmentButtonV2Items } from '@kit.ArkUI';
import { MainModel } from '../model/MainModel';
import { ProfileInfo, ProxyNode } from '../model/AppModels';
import { LayoutTokens, ThemeTokens } from '../components/DesignTokens';
import {
  ConnectionControl,
  NativePageScaffold,
  PageHeading,
  formatBytes,
  showError
} from '../components/AppWidgets';
import { nativeControlMaterial, nativeControlShadowSpace } from '../components/MaterialSurface';
import { NodeBrowser, NodeBrowserControls, primaryGroup } from '../components/NodeBrowser';

// 两栏需要 280vp 操作区、320vp 节点区，以及间距和页面边距。
const OVERVIEW_SPLIT_WIDTH: number = 280 + 320 + LayoutTokens.sectionGap + LayoutTokens.pageRegular * 2;

@ComponentV2
export struct ConnectionPage {
  @Require @Param model: MainModel;
  @Param footerSpace: number = 0;
  @Event onOpenProfiles: () => void = () => {
  };
  @Local private availableWidth: number = 0;
  private inspectorScroller: Scroller = new Scroller();
  private nodeScroller: ListScroller = new ListScroller();
  // 搜索与代理组属于页面状态，折叠/展开搬移面板时不丢失。
  @Local private search: string = '';
  @Local private groupName: string = '';

  private wide(): boolean {
    // 没有配置时只展示导入引导，宽屏也不生成空白节点栏。
    return this.availableWidth >= OVERVIEW_SPLIT_WIDTH &&
      (this.model.profiles.length > 0 || this.model.groups.length > 0);
  }

  private inspectorWidth(): number {
    const contentWidth = Math.min(this.availableWidth, LayoutTokens.overviewMaxWidth) -
      LayoutTokens.pageRegular * 2 - LayoutTokens.sectionGap;
    return Math.max(280, Math.min(360, contentWidth * 0.42));
  }

  private showNodes(): void {
    // 折叠时连接卡片共占一个 ListItemGroup，节点标题紧接在其后。
    this.nodeScroller.scrollToIndex(this.wide() ? 0 : 1, true, ScrollAlign.START);
  }

  private titleShadowSpace(): number {
    return this.model.profiles.length > 0 || (this.wide() && this.model.groups.length > 0) ?
      nativeControlShadowSpace() : 0;
  }

  @Builder
  ConnectionItems() {
    ListItemGroup({ space: LayoutTokens.pageCompact }) {
      ListItem() {
        ConnectionControl({ model: this.model, onOpenProfiles: this.onOpenProfiles })
      }

      if (this.model.profiles.length > 0) {
        ListItem() {
          ConnectionOptions({
            model: this.model, onOpenProfiles: this.onOpenProfiles, onOpenNodes: () => this.showNodes(),
          })
        }
      }
      if (this.model.phase === 'connected') {
        ListItem() {
          TrafficPanel({ model: this.model })
        }
      }
    }
  }

  @Builder
  PageTitle() {
    Row({ space: LayoutTokens.sectionGap }) {
      Column({ space: LayoutTokens.pageCompact }) {
        PageHeading({
          title: '连接',
          detail: this.model.operationKind === 'setMode' ? '正在切换代理模式…' :
            this.model.profiles.length > 0 ? '鸿流 · 代理模式' : '鸿流',
        })
        if (this.model.profiles.length > 0) {
          ModeControl({ model: this.model })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width(this.wide() ? this.inspectorWidth() : '100%')

      if (this.wide() && this.model.groups.length > 0) {
        NodeBrowserControls({
          model: this.model,
          search: this.search,
          groupName: this.groupName,
          onSearch: (value: string) => this.search = value,
          onGroup: (value: string) => this.groupName = value,
        })
          .layoutWeight(1)
      }
    }
    .alignItems(VerticalAlign.Top)
    .width('100%')
    .constraintSize({ maxWidth: this.wide() ? LayoutTokens.overviewMaxWidth : LayoutTokens.listMaxWidth })
    .padding({
      left: this.wide() ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      right: this.wide() ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      top: LayoutTokens.pageRegular,
      bottom: LayoutTokens.pageCompact + this.titleShadowSpace(),
    })
  }

  @Builder
  PageContent() {
    Column() {
      if (this.wide()) {
        Row({ space: LayoutTokens.sectionGap }) {
          Scroll(this.inspectorScroller) {
            Column({ space: LayoutTokens.pageCompact }) {
              ConnectionControl({ model: this.model, onOpenProfiles: this.onOpenProfiles })
              if (this.model.profiles.length > 0) {
                ConnectionOptions({
                  model: this.model, onOpenProfiles: this.onOpenProfiles, onOpenNodes: () => this.showNodes(),
                })
              }
              if (this.model.phase === 'connected') {
                TrafficPanel({ model: this.model })
              }
            }
            .width('100%')
            .padding({ bottom: this.footerSpace })
          }
          .align(Alignment.Top)
          .width(this.inspectorWidth())
          .height('100%')

          NodeBrowser({
            model: this.model,
            scroller: this.nodeScroller,
            inOverview: true,
            controlsInTitle: true,
            footerSpace: this.footerSpace,
            search: this.search,
            groupName: this.groupName,
            onSearch: (value: string) => this.search = value,
            onGroup: (value: string) => this.groupName = value,
          })
            .layoutWeight(1)
        }
        .width('100%')
        .height('100%')
        .padding({
          top: LayoutTokens.pageCompact - this.titleShadowSpace(),
          left: LayoutTokens.pageRegular,
          right: LayoutTokens.pageRegular,
        })
        .constraintSize({ maxWidth: LayoutTokens.overviewMaxWidth })
      } else {
        NodeBrowser({
          model: this.model,
          scroller: this.nodeScroller,
          contentWidth: this.availableWidth,
          footerSpace: this.footerSpace,
          showHeading: true,
          contentStartSpace: LayoutTokens.pageCompact - this.titleShadowSpace(),
          search: this.search,
          groupName: this.groupName,
          onSearch: (value: string) => this.search = value,
          onGroup: (value: string) => this.groupName = value,
          leadingContent: () => {
            this.ConnectionItems();
          },
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  build() {
    NativePageScaffold({
      titleBuilder: () => {
        this.PageTitle();
      },
      contentBuilder: () => {
        this.PageContent();
      },
    })
      .width('100%')
      .height('100%')
      .onSizeChange((_oldSize: SizeOptions, size: SizeOptions) => this.availableWidth = Number(size.width))
  }
}

@ComponentV2
struct TrafficPanel {
  @Require @Param model: MainModel;

  build() {
    Row({ space: 20 }) {
      TrafficMetric({ speed: this.model.downloadSpeed, total: this.model.downloadTotal, label: '下载' })
      Divider().vertical(true).height(56)
      TrafficMetric({ speed: this.model.uploadSpeed, total: this.model.uploadTotal, label: '上传' })
    }
    .width('100%')
    .padding(LayoutTokens.cardPadding)
    .backgroundColor(ThemeTokens.surface)
    .borderRadius(LayoutTokens.surfaceRadius)
  }
}

@ComponentV2
struct TrafficMetric {
  @Param speed: number = 0;
  @Param total: number = 0;
  @Param label: string = '';

  build() {
    Column({ space: 6 }) {
      Text(this.label).fontSize(13).fontColor(ThemeTokens.textSecondary)
      Text(`${formatBytes(this.speed)}/s`)
        .fontSize(18)
        .minFontSize(14)
        .maxFontSize(18)
        .maxLines(1)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeTokens.textPrimary)
      Text(`累计 ${formatBytes(this.total)}`).fontSize(12).fontColor(ThemeTokens.textSecondary)
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }
}

@ComponentV2
struct ConnectionOptions {
  @Require @Param model: MainModel;
  @Event onOpenProfiles: () => void = () => {
  };
  @Event onOpenNodes: () => void = () => {
  };

  private profileName(): string {
    return this.model.profiles.find((profile: ProfileInfo) => profile.id === this.model.selectedProfileId)?.name ??
      '尚未添加配置';
  }

  private currentNode(): ProxyNode | undefined {
    if (this.model.mode === 'direct') {
      return undefined;
    }
    const group = primaryGroup(this.model);
    return group?.nodes.find((node: ProxyNode) => node.name === group.now);
  }

  build() {
    Column({ space: 12 }) {
      Column() {
        Button({ type: ButtonType.Normal }) {
          Row({ space: 16 }) {
            Text('当前配置').fontSize(15).fontColor(ThemeTokens.textPrimary)
            Text(this.profileName())
              .fontSize(15)
              .fontColor(ThemeTokens.textSecondary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .textAlign(TextAlign.End)
              .layoutWeight(1)
            SymbolGlyph($r('sys.symbol.chevron_right'))
              .fontSize(14).fontColor([ThemeTokens.textSecondary]).accessibilityLevel('no')
          }
          .width('100%')
        }
        .width('100%')
        .padding({ left: LayoutTokens.cardPadding, right: LayoutTokens.cardPadding })
        .borderRadius(0)
        .backgroundColor(Color.Transparent)
        .constraintSize({ minHeight: 56 })
        .onClick(this.onOpenProfiles)
        .accessibilityText('当前配置，' + this.profileName() + '，管理配置')

        if (this.currentNode() !== undefined) {
          Divider().color($r('sys.color.comp_divider'))
            .margin({ left: LayoutTokens.cardPadding, right: LayoutTokens.cardPadding })
          Button({ type: ButtonType.Normal }) {
            Row({ space: 16 }) {
              Text(this.model.phase === 'connected' ? '当前节点' : '上次节点')
                .fontSize(15).fontColor(ThemeTokens.textPrimary)
              Text(this.currentNode()!.name)
                .fontSize(15)
                .fontColor(ThemeTokens.textSecondary)
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .textAlign(TextAlign.End)
                .layoutWeight(1)
              SymbolGlyph($r('sys.symbol.chevron_right'))
                .fontSize(14).fontColor([ThemeTokens.textSecondary]).accessibilityLevel('no')
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: LayoutTokens.cardPadding, right: LayoutTokens.cardPadding })
          .borderRadius(0)
          .backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 64 })
          .onClick(this.onOpenNodes)
          .accessibilityText('节点，' + this.currentNode()!.name + '，查看节点列表')
        }
        Divider().color($r('sys.color.comp_divider'))
          .margin({ left: LayoutTokens.cardPadding, right: LayoutTokens.cardPadding })
        Text(this.model.mode === 'global' ? '全部流量通过所选节点转发' :
          this.model.mode === 'direct' ? '全部流量直接连接目标网络' : '根据配置规则选择直连或节点转发')
          .fontSize(12)
          .fontColor(ThemeTokens.textSecondary)
          .padding({
            left: LayoutTokens.cardPadding,
            right: LayoutTokens.cardPadding,
            top: LayoutTokens.pageCompact,
            bottom: LayoutTokens.cardPadding,
          })
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .backgroundColor(ThemeTokens.surface)
      .borderRadius(LayoutTokens.surfaceRadius)
      // 内容内距放在可点击行内，整行按压背景由外层卡片圆角裁切。
      .clip(true)

      if (!this.model.canModifyProfiles) {
        Text(this.model.needsCleanup ? '先清理连接，再修改配置' : '切换配置前请先断开连接')
          .fontSize(12)
          .fontColor(ThemeTokens.textSecondary)
          .padding({ left: LayoutTokens.pageCompact, right: LayoutTokens.pageCompact })
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}

@ComponentV2
struct ModeControl {
  @Require @Param model: MainModel;
  private items: SegmentButtonV2Items =
    new SegmentButtonV2Items([{ text: '规则' }, { text: '全局' }, { text: '直连' }]);

  private index(): number {
    return this.model.mode === 'global' ? 1 : this.model.mode === 'direct' ? 2 : 0;
  }

  private change(index: number): void {
    const modes: string[] = ['rule', 'global', 'direct'];
    this.model.setMode(modes[index]).catch((error: Error) => showError(this.getUIContext(), error));
  }

  build() {
    CapsuleSegmentButtonV2({
      items: this.items,
      selectedIndex: this.index(),
      $selectedIndex: (index: number) => this.change(index),
      // 必须位于真实 Navigation 标题栏；专用参数也开启控件自身的材质交互动效。
      backgroundSystemMaterial: nativeControlMaterial(),
    })
      .width('100%')
      .enabled(this.model.canChangeMode)
  }
}
