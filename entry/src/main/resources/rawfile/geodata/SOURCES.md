# Geo 数据来源

核实日期：2026-10-12。三个二进制直接复制自 FlClash 的固定版本，未重新生成、修改或下载替换。

- 项目：[chen08209/FlClash](https://github.com/chen08209/FlClash)
- Tag：`v0.8.99`
- Commit：`68c71b8ef9b7486a224972eb371ff153c6b2de0f`
- Tag commit 日期：2026-10-03 19:03:12 +08:00。此日期是应用版本日期，不代表 Geo 数据更新日期。
- 对应 Mihomo submodule：`8597778c7df410ebe88c57e59eaab32d203156df`
- 复制前、复制后均与 `git show <commit>:assets/data/<filename>` 逐字节比较一致。

## 文件清单

| 文件 | 字节数 | SHA-256 | 固定来源 |
| --- | ---: | --- | --- |
| `GEOIP.metadb` | 9,643,689 | `7722ab3c5518a27de61f4d444528dbdf3d6067d1614b6c84c66b732fbf9021d7` | [assets/data/GEOIP.metadb](https://github.com/chen08209/FlClash/blob/68c71b8ef9b7486a224972eb371ff153c6b2de0f/assets/data/GEOIP.metadb) |
| `GEOSITE.dat` | 4,433,793 | `098b98841c252e4b0c83cfea9fae19a97b018e142070406f019f7343b9784ad5` | [assets/data/GEOSITE.dat](https://github.com/chen08209/FlClash/blob/68c71b8ef9b7486a224972eb371ff153c6b2de0f/assets/data/GEOSITE.dat) |
| `GEOIP.dat` | 20,512,850 | `2dea9374371ee651b15705293ebd25076cc62948eb8fb8121d69e25db5e1add8` | [assets/data/GEOIP.dat](https://github.com/chen08209/FlClash/blob/68c71b8ef9b7486a224972eb371ff153c6b2de0f/assets/data/GEOIP.dat) |

`GEOIP.metadb` 的 MMDB metadata 为 `database_type=Meta-geoip0`、`build_epoch=1757111843`，表示构建时间 2025-09-05 22:37:23 UTC，即北京时间 2025-09-06 06:37:23。它不是 2026-10-03 新构建的数据。

`GEOIP.dat` 与 `GEOSITE.dat` 未查到嵌入的生成日期；当前 FlClash checkout 是浅克隆，只有 release commit 可见，因此不能从本地 `git log` 确定这两个文件最后更新的日期。

## 来源与许可核实

三个文件所在的 FlClash 仓库 [LICENSE](https://github.com/chen08209/FlClash/blob/68c71b8ef9b7486a224972eb371ff153c6b2de0f/LICENSE) 是 GNU GPL 第 3 版全文。固定版本的 `assets/data` 下只有四个 Geo 二进制，未提供逐文件许可或生成清单。因此这里记录已核实的仓库声明，不把仓库的 GPL 文件推定为所有聚合数据唯一的许可。

FlClash 同一固定版本的 [lib/models/clash_config.dart](https://github.com/chen08209/FlClash/blob/68c71b8ef9b7486a224972eb371ff153c6b2de0f/lib/models/clash_config.dart) 指定以下默认更新源；这些链接是更新来源线索，不是本次复制来源，也没有据此证明冻结二进制对应哪次上游构建：

| 本目录文件 | FlClash 配置中的默认更新源 | 已核实的上游说明 |
| --- | --- | --- |
| `GEOIP.metadb` | [meta-rules-dat/geoip.metadb](https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.metadb) | MetaCubeX 当前 [构建流程](https://github.com/MetaCubeX/meta-rules-dat/blob/master/.github/workflows/run.yml) 将 `Loyalsoldier/geoip` 的 `geoip.dat` 转为 Meta 格式。其 [LICENSE](https://github.com/MetaCubeX/meta-rules-dat/blob/master/LICENSE) 为 GPL 第 3 版。 |
| `GEOIP.dat` | [meta-rules-dat/geoip.dat](https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geoip.dat) | 同一构建流程直接获取 `Loyalsoldier/geoip` release 的 `geoip.dat`。Loyalsoldier 的 [LICENSE](https://github.com/Loyalsoldier/geoip/blob/master/LICENSE) 是 CC BY-SA 4.0；其 [README License](https://github.com/Loyalsoldier/geoip#license) 同时列出 CC BY-SA 4.0 与 GPL-3.0，并声明包含 MaxMind GeoLite2 数据。 |
| `GEOSITE.dat` | [meta-rules-dat/geosite.dat](https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/geosite.dat) | MetaCubeX [README](https://github.com/MetaCubeX/meta-rules-dat#geositedatgeositedb-内容) 和构建流程说明它聚合多个域名列表。已读取 `v2fly/domain-list-community` 的 [MIT LICENSE](https://github.com/v2fly/domain-list-community/blob/master/LICENSE) 与 `blackmatrix7/ios_rule_script` 的 [GPL 第 2 版 LICENSE](https://github.com/blackmatrix7/ios_rule_script/blob/master/LICENSE)。其他聚合列表不能仅凭这两个许可证统一归类。 |

本清单核实了直接拷贝源和上述官方仓库许可文件，但固定 FlClash Geo 二进制未附完整生成输入清单；没有据此宣称每一个聚合列表的独立许可已全部核实。

## 内核使用与 ASN 范围

Mihomo `8597778c7df410ebe88c57e59eaab32d203156df` 的 `constant/path.go` 从内核 home 目录查找这些文件，支持本目录使用的大写文件名。应用应在内核启动的完整配置解析前将 rawfile 资源写入该 home 目录的根部；基础 YAML 导入校验不需要读取这些 Geo 文件。

- 默认 MMDB 模式的 `GEOIP` 使用 `GEOIP.metadb`。
- `geodata-mode: true` 的 `GEOIP` 使用 `GEOIP.dat`。
- `GEOSITE` 规则及对应 DNS 列表使用 `GEOSITE.dat`。

本次不复制 `ASN.mmdb`。该固定内核在 `rules/common/ipasn.go:NewIPASN` 中按需调用 `geodata.InitASN()`，解析 `IP-ASN`／`SRC-IP-ASN` 规则才要求 ASN 数据；普通 `GEOIP`／`GEOSITE` 不要求它。若将来配置含 ASN 规则，需提供 ASN 文件或允许内核按用户配置的 `geox-url.asn` 下载；这三份内置资源不代表已提供离线 ASN 规则支持。
