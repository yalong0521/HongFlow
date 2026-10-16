import { MainModel } from '../model/MainModel';
import { isSelectableGroup, ProxyGroup, ProxyNode } from '../model/AppModels';
import { LayoutTokens, ThemeTokens } from './DesignTokens';
import { EmptyState, showError } from './AppWidgets';
import { NativeControlMaterial } from './MaterialSurface';

export function primaryGroup(model: MainModel): ProxyGroup | undefined {
  if (model.mode === 'global') {
    return model.groups.find((group: ProxyGroup) => group.name === 'GLOBAL');
  }
  return model.groups.find((group: ProxyGroup) => group.type === 'Selector' && group.name !== 'GLOBAL') ??
    model.groups.find((group: ProxyGroup) => isSelectableGroup(group.type)) ?? model.groups[0];
}

export function browserGroup(model: MainModel, groupName: string): ProxyGroup | undefined {
  return model.groups.find((group: ProxyGroup) => group.name === groupName) ?? primaryGroup(model);
}

@ComponentV2
export struct NodeBrowserControls {
  @Require @Param model: MainModel;
  @Param search: string = '';
  @Param groupName: string = '';
  @Param inTitleBar: boolean = true;
  @Event onSearch: (value: string) => void = () => {
  };
  @Event onGroup: (value: string) => void = () => {
  };
  @Event onSearchFocus: (focused: boolean) => void = () => {
  };

  private group(): ProxyGroup | undefined {
    return browserGroup(this.model, this.groupName);
  }

  private options(): SelectOption[] {
    return this.model.groups.map((group: ProxyGroup): SelectOption => ({ value: group.name }));
  }

  private groupIndex(): number {
    const name = this.group()?.name;
    return this.model.groups.findIndex((group: ProxyGroup) => group.name === name);
  }

  private testLabel(): string {
    return this.model.operationKind === 'testGroup' && this.model.operationTarget === this.group()?.name ?
      '测速中…' : '测速';
  }

  private test(): void {
    const group = this.group();
    if (group) {
      this.model.testGroup(group.name).catch((error: Error) => showError(this.getUIContext(), error));
    }
  }

  build() {
    Column({ space: LayoutTokens.pageCompact }) {
      Row({ space: 12 }) {
        Select(this.options())
          .showInSubWindow(true)
          .selected(this.groupIndex())
          .value(this.group()?.name ?? '选择代理组')
          .font({ size: 16, weight: FontWeight.Medium })
          .fontColor(ThemeTokens.textPrimary)
          .backgroundColor(Color.Transparent)
          .constraintSize({ minHeight: 44 })
          .layoutWeight(1)
          .onSelect((_index: number, value: string) => this.onGroup(value))
          .accessibilityText('代理组，' + (this.group()?.name ?? '未选择'))
        Button(this.testLabel(), { type: ButtonType.Capsule })
          .buttonStyle(ButtonStyleMode.NORMAL)
          .fontSize(15)
          .fontColor(ThemeTokens.textPrimary)
          .constraintSize({ minHeight: 44 })
          .attributeModifier(this.inTitleBar ? new NativeControlMaterial() : undefined)
          .enabled(this.model.phase === 'connected' && !this.model.busy && this.group() !== undefined)
          .onClick(() => this.test())
          .accessibilityText('测速 ' + (this.group()?.name ?? '当前代理组'))
      }
      .width('100%')

      Search({ value: this.search, placeholder: '搜索当前组的节点' })
        .onChange((value: string) => this.onSearch(value))
        .onFocus(() => this.onSearchFocus(true))
        .onBlur(() => this.onSearchFocus(false))
        .width('100%')
        .fontColor(ThemeTokens.textPrimary)
        .placeholderColor(ThemeTokens.textSecondary)
        .searchIcon({ color: $r('sys.color.icon_secondary') })
        .cancelButton({ style: CancelButtonStyle.INPUT, icon: { color: $r('sys.color.icon_secondary') } })
        .caretStyle({ color: $r('sys.color.brand') })
        .attributeModifier(this.inTitleBar ? new NativeControlMaterial() : undefined)
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }
}

@ComponentV2
export struct NodeBrowser {
  @Require @Param model: MainModel;
  @Param footerSpace: number = 0;
  @Param contentWidth: number = 0;
  @Param search: string = '';
  @Param groupName: string = '';
  @Param inOverview: boolean = false;
  @Param controlsInTitle: boolean = false;
  @Param scroller: ListScroller = new ListScroller();
  @Param showHeading: boolean = false;
  @Param contentStartSpace: number = LayoutTokens.pageCompact;
  @BuilderParam leadingContent: () => void = this.EmptyLeadingContent;
  @Event onSearch: (value: string) => void = () => {
  };
  @Event onGroup: (value: string) => void = () => {
  };
  private searchFocused: boolean = false;

  private revealSearch(align: ScrollAlign = ScrollAlign.START): void {
    if (this.searchFocused && this.showHeading) {
      // 键盘压缩列表后，折叠布局的节点标题项仍需完整露出末尾搜索框。
      this.scroller.scrollToIndex(1, false, align);
    }
  }

  private group(): ProxyGroup | undefined {
    return browserGroup(this.model, this.groupName);
  }

  private visibleNodes(): ProxyNode[] {
    const nodes = this.group()?.nodes ?? [];
    const query = this.search.trim().toLocaleLowerCase();
    return query.length === 0 ? nodes : nodes.filter((node: ProxyNode) =>
    node.name.toLocaleLowerCase().includes(query));
  }

  private groupHint(): string {
    if (this.model.phase !== 'connected') {
      return '显示上次连接的节点，连接后可切换和测速。';
    }
    return isSelectableGroup(this.group()?.type ?? '') ? '' : '此代理组自动选择节点，可查看并测速。';
  }

  @Builder
  private EmptyLeadingContent() {
  }

  build() {
    List({ space: LayoutTokens.pageCompact, scroller: this.scroller }) {
      this.leadingContent()
      if (this.model.profiles.length > 0 || this.model.groups.length > 0) {
        if (this.showHeading || (!this.controlsInTitle && this.model.groups.length > 0)) {
          ListItem() {
            Column({ space: LayoutTokens.pageCompact }) {
              if (this.showHeading) {
                Text('节点')
                  .fontSize(18)
                  .fontWeight(FontWeight.Medium)
                  .fontColor(ThemeTokens.textPrimary)
              }
              if (!this.controlsInTitle && this.model.groups.length > 0) {
                NodeBrowserControls({
                  model: this.model,
                  search: this.search,
                  groupName: this.groupName,
                  inTitleBar: false,
                  onSearch: this.onSearch,
                  onGroup: this.onGroup,
                  onSearchFocus: (focused: boolean) => {
                    this.searchFocused = focused;
                    this.revealSearch();
                  },
                })
              }
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
          }
        }
        if (this.model.groups.length > 0) {
          if (this.groupHint().length > 0) {
            ListItem() {
              Text(this.groupHint())
                .fontSize(13)
                .fontColor(ThemeTokens.textSecondary)
                .width('100%')
            }
          }
          if (this.visibleNodes().length === 0) {
            ListItem() {
              Column({ space: 12 }) {
                EmptyState({
                  title: this.search.trim().length > 0 ? '没有匹配的节点' : '当前组没有节点',
                  detail: this.search.trim().length > 0 ? '试试其他名称，或切换代理组。' : '切换代理组，查看其他节点。',
                })
                if (this.search.trim().length > 0) {
                  Button('清除搜索', { type: ButtonType.Capsule })
                    .buttonStyle(ButtonStyleMode.TEXTUAL)
                    .constraintSize({ minHeight: 44 })
                    .margin({ left: LayoutTokens.cardPadding, bottom: LayoutTokens.cardPadding })
                    .onClick(() => this.onSearch(''))
                }
              }
              .alignItems(HorizontalAlign.Start)
              .width('100%')
              .backgroundColor(this.inOverview ? Color.Transparent : ThemeTokens.surface)
              .borderRadius(this.inOverview ? 0 : LayoutTokens.surfaceRadius)
            }
          } else {
            ListItemGroup({ space: 0 }) {
              Repeat<ProxyNode>(this.visibleNodes())
                .each((row: RepeatItem<ProxyNode>) => {
                  ListItem() {
                    NodeRow({
                      node: row.item,
                      group: this.group()!,
                      model: this.model,
                      compact: this.inOverview,
                      radioScope: this.inOverview ? 'overview-browser' : 'nodes-browser',
                    })
                  }
                })
                .key((node: ProxyNode) => node.name)
                .virtualScroll()
            }
            .divider({
              strokeWidth: 0.5,
              startMargin: this.inOverview ? 0 : LayoutTokens.cardPadding,
              endMargin: this.inOverview ? 0 : LayoutTokens.cardPadding,
              color: $r('sys.color.comp_divider'),
            })
            .backgroundColor(this.inOverview ? Color.Transparent : ThemeTokens.surface)
            .borderRadius(this.inOverview ? 0 : LayoutTokens.surfaceRadius)
            .clip(true)
          }
        } else {
          ListItem() {
            EmptyState({
              title: this.model.phase === 'connected' ? '当前配置没有代理组' : '连接后查看节点',
              detail: this.model.phase === 'connected' ? '此配置未提供可展示的代理组，请检查当前配置。' :
                '连接 VPN 后，可查看当前配置的代理组和节点。',
            })
          }
        }
      }
    }
    .width('100%')
    .height('100%')
    .onSizeChange((oldSize: SizeOptions, size: SizeOptions) => {
      // 压缩时先露出输入框；恢复高度时将标题项置顶，避开底部浮栏。
      this.revealSearch(Number(size.height) < Number(oldSize.height) ? ScrollAlign.END : ScrollAlign.START);
    })
    // 保留列表自身的滚动裁切，但让正文控件阴影可以绘制到页面内边距。
    .clipContent(ContentClipMode.BOUNDARY)
    .contentEndOffset(this.footerSpace)
    .constraintSize({ maxWidth: this.inOverview ? LayoutTokens.overviewMaxWidth : LayoutTokens.listMaxWidth })
    .padding({
      top: this.controlsInTitle ? 0 : this.inOverview ? LayoutTokens.cardPadding : this.contentStartSpace,
      bottom: this.inOverview ? LayoutTokens.cardPadding : LayoutTokens.pageCompact,
      left: this.inOverview ? LayoutTokens.cardPadding : this.contentWidth >= 600 ?
        LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      right: this.inOverview ? LayoutTokens.cardPadding : this.contentWidth >= 600 ?
        LayoutTokens.pageRegular : LayoutTokens.pageCompact,
    })
    .backgroundColor(this.inOverview ? ThemeTokens.surface : ThemeTokens.background)
    .borderRadius(this.inOverview ? LayoutTokens.surfaceRadius : 0)
  }
}

@ComponentV2
export struct NodeRow {
  @Require @Param model: MainModel;
  @Require @Param node: ProxyNode;
  @Require @Param group: ProxyGroup;
  @Param compact: boolean = false;
  @Param radioScope: string = 'nodes-browser';

  private selected(): boolean {
    return this.group.now === this.node.name;
  }

  private switching(): boolean {
    return this.model.operationKind === 'selectNode' && this.model.operationTarget === this.group.name &&
      this.model.operationNode === this.node.name;
  }

  private delayLabel(): string {
    return this.node.delay > 0 ? `${this.node.delay} ms` : this.node.delay < 0 ? '超时' : '未测';
  }

  private selectable(): boolean {
    return this.model.phase === 'connected' && !this.model.busy && isSelectableGroup(this.group.type);
  }

  @Builder
  private NodeInformation() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(this.node.name)
          .fontSize(16)
          .fontWeight(this.selected() ? FontWeight.Medium : FontWeight.Normal)
          .fontColor(ThemeTokens.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(this.node.type)
          .fontSize(12)
          .fontColor(ThemeTokens.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.delayLabel())
        .fontSize(13)
        .fontColor(this.node.delay < 0 ? ThemeTokens.warning :
          this.selected() && this.node.delay > 0 ? ThemeTokens.success : ThemeTokens.textSecondary)
        .maxLines(1)

      // 保留 Radio 及其系统边距占位，隐藏后叠加进度，避免文字左右移动或行高变化。
      Stack() {
        Radio({ value: this.node.name, group: this.radioScope + ':' + this.group.name })
          .checked(this.selected())
          .visibility(this.switching() ? Visibility.Hidden : Visibility.Visible)
          .hitTestBehavior(HitTestMode.None)
          .focusable(false)
          .accessibilityLevel('no')
          .width(20)
          .height(20)
        if (this.switching()) {
          LoadingProgress()
            .color($r('sys.color.brand'))
            .width(20)
            .height(20)
            .accessibilityLevel('no')
        }
      }
    }
    .width('100%')
    .padding({
      left: this.compact ? 0 : LayoutTokens.cardPadding,
      right: this.compact ? 0 : LayoutTokens.cardPadding,
      top: 12,
      bottom: 12
    })
    .constraintSize({ minHeight: LayoutTokens.nodeRowCompactMinHeight })
  }

  build() {
    if (this.selectable()) {
      Button({ type: ButtonType.Normal }) {
        this.NodeInformation()
      }
      .width('100%')
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => this.model.selectNode(this.group.name, this.node.name)
        .catch((error: Error) => showError(this.getUIContext(), error)))
      .accessibilityText(`${this.node.name}，${this.selected() ? '当前节点' : '未选择'}，${this.delayLabel()}`)
    } else {
      // 缓存节点和不可手选的代理组仍是可读信息，不能由禁用按钮将文字与延迟一同淡化。
      Column() {
        this.NodeInformation()
      }
      .width('100%')
      .accessibilityGroup(true)
      .accessibilityText(this.switching() ? `${this.node.name}，正在切换` :
        `${this.node.name}，${this.selected() ? '当前节点' : '未选择'}，${this.delayLabel()}，只读`)
    }
  }
}
