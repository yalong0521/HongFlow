# 内核可信 CA

`cacert-2026-09-25.pem` 是 curl 官方从 Mozilla 根证书库提取的固定版本。2026-10-12 通过 HTTPS 下载并与官方同版本 SHA-256 文件核对，未修改证书、信任标记或正文。

- 官方说明及许可：[curl CA Extract](https://curl.se/docs/caextract.html)
- 固定归档：[cacert-2026-09-25.pem](https://curl.se/ca/cacert-2026-09-25.pem)
- 官方哈希：[cacert-2026-09-25.pem.sha256](https://curl.se/ca/cacert-2026-09-25.pem.sha256)
- Mozilla 数据时间：`2026-09-25 03:12:01 GMT`，PEM 文件头提供此日期。
- 文件大小：188900 字节；包含 121 个根证书。
- SHA-256：`a41b5d356aea97a529fe27e0f7316d2f9d946d75927476cf9cf1b90637d00505`。
- 许可：MPL-2.0；完整文本保留于 [LICENSE-MPL-2.0.txt](LICENSE-MPL-2.0.txt)，来自 [Mozilla 官方文本](https://www.mozilla.org/media/MPL/2.0/index.f75d2927d3c1.txt)。

`tools/build-core.sh` 在每次构建前核对上述固定哈希，并将文件复制到固定 Mihomo 源码的 `component/ca/ca-certificates.crt`，由上游 `go:embed` 编入动态库。上游 `ca.GetCertPool` 追加这些根证书；节点 TLS、提供者 HTTPS 和 DoH/DoT 使用其证书池，无需假定 HarmonyOS 可读取 Linux 系统证书目录。

此次集成没有开启跳过证书验证。根证书、签名链、主机名等校验按 Mihomo 的正常 TLS 行为执行；节点配置显式设置的 TLS 选项仍由内核处理。PEM 是 Mozilla 信任库的转换版本，Firefox 中额外的域名约束不会随 PEM 转换保留，详见官方提取说明。更新信任库时需要同时核对官方来源、更新文件与固定哈希，不能仅下载一个未核验的“最新版”替换。
