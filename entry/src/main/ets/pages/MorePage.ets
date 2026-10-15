import { bundleManager, common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { MainModel } from '../model/MainModel';
import { LogLine } from '../model/AppModels';
import { VpnCardService } from '../service/VpnCardService';
import {
  EmptyState,
  InlineNotice,
  NativePageScaffold,
  PageHeading,
  formatDate
} from '../components/AppWidgets';
import { LayoutTokens, ThemeTokens } from '../components/DesignTokens';

interface LicenseDocument {
  title: string;
  detail: string;
  file: string;
}

@ComponentV2
export struct MorePage {
  @Require @Param model: MainModel;
  @Param footerSpace: number = 0;
  @Param contentWidth: number = 0;
  @Local private showLogs: boolean = false;
  @Local private showAbout: boolean = false;
  @Local private showPrivacy: boolean = false;
  @Local private showLicenses: boolean = false;
  @Local private error: string = '';
  @Local private appVersion: string = '版本信息暂不可用';
  @Local private licenseDocuments: LicenseDocument[] = [];
  @Local private licenseTitle: string = '';
  @Local private licenseText: string = '';
  @Local private licenseError: string = '';

  aboutToAppear(): void {
    try {
      const bundle = bundleManager.getBundleInfoForSelfSync(bundleManager.BundleFlag.GET_BUNDLE_INFO_DEFAULT);
      this.appVersion = '版本 ' + bundle.versionName;
    } catch (_) {
      // 版本来自实际安装包，不用源码中的固定值冒充读取结果。
    }
  }

  private addDesktopCard(): void {
    this.error = '';
    try {
      VpnCardService.openManager();
    } catch (error) {
      this.error = (error as Error)?.message || '暂时无法打开桌面卡片管理。';
    }
  }

  private readNotice(file: string): string {
    try {
      const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
      const bytes = context.resourceManager.getRawFileContentSync('licenses/' + file);
      return util.TextDecoder.create('utf-8', { fatal: true }).decodeToString(bytes);
    } catch (_) {
      throw new Error('无法读取开源声明');
    }
  }

  private sheetType(): SheetType {
    return this.contentWidth >= 600 ? SheetType.CENTER : SheetType.BOTTOM;
  }

  private openLicenses(): void {
    this.licenseTitle = '';
    this.licenseText = '';
    this.licenseError = '';
    this.licenseDocuments = [];
    try {
      this.licenseDocuments = JSON.parse(this.readNotice('index.json')) as LicenseDocument[];
    } catch (_) {
      this.licenseError = '暂时无法读取开源声明，请重新打开此页面。';
    }
    this.showLicenses = true;
  }

  private openLicenseDocument(document: LicenseDocument): void {
    this.licenseError = '';
    try {
      this.licenseText = this.readNotice(document.file);
      this.licenseTitle = document.title;
    } catch (_) {
      this.licenseError = '暂时无法读取这份声明，请重试。';
    }
  }

  @Builder
  PageContent() {
    List({ space: 12 }) {
      if (this.error.length > 0) {
        ListItem() {
          InlineNotice({ title: '操作未完成', detail: this.error })
        }
      }

      ListItem() {
        Text('快捷操作').fontSize(14).fontColor(ThemeTokens.textSecondary)
          .padding({ left: LayoutTokens.cardPadding, top: 8 })
      }

      ListItemGroup({ space: 0 }) {
        ListItem() {
          SettingsRow({
            title: '桌面卡片',
            detail: '1×2 卡片，右侧开关，左侧打开应用。',
            symbol: $r('sys.symbol.ohos_lock'),
            actionText: '添加',
            onOpen: () => this.addDesktopCard(),
          })
        }
      }
      .backgroundColor(ThemeTokens.surface)
      .borderRadius(LayoutTokens.surfaceRadius)
      .clip(true)
      .divider({
        strokeWidth: 0.5,
        startMargin: 20,
        endMargin: 20,
        color: ThemeTokens.surfaceSubtle
      })

      ListItem() {
        Text('诊断').fontSize(14).fontColor(ThemeTokens.textSecondary)
          .padding({ left: LayoutTokens.cardPadding, top: 8 })
      }

      ListItemGroup({ space: 0 }) {
        ListItem() {
          SettingsRow({
            title: '运行日志',
            detail: '查看最近 200 条连接信息。',
            symbol: $r('sys.symbol.doc_text'),
            onOpen: () => this.showLogs = true,
          })
        }
        // 各入口绑定独立原生 Sheet，系统返回键关闭当前弹层。
        .bindSheet($$this.showLogs, this.LogsSheet, {
          height: SheetSize.LARGE,
          title: { title: '运行日志', subtitle: '仅在本机展示最近的运行信息' },
          showClose: true,
          dragBar: this.contentWidth < 600,
          preferType: this.sheetType(),
          width: this.contentWidth >= 600 ? 520 : '100%',
          enableHoverMode: true,
        })
      }
      .backgroundColor(ThemeTokens.surface)
      .borderRadius(LayoutTokens.surfaceRadius)
      .clip(true)

      ListItem() {
        Text('应用与隐私').fontSize(14).fontColor(ThemeTokens.textSecondary)
          .padding({ left: LayoutTokens.cardPadding, top: 8 })
      }

      ListItemGroup({ space: 0 }) {
        ListItem() {
          SettingsRow({
            title: '关于鸿流',
            detail: this.appVersion,
            symbol: $r('sys.symbol.info_circle'),
            onOpen: () => this.showAbout = true,
          })
        }

        ListItem() {
          SettingsRow({
            title: '隐私与数据',
            detail: '了解本机存储、网络访问与权限。',
            symbol: $r('sys.symbol.ohos_lock'),
            onOpen: () => this.showPrivacy = true,
          })
        }
        .bindSheet($$this.showPrivacy, this.PrivacySheet, {
          height: SheetSize.LARGE,
          title: { title: '隐私与数据', subtitle: '了解鸿流如何处理你的配置与连接' },
          showClose: true,
          dragBar: this.contentWidth < 600,
          preferType: this.sheetType(),
          width: this.contentWidth >= 600 ? 520 : '100%',
          enableHoverMode: true,
        })

        ListItem() {
          SettingsRow({
            title: '开源许可',
            detail: '组件来源、版权与完整许可文本。',
            symbol: $r('sys.symbol.doc_text'),
            onOpen: () => this.openLicenses(),
          })
        }
        .bindSheet($$this.showLicenses, this.LicensesSheet, {
          height: SheetSize.LARGE,
          title: { title: '开源许可', subtitle: '感谢开源社区的贡献' },
          showClose: true,
          dragBar: this.contentWidth < 600,
          preferType: this.sheetType(),
          width: this.contentWidth >= 600 ? 640 : '100%',
          enableHoverMode: true,
        })
      }
      .backgroundColor(ThemeTokens.surface)
      .borderRadius(LayoutTokens.surfaceRadius)
      .clip(true)
      .divider({
        strokeWidth: 0.5,
        startMargin: 20,
        endMargin: 20,
        color: ThemeTokens.surfaceSubtle
      })
    }
    .width('100%')
    .height('100%')
    .constraintSize({ maxWidth: LayoutTokens.listMaxWidth })
    .contentStartOffset(LayoutTokens.pageCompact)
    .contentEndOffset(this.footerSpace + 24)
    .padding({
      left: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      right: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      bottom: LayoutTokens.pageRegular,
    })
  }

  @Builder
  AboutApplication() {
    Column({ space: 20 }) {
      Row({ space: 16 }) {
        // 分层 JSON 供系统桌面读取；页面直接复用两层 PNG，避免 Image 将 JSON 当作图片解码。
        Stack() {
          Image($r('app.media.app_icon_background')).width('100%').height('100%')
          Image($r('app.media.app_icon_foreground')).width('100%').height('100%')
        }
        .width(64)
        .height(64)
        .borderRadius(LayoutTokens.surfaceRadius)
        .clip(true)
        .accessibilityLevel('no')

        Column({ space: 6 }) {
          Text('鸿流')
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(ThemeTokens.textPrimary)
          Text(this.appVersion).fontSize(14).fontColor(ThemeTokens.textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
      }
      .width('100%')

      Divider().color(ThemeTokens.surfaceSubtle)
      Text('鸿流 · 原生鸿蒙网络连接工具')
        .fontSize(14)
        .fontColor(ThemeTokens.textSecondary)
        .lineHeight(22)
      Text('外观与光感跟随系统设置。')
        .fontSize(13)
        .fontColor(ThemeTokens.textSecondary)
        .lineHeight(20)
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
  PrivacySection(title: string, detail: string) {
    Column({ space: 8 }) {
      Text(title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(ThemeTokens.textPrimary)
      Text(detail)
        .fontSize(14)
        .fontColor(ThemeTokens.textSecondary)
        .lineHeight(22)
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  @Builder
  PrivacySheet() {
    Scroll() {
      Column({ space: LayoutTokens.sectionGap }) {
        this.PrivacySection('配置保存在本机',
          '导入的订阅地址、配置文件、所选节点和连接设置保存在应用的私有目录中。请妥善保管订阅地址，其中可能包含访问凭据。删除配置会移除对应配置文件与订阅记录。')
        this.PrivacySection('内核缓存与删除',
          '内核会在本机缓存节点提供者和规则数据，其中可能包含节点凭据；使用 Fake-IP 模式时，还会保存域名与合成 IP 的映射。删除配置不会清除这些缓存。若要移除应用在本机保存的全部数据，可通过系统卸载应用；卸载前请备份需要保留的配置。')
        this.PrivacySection('网络访问由你的配置决定',
          '添加或更新订阅时，应用会访问你填写的地址。连接后，网络流量按照当前配置直连或经所选节点转发；节点、远程规则和配置中的 DNS 服务可能接收相应请求，请使用可信来源。')
        this.PrivacySection('DNS 与节点测速',
          '未配置主 DNS 时，默认使用 1.1.1.1 和 223.5.5.5 的 DoH 服务。未配置引导 DNS 时，需要解析 DNS 服务器域名仍会使用这两个地址，即使已指定主 DNS。点击测速会通过对应节点访问 https://www.gstatic.com/generate_204，以计算往返延迟。')
        this.PrivacySection('运行信息与日志',
          '应用在本机读取连接状态和流量统计，用于显示连接信息。日志保留最近 200 条，可能包含域名、节点名称或错误详情；已保存的完整订阅地址会隐藏。复制日志前，请检查其中是否包含敏感信息。')
        this.PrivacySection('权限由系统管理',
          'VPN 连接需要系统授权。选择本地配置时，通过系统文件选择器读取你选中的文件。')
        this.PrivacySection('桌面卡片',
          '卡片只显示 VPN 连接状态。点击右侧按钮在后台连接或断开，不打开应用窗口；点击左侧信息区打开应用。首次连接仍需系统 VPN 授权。配置名称、订阅地址、节点凭据与内核鉴权秘密不会交给桌面卡片。')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
      .padding({
        left: LayoutTokens.pageRegular,
        right: LayoutTokens.pageRegular,
        top: LayoutTokens.pageCompact,
        bottom: LayoutTokens.pageRegular
      })
    }
    .width('100%')
    .height('100%')
    .scrollBar(BarState.Auto)
  }

  @Builder
  LicensesSheet() {
    Column({ space: 12 }) {
      if (this.licenseError.length > 0) {
        InlineNotice({ title: '声明暂不可用', detail: this.licenseError })
      }
      if (this.licenseTitle.length > 0) {
        Button('返回声明目录', { type: ButtonType.Capsule })
          .buttonStyle(ButtonStyleMode.TEXTUAL)
          .height(44)
          .onClick(() => {
            this.licenseTitle = '';
            this.licenseText = '';
          })
        Scroll() {
          Column({ space: 16 }) {
            Text(this.licenseTitle)
              .fontSize(16)
              .fontWeight(FontWeight.Medium)
              .fontColor(ThemeTokens.textPrimary)
              .wordBreak(WordBreak.BREAK_ALL)
            Text(this.licenseText)
              .fontSize(14)
              .lineHeight(22)
              .fontColor(ThemeTokens.textSecondary)
              .copyOption(CopyOptions.LocalDevice)
              .wordBreak(WordBreak.BREAK_WORD)
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .padding({ bottom: LayoutTokens.pageRegular })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      } else {
        Text('鸿流及所用网络内核采用 GPL-3.0 许可。以下名称仅用于注明组件来源、版权和许可。')
          .fontSize(14)
          .fontColor(ThemeTokens.textSecondary)
          .lineHeight(22)
        List() {
          ForEach(this.licenseDocuments, (document: LicenseDocument) => {
            ListItem() {
              SettingsRow({
                title: document.title,
                detail: document.detail,
                showIcon: false,
                onOpen: () => this.openLicenseDocument(document),
              })
            }
          }, (document: LicenseDocument) => document.file)
        }
        .width('100%')
        .layoutWeight(1)
        .borderRadius(LayoutTokens.surfaceRadius)
        .clip(true)
        .contentEndOffset(LayoutTokens.pageRegular)
      }
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .height('100%')
    .padding({
      left: LayoutTokens.pageCompact,
      right: LayoutTokens.pageCompact,
      top: LayoutTokens.pageCompact,
      bottom: LayoutTokens.pageRegular
    })
  }

  @Builder
  LogsSheet() {
    Column() {
      if (this.model.logs.length === 0) {
        Scroll() {
          EmptyState({
            title: '暂无日志',
            detail: 'VPN 连接成功后开始接收内核运行日志，最多保留最近 200 条。',
          })
        }
        .width('100%')
        .layoutWeight(1)
        .padding({ bottom: LayoutTokens.pageRegular })
      } else {
        List({ space: 0 }) {
          ForEach(this.model.logs, (line: LogLine) => {
            ListItem() {
              LogRow({ line: line })
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .borderRadius(LayoutTokens.surfaceRadius)
        .clip(true)
        .contentEndOffset(LayoutTokens.pageRegular)
      }
    }
    .width('100%')
    .height('100%')
    .padding({ left: LayoutTokens.pageCompact, right: LayoutTokens.pageCompact, bottom: LayoutTokens.pageRegular })
  }

  @Builder
  PageTitle() {
    Column() {
      PageHeading({ title: '设置', detail: '快捷操作、诊断与应用信息' })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .constraintSize({ maxWidth: LayoutTokens.listMaxWidth })
    .padding({
      top: LayoutTokens.pageRegular,
      left: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      right: this.contentWidth >= 600 ? LayoutTokens.pageRegular : LayoutTokens.pageCompact,
      bottom: LayoutTokens.pageCompact,
    })
    .backgroundColor(ThemeTokens.background)
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
      .bindSheet($$this.showAbout, this.AboutApplication, {
        height: SheetSize.FIT_CONTENT,
        title: { title: '关于鸿流' },
        showClose: true,
        dragBar: this.contentWidth < 600,
        preferType: this.sheetType(),
        width: this.contentWidth >= 600 ? 520 : '100%',
        enableHoverMode: true,
      })
  }
}

@ComponentV2
struct SettingsRow {
  @Require @Param title: string;
  @Require @Param detail: string;
  @Param symbol: Resource = $r('sys.symbol.doc_text');
  @Param showIcon: boolean = true;
  @Param actionText: string = '';
  @Event onOpen: () => void = () => {
  };

  build() {
    Button({ type: ButtonType.Normal }) {
      Row({ space: 12 }) {
        if (this.showIcon) {
          SymbolGlyph(this.symbol)
            .fontSize(24)
            .fontColor([ThemeTokens.accent])
            .accessibilityLevel('no')
        }
        Column({ space: 4 }) {
          Text(this.title).fontSize(16).fontWeight(FontWeight.Medium).fontColor(ThemeTokens.textPrimary)
            .wordBreak(WordBreak.BREAK_WORD)
          Text(this.detail).fontSize(14).fontColor(ThemeTokens.textSecondary)
            .lineHeight(20)
            .wordBreak(WordBreak.BREAK_WORD)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (this.actionText.length > 0) {
          Text(this.actionText).fontSize(14).fontColor(ThemeTokens.accent)
        } else {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([ThemeTokens.textSecondary])
            .accessibilityLevel('no')
        }
      }
      .width('100%')
    }
    .width('100%')
    .constraintSize({ minHeight: LayoutTokens.rowMinHeight })
    .padding({
      left: LayoutTokens.cardPadding,
      right: LayoutTokens.cardPadding,
      top: 14,
      bottom: 14
    })
    .backgroundColor(Color.Transparent)
    .onClick(this.onOpen)
    .accessibilityText(this.title + '，' + this.detail + (this.actionText ? '，' + this.actionText : ''))
  }
}

@ComponentV2
struct LogRow {
  @Require @Param line: LogLine;

  build() {
    Column({ space: 8 }) {
      Text(formatDate(this.line.time) + ' · ' + this.line.level.toLocaleUpperCase())
        .fontSize(11)
        .fontColor(this.line.level === 'error' ? ThemeTokens.warning : ThemeTokens.textSecondary)
      Text(this.line.message)
        .fontSize(13)
        .fontFamily('monospace')
        .fontColor(ThemeTokens.textPrimary)
        .copyOption(CopyOptions.LocalDevice)
      Divider().color(ThemeTokens.surfaceSubtle).margin({ top: 8 })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({
      top: 16,
      bottom: 0,
      left: 20,
      right: 20
    })
  }
}
