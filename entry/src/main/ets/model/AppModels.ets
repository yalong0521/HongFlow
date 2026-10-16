export const APP_BUNDLE_NAME: string = 'com.weiyalong.hongflow';

export const VPN_START_TIMEOUT: number = 30000;

export const DEFAULT_SUBSCRIPTION_UPDATE_HOURS: number = 24;

export const SUBSCRIPTION_UPDATE_HOURS: number[] = [0, 6, 12, 24];

export type OperationKind = 'none' | 'importSubscription' | 'importLocalFile' | 'selectProfile' |
'refreshProfile' | 'removeProfile' | 'selectNode' | 'testGroup' | 'setMode' | 'connect' | 'disconnect';

export function isSelectableGroup(type: string): boolean {
  return type === 'Selector' || type === 'URLTest' || type === 'Fallback';
}

export class ProfileInfo {
  id: string = '';
  name: string = '';
  url: string = '';
  updatedAt: number = 0;
  nodeCount: number = 0;
  // 每次内容更新产生新身份，后台旧下载不能覆盖同一毫秒内完成的手动更新。
  revision: string = '';
}

@ObservedV2
export class ProxyNode {
  @Trace name: string = '';
  @Trace type: string = '';
  @Trace delay: number = 0;
}

@ObservedV2
export class ProxyGroup {
  @Trace name: string = '';
  @Trace type: string = '';
  @Trace now: string = '';
  @Trace nodes: ProxyNode[] = [];
}

export class LogLine {
  time: number = 0;
  level: string = 'info';
  message: string = '';
}

export class VpnSnapshot {
  phase: string = 'idle';
  message: string = '';
  requestId: string = '';
  profileId: string = '';
  secret: string = '';
  connectedSince: number = 0;
  updatedAt: number = 0;
  // 创建前先持久化 creating；清理步骤全部成功才发布 released，仍须核对系统网卡已消失。
  // 旧版本没有这些字段时保持未知，不能把其他 VPN 当作本请求的释放确认。
  tunnelState: string = 'unknown';
  vpnNetId: number = -1;
}

export class VpnRequest {
  id: string = '';
  profileId: string = '';
  secret: string = '';
  createdAt: number = 0;
  cancelled: boolean = false;
  stopping: boolean = false;
}

export class SavedSettings {
  selectedProfileId: string = '';
  mode: string = 'rule';
  selections: Record<string, Record<string, string>> = {};
  autoUpdateHours: number = DEFAULT_SUBSCRIPTION_UPDATE_HOURS;
  autoUpdateRevision: string = '';
}

export interface ValidationResult {
  valid: boolean;
  proxies: number;
  groups: number;
  rules: number;
  providers: number;
  mode: string;
  error?: string;
}
