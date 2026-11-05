# 静态更新清单修复验证

日期：2026-11-05。版本：0.2.1。范围：原生 macOS 和跨平台共享更新检查，保持工资、隐私偏好、24 小时限频、手动检查和手动下载方式。

## RED / GREEN 与集成证据

- RED：为本地真实 HTTP 服务器添加正常静态清单和返回 403 的备用 API，旧实现仍请求 API，`node scripts/test-updates.mjs` 在新场景抛出“更新服务暂时受限”。
- GREEN：Swift 与 JavaScript 都改为静态清单优先；同一场景通过，服务器请求计数证明备用 API 为 0 次。
- `npm run test:updates` 覆盖静态新版、相同版本、低于本机版本、macOS/Windows 平台筛选和纯文本说明。主源 404、403、无效 JSON、外站下载、外站发布页、标签不匹配、预发布版本、无效说明、超大响应、断连和超时均只回退 1 次 API；双源失败保留明确错误。
- 发布生成器拒绝草稿、预发布、无安装包、不完整上传和外站下载地址，只从实际正式 Release 生成清单。
- `npm run test:core` 与已有 10 组 Swift 收入/存储集成通过；自动限频及关闭检查测试继续通过。

## 实际部署及运行

- GitHub Pages 的 `codex/update-feed` 来源已配置并部署，公开 `latest.json` 返回 HTTP 200、`application/json` 和 `Access-Control-Allow-Origin: *`；本次观察到 CDN 缓存上限 600 秒。初始化只公告已经发布的 0.2.0，0.2.1 在对应安装包正式发布后才同步。
- 原生探针直接编译实际 `UpdateService.swift`，使用真实线上静态源和不可连接的备用地址。相同版本返回已是最新；低版本发现实际已发布版本，证明无须 API。未读取用户工资或 UserDefaults。
- ego-browser 加载正式前端资源，应用 Tauri 同样的 CSP 并通过模拟桥提供真实包版本；静态请求使用真实线上地址。启动及点击“检查更新”均显示已是最新版，Performance 记录只有 Pages 请求，没有 API 请求。模拟桥不等于 Windows 原生验收。
- 原生 macOS 13 最低目标的 arm64/x86_64 通用包构建与签名校验通过（临时签名）。SDK 搜索路径及 Intel 兼容库警告不阻断构建；Intel 实机、macOS 13 和 Windows 原生安装未验证。

## 边界

旧 0.2.0 二进制不会自动获得修复，需先手动替换到 0.2.1。主备来源都不可达仍可能检查失败；未承诺网络可用性，不在客户端嵌入 Token，不自动下载或安装。
