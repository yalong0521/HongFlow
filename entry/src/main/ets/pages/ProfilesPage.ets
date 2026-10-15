import { MainModel } from '../model/MainModel';
import { ProfileInfo } from '../model/AppModels';
import {
  EmptyState,
  InlineNotice,
  NativePageScaffold,
  PageHeading,
  formatDate
} from '../components/AppWidgets';
import { LayoutTokens, ThemeTokens } from '../components/DesignTokens';
import {
  NativeControlMaterial,
  nativeControlShadowSpace,
  supportsImmersiveMaterial
} from '../components/MaterialSurface';

@ComponentV2
export struct ProfilesPage {
  @Require @Param model: MainModel;
  @Param footerSpace: number = 0;
  @Param contentWidth: number = 0;
  @Event onOpenConnection: () => void = () => {
  };
  @Local private showImport: boolean = false;
  @Local private name: string = '';
  @Local private url: string = '';
  @Local private urlError: string = '';
  @Local private formError: string = '';
  @Local private pageError: string = '';
  @Local private importSuccess: string = '';
  private generation: number = 0;

  aboutToAppear(): void {
    this.generation += 1;
  }

  aboutToDisappear(): void {
    this.generation += 1;
  }

  private errorMessage(error: Error | undefined | null): string {
    return error?.message || '操作失败，请重试或查看运行日志。';
  }

  private selectedName(): string {
    return this.model.profiles.find((item: ProfileInfo) => item.id === this.model.selectedProfileId)?.name ||
      '尚未选择配置';
  }

  private sheetType(): SheetType {
    return this.contentWidth >= 600 ? SheetType.CENTER : SheetType.BOTTOM;
  }

  private lockedReason(): string {
    if (this.model.needsCleanup) {
      return '上次连接尚未完全释放，请先清理连接。';
    }
    if (this.model.phase === 'connected') {
      return 'VPN 连接期间不能修改配置，请先断开。';
    }
    if (this.model.phase === 'starting' || this.model.phase === 'stopping') {
      return '请等待 VPN 完成当前操作后再修改配置。';
    }
    return '正在处理当前操作，请稍候。';
  }

  private showImportSuccess(previousIds: string[]): void {
    // 文件选择器取消也会正常返回；只有实际新增配置才能显示导入成功。
    const imported = this.model.profiles.find((profile: ProfileInfo) => !previousIds.includes(profile.id));
    if (!imported) {
      return;
    }
    this.importSuccess = previousIds.length === 0 ? '配置已就绪，可以连接 VPN。' :
      '配置已导入。选择要使用的配置，再前往连接。';
    this.pageError = '';
  }

  private async importUrl(): Promise<void> {
    const name = this.name.trim();
    const url = this.url.trim();
    const lowerUrl = url.toLowerCase();
    if (!lowerUrl.startsWith('https://') && !lowerUrl.startsWith('http://')) {
      this.urlError = '请输入以 https:// 或 http:// 开头的订阅地址。';
      try {
        this.getUIContext().getFocusController().requestFocus('subscription-url');
      } catch (_) {
        // 字段错误保持可见；窗口失焦时由用户再次选择输入框。
      }
      return;
    }
    const generation = this.generation;
    const previousIds = this.model.profiles.map((profile: ProfileInfo) => profile.id);
    this.formError = '';
    this.urlError = '';
    try {
      await this.model.importSubscription(name, url);
      if (generation !== this.generation) {
        return;
      }
      this.showImport = false;
      this.name = '';
      this.url = '';
      this.showImportSuccess(previousIds);
    } catch (error) {
      if (generation === this.generation) {
        this.formError = this.errorMessage(error as Error);
        try {
          this.getUIContext().getFocusController().requestFocus('subscription-url');
        } catch (_) {
          // 导入失败仍显示在地址旁，失焦窗口无需再次弹出键盘。
        }
      }
    }
  }

  private async importFile(): Promise<void> {
    const generation = this.generation;
    const previousIds = this.model.profiles.map((profile: ProfileInfo) => profile.id);
    this.pageError = '';
    this.importSuccess = '';
    try {
      await this.model.importLocalFile();
      if (generation === this.generation) {
        this.showImportSuccess(previousIds);
      }
    } catch (error) {
      if (generation === this.generation) {
        this.pageError = this.errorMessage(error as Error);
      }
    }
  }

  private async run(action: Promise<void>): Promise<void> {
    const generation = this.generation;
    this.pageError = '';
    try {
      await action;
    } catch (error) {
      if (generation === this.generation) {
        this.pageError = this.errorMessage(error as Error);
      }
    }
  }

  private remove(profile: ProfileInfo): void {
    try {
      this.getUIContext().showAlertDialog({
        title: '删除配置',
        message: '删除“' + profile.name + '”？此配置与保存的节点选择会一并移除。',
        primaryButton: {
          value: '取消', action: () => {
          }
        },
        secondaryButton: {
          value: '删除',
          fontColor: ThemeTokens.warning,
          action: () => this.run(this.model.removeProfile(profile.id)),
        },
      });
    } catch (error) {
      this.pageError = this.errorMessage(error as Error);
    }
  }

  @Builder
  ImportSheet() {
    if (this.contentWidth < 600) {
      Scroll() {
        this.ImportForm()
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
    } else {
      Scroll() {
        this.ImportForm()
      }
      // 居中面板继续适应表单高度，不和 FIT_CONTENT 互相依赖百分比高度。
      .width('100%')
      .align(Alignment.Top)
      .scrollable(ScrollDirection.Vertical)
      .scrollBar(BarState.Auto)
    }
  }

  @Builder
  ImportForm() {
    Column({ space: 16 }) {
      Text('订阅地址需提供 YAML 格式的网络配置。')
        .fontSize(14)
        .fontColor(ThemeTokens.textSecondary)
        .width('100%')

      Column({ space: 8 }) {
        Text('订阅地址').fontSize(14).fontColor(ThemeTokens.textPrimary)
        TextInput({ text: this.url, placeholder: 'https://…' })
          .id('subscription-url')
          .type(InputType.URL)
          .enterKeyType(EnterKeyType.Next)
          .enabled(this.model.operationKind !== 'importSubscription')
          .onChange((value: string) => {
            this.url = value;
            this.urlError = '';
            this.formError = '';
          })
          .onSubmit(() => {
            try {
              this.getUIContext().getFocusController().requestFocus('subscription-name');
            } catch (_) {
              // 原生 Sheet 会处理键盘避让；无法移动焦点时仍可点击名称字段。
            }
          })
          .copyOption(CopyOptions.LocalDevice)
          .accessibilityText('订阅地址，必填')
        if (this.urlError.length > 0 || this.formError.length > 0) {
          Text(this.urlError.length > 0 ? this.urlError : this.formError)
            .fontSize(13)
            .fontColor(ThemeTokens.warning)
            .width('100%')
        } else {
          Text('从该地址下载配置，保存到本机。')
            .fontSize(12)
            .fontColor(ThemeTokens.textSecondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      Column({ space: 8 }) {
        Text('配置名称（可选）').fontSize(14).fontColor(ThemeTokens.textPrimary)
        TextInput({ text: this.name, placeholder: '默认：订阅配置' })
          .id('subscription-name')
          .maxLength(80)
          .enterKeyType(EnterKeyType.Done)
          .enabled(this.model.operationKind !== 'importSubscription')
          .onChange((value: string) => this.name = value)
          .onSubmit(() => {
            if (this.model.canModifyProfiles) {
              this.importUrl();
            }
          })
          .accessibilityText('配置名称，可选')
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')

      if (!this.model.canModifyProfiles && this.model.operationKind !== 'importSubscription') {
        InlineNotice({ title: '暂时不能添加', detail: this.lockedReason() })
      }

      Button(this.model.operationKind === 'importSubscription' ? '正在导入订阅…' : '导入订阅',
        { type: ButtonType.Capsule })
        .width('100%')
        .constraintSize({ minHeight: 48 })
        .buttonStyle(ButtonStyleMode.EMPHASIZED)
        .backgroundColor(ThemeTokens.actionBackground)
        .fontColor(ThemeTokens.actionForeground)
        .enabled(this.model.canModifyProfiles)
        .onClick(() => this.importUrl())
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({
      left: 24,
      right: 24,
      top: 24,
      bottom: 32
    })
  }

  @Builder
  PageNotices() {
    Column({ space: LayoutTokens.sectionGap }) {
      if (!this.model.canModifyProfiles) {
        Column({ space: 8 }) {
          InlineNotice({ title: '配置暂时只读', detail: this.lockedReason() })
          if (this.model.phase === 'connected' || this.model.phase === 'starting' ||
            this.model.phase === 'stopping' || this.model.needsCleanup) {
            Button('返回连接', { type: ButtonType.Capsule })
              .buttonStyle(ButtonStyleMode.TEXTUAL)
              .constraintSize({ minHeight: 44 })
              .onClick(this.onOpenConnection)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }

      if (this.pageError.length > 0) {
        InlineNotice({ title: '操作未完成', detail: this.pageError })
      }
      if (this.importSuccess.length > 0) {
        Column({ space: 8 }) {
          InlineNotice({ title: this.importSuccess, detail: '当前配置：' + this.selectedName() })
          Button('前往连接', { type: ButtonType.Capsule })
            .buttonStyle(ButtonStyleMode.TEXTUAL)
            .constraintSize({ minHeight: 44 })
            .onClick(this.onOpenConnection)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
  }

  @Builder
  PageTitle() {
    Row() {
      Column({ space: LayoutTokens.pageCompact }) {
        PageHeading({ title: '配置', detail: '导入订阅地址或本地 YAML 配置。' })
        Row({ space: 12 }) {
          Button('添加订阅', { type: ButtonType.Capsule })
            .buttonStyle(ButtonStyleMode.EMPHASIZED)
            .fontSize(15)
            .constraintSize({ minHeight: 48 })
            .layoutWeight(1)
            .backgroundColor(ThemeTokens.actionBackground)
            // 光感背板使用可反色强调文字；基础蓝色按钮回退为系统白字。
            .fontColor(supportsImmersiveMaterial() ? ThemeTokens.accent : $r('sys.color.font_on_primary'))
            .attributeModifier(new NativeControlMaterial())
            .onClick(() => this.showImport = true)
            .enabled(this.model.canModifyProfiles)
          Button(this.model.operationKind === 'importLocalFile' ? '正在导入…' : '导入文件',
            { type: ButtonType.Capsule })
            .buttonStyle(ButtonStyleMode.NORMAL)
            .fontSize(15)
            .fontColor(ThemeTokens.textPrimary)
            .constraintSize({ minHeight: 48 })
            .layoutWeight(1)
            .attributeModifier(new NativeControlMaterial())
            .onClick(() => this.importFile())
            .enabled(this.model.canModifyProfiles)
        }
        .width('100%')
        .constraintSize({ maxWidth: 520 })
        .align(Alignment.Start)
      }
      .alignItems(HorizontalAlign.Start)
      .width('100%')
      .constraintSize({ maxWidth: LayoutTokens.listMaxWidth })
      .padding({
        top: LayoutTokens.pageRegular,
        bottom: LayoutTokens.pageCompact + nativeControlShadowSpace(),
        left: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
        right: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
  }

  @Builder
  SavedProfilesHeading() {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text('已保存配置')
          .fontSize(18)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeTokens.textPrimary)
        Text('选择配置后，前往连接页启用。')
          .fontSize(13)
          .fontColor(ThemeTokens.textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      Text(this.model.profiles.length + ' 个')
        .fontSize(14)
        .fontColor(ThemeTokens.textSecondary)
    }
    .width('100%')
  }

  @Builder
  PageContent() {
    Row() {
      List({ space: LayoutTokens.sectionGap }) {
        if (!this.model.canModifyProfiles || this.pageError.length > 0 || this.importSuccess.length > 0) {
          ListItem() {
            this.PageNotices()
          }
        }

        if (this.model.profiles.length > 0) {
          ListItem() {
            this.SavedProfilesHeading()
          }

          ListItemGroup({ space: 0 }) {
            Repeat<ProfileInfo>(this.model.profiles)
              .each((row: RepeatItem<ProfileInfo>) => {
                ListItem() {
                  ProfileRow({
                    row: row,
                    model: this.model,
                    onSelect: () => this.run(this.model.selectProfile(row.item.id)),
                    onRefresh: () => this.run(this.model.refreshProfile(row.item.id)),
                    onRemove: () => this.remove(row.item),
                  })
                }
              })
              .key((profile: ProfileInfo) => profile.id)
              .virtualScroll()
          }
          .backgroundColor(ThemeTokens.surface)
          .borderRadius(LayoutTokens.surfaceRadius)
          .clip(true)
          .divider({
            strokeWidth: 0.5,
            startMargin: LayoutTokens.cardPadding,
            endMargin: LayoutTokens.cardPadding,
            color: $r('sys.color.comp_divider')
          })
        } else {
          ListItem() {
            EmptyState({
              title: '还没有配置',
              detail: '添加订阅或导入 .yaml、.yml 文件，导入后即可连接 VPN。',
            })
          }
        }
      }
      .width('100%')
      .height('100%')
      .constraintSize({ maxWidth: LayoutTokens.listMaxWidth })
      .contentEndOffset(this.footerSpace + LayoutTokens.pageRegular)
      .padding({
        left: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
        right: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
        bottom: LayoutTokens.pageRegular,
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
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
      .bindSheet($$this.showImport, this.ImportSheet, {
        // 手机使用原生大面板提供完整视口；键盘出现后仅压缩可滚动内容。
        height: this.contentWidth < 600 ? SheetSize.LARGE : SheetSize.FIT_CONTENT,
        title: { title: '添加订阅' },
        showClose: this.model.operationKind !== 'importSubscription',
        dragBar: this.contentWidth < 600,
        preferType: this.sheetType(),
        width: this.contentWidth >= 600 ? 520 : '100%',
        enableHoverMode: true,
        keyboardAvoidMode: this.contentWidth < 600 ? SheetKeyboardAvoidMode.RESIZE_ONLY :
          SheetKeyboardAvoidMode.TRANSLATE_AND_RESIZE,
        onWillSpringBackWhenDismiss: (action: SpringBackAction) => {
          // 自定义关闭拦截时系统会先回弹；仅下载中保留表单需要这段回弹。
          if (this.model.operationKind === 'importSubscription') {
            action.springBack();
          }
        },
        onWillDismiss: (action: DismissSheetAction) => {
          // 下载期间保持当前表单；避免旧请求完成后清空重新打开的草稿。
          if (this.model.operationKind !== 'importSubscription') {
            this.showImport = false;
            action.dismiss();
          }
        },
      })
  }
}

@ComponentV2
struct ProfileRow {
  @Require @Param row: RepeatItem<ProfileInfo>;
  @Require @Param model: MainModel;
  @Event onSelect: () => void = () => {
  };
  @Event onRefresh: () => void = () => {
  };
  @Event onRemove: () => void = () => {
  };

  private selected(): boolean {
    return this.row.item.id === this.model.selectedProfileId;
  }

  private progressLabel(): string {
    if (this.model.operationTarget !== this.row.item.id) {
      return '';
    }
    if (this.model.operationKind === 'refreshProfile') {
      return '正在更新订阅…';
    }
    if (this.model.operationKind === 'removeProfile') {
      return '正在删除…';
    }
    return '';
  }

  @Builder
  ProfileMenu() {
    Menu() {
      if (this.row.item.url.length > 0) {
        MenuItem({ content: '更新订阅' })
          .enabled(this.model.canModifyProfiles)
          .onClick(this.onRefresh)
      }
      MenuItem({ content: '删除配置' })
        .contentFontColor(ThemeTokens.warning)
        .enabled(this.model.canModifyProfiles)
        .onClick(this.onRemove)
    }
  }

  @Builder
  private ProfileInformation() {
    Row({ space: 12 }) {
      Radio({ value: this.row.item.id, group: 'profiles' })
        .checked(this.selected())
        .hitTestBehavior(HitTestMode.None)
        .focusable(false)
        .width(20)
        .height(20)
        .accessibilityLevel('no')
      Column({ space: 4 }) {
        Text(this.row.item.name)
          .fontSize(16)
          .fontWeight(FontWeight.Medium)
          .fontColor(ThemeTokens.textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text((this.selected() ? '当前 · ' : '') +
          (this.row.item.url ? '订阅' : '本地文件') + ' · ' + this.row.item.nodeCount + ' 个节点')
          .fontSize(12)
          .fontColor(this.selected() ? ThemeTokens.accent : ThemeTokens.textSecondary)
        Text(this.progressLabel() || '更新于 ' + formatDate(this.row.item.updatedAt))
          .fontSize(12)
          .fontColor(ThemeTokens.textSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
  }

  build() {
    Row({ space: 8 }) {
      if (this.model.canModifyProfiles) {
        Button({ type: ButtonType.Normal }) {
          this.ProfileInformation()
        }
        .layoutWeight(1)
        .constraintSize({ minHeight: 64 })
        .padding({ left: LayoutTokens.cardPadding, top: 12, bottom: 12 })
        .backgroundColor(Color.Transparent)
        .enabled(this.model.canModifyProfiles)
        .onClick(this.onSelect)
        .accessibilityText(this.row.item.name + '，' + (this.selected() ? '当前配置' : '未选择') + '，' +
          this.row.item.nodeCount + ' 个节点')
      } else {
        // 只读时展示已保存信息，避免禁用 Button 将配置文字一起淡化。
        Column() {
          this.ProfileInformation()
        }
        .layoutWeight(1)
        .constraintSize({ minHeight: 64 })
        .padding({ left: LayoutTokens.cardPadding, top: 12, bottom: 12 })
        .justifyContent(FlexAlign.Center)
        .accessibilityGroup(true)
        .accessibilityText(this.row.item.name + '，' + (this.selected() ? '当前配置' : '未选择') + '，' +
          this.row.item.nodeCount + ' 个节点，只读')
      }

      Button('操作', { type: ButtonType.Capsule })
        .buttonStyle(ButtonStyleMode.TEXTUAL)
        .fontSize(14)
        .padding(0)
        .constraintSize({ minWidth: 44, minHeight: 44 })
        .enabled(this.model.canModifyProfiles)
        .bindMenu(this.ProfileMenu, { placement: Placement.BottomRight })
        .accessibilityText(this.row.item.name + ' 的配置操作')
    }
    .width('100%')
    .padding({ right: 8 })
  }
}
