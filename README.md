# 牛马上班（macOS）

以当前班次和本年预估收入提供上班鼓励的轻量菜单栏工具，适配 Apple Silicon 与 Intel 机型，最低 macOS 13。

## macOS 与 Windows 共用实现

当前已加入 Tauri 2 跨平台工程骨架。工资、排班、跨夜、休息和收入快照位于 `shared/income-engine.mjs`，Tauri 版 macOS 与 Windows 共用；窗口、系统托盘、关闭后隐藏和登录自动启动位于 `src-tauri`，由 Tauri 在两个系统分别调用原生能力；界面位于 `frontend`，使用同一套 HTML/CSS/JavaScript。原有 `Sources/Niuma` 是已经交付的 Swift/AppKit macOS 版，暂时保留为兼容实现，后续可在 Tauri 版验收通过后移除。

```bash
# 安装前端与 Tauri CLI 依赖
npm install

# 验证共享收入核心
npm run test:core

# 本地 HTTP 验证更新检查，并运行 Swift 收入与更新集成测试
npm run test:updates

# 在具备 Rust 工具链的 macOS 或 Windows 开发机运行
npm run tauri:dev

# 生成对应系统安装包
npm run tauri:build
```

构建前会由 `scripts/sync-frontend-core.mjs` 把共享核心复制到 Tauri 的前端资源目录，源文件仍只有 `shared/income-engine.mjs` 一份。本机当前没有 Rust/Cargo，因此已经完成的 Node 核心测试和 JavaScript 静态检查可以运行，Tauri 原生编译与安装包尚未在本机完成验证。

Windows 构建可以直接使用 `scripts/build-windows.ps1`，或在 GitHub Actions 手动运行“Windows 构建”工作流。工作流会上传 NSIS `.exe` 和 MSI 安装包；拿到 Windows 构建产物后仍需在 Windows 10/11 真机完成托盘、自动启动、安装升级和卸载验收。

## 原生开发版

当前已有 Swift + AppKit 原生工程，无第三方运行依赖。已在本机 M5、macOS 27.2、Swift 6.4.2 命令行工具链上构建，尚未完成正式发布验收。

```bash
# 构建通用（arm64 + x86_64）应用包，并验证本地临时签名。
bash scripts/build-app.sh

# 打开应用；首次使用需要填写自己的工资，程序不会生成示例工资。
open build/牛马上班.app

# 运行真实文件保存、重载和收入计算的集成验证。
swift run --disable-automatic-resolution NiumaIntegrationTests
```

可运行的开发包位于 `build/牛马上班.app`。构建产物不纳入 Git。当前采用本机临时签名，尚未进行 Developer ID 签名或公证，不作为公开分发包。

## 打包分享

```bash
# 生成 dist/牛马上班-<版本>-macOS-universal.zip，内含 .app 与「安装说明.txt」。
bash scripts/package-release.sh
```

默认走 ad-hoc 临时签名，对方解压后首次打开需在「系统设置 → 隐私与安全性」点「仍要打开」，或先执行一次 `xattr -dr com.apple.quarantine`。

配置 Developer ID 后，同一脚本会自动签名、公证并装订，接收方双击即可打开，不再需要放行步骤：

```bash
xcrun notarytool store-credentials niuma-notary --apple-id <账号> --team-id <团队ID> --password <专用密码>
DEVELOPER_ID_APP="Developer ID Application: 名字 (团队ID)" NOTARY_PROFILE=niuma-notary bash scripts/package-release.sh
```

兼容范围：最低 macOS 13 Ventura，最高跟随构建 SDK；打包为 arm64 + x86_64 通用二进制，Apple Silicon 与 Intel 均为原生运行。版本下限由 `Package.swift` 的 `platforms` 与 `Info.plist` 的 `LSMinimumSystemVersion` 共同决定，两者须保持一致。低于 macOS 13 的系统会提示版本不足。

macOS 13/14 上使用 `if #available` 回退：无参 `NSApp.activate()` 与 `NSApplication.activate()` 自 macOS 14 起提供，旧系统改走 `ignoringOtherApps` 等价调用；`NSViewController.loadViewIfNeeded()` 需 macOS 14，改为访问 `view` 触发按需加载。登录启动依赖 macOS 13 起的 `SMAppService`，构成版本下限的技术原因。

首次启动会打开设置；保存后返回当前收入面板。后续启动默认只保留菜单栏叶子图标，点击展开。隐藏金额会同时隐藏设置页工资。原生快捷键：`⌘I` 查看收入、`⌘,` 打开设置、`⌘Q` 退出（应用处于激活状态时）。

## 自动检测更新

原生版和 Tauri 版均提供“设置 → 应用更新”，展示实际应用版本、自动检查开关、“检查更新”和新版下载入口。自动检查默认开启，启动时及持续运行期间每天尝试一次，最近自动尝试时间会保存，24 小时内重启不会重复请求；手动检查可随时使用。开关立即生效，独立于工资表单保存与取消。

从 0.2.1 起，优先读取 GitHub Pages 静态版本清单，主源失败或内容无效时才回退 GitHub API；主源正常时不消耗 API 匿名额度。清单仅同步本仓库已发布的正式 Release，排除草稿与预发布，按数值比较版本并检查本平台是否提供安装包。发现新版后，原生版显示提示和说明，Tauri 首页显示提示并可在设置中查看说明；用户点击后由系统浏览器打开发布页，下载和替换由用户操作。本次没有自动下载或安装功能。

检查仅获取公开版本信息，不携带工资、排班或账号凭证。断网、限流或服务异常时，后台检查不弹错误提示，收入计算继续离线可用；手动检查会显示具体状态。发布新版的方法见 [发布与更新](docs/发布与更新.md)，初始更新功能验证见 [更新检查验证](docs/verification/update-check.md)，0.2.1 的双源验证见 [静态清单验证](docs/verification/static-update-manifest.md)。

## 当前内容

- [需求文档](docs/需求文档.md)：当前版本 v0.6，包含当前/本年预估收入、更新检查、M5 资源预算和 39 个验收场景。
- [交互原型](prototype/index.html)：可直接在浏览器打开，体验当前收入、工资作息设置和工作状态预览。
- [原型源片段](prototype/niuma-income.fragment.html)：用于维护交互原型；`index.html` 是供浏览器打开的导出版。
- `Sources/NiumaCore`：工资排班校验、跨夜收入计算和原子配置存储。
- `Sources/Niuma`：原生菜单栏、收入面板、设置和按需刷新。
- `Tests/NiumaCoreTests`：不依赖 XCTest 的集成验证程序，适用于当前命令行 SDK。
- [本机验证记录](docs/verification/native-baseline.md)：记录实际检查、资源基线和未验证项目。
- [当前与本年收入验证](docs/verification/current-year-income.md)：记录本次计算边界、原生视图、前端操作及构建限制。

## 使用说明

双击 `prototype/index.html`，或将其拖入浏览器。默认使用示例日期和演示时钟；工资和作息仅用于本页演示，不代表原生应用已实现配置保存、系统菜单栏或后台运行。

修改原型时，以 `prototype/niuma-income.fragment.html` 为源文件，并同步重新导出 `index.html`。

## 当前阶段

原生开发版已实现工资作息设置、月薪与日薪计算、多段休息、跨夜跨月、当前班次已赚、本年预估已赚、本地保存、金额隐藏、菜单栏收入和退出。本年金额按当前配置回算，不保存收入历史；面板隐藏且仅显示图标时停止收入刷新，面板打开或菜单栏需要显示增长中的金额时才按秒更新。

登录启动已接入系统服务并展示实际状态，但尚未完成安装后的注册与真实重新登录验收。休眠恢复、完整资源窗口和连续运行 8 小时等项目仍需验证，不能将开发包视为已通过全部验收。

## 配置、重置与卸载

工资作息使用以下配置文件，不保存收入历史，不建立专用缓存或文件日志；更新检查开关及最近自动尝试时间独立保存在系统 UserDefaults 中。Tauri 版分别使用 `niuma.settings.v1` 和 `niuma.updates.v1` 的本地存储：

```text
~/Library/Application Support/com.hcxgrassstar.niuma/settings.json
```

原生“清除设置并重置”会先关闭应用管理的自动启动，再移除自己的工资配置及更新检查偏好；不删除目录中的未知文件。若关闭启动或删除文件失败，界面说明原因并保留恢复入口。

本机安装时将 `.app` 复制到“应用程序”后打开。卸载前先关闭自动启动，按需要执行重置，再退出并移除 `.app`。只删除 `.app` 不代表已经清除配置。

## 资源检查

资源采样工具只读取内核的 physical footprint 和 CPU 累计时间，不读取工资数据。测量时保持被测界面状态不变，正式验收须预热 60 秒，并按需求执行 600 秒稳定采样。

```bash
# 用应用的实际 PID 替换 12345；采样工具不属于被测应用进程。
xcrun swift scripts/measure-resources.swift 12345 600 build/resource-check.json
```

本次记录属于短时开发基线，不能代替四种显示模式的完整窗口或 8 小时稳定性验收。

需求文档和原型文件统一存放在本项目，旧位置的兼容链接已删除。请使用本项目中的文档和原型入口；之前会话中引用旧路径的链接或预览可能失效。
