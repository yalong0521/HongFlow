import { ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { rpc } from '@kit.IPCKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { appSession } from '../service/AppSession';
import { CardCommandInbox } from '../service/CardCommandInbox';
import { VpnCardService } from '../service/VpnCardService';

const CARD_CONTROL_METHOD: string = 'controlVpn';

class CardControlReply implements rpc.Parcelable {
  private accepted: boolean;

  constructor(accepted: boolean) {
    this.accepted = accepted;
  }

  marshalling(data: rpc.MessageSequence): boolean {
    try {
      data.writeBoolean(this.accepted);
      return true;
    } catch (_) {
      return false;
    }
  }

  unmarshalling(data: rpc.MessageSequence): boolean {
    try {
      this.accepted = data.readBoolean();
      return true;
    } catch (_) {
      return false;
    }
  }
}

export default class EntryAbility extends UIAbility {
  private windowGeneration: number = 0;
  private cardControlRegistered: boolean = false;
  private cardControl = (data: rpc.MessageSequence): rpc.Parcelable => {
    let accepted = false;
    try {
      accepted = this.handleCard({ parameters: { params: data.readString() } });
      if (accepted) {
        this.initializeSession();
      }
    } catch (_) {
      // 外部调用和损坏的序列化数据均不得绕过卡片令牌校验。
    }
    return new CardControlReply(accepted);
  };

  onCreate(want: Want): void {
    try {
      this.callee.on(CARD_CONTROL_METHOD, this.cardControl);
      this.cardControlRegistered = true;
    } catch (_) {
      // A card IPC registration failure must not prevent normal app startup.
      hilog.error(0x0000, 'HongFlow', '注册桌面卡片后台控制失败');
    }
    this.handleCard(want);
    this.initializeSession();
  }

  onNewWant(want: Want): void {
    this.handleCard(want);
    this.initializeSession();
  }

  onDestroy(): void {
    this.windowGeneration += 1;
    try {
      if (this.cardControlRegistered) {
        this.callee.off(CARD_CONTROL_METHOD);
      }
    } catch (_) {
      hilog.warn(0x0000, 'HongFlow', '注销桌面卡片后台控制失败');
    } finally {
      this.cardControlRegistered = false;
      appSession.dispose();
    }
  }

  private initializeSession(): void {
    appSession.initialize(this.context).catch((error: Error) => {
      hilog.error(0x0000, 'HongFlow', '应用初始化失败: %{public}s', error.message);
    });
  }

  private handleCard(want: Want): boolean {
    try {
      const command = new VpnCardService(this.context).authenticatedCommand(want);
      if (command !== undefined) {
        CardCommandInbox.offer(command);
        return true;
      }
    } catch (_) {
      // Both launcher and call entries are public. Invalid or removed-card
      // commands cannot create a VPN request or cancel a connection.
    }
    return false;
  }

  onWindowStageCreate(stage: window.WindowStage): void {
    const generation = ++this.windowGeneration;
    this.loadMainWindow(stage, generation).catch((error: Error) => {
      hilog.error(0x0000, 'HongFlow', '窗口加载失败: %{public}s', String(error));
    });
  }

  onWindowStageDestroy(): void {
    this.windowGeneration += 1;
  }

  private async loadMainWindow(stage: window.WindowStage, generation: number): Promise<void> {
    try {
      // Let the background cover the gesture area. Index applies the system's
      // measured content insets once inside this window.
      await stage.getMainWindowSync().setWindowLayoutFullScreen(true);
    } catch (error) {
      hilog.warn(0x0000, 'HongFlow', '窗口沉浸布局设置失败: %{public}s', String(error));
    }
    if (generation !== this.windowGeneration) {
      return;
    }
    try {
      // 在首次渲染前交还系统主题，窗口重新创建时仍沿用系统的当前外观。
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      hilog.error(0x0000, 'HongFlow', '系统主题初始化失败: %{public}s', String(error));
    }
    stage.loadContent('pages/Index', (error) => {
      if (generation !== this.windowGeneration) {
        return;
      }
      if (error.code) {
        hilog.error(0x0000, 'HongFlow', '页面加载失败: %{public}s', error.message);
        return;
      }
    });
  }
}
