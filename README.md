# 鸿流 HongFlow

原生 HarmonyOS VPN 客户端，使用 ArkTS / ArkUI 构建界面，通过系统 `VpnExtensionAbility` 与嵌入式 Mihomo 内核处理代理连接。

- 包名：`com.weiyalong.hongflow`
- 当前版本：`0.1.0`
- 目标 API 26，最低声明兼容 API 22
- 设备类型：手机、平板、鸿蒙电脑（`2in1`）；原生库架构为 ARM64

## 功能

- 导入兼容的 YAML 订阅链接或本地文件，校验、更新、选择和删除配置。
- 默认每天自动检查订阅，支持每 6 / 12 小时或关闭，当前 VPN 连接不受更新影响。
- 节点与代理组选择、HTTP 延迟测试，以及规则 / 全局 / 直连模式。
- 保存代理模式和每份配置的手选节点，连接时恢复选择。
- 系统 VPN、IPv4 / IPv6 与 DNS 转发、流量统计和运行日志。
- 内置固定版本 CA 和 Geo 规则数据，保留正常 TLS 证书及主机名校验。
- 原生 ArkUI 深浅色和宽窄屏布局，在系统支持的区域使用官方沉浸材质。
- 1×2 桌面卡片：左侧打开应用，右侧后台连接、取消或断开；首次连接仍需系统 VPN 授权。
- 鸿蒙电脑系统状态栏入口；应用进程存活时可查看状态和控制连接。

主入口为“连接、配置、设置”，节点列表位于连接页。当前连接未清理完成时禁止修改配置；切换节点影响新连接，保留已有连接。应用窗口关闭不会主动停止 VPN。

当前未实现单节点分享链接转换、按应用选择列表、进程归属规则、订阅用量展示、外部仪表盘和配置编辑器。电脑状态栏与桌面卡片不是控制中心自定义开关。

### 自动更新订阅

“设置 → 自动更新订阅”提供关闭、每 6 小时、每 12 小时和每天一次，默认每天一次。系统后台任务在有网络时检查到期的远程订阅，打开应用时也会补查；本地导入的文件不自动更新，联网可能使用移动数据。

自动下载复用手动更新的大小、编码和配置校验，失败保留原配置。下载成功后先保存候选内容，只有主应用确认 VPN 已断开时才替换配置，供下次连接使用；不会重启正在使用的 VPN。用户删除或手动更新订阅、调整自动更新设置后，旧下载结果自动失效。

后台任务使用系统持久化延迟任务，单次最多工作 110 秒；设置的周期是检查目标，系统可能因电量、应用活跃程度和后台限制而延后。持久化任务不代表能绕过用户结束应用或系统强制停止，划掉应用后的持续调度仍需真机验证。接口限制见[官方延迟任务说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/task-management/work-scheduler.md)。

### 最近任务清理与卡片状态

返回桌面与结束应用进程不同。系统可能在启动 VPN 的主进程结束后销毁 VPN；独立扩展进程不能保证在最近任务清理后继续连接。华为系统支持锁定最近任务卡片以排除一键清理，但手动上滑仍会结束锁定任务，参见[官方导航说明](https://consumer.huawei.com/cn/support/content/zh-cn16059585/)。

活动连接会为桌面卡片预约 5 分钟后的系统刷新，并在心跳存活时每分钟延后预约；进程被清理后，系统仍有机会唤醒卡片提供方核对状态。旧连接心跳超时且确认自有网卡已消失时显示“未连接”，按钮保留“清理连接”，由既有流程完成停止确认后再允许重连。查询失败、身份不匹配或自有网卡仍在时保留异常提示，不擅自改写连接文件。

此机制不是即时刷新保证：预约与周期刷新共享每卡每日 50 次配额，并受卡片可见性及系统调度影响。仍保留 30 分钟周期作为新卡添加和预约失败时的兜底。接口限制见[官方卡片刷新说明](https://github.com/openharmony/docs/blob/master/zh-cn/application-dev/form/arkts-ui-widget-passive-refresh.md)。

## 构建

需要 DevEco Studio 26、对应 HarmonyOS SDK / Native SDK，以及用于构建固定 OHOS Go 工具链的宿主 Go。构建脚本默认使用 macOS 的 `/Applications/DevEco-Studio.app/Contents`，可通过 `HONGFLOW_STUDIO_HOME` 指定 DevEco 安装目录。

```bash
./tools/build-app.sh release
```

仓库不保存预编译内核。首次构建缺少 `entry/libs/arm64-v8a/libhongflow_core.so` 时会自动执行内核构建，下载固定版本的工具链和依赖；需要网络及较长构建时间。

单独重建内核：

```bash
./tools/build-core.sh
```

`HONGFLOW_WORK_DIR` 可指定内核构建缓存，`OHOS_NATIVE_SDK` 可指定 Native SDK。修改 `native/core` 或项目补丁后需要主动重建内核，再构建应用；现有 `.so` 不会因源码变化自动重建。

内核必须使用脚本固定的 OpenHarmony-SIG Go 工具链。普通 Go 的动态 TLS 与鸿蒙 musl 加载方式不兼容，不应直接替换。

### 本地签名

公共 `build-profile.json5` 不含签名材料。未配置本地签名时生成未签名包；安装到设备前需配置自己的开发签名。

1. 在 DevEco Studio 中生成自己的证书、Profile 和密钥库。
2. 复制 `build-profile.local.example.json5` 为 `build-profile.local.json5`，填入实际材料路径、别名及密码。
3. 重新执行构建。根 `hvigorfile.ts` 通过公开构建 API 读取本地 JSON5，只在内存中合并签名设置，不回写公共配置。

`build-profile.local.json5`、`signing/`、签名材料、构建缓存和安装包均被 Git 忽略。签名材料可放在本机路径或 `signing/` 中。Release 编译与正式发布签名是不同步骤，调试 Profile 生成的包仍是测试包。

## 验证

现有主机回归直接执行生产 ArkTS 模块，系统 Kit、VPN / Form IPC、HTTP 和原生桥接由测试模拟：

```bash
node tools/test-card-host.cjs
node tools/test-model-review.cjs
node tools/test-model-round2.cjs
node tools/test-model-round3.cjs
node tools/test-ability-review.cjs
node tools/test-native-bridge.cjs
```

测试默认读取 DevEco 自带的 ArkTS 编译器，也可通过 `DEVECO_SDK_HOME` 指定 SDK 根目录。桥接回归在 macOS / Linux 上使用宿主 `clang++` 和 Node N-API 头文件，可通过 `CXX` 与 `HONGFLOW_NODE_INCLUDE` 指定位置；它使用模拟 ioctl，不创建系统 VPN。

Go 测试需要在应用了项目补丁和固定 CA 的 Mihomo 源码上运行；普通上游模块不包含项目扩展入口。内核构建完成后，可复用其构建目录运行：

```bash
HONGFLOW_WORK_DIR="${HONGFLOW_WORK_DIR:-$PWD/work/kernel-build}"
GOTOOLCHAIN=local "$HONGFLOW_WORK_DIR/ohos-go/bin/go" -C "$HONGFLOW_WORK_DIR/wrapper" test -tags netgo ./...
```

当前修复、执行结果及设备验证边界见 [VALIDATION.md](VALIDATION.md)。本机历史截图、测试工程、安装包和日志保存在被忽略的 `validation/` 中，不作为仓库依赖。

## 目录

- `entry/src/main/ets/`：页面、状态模型、存储、卡片与 VPN 扩展。
- `entry/src/main/cpp/`：ArkTS 与原生内核之间的 N-API 桥。
- `native/core/`：Go 内核封装、回归测试、上游补丁与固定 CA。
- `entry/src/main/resources/rawfile/`：Geo 数据和应用内开源许可。
- `tools/`：构建脚本和主机回归。

## 参考与许可

本项目源码按 [GPL-3.0](LICENSE) 发布。

- [FlClash](https://github.com/chen08209/FlClash)：`v0.8.99`，提交 `68c71b8ef9b7486a224972eb371ff153c6b2de0f`。
- [Mihomo fork](https://github.com/chen08209/Clash.Meta)：提交 `8597778c7df410ebe88c57e59eaab32d203156df`。
- [OpenHarmony-SIG Go](https://gitcode.com/openharmony-sig/ohos_golang_go)：提交 `302a5306b6fad2f47196360b82561d1db1f954cf`。

对应声明与完整许可保存在 `native/core/LICENSE.*` 和应用的开源许可入口。固定 CA 的来源、哈希及许可见 [证书说明](native/core/certificates/README.md)；Geo 数据来源与已核实边界见 [数据说明](entry/src/main/resources/rawfile/geodata/SOURCES.md)。上游固定 Geo 二进制缺少完整生成输入清单，保留该来源核实边界，不将仓库许可推定为所有聚合数据的唯一许可。
