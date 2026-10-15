import { connection } from '@kit.NetworkKit';
import { VpnRequest, VpnSnapshot } from '../model/AppModels';

// NetworkKit NetHandle.netId 契约：0 表示无默认网络，有效网络标识从 100 开始。
const MIN_NET_ID: number = 100;

/** 仅按真实 TUN fd 对应的网卡名认领系统网络，不能用地址或网络列表差集猜测。 */
export function findVpnNetworkId(interfaceName: string): number {
  if (interfaceName.length === 0) {
    return -1;
  }
  try {
    for (const network of connection.getAllNetsSync()) {
      if (network.netId >= MIN_NET_ID &&
        connection.getNetCapabilitiesSync(network).bearerTypes.includes(connection.NetBearType.BEARER_VPN) &&
        connection.getConnectionPropertiesSync(network).interfaceName === interfaceName) {
        return network.netId;
      }
    }
  } catch (_) {
    // 系统登记可能晚于 create 返回；扩展后续状态更新还会尝试获取身份。
  }
  return -1;
}

/** 调用方仍须等待本次系统 stop 结算；此处只确认本请求的网卡是否已释放。 */
export function isVpnRequestReleased(request: VpnRequest | undefined, snapshot: VpnSnapshot): boolean {
  const matching = request !== undefined && request.id === snapshot.requestId &&
    request.profileId === snapshot.profileId && request.secret === snapshot.secret;
  if (matching) {
    if (snapshot.vpnNetId >= MIN_NET_ID) {
      try {
        // 网卡身份跨进程保留，其他应用后来创建的 VPN 不影响本请求的清理。
        return connection.getAllNetsSync().every((network: connection.NetHandle) =>
        network.netId !== snapshot.vpnNetId);
      } catch (_) {
        return false;
      }
    }
    if (request?.cancelled === true && snapshot.tunnelState === 'not-created') {
      return true;
    }
  }
  // 旧快照、创建中途退出、未能取得身份的连接仍不假设已经释放。
  // destroy 返回成功但系统网卡尚在时，released 也不能替代网络存在性检查。
  return isSystemVpnAbsent();
}

/** SDK 停止调用返回后，仍需核对系统网卡；查询失败不能当作已经断开。 */
export function isSystemVpnAbsent(): boolean {
  try {
    return connection.getAllNetsSync().every((network: connection.NetHandle) => {
      const capabilities = connection.getNetCapabilitiesSync(network);
      return !capabilities.bearerTypes.includes(connection.NetBearType.BEARER_VPN);
    });
  } catch (_) {
    return false;
  }
}
